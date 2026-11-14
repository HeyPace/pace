import Foundation

nonisolated struct PaceCodingSessionID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

nonisolated struct PaceCodexThreadID: Hashable, Codable, Sendable { let rawValue: String }
nonisolated struct PaceCodexTurnID: Hashable, Codable, Sendable { let rawValue: String }

nonisolated enum PaceCodingSessionCommand: Equatable, Sendable {
    case start(directory: String, task: String)
    case resume(sessionID: PaceCodingSessionID, task: String)
    case status(sessionID: PaceCodingSessionID?)
    case cancel(sessionID: PaceCodingSessionID?)

    var requiresExecutionConsent: Bool {
        switch self { case .start, .resume: return true; case .status, .cancel: return false }
    }

    var summary: String {
        switch self {
        case .start(let directory, let task): return "Start retained coding in \(directory): \(task)"
        case .resume(let identifier, let task): return "Resume coding \(identifier.rawValue): \(task)"
        case .status: return "Read retained coding status"
        case .cancel: return "Cancel retained coding work"
        }
    }

    static func parse(_ arguments: [String: PaceMCPJSONValue]) -> Self? {
        func string(_ key: String) -> String? {
            guard case .string(let value) = arguments[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        func identifier() -> PaceCodingSessionID? {
            string("sessionID").flatMap(UUID.init(uuidString:)).map(PaceCodingSessionID.init)
        }
        let keys = Set(arguments.keys).subtracting(["tool"])
        switch string("operation") {
        case "start":
            guard keys == ["operation", "directory", "task"], let directory = string("directory"),
                  directory.hasPrefix("/") || directory.hasPrefix("~/"), let task = string("task") else { return nil }
            return .start(directory: directory, task: task)
        case "resume":
            guard keys == ["operation", "sessionID", "task"], let identifier = identifier(), let task = string("task") else { return nil }
            return .resume(sessionID: identifier, task: task)
        case "status":
            guard keys.isSubset(of: ["operation", "sessionID"]), arguments["sessionID"] == nil || identifier() != nil else { return nil }
            return .status(sessionID: identifier())
        case "cancel":
            guard keys == ["operation", "sessionID"], let identifier = identifier() else { return nil }
            return .cancel(sessionID: identifier)
        default: return nil
        }
    }

    static func localControl(_ transcript: String) -> Self? {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["coding status", "coding session status", "how is the coding task going", "list coding sessions", "status of coding task"].contains(normalized) {
            return .status(sessionID: nil)
        }
        if ["cancel coding", "cancel coding task", "cancel that coding task", "stop coding", "stop coding task"].contains(normalized) {
            return .cancel(sessionID: nil)
        }
        for (prefix, cancel) in [("cancel coding session ", true), ("stop coding session ", true), ("coding status ", false), ("status coding session ", false)] {
            if normalized.hasPrefix(prefix), let uuid = UUID(uuidString: String(normalized.dropFirst(prefix.count))) {
                return cancel ? .cancel(sessionID: .init(uuid)) : .status(sessionID: .init(uuid))
            }
        }
        return nil
    }
}

nonisolated enum PaceCodingSessionState: String, Codable, Sendable {
    case ready, starting, running, awaitingApproval, cancelling, completed, interrupted, failed, needsResume
    var isBusy: Bool { [.starting, .running, .awaitingApproval, .cancelling].contains(self) }
}

nonisolated struct PaceCodingSessionSnapshot: Codable, Equatable, Sendable {
    let id: PaceCodingSessionID
    let directory: URL
    let threadID: PaceCodexThreadID
    var lastTurnID: PaceCodexTurnID?
    var conversationTurnIdentifier: String?
    var state: PaceCodingSessionState
    var updatedAt: Date

    var summary: String {
        "Coding session \(id.rawValue.uuidString) · \(directory.path) · \(state.rawValue)"
    }
}

nonisolated enum PaceCodingSessionEvent: Sendable {
    case changed(PaceCodingSessionSnapshot)
    case conversation(ConversationEvent)
}

nonisolated enum PaceCodingError: Error, LocalizedError {
    case unavailable, invalidWorkspace, workspaceChanged, busy, missingSession, ambiguousSession, invalidProtocol, unsafePolicy, disconnected, timedOut, permissionDenied, persistence
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex is not available on PATH."
        case .invalidWorkspace: return "Choose an existing absolute workspace directory."
        case .workspaceChanged: return "The retained workspace identity changed. Start a new coding session."
        case .busy: return "This coding session is already busy. Use status or explicitly cancel it."
        case .missingSession: return "No matching retained coding session exists."
        case .ambiguousSession: return "More than one coding session matches. Specify its session ID."
        case .invalidProtocol: return "Codex returned an invalid coding protocol response."
        case .unsafePolicy: return "Codex did not confirm the required workspace-only, offline, user-reviewed policy. No task was started."
        case .disconnected: return "The owned Codex process disconnected. Explicitly resume to reconcile the retained thread."
        case .timedOut: return "Codex did not confirm completion in time. Check status before resuming."
        case .permissionDenied: return "Coding requires EnableActions and current Codex off-device consent."
        case .persistence: return "Coding session state could not be saved safely. No further task was started."
        }
    }
}

nonisolated extension PaceMCPJSONValue {
    var codingObject: [String: Self]? { if case .object(let object) = self { return object }; return nil }
    var codingString: String? { if case .string(let string) = self { return string }; return nil }
    var codingArray: [Self]? { if case .array(let array) = self { return array }; return nil }
}
