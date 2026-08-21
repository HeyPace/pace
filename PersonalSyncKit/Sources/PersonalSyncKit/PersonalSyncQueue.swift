import Foundation

public actor PersonalSyncQueue {
    public let fileURL: URL
    private var snapshot: PersonalSyncSnapshot

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            snapshot = try Self.decoder.decode(PersonalSyncSnapshot.self, from: data)
        } else {
            snapshot = PersonalSyncSnapshot()
        }
    }

    public func current() -> PersonalSyncSnapshot { snapshot }

    @discardableResult
    public func enqueue<Body: Encodable & Sendable>(
        _ body: Body,
        idempotencyKey: String
    ) throws -> PersonalSyncMutation {
        if let existing = snapshot.pendingMutations.first(where: {
            $0.idempotencyKey == idempotencyKey
        }) {
            return existing
        }
        let mutation = PersonalSyncMutation(
            idempotencyKey: idempotencyKey,
            body: try Self.encoder.encode(body)
        )
        snapshot.pendingMutations.append(mutation)
        try persist()
        return mutation
    }

    public func markAttempted(_ mutationID: UUID) throws {
        guard let index = snapshot.pendingMutations.firstIndex(where: { $0.id == mutationID }) else {
            return
        }
        snapshot.pendingMutations[index].attemptCount += 1
        try persist()
    }

    public func accept(_ mutationIDs: Set<UUID>, cursor: Int, synchronizedAt: Date) throws {
        snapshot.pendingMutations.removeAll { mutationIDs.contains($0.id) }
        snapshot.cursor = max(snapshot.cursor, cursor)
        snapshot.lastSynchronizedAt = synchronizedAt
        try persist()
    }

    public func recordConflict(
        mutationID: UUID,
        message: String,
        cursor: Int? = nil
    ) throws {
        snapshot.pendingMutations.removeAll { $0.id == mutationID }
        snapshot.conflicts.append(PersonalSyncConflict(mutationID: mutationID, message: message))
        if let cursor { snapshot.cursor = max(snapshot.cursor, cursor) }
        try persist()
    }

    public func advance(cursor: Int, synchronizedAt: Date) throws {
        snapshot.cursor = max(snapshot.cursor, cursor)
        snapshot.lastSynchronizedAt = synchronizedAt
        try persist()
    }

    public func clearResolvedConflicts() throws {
        snapshot.conflicts = []
        try persist()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
