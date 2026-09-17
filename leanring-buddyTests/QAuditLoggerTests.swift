//
//  QAuditLoggerTests.swift
//  leanring-buddyTests
//
//  Unit and Redaction Tests for QAuditLogger (Phase 1c.5)
//

import Testing
import Foundation
@testable import Pace

@Suite("QAuditLoggerTests")
struct QAuditLoggerTests {

    @Test("Secret Redactor scrubs API keys, private keys, and passwords")
    func secretRedaction() {
        // OpenAI Key
        let text1 = "Error connecting with key sk-1234567890abcdef1234567890abcdef to OpenAI"
        let redacted1 = QSecretRedactor.redact(text1)
        #expect(!redacted1.contains("sk-1234567890abcdef1234567890abcdef"))
        #expect(redacted1.contains("[REDACTED_SECRET]"))

        // Bearer Token
        let text2 = "Authorization: Bearer secret_access_token_1234567890"
        let redacted2 = QSecretRedactor.redact(text2)
        #expect(!redacted2.contains("secret_access_token_1234567890"))
        #expect(redacted2.contains("[REDACTED_SECRET]"))

        // GitHub PAT
        let text3 = "git clone https://ghp_0123456789abcdef0123456789abcdef0123@github.com/repo"
        let redacted3 = QSecretRedactor.redact(text3)
        #expect(!redacted3.contains("ghp_0123456789abcdef0123456789abcdef0123"))

        // PEM Private Key
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA0Y1+
        secret_key_bytes_here
        -----END RSA PRIVATE KEY-----
        """
        let redactedPem = QSecretRedactor.redact("Loaded key: \(pem)")
        #expect(!redactedPem.contains("secret_key_bytes_here"))
        #expect(redactedPem.contains("[REDACTED_SECRET]"))

        // Password in JSON/CLI
        let textPass = #"{"username": "admin", "password": "supersecretpassword123"}"#
        let redactedPass = QSecretRedactor.redact(textPass)
        #expect(!redactedPass.contains("supersecretpassword123"))
    }

    @Test("Audit records redact execution summaries and hash input arguments")
    func auditRecordHashingAndRedaction() {
        let rawArgs = #"{"path": "/tmp/test.txt", "token": "sk-test12345678901234567890"}"#
        let executionOutput = "Failed with token sk-test12345678901234567890: 401 Unauthorized"

        let record = QAuditRecord(
            sessionId: "sess-01",
            taskId: "task-01",
            tool: "fs.write",
            riskLevel: .level2UserApproval,
            rawArguments: rawArgs,
            authorizationResult: "allow",
            provenance: "trusted:user",
            executionSummary: executionOutput
        )

        // Argument hash is a 64-char hex SHA256
        #expect(record.argumentsHash.count == 64)
        // Raw argument text is not stored in plaintext
        #expect(record.argumentsHash != rawArgs)

        // Execution summary was scrubbed
        #expect(record.executionSummary != nil)
        #expect(!record.executionSummary!.contains("sk-test12345678901234567890"))
        #expect(record.executionSummary!.contains("[REDACTED_SECRET]"))
    }

    @Test("Audit logger appends records and retrieves recent entries")
    func auditLoggerAppending() {
        let tempLogURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q_audit_test_\(UUID().uuidString).log")
        let logger = QAuditLogger(customLogURL: tempLogURL)

        let record1 = QAuditRecord(
            sessionId: "sess-01",
            taskId: "task-01",
            tool: "screen.capture",
            riskLevel: .level0ReadOnly,
            rawArguments: "{}",
            authorizationResult: "allow",
            provenance: "trusted:system"
        )
        let record2 = QAuditRecord(
            sessionId: "sess-01",
            taskId: "task-02",
            tool: "fs.delete",
            riskLevel: .level3HighRisk,
            rawArguments: #"{"file": "/tmp/a"}"#,
            authorizationResult: "require_approval",
            provenance: "trusted:user"
        )

        logger.record(record1)
        logger.record(record2)

        let recent = logger.getRecentRecords(limit: 10)
        #expect(recent.count == 2)
        #expect(recent[0].tool == "screen.capture")
        #expect(recent[1].tool == "fs.delete")

        // Verify file on disk exists and contains 2 lines
        let content = try? String(contentsOf: tempLogURL, encoding: .utf8)
        #expect(content != nil)
        let lines = content?.split(separator: "\n")
        #expect(lines?.count == 2)
    }

    @Test("Newly created audit log file has owner-only (0600) permissions")
    func newAuditLogFileHasRestrictivePermissions() throws {
        let tempLogURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q_audit_perm_test_\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tempLogURL) }
        let logger = QAuditLogger(customLogURL: tempLogURL)

        logger.record(QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system"
        ))

        let attributes = try FileManager.default.attributesOfItem(atPath: tempLogURL.path)
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

// MARK: - HIGH-1: oversized-field truncation and safe-content-descriptor tests

/// Regression coverage for the confirmed production leak: `screen.ocr` and
/// `agent.completed` audit entries reached 2,000-5,000+ characters of
/// near-verbatim screen/response content, because `QSecretRedactor` only
/// strips credential-*shaped* substrings and was never meant to (and cannot)
/// generically identify arbitrary sensitive free text.
@Suite("QAuditRecordSafeContentTests")
struct QAuditRecordSafeContentTests {

    @Test("A short executionSummary passes through unchanged")
    func shortSummaryIsUnaffected() {
        let record = QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system",
            executionSummary: "Short, safe status line."
        )
        #expect(record.executionSummary == "Short, safe status line.")
    }

    @Test("An oversized executionSummary is truncated to the bounded length and carries a hash + original length, never the full content")
    func oversizedSummaryIsTruncatedWithHash() throws {
        // Simulates a real screen.ocr dump: several thousand characters of
        // plausible-looking recognized screen text, containing a distinctive
        // marker well past the truncation point to prove the full text is
        // gone, not just hidden behind a prefix.
        let sensitiveMarker = "ACCOUNT-NUMBER-9F3E7C1A-DO-NOT-LOG"
        let simulatedOCRText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100) + sensitiveMarker
        #expect(simulatedOCRText.count > 4000)

        let record = QAuditRecord(
            sessionId: "s", taskId: "t", tool: "screen.ocr", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system",
            executionSummary: simulatedOCRText
        )

        let stored = try #require(record.executionSummary)
        #expect(stored.count < 350, "stored field must be bounded (200-char prefix + a short fixed-format marker), not near the ~4000+ char original")
        #expect(!stored.contains(sensitiveMarker), "content past the truncation point must never appear")
        #expect(stored.contains("truncated:"))
        #expect(stored.contains("chars total"))
        #expect(stored.contains("sha256="))
    }

    @Test("An oversized error field is truncated the same way as executionSummary")
    func oversizedErrorFieldIsTruncated() {
        let longError = String(repeating: "stack frame detail line\n", count: 50)
        let record = QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "error", provenance: "trusted:system",
            error: longError
        )
        let stored = try? #require(record.error)
        #expect((stored?.count ?? 0) < 350)
        #expect(stored?.contains("sha256=") == true)
    }

    @Test("Redaction still runs BEFORE truncation — a credential near the start of a long string is still caught")
    func redactionRunsBeforeTruncation() {
        let longSummaryWithLeadingSecret = "sk-abcdefghijklmnopqrstuvwxyz0123456789 " + String(repeating: "padding text here. ", count: 50)
        let record = QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system",
            executionSummary: longSummaryWithLeadingSecret
        )
        let stored = try? #require(record.executionSummary)
        #expect(stored?.contains("sk-abcdefghijklmnopqrstuvwxyz0123456789") == false)
    }

    @Test("safeDescriptor never embeds any of the omitted content, only a length and a hash")
    func safeDescriptorNeverEmbedsContent() {
        let secretContent = "The user's screen showed: bank balance $48,213.55, SSN ending 4471"
        let descriptor = QAuditRecord.safeDescriptor(omittedContent: secretContent, label: "screen/perception content")

        #expect(!descriptor.contains("48,213.55"))
        #expect(!descriptor.contains("4471"))
        #expect(!descriptor.contains(secretContent))
        #expect(descriptor.contains("\(secretContent.count) chars"))
        #expect(descriptor.contains("sha256="))
        #expect(descriptor.contains("screen/perception content"))
    }

    @Test("safeDescriptor is deterministic for identical content — same input always yields the same hash")
    func safeDescriptorIsDeterministic() {
        let content = "identical content for hash comparison"
        let first = QAuditRecord.safeDescriptor(omittedContent: content, label: "x")
        let second = QAuditRecord.safeDescriptor(omittedContent: content, label: "x")
        #expect(first == second)
    }

    @Test("Empty executionSummary/error remain nil, not an empty descriptor")
    func nilFieldsStayNil() {
        let record = QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system"
        )
        #expect(record.executionSummary == nil)
        #expect(record.error == nil)
    }
}

// MARK: - HIGH-1: bounded log rotation tests

@Suite("QAuditLoggerRotationTests")
struct QAuditLoggerRotationTests {

    private func makeIsolatedLogURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("q_audit_rotation_test_\(UUID().uuidString).log")
    }

    @Test("A log file under the size cap is never rotated")
    func underCapNeverRotates() {
        let logURL = makeIsolatedLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let logger = QAuditLogger(customLogURL: logURL)

        for i in 0..<20 {
            logger.record(QAuditRecord(
                sessionId: "s", taskId: "t\(i)", tool: "test.noop", riskLevel: .level0ReadOnly,
                rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system"
            ))
        }

        #expect(FileManager.default.fileExists(atPath: logURL.path))
        #expect(!FileManager.default.fileExists(atPath: logURL.path + ".1"))
    }

    @Test("Rotation fires once the file reaches the size cap, preserves the prior content in .1, and starts a fresh main file with restrictive permissions")
    func rotationFiresAtSizeCapAndPreservesHistory() throws {
        let logURL = makeIsolatedLogURL()
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(atPath: logURL.path + ".1")
        }

        // Pre-seed a file already at/above the 25 MB rotation threshold so a
        // single subsequent record() call triggers rotation deterministically,
        // without this test actually writing 25 MB of real audit records.
        let oversizedPayload = Data(String(repeating: "x", count: 26 * 1024 * 1024).utf8)
        try oversizedPayload.write(to: logURL)
        let sizeBeforeRotation = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int

        let logger = QAuditLogger(customLogURL: logURL)
        logger.record(QAuditRecord(
            sessionId: "s", taskId: "post-rotation", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system"
        ))

        let rotatedPath = logURL.path + ".1"
        #expect(FileManager.default.fileExists(atPath: rotatedPath), "the oversized file must have been rotated out to .1")
        let rotatedSize = try FileManager.default.attributesOfItem(atPath: rotatedPath)[.size] as? Int
        #expect(rotatedSize == sizeBeforeRotation, "rotated-out file must retain the full prior content untouched")

        let rotatedPermissions = try FileManager.default.attributesOfItem(atPath: rotatedPath)[.posixPermissions] as? Int
        #expect(rotatedPermissions == 0o600, "rotated-out file must keep the same restrictive permissions")

        // The main path must now be a small, FRESH file containing only the
        // new record — never re-appended onto the old 26 MB content.
        let newMainSize = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int
        #expect((newMainSize ?? Int.max) < 10_000, "post-rotation main log must be a fresh, small file")

        let newMainContent = try String(contentsOf: logURL, encoding: .utf8)
        #expect(newMainContent.contains("post-rotation"))
    }

    @Test("Auditing continues even if the log directory cannot be written to — rotation/logging failures never throw or crash")
    func loggingNeverCrashesOnWriteFailure() {
        // A path under a nonexistent parent directory: the constructor's own
        // createDirectory call only runs for the default (non-custom) URL, so
        // a custom URL pointing at a nonexistent nested directory exercises
        // the same "disk write can fail silently" path the production
        // do/catch around encoding+writing is meant to absorb.
        let unwritableURL = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/q-audit.log")
        let logger = QAuditLogger(customLogURL: unwritableURL)

        // Must not crash or throw — record() has no throwing/optional return,
        // so simply completing this call without a fatal error is the test.
        logger.record(QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system"
        ))

        // The in-memory record must still be retained even though the disk
        // write failed — auditing is not silently disabled just because the
        // disk sink is unavailable.
        #expect(logger.getRecentRecords(limit: 10).count == 1)
    }

    @Test("Retention is bounded: rotated files beyond the retained count are dropped, not accumulated forever")
    func retentionIsBounded() throws {
        let logURL = makeIsolatedLogURL()
        defer {
            try? FileManager.default.removeItem(at: logURL)
            for index in 1...4 {
                try? FileManager.default.removeItem(atPath: logURL.path + ".\(index)")
            }
        }

        // Pre-seed rotated files .1, .2, .3 so the NEXT rotation must drop
        // the oldest (.3) rather than growing an unbounded chain of backups.
        try Data("oldest-generation".utf8).write(to: URL(fileURLWithPath: logURL.path + ".3"))
        try Data("middle-generation".utf8).write(to: URL(fileURLWithPath: logURL.path + ".2"))
        try Data("newest-generation".utf8).write(to: URL(fileURLWithPath: logURL.path + ".1"))
        try Data(String(repeating: "x", count: 26 * 1024 * 1024).utf8).write(to: logURL)

        let logger = QAuditLogger(customLogURL: logURL)
        logger.record(QAuditRecord(
            sessionId: "s", taskId: "t", tool: "test.noop", riskLevel: .level0ReadOnly,
            rawArguments: "{}", authorizationResult: "allow", provenance: "trusted:system"
        ))

        // .3 (the oldest) must have been dropped, not shifted further —
        // there is no .4, confirming the retention count is enforced.
        #expect(!FileManager.default.fileExists(atPath: logURL.path + ".4"))
        // The generations that survive must have shifted up by exactly one.
        let content3 = try? String(contentsOf: URL(fileURLWithPath: logURL.path + ".3"), encoding: .utf8)
        #expect(content3 == "middle-generation")
        let content2 = try? String(contentsOf: URL(fileURLWithPath: logURL.path + ".2"), encoding: .utf8)
        #expect(content2 == "newest-generation")
    }
}
