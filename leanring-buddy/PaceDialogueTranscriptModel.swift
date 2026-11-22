import Foundation

nonisolated struct PaceDialogueActivityEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let occurredAt: Date
    let resultState: PaceChatToolActivityResultState?
}

nonisolated struct PaceDialogueActivityGroup: Identifiable, Equatable {
    let id: String
    let entries: [PaceDialogueActivityEntry]
    let occurredAt: Date
    let needsAttention: Bool
}

nonisolated enum PaceDialogueTranscriptItem: Identifiable, Equatable {
    case message(PaceChatTranscriptMessageRowModel)
    case activity(PaceDialogueActivityGroup)

    var id: String {
        switch self {
        case .message(let message): return "dialogue-message-\(message.id)"
        case .activity(let activity): return "dialogue-activity-\(activity.id)"
        }
    }

    var occurredAt: Date {
        switch self {
        case .message(let message): return message.createdAt
        case .activity(let activity): return activity.occurredAt
        }
    }
}

nonisolated enum PaceDialogueTranscriptModel {
    static func activityRows(fromNewestFirst records: [PaceActionRunRecord]) -> [PaceChatToolActivityRowModel] {
        let rows: [PaceChatToolActivityRowModel] = records.enumerated().compactMap { index, record in
            guard record.showsInConversation else { return nil }
            if record.status == .planned, let turnIdentifier = record.turnIdentifier,
                records.prefix(index).contains(where: { $0.turnIdentifier == turnIdentifier && $0.status != .planned })
            {
                return nil
            }
            return PaceChatTranscriptModel.toolActivityRowModel(fromActionRunRecord: record)
        }
        return Array(rows.reversed())
    }

    static func visibleActivities(
        _ activities: [PaceChatToolActivityRowModel],
        messages: [PaceChatTranscriptMessageRowModel], windowEnd: Date? = nil
    ) -> [PaceChatToolActivityRowModel] {
        let visibleTurnIdentifiers = Set(messages.compactMap(\.turnIdentifier))
        guard let windowStart = messages.map(\.createdAt).min() else { return [] }
        return activities.filter { activity in
            if let turnIdentifier = activity.turnIdentifier { return visibleTurnIdentifiers.contains(turnIdentifier) }
            return activity.occurredAt >= windowStart && (windowEnd.map { activity.occurredAt < $0 } ?? true)
        }
    }

    static func showsCurrentTurnStatus(state: PaceSignalState, hasFailure: Bool) -> Bool {
        hasFailure
            || [.listening, .understanding, .awaitingApproval, .acting, .speaking, .blocked, .failed].contains(state)
    }

    static func items(
        messages: [PaceChatTranscriptMessageRowModel],
        activities: [PaceChatToolActivityRowModel]
    ) -> [PaceDialogueTranscriptItem] {
        var items: [PaceDialogueTranscriptItem] = []
        var groupedEntries: [String: [PaceDialogueActivityEntry]] = [:]
        var latestMessageDates: [String: Date] = [:]
        var groupOrder: [String] = []

        func appendRoutineEntry(_ entry: PaceDialogueActivityEntry, groupIdentifier: String) {
            if groupedEntries[groupIdentifier] == nil { groupOrder.append(groupIdentifier) }
            groupedEntries[groupIdentifier, default: []].append(entry)
        }

        for message in messages {
            if let turnIdentifier = message.turnIdentifier {
                latestMessageDates[turnIdentifier] = max(
                    latestMessageDates[turnIdentifier] ?? .distantPast, message.createdAt)
            }
            if message.author == .assistant, message.origin == .progress {
                let groupIdentifier = message.turnIdentifier ?? "unlinked-message-\(message.id)"
                appendRoutineEntry(
                    PaceDialogueActivityEntry(
                        id: message.id, title: "Progress update", detail: message.bodyText,
                        occurredAt: message.createdAt, resultState: nil), groupIdentifier: groupIdentifier)
            } else {
                items.append(.message(message))
            }
        }
        for activity in activities {
            let entry = PaceDialogueActivityEntry(
                id: activity.id, title: activity.toolDisplayName,
                detail: activity.fullDetail ?? activity.resultSummaryLine,
                occurredAt: activity.occurredAt, resultState: activity.resultState)
            if activity.resultState == .failed {
                items.append(
                    .activity(
                        PaceDialogueActivityGroup(
                            id: "attention-\(activity.id)", entries: [entry],
                            occurredAt: activity.occurredAt, needsAttention: true)))
            } else {
                let groupIdentifier = activity.turnIdentifier ?? "unlinked-activity-\(activity.id)"
                appendRoutineEntry(entry, groupIdentifier: groupIdentifier)
            }
        }
        for groupIdentifier in groupOrder {
            guard let entries = groupedEntries[groupIdentifier] else { continue }
            let orderedEntries = entries.enumerated().sorted {
                $0.element.occurredAt == $1.element.occurredAt
                    ? $0.offset < $1.offset : $0.element.occurredAt < $1.element.occurredAt
            }.map(\.element)
            let latestEntryDate = orderedEntries.last?.occurredAt ?? .distantPast
            // Only explicit turn identity can move activity beneath its answer.
            let occurredAt = max(latestEntryDate, latestMessageDates[groupIdentifier] ?? .distantPast)
            items.append(
                .activity(
                    PaceDialogueActivityGroup(
                        id: groupIdentifier, entries: orderedEntries, occurredAt: occurredAt, needsAttention: false)))
        }
        return items.enumerated().sorted {
            $0.element.occurredAt == $1.element.occurredAt
                ? $0.offset < $1.offset : $0.element.occurredAt < $1.element.occurredAt
        }.map(\.element)
    }

    static func shouldShowStreamingReply(
        text: String, assistantEventIdentifier: String?, committedMessages: [PaceChatMessage]
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let assistantEventIdentifier else { return true }
        return !committedMessages.contains { $0.role == .pace && $0.id == assistantEventIdentifier }
    }
}
