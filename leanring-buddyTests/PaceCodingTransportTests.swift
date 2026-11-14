import Darwin
import Foundation
import Testing
@testable import Pace

private actor SuspendedCodingMetadata {
    private var continuation: CheckedContinuation<[String: PaceMCPJSONValue], any Error>?
    private(set) var wasCancelled = false
    var isWaiting: Bool { continuation != nil }
    func wait() async throws -> [String: PaceMCPJSONValue] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { await self.noteCancellation() } }
    }
    private func noteCancellation() { wasCancelled = true }
    func finish() { continuation?.resume(returning: [:]); continuation = nil }
}


struct PaceCodingTransportTests {
    private func fixture() throws -> (URL, PaceCodingAppServerTransport) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaceCodingWire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = directory.appendingPathComponent("fixture-server")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, time, subprocess
        if sys.argv[1:3] == ['mcp', 'list']:
            print('[]')
            sys.exit(0)
        with open('app-server-launch.marker', 'w') as marker:
            marker.write(str(os.getpid()))
        def send(value):
            raw = (json.dumps(value) + '\n').encode()
            for start in range(0, len(raw), 7):
                os.write(1, raw[start:start + 7])
                time.sleep(.001)
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if method == 'fixture/crash':
                sys.exit(7)
            if method == 'fixture/never':
                continue
            if method == 'fixture/spawn-child':
                child = subprocess.Popen(['/usr/bin/python3', '-c', 'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(.1)
                send({'id': request['id'], 'result': {'child': child.pid}})
                continue
            if 'id' in request and 'method' in request:
                if method == 'fixture/echo':
                    send({'id': 900, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'owned', 'turnId': 'turn-1', 'command': 'swift test', 'cwd': '/tmp'}})
                send({'id': request['id'], 'result': {'method': method, 'params': request.get('params', {})}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, PaceCodingAppServerTransport(executable: executable, workingDirectory: directory))
    }

    @Test func splitLinesAndInterleavedApprovalDoNotStealRPCResponse() async throws {
        let (_, transport) = try fixture()
        let events = await transport.events()
        let approval = Task {
            for await event in events {
                if case .message(let message) = event, message["id"] == .number(900) { return message }
            }
            return [:]
        }
        try await transport.open()
        let response = try await transport.request("fixture/echo", params: ["sentinel": .string("request-value")])
        #expect(response.codingObject?["params"]?.codingObject?["sentinel"] == .string("request-value"))
        let request = await approval.value
        #expect(request["method"] == .string("item/commandExecution/requestApproval"))
        try await transport.reply(id: .number(900), result: .object(["decision": .string("cancel")]), error: nil)
        await transport.shutdown()
    }

    @Test func crashResolvesPendingRequestAndCancellationIsBounded() async throws {
        let (_, transport) = try fixture()
        try await transport.open()
        do { _ = try await transport.request("fixture/crash", params: [:]); Issue.record("crashed RPC cannot succeed") }
        catch { #expect(error is PaceCodingError) }
        await transport.shutdown()
        let (_, waiting) = try fixture()
        try await waiting.open()
        let task = Task { try await waiting.request("fixture/never", params: [:]) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled RPC cannot succeed") }
        catch { #expect(error is CancellationError) }
        await waiting.shutdown()
    }
    @Test func shutdownStopsOwnedChildThatIgnoresTermAfterParentExits() async throws {
        let (_, transport) = try fixture()
        try await transport.open()
        let result = try await transport.request("fixture/spawn-child", params: [:])
        guard case .number(let number)? = result.codingObject?["child"] else { Issue.record("missing child PID"); return }
        let child = pid_t(number)
        #expect(kill(child, 0) == 0)
        await transport.shutdown()
        for _ in 0..<100 {
            if kill(child, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(child, 0) != 0)
    }

    @Test func privateProcessOverridesUseValidTOMLStringsAndSupportedApprovalPolicy() {
        let arguments = PaceCodingAppServerTransport.arguments(mcpOverrides: [
            "mcp_servers.local.enabled": .bool(false), "mcp_servers.local.command": .string("/usr/bin/false"),
            "mcp_servers.remote.enabled": .bool(false), "mcp_servers.remote.url": .string("http://127.0.0.1:1")])
        #expect(arguments.contains("mcp_servers.local.command=\"/usr/bin/false\""))
        #expect(arguments.contains("mcp_servers.remote.url=\"http://127.0.0.1:1\""))
        #expect(arguments.contains("approval_policy=\"on-request\""))
        #expect(!arguments.contains { $0.contains("untrusted") || $0.contains("\\/") })
        #expect(!arguments.contains("shell_tool"))
        #expect(!arguments.contains { $0.contains("project_doc_max_bytes") || $0.contains("ignore-user-config") })
    }

    @Test func shutdownDuringMetadataWaitsAndRejectsLateResultBeforeAnyAppServerLaunch() async throws {
        let (directory, _) = try fixture()
        let metadata = SuspendedCodingMetadata()
        let transport = PaceCodingAppServerTransport(executable: directory.appendingPathComponent("fixture-server"),
            workingDirectory: directory, discoverMCPOverrides: { _, _ in try await metadata.wait() })
        let opening = Task { try await transport.open() }
        let deadline = Date().addingTimeInterval(3)
        while !(await metadata.isWaiting), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await metadata.isWaiting)
        let shutdown = Task { await transport.shutdown() }
        while !(await metadata.wasCancelled), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await metadata.wasCancelled)
        await metadata.finish()
        await shutdown.value
        do { try await opening.value; Issue.record("closed transport cannot finish opening") }
        catch { #expect(error is CancellationError || error is PaceCodingError) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("app-server-launch.marker").path))
        do { try await transport.open(); Issue.record("shutdown permanently closes the owned transport") }
        catch { #expect(error is PaceCodingError) }
    }

}
