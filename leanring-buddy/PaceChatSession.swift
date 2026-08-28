//
//  PaceChatSession.swift
//  leanring-buddy
//
//  Backing store for the in-window chat surface in the Conversations tab.
//  This file owns the ordered list of messages the SwiftUI view renders;
//  the SOURCE OF TRUTH for persistence is still the existing `paceHistory`
//  retrieval index that voice turns already write to via
//  `PaceLocalRetriever.recordPaceHistory`. The chat session reads from
//  that same index at load time and listens for new turns through
//  `appendTurn(userTranscript:assistantResponse:)`, which `CompanionManager`
//  calls from the single `recordConversationTurn` chokepoint — so voice
//  and chat are always rendering the same conversation.
//
//  Mute is intentionally a per-session ephemeral `@Published` flag: it
//  is NOT persisted (no UserDefaults, no chat-level prefs file). On app
//  restart it returns to the default (false → Pace still speaks). The
//  flag is read once per turn by `CompanionManager` when chat-mode
//  submission begins, so toggling it mid-turn affects the NEXT turn but
//  not the one currently streaming — matches voice-turn semantics.
//

import Combine
import Foundation
import SwiftUI

// `nonisolated`: these are plain value DTOs. The app target's default
// actor isolation is MainActor, which would otherwise pin them there —
// but the pure `PaceChatTranscriptModel` mapping layer (and its
// off-main-actor tests) needs to read them from a nonisolated context.
nonisolated enum PaceChatRole: String, Codable, Equatable {
    case user
    case pace
}

nonisolated struct PaceChatMessage: Identifiable, Equatable {
    let id: String
    let role: PaceChatRole
    let body: String
    let createdAt: Date

    var isInternalRuntimeEvent: Bool {
        guard role == .user else { return false }
        let normalizedBody =
            body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedBody.hasPrefix("(system)")
            || normalizedBody.hasPrefix("(agent step ")
            || normalizedBody.hasPrefix("session ended (cause:")
    }

    var persistedTurnIdentifier: String? {
        guard id.hasSuffix(":user") || id.hasSuffix(":pace"),
            let roleSeparatorIndex = id.lastIndex(of: ":")
        else { return nil }
        return String(id[..<roleSeparatorIndex])
    }
}

/// Read surface the chat session uses to rehydrate prior turns from
/// `paceHistory`. Kept as a tiny protocol so unit tests can inject a
/// fixture list of turns without standing up the full retrieval index.
/// The single conformer in product code is `PaceLocalChatHistoryReader`,
/// which reads the same `retrieval-index.json` the legacy
/// `PaceConversationsView` static reader used to read.
protocol PaceChatHistorySource: AnyObject {
    /// Returns past Pace turns oldest-first so the chat transcript can
    /// be appended in natural order (newest at the bottom).
    func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn]
}

/// Raw turn pair extracted from `paceHistory` storage. Mirrors the
/// "User: …\nPace: …" body shape `recordPaceHistory` writes; the
/// session expands each pair into two `PaceChatMessage` rows.
struct PaceChatHistoryTurn: Equatable, Sendable {
    let id: String
    let userText: String
    let paceText: String
    let recordedAt: Date?
}

/// Thin abstraction over the chat-mode submission path on
/// `CompanionManager`. Exists so `PaceChatSession` can be unit-tested
/// without instantiating a real `CompanionManager` (which owns the
/// dictation engine, the LM Studio client, and a dozen other heavy
/// dependencies). Production wiring passes a closure that forwards
/// into `submitChatTranscriptFromChatSession(_:)`.
protocol PaceChatTranscriptSubmitting: AnyObject {
    func submitChatTranscript(
        _ transcript: String,
        optimisticMessageIdentifier: String
    )
}

@MainActor
final class PaceChatSession: ObservableObject {
    @Published private(set) var messages: [PaceChatMessage] = []
    @Published private(set) var hasLoadedHistory: Bool = false

