//
//  PaceFlowReplay.swift
//  leanring-buddy
//
//  Local JSON store and voice-command parser for demonstration replay.
//  The recorder/replayer runtime can build on this without changing the
//  on-disk contract.
//

import Foundation

struct PaceRecordedFlow: Codable, Equatable, Identifiable {
    let name: String
    let createdAt: Date
    var steps: [PaceRecordedStep]

    var id: String { name }
}

enum PaceRecordedStep: Codable, Equatable {
    case activateApp(bundleIdentifier: String)
    case axPress(rolePath: [String], label: String)
    case typeText(text: String, secure: Bool)
    case keyShortcut(key: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIdentifier
        case rolePath
        case label
        case text
        case secure
        case key
    }

    private enum Kind: String, Codable {
        case activateApp
        case axPress
        case typeText
        case keyShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .activateApp:
            self = .activateApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case .axPress:
            self = .axPress(
                rolePath: try container.decode([String].self, forKey: .rolePath),
                label: try container.decode(String.self, forKey: .label)
            )
        case .typeText:
            self = .typeText(
                text: try container.decode(String.self, forKey: .text),
                secure: try container.decode(Bool.self, forKey: .secure)
            )
        case .keyShortcut:
            self = .keyShortcut(key: try container.decode(String.self, forKey: .key))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .activateApp(let bundleIdentifier):
            try container.encode(Kind.activateApp, forKey: .kind)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        case .axPress(let rolePath, let label):
            try container.encode(Kind.axPress, forKey: .kind)
            try container.encode(rolePath, forKey: .rolePath)
            try container.encode(label, forKey: .label)
        case .typeText(let text, let secure):
            try container.encode(Kind.typeText, forKey: .kind)
            try container.encode(secure ? "<password redacted>" : text, forKey: .text)
            try container.encode(secure, forKey: .secure)
        case .keyShortcut(let key):
            try container.encode(Kind.keyShortcut, forKey: .kind)
            try container.encode(key, forKey: .key)
        }
    }
}

struct PaceFlowStore {
    static var defaultDirectoryURL: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupportURL.appendingPathComponent("Pace/flows", isDirectory: true)
    }

    let directoryURL: URL

    init(directoryURL: URL = PaceFlowStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    func save(_ flow: PaceRecordedFlow) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(flow)
        try data.write(to: fileURL(for: flow.name), options: .atomic)
    }

    func load(named name: String) -> PaceRecordedFlow? {
        guard let data = try? Data(contentsOf: fileURL(for: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PaceRecordedFlow.self, from: data)
    }

    func delete(named name: String) throws {
        let url = fileURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func listAll() -> [PaceRecordedFlow] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { fileURL -> PaceRecordedFlow? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode(PaceRecordedFlow.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func fileURL(for name: String) -> URL {
        directoryURL.appendingPathComponent(Self.slug(for: name)).appendingPathExtension("json")
    }

    static func slug(for name: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let loweredName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = loweredName.unicodeScalars.map { scalar -> Character in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "flow" : collapsed
    }
}

enum PaceFlowCommand: Equatable {
    case startRecording(name: String)
    case stopRecording
    case run(name: String)
    case delete(name: String)
}

enum PaceFlowCommandParser {
    static func parse(_ transcript: String) -> PaceFlowCommand? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = trimmedTranscript.lowercased()
        guard !normalizedTranscript.isEmpty else { return nil }

        if normalizedTranscript == "stop recording" || normalizedTranscript == "i'm done" {
            return .stopRecording
        }

        for prefix in ["remember this flow as ", "remember this as ", "save this as a flow called "] {
            if normalizedTranscript.hasPrefix(prefix) {
                let name = String(trimmedTranscript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : .startRecording(name: name)
            }
        }

        for prefix in ["delete the flow ", "forget the flow "] {
            if normalizedTranscript.hasPrefix(prefix) {
                let name = String(trimmedTranscript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : .delete(name: name)
            }
        }

        for prefix in ["run ", "play back ", "do "] {
            if normalizedTranscript.hasPrefix(prefix) {
                let name = String(trimmedTranscript.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : .run(name: name)
            }
        }

        return nil
    }
}

struct PaceFlowRecorder {
    private(set) var activeFlowName: String?
    private(set) var steps: [PaceRecordedStep] = []

    var isRecording: Bool {
        activeFlowName != nil
    }

    mutating func startRecording(name: String) {
        activeFlowName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        steps = []
    }

    mutating func record(_ step: PaceRecordedStep) {
        guard isRecording else { return }
        steps.append(step)
    }

    mutating func stopRecording(now: Date = Date()) -> PaceRecordedFlow? {
        guard let activeFlowName, !activeFlowName.isEmpty else {
            self.activeFlowName = nil
            steps = []
            return nil
        }
        let flow = PaceRecordedFlow(name: activeFlowName, createdAt: now, steps: steps)
        self.activeFlowName = nil
        steps = []
        return flow
    }
}

enum PaceFlowReplayPlanner {
    static func shouldPauseBeforeSend(step: PaceRecordedStep, isLastStep: Bool) -> Bool {
        guard isLastStep else { return false }
        guard case .axPress(_, let label) = step else { return false }
        let normalizedLabel = label.lowercased()
        return ["send", "submit", "post", "reply"].contains { sendWord in
            normalizedLabel == sendWord || normalizedLabel.contains(sendWord)
        }
    }

    static func replayObservations(for flow: PaceRecordedFlow) -> [String] {
        flow.steps.enumerated().map { index, step in
            if shouldPauseBeforeSend(step: step, isLastStep: index == flow.steps.count - 1) {
                return "ready to send - say go ahead"
            }
            switch step {
            case .activateApp(let bundleIdentifier):
                return "activate \(bundleIdentifier)"
            case .axPress(_, let label):
                return "press \(label)"
            case .typeText(let text, let secure):
                return secure ? "type secure text" : "type \(text.count) characters"
            case .keyShortcut(let key):
                return "press \(key)"
            }
        }
    }
}
