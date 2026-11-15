//
//  PaceChatTranscriptModelTests.swift
//  leanring-buddyTests
//
//  Covers the pure mapping layer behind the premium chat panel
//  (docs/prds/premium-chat-panel.md, phase 1): conversation turns →
//  message row models, tool observations / action run records →
//  activity row models, the chronological thread merge, and the
//  empty-state decision. The suite is intentionally NOT @MainActor —
//  the whole point of `PaceChatTranscriptModel` is that it is pure and
//  isolation-free, so these tests exercising it off the main actor is
//  itself part of the contract.
//

import ApplicationServices
import Foundation
import Testing
@testable import Pace

struct PaceChatTranscriptModelTests {

    @Test func appTargetClarificationHasOneHumanReplyWhileTechnicalDetailsRemainAvailable() {
        let observation = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window",
            summary: "Application target remains ambiguous. Provider diagnostic: PID:111 PID:222",
            userFacingSummary: "Which Google Chrome window do you mean?",
            terminalReason: .ambiguousApplicationTarget)
        let record = PaceActionRunRecord.completed(observations: [observation])
        #expect(record.status == .failed)
        #expect(!record.showsInConversation)
        #expect(!record.detail.contains("PID:111"))
        #expect(record.diagnosticDetail?.contains("PID:111") == true)
        #expect(PaceActionExecutionObservation.formatForPlanner([observation]).contains("PID:222"))
        #expect(
            PaceActionExecutionObservation.formatForUserFeedback([observation])
                == "Which Google Chrome window do you mean?")
        #expect(PaceChatTranscriptModel.toolActivityRowModels(fromNewestFirstActionRunRecords: [record]).isEmpty)
    }

    @Test func recoveryDoesNotCreateAnInterimChipAndUncoveredFailuresStayVisible() {
        let recovery = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window",
            summary: "Read-only candidate inventory", userFacingSummary: "", terminalReason: .ambiguousInspectionTarget)
        let recoveryRecord = PaceActionRunRecord.completed(observations: [recovery])
        #expect(recoveryRecord.status == .skipped)
        #expect(recoveryRecord.title == "Choosing a window")
        #expect(!recoveryRecord.showsInConversation)
        #expect(PaceActionExecutionObservation.formatForUserFeedback([recovery]) == nil)

        let unrelatedFailure = PaceActionExecutionObservation(toolName: "notes", summary: "Failed to save the note.")
        let mixedRecord = PaceActionRunRecord.completed(observations: [unrelatedFailure, recovery])
        #expect(mixedRecord.status == .failed)
        #expect(mixedRecord.showsInConversation)
        let rows = PaceChatTranscriptModel.toolActivityRowModels(fromNewestFirstActionRunRecords: [
            mixedRecord, recoveryRecord,
        ])
        #expect(rows.count == 1)
        #expect(PaceActionRunRecord(status: .failed, title: "Failed", detail: "Other failure").showsInConversation)
    }

    @Test func completedEarlierActionsRemainVisibleWhenAWindowNeedsClarification() {
        let success = PaceActionExecutionObservation(toolName: "notes", summary: "Created the meeting note.")
        let clarification = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window",
            summary: "Multiple apps match, PID:111 PID:222", userFacingSummary: "Which Chrome window do you mean?",
            terminalReason: .ambiguousApplicationTarget)
        let record = PaceActionRunRecord.completed(observations: [success, clarification])
        #expect(record.showsInConversation)
        #expect(record.status == .completed)
        #expect(record.title == "Earlier actions completed")
        #expect(record.detail == "Created the meeting note.")
        #expect(record.targetResolution == .clarification("Which Chrome window do you mean?"))
        #expect(record.diagnosticDetail?.contains("PID:111") == true)
        let rows = PaceChatTranscriptModel.toolActivityRowModels(fromNewestFirstActionRunRecords: [record])
        #expect(rows.count == 1)
        #expect(rows.first?.resultSummaryLine == "Created the meeting note.")
    }

    @MainActor @Test func actualManagerKeepsTargetDiagnosticsOutOfTheHUD() {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let recovery = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window",
            summary: "RAW PRIVATE INVENTORY PID:111", userFacingSummary: "", terminalReason: .ambiguousInspectionTarget)
        manager.appendActionResult(.completed(observations: [recovery]))
        #expect(manager.currentTurnHUDState.status == .acting)
        #expect(manager.currentTurnHUDState.detail == "Finding the right window")
        #expect(manager.recentActionResults.first?.detail == "Checking which window you mean.")
        #expect(manager.recentActionResults.first?.diagnosticDetail?.contains("RAW PRIVATE INVENTORY") == true)

        let clarification = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window",
            summary: "RAW PRIVATE INVENTORY PID:222", userFacingSummary: "Which Chrome window do you mean?",
            terminalReason: .ambiguousApplicationTarget)
        manager.appendActionResult(.completed(observations: [clarification]))
        #expect(manager.currentTurnHUDState.status == .needsClarification)
        #expect(manager.currentTurnHUDState.title == "Which Chrome window do you mean?")
        #expect(manager.currentTurnHUDState.detail?.contains("PID:") != true)

        let stale = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window", summary: "PID:999 exited",
            userFacingSummary: "Chrome closed. Please reopen it so I can continue.",
            terminalReason: .staleApplicationTarget)
        manager.appendActionResult(.completed(observations: [stale]))
        #expect(manager.currentTurnHUDState.status == .failed)
        #expect(manager.currentTurnHUDState.detail == "Chrome closed. Please reopen it so I can continue.")
    }

    @MainActor @Test func earlierFailureIsNotMaskedByTargetDiscovery() {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let failure = PaceActionExecutionObservation(
            toolName: "notes", summary: "Failed internal note implementation",
            userFacingSummary: "I couldn’t save the note.")
        let discovery = PaceActionExecutionObservation(
            toolName: "mcp.peekaboo.window", summary: "PRIVATE PID:111",
            userFacingSummary: "", terminalReason: .recoverableInspectionFailure)
        manager.appendActionResult(.completed(observations: [failure, discovery]))
        #expect(manager.currentTurnHUDState.status == .failed)
        #expect(manager.currentTurnHUDState.detail == "I couldn’t save the note.")
        #expect(manager.recentActionResults.first?.showsInConversation == true)
    }

    @MainActor @Test func cancelledExecutionDoesNotAdvertiseUndo() async {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let previousMutationCount = manager.actionExecutor.mutationLog.count
        manager.actionExecutor.mutationLog.append(
            .axValue(
                element: AXUIElementCreateApplication(1), oldValue: "before", summary: "Actual edit"))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            manager.noteReversibleActionExecuted(sinceMutationCount: previousMutationCount)
        }
        await task.value
        #expect(manager.mostRecentReversibleActionAt == nil)
    }

    @Test func technicalDetailsAreBoundedWithoutChangingPlannerReceipts() {
        let observations = (0..<4).map { index in
            PaceActionExecutionObservation(
                toolName: "fixture-\(index)",
                summary: String(repeating: "é", count: 4_000)
                    + "\nTool structuredContent:\nPRIVATE STRUCTURE\nTool _meta:\nPRIVATE META",
                userFacingSummary: "I couldn’t finish that step.")
        }
        let record = PaceActionRunRecord.completed(observations: observations)
        #expect((record.diagnosticDetail?.utf8.count ?? 0) <= 8_000)
        #expect(record.diagnosticDetail?.contains("PRIVATE STRUCTURE") == false)
        #expect(record.diagnosticDetail?.contains("PRIVATE META") == false)
        #expect(record.diagnosticDetail?.contains("truncated") == true)
        #expect(PaceActionExecutionObservation.formatForPlanner(observations).contains("PRIVATE STRUCTURE"))
        let metadataOnly = PaceActionExecutionObservation(
            toolName: "fixture", summary: "A short error\nTool _meta:\nPRIVATE META",
            userFacingSummary: "I couldn’t finish that step.")
        #expect(
            PaceActionRunRecord.completed(observations: [metadataOnly]).diagnosticDetail == "fixture: A short error")
    }

    // MARK: - Fixtures

    private func makeChatMessage(
        id: String = "turn-1:user",
        role: PaceChatRole = .user,
        body: String = "open my calendar",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PaceChatMessage {
        PaceChatMessage(id: id, role: role, body: body, createdAt: createdAt)
    }

    private func makeActionRunRecord(
        status: PaceActionRunStatus,
        title: String = "Action complete",
        detail: String = "Opened Calendar.",
        createdAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> PaceActionRunRecord {
        PaceActionRunRecord(
            createdAt: createdAt,
            status: status,
            title: title,
            detail: detail
        )
    }

    @Test func quickPanelKeepsRecentQuestionsWithTheirAnswersAndHistoryRemainsSelectable() {
        let messages = (1...5).flatMap { turn in
            [
                makeChatMessage(id: "\(turn):user", body: "Question \(turn)"),
                makeChatMessage(id: "\(turn):pace", role: .pace, body: "Answer \(turn)"),
            ]
        }
        let recent = PaceChatTranscriptModel.quickPanelMessages(messages, selectedQuestionIdentifier: nil)
        #expect(recent.map(\.id) == ["3:user", "3:pace", "4:user", "4:pace", "5:user", "5:pace"])
        let selected = PaceChatTranscriptModel.quickPanelMessages(messages, selectedQuestionIdentifier: "2:user")
        #expect(selected.map(\.id) == ["2:user", "2:pace"])
        #expect(messages.count == 10)
        #expect(PaceChatTranscriptModel.quickPanelMessages(messages, selectedQuestionIdentifier: "missing") == recent)
    }

    @Test func quickPanelHandlesEmptyHistoryAndAnUnansweredQuestion() {
        #expect(PaceChatTranscriptModel.quickPanelMessages([], selectedQuestionIdentifier: nil).isEmpty)
        let pending = makeChatMessage(id: "pending:user", body: "Still thinking")
        #expect(
            PaceChatTranscriptModel.quickPanelMessages([pending], selectedQuestionIdentifier: pending.id) == [pending])
    }

    // MARK: - Conversation turns → message rows

    @Test func userChatMessageMapsToTrailingAccentTintedRow() {
        let userChatMessage = makeChatMessage(id: "turn-9:user", role: .user, body: "hello")
        let messageRowModel = PaceChatTranscriptModel.messageRowModel(fromChatMessage: userChatMessage)

        #expect(messageRowModel.id == "message-turn-9:user")
        #expect(messageRowModel.author == .user)
        #expect(messageRowModel.bodyText == "hello")
        #expect(messageRowModel.createdAt == userChatMessage.createdAt)
        #expect(messageRowModel.isAlignedToTrailingEdge)
        #expect(messageRowModel.usesAccentTintedBubble)
    }

    @Test func assistantChatMessageMapsToLeadingNeutralRow() {
        let assistantChatMessage = makeChatMessage(id: "turn-9:pace", role: .pace, body: "Hi there.")
        let messageRowModel = PaceChatTranscriptModel.messageRowModel(fromChatMessage: assistantChatMessage)

        #expect(messageRowModel.author == .assistant)
        #expect(!messageRowModel.isAlignedToTrailingEdge)
        #expect(!messageRowModel.usesAccentTintedBubble)
    }

    @Test func messageRowModelsPreserveInputOrder() {
        let chatMessages = [
            makeChatMessage(id: "a", role: .user, body: "first"),
            makeChatMessage(id: "b", role: .pace, body: "second"),
            makeChatMessage(id: "c", role: .user, body: "third")
        ]
        let messageRowModels = PaceChatTranscriptModel.messageRowModels(fromChatMessages: chatMessages)

        #expect(messageRowModels.map(\.bodyText) == ["first", "second", "third"])
        #expect(messageRowModels.map(\.id) == ["message-a", "message-b", "message-c"])
    }

    @Test func historicalVisualToolPayloadRendersAsNeutralRequestWithoutChangingSavedBody() {
        let body =
            #"{"tool":"generate_image","prompt":"Brushed titanium turbofan with blue leader lines","title":"Labeled turbofan engine cutaway","edit":false}"#
        let message = makeChatMessage(role: .pace, body: body)
        let row = PaceChatTranscriptModel.messageRowModel(fromChatMessage: message)
        #expect(row.bodyText == "Image request · Labeled turbofan engine cutaway")
        #expect(!row.bodyText.contains("prompt"))
        #expect(!row.bodyText.contains("ready"))
        #expect(message.body == body)
    }

    @Test func visualPayloadProjectionPreservesUserMessagesCodeExamplesAndOtherJSON() {
        let payload = #"{"tool":"generate_image","prompt":"A plane","title":"Plane","edit":false}"#
        #expect(PaceChatTranscriptModel.displayedBodyText(forChatMessage: makeChatMessage(body: payload)) == payload)
        for body in [
            "```json\n\(payload)\n```", #"{"engine":"turbofan","stages":4}"#,
            #"{"tool":"my_custom_example","title":"Example"}"#,
            #"{"tool":"generate_image","explanation":"This is a schema example"}"#, "Here is an example: \(payload)",
            #"{"tool":"generate_image","prompt":"unfinished""#,
        ] {
            #expect(
                PaceChatTranscriptModel.displayedBodyText(
                    forChatMessage: makeChatMessage(role: .pace, body: body)) == body)
        }
    }

    @Test func visualPayloadProjectionHasBoundedTitlesAndDoesNotClaimAnOutcome() throws {
        let title = "Fan\n[CLICK:20,20]"
        let data = try JSONSerialization.data(withJSONObject: ["tool": "show_diagram", "title": title, "nodes": []])
        let message = makeChatMessage(role: .pace, body: String(decoding: data, as: UTF8.self))
        #expect(PaceChatTranscriptModel.displayedBodyText(forChatMessage: message) == "Diagram request · Fan")
        let close = makeChatMessage(role: .pace, body: #"{"tool":"dismiss_diagram"}"#)
        #expect(PaceChatTranscriptModel.displayedBodyText(forChatMessage: close) == "Close diagram request")
    }

    // MARK: - Tool display name

    @Test func toolDisplayNameReplacesUnderscoresWithSpaces() {
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "open_url") == "open url")
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "create_calendar_event") == "create calendar event")
    }

    @Test func toolDisplayNameTrimsWhitespaceAndFallsBackWhenBlank() {
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "  click  ") == "click")
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "") == "tool")
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "   \n ") == "tool")
    }

    // MARK: - Observation failure detection

    @Test func observationSummaryFailureKeywordsAreDetectedCaseInsensitively() {
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("Click FAILED after 3 candidates"))
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("Could not open the app"))
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("Calendar access not granted"))
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("The note does not exist"))
    }

    @Test func observationSummaryWithoutFailureKeywordsIsNotAFailure() {
        #expect(!PaceChatTranscriptModel.observationSummaryIndicatesFailure("Opened Safari."))
        #expect(!PaceChatTranscriptModel.observationSummaryIndicatesFailure("Created reminder \"send invoice\"."))
        #expect(!PaceChatTranscriptModel.observationSummaryIndicatesFailure(""))
    }

    // MARK: - One-line summary

    @Test func oneLineSummaryTakesFirstNonEmptyLineTrimmed() {
        let multiLineSummary = "\n\n  Opened Calendar.  \nSecond line detail."
        #expect(PaceChatTranscriptModel.oneLineSummary(fromRawSummary: multiLineSummary) == "Opened Calendar.")
    }

    @Test func oneLineSummaryTruncatesPastTheCharacterCapWithEllipsis() {
        let longSummary = String(repeating: "a", count: 300)
        let oneLineSummary = PaceChatTranscriptModel.oneLineSummary(
            fromRawSummary: longSummary,
            maximumCharacterCount: 10
        )
        #expect(oneLineSummary == String(repeating: "a", count: 10) + "…")
    }

    @Test func oneLineSummaryOfBlankInputIsEmpty() {
        #expect(PaceChatTranscriptModel.oneLineSummary(fromRawSummary: "") == "")
        #expect(PaceChatTranscriptModel.oneLineSummary(fromRawSummary: "\n  \n") == "")
    }

    // MARK: - Observations → activity rows

    @Test func successfulObservationMapsToDoneActivityRow() {
        let observation = PaceActionExecutionObservation(
            toolName: "open_app",
            summary: "Opened Safari."
        )
        let observedAt = Date(timeIntervalSince1970: 3_000)
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromObservation: observation,
            turnIdentifier: "turn-42",
            observationIndex: 0,
            observedAt: observedAt
        )

        #expect(toolActivityRowModel.id == "observation-turn-42-0")
        #expect(toolActivityRowModel.toolDisplayName == "open app")
        #expect(toolActivityRowModel.resultState == .done)
        #expect(toolActivityRowModel.resultSummaryLine == "Opened Safari.")
        #expect(toolActivityRowModel.occurredAt == observedAt)
    }

    @Test func failedObservationMapsToFailedActivityRow() {
        let observation = PaceActionExecutionObservation(
            toolName: "click",
            summary: "Click failed after trying 3 of 3 candidates."
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromObservation: observation,
            turnIdentifier: "turn-42",
            observationIndex: 1,
            observedAt: Date(timeIntervalSince1970: 3_000)
        )

        #expect(toolActivityRowModel.resultState == .failed)
    }

    @Test func observationBatchGetsIndexStableIdsInInputOrder() {
        let observations = [
            PaceActionExecutionObservation(toolName: "open_app", summary: "Opened Safari."),
            PaceActionExecutionObservation(toolName: "open_url", summary: "Opened https://example.com.")
        ]
        let toolActivityRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromObservations: observations,
            turnIdentifier: "turn-7",
            observedAt: Date(timeIntervalSince1970: 4_000)
        )

        #expect(toolActivityRowModels.map(\.id) == ["observation-turn-7-0", "observation-turn-7-1"])
        #expect(toolActivityRowModels.map(\.toolDisplayName) == ["open app", "open url"])
    }

    // MARK: - Run-record status → result state

    @Test func runRecordStatusCollapsesToTheThreeStateContract() {
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .planned) == .running)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .completed) == .done)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .failed) == .failed)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .denied) == .failed)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .skipped) == .failed)
    }

    @Test func runRecordMapsTitleDetailAndTimestampIntoTheActivityRow() {
        let actionRunRecord = makeActionRunRecord(
            status: .completed,
            title: "Action complete",
            detail: "Opened Calendar.\nExtra detail line."
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: actionRunRecord
        )

        #expect(toolActivityRowModel.id == "record-\(actionRunRecord.id.uuidString)")
        #expect(toolActivityRowModel.toolDisplayName == "Action complete")
        #expect(toolActivityRowModel.resultState == .done)
        #expect(toolActivityRowModel.resultSummaryLine == "Opened Calendar.")
        #expect(toolActivityRowModel.occurredAt == actionRunRecord.createdAt)
    }

    @Test func runRecordWithBlankDetailFallsBackToTitleForTheSummaryLine() {
        let actionRunRecord = makeActionRunRecord(
            status: .denied,
            title: "Action denied",
            detail: "   "
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: actionRunRecord
        )

        #expect(toolActivityRowModel.resultState == .failed)
        #expect(toolActivityRowModel.resultSummaryLine == "Action denied")
    }

    // MARK: - Newest-first record list → oldest-first rows

    @Test func newestFirstRecordsComeBackOldestFirst() {
        let olderRecord = makeActionRunRecord(
            status: .completed,
            detail: "older",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newerRecord = makeActionRunRecord(
            status: .failed,
            detail: "newer",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        // CompanionManager.recentActionResults stores newest-first.
        let toolActivityRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromNewestFirstActionRunRecords: [newerRecord, olderRecord]
        )

        #expect(toolActivityRowModels.map(\.resultSummaryLine) == ["older", "newer"])
    }

    @Test func supersededPlannedRecordIsDroppedButNewestPlannedRecordSurvivesAsRunning() {
        let supersededPlannedRecord = makeActionRunRecord(
            status: .planned,
            title: "1 tool planned",
            detail: "superseded",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let completedRecord = makeActionRunRecord(
            status: .completed,
            detail: "completed twin",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let inFlightPlannedRecord = makeActionRunRecord(
            status: .planned,
            title: "1 tool planned",
            detail: "in flight",
            createdAt: Date(timeIntervalSince1970: 300)
        )
        // Newest-first, matching CompanionManager.appendActionResult.
        let toolActivityRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromNewestFirstActionRunRecords: [inFlightPlannedRecord, completedRecord, supersededPlannedRecord]
        )

        #expect(toolActivityRowModels.count == 2)
        #expect(toolActivityRowModels.map(\.resultSummaryLine) == ["completed twin", "in flight"])
        #expect(toolActivityRowModels.last?.resultState == .running)
    }

    // MARK: - Result-state rendering decisions

    @Test func resultStatesCarryTheirDisplayLabelsAndSymbols() {
        #expect(PaceChatToolActivityResultState.running.displayLabel == "Running")
        #expect(PaceChatToolActivityResultState.done.displayLabel == "Done")
        #expect(PaceChatToolActivityResultState.failed.displayLabel == "Failed")
        #expect(PaceChatToolActivityResultState.running.systemSymbolName == "circle.dotted")
        #expect(PaceChatToolActivityResultState.done.systemSymbolName == "checkmark.circle.fill")
        #expect(PaceChatToolActivityResultState.failed.systemSymbolName == "exclamationmark.triangle.fill")
    }

    // MARK: - Thread merge

    @Test func threadRowsMergeMessagesAndToolActivityChronologically() {
        let userMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(
                id: "t:user",
                role: .user,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        let assistantMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(
                id: "t:pace",
                role: .pace,
                body: "Done — Calendar is open.",
                createdAt: Date(timeIntervalSince1970: 300)
            )
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: makeActionRunRecord(
                status: .completed,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        let threadRows = PaceChatTranscriptModel.threadRows(
            messageRowModels: [userMessageRowModel, assistantMessageRowModel],
            toolActivityRowModels: [toolActivityRowModel]
        )

        #expect(threadRows.count == 3)
        #expect(threadRows[0].id == "thread-message-message-t:user")
        #expect(threadRows[1].id == "thread-tool-\(toolActivityRowModel.id)")
        #expect(threadRows[2].id == "thread-message-message-t:pace")
    }

    @Test func exactTimestampTiePutsTheMessageBeforeTheToolActivityRow() {
        let sharedTimestamp = Date(timeIntervalSince1970: 500)
        let messageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(id: "tie:pace", role: .pace, createdAt: sharedTimestamp)
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: makeActionRunRecord(status: .completed, createdAt: sharedTimestamp)
        )

        let threadRows = PaceChatTranscriptModel.threadRows(
            messageRowModels: [messageRowModel],
            toolActivityRowModels: [toolActivityRowModel]
        )

        #expect(threadRows.first?.id == "thread-message-message-tie:pace")
        #expect(threadRows.last?.id == "thread-tool-\(toolActivityRowModel.id)")
    }

    @Test func sameKindTimestampTiesKeepInputOrder() {
        let sharedTimestamp = Date(timeIntervalSince1970: 500)
        let firstMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(id: "first", role: .user, createdAt: sharedTimestamp)
        )
        let secondMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(id: "second", role: .pace, createdAt: sharedTimestamp)
        )

        let threadRows = PaceChatTranscriptModel.threadRows(
            messageRowModels: [firstMessageRowModel, secondMessageRowModel],
            toolActivityRowModels: []
        )

        #expect(threadRows.map(\.id) == [
            "thread-message-message-first",
            "thread-message-message-second"
        ])
    }

    @Test func threadRowOccurredAtMirrorsTheUnderlyingRowModel() {
        let messageTimestamp = Date(timeIntervalSince1970: 111)
        let toolTimestamp = Date(timeIntervalSince1970: 222)
        let messageThreadRow = PaceChatThreadRowModel.message(
            PaceChatTranscriptModel.messageRowModel(
                fromChatMessage: makeChatMessage(createdAt: messageTimestamp)
            )
        )
        let toolThreadRow = PaceChatThreadRowModel.toolActivity(
            PaceChatTranscriptModel.toolActivityRowModel(
                fromActionRunRecord: makeActionRunRecord(status: .completed, createdAt: toolTimestamp)
            )
        )

        #expect(messageThreadRow.occurredAt == messageTimestamp)
        #expect(toolThreadRow.occurredAt == toolTimestamp)
    }

    // MARK: - Empty-state decision

    @Test func emptyStateShowsOnlyWhenThereIsTrulyNothingToRender() {
        #expect(PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "",
            inFlightStreamedReplyText: ""
        ))
        #expect(PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "   \n",
            inFlightStreamedReplyText: "  "
        ))
    }

    @Test func emptyStateHidesWhenAnySurfaceHasContent() {
        #expect(!PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 1,
            liveSpeechDraftText: "",
            inFlightStreamedReplyText: ""
        ))
        #expect(!PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "open my cal",
            inFlightStreamedReplyText: ""
        ))
        #expect(!PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "",
            inFlightStreamedReplyText: "Sure — opening"
        ))
    }
}
