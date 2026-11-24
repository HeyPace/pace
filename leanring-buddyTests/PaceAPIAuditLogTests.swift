//
//  PaceAPIAuditLogTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceAPIAuditLogTests {
    @Test func unitHostAuditNeverUsesTheInstalledAppsLog() {
        let testURL = PaceAPIAuditLog.defaultLogFileURL(environment: ["XCTestConfigurationFilePath": "/test/config"])
        let installedURL = PaceAPIAuditLog.defaultLogFileURL(environment: [:])
        #expect(testURL != installedURL)
        #expect(testURL.path.contains("pace-unit-audit-"))
        #expect(installedURL.path.hasSuffix("/Pace/api-audit.jsonl"))
    }

    @Test func usageCountsOnlyRecordedFailuresAcrossBothLogGenerations() throws {
        let logURL = makeTemporaryLogURL()
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let audit = PaceAPIAuditLog(logFileURL: logURL)
        _ = audit.beginTurn()
        for (milliseconds, outcome) in [(1, "ok"), (9, "transport_error")] {
            audit.record(
                subsystem: "mcp", operation: "tools/call", target: "browse.status",
                durationMilliseconds: milliseconds, outcome: outcome, at: now)
        }
        audit.waitForPendingWrites()
        try FileManager.default.moveItem(at: logURL, to: logURL.appendingPathExtension("1"))
        audit.record(
            subsystem: "tts", operation: "speak", target: "voice", durationMilliseconds: 0,
            outcome: "skipped_muted", at: now)
        audit.record(
            subsystem: "mcp", operation: "tools/list", target: "browse", durationMilliseconds: 3,
            outcome: "ok", at: now)
        audit.record(
            subsystem: "mcp", operation: "tools/call", target: "old", durationMilliseconds: 0,
            outcome: "error", at: now.addingTimeInterval(-86_401))
        let snapshot = PaceUsageSnapshot(logData: audit.retainedLogData(), now: now)
        #expect(snapshot.turnCount == 1)
        #expect(snapshot.toolCount == 1)
        #expect(snapshot.failureCount == 1)
        #expect(snapshot.rows.count == 3)
        let browse = try #require(snapshot.rows.first { $0.target == "browse.status" })
        #expect(browse.callCount == 2)
        #expect(browse.p50Milliseconds == 5)
        #expect(browse.p95Milliseconds == 9)
    }

    @Test func auditOutcomeClassification() {
        for outcome in ["failed", "decode_error", "fetch_failed", "failed_validation", "http_503", "non_2xx"] {
            #expect(PaceAPIAuditEntry.isRecordedFailure(outcome))
        }
        for outcome in ["loaded", "skipped_muted", "cancelled", "unknown", "http_200"] {
            #expect(!PaceAPIAuditEntry.isRecordedFailure(outcome))
        }
    }

    private func makeTemporaryLogURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-audit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("api-audit.jsonl")
    }

    @Test func recordsAppendOneJSONObjectPerLine() async throws {
        let logURL = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent()) }
        let auditLog = PaceAPIAuditLog(logFileURL: logURL)

        auditLog.record(
            subsystem: "planner",
            operation: "chat.completions.stream",
            target: "qwen/qwen3-30b-a3b",
            durationMilliseconds: 925,
            outcome: "ok",
            outputCharacterCount: 240,
            detail: "3 msgs"
        )
        auditLog.record(
            subsystem: "tts",
            operation: "audio.speech",
            target: "kokoro/af_heart",
            durationMilliseconds: 150,
            outcome: "transport_error"
        )
        auditLog.waitForPendingWrites()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)

        let firstEntry = try JSONDecoder.auditDecoder.decode(
            PaceAPIAuditEntry.self,
            from: Data(lines[0].utf8)
        )
        #expect(firstEntry.subsystem == "planner")
        #expect(firstEntry.durationMilliseconds == 925)
        #expect(firstEntry.outcome == "ok")
        #expect(firstEntry.outputCharacterCount == 240)

        let secondEntry = try JSONDecoder.auditDecoder.decode(
            PaceAPIAuditEntry.self,
            from: Data(lines[1].utf8)
        )
        #expect(secondEntry.subsystem == "tts")
        #expect(secondEntry.outcome == "transport_error")
        #expect(secondEntry.inputCharacterCount == nil)
    }

    @Test func rotationMovesOversizedLogToPreviousGeneration() async throws {
        let logURL = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Pre-seed an oversized file so the next record rotates it away.
        let oversizedContents = String(
            repeating: "x",
            count: PaceAPIAuditLog.rotationByteThreshold
        )
        try oversizedContents.write(to: logURL, atomically: true, encoding: .utf8)

        let auditLog = PaceAPIAuditLog(logFileURL: logURL)
        auditLog.record(
            subsystem: "mcp",
            operation: "tools/call",
            target: "apple.notes",
            durationMilliseconds: 80,
            outcome: "ok"
        )
        auditLog.waitForPendingWrites()

        let rotatedURL = logURL.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))
        let freshLines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(freshLines.count == 1)
    }
}

private extension JSONDecoder {
    static var auditDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
