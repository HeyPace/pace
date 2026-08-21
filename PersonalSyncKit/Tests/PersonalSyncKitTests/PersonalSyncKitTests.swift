import Foundation
import Testing

@testable import PersonalSyncKit

@Test("Outbox persists idempotent mutations and advances its cursor")
func outboxPersistence() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let file = directory.appending(path: "sync.json")
    let queue = try PersonalSyncQueue(fileURL: file)
    let first = try await queue.enqueue(["name": "Rahul"], idempotencyKey: "person-1-v1")
    let duplicate = try await queue.enqueue(["name": "Changed"], idempotencyKey: "person-1-v1")
    #expect(first.id == duplicate.id)

    try await queue.markAttempted(first.id)
    try await queue.accept([first.id], cursor: 4, synchronizedAt: Date(timeIntervalSince1970: 10))
    let restored = try PersonalSyncQueue(fileURL: file)
    let snapshot = await restored.current()
    #expect(snapshot.pendingMutations.isEmpty)
    #expect(snapshot.cursor == 4)
    #expect(snapshot.lastSynchronizedAt == Date(timeIntervalSince1970: 10))
}

@Test("Apple nonces hash deterministically")
func appleNonceHashing() {
    #expect(AppleNonce.make().count == 32)
    #expect(AppleNonce.digest("pace") == "19b87ac5ecb1afe2d7f3a59cbc81fe0f6c257624157e45c7ecd96bb0d0e76206")
}
