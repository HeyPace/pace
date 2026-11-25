//
//  PaceChatTurnQueue.swift
//  leanring-buddy
//

import Foundation

struct PaceQueuedChatTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let transcript: String
    let shouldMuteTTS: Bool
    let allowsPermissionPrompt: Bool
    let optimisticMessageIdentifier: String?
    let screenSuggestionContext: PaceScreenSuggestionRequestContext?
    let catalogSelection: PaceChatPowerCatalog.Selection?

    init(
        id: UUID = UUID(),
        transcript: String,
        shouldMuteTTS: Bool,
        allowsPermissionPrompt: Bool = false,
        optimisticMessageIdentifier: String? = nil,
        screenSuggestionContext: PaceScreenSuggestionRequestContext? = nil,
        catalogSelection: PaceChatPowerCatalog.Selection? = nil
    ) {
        self.id = id
        self.transcript = transcript
        self.shouldMuteTTS = shouldMuteTTS
        self.allowsPermissionPrompt = allowsPermissionPrompt
        self.optimisticMessageIdentifier = optimisticMessageIdentifier
        self.screenSuggestionContext = screenSuggestionContext
        self.catalogSelection = catalogSelection
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

    mutating func removeTurns(eventIdentifiers: Set<String>) -> [PaceQueuedChatTurn] {
        let removedTurns = pendingTurns.filter { turn in
            turn.optimisticMessageIdentifier.map(eventIdentifiers.contains) ?? false
        }
        pendingTurns.removeAll { turn in
            turn.optimisticMessageIdentifier.map(eventIdentifiers.contains) ?? false
        }
        return removedTurns
    }

    mutating func removeAll() {
        pendingTurns.removeAll(keepingCapacity: true)
    }
}