    /// Mute toggle for THIS session only. Reset to `false` on every app
    /// launch (a fresh `CompanionManager` builds a fresh session) so
    /// nothing persists across restarts. The PRD explicitly calls this
    /// out: "Mute is a per-session ephemeral flag — do NOT persist it
    /// across restart."
    @Published var isChatTTSMuted: Bool = false

    /// Keeps an unfinished command alive while the transient notch tray is
    /// closed and reopened. This remains session-only and is never persisted.
    @Published var draftMessageText: String = ""

    private var isHistoryLoadInFlight = false

    private let historySource: PaceChatHistorySource
    /// Strongly held. The adapter that conforms to this protocol in
    /// production code holds `CompanionManager` weakly, so a strong
    /// reference here cannot create a retain cycle. Tests can pass a
    /// fixture submitter that's safe to keep alive for the lifetime of
    /// the session under test.
    private let transcriptSubmitter: any PaceChatTranscriptSubmitting

    init(
        historySource: PaceChatHistorySource,
        transcriptSubmitter: any PaceChatTranscriptSubmitting
    ) {
        self.historySource = historySource
        self.transcriptSubmitter = transcriptSubmitter
    }

    /// Pulls past `paceHistory` turns and seeds `messages` with them.
    /// Idempotent: re-loading replaces the rendered transcript wholesale
    /// from the persistence layer, so newly-arrived voice turns show up
    /// when the user re-opens the window. Safe to call from `.onAppear`.
    func loadHistory() {
        let pastTurns = historySource.loadPastTurnsOldestFirst()
        applyLoadedHistory(pastTurns)
    }

    /// The production source reads a JSON index from disk. Keep that work
    /// away from the main actor so opening a Pace surface never waits on a
    /// growing retrieval index. Test sources remain synchronous.
    func loadHistoryWithoutBlockingInterface() {
        guard !isHistoryLoadInFlight else { return }
        guard let localHistoryReader = historySource as? PaceLocalChatHistoryReader else {
            loadHistory()
            return
        }

        isHistoryLoadInFlight = true
        let messageIdentifiersBeforeHistoryLoad = Set(messages.map(\.id))
        Task { [weak self] in
            let pastTurns = await localHistoryReader.loadPastTurnsOldestFirstOffMain()
            guard let self else { return }
            let messagesAddedDuringHistoryLoad = self.messages.filter { message in
                !messageIdentifiersBeforeHistoryLoad.contains(message.id)
            }
            self.isHistoryLoadInFlight = false
            self.applyLoadedHistory(pastTurns)
            let loadedMessageIdentifiers = Set(self.messages.map(\.id))
            self.messages.append(
                contentsOf: messagesAddedDuringHistoryLoad.filter { message in
                    !loadedMessageIdentifiers.contains(message.id)
                })
        }
    }

    private func applyLoadedHistory(_ pastTurns: [PaceChatHistoryTurn]) {
        var rehydratedMessages: [PaceChatMessage] = []
        rehydratedMessages.reserveCapacity(pastTurns.count * 2)
        for pastTurn in pastTurns {
            let baseTimestamp = pastTurn.recordedAt ?? Date.distantPast
            if !pastTurn.userText.isEmpty {
                rehydratedMessages.append(
                    PaceChatMessage(
                        id: "\(pastTurn.id):user",
                        role: .user,
                        body: pastTurn.userText,
                        createdAt: baseTimestamp
                    )
                )
            }
            if !pastTurn.paceText.isEmpty {
                rehydratedMessages.append(
                    PaceChatMessage(
                        id: "\(pastTurn.id):pace",
                        role: .pace,
                        // Offset the assistant timestamp by 1ms so
                        // ordering by `createdAt` is stable when the
                        // recorded turn timestamp is the same for both
                        // halves (always true — they're written
                        // together).
                        body: pastTurn.paceText,
                        createdAt: baseTimestamp.addingTimeInterval(0.001)
                    )
                )
            }
        }
        messages = rehydratedMessages
        hasLoadedHistory = true
    }

