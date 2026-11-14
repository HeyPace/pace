import Foundation

actor PaceCodingSessionCoordinator {
    typealias TransportFactory = @Sendable (URL) -> any PaceCodingTransport
    typealias EventSink = @Sendable (PaceCodingSessionEvent) async -> Void
    typealias Approval = @Sendable (PaceActionApprovalRequest) async -> PaceActionApprovalDecision
    private let store: PaceCodingSessionStore
    private let transportFactory: TransportFactory
    private let eventSink: EventSink
    private let approve: Approval
    private var sessions: [PaceCodingSessionID: PaceCodingSessionSnapshot] = [:]
    private var loaded = false
    private var transport: (any PaceCodingTransport)?
    private var transportGeneration = UUID()
    private var opening: Task<Void, any Error>?
    private var eventTask: Task<Void, Never>?
    private var reservedWorkspaces: Set<URL> = []
    private var pendingCancellations: Set<PaceCodingSessionID> = []
    private var startingThreads: Set<PaceCodexThreadID> = []
    private var earlyMessages: [PaceCodexThreadID: [[String: PaceMCPJSONValue]]] = [:]
    private var seenItemIDs: Set<String> = []
    private var completedMessages: [PaceCodingSessionID: [String]] = [:]
    private var fileChanges: [String: [String]] = [:]
    private var resolvedApprovalIDs: Set<String> = []
    private var pendingApprovals: [String: Task<Void, Never>] = [:]
    private var approvalSessionIDs: [String: PaceCodingSessionID] = [:]
    private var pendingApprovalIDs: [String: PaceMCPJSONValue] = [:]

    init(store: PaceCodingSessionStore = .init(),
         transportFactory: @escaping TransportFactory = { PaceCodingAppServerTransport(workingDirectory: $0) },
         eventSink: @escaping EventSink,
         approve: @escaping Approval) {
        self.store = store
        self.transportFactory = transportFactory
        self.eventSink = eventSink
        self.approve = approve
    }

    func execute(_ command: PaceCodingSessionCommand, conversationTurnIdentifier: String?, authorized: Bool) async throws -> String {
        try loadIfNeeded()
        if command.requiresExecutionConsent, !authorized { throw PaceCodingError.permissionDenied }
        switch command {
        case .status(let identifier):
            let matches = identifier.map { identifier in sessions.values.filter { $0.id == identifier } } ?? Array(sessions.values)
            guard !matches.isEmpty else { return "No retained coding sessions." }
            return matches.sorted { $0.updatedAt > $1.updatedAt }.map(\.summary).joined(separator: "\n")
        case .cancel(let identifier):
            let session = try resolve(identifier, busyOnly: identifier == nil)
            guard session.state.isBusy else { return session.summary + ". No owned job is running." }
            if session.state == .starting || startingThreads.contains(session.threadID) {
                pendingCancellations.insert(session.id)
                try await change(session.id, state: .cancelling)
                return "Coding session \(session.id.rawValue) cancellation is requested. Waiting for its turn identity and terminal confirmation."
            }
            guard let transport, let turnID = session.lastTurnID else {
                try await change(session.id, state: .needsResume)
                return session.summary + ". Disconnected; no terminal interruption confirmation."
            }
            await denyApprovals(for: session)
            try await change(session.id, state: .cancelling)
            _ = try await transport.request("turn/interrupt", params: ["threadId": .string(session.threadID.rawValue), "turnId": .string(turnID.rawValue)])
            // The RPC acknowledgement is not terminal. Notifications remain the state authority.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if let current = sessions[session.id], !current.state.isBusy { return current.summary }
                try await Task.sleep(for: .milliseconds(40))
            }
            return "Coding session \(session.id.rawValue) is cancelling. Codex has not confirmed terminal interruption."
        case .start(let directory, let task):
            guard sessions.count < 200 else { throw PaceCodingError.persistence }
            let workspace = try Self.workspace(directory)
            guard !reservedWorkspaces.contains(workspace), !sessions.values.contains(where: { $0.directory == workspace && $0.state.isBusy }) else { throw PaceCodingError.busy }
            reservedWorkspaces.insert(workspace)
            defer { reservedWorkspaces.remove(workspace) }
            let transport = try await ensureTransport(cwd: workspace)
            let response = try await transport.request("thread/start", params: Self.threadParameters(cwd: workspace).merging(["ephemeral": .bool(false)]) { _, new in new })
            let result = try Self.validatePolicy(response, cwd: workspace)
            guard let thread = result["thread"]?.codingObject, let threadID = thread["id"]?.codingString else { throw PaceCodingError.invalidProtocol }
            let snapshot = PaceCodingSessionSnapshot(id: .init(), directory: workspace,
                threadID: .init(rawValue: threadID), lastTurnID: nil,
                conversationTurnIdentifier: conversationTurnIdentifier, state: .ready, updatedAt: Date())
            sessions[snapshot.id] = snapshot
            try persist()
            await eventSink(.changed(snapshot))
            return try await startTurn(snapshot, task: task, conversationTurnIdentifier: conversationTurnIdentifier, transport: transport)
        case .resume(let identifier, let task):
            var session = try resolve(identifier)
            guard !session.state.isBusy, !reservedWorkspaces.contains(session.directory) else { throw PaceCodingError.busy }
            guard try Self.workspace(session.directory.path) == session.directory else { throw PaceCodingError.workspaceChanged }
            reservedWorkspaces.insert(session.directory)
            defer { reservedWorkspaces.remove(session.directory) }
            let transport = try await ensureTransport(cwd: session.directory)
            // Read without executing. A lost running record never replays its original task.
            let read = try await transport.request("thread/read", params: ["threadId": .string(session.threadID.rawValue), "includeTurns": .bool(true)])
            guard let thread = read.codingObject?["thread"]?.codingObject, thread["id"]?.codingString == session.threadID.rawValue,
                  thread["cwd"]?.codingString == session.directory.path else { throw PaceCodingError.workspaceChanged }
            if let turns = thread["turns"]?.codingArray, turns.contains(where: { $0.codingObject?["status"]?.codingString == "inProgress" }) { throw PaceCodingError.busy }
            let response = try await transport.request("thread/resume", params: Self.threadParameters(cwd: session.directory).merging(["threadId": .string(session.threadID.rawValue)]) { _, new in new })
            let resumed = try Self.validatePolicy(response, cwd: session.directory)
            guard resumed["thread"]?.codingObject?["id"]?.codingString == session.threadID.rawValue else { throw PaceCodingError.invalidProtocol }
            session.state = .ready
            sessions[identifier] = session
            try persist()
            return try await startTurn(session, task: task, conversationTurnIdentifier: conversationTurnIdentifier, transport: transport)
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        var stored = try store.load()
        for index in stored.indices where stored[index].state.isBusy {
            stored[index].state = .needsResume
            stored[index].updatedAt = Date()
        }
        sessions = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        try persist()
        loaded = true
    }

    private func persist() throws {
        do { try store.save(Array(sessions.values)) } catch { throw PaceCodingError.persistence }
    }

    private func resolve(_ identifier: PaceCodingSessionID?, busyOnly: Bool = false) throws -> PaceCodingSessionSnapshot {
        if let identifier { guard let session = sessions[identifier] else { throw PaceCodingError.missingSession }; return session }
        let matches = sessions.values.filter { !busyOnly || $0.state.isBusy }
        guard !matches.isEmpty else { throw PaceCodingError.missingSession }
        guard matches.count == 1 else { throw PaceCodingError.ambiguousSession }
        return matches.first!
    }

    private func ensureTransport(cwd: URL) async throws -> any PaceCodingTransport {
        if let transport {
            if let opening { try await opening.value }
            return transport
        }
        let candidate = transportFactory(cwd)
        let generation = UUID()
        transportGeneration = generation
        transport = candidate
        let events = await candidate.events()
        eventTask = Task { [weak self] in
            for await event in events { await self?.receive(event, generation: generation) }
        }
        let opening = Task { try await candidate.open() }
        self.opening = opening
        do {
            try await opening.value
            self.opening = nil
            return candidate
        } catch {
            self.opening = nil
            transport = nil
            await candidate.shutdown()
            throw error
        }
    }

    private func startTurn(_ original: PaceCodingSessionSnapshot, task: String, conversationTurnIdentifier: String?, transport: any PaceCodingTransport) async throws -> String {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.count <= 100_000 else { throw PaceCodingError.invalidProtocol }
        try await change(original.id, state: .starting)
        startingThreads.insert(original.threadID)
        defer { startingThreads.remove(original.threadID); earlyMessages.removeValue(forKey: original.threadID) }
        do {
            let response = try await transport.request("turn/start", params: [
                "threadId": .string(original.threadID.rawValue),
                "input": .array([.object(["type": .string("text"), "text": .string(task)])]),
                "cwd": .string(original.directory.path), "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"), "sandboxPolicy": Self.sandbox(original.directory),
            ])
            guard let turn = response.codingObject?["turn"]?.codingObject, let turnID = turn["id"]?.codingString else { throw PaceCodingError.invalidProtocol }
            var session = original
            session.lastTurnID = .init(rawValue: turnID)
            session.conversationTurnIdentifier = conversationTurnIdentifier
            session.state = pendingCancellations.contains(session.id) ? .cancelling : .running
            session.updatedAt = Date()
            sessions[session.id] = session
            completedMessages[session.id] = []
            try persist()
            await eventSink(.changed(session))
            if pendingCancellations.remove(session.id) != nil {
                _ = try await transport.request("turn/interrupt", params: ["threadId": .string(session.threadID.rawValue), "turnId": .string(turnID)])
            }
            while let queued = earlyMessages.removeValue(forKey: original.threadID), !queued.isEmpty {
                for message in queued { await handle(message, bypassingStartGate: true) }
            }
            startingThreads.remove(original.threadID)
            return (sessions[session.id] ?? session).summary
        } catch {
            pendingCancellations.remove(original.id)
            await transport.shutdown()
            try? await change(original.id, state: .needsResume)
            throw error
        }
    }

    private func receive(_ event: PaceCodingTransportEvent, generation: UUID) async {
        guard generation == transportGeneration else { return }
        switch event {
        case .disconnected:
            transport = nil
            for session in Array(sessions.values) where session.state.isBusy {
                try? await change(session.id, state: .needsResume)
                if let turnID = session.lastTurnID {
                    await eventSink(.conversation(ConversationEvent(eventID: "coding-disconnected-" + session.threadID.rawValue + "/" + turnID.rawValue,
                        turnID: session.conversationTurnIdentifier, role: .pace, origin: .failure,
                        text: session.summary + ". Codex disconnected. Explicit resume is required; completion is unverified.", deliveryState: .interrupted)))
                }
            }
            for approval in pendingApprovals.values { approval.cancel() }
            pendingApprovals.removeAll(); pendingApprovalIDs.removeAll(); approvalSessionIDs.removeAll()
        case .message(let message): await handle(message)
        }
    }

    private func handle(_ message: [String: PaceMCPJSONValue], bypassingStartGate: Bool = false) async {
        guard let method = message["method"]?.codingString, let params = message["params"]?.codingObject else {
            if let requestID = message["id"] { try? await transport?.reply(id: requestID, result: nil, error: "Pace rejects malformed server requests.") }
            return
        }
        guard let threadID = params["threadId"]?.codingString else {
            if let requestID = message["id"] { try? await transport?.reply(id: requestID, result: nil, error: "Pace rejects unscoped server requests.") }
            return
        }
        let typedThreadID = PaceCodexThreadID(rawValue: threadID)
        if !bypassingStartGate, startingThreads.contains(typedThreadID) {
            var queued = earlyMessages[typedThreadID, default: []]
            guard queued.count < 200 else { await shutdown(); return }
            queued.append(message); earlyMessages[typedThreadID] = queued; return
        }
        guard let session = sessions.values.first(where: { $0.threadID == typedThreadID }), session.state.isBusy,
              let turnID = session.lastTurnID,
              (params["turnId"]?.codingString ?? params["turn"]?.codingObject?["id"]?.codingString) == turnID.rawValue else {
            if let requestID = message["id"] { try? await transport?.reply(id: requestID, result: nil, error: "Pace rejects stale or unowned turns.") }
            return
        }
        if let requestID = message["id"] {
            await requestApproval(method, params: params, requestID: requestID, session: session)
            return
        }
        if ["item/started", "item/completed"].contains(method), let item = params["item"]?.codingObject, let itemID = item["id"]?.codingString {
            let identity = threadID + "/" + turnID.rawValue + "/" + itemID
            if item["type"]?.codingString == "fileChange", let changes = item["changes"]?.codingArray {
                fileChanges[identity] = changes.compactMap { $0.codingObject?["path"]?.codingString }
            }
            guard method == "item/completed", seenItemIDs.insert(identity).inserted else { return }
            if item["type"]?.codingString == "agentMessage", let text = item["text"]?.codingString, !text.isEmpty {
                completedMessages[session.id, default: []].append(String(text.prefix(40_000)))
                if item["phase"]?.codingString == "commentary" {
                    await eventSink(.conversation(ConversationEvent(eventID: "coding-progress-" + identity,
                        turnID: session.conversationTurnIdentifier, role: .pace, origin: .progress,
                        text: text, deliveryState: .completed)))
                }
            }
        } else if method == "turn/completed", let turn = params["turn"]?.codingObject,
                  let status = turn["status"]?.codingString, ["completed", "interrupted", "failed"].contains(status) {
            await denyApprovals(for: session)
            let state: PaceCodingSessionState = status == "completed" ? .completed : status == "interrupted" ? .interrupted : .failed
            do { try await change(session.id, state: state) }
            catch { try? await change(session.id, state: .needsResume); return }
            let text = status == "completed" ? (completedMessages[session.id]?.last ?? "Coding turn completed. Ask for status or resume this session.")
                : "Coding session \(session.id.rawValue.uuidString) \(status)."
            completedMessages.removeValue(forKey: session.id)
            await eventSink(.conversation(ConversationEvent(eventID: "coding-final-" + threadID + "/" + turnID.rawValue,
                turnID: session.conversationTurnIdentifier, role: .pace, origin: .assistant, text: text,
                deliveryState: status == "interrupted" ? .interrupted : .completed)))
        }
    }

    private func requestApproval(_ method: String, params: [String: PaceMCPJSONValue], requestID: PaceMCPJSONValue, session: PaceCodingSessionSnapshot) async {
        guard let transport else { return }
        let identifier = (try? JSONEncoder().encode(requestID)).flatMap { String(data: $0, encoding: .utf8) } ?? "invalid"
        guard pendingApprovals[identifier] == nil, !resolvedApprovalIDs.contains(identifier) else {
            try? await transport.reply(id: requestID, result: nil, error: "Pace rejects duplicate approval IDs.")
            return
        }
        let recognized = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method)
        let forbiddenKeys = ["networkApprovalContext", "proposedNetworkPolicyAmendments", "proposedExecpolicyAmendment", "additionalPermissions", "grantRoot"]
        let hasElevation = forbiddenKeys.contains { params[$0] != nil && params[$0] != .null }
        var detail: String?
        if recognized, !hasElevation, session.state != .cancelling {
            if method == "item/commandExecution/requestApproval", params["kind"] == .string("humanCommand"),
               let command = params["command"]?.codingString,
               let cwd = params["cwd"]?.codingString, Self.isWithinWorkspace(cwd, workspace: session.directory) {
                detail = "Command: \(command)\nWorking directory: \(cwd)"
            } else if method == "item/fileChange/requestApproval", let itemID = params["itemId"]?.codingString,
                      let turnID = session.lastTurnID,
                      let paths = fileChanges[session.threadID.rawValue + "/" + turnID.rawValue + "/" + itemID],
                      !paths.isEmpty, paths.allSatisfy({ Self.isWithinWorkspace($0, workspace: session.directory) }) {
                detail = "Change files:\n" + paths.joined(separator: "\n")
            }
        }
        guard let detail, let approval = PaceActionApprovalRequest(
            approvalSummary: detail + "\nReason: " + (params["reason"]?.codingString ?? "Codex requests this exact action."),
            preflightSummary: "Coding session \(session.id.rawValue). Workspace \(session.directory.path). This approves only the displayed managed checkpoint or file changes. No session permission or policy change is granted.",
            requiresActionApproval: true) else {
            if recognized { try? await transport.reply(id: requestID, result: .object(["decision": .string("cancel")]), error: nil) }
            else { try? await transport.reply(id: requestID, result: nil, error: "Pace rejects this server request.") }
            return
        }
        try? await change(session.id, state: .awaitingApproval)
        approvalSessionIDs[identifier] = session.id
        pendingApprovalIDs[identifier] = requestID
        pendingApprovals[identifier] = Task { [weak self, approve] in
            let decision = await approve(approval)
            await self?.finishApproval(identifier, session: session, decision: decision)
        }
    }

    private func finishApproval(_ identifier: String, session: PaceCodingSessionSnapshot, decision: PaceActionApprovalDecision) async {
        guard let requestID = pendingApprovalIDs.removeValue(forKey: identifier) else { return }
        pendingApprovals.removeValue(forKey: identifier)
        resolvedApprovalIDs.insert(identifier)
        approvalSessionIDs.removeValue(forKey: identifier)
        let current = sessions[session.id]
        let accepted = decision == .allowOnce && current?.lastTurnID == session.lastTurnID && current?.state == .awaitingApproval
        try? await transport?.reply(id: requestID, result: .object(["decision": .string(accepted ? "accept" : "cancel")]), error: nil)
        if current?.state == .awaitingApproval, !approvalSessionIDs.values.contains(session.id) {
            try? await change(session.id, state: .running)
        }
    }

    private func denyApprovals(for session: PaceCodingSessionSnapshot) async {
        let matching = approvalSessionIDs.filter { $0.value == session.id }.map(\.key)
        for identifier in matching {
            pendingApprovals.removeValue(forKey: identifier)?.cancel()
            if let requestID = pendingApprovalIDs.removeValue(forKey: identifier) {
                try? await transport?.reply(id: requestID, result: .object(["decision": .string("cancel")]), error: nil)
            }
            approvalSessionIDs.removeValue(forKey: identifier)
        }
    }

    func dismissApprovals() async {
        for session in sessions.values where session.state == .awaitingApproval {
            await denyApprovals(for: session)
            if let turnID = session.lastTurnID {
                try? await change(session.id, state: .cancelling)
                _ = try? await transport?.request("turn/interrupt", params: ["threadId": .string(session.threadID.rawValue), "turnId": .string(turnID.rawValue)])
            }
        }
    }

    func shutdown() async {
        await dismissApprovals()
        for session in Array(sessions.values) where session.state.isBusy { try? await change(session.id, state: .needsResume) }
        await transport?.shutdown()
        transport = nil
        eventTask?.cancel(); eventTask = nil
    }

    private func change(_ identifier: PaceCodingSessionID, state: PaceCodingSessionState) async throws {
        guard var session = sessions[identifier] else { throw PaceCodingError.missingSession }
        session.state = state; session.updatedAt = Date(); sessions[identifier] = session
        try persist()
        await eventSink(.changed(session))
    }

    nonisolated static func workspace(_ directory: String) throws -> URL {
        let expanded = (directory as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw PaceCodingError.invalidWorkspace }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              url.path != "/", url != FileManager.default.homeDirectoryForCurrentUser else { throw PaceCodingError.invalidWorkspace }
        return url
    }

    nonisolated static func isWithinWorkspace(_ path: String, workspace: URL) -> Bool {
        let candidate = URL(fileURLWithPath: path, relativeTo: workspace).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == workspace.path || candidate.hasPrefix(workspace.path + "/")
    }

    private nonisolated static func sandbox(_ cwd: URL) -> PaceMCPJSONValue {
        .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(cwd.path)]),
            "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(true), "excludeSlashTmp": .bool(true)])
    }

    private nonisolated static func threadParameters(cwd: URL) -> [String: PaceMCPJSONValue] {
        ["cwd": .string(cwd.path), "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
         "sandbox": .string("workspace-write"), "config": .object([
            "sandbox_workspace_write": .object(["writable_roots": .array([.string(cwd.path)]),
                "network_access": .bool(false), "exclude_tmpdir_env_var": .bool(true), "exclude_slash_tmp": .bool(true)])])]
    }

    private nonisolated static func validatePolicy(_ response: PaceMCPJSONValue, cwd: URL) throws -> [String: PaceMCPJSONValue] {
        guard let object = response.codingObject, object["cwd"]?.codingString == cwd.path,
              object["approvalPolicy"] == .string("on-request"), object["approvalsReviewer"] == .string("user"),
              let sandbox = object["sandbox"]?.codingObject, sandbox["type"] == .string("workspaceWrite"),
              sandbox["networkAccess"] == .bool(false), sandbox["excludeTmpdirEnvVar"] == .bool(true),
              sandbox["excludeSlashTmp"] == .bool(true), let roots = sandbox["writableRoots"]?.codingArray,
              roots.allSatisfy({ $0.codingString == cwd.path }) else { throw PaceCodingError.unsafePolicy }
        return object
    }
}
