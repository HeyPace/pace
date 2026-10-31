//
//  PaceChatSessionTests.swift
//  leanring-buddyTests
//
//  Covers the chat-session backing store that powers the in-window
//  Conversations tab. Persistence still lives in the existing
//  `paceHistory` retrieval index — this suite exercises load/submit/
//  filter behaviours against a fake history source and a fake submitter
//  so we don't need a live `CompanionManager`.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceChatSessionTests {

    // MARK: - Test doubles

    final class FakeHistorySource: PaceChatHistorySource {
        var stubbedTurns: [PaceChatHistoryTurn] = []
        var loadCallCount: Int = 0

        func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
            loadCallCount += 1
            return stubbedTurns
        }
    }

    final class FakeTranscriptSubmitter: PaceChatTranscriptSubmitting {
        var submittedTranscripts: [String] = []
        var optimisticMessageIdentifiers: [String] = []

        func submitChatTranscript(
            _ transcript: String,
            optimisticMessageIdentifier: String
        ) {
            submittedTranscripts.append(transcript)
            optimisticMessageIdentifiers.append(optimisticMessageIdentifier)
        }
    }

    private func makeSession(
        historySource: FakeHistorySource,
        submitter: FakeTranscriptSubmitter
    ) -> PaceChatSession {
        return PaceChatSession(
            historySource: historySource,
            transcriptSubmitter: submitter
        )
    }

    // MARK: - loadHistory roundtrip

    private func screenSuggestionEvent(identifier: String = "screen-suggestion-offer", createdAt: Date) -> ConversationEvent {
        ConversationEvent(eventID: identifier, role: .pace, origin: .proactive,
            text: "Want to understand why climbing grades do not map directly to raw strength?",
            createdAt: createdAt)
    }

    private func historyTurn(for event: ConversationEvent) -> PaceChatHistoryTurn {
        PaceChatHistoryTurn(id: event.eventID, userText: "", paceText: "", recordedAt: event.createdAt, conversationEvent: event)
    }

    private func unreadPreferences() -> UserDefaults {
        UserDefaults(suiteName: "PaceChatSessionUnreadTests." + UUID().uuidString)!
    }

    @Test func watchOfferRestoresUnreadFromTypedHistory() {
        let historySource = FakeHistorySource()
        let offer = screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100))
        historySource.stubbedTurns = [historyTurn(for: offer)]
        let session = PaceChatSession(historySource: historySource, transcriptSubmitter: FakeTranscriptSubmitter(),
            preferences: unreadPreferences())
        session.loadHistoryWithoutBlockingInterface()
        #expect(session.hasUnreadScreenSuggestion)
        #expect(session.latestScreenSuggestionEvent == offer)
        #expect(session.userFacingMessages.map(\.body) == [offer.text])
    }

    @Test func acknowledgedOfferStaysReadAfterRelaunchAndReload() {
        let preferences = unreadPreferences()
        let historySource = FakeHistorySource()
        let offer = screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100))
        historySource.stubbedTurns = [historyTurn(for: offer)]
        let session = PaceChatSession(historySource: historySource, transcriptSubmitter: FakeTranscriptSubmitter(),
            preferences: preferences, now: { Date(timeIntervalSince1970: 200) })
        session.loadHistory()
        session.conversationPanelDidShow(.interactive)
        let relaunchedSession = PaceChatSession(historySource: historySource, transcriptSubmitter: FakeTranscriptSubmitter(),
            preferences: preferences)
        relaunchedSession.loadHistory()
        #expect(!relaunchedSession.hasUnreadScreenSuggestion)
        relaunchedSession.loadHistory()
        #expect(!relaunchedSession.hasUnreadScreenSuggestion)
        #expect(preferences.string(forKey: PaceUserPreferenceKey.lastAcknowledgedScreenSuggestionEventIdentifier.rawValue) == offer.eventID)
    }

    @Test func newerOfferBecomesUnreadAfterAcknowledgement() {
        let session = PaceChatSession(historySource: FakeHistorySource(), transcriptSubmitter: FakeTranscriptSubmitter(),
            preferences: unreadPreferences(), now: { Date(timeIntervalSince1970: 200) })
        session.upsertConversationEvent(screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100)))
        session.conversationPanelDidShow(.interactive)
        #expect(!session.hasUnreadScreenSuggestion)
        let newerOffer = screenSuggestionEvent(identifier: "screen-suggestion-newer", createdAt: Date(timeIntervalSince1970: 201))
        session.upsertConversationEvent(newerOffer)
        #expect(session.hasUnreadScreenSuggestion)
        #expect(session.latestScreenSuggestionEvent == newerOffer)
    }

    @Test func duplicateOfferAndUnrelatedNarrationDoNotChangeUnread() {
        let session = PaceChatSession(historySource: FakeHistorySource(), transcriptSubmitter: FakeTranscriptSubmitter(),
            now: { Date(timeIntervalSince1970: 200) })
        let offer = screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100))
        session.upsertConversationEvent(offer)
        session.conversationPanelDidShow(.interactive)
        session.upsertConversationEvent(offer)
        for event in [
            ConversationEvent(role: .pace, origin: .proactive, text: "A calendar nudge."),
            ConversationEvent(eventID: "screen-suggestion-progress", role: .pace, origin: .progress, text: "Working."),
            ConversationEvent(eventID: "screen-suggestion-user", role: .user, origin: .proactive, text: "User text."),
            ConversationEvent(eventID: "screen-suggestion-cancelled", role: .pace, origin: .proactive,
                text: "A cancelled offer.", deliveryState: .cancelled)
        ] { session.upsertConversationEvent(event) }
        #expect(!session.hasUnreadScreenSuggestion)
        #expect(session.latestScreenSuggestionEvent == offer)
    }

    @Test func distinctOfferAtAcknowledgementTimestampRemainsUnread() {
        let createdAt = Date(timeIntervalSince1970: 200)
        let session = PaceChatSession(historySource: FakeHistorySource(), transcriptSubmitter: FakeTranscriptSubmitter(),
            now: { createdAt })
        session.upsertConversationEvent(screenSuggestionEvent(createdAt: createdAt))
        session.conversationPanelDidShow(.interactive)
        session.upsertConversationEvent(screenSuggestionEvent(identifier: "screen-suggestion-distinct", createdAt: createdAt))
        #expect(session.hasUnreadScreenSuggestion)
    }

    @Test func interactiveOpenDuringHistoryLoadAcknowledgesOnlyExistingOffers() {
        let preferences = unreadPreferences()
        let historySource = FakeHistorySource()
        let oldOffer = screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100))
        let session = PaceChatSession(historySource: historySource, transcriptSubmitter: FakeTranscriptSubmitter(),
            preferences: preferences, now: { Date(timeIntervalSince1970: 200) })
        session.conversationPanelDidShow(.interactive)
        session.applyLoadedHistory([historyTurn(for: oldOffer)])
        #expect(!session.hasUnreadScreenSuggestion)
        let newOffer = screenSuggestionEvent(identifier: "screen-suggestion-after-open", createdAt: Date(timeIntervalSince1970: 201))
        session.upsertConversationEvent(newOffer)
        session.applyLoadedHistory([historyTurn(for: oldOffer)])
        #expect(session.hasUnreadScreenSuggestion)
        #expect(session.latestScreenSuggestionEvent == newOffer)
        #expect(session.userFacingMessages.last?.body == newOffer.text)
    }

    @Test func liveScreenOfferUpdateWinsOverStaleHistoryMetadata() {
        let session = PaceChatSession(historySource: FakeHistorySource(), transcriptSubmitter: FakeTranscriptSubmitter())
        let oldOffer = screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100))
        var updatedOffer = oldOffer
        updatedOffer.text = "Want an explanation of climbing grades and raw strength?"
        session.upsertConversationEvent(updatedOffer)
        session.applyLoadedHistory([historyTurn(for: oldOffer)])
        #expect(session.latestScreenSuggestionEvent == updatedOffer)
        #expect(session.userFacingMessages.map(\.body) == [updatedOffer.text])
    }

    @Test func previewKeepsScreenOfferUnreadAndInteractiveOpenAcknowledges() {
        let preferences = unreadPreferences()
        let session = PaceChatSession(historySource: FakeHistorySource(), transcriptSubmitter: FakeTranscriptSubmitter(),
            preferences: preferences, now: { Date(timeIntervalSince1970: 200) })
        session.upsertConversationEvent(screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100)))
        session.conversationPanelDidShow(.preview)
        #expect(session.hasUnreadScreenSuggestion)
        #expect(preferences.object(forKey: PaceUserPreferenceKey.screenSuggestionReadThroughDate.rawValue) == nil)
        session.conversationPanelDidShow(.interactive)
        #expect(!session.hasUnreadScreenSuggestion)
    }

    @Test func nonblankSubmissionAcknowledgesSuggestion() {
        let submitter = FakeTranscriptSubmitter()
        let session = PaceChatSession(historySource: FakeHistorySource(), transcriptSubmitter: submitter,
            now: { Date(timeIntervalSince1970: 200) })
        session.upsertConversationEvent(screenSuggestionEvent(createdAt: Date(timeIntervalSince1970: 100)))
        session.draftMessageText = "Maybe explain it"
        session.submitUserMessage("   ")
        #expect(session.hasUnreadScreenSuggestion)
        session.submitUserMessage("Explain it")
        #expect(!session.hasUnreadScreenSuggestion)
        #expect(submitter.submittedTranscripts == ["Explain it"])
    }

    @Test func loadHistorySeedsTranscriptInOldestFirstOrder() async throws {
        let historySource = FakeHistorySource()
        let earlierDate = Date(timeIntervalSince1970: 1_000_000)
        let laterDate = Date(timeIntervalSince1970: 1_000_500)
        historySource.stubbedTurns = [
            PaceChatHistoryTurn(
                id: "turn-1",
                userText: "what's the time",
                paceText: "it's 9 pm",
                recordedAt: earlierDate
            ),
            PaceChatHistoryTurn(
                id: "turn-2",
                userText: "thanks",
                paceText: "you're welcome",
                recordedAt: laterDate
            ),
        ]
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(historySource: historySource, submitter: submitter)

        session.loadHistory()

        #expect(historySource.loadCallCount == 1)
        #expect(session.hasLoadedHistory == true)
        // Each turn expands into TWO messages (user + pace).
        #expect(session.messages.count == 4)
        #expect(session.messages.map(\.role) == [.user, .pace, .user, .pace])
        #expect(
            session.messages.map(\.body) == [
                "what's the time",
                "it's 9 pm",
                "thanks",
                "you're welcome",
            ])
    }

    @Test func loadHistoryDropsEmptyHalves() async throws {
        let historySource = FakeHistorySource()
        historySource.stubbedTurns = [
            PaceChatHistoryTurn(
                id: "session-end-marker",
                userText: "session ended (cause: idleTimeout)",
                paceText: "",
                recordedAt: Date()
            )
        ]
        let session = makeSession(
            historySource: historySource,
            submitter: FakeTranscriptSubmitter()
        )

        session.loadHistory()

        #expect(session.messages.count == 1)
        #expect(session.messages.first?.role == .user)
    }

    @Test func loadHistoryIsIdempotentReplacingPriorTranscript() async throws {
        let historySource = FakeHistorySource()
        historySource.stubbedTurns = [
            PaceChatHistoryTurn(
                id: "turn-1",
                userText: "hi",
                paceText: "hello",
                recordedAt: Date()
            )
        ]
        let session = makeSession(
            historySource: historySource,
            submitter: FakeTranscriptSubmitter()
        )

        session.loadHistory()
        let firstLoadCount = session.messages.count
        // Re-loading replaces the transcript wholesale so newly-arrived
        // voice turns show up when the window is re-opened.
        historySource.stubbedTurns.append(
            PaceChatHistoryTurn(
                id: "turn-2",
                userText: "another",
                paceText: "reply",
                recordedAt: Date()
            )
        )
        session.loadHistory()

        #expect(firstLoadCount == 2)
        #expect(session.messages.count == 4)
    }

    // MARK: - submitUserMessage

    @Test func submitUserMessageAppendsOptimisticRowAndForwardsToSubmitter() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )

        session.submitUserMessage("  what's the time  ")

        #expect(submitter.submittedTranscripts == ["what's the time"])
        #expect(submitter.optimisticMessageIdentifiers.count == 1)
        #expect(submitter.optimisticMessageIdentifiers.first?.hasPrefix("chat-pending-") == true)
        #expect(session.messages.count == 1)
        #expect(session.messages.first?.role == .user)
        #expect(session.messages.first?.body == "what's the time")
    }

    @Test func submitUserMessageDropsBlankInputs() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )

        session.submitUserMessage("   ")
        session.submitUserMessage("")

        #expect(submitter.submittedTranscripts.isEmpty)
        #expect(session.messages.isEmpty)
    }

    // MARK: - appendCompletedTurn dedupes the optimistic row

    @Test func appendCompletedTurnDoesNotDuplicateOptimisticUserRow() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )

        session.submitUserMessage("what's the time")
        session.appendCompletedTurn(
            userTranscript: "what's the time",
            assistantResponse: "it's 9 pm"
        )

        #expect(session.messages.count == 2)
        #expect(session.messages.first?.role == .user)
        #expect(session.messages.first?.body == "what's the time")
        #expect(session.messages.last?.role == .pace)
        #expect(session.messages.last?.body == "it's 9 pm")
    }

    @Test func appendCompletedTurnAppendsBothRowsWhenComingFromVoice() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        // Voice turn — submitUserMessage was never called, so both rows
        // should be appended fresh.
        session.appendCompletedTurn(
            userTranscript: "hello",
            assistantResponse: "hi there"
        )

        #expect(session.messages.map(\.role) == [.user, .pace])
        #expect(session.messages.map(\.body) == ["hello", "hi there"])
    }

    @Test func queuedOptimisticRowsReceiveRepliesInTurnOrder() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.submitUserMessage("first")
        session.submitUserMessage("second")
        session.submitUserMessage("third")

        session.appendCompletedTurn(userTranscript: "first", assistantResponse: "one")
        session.appendCompletedTurn(userTranscript: "second", assistantResponse: "two")

        #expect(session.messages.map(\.role) == [.user, .pace, .user, .pace, .user])
        #expect(session.messages.map(\.body) == ["first", "one", "second", "two", "third"])
    }

    @Test func duplicateQueuedTranscriptsConsumeOneOptimisticRowPerCompletion() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.submitUserMessage("repeat")
        session.submitUserMessage("repeat")

        session.appendCompletedTurn(userTranscript: "repeat", assistantResponse: "first reply")
        session.appendCompletedTurn(userTranscript: "repeat", assistantResponse: "second reply")

        #expect(
            session.messages.map(\.body) == [
                "repeat", "first reply", "repeat", "second reply",
            ])
    }

    @Test func clearingQueuedIdentifierPreservesOtherPendingRows() async throws {
        let submitter = FakeTranscriptSubmitter()
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: submitter
        )
        session.submitUserMessage("active")
        session.submitUserMessage("queued")

        session.removePendingUserMessages(
            withIdentifiers: [submitter.optimisticMessageIdentifiers[1]]
        )

        #expect(session.messages.map(\.body) == ["active"])
    }

    // MARK: - Mute toggle

    @Test func muteFlagStartsFalseAndPersistsForSessionInstance() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )

        #expect(session.isChatTTSMuted == false)
        session.isChatTTSMuted = true
        #expect(session.isChatTTSMuted == true)
        // Toggling is independent of history loading or message submission.
        session.submitUserMessage("anything")
        #expect(session.isChatTTSMuted == true)
        session.loadHistory()
        #expect(session.isChatTTSMuted == true)
    }

    @Test func unfinishedDraftPersistsAcrossHistoryRefresh() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )

        session.draftMessageText = "finish this later"
        session.loadHistory()

        #expect(session.draftMessageText == "finish this later")
    }

    // MARK: - Filtering

    @Test func filteredMessagesReturnsAllWhenQueryIsBlank() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.appendCompletedTurn(userTranscript: "hello", assistantResponse: "hi")
        session.appendCompletedTurn(userTranscript: "what time", assistantResponse: "9 pm")

        #expect(session.filteredMessages(matching: "").count == 4)
        #expect(session.filteredMessages(matching: "   ").count == 4)
    }

    @Test func filteredMessagesIsCaseInsensitiveSubstringMatch() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.appendCompletedTurn(userTranscript: "what's the launch date", assistantResponse: "Friday")
        session.appendCompletedTurn(userTranscript: "dinner ideas?", assistantResponse: "pasta or pizza")

        let launchMatches = session.filteredMessages(matching: "LAUNCH")
        #expect(launchMatches.count == 1)
        #expect(launchMatches.first?.body.contains("launch") == true)

        let pizzaMatches = session.filteredMessages(matching: "pizza")
        #expect(pizzaMatches.count == 1)
        #expect(pizzaMatches.first?.role == .pace)
    }

    @Test func internalSystemTurnsStayOutOfUserFacingConversationSurfaces() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.appendCompletedTurn(
            userTranscript: "(system) proactive nudge",
            assistantResponse: "Take a short break"
        )
        session.appendCompletedTurn(
            userTranscript: "session ended (cause: idleTimeout)",
            assistantResponse: "session thread-example ended"
        )
        session.appendCompletedTurn(
            userTranscript: "(agent step 2)",
            assistantResponse: "Intermediate tool result"
        )
        session.appendCompletedTurn(
            userTranscript: "Show my schedule",
            assistantResponse: "You have two meetings"
        )

        #expect(session.messages.count == 8)
        #expect(
            session.userFacingMessages.map(\.body) == [
                "Show my schedule",
                "You have two meetings",
            ])
        #expect(session.filteredMessages(matching: "nudge").isEmpty)
    }

    // MARK: - Local history reader text parsing

    @Test func finalAgentAnswerRemainsVisibleWithoutAnotherUserMessage() async throws {
        let session = makeSession(
            historySource: FakeHistorySource(),
            submitter: FakeTranscriptSubmitter()
        )
        session.appendCompletedTurn(userTranscript: "Open a test document", assistantResponse: "")
        session.appendCompletedTurn(userTranscript: "(agent step 2)", assistantResponse: "Intermediate tool result")
        session.appendCompletedTurn(userTranscript: "", assistantResponse: "Created the test document.")

        #expect(session.userFacingMessages.map(\.body) == ["Open a test document", "Created the test document."])
        let restored = PaceLocalChatHistoryReader.splitUserAndPace("User: \nPace: Created the test document.")
        #expect(restored.userText.isEmpty)
        #expect(restored.paceText == "Created the test document.")
    }

    @Test func localHistoryReaderSplitsUserAndPaceFromDocumentText() async throws {
        let (userText, paceText) = PaceLocalChatHistoryReader.splitUserAndPace(
            "User: hi there\nPace: hi back"
        )
        #expect(userText == "hi there")
        #expect(paceText == "hi back")
    }

    @Test func localHistoryReaderHandlesMissingPaceMarker() async throws {
        let (userText, paceText) = PaceLocalChatHistoryReader.splitUserAndPace(
            "User: only the user said something"
        )
        #expect(userText == "only the user said something")
        #expect(paceText == "")
    }
}
