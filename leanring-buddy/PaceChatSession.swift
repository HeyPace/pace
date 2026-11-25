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
    var speechRequest: PaceSpeechRequest? = nil
    var turnIdentifier: String? = nil
    var origin: ConversationEvent.Origin? = nil
    var deliveryState: ConversationEvent.DeliveryState? = nil
    var generatedImagePreviewID: UUID? = nil
    var threadRootID: String? = nil
    var powerCatalog: PaceChatPowerCatalog? = nil

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
    @Published private(set) var messages: [PaceChatMessage] = [] {
        didSet {
            cachedReplyCounts = nil
            cachedTurnRoots = nil
        }
    }
    @Published private(set) var activeThreadRootID: String?
    private var cachedTurnRoots: [String: String]?
    private var cachedReplyCounts: [String: Int]?
    private var draftConnections: [String?: PacePowerConnection] = [:]
    private var inactiveDrafts: [String?: String] = [:]
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

    private var historyLoadID: UUID?

    private let historySource: PaceChatHistorySource
    private let preferences: UserDefaults?
    private let now: () -> Date
    private let didAcknowledgeScreenSuggestion: (String) -> Void
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
        now: @escaping () -> Date = Date.init,
        didAcknowledgeScreenSuggestion: @escaping (String) -> Void = { _ in }
    ) {
        self.historySource = historySource
        self.transcriptSubmitter = transcriptSubmitter
        self.preferences = preferences
        self.now = now
        self.didAcknowledgeScreenSuggestion = didAcknowledgeScreenSuggestion
        self.lastAcknowledgedScreenSuggestionEventIdentifier =
            preferences.map {
                PaceUserPreferencesStore.string(
                    .lastAcknowledgedScreenSuggestionEventIdentifier, default: "", defaults: $0)
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
        guard historyLoadID == nil else { return }
        guard let localHistoryReader = historySource as? PaceLocalChatHistoryReader else {
            loadHistory()
            return
        }

        let loadID = UUID()
        historyLoadID = loadID
        Task { [weak self] in
            let pastTurns = await localHistoryReader.loadPastTurnsOldestFirstOffMain()
            guard let self, self.historyLoadID == loadID else { return }
            self.historyLoadID = nil
            self.applyLoadedHistory(pastTurns)
        }
    }

    func applyLoadedHistory(_ pastTurns: [PaceChatHistoryTurn]) {
        var merged: [PaceChatMessage] = []
        var positions: [String: Int] = [:]
        func merge(_ row: PaceChatMessage) {
            if let position = positions[row.id] {
                merged[position] = row
            } else {
                positions[row.id] = merged.count
                merged.append(row)
            }
        }

        let liveSuggestion = latestScreenSuggestionEvent
        for turn in pastTurns {
            if let event = turn.conversationEvent {
                merge(message(from: event))
                updateLatestScreenSuggestion(event)
            } else {
                let date = turn.recordedAt ?? .distantPast
                if !turn.userText.isEmpty {
                    merge(PaceChatMessage(id: "\(turn.id):user", role: .user, body: turn.userText, createdAt: date))
                }
                if !turn.paceText.isEmpty {
                    merge(
                        PaceChatMessage(
                            id: "\(turn.id):pace", role: .pace, body: turn.paceText,
                            createdAt: date.addingTimeInterval(0.001)))
                }
            }
        }
        for live in messages { merge(live) }
        if let liveSuggestion { updateLatestScreenSuggestion(liveSuggestion) }
        messages = merged.sorted { $0.createdAt < $1.createdAt }
        hasLoadedHistory = true
    }

    func orderMessagesChronologically() {
        messages.sort { $0.createdAt < $1.createdAt }
    }

    func upsertConversationEvent(_ event: ConversationEvent) {
        upsertMessage(message(from: event))
        updateLatestScreenSuggestion(event)
    }

    private func message(from event: ConversationEvent) -> PaceChatMessage {
        PaceChatMessage(
            id: event.eventID, role: event.role, body: event.text, createdAt: event.createdAt,
            speechRequest: event.speechRequest, turnIdentifier: event.turnID, origin: event.origin,
            deliveryState: event.deliveryState, generatedImagePreviewID: event.generatedImagePreviewID,
            threadRootID: event.threadRootID, powerCatalog: event.powerCatalog)
    }

    private func updateLatestScreenSuggestion(_ event: ConversationEvent) {
        if event.role == .pace, event.origin == .proactive, event.deliveryState == .completed,
            event.eventID.hasPrefix("screen-suggestion-"),
            !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            latestScreenSuggestionEvent.map({ event.createdAt >= $0.createdAt }) ?? true
        {
            latestScreenSuggestionEvent = event
        }
    }

    var activeThreadRoot: PaceChatMessage? {
        guard let activeThreadRootID else { return nil }
        return messages.first { $0.id == activeThreadRootID }
    }

    var visibleMessages: [PaceChatMessage] {
        let visible = userFacingMessages
        guard let activeThreadRootID else { return visible.filter { $0.threadRootID == nil } }
        let root = visible.first { $0.id == activeThreadRootID }
        return [root].compactMap { $0 } + visible.filter { $0.threadRootID == activeThreadRootID }
    }

    func openThread(for message: PaceChatMessage) {
        guard let stored = messages.first(where: { $0.id == message.id }) else { return }
        navigate(to: stored.threadRootID ?? stored.id)
    }

    func returnToMainChat() { navigate(to: nil) }

    func showLocation(of message: PaceChatMessage) {
        guard let stored = messages.first(where: { $0.id == message.id }) else { return }
        navigate(to: stored.threadRootID)
    }

    func navigate(to rootID: String?) {
        guard activeThreadRootID != rootID else { return }
        inactiveDrafts[activeThreadRootID] = draftMessageText.isEmpty ? nil : draftMessageText
        draftMessageText = inactiveDrafts.removeValue(forKey: rootID) ?? ""
        activeThreadRootID = rootID
    }

    func replyCount(for message: PaceChatMessage) -> Int {
        if cachedReplyCounts == nil {
            var counts: [String: Int] = [:]
            for reply in userFacingMessages where !(reply.role == .pace && reply.origin == .progress) {
                if let root = reply.threadRootID { counts[root, default: 0] += 1 }
            }
            cachedReplyCounts = counts
        }
        return cachedReplyCounts?[message.id] ?? 0
    }

    func threadRootID(forTurnID turnID: String) -> String? {
        if cachedTurnRoots == nil {
            var roots: [String: String] = [:]
            for message in messages where message.role == .user {
                guard let root = message.threadRootID else { continue }
                roots[message.id] = root
                if let id = message.turnIdentifier { roots[id] = root }
            }
            cachedTurnRoots = roots
        }
        return cachedTurnRoots?[turnID]
    }

    func plannerHistory(
        forThreadRootID rootID: String, excludingTurnID: String?,
        maximumPriorTurns: Int = 8, since cutoff: Date? = nil
    )
        -> [(userTranscript: String, assistantResponse: String)]
    {
        let visible = userFacingMessages
        var history: [(userTranscript: String, assistantResponse: String)] = []
        if let root = visible.first(where: { $0.id == rootID }) {
            let anchor = String(root.body.prefix(4_000))
            let rootTurnID = root.turnIdentifier ?? root.persistedTurnIdentifier ?? root.id
            let counterpart =
                maximumPriorTurns > 0
                ? visible.last { candidate in
                    candidate.role != root.role && candidate.threadRootID == nil && candidate.origin != .progress
                        && candidate.deliveryState != .cancelled && candidate.deliveryState != .interrupted
                        && (candidate.turnIdentifier ?? candidate.persistedTurnIdentifier ?? candidate.id) == rootTurnID
                        && (cutoff.map { candidate.createdAt >= $0 } ?? true)
                } : nil
            let pairedText = String((counterpart?.body ?? "").prefix(2_000))
            history.append(root.role == .user ? (anchor, pairedText) : (pairedText, anchor))
        }
        guard maximumPriorTurns > 0 else { return history }

        // Read recent completed replies backward so idle queues and long-lived
        // threads cannot overwhelm the new request. Preserve the anchor separately.
        var recentTurnIDs: [String] = []
        var selectedTurns = Set<String>()
        for message in visible.reversed() where message.threadRootID == rootID && message.role == .pace {
            guard let turnID = message.turnIdentifier ?? message.persistedTurnIdentifier,
                turnID != excludingTurnID, cutoff.map({ message.createdAt >= $0 }) ?? true,
                message.deliveryState != .cancelled,
                message.deliveryState != .interrupted, message.origin != .progress
            else { continue }
            if selectedTurns.insert(turnID).inserted { recentTurnIDs.append(turnID) }
            if recentTurnIDs.count >= maximumPriorTurns { break }
        }
        var pairsByTurn: [String: (userTranscript: String, assistantResponse: String)] = [:]
        for message in visible where message.threadRootID == rootID {
            guard let turnID = message.turnIdentifier ?? message.persistedTurnIdentifier,
                selectedTurns.contains(turnID), cutoff.map({ message.createdAt >= $0 }) ?? true,
                message.deliveryState != .cancelled,
                message.deliveryState != .interrupted
            else { continue }
            if message.role == .user {
                pairsByTurn[turnID, default: ("", "")].userTranscript = String(message.body.prefix(2_000))
            } else {
                let preceding = pairsByTurn[turnID]?.assistantResponse ?? ""
                let text = String(message.body.prefix(2_000))
                // Keep the final answer when preceding progress has filled the budget.
                let remaining = max(0, 2_000 - text.count - 1)
                let prefix = preceding.suffix(remaining)
                pairsByTurn[turnID, default: ("", "")].assistantResponse = prefix.isEmpty ? text : "\(prefix)\n\(text)"
            }
        }
        history.append(contentsOf: recentTurnIDs.reversed().compactMap { pairsByTurn[$0] })
        return history
    }

    func clearHistory() {
        historyLoadID = nil
        activeThreadRootID = nil
        draftMessageText = ""
        inactiveDrafts.removeAll()
        draftConnections.removeAll()
        latestScreenSuggestionEvent = nil
        messages.removeAll()
    }

    var hasUnreadScreenSuggestion: Bool {
        guard let event = latestScreenSuggestionEvent,
            event.eventID != lastAcknowledgedScreenSuggestionEventIdentifier
        else { return false }
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
            PaceUserPreferencesStore.setDate(
                acknowledgementDate, for: .screenSuggestionReadThroughDate, defaults: preferences)
        }
        if let event = latestScreenSuggestionEvent, event.createdAt <= acknowledgementDate {
            acknowledgeScreenSuggestion(eventIdentifier: event.eventID)
        }
    }

    func acknowledgeScreenSuggestion(eventIdentifier: String) {
        guard latestScreenSuggestionEvent?.eventID == eventIdentifier else { return }
        lastAcknowledgedScreenSuggestionEventIdentifier = eventIdentifier
        if let preferences {
            PaceUserPreferencesStore.setString(
                eventIdentifier,
                for: .lastAcknowledgedScreenSuggestionEventIdentifier, defaults: preferences)
        }
        didAcknowledgeScreenSuggestion(eventIdentifier)
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
    func prepareDraft(using connection: PacePowerConnection) {
        var content = draftMessageText
        if let previous = draftConnections[activeThreadRootID] {
            if content == previous.suggestedRequest {
                content = ""
            } else {
                let previousPrefixes = ["Use " + previous.id + ": ", "Use " + previous.id + " to "]
                if let prefix = previousPrefixes.first(where: content.hasPrefix) { content.removeFirst(prefix.count) }
            }
        }
        draftConnections[activeThreadRootID] = connection
        draftMessageText =
            content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? connection.suggestedRequest : "Use " + connection.id + ": " + content
    }

    func insertPowerExample(_ example: String) {
        let existing = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty {
            draftMessageText = example
        } else if existing != example && !existing.hasSuffix("\n" + example) {
            draftMessageText += "\n" + example
        }
    }

    func submitUserMessage(_ rawTranscript: String) {
        let trimmedTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        draftConnections[activeThreadRootID] = nil
        acknowledgeScreenSuggestions()
        let now = Date()
        let pendingMessageId =
            "chat-pending-" + UUID().uuidString
        messages.append(
            PaceChatMessage(
                id: pendingMessageId,
                role: .user,
                body: trimmedTranscript,
                createdAt: now,
                turnIdentifier: pendingMessageId,
                origin: .typed,
                deliveryState: .accepted,
                threadRootID: activeThreadRootID
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
                    && message.deliveryState == .accepted
                    && message.body == trimmedUserTranscript
            }) {
                let optimisticMessage = messages[optimisticMessageIndex]
                messages[optimisticMessageIndex] = PaceChatMessage(
                    id: optimisticMessage.id,
                    role: .user,
                    body: trimmedUserTranscript,
                    createdAt: recordedAt,
                    turnIdentifier: optimisticMessage.turnIdentifier, origin: optimisticMessage.origin,
                    deliveryState: .completed, threadRootID: optimisticMessage.threadRootID
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
                createdAt: recordedAt.addingTimeInterval(0.001),
                turnIdentifier: completedUserMessageIndex.flatMap { messages[$0].turnIdentifier },
                threadRootID: completedUserMessageIndex.flatMap { messages[$0].threadRootID }
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
        guard oldestFirstTurns.count > maximumDisplayedTurnCount else { return oldestFirstTurns }
        // Only unthreaded history is windowed. A saved conversation remains complete
        // even if the root is one half of an old paired document.
        let roots = Set(oldestFirstTurns.compactMap { $0.conversationEvent?.threadRootID })
        let anchorTurnIDs = Set(
            oldestFirstTurns.compactMap { turn -> String? in
                guard let event = turn.conversationEvent, roots.contains(event.eventID) else {
                    return nil
                }
                return event.turnID ?? event.eventID
            })
        var mainCount = 0
        let retained = oldestFirstTurns.reversed().filter { turn in
            if let event = turn.conversationEvent {
                if event.threadRootID != nil || roots.contains(event.eventID) { return true }
                if event.origin != .progress, event.deliveryState != .cancelled, event.deliveryState != .interrupted,
                    anchorTurnIDs.contains(event.turnID ?? event.eventID)
                {
                    return true
                }
            } else if roots.contains("\(turn.id):user") || roots.contains("\(turn.id):pace") {
                return true
            }
            guard mainCount < maximumDisplayedTurnCount else { return false }
            mainCount += 1
            return true
        }
        return Array(retained.reversed())
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
