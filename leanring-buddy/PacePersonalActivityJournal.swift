import Foundation

protocol PacePersonalActivityPersisting: Sendable {
    func load() -> [PaceActivityRecord]
    func save(_ records: [PaceActivityRecord])
}

struct PacePersonalActivityJournal: PacePersonalActivityPersisting {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.fileURL = applicationSupportURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("personal-control-plane-activity.json")
    }

    func load() -> [PaceActivityRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([PaceActivityRecord].self, from: data)) ?? []
    }

    func save(_ records: [PaceActivityRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Array(records.prefix(250))).write(to: fileURL, options: .atomic)
        } catch {
            // The activity UI keeps the in-memory record and visibly reports
            // connector outcomes. Persistence failure must never repeat a write.
        }
    }
}
