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
            arguments: ["-c", "import os; os.write(2, b'e' * 200000); os.write(1, bytes([226])); os.write(1, bytes([130,172,10])); print('done')"],
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

}
