//
//  PaceAPIAuditLogTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceAPIAuditLogTests {
    @MainActor
    @Test func supersedingATaughtWorkflowLeavesItsRunUnfinished() {
        let manager = CompanionManager()
        defer { manager.cancelActiveTurnTasks() }
        let run = CompanionManager.ActiveSkillRun(runId: "interrupted", skillSlug: "test", stepsPlanned: 2)
        manager.sendTranscriptToPlannerWithScreenshot(
            transcript: "first", continuingAcceptedRequest: true, skillRun: run)
        #expect(manager.activeSkillRun?.runId == run.runId)
        manager.sendTranscriptToPlannerWithScreenshot(transcript: "next")
        #expect(manager.activeSkillRun == nil)
    }

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
        #expect(snapshot.rows.first { $0.subsystem == "tts" }?.timedCount == 0)
    }

    @Test func usageAttributesOnlyKnownPowerEventsAndMeasuresTailLatency() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = now.ISO8601Format()
        func event(_ subsystem: String, _ operation: String, _ duration: Int, outcome: String = "ok") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "at": stamp, "subsystem": subsystem, "operation": operation, "target": "example",
                "durationMilliseconds": duration, "outcome": outcome,
            ])
        }
        var data = Data()
        for duration in 1...100 {
            data.append(try event("action", "key_press", duration, outcome: duration == 1 ? "failed" : "ok"))
            data.append(10)
        }
        for (subsystem, operation) in [
            ("action", "mcp_call"), ("mcp", "tools/list"), ("mcp", "tools/call"),
            ("reminders", "permission_prompt"), ("future", "key_press"),
        ] {
            data.append(try event(subsystem, operation, operation == "mcp_call" ? 0 : 20))
            data.append(10)
        }
        let snapshot = PaceUsageSnapshot(logData: [data], now: now)
        #expect(snapshot.eventCount == 105)
        #expect(snapshot.rows.first { $0.subsystem == "action" }?.timedCount == 101)
        #expect(snapshot.failureCount == 1)
        #expect(snapshot.powerRows.count == 2)
        let computer = try #require(snapshot.powerRows.first { $0.subsystem == "Computer use" })
        #expect(computer.failureCount == 1)
        #expect(computer.callCount == 100)
        #expect(computer.p95Milliseconds == 95)
        #expect(computer.p99Milliseconds == 99)
        #expect(snapshot.powerRows.first { $0.subsystem == "Integrations" }?.callCount == 1)
    }

    @Test func workflowUsagePairsAcrossRotationAndSeparatesDispatchesFromMeasuredRuns() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = makeTemporaryLogURL()
        let journal = PaceSkillRunJournal(logFileURL: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let run = journal.recordStarted(skillSlug: "daily", stepsPlanned: 1, at: now.addingTimeInterval(-0.25))
        journal.waitForPendingWrites()
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        journal.recordCompleted(runId: run, skillSlug: "daily", stepsPlanned: 1, at: now)
        journal.recordFailed(runId: "orphan", skillSlug: "daily", stepsPlanned: 1, failureReason: "fixture", at: now)
        journal.recordStarted(skillSlug: "daily", stepsPlanned: 1, at: now)
        let records = journal.readAllRecords()
        #expect(records.count == 4)
        let rows = PaceWorkflowUsage.aggregate(
            records + records, dispatches: ["program:daily": 2],
            cutoff: now.addingTimeInterval(-86400), now: now)
        let workflow = try #require(rows.first { $0.id == "skill:daily" })
        #expect(workflow.finished == 2)
        #expect(workflow.failures == 1)
        #expect(workflow.unfinished == 1)
        #expect(workflow.durations == [250])
        let program = try #require(rows.first { $0.id == "program:daily" })
        #expect(program.dispatches == 2)
        #expect(program.finished == 0)
        #expect(program.durations.isEmpty)
    }

    @Test func workflowFailureAtTheStepLimitIsJournaledAsFailed() {
        let url = makeTemporaryLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = PaceSkillRunJournal(logFileURL: url)
        let run = journal.recordStarted(skillSlug: "browse", stepsPlanned: 2)
        journal.recordFinished(runId: run, skillSlug: "browse", stepsPlanned: 2, failed: true)
        #expect(journal.readAllRecords().map(\.phase) == ["started", "failed"])
    }

    @Test func historicalWorkflowTimesKeepUnmeasuredAndOutOfWindowRunsSeparate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = now.addingTimeInterval(-86400)
        func record(_ run: String, _ phase: String, _ date: Date) -> PaceSkillRunRecord {
            PaceSkillRunRecord(
                at: date, runId: run, skillSlug: "legacy", phase: phase, stepsPlanned: 1,
                failureReason: nil)
        }
        let rows = PaceWorkflowUsage.aggregate(
            [
                record("crossing", "started", cutoff.addingTimeInterval(-1)), record("crossing", "completed", cutoff),
                record("same", "started", now), record("same", "completed", now),
                record("future", "completed", now.addingTimeInterval(1)),
                record("old", "started", cutoff.addingTimeInterval(-1)), record("unknown", "cancelled", now),
            ], dispatches: [:], cutoff: cutoff, now: now)
        #expect(rows.count == 1)
        #expect(rows.first?.finished == 2)
        #expect(rows.first?.durations == [1000])
        #expect(rows.first?.unfinished == 0)
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
