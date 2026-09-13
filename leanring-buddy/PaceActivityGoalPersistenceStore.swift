//
//  PaceActivityGoalPersistenceStore.swift
//  leanring-buddy
//
//  On-device persistence for the activity-goal-model's observations (see
//  openspec/changes/2026-09-13-add-activity-goal-model). Single atomic JSON
//  file at `~/Library/Application Support/Pace/activity-goal-model.json`,
//  mirroring `PaceMemoryStore.swift`/`PaceThreadMemoryStore.swift`: the
//  model types (`PaceActivityGoalModel.swift`) stay I/O-free, this store is
//  the only thing that touches disk, and writes are atomic
//  (`Data.write(.atomic)` does a temp-file + rename on the same volume) so a
//  crash mid-write can never leave a half-written file behind. A missing or
//  corrupt file loads as an empty list rather than throwing — persistence
//  must never block launch.
//
//  Privacy: the file stays on this Mac and is removed by `clear()` on an
//  explicit reset. Nothing here is ever uploaded — same on-device posture
//  as the rest of Pace.
//
//  `fileURL` is injectable (unlike `PaceMemoryStore`/`PaceThreadMemoryStore`,
//  which hardcode their path) so tests can point this at a temp directory
//  rather than touching the real Application Support folder.
//

import Foundation

@MainActor
final class PaceActivityGoalPersistenceStore {
    private let fileURL: URL?

    init(fileURL: URL? = PaceActivityGoalPersistenceStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("activity-goal-model.json", isDirectory: false)
    }

    /// Load the persisted observations, or an empty list when nothing has
    /// been saved yet / the file is unreadable. A decode failure returns
    /// `[]` (start fresh) rather than throwing.
    func load() -> [PaceActivityObservation] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PaceActivityObservation].self, from: data)) ?? []
    }

    /// Persist the current observation list. Best-effort: any failure is
    /// swallowed so a save never blocks or fails a caller. Creates the
    /// `Pace` support directory on first write.
    func save(_ observations: [PaceActivityObservation]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(observations) else { return }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Removes the persisted file entirely. No reset UI wires to this in
    /// Slice 1; provided now so a future Settings reset hook (mirroring
    /// episodic memory's reset) has a matching primitive to call.
    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