    /// Called by the chat view when the user hits Enter. Trims the
    /// input, appends the user message locally so the row renders
    /// immediately (the planner pipeline can take seconds to start
    /// streaming), then forwards to `CompanionManager` through the
    /// submitter. The matching assistant message is appended later by
    /// `appendCompletedTurn` from `recordConversationTurn` — that's
    /// where we get the final cleaned spoken text.
    func submitUserMessage(_ rawTranscript: String) {
        let trimmedTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        let now = Date()
        let pendingMessageId =
            "chat-pending-\(Int(now.timeIntervalSince1970 * 1000))-\(abs(trimmedTranscript.hashValue))"
        messages.append(
            PaceChatMessage(
                id: pendingMessageId,
                role: .user,
                body: trimmedTranscript,
                createdAt: now
            )
        )
        transcriptSubmitter.submitChatTranscript(
            trimmedTranscript,
            optimisticMessageIdentifier: pendingMessageId
        )
    }

    /// `CompanionManager.recordConversationTurn` calls this after every
    /// turn — voice OR chat — so the chat surface stays aligned with
    /// the canonical `paceHistory` write. Dedupes against the optimistic
    /// user row that `submitUserMessage` appended.
    func appendCompletedTurn(
        userTranscript: String,
        assistantResponse: String,
        recordedAt: Date = Date()
    ) {
        let trimmedUserTranscript = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistantResponse = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableTurnIdPrefix = "chat-\(Int(recordedAt.timeIntervalSince1970))-\(abs(trimmedUserTranscript.hashValue))"

        var completedUserMessageIndex: Int?
        if !trimmedUserTranscript.isEmpty {
            if let optimisticMessageIndex = messages.firstIndex(where: { message in
                message.id.hasPrefix("chat-pending-")
                    && message.role == .user
                    && message.body == trimmedUserTranscript
            }) {
                messages[optimisticMessageIndex] = PaceChatMessage(
                    id: "\(stableTurnIdPrefix):user",
                    role: .user,
                    body: trimmedUserTranscript,
                    createdAt: recordedAt
                )
                completedUserMessageIndex = optimisticMessageIndex
            } else if let mostRecentMessageIndex = messages.indices.last,
                messages[mostRecentMessageIndex].role == .user,
                messages[mostRecentMessageIndex].body == trimmedUserTranscript
            {
                completedUserMessageIndex = mostRecentMessageIndex
            } else {
                messages.append(
                    PaceChatMessage(
                        id: "\(stableTurnIdPrefix):user",
                        role: .user,
                        body: trimmedUserTranscript,
                        createdAt: recordedAt
                    )
                )
                completedUserMessageIndex = messages.indices.last
            }
        }

        if !trimmedAssistantResponse.isEmpty {
            let assistantMessage = PaceChatMessage(
                id: "\(stableTurnIdPrefix):pace",
                role: .pace,
                body: trimmedAssistantResponse,
                createdAt: recordedAt.addingTimeInterval(0.001)
            )
            if let completedUserMessageIndex {
                messages.insert(
                    assistantMessage,
                    at: min(completedUserMessageIndex + 1, messages.count)
                )
            } else {
                messages.append(assistantMessage)
            }
        }
    }

    /// Removes optimistic rows for queue entries the user cleared before
    /// execution. Active and completed turns have stable non-pending IDs and
    /// are therefore never affected.
    func removePendingUserMessages(withIdentifiers messageIdentifiers: [String]) {
        let messageIdentifierSet = Set(messageIdentifiers)
        guard !messageIdentifierSet.isEmpty else { return }
        messages.removeAll { message in
            messageIdentifierSet.contains(message.id)
        }
    }

    /// Internal runtime turns stay in persistence and planner history, but they
    /// must never masquerade as something the user typed in chat surfaces.
    var userFacingMessages: [PaceChatMessage] {
        let hiddenTurnIdentifiers = Set(
            messages.compactMap { message in
                message.isInternalRuntimeEvent
                    ? message.persistedTurnIdentifier
                    : nil
            }
        )

        return messages.filter { message in
            guard let persistedTurnIdentifier = message.persistedTurnIdentifier else {
                return !message.isInternalRuntimeEvent
            }
            return !hiddenTurnIdentifiers.contains(persistedTurnIdentifier)
        }
    }

