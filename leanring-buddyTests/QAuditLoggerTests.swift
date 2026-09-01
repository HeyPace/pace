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
}
