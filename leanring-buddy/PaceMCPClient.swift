//
//  PaceMCPClient.swift
//  leanring-buddy
//
//  Minimal stdio MCP bridge. Pace stays the local approval/UI shell while
//  third-party servers own broad app integrations.
//

import Foundation
import MCP
import System

enum PaceMCPClientError: Error, CustomStringConvertible {
    case serverNotConfigured(String)
    case invalidCommand(String)
    case launchFailed(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case rpcError(String)

    var description: String {
        switch self {
        case .serverNotConfigured(let serverName):
            return "MCP server is not configured: \(serverName)"
        case .invalidCommand(let command):
            return "MCP command is not executable: \(command)"
        case .launchFailed(let message):
            return "MCP server launch failed: \(message)"
        case .requestTimedOut(let method):
            return "MCP request timed out: \(method)"
        case .invalidResponse(let message):
            return "MCP server returned an invalid response: \(message)"
        case .rpcError(let message):
            return "MCP server returned an error: \(message)"
        }
    }
}

/// Pure helper that builds the spawn-time `environment` map for an MCP
/// subprocess. Empty values in `serverConfigurationEnvironment` are
/// the sentinel the bundled catalog uses to say "look this one up at
/// spawn time" — see `PaceMCPSecretStore`. The `secretLookup` closure
/// is injected so tests can drive the substitution without touching
/// the real Keychain.
///
/// Layering rule: secrets always win over the base process env, but
/// only when the user has stored one. A missing secret leaves the
/// empty sentinel in place so the subprocess can fail loudly with a
/// clear "missing API key" message rather than silently inheriting an
/// unrelated env var the parent shell happened to set.
nonisolated enum PaceMCPClientEnvironmentBuilder {
    static func buildSpawnEnvironment(
        baseEnvironment: [String: String],
        serverConfigurationEnvironment: [String: String],
        serverSlug: String,
        secretLookup: (_ server: String, _ key: String) -> String?
    ) -> [String: String] {
        var resolvedEnvironment = baseEnvironment
        for (envKey, envValue) in serverConfigurationEnvironment {
            if envValue.isEmpty,
                let storedSecret = secretLookup(serverSlug, envKey)
            {
                resolvedEnvironment[envKey] = storedSecret
            } else {
                resolvedEnvironment[envKey] = envValue
            }
        }
        return resolvedEnvironment
    }
}

nonisolated struct PaceMCPServerConfiguration: Decodable, Equatable {
    let command: String
    let args: [String]
    let workingDirectory: String?
    let env: [String: String]

    enum CodingKeys: String, CodingKey {
        case command
        case args
        case workingDirectory
        case cwd
        case env
    }

    init(
        command: String,
        args: [String] = [],
        workingDirectory: String? = nil,
        env: [String: String] = [:]
    ) {
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try container.decode(String.self, forKey: .command)
        self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        self.workingDirectory =
            try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            ?? container.decodeIfPresent(String.self, forKey: .cwd)
        self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

nonisolated struct PaceMCPToolCall: Equatable, Sendable {
    let serverName: String
    let toolName: String
    let arguments: [String: PaceMCPJSONValue]

    var approvalDescription: String {
        let argumentSummary = arguments.keys.sorted().joined(separator: ", ")
        guard !argumentSummary.isEmpty else {
            return "\(serverName).\(toolName)"
        }
        return "\(serverName).\(toolName) with \(argumentSummary)"
    }
}

nonisolated enum PaceMCPJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PaceMCPJSONValue])
    case array([PaceMCPJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .number(Double(intValue))
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([PaceMCPJSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: PaceMCPJSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported MCP JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.jsonObject)
        case .array(let value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }

}

nonisolated enum PaceMCPServerRegistry {
    private struct RootConfiguration: Decodable {
        let servers: [String: PaceMCPServerConfiguration]?
        let mcpServers: [String: PaceMCPServerConfiguration]?
    }

    static var configurationPaths: [URL] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            homeDirectory.appendingPathComponent(".config/pace/mcp-servers.json"),
            homeDirectory.appendingPathComponent(".pace/mcp-servers.json"),
        ]
    }

    /// Starter config written when the user creates the MCP config from
    /// Settings. Ships apple-mcp (contacts, notes, messages, mail, reminders,
    /// calendar, maps over one stdio server — handshake-verified against
    /// Pace's newline JSON-RPC dialect) so Apple-app breadth works out of the
    /// box; users add further servers by editing the same file (see
    /// mcp-servers.example.json for curated options).
    static let starterConfigurationJSON = """
    {
      "mcpServers": {
        "apple": {
          "command": "npx",
          "args": ["-y", "apple-mcp"]
        }
      }
    }
    """

    static func loadConfiguredServers() -> [String: PaceMCPServerConfiguration] {
        for configurationPath in configurationPaths {
            guard let data = try? Data(contentsOf: configurationPath) else { continue }
            guard let root = try? JSONDecoder().decode(RootConfiguration.self, from: data) else {
                print("⚠️ Pace MCP: could not decode \(configurationPath.path)")
                continue
            }
            let servers = root.mcpServers ?? root.servers ?? [:]
            if !servers.isEmpty {
                return servers
            }
        }
        return [:]
    }
}

nonisolated struct PaceMCPStdioClient {
    private let serverConfigurationsProvider: () -> [String: PaceMCPServerConfiguration]
    private let requestTimeoutInSeconds: TimeInterval

    init(
        serverConfigurations: [String: PaceMCPServerConfiguration]? = nil,
        requestTimeoutInSeconds: TimeInterval = 20
    ) {
        if let serverConfigurations {
            self.serverConfigurationsProvider = { serverConfigurations }
        } else {
            self.serverConfigurationsProvider = PaceMCPServerRegistry.loadConfiguredServers
        }
        self.requestTimeoutInSeconds = requestTimeoutInSeconds
    }

    init(
        serverConfigurationsProvider: @escaping () -> [String: PaceMCPServerConfiguration],
        requestTimeoutInSeconds: TimeInterval = 20
    ) {
        self.serverConfigurationsProvider = serverConfigurationsProvider
        self.requestTimeoutInSeconds = requestTimeoutInSeconds
    }

    var configuredServerNames: [String] {
        serverConfigurationsProvider().keys.sorted()
    }

    func peekabooToolCatalog() async throws -> String {
        try await toolCatalog(
            serverName: "peekaboo",
            allowedNames: [
                "app", "window", "see", "click", "type", "press", "scroll", "set_value", "select_text", "action",
                "menu",
            ])
    }

    func playwrightToolCatalog() async throws -> String {
        try await toolCatalog(
            serverName: "playwright",
            allowedNames: [
                "browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_fill_form",
                "browser_press_key", "browser_tabs", "browser_select_option", "browser_hover", "browser_wait_for",
                "browser_close", "browser_navigate_back", "browser_resize", "browser_drag", "browser_take_screenshot",
            ])
    }

    func toolCatalog(serverName: String) async throws -> String {
        try await toolCatalog(serverName: serverName, allowedNames: nil)
    }

    private func toolCatalog(serverName: String, allowedNames: Set<String>?) async throws -> String {
        guard let configuration = serverConfigurationsProvider()[serverName] else {
            throw PaceMCPClientError.serverNotConfigured(serverName)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try PaceMCPPersistentSessions.shared.request(
                        serverName: serverName, configuration: configuration,
                        method: "tools/list", parameters: [:], timeout: requestTimeoutInSeconds
                    )
                    let tools = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
                    let allowedTools = tools.filter { allowedNames?.contains($0["name"] as? String ?? "") ?? true }
                    let data = try JSONSerialization.data(withJSONObject: allowedTools, options: [.sortedKeys])
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func callTool(_ toolCall: PaceMCPToolCall) async throws -> String {
        let serverConfigurations = serverConfigurationsProvider()
        guard let serverConfiguration = serverConfigurations[toolCall.serverName] else {
            throw PaceMCPClientError.serverNotConfigured(toolCall.serverName)
        }

        let callStartedAt = Date()
        // Estimate the bytes leaving this Mac as the serialized JSON
        // size of the tool args. Cheap to compute, defensible enough
        // for the Privacy Dashboard headline. The tool name and server
        // slug are also sent but they're tiny compared to args, so
        // skip those.
        let estimatedInputCharacterCount: Int = {
            guard !toolCall.arguments.isEmpty,
                  let argumentsData = try? JSONEncoder().encode(toolCall.arguments),
                let argumentsString = String(data: argumentsData, encoding: .utf8)
            else {
                return 0
            }
            return argumentsString.count
        }()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                func auditMCPCall(outcome: String, outputCharacterCount: Int? = nil, detail: String? = nil) {
                    PaceAPIAuditLog.shared.record(
                        subsystem: "mcp",
                        operation: "tools/call",
                        target: "\(toolCall.serverName).\(toolCall.toolName)",
                        durationMilliseconds: Int(Date().timeIntervalSince(callStartedAt) * 1000),
                        outcome: outcome,
                        inputCharacterCount: estimatedInputCharacterCount,
                        outputCharacterCount: outputCharacterCount,
                        detail: detail
                    )
                }
                do {
                    let result = try runSynchronousToolCall(
                        toolCall,
                        serverConfiguration: serverConfiguration,
                        timeoutInSeconds: requestTimeoutInSeconds
                    )
                    auditMCPCall(outcome: "ok", outputCharacterCount: result.count)
                    continuation.resume(returning: result)
                } catch {
                    auditMCPCall(
                        outcome: "error",
                        detail: String(String(describing: error).prefix(160))
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func runSynchronousToolCall(
    _ toolCall: PaceMCPToolCall,
    serverConfiguration: PaceMCPServerConfiguration,
    timeoutInSeconds: TimeInterval
) throws -> String {
    do {
        let response = try PaceMCPPersistentSessions.shared.request(
            serverName: toolCall.serverName, configuration: serverConfiguration,
            method: "tools/call",
            parameters: ["name": toolCall.toolName, "arguments": toolCall.arguments.mapValues(\.jsonObject)],
            timeout: timeoutInSeconds
        )
        let summary = summarizeMCPToolCallResponse(response)
        guard let result = response["result"] as? [String: Any] else { return summary }
        var sections = [summary]
        let evidenceFields =
            ["peekaboo", "playwright"].contains(toolCall.serverName)
            ? ["structuredContent", "_meta"] : ["structuredContent"]
        for field in evidenceFields {
            if let value = result[field], JSONSerialization.isValidJSONObject(value) {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                sections.append("Tool \(field):\n" + String(decoding: data, as: UTF8.self))
            }
        }
        let observationText = sections.joined(separator: "\n")
        if result["isError"] as? Bool == true {
            throw PaceMCPClientError.rpcError(observationText)
        }
        return observationText
    }
}

// Peekaboo snapshots belong to the server process that observed them. Keep
// that process alive across observations/actions; never retry a failed mutation.
private final class PaceMCPPersistentSessions: @unchecked Sendable {
    static let shared = PaceMCPPersistentSessions()
    private let lock = NSLock()
    private var slots: [String: PaceMCPPersistentSessionSlot] = [:]

    private init() {
        atexit { PaceMCPPersistentSessions.shared.closeAll() }
    }

    private func closeAll() {
        lock.lock()
        let currentSlots = Array(slots.values)
        slots.removeAll()
        lock.unlock()
        for slot in currentSlots { slot.close() }
    }

    func request(
        serverName: String, configuration: PaceMCPServerConfiguration,
        method: String, parameters: [String: Any], timeout: TimeInterval
    ) throws -> [String: Any] {
        lock.lock()
        let slot = slots[serverName] ?? PaceMCPPersistentSessionSlot()
        slots[serverName] = slot
        lock.unlock()
        // An OAuth connection must not block an unrelated desktop server.
        return try slot.request(
            serverName: serverName, configuration: configuration,
            method: method, parameters: parameters, timeout: timeout)
    }
}

private final class PaceMCPPersistentSessionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var session: PaceMCPPersistentSession?

    func request(
        serverName: String, configuration: PaceMCPServerConfiguration,
        method: String, parameters: [String: Any], timeout: TimeInterval
    ) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let previous = session, previous.configuration != configuration || !previous.process.isRunning {
            previous.close()
            session = nil
        }
        do {
            if session == nil {
                session = try PaceMCPPersistentSession(
                    serverName: serverName, configuration: configuration, timeout: timeout)
            }
            guard let session else { throw PaceMCPClientError.launchFailed("MCP session unavailable") }
            return try session.request(method: method, parameters: parameters, timeout: timeout)
        } catch {
            session?.close()
            session = nil
            if let rpcError = error as? MCPError {
                throw PaceMCPClientError.rpcError(String(describing: rpcError))
            }
            throw error
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        session?.close()
        session = nil
    }
}

private final class PaceMCPPersistentSession {
    let configuration: PaceMCPServerConfiguration
    let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrHandle: FileHandle
    private let client = MCP.Client(name: "Pace", version: "1.0")

    init(serverName: String, configuration: PaceMCPServerConfiguration, timeout: TimeInterval) throws {
        self.configuration = configuration
        guard let nullHandle = FileHandle(forWritingAtPath: "/dev/null") else {
            throw PaceMCPClientError.launchFailed("Could not open stderr sink")
        }
        stderrHandle = nullHandle
        process.executableURL = try executableURL(for: configuration.command)
        process.arguments = configuration.args
        var runtimeEnvironment = ProcessInfo.processInfo.environment
        runtimeEnvironment["PATH"] =
            (runtimeEnvironment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: runtimeEnvironment,
            serverConfigurationEnvironment: configuration.env, serverSlug: serverName,
            secretLookup: { server, key in PaceMCPSecretStore.loadSecret(server: server, key: key) }
        )
        if let directory = configuration.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrHandle
        do {
            try process.run()
            let transport = MCP.StdioTransport(
                input: .init(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
                output: .init(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
            )
            let client = self.client
            _ = try waitForMCPResult(timeout: timeout) { try await client.connect(transport: transport) }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func request(method: String, parameters: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let client = self.client
        let resultData: Data
        if method == "tools/list" {
            resultData = try waitForMCPResult(timeout: timeout) {
                var tools: [MCP.Tool] = []
                var cursor: String?
                repeat {
                    let page = try await client.listTools(cursor: cursor)
                    tools.append(contentsOf: page.tools)
                    cursor = page.nextCursor
                } while cursor != nil
                return try JSONEncoder().encode(tools)
            }
            return ["result": ["tools": try JSONSerialization.jsonObject(with: resultData)]]
        }
        let name = parameters["name"] as? String ?? ""
        let argumentData = try JSONSerialization.data(withJSONObject: parameters["arguments"] ?? [:])
        let arguments = try JSONDecoder().decode([String: MCP.Value].self, from: argumentData)
        resultData = try waitForMCPResult(timeout: timeout) {
            // Use the full typed result; the convenience tuple drops snapshot metadata.
            let context: MCP.RequestContext<MCP.CallTool.Result> = try await client.callTool(
                name: name, arguments: arguments)
            let result = try await context.value
            return try JSONEncoder().encode(result)
        }
        return ["result": try JSONSerialization.jsonObject(with: resultData)]
    }

    func close() {
        let client = self.client
        Task { await client.disconnect() }
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrHandle.close()
    }
}

nonisolated private final class PaceMCPResultBox<Value: Sendable>: @unchecked Sendable {
    let condition = NSCondition()
    var result: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        condition.lock()
        self.result = result
        condition.signal()
        condition.unlock()
    }
}

private func waitForMCPResult<Value: Sendable>(
    timeout: TimeInterval, operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let box = PaceMCPResultBox<Value>()
    let task = Task.detached {
        let result: Result<Value, Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        box.complete(result)
    }
    let deadline = Date().addingTimeInterval(timeout)
    box.condition.lock()
    defer { box.condition.unlock() }
    while box.result == nil {
        if !box.condition.wait(until: deadline) {
            task.cancel()
            throw PaceMCPClientError.requestTimedOut("SDK request")
        }
    }
    return try box.result!.get()
}

private func executableURL(for command: String) throws -> URL {
    let expandedCommand = NSString(string: command).expandingTildeInPath
    if expandedCommand.contains("/") {
        guard FileManager.default.isExecutableFile(atPath: expandedCommand) else {
            throw PaceMCPClientError.invalidCommand(command)
        }
        return URL(fileURLWithPath: expandedCommand)
    }

    let pathCandidates =
        ((ProcessInfo.processInfo.environment["PATH"] ?? "")
        + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        .split(separator: ":")
        .map(String.init)

    for pathCandidate in pathCandidates {
        let executablePath = URL(fileURLWithPath: pathCandidate).appendingPathComponent(command).path
        if FileManager.default.isExecutableFile(atPath: executablePath) {
            return URL(fileURLWithPath: executablePath)
        }
    }

    throw PaceMCPClientError.invalidCommand(command)
}

private func sendJSONRPCMessage(_ jsonObject: [String: Any], to stdinHandle: FileHandle) throws {
    let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    var newlineTerminatedData = data
    newlineTerminatedData.append(0x0A)
    try stdinHandle.write(contentsOf: newlineTerminatedData)
}

private func readJSONRPCResponse(
    id expectedID: Int,
    from stdoutReader: PaceMCPLineReader,
    timeoutInSeconds: TimeInterval
) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeoutInSeconds)

    while Date() < deadline {
        for lineData in stdoutReader.drainLines() {
            guard !lineData.isEmpty else { continue }
            guard let jsonObject = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let errorObject = jsonObject["error"] as? [String: Any] {
                throw PaceMCPClientError.rpcError(formatJSONRPCError(errorObject))
            }

            guard let responseID = jsonObject["id"] as? Int, responseID == expectedID else {
                continue
            }

            return jsonObject
        }

        Thread.sleep(forTimeInterval: 0.01)
    }

    throw PaceMCPClientError.requestTimedOut("id \(expectedID)")
}

private final class PaceMCPLineReader {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        self.fileHandle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
    }

    func stop() {
        fileHandle.readabilityHandler = nil
    }

    func drainLines() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let currentLines = lines
        lines.removeAll()
        return currentLines
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            lines.append(lineData)
        }
    }
}

private func formatJSONRPCError(_ errorObject: [String: Any]) -> String {
    let codeText = (errorObject["code"] as? Int).map { "\($0): " } ?? ""
    let messageText = errorObject["message"] as? String ?? "Unknown error"
    return "\(codeText)\(messageText)"
}

private func summarizeMCPToolCallResponse(_ response: [String: Any]) -> String {
    guard let result = response["result"] as? [String: Any] else {
        return "MCP tool completed."
    }

    if let isError = result["isError"] as? Bool, isError {
        return "MCP tool reported an error: \(extractMCPContentText(from: result))"
    }

    let contentText = extractMCPContentText(from: result)
    guard !contentText.isEmpty else {
        return "MCP tool completed."
    }
    return contentText
}

private func extractMCPContentText(from result: [String: Any]) -> String {
    guard let contentArray = result["content"] as? [[String: Any]] else {
        return ""
    }

    return
        contentArray
        .compactMap { contentItem in
            contentItem["text"] as? String
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}
