import Darwin
import Foundation
import Testing
@testable import Pace

struct PaceCLIProcessRunnerTests {
    @Test func largeStderrDoesNotBlockStdoutAndUnicodeIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var output: [String] = []
        for try await line in PaceCLIProcessRunner.lines(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import os; os.write(2, b'e' * 200000); os.write(1, bytes([226])); os.write(1, bytes([130,172,10])); print('done')",
            ],
            stdinPayload: "", workingDirectoryURL: directory, timeout: 10
        ) { output.append(line) }
        #expect(output == ["€", "done"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func stalledPlannerTimesOutAndReturnsControl() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date()
        do {
            for try await _ in PaceCLIProcessRunner.lines(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdinPayload: "", workingDirectoryURL: directory, timeout: 0.2
            ) {}
            Issue.record("Expected timeout")
        } catch PaceCLIProcessError.timedOut {
            #expect(Date().timeIntervalSince(startedAt) < 5)
        }
    }
    @Test func cancellingConsumerStopsThePlannerAndCleansItsTemporaryOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let consumer = Task {
            for try await _ in PaceCLIProcessRunner.lines(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                stdinPayload: "", workingDirectoryURL: directory, timeout: 30
            ) {}
        }
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        _ = try? await consumer.value
        for _ in 0..<30 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Cancelled planner did not clean up within three seconds")
    }

    @MainActor
    @Test func sealedCodexTurnReturnsBeforeLateCleanupAndReapsTheOwnedProcess() async throws {
        for delivery in [PaceCodexTextDelivery.completedMessage, .completedTurn] {
            let directory = try makePlannerFixture(lines: [codexMessage, codexCompletion],
                cleanupDelay: 3, ignoresTermination: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = fixturePlanner(directory: directory, textDelivery: delivery)
            var deliveredTexts: [String] = []
            let startedAt = ProcessInfo.processInfo.systemUptime
            let response = try await planner.generateResponseStreaming(images: [], systemPrompt: "Synthetic",
                conversationHistory: [], userPrompt: "Synthetic", onTextChunk: { deliveredTexts.append($0) })
            #expect(response.text == "Accepted answer.")
            #expect(deliveredTexts == ["Accepted answer."])
            #expect(ProcessInfo.processInfo.systemUptime - startedAt < 2.5)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-cleanup").path))
            try expectPlannerExitedAndWorkDirectoryRemoved(directory)
        }
    }

    @MainActor
    @Test func invalidOrUnsealedCodexTurnsWaitForProcessExit() async throws {
        let cases = [
            [codexMessage],
            [codexMessage, #"{"type":"turn.failed","error":{"message":"Synthetic failure"}}"#, codexCompletion],
            [codexMessage, "malformed stream", codexCompletion],
            [codexMessage, #"{"type":"turn.completed""#],
            [codexCompletion],
        ]
        for lines in cases {
            let directory = try makePlannerFixture(lines: lines, cleanupDelay: 0.25)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = fixturePlanner(directory: directory, textDelivery: .completedTurn)
            var deliveredTexts: [String] = []
            do {
                _ = try await planner.generateResponseStreaming(images: [], systemPrompt: "Synthetic",
                    conversationHistory: [], userPrompt: "Synthetic", onTextChunk: { deliveredTexts.append($0) })
                Issue.record("Invalid or unsealed Codex output must not succeed")
            } catch is CancellationError { throw CancellationError() }
            catch {}
            #expect(deliveredTexts.isEmpty)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-cleanup").path))
            try expectPlannerExitedAndWorkDirectoryRemoved(directory)
        }
    }

    @MainActor
    @Test func refusalBeforeSealRemainsARejection() async throws {
        let directory = try makePlannerFixture(lines: [codexMessage,
            #"{"type":"turn.failed","error":{"code":"invalid_api_key"}}"#, codexCompletion], cleanupDelay: 0.25)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = fixturePlanner(directory: directory, textDelivery: .completedTurn)
        do {
            _ = try await planner.generateResponseStreaming(images: [], systemPrompt: "Synthetic",
                conversationHistory: [], userPrompt: "Synthetic", onTextChunk: { _ in })
            Issue.record("Expected authentication rejection")
        } catch PaceLocalCLIPlannerError.rejected(let category) {
            #expect(category == .authentication)
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-cleanup").path))
        try expectPlannerExitedAndWorkDirectoryRemoved(directory)
    }

    @MainActor
    @Test func cancellationBeforeSealCannotSucceedOrLeaveTheOwnedProcessRunning() async throws {
        let directory = try makePlannerFixture(lines: [codexMessage, codexCompletion], sealDelay: 3,
            cleanupDelay: 3, ignoresTermination: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planner = fixturePlanner(directory: directory)
        var receivedMessage = false
        let consumer = Task {
            try await planner.generateResponseStreaming(images: [], systemPrompt: "Synthetic",
                conversationHistory: [], userPrompt: "Synthetic", onTextChunk: { _ in receivedMessage = true })
        }
        for _ in 0..<100 {
            if receivedMessage { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(receivedMessage)
        consumer.cancel()
        do {
            _ = try await consumer.value
            Issue.record("A cancelled turn must not succeed")
        } catch is CancellationError {}
        try expectPlannerExitedAndWorkDirectoryRemoved(directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-cleanup").path))
    }

    @MainActor
    @Test func claudeAndExplicitProcessExitPolicyKeepNormalCleanup() async throws {
        for upstream in [PaceLocalCLIUpstream.claude, .codex] {
            let lines = upstream == .claude
                ? [#"{"type":"assistant","message":{"content":[{"type":"text","text":"Accepted answer."}]}}"#,
                   codexCompletion]
                : [codexMessage, codexCompletion]
            let directory = try makePlannerFixture(lines: lines, cleanupDelay: 0.25, exitStatus: 0)
            defer { try? FileManager.default.removeItem(at: directory) }
            let planner = fixturePlanner(directory: directory, upstream: upstream,
                completionPolicy: upstream == .codex ? .processExit : .completedTurn)
            var deliveredTexts: [String] = []
            let response = try await planner.generateResponseStreaming(images: [], systemPrompt: "Synthetic",
                conversationHistory: [], userPrompt: "Synthetic", onTextChunk: { deliveredTexts.append($0) })
            #expect(response.text == "Accepted answer.")
            #expect(deliveredTexts == ["Accepted answer."])
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-cleanup").path))
            try expectPlannerExitedAndWorkDirectoryRemoved(directory)
        }
    }

    private var codexMessage: String {
        #"{"type":"item.completed","item":{"type":"agent_message","text":"Accepted answer."}}"#
    }

    private var codexCompletion: String { #"{"type":"turn.completed"}"# }

    @MainActor
    private func fixturePlanner(
        directory: URL, upstream: PaceLocalCLIUpstream = .codex,
        textDelivery: PaceCodexTextDelivery = .completedMessage,
        completionPolicy: PaceCodexCompletionPolicy = .completedTurn
    ) -> PaceLocalCLIPlannerClient {
        let executableURL = directory.appendingPathComponent("fake-cli")
        return PaceLocalCLIPlannerClient(upstream: upstream, modelIdentifier: nil,
            codexTextDelivery: textDelivery, requestTimeout: 10, codexCompletionPolicy: completionPolicy,
            executableResolver: { _ in executableURL })
    }

    private func makePlannerFixture(
        lines: [String], sealDelay: Double = 0, cleanupDelay: Double, exitStatus: Int = 17,
        ignoresTermination: Bool = false
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encodedLines = try JSONEncoder().encode(lines).base64EncodedString()
        let script = """
        #!/usr/bin/python3
        import base64, json, os, signal, sys, time
        from pathlib import Path
        directory = Path(__file__).parent
        (directory / 'pid').write_text(str(os.getpid()))
        (directory / 'working-directory').write_text(str(Path.cwd()))
        if \(ignoresTermination ? "True" : "False"):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdin.read()
        lines = json.loads(base64.b64decode('\(encodedLines)'))
        for index, line in enumerate(lines):
            if index > 0:
                time.sleep(\(sealDelay))
            print(line, flush=True)
        time.sleep(\(cleanupDelay))
        (directory / 'late-cleanup').write_text('done')
        if \(exitStatus) != 0:
            print('Synthetic late cleanup failure', file=sys.stderr, flush=True)
        sys.exit(\(exitStatus))
        """
        let executableURL = directory.appendingPathComponent("fake-cli")
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return directory
    }

    private func expectPlannerExitedAndWorkDirectoryRemoved(_ directory: URL) throws {
        let processIdentifier = try #require(Int32(String(contentsOf: directory.appendingPathComponent("pid"),
            encoding: .utf8)))
        #expect(kill(processIdentifier, 0) == -1 && errno == ESRCH)
        let workingDirectoryPath = try String(contentsOf: directory.appendingPathComponent("working-directory"),
            encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: workingDirectoryPath))
    }

}
