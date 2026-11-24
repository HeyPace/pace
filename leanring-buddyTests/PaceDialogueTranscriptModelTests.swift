import Foundation
import Testing

@testable import Pace

struct PaceDialogueTranscriptModelTests {
    private let timestamp = Date(timeIntervalSince1970: 1_000)

    private func activity(_ id: String, turnIdentifier: String?, state: PaceChatToolActivityResultState = .done)
        -> PaceChatToolActivityRowModel
    {
        var row = PaceChatToolActivityRowModel(
            id: id, toolDisplayName: "Action complete", resultState: state,
            resultSummaryLine: "Compact summary", occurredAt: timestamp)
        row.turnIdentifier = turnIdentifier
        row.fullDetail = "Full receipt for \(id)\nincluding the original detail."
        return row
    }

    @Test func earlierReplyTimestampCannotMoveTheOriginalMessageBelowItsReplies() {
        let original = PaceChatTranscriptMessageRowModel(
            id: "message-root", author: .assistant, bodyText: "Original", createdAt: timestamp)
        let reply = PaceChatTranscriptMessageRowModel(
            id: "message-reply", author: .user, bodyText: "Follow-up", createdAt: timestamp.addingTimeInterval(-1))
        let rows = PaceDialogueTranscriptModel.items(messages: [original, reply], activities: [], threadRootID: "root")
        #expect(rows == [.message(original), .message(reply)])
    }

    @Test func exactParentGroupsRoutineUpdatesAndPreservesEverySourceBody() {
        var progress = PaceChatTranscriptMessageRowModel(
            id: "progress", author: .assistant,
            bodyText: "Running Japanese Greeting.", createdAt: timestamp)
        progress.turnIdentifier = "turn-a"
        progress.origin = .progress
        var answer = PaceChatTranscriptMessageRowModel(
            id: "answer", author: .assistant,
            bodyText: "Hello.", createdAt: timestamp.addingTimeInterval(3))
        answer.turnIdentifier = "turn-a"
        let sourceMessages = [progress, answer]
        let sourceActivity = activity("receipt", turnIdentifier: "turn-a")
        let rows = PaceDialogueTranscriptModel.items(messages: sourceMessages, activities: [sourceActivity])
        #expect(rows.count == 2)
        guard case .message(let displayedAnswer) = rows[0], case .activity(let group) = rows[1] else {
            Issue.record("Expected the answer followed by its routine activity")
            return
        }
        #expect(displayedAnswer.bodyText == "Hello.")
        #expect(group.id == "turn-a" && group.entries.count == 2)
        #expect(group.entries.map(\.detail) == [progress.bodyText, sourceActivity.fullDetail!])
        #expect(sourceMessages == [progress, answer])
        #expect(!group.needsAttention)
    }

    @Test func unknownAndOtherParentsNeverAttachByMatchingTimestamps() {
        let rows = PaceDialogueTranscriptModel.items(
            messages: [],
            activities: [
                activity("a", turnIdentifier: "turn-a"), activity("b", turnIdentifier: "turn-b"),
                activity("unknown-one", turnIdentifier: nil), activity("unknown-two", turnIdentifier: nil),
            ])
        let groups = rows.compactMap { item -> PaceDialogueActivityGroup? in
            guard case .activity(let group) = item else { return nil }
            return group
        }
        #expect(groups.count == 4)
        #expect(Set(groups.map(\.id)).count == 4)
        #expect(groups.allSatisfy { $0.entries.count == 1 })
    }

    @Test func failuresAndCurrentApprovalRemainVisibleOutsideRoutineDisclosures() {
        let rows = PaceDialogueTranscriptModel.items(
            messages: [],
            activities: [
                activity("done", turnIdentifier: "same-turn"),
                activity("failed", turnIdentifier: "same-turn", state: .failed),
            ])
        let attention = rows.compactMap { item -> PaceDialogueActivityGroup? in
            guard case .activity(let group) = item, group.needsAttention else { return nil }
            return group
        }
        #expect(attention.count == 1)
        #expect(attention.first?.entries.first?.detail.contains("Full receipt for failed") == true)
        #expect(PaceDialogueTranscriptModel.showsCurrentTurnStatus(state: .awaitingApproval, hasFailure: false))
        #expect(PaceDialogueTranscriptModel.showsCurrentTurnStatus(state: .ready, hasFailure: true))
        #expect(PaceDialogueTranscriptModel.showsCurrentTurnStatus(state: .failed, hasFailure: false))
        #expect(!PaceDialogueTranscriptModel.showsCurrentTurnStatus(state: .ready, hasFailure: false))
    }

