import Foundation
import Testing
@testable import Pace

@Suite("Chat turn queue")
struct PaceChatTurnQueueTests {
    @Test("Queued turns drain in submission order")
    func queuedTurnsDrainInSubmissionOrder() {
        var queue = PaceChatTurnQueue()
        let firstTurn = PaceQueuedChatTurn(transcript: "first", shouldMuteTTS: false)
        let secondTurn = PaceQueuedChatTurn(transcript: "second", shouldMuteTTS: true)

        #expect(queue.enqueue(firstTurn) == 1)
        #expect(queue.enqueue(secondTurn) == 2)
        #expect(queue.dequeue() == firstTurn)
        #expect(queue.dequeue() == secondTurn)
        #expect(queue.dequeue() == nil)
    }

    @Test("Each queued turn retains its own mute preference")
    func queuedTurnsRetainMutePreference() {
        var queue = PaceChatTurnQueue()
        queue.enqueue(PaceQueuedChatTurn(transcript: "spoken", shouldMuteTTS: false))
        queue.enqueue(PaceQueuedChatTurn(transcript: "silent", shouldMuteTTS: true))

        #expect(queue.dequeue()?.shouldMuteTTS == false)
        #expect(queue.dequeue()?.shouldMuteTTS == true)
    }

    @Test("Clearing removes only pending turns")
    func clearingRemovesPendingTurns() {
        var queue = PaceChatTurnQueue()
        queue.enqueue(PaceQueuedChatTurn(transcript: "first", shouldMuteTTS: false))
        queue.enqueue(PaceQueuedChatTurn(transcript: "second", shouldMuteTTS: false))

        queue.removeAll()

        #expect(queue.isEmpty)
        #expect(queue.count == 0)
    }
}
