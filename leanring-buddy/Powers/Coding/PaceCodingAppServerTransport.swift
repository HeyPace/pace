import Darwin
import Foundation

nonisolated protocol PaceCodingTransport: Sendable {
    func open() async throws
    func request(_ method: String, params: [String: PaceMCPJSONValue]) async throws -> PaceMCPJSONValue
    func reply(id: PaceMCPJSONValue, result: PaceMCPJSONValue?, error: String?) async throws
    func events() async -> AsyncStream<PaceCodingTransportEvent>
    func shutdown() async
}

nonisolated enum PaceCodingTransportEvent: Sendable {
    case message([String: PaceMCPJSONValue])
    case disconnected
}

actor PaceCodingAppServerTransport: PaceCodingTransport {
    private let executable: URL?
    private let workingDirectory: URL
    private let discoverMCPOverrides: (@Sendable (URL, URL) async throws -> [String: PaceMCPJSONValue])?
    private var metadataTask: Task<[String: PaceMCPJSONValue], any Error>?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let processControl = PaceCLIProcessControl()
    private var pending: [String: CheckedContinuation<PaceMCPJSONValue, any Error>] = [:]
    private var serial = 0
    private var buffer = Data()
    private var reapTask: Task<Void, Never>?
    private var hasDisconnected = false
    private var isClosed = false
    private var reader: Task<Void, Never>?
    private let stream: AsyncStream<PaceCodingTransportEvent>
    private let continuation: AsyncStream<PaceCodingTransportEvent>.Continuation

    init(executable: URL? = PaceLocalCLIPlannerClient.resolveExecutable(named: "codex"), workingDirectory: URL,
         discoverMCPOverrides: (@Sendable (URL, URL) async throws -> [String: PaceMCPJSONValue])? = nil) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.discoverMCPOverrides = discoverMCPOverrides
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<PaceCodingTransportEvent> { stream }

    func open() async throws {
        guard !isClosed, !hasDisconnected else { throw PaceCodingError.disconnected }
        guard process == nil else { return }
        guard let executable else { throw PaceCodingError.unavailable }
        guard metadataTask == nil else { throw PaceCodingError.busy }
        let metadata = Task { [discoverMCPOverrides, workingDirectory] in
            if let discoverMCPOverrides { return try await discoverMCPOverrides(executable, workingDirectory) }
            return try await Self.disabledMCPOverrides(executable: executable, cwd: workingDirectory)
        }
        metadataTask = metadata
        let overrides: [String: PaceMCPJSONValue]
        do {
            overrides = try await withTaskCancellationHandler { try await metadata.value } onCancel: { metadata.cancel() }
        }
        catch { metadataTask = nil; throw error }
        metadataTask = nil
        try Task.checkCancellation()
        guard !isClosed, !hasDisconnected else { throw PaceCodingError.disconnected }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["app-server", "--stdio"] + Self.arguments(mcpOverrides: overrides)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let (chunks, chunkContinuation) = AsyncStream<Data>.makeStream()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { chunkContinuation.finish() }
            else { chunkContinuation.yield(data) }
        }
        process.terminationHandler = { _ in chunkContinuation.finish() }
        try processControl.launch(process)
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        reader = Task { [weak self] in
            for await chunk in chunks { await self?.receive(chunk) }
            await self?.didDisconnect()
        }
        do {
            _ = try await request("initialize", params: [
                "clientInfo": .object(["name": .string("pace_coding"), "version": .string("1")]),
                "capabilities": .object(["experimentalApi": .bool(true)]),
            ])
            try write(["method": .string("initialized"), "params": .object([:])])
        } catch {
            await shutdown()
            throw error
        }
    }

    func request(_ method: String, params: [String: PaceMCPJSONValue]) async throws -> PaceMCPJSONValue {
        try Task.checkCancellation()
        serial += 1
        let identifier = "pace-\(serial)"
        let startedAt = Date()
        var outcome = "failed"
        var model = "configured"
        defer {
            PaceAPIAuditLog.shared.record(subsystem: "coding.codex.appserver", operation: method,
                target: "codex.app-server", durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                outcome: outcome, detail: "model=\(model) retained=true workspaceWrite=true network=false reviewer=user")
        }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[identifier] = continuation
                do { try write(["id": .string(identifier), "method": .string(method), "params": .object(params)]) }
                catch { pending.removeValue(forKey: identifier)?.resume(throwing: error); return }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.expire(identifier, error: PaceCodingError.timedOut)
                }
            }
        } onCancel: {
            Task { await self.expire(identifier, error: CancellationError()) }
        }
        outcome = "ok"
        if let returnedModel = response.codingObject?["model"]?.codingString { model = String(returnedModel.prefix(120)) }
        return response
    }

    func reply(id: PaceMCPJSONValue, result: PaceMCPJSONValue?, error: String?) throws {
        if let error {
            try write(["id": id, "error": .object(["code": .number(-32601), "message": .string(error)])])
        } else { try write(["id": id, "result": result ?? .object([:])]) }
    }

    private func write(_ object: [String: PaceMCPJSONValue]) throws {
        guard !isClosed, let input, process?.isRunning == true else { throw PaceCodingError.disconnected }
        var data = try JSONEncoder().encode(object)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func expire(_ identifier: String, error: any Error) {
        pending.removeValue(forKey: identifier)?.resume(throwing: error)
    }

    private func receive(_ data: Data) async {
        buffer.append(data)
        guard buffer.count <= 4_194_304 else { await shutdown(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode([String: PaceMCPJSONValue].self, from: line) else {
                await shutdown(); return
            }
            if let identifier = message["id"]?.codingString, message["method"] == nil,
               let pendingRequest = pending.removeValue(forKey: identifier) {
                if message["error"] != nil { pendingRequest.resume(throwing: PaceCodingError.invalidProtocol) }
                else if let result = message["result"] { pendingRequest.resume(returning: result) }
                else { pendingRequest.resume(throwing: PaceCodingError.invalidProtocol) }
            } else if message["method"] != nil { continuation.yield(.message(message)) }
        }
    }

    private func didDisconnect() async {
        if !hasDisconnected {
            hasDisconnected = true
            input = nil
            for request in pending.values { request.resume(throwing: PaceCodingError.disconnected) }
            pending.removeAll()
            continuation.yield(.disconnected)
        }
        await reapOwnedProcess()
    }

    private func reapOwnedProcess() async {
        if let reapTask { await reapTask.value; return }
        guard let ownedProcess = process else { return }
        process = nil
        let control = processControl
        control.stop()
        let task = Task.detached {
            ownedProcess.waitUntilExit()
            control.waitForStoppedProcessGroup()
            control.finished()
        }
        reapTask = task
        await task.value
    }

    func shutdown() async {
        // Close before yielding so a suspended inventory result cannot launch a new owned process.
        isClosed = true
        processControl.stop()
        let metadata = metadataTask
        metadata?.cancel()
        output?.readabilityHandler = nil
        try? input?.close()
        input = nil
        await didDisconnect()
        _ = try? await metadata?.value
        metadataTask = nil
        try? output?.close()
        output = nil
        reader?.cancel()
        reader = nil
        continuation.finish()
    }

    nonisolated static func arguments(mcpOverrides: [String: PaceMCPJSONValue]) -> [String] {
        var arguments: [String] = []
        for feature in ["hooks", "apps", "browser_use", "computer_use", "multi_agent", "image_generation"] {
            arguments += ["--disable", feature]
        }
        var config = mcpOverrides
        config["web_search"] = .string("disabled")
        config["approval_policy"] = .string("on-request")
        config["approvals_reviewer"] = .string("user")
        config["sandbox_mode"] = .string("workspace-write")
        config["sandbox_workspace_write.network_access"] = .bool(false)
        config["sandbox_workspace_write.exclude_tmpdir_env_var"] = .bool(true)
        config["sandbox_workspace_write.exclude_slash_tmp"] = .bool(true)
        config["sandbox_workspace_write.writable_roots"] = .array([])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for key in config.keys.sorted() {
            guard let value = config[key], let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { continue }
            arguments += ["--config", key + "=" + text]
        }
        return arguments
    }

    private nonisolated static func disabledMCPOverrides(executable: URL, cwd: URL) async throws -> [String: PaceMCPJSONValue] {
        // The CLI's metadata command supplies the effective server inventory. Only name and transport
        // are retained. Never persist or log its wire output, environment, URLs or credential fields.
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp", "list", "--json"]
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let control = PaceCLIProcessControl()
        let worker = Task.detached { () throws -> Data in
            try control.launch(process)
            let timeout = Task.detached {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { control.stop(timedOut: true) }
            }
            defer { timeout.cancel(); control.finished() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            control.waitForStoppedProcessGroup()
            try control.checkCancellation()
            guard process.terminationStatus == 0, data.count <= 1_048_576 else { throw PaceCodingError.invalidProtocol }
            return data
        }
        let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { control.stop(); worker.cancel() }
        guard let servers = try JSONDecoder().decode(PaceMCPJSONValue.self, from: data).codingArray else { throw PaceCodingError.invalidProtocol }
        var config: [String: PaceMCPJSONValue] = [:]
        for server in servers {
            guard let object = server.codingObject, let name = object["name"]?.codingString,
                  name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  let transport = object["transport"]?.codingObject,
                  let kind = transport["type"]?.codingString, ["stdio", "streamable_http"].contains(kind)
            else { throw PaceCodingError.invalidProtocol }
            config["mcp_servers.\(name).enabled"] = .bool(false)
            config["mcp_servers.\(name).\(kind == "stdio" ? "command" : "url")"] =
                .string(kind == "stdio" ? "/usr/bin/false" : "http://127.0.0.1:1")
        }
        return config
    }
}