    @Test func onlySameParentCanSupersedeAPlannedRecord() {
        var planned = PaceActionRunRecord(status: .planned, title: "Planned", detail: "Two tools")
        planned.turnIdentifier = "turn-a"
        var unrelatedResult = PaceActionRunRecord(status: .completed, title: "Done", detail: "Another request")
        unrelatedResult.turnIdentifier = "turn-b"
        #expect(PaceDialogueTranscriptModel.activityRows(fromNewestFirst: [unrelatedResult, planned]).count == 2)
        unrelatedResult.turnIdentifier = "turn-a"
        #expect(PaceDialogueTranscriptModel.activityRows(fromNewestFirst: [unrelatedResult, planned]).count == 1)
        planned.turnIdentifier = nil
        #expect(PaceDialogueTranscriptModel.activityRows(fromNewestFirst: [unrelatedResult, planned]).count == 2)
    }

    @Test func japaneseVoiceWithoutCaptionIsNotLabeledAsEnglish() {
        let captionless = PaceChatMessage(
            id: "jp", role: .pace, body: "こんにちは。", createdAt: timestamp,
            speechRequest: .init(text: "こんにちは。", profile: .japaneseFemale))
        let row = PaceChatTranscriptModel.messageRowModel(fromChatMessage: captionless)
        #expect(!row.isEnglishSubtitle && row.bodyText == "こんにちは。")
        #expect(row.speechRequest?.profile == .japaneseFemale)
        var subtitled = captionless
        subtitled = PaceChatMessage(
            id: "en", role: .pace, body: "Hello.", createdAt: timestamp,
            speechRequest: .init(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello."))
        #expect(PaceChatTranscriptModel.messageRowModel(fromChatMessage: subtitled).isEnglishSubtitle)
        let mismatched = PaceChatMessage(
            id: "different", role: .pace, body: "Unrelated text", createdAt: timestamp,
            speechRequest: subtitled.speechRequest)
        #expect(!PaceChatTranscriptModel.messageRowModel(fromChatMessage: mismatched).isEnglishSubtitle)
    }

    @Test func latestAndEarlierWindowsShowOnlyTheirLinkedActivityAndBoundUnlinkedRecords() {
        let oldDate = Date(timeIntervalSince1970: 100)
        let currentDate = Date(timeIntervalSince1970: 200)
        var earlier = PaceChatTranscriptMessageRowModel(
            id: "old-question", author: .user, bodyText: "Earlier", createdAt: oldDate)
        earlier.turnIdentifier = "old-turn"
        var current = PaceChatTranscriptMessageRowModel(
            id: "new-question", author: .user, bodyText: "Current", createdAt: currentDate)
        current.turnIdentifier = "current-turn"
        func receipt(_ id: String, parent: String?, time: TimeInterval, state: PaceChatToolActivityResultState = .done)
            -> PaceChatToolActivityRowModel
        {
            var row = PaceChatToolActivityRowModel(
                id: id, toolDisplayName: id, resultState: state,
                resultSummaryLine: id, occurredAt: Date(timeIntervalSince1970: time))
            row.turnIdentifier = parent
            return row
        }
        let receipts = [
            receipt("old-linked", parent: "old-turn", time: 220, state: .failed),
            receipt("current-linked", parent: "current-turn", time: 150, state: .failed),
            receipt("old-unlinked", parent: nil, time: 150), receipt("current-unlinked", parent: nil, time: 210),
        ]
        let latest = PaceDialogueTranscriptModel.visibleActivities(receipts, messages: [current])
        #expect(latest.map(\.id) == ["current-linked", "current-unlinked"])
        let selectedEarlier = PaceDialogueTranscriptModel.visibleActivities(
            receipts, messages: [earlier], windowEnd: currentDate)
        #expect(selectedEarlier.map(\.id) == ["old-linked", "old-unlinked"])
        let expanded = PaceDialogueTranscriptModel.visibleActivities(receipts, messages: [earlier, current])
        #expect(expanded.count == 4 && receipts.count == 4)
    }

    @Test func committedEventIdentityRetiresStreamingMirrorWithoutTextGuessing() {
        let committed = PaceChatMessage(id: "assistant-event", role: .pace, body: "Hello.", createdAt: timestamp)
        #expect(
            !PaceDialogueTranscriptModel.shouldShowStreamingReply(
                text: "Hello.",
                assistantEventIdentifier: "assistant-event", committedMessages: [committed]))
        #expect(
            PaceDialogueTranscriptModel.shouldShowStreamingReply(
                text: "Hello.",
                assistantEventIdentifier: "next-event", committedMessages: [committed]))
        #expect(
            !PaceDialogueTranscriptModel.shouldShowStreamingReply(
                text: " ",
                assistantEventIdentifier: nil, committedMessages: []))
    }
}
