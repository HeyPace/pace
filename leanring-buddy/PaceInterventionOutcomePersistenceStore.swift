//
//  PaceInterventionOutcomePersistenceStore.swift
//  leanring-buddy
//
//  On-device persistence for the outcome-feedback-telemetry proposal's
//  outcome records (see
//  openspec/changes/2026-09-13-add-outcome-feedback-telemetry). Single
//  atomic JSON file at
//  `~/Library/Application Support/Pace/intervention-outcomes.json`,
//  mirroring `PaceActivityGoalPersistenceStore.swift`/`PaceMemoryStore.swift`:
//  the model types (`PaceInterventionOutcomeModel.swift`) stay I/O-free,
//  this store is the only thing that touches disk, and writes are atomic
//  so a crash mid-write can never leave a half-written file behind. A
//  missing or corrupt file loads as an empty list rather than throwing —
//  persistence must never block launch.
//
//  Privacy: the file stays on this Mac and is removed by `clear()` on an
//  explicit reset. Nothing here is ever uploaded.
//
//  `fileURL` is injectable so tests can point this at a temp directory
//  rather than touching the real Application Support folder.
//

import Foundation

@MainActor
final class PaceInterventionOutcomePersistenceStore {
    private let fileURL: URL?

    init(fileURL: URL? = PaceInterventionOutcomePersistenceStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("intervention-outcomes.json", isDirectory: false)
    }

    /// Load the persisted records, or an empty list when nothing has been
    /// saved yet / the file is unreadable. A decode failure returns `[]`
    /// (start fresh) rather than throwing.
    func load() -> [PaceInterventionOutcomeRecord] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PaceInterventionOutcomeRecord].self, from: data)) ?? []
    }

    /// Persist the current record list. Best-effort: any failure is
    /// swallowed so a save never blocks or fails a caller. Creates the
    /// `Pace` support directory on first write.
    func save(_ records: [PaceInterventionOutcomeRecord]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes the persisted file entirely. No reset UI wires to this yet;
    /// provided now so a future Settings reset hook has a matching
    /// primitive to call.
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
