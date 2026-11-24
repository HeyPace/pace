//
//  PaceSkillRunJournal.swift
//  leanring-buddy
//
//  Local-only, fire-and-forget success-rate telemetry for taught-skill
//  runs. One JSON object per line in Application Support so we can study
//  which workflows complete or fail. Usage reads the retained generations.
//
//  Why a JSONL log and NOT a PaceRetrievalSource journal: this is pure
//  telemetry, not recall material. A retrieval-source journal
//  (PaceResearchJournal-style) would need a new PaceRetrievalSource
//  case, store wiring, rehydration, dedup, day-bucketing, and a browse
//  UI — none of which telemetry needs. Mirroring PaceAPIAuditLog's
//  append-only JSONL pattern is far less code and matches an already-
//  proven, well-tested sibling. The file never leaves the Mac.
//

import Foundation

nonisolated struct PaceSkillRunRecord: Codable, Equatable {
    /// When the skill run was recorded (start OR finish — see `phase`).
    let at: Date
    /// Stable id shared by the "started" and the terminal record of one
    /// run, so the two lines can be paired when the log is analyzed.
    let runId: String
    /// Slug of the skill that was run.
    let skillSlug: String
    /// "started" | "completed" | "failed" — the lifecycle point this
    /// line captures. Kept as a string (not an enum) so an older or
    /// newer generation of the log can be decoded without a migration.
    let phase: String
    /// Number of steps the skill declared at run time. Recorded on both
    /// the start and terminal lines so a start-only line (crash before
    /// finish) still carries the planned step count.
    let stepsPlanned: Int
    /// Plain-language reason the run did not complete. Nil on the
    /// "started" and "completed" lines; set only on a "failed" line.
    let failureReason: String?
    // The original ISO timestamp is whole-second precision. Preserve it for older readers.
    var millisecondsSince1970: Int64?

    var measuredAt: Date {
        millisecondsSince1970.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? at
    }
}

nonisolated final class PaceSkillRunJournal: @unchecked Sendable {
    static let shared = PaceSkillRunJournal()

    /// Rotate when the log passes this size; one previous generation kept.
    /// Mirrors PaceAPIAuditLog so the two logs age out the same way.
    static let rotationByteThreshold = 5 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.pace.skill-run-journal", qos: .utility)
    private let logFileURL: URL
    private let encoder: JSONEncoder

    init(logFileURL: URL? = nil) {
        self.logFileURL = logFileURL ?? Self.defaultLogFileURL()
        let configuredEncoder = JSONEncoder()
        configuredEncoder.dateEncodingStrategy = .iso8601
        configuredEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = configuredEncoder
    }

    /// Records that a skill run is starting. Returns the `runId` the
    /// caller must hand back to `recordCompleted`/`recordFailed` so the
    /// two lines pair up. Fire-and-forget: the disk append happens on a
    /// utility queue so the hot run path pays nothing.
    @discardableResult
    func recordStarted(
        skillSlug: String,
        stepsPlanned: Int,
        at timestamp: Date = Date()
    ) -> String {
        let runId = UUID().uuidString
        append(PaceSkillRunRecord(
            at: timestamp,
            runId: runId,
            skillSlug: skillSlug,
            phase: "started",
            stepsPlanned: stepsPlanned,
            failureReason: nil
        ))
        return runId
    }

    func recordFinished(runId: String, skillSlug: String, stepsPlanned: Int, failed: Bool) {
        if failed {
            recordFailed(
                runId: runId, skillSlug: skillSlug, stepsPlanned: stepsPlanned,
                failureReason: "Workflow ended before completion was verified.")
        } else {
            recordCompleted(runId: runId, skillSlug: skillSlug, stepsPlanned: stepsPlanned)
        }
    }

    /// Records that a previously-started skill run completed successfully.
    func recordCompleted(
        runId: String,
        skillSlug: String,
        stepsPlanned: Int,
        at timestamp: Date = Date()
    ) {
        append(PaceSkillRunRecord(
            at: timestamp,
            runId: runId,
            skillSlug: skillSlug,
            phase: "completed",
            stepsPlanned: stepsPlanned,
            failureReason: nil
        ))
    }

    /// Records that a previously-started skill run did not complete, with
    /// a plain-language reason (e.g. "no matching skill",
    /// "missing preference: preferredFocusPlaylist").
    func recordFailed(
        runId: String,
        skillSlug: String,
        stepsPlanned: Int,
        failureReason: String,
        at timestamp: Date = Date()
    ) {
        append(PaceSkillRunRecord(
            at: timestamp,
            runId: runId,
            skillSlug: skillSlug,
            phase: "failed",
            stepsPlanned: stepsPlanned,
            failureReason: failureReason
        ))
    }

    /// Synchronously flushes pending writes — for tests.
    func waitForPendingWrites() {
        queue.sync {}
    }

    /// Read-only decode of the JSONL file. Chronological order (oldest
    /// first); malformed lines are silently skipped so one bad line can't
    /// break analysis. Snapshot both generations on the writer queue to avoid rotation races.
    func readAllRecords() -> [PaceSkillRunRecord] {
        let generations = queue.sync {
            [logFileURL.appendingPathExtension("1"), logFileURL].compactMap { try? Data(contentsOf: $0) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedRecords: [PaceSkillRunRecord] = generations.flatMap { generation in
            generation.split(separator: 0x0A).compactMap { line in
                try? decoder.decode(PaceSkillRunRecord.self, from: line)
            }
        }
        return decodedRecords
    }

    private func append(_ record: PaceSkillRunRecord) {
        queue.async { [weak self] in
            self?.appendSynchronously(record)
        }
    }

    private func appendSynchronously(_ record: PaceSkillRunRecord) {
        var timedRecord = record
        timedRecord.millisecondsSince1970 = Int64((record.at.timeIntervalSince1970 * 1000).rounded())
        guard var lineData = try? encoder.encode(timedRecord) else { return }
        lineData.append(0x0A)

        let fileManager = FileManager.default
        let directoryURL = logFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        rotateIfNeeded(fileManager: fileManager)

        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: logFileURL)
        }
    }

    private func rotateIfNeeded(fileManager: FileManager) {
        guard let fileSize = (try? fileManager.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
              fileSize >= Self.rotationByteThreshold else {
            return
        }
        let rotatedURL = logFileURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: logFileURL, to: rotatedURL)
    }

    private static func defaultLogFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupportURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("skill-runs.jsonl")
    }
}
