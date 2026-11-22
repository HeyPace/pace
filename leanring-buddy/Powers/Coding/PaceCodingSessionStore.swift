import Foundation

nonisolated struct PaceCodingSessionStore: Sendable {
    private struct Catalog: Codable {
        let schemaVersion: Int
        let sessions: [PaceCodingSessionSnapshot]
    }
    let directory: URL
    private var primary: URL { directory.appendingPathComponent("sessions-v1.json") }
    private var recovery: URL { directory.appendingPathComponent("sessions-v1.recovery.json") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pace/Coding", isDirectory: true)) { self.directory = directory }

    func load() throws -> [PaceCodingSessionSnapshot] {
        guard FileManager.default.fileExists(atPath: primary.path) else {
            if FileManager.default.fileExists(atPath: recovery.path) { return try decode(Data(contentsOf: recovery)) }
            return []
        }
        do { return try decode(Data(contentsOf: primary)) }
        catch {
            guard FileManager.default.fileExists(atPath: recovery.path) else { throw PaceCodingError.persistence }
            return try decode(Data(contentsOf: recovery))
        }
    }

    private func decode(_ data: Data) throws -> [PaceCodingSessionSnapshot] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schemaVersion == 1, catalog.sessions.count <= 200,
              Set(catalog.sessions.map(\.id)).count == catalog.sessions.count,
              Set(catalog.sessions.map(\.threadID)).count == catalog.sessions.count,
              catalog.sessions.allSatisfy({ $0.directory.isFileURL && $0.directory.path.hasPrefix("/")
                  && !$0.threadID.rawValue.isEmpty && $0.threadID.rawValue.count <= 512 }) else {
            throw PaceCodingError.persistence
        }
        return catalog.sessions
    }

    func save(_ sessions: [PaceCodingSessionSnapshot]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: primary.path), let existing = try? Data(contentsOf: primary), (try? decode(existing)) != nil {
            try existing.write(to: recovery, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recovery.path)
        }
        let data = try JSONEncoder().encode(Catalog(schemaVersion: 1, sessions: sessions))
        try data.write(to: primary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primary.path)
    }
}
