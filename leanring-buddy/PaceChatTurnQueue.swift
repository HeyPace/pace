//
//  PaceChatTurnQueue.swift
//  leanring-buddy
//

import Foundation

struct PaceQueuedChatTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let transcript: String
    let shouldMuteTTS: Bool
    let optimisticMessageIdentifier: String?

    init(
        id: UUID = UUID(),
        transcript: String,
        shouldMuteTTS: Bool,
        optimisticMessageIdentifier: String? = nil
    ) {
        self.id = id
        self.transcript = transcript
        self.shouldMuteTTS = shouldMuteTTS
        self.optimisticMessageIdentifier = optimisticMessageIdentifier
    }
}

/// In-memory FIFO for typed turns submitted while another turn owns the
/// planner, speech pipeline, conversation memory, and action executor.
struct PaceChatTurnQueue {
    private(set) var pendingTurns: [PaceQueuedChatTurn] = []

    var count: Int {
        pendingTurns.count
    }

    var isEmpty: Bool {
        pendingTurns.isEmpty
    }

    @discardableResult
    mutating func enqueue(_ queuedTurn: PaceQueuedChatTurn) -> Int {
        pendingTurns.append(queuedTurn)
        return pendingTurns.count
    }

    mutating func dequeue() -> PaceQueuedChatTurn? {
        guard !pendingTurns.isEmpty else { return nil }
        return pendingTurns.removeFirst()
    }

    mutating func removeAll() {
        pendingTurns.removeAll(keepingCapacity: true)
    }
}
