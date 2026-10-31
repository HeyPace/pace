// Shared live transcript backed by the local paceHistory retrieval index.

import Combine
import Foundation
import SwiftUI

// `nonisolated`: these are plain value DTOs. The app target's default
// actor isolation is MainActor, which would otherwise pin them there —
// but the pure `PaceChatTranscriptModel` mapping layer (and its
// off-main-actor tests) needs to read them from a nonisolated context.
nonisolated enum PaceChatRole: String, Codable, Equatable, Sendable {
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
    var conversationEvent: ConversationEvent? = nil
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
    @Published private(set) var latestScreenSuggestionEvent: ConversationEvent?
    @Published private var lastAcknowledgedScreenSuggestionEventIdentifier: String
    @Published private var screenSuggestionReadThroughDate: Date?

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
    private let preferences: UserDefaults?
    private let now: () -> Date
    /// Strongly held. The adapter that conforms to this protocol in
    /// production code holds `CompanionManager` weakly, so a strong
    /// reference here cannot create a retain cycle. Tests can pass a
    /// fixture submitter that's safe to keep alive for the lifetime of
    /// the session under test.
    private let transcriptSubmitter: any PaceChatTranscriptSubmitting

    init(
        historySource: PaceChatHistorySource,
        transcriptSubmitter: any PaceChatTranscriptSubmitting,
        preferences: UserDefaults? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.historySource = historySource
        self.transcriptSubmitter = transcriptSubmitter
        self.preferences = preferences
        self.now = now
        self.lastAcknowledgedScreenSuggestionEventIdentifier = preferences.map {
            PaceUserPreferencesStore.string(.lastAcknowledgedScreenSuggestionEventIdentifier, default: "", defaults: $0)
        } ?? ""
        self.screenSuggestionReadThroughDate = preferences.flatMap {
            PaceUserPreferencesStore.date(.screenSuggestionReadThroughDate, defaults: $0)
        }
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
        Task { [weak self] in
            let pastTurns = await localHistoryReader.loadPastTurnsOldestFirstOffMain()
            guard let self else { return }
            self.isHistoryLoadInFlight = false
            self.applyLoadedHistory(pastTurns)
        }
    }

    func applyLoadedHistory(_ pastTurns: [PaceChatHistoryTurn]) {
        let currentMessages = messages
        let currentScreenSuggestionEvent = latestScreenSuggestionEvent
        messages = []
        for pastTurn in pastTurns {
            if let event = pastTurn.conversationEvent {
                upsertConversationEvent(event)
                continue
            }
            let baseTimestamp = pastTurn.recordedAt ?? Date.distantPast
            if !pastTurn.userText.isEmpty {
                upsertMessage(PaceChatMessage(id: "\(pastTurn.id):user", role: .user,
                    body: pastTurn.userText, createdAt: baseTimestamp))
            }
            if !pastTurn.paceText.isEmpty {
                upsertMessage(PaceChatMessage(id: "\(pastTurn.id):pace", role: .pace,
                    body: pastTurn.paceText, createdAt: baseTimestamp.addingTimeInterval(0.001)))
            }
        }
        // Main-actor events that arrived or changed while disk was being read win.
        for message in currentMessages { upsertMessage(message) }
        if let currentScreenSuggestionEvent { upsertConversationEvent(currentScreenSuggestionEvent) }
        messages.sort { $0.createdAt < $1.createdAt }
        hasLoadedHistory = true
    }

    func upsertConversationEvent(_ event: ConversationEvent) {
        upsertMessage(PaceChatMessage(id: event.eventID, role: event.role,
            body: event.text, createdAt: event.createdAt))
        if event.role == .pace, event.origin == .proactive, event.deliveryState == .completed,
           event.eventID.hasPrefix("screen-suggestion-"),
           !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           latestScreenSuggestionEvent.map({ event.createdAt >= $0.createdAt }) ?? true {
            latestScreenSuggestionEvent = event
        }
    }

    var hasUnreadScreenSuggestion: Bool {
        guard let event = latestScreenSuggestionEvent,
              event.eventID != lastAcknowledgedScreenSuggestionEventIdentifier else { return false }
        guard let screenSuggestionReadThroughDate else { return true }
        return event.createdAt >= screenSuggestionReadThroughDate
    }

    func conversationPanelDidShow(_ intent: PaceConversationPanelPresentationIntent) {
        guard intent == .interactive else { return }
        acknowledgeScreenSuggestions()
    }

    func acknowledgeScreenSuggestions() {
        let acknowledgementDate = now()
        if let screenSuggestionReadThroughDate, acknowledgementDate < screenSuggestionReadThroughDate { return }
        screenSuggestionReadThroughDate = acknowledgementDate
        if let preferences {
            PaceUserPreferencesStore.setDate(acknowledgementDate, for: .screenSuggestionReadThroughDate, defaults: preferences)
        }
        if let event = latestScreenSuggestionEvent, event.createdAt <= acknowledgementDate {
            lastAcknowledgedScreenSuggestionEventIdentifier = event.eventID
            if let preferences {
                PaceUserPreferencesStore.setString(event.eventID,
                    for: .lastAcknowledgedScreenSuggestionEventIdentifier, defaults: preferences)
            }
        }
    }

    private func upsertMessage(_ message: PaceChatMessage) {
        if let messageIndex = messages.firstIndex(where: { $0.id == message.id }) {
            messages[messageIndex] = message
        } else {
            messages.append(message)
        }
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
        acknowledgeScreenSuggestions()
        let now = Date()
        let pendingMessageId =
            "chat-pending-" + UUID().uuidString
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
        let stableTurnIdPrefix = "chat-" + UUID().uuidString

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
    private nonisolated let indexURL: URL?

    init(indexURL: URL? = nil) {
        self.indexURL = indexURL
    }

    func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
        Self.loadPastTurnsOldestFirstFromDisk(indexURL: indexURL)
    }

    nonisolated func loadPastTurnsOldestFirstOffMain() async -> [PaceChatHistoryTurn] {
        let indexURL = indexURL
        return await Task.detached(priority: .userInitiated) {
            Self.loadPastTurnsOldestFirstFromDisk(indexURL: indexURL)
        }.value
    }

    private nonisolated static func loadPastTurnsOldestFirstFromDisk(indexURL: URL?) -> [PaceChatHistoryTurn] {
        guard let indexURL = indexURL ?? retrievalIndexFileURL(),
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
                recordedAt: recordedAt,
                conversationEvent: (documentRaw["conversationEvent"] as? [String: Any]).flatMap { rawEvent in
                    guard let eventData = try? JSONSerialization.data(withJSONObject: rawEvent) else { return nil }
                    return try? JSONDecoder().decode(ConversationEvent.self, from: eventData)
                }
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