    /// Pure test surface: returns whichever subset of user-visible messages matches
    /// the search query (case-insensitive substring against role-agnostic
    /// body text). Lives here rather than in the view so the search
    /// behavior is unit-testable and consistent if more surfaces start
    /// rendering the chat transcript.
    func filteredMessages(matching searchQuery: String) -> [PaceChatMessage] {
        let trimmedQuery =
            searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmedQuery.isEmpty else { return userFacingMessages }
        return userFacingMessages.filter { message in
            message.body.lowercased().contains(trimmedQuery)
        }
    }
}

/// Production conformer of `PaceChatHistorySource`. Reads the same
/// `retrieval-index.json` file that the static reader inside
/// `PaceConversationsView` used to read directly — but exposes it as
/// an injectable protocol so the new chat code stays unit-testable.
@MainActor
final class PaceLocalChatHistoryReader: PaceChatHistorySource {

    private nonisolated static let maximumDisplayedTurnCount = 200

    func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
        Self.loadPastTurnsOldestFirstFromDisk()
    }

    nonisolated func loadPastTurnsOldestFirstOffMain() async -> [PaceChatHistoryTurn] {
        await Task.detached(priority: .userInitiated) {
            Self.loadPastTurnsOldestFirstFromDisk()
        }.value
    }

    private nonisolated static func loadPastTurnsOldestFirstFromDisk() -> [PaceChatHistoryTurn] {
        guard let indexURL = retrievalIndexFileURL(),
            let indexData = try? Data(contentsOf: indexURL),
            let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let rawDocuments = indexJSON["documents"] as? [[String: Any]]
        else {
            return []
        }

        let isoDateFormatterWithFractionalSeconds = ISO8601DateFormatter()
        isoDateFormatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoDateFormatterPlain = ISO8601DateFormatter()

        let pastTurns: [PaceChatHistoryTurn] = rawDocuments.compactMap { documentRaw in
            guard let source = documentRaw["source"] as? String, source == "paceHistory",
                let id = documentRaw["id"] as? String,
                let bodyText = documentRaw["text"] as? String
            else {
                return nil
            }
            let (userText, paceText) = Self.splitUserAndPace(bodyText)
            let recordedAt: Date?
            if let modifiedAt = documentRaw["modifiedAt"] as? Double {
                recordedAt = Date(timeIntervalSinceReferenceDate: modifiedAt)
            } else if let modifiedAtString = documentRaw["modifiedAt"] as? String {
                recordedAt =
                    isoDateFormatterWithFractionalSeconds.date(from: modifiedAtString)
                    ?? isoDateFormatterPlain.date(from: modifiedAtString)
            } else {
                recordedAt = nil
            }
            return PaceChatHistoryTurn(
                id: id,
                userText: userText,
                paceText: paceText,
                recordedAt: recordedAt
            )
        }
        // Oldest-first so the chat transcript renders top-down with the
        // newest message at the bottom — standard chat ordering.
        let oldestFirstTurns = pastTurns.sorted {
            ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast)
        }
        return Array(oldestFirstTurns.suffix(maximumDisplayedTurnCount))
    }

    private nonisolated static func retrievalIndexFileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace/retrieval-index.json")
    }

    /// Pace history docs are stored as "User: …\nPace: …". Same logic
    /// the legacy static reader used; moved here so the production
    /// conformer and tests share one parser.
    nonisolated static func splitUserAndPace(
        _ documentText: String
    ) -> (userText: String, paceText: String) {
        let lowercasedDocument = documentText.lowercased()
        guard let userMarkerRange = lowercasedDocument.range(of: "user:") else {
            return (documentText, "")
        }
        let afterUserMarker = documentText[userMarkerRange.upperBound...]
        if let paceMarkerRange = afterUserMarker.range(of: "Pace:") {
            let userText = afterUserMarker[..<paceMarkerRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let paceText = afterUserMarker[paceMarkerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (userText, paceText)
        }
        return (
            afterUserMarker.trimmingCharacters(in: .whitespacesAndNewlines),
            ""
        )
    }
}
