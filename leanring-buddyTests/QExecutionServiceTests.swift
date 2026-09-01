//
//  QExecutionServiceTests.swift
//  leanring-buddyTests
//
//  Unit tests for QExecutionService (Phase 1D.6)
//

import Testing
import Foundation
@testable import Pace

@Suite("QExecutionServiceTests")
struct QExecutionServiceTests {

    @Test("Execution service runs safe no-op action")
    func noopExecution() async throws {
        let exec = QExecutionService.shared
        let context = QTaskContext(taskId: "test_noop_task")
        let req = QActionRequest(
            toolName: "test.noop",
            toolFamily: "test",
            riskLevel: .level0ReadOnly,
            literalAction: "Run test no-op"
        )

        let res = try await exec.executeAction(req, context: context)
        #expect(res.success == true)
        #expect(res.summary.contains("No-op test action completed"))
    }

    @Test("Execution service performs sandboxed file write and read")
    func sandboxFileOperations() async throws {
        let exec = QExecutionService.shared
        let context = QTaskContext(taskId: "test_fs_task")
        let testSandboxPath = "/tmp/q-sandbox-test-\(UUID().uuidString)/data.txt"

        // Write
        let writeReq = QActionRequest(
            toolName: "fs.write_sandbox",
            toolFamily: "fs",
            riskLevel: .level1SafeLocalAction,
            literalAction: "Write sandbox file",
            targetResources: [testSandboxPath],
            parameters: [
                "path": testSandboxPath,
                "content": "Hello from Q Execution Service"
            ]
        )

        let writeRes = try await exec.executeAction(writeReq, context: context)
        #expect(writeRes.success == true)

        // Read
        let readReq = QActionRequest(
            toolName: "fs.read",
            toolFamily: "fs",
            riskLevel: .level0ReadOnly,
            literalAction: "Read sandbox file",
            targetResources: [testSandboxPath],
            parameters: ["path": testSandboxPath]
        )

        let readRes = try await exec.executeAction(readReq, context: context)
        #expect(readRes.success == true)
        #expect(readRes.outputData["content"] == "Hello from Q Execution Service")

        // Cleanup
        try? FileManager.default.removeItem(atPath: (testSandboxPath as NSString).deletingLastPathComponent)
    }

    @Test("Execution service rejects denylisted paths before execution")
    func rejectsDenylistedPaths() async throws {
        let exec = QExecutionService.shared
        let context = QTaskContext(taskId: "malicious_task")

        let req = QActionRequest(
            toolName: "fs.read",
            toolFamily: "fs",
            riskLevel: .level1SafeLocalAction,
            literalAction: "Read SSH keys",
            targetResources: ["~/.ssh/id_rsa"],
            parameters: ["path": "~/.ssh/id_rsa"]
        )

        let res = try await exec.executeAction(req, context: context)
        #expect(res.success == false)
        #expect(res.error?.contains(".ssh") == true || res.summary.contains("Denied"))
    }

    @Test("Execution service rejects arbitrary unrecognized tools")
    func rejectsUnrecognizedTools() async throws {
        let exec = QExecutionService.shared
        let context = QTaskContext(taskId: "arbitrary_task")

        let req = QActionRequest(
            toolName: "shell.exec_raw",
            toolFamily: "shell",
            riskLevel: .level4Blocked,
            literalAction: "rm -rf /"
        )

        let res = try await exec.executeAction(req, context: context)
        #expect(res.success == false)
        #expect(res.error?.contains("not implemented in safe execution set") == true)
    }
}
