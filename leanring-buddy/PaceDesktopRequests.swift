import AppKit
import CryptoKit
import Foundation

nonisolated struct PaceBrowserOpenRequest: Equatable, Sendable {
    let browserName: String
    let url: String?
    let chromeProfile: String?

    static func profileDirectory(for requestedProfile: String?, savedProfile: String?) -> String? {
        guard let requestedProfile else { return savedProfile }
        let normalizedProfile = requestedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["work", "work profile", "preferred", "my work profile"].contains(normalizedProfile.lowercased()) {
            return savedProfile
        }
        guard
            normalizedProfile == "Default"
                || normalizedProfile.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return normalizedProfile
    }
}

nonisolated enum PaceScreenCaptureKind: String, Sendable {
    case screenshot
    case recording

    var arguments: [String] {
        ["-i", "-U", "-J", self == .recording ? "video" : "selection", "-p"]
    }
}

nonisolated struct PaceCodexSessionRequest: Equatable, Sendable {
    let directory: String

    func resolvedDirectory() -> URL? {
        let expandedDirectory = (directory as NSString).expandingTildeInPath
        guard expandedDirectory.hasPrefix("/"), !expandedDirectory.contains("{{") else { return nil }
        let directoryURL = URL(fileURLWithPath: expandedDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return directoryURL
    }

    static func warpConfiguration(directory: URL, executable: URL) throws -> String {
        // JSON strings are valid TOML basic strings. Shell-quote the fixed
        // executable separately; the directory never enters shell code.
        func quoted(_ value: String) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self)
        }
        let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
            name = "Pace Codex"
            [[panes]]
            id = "codex"
            type = "terminal"
            directory = \(try quoted(directory.path))
            commands = [\(try quoted(command))]
            shell = "zsh"
            is_focused = true
            """
    }
}

@MainActor
extension PaceActionExecutor {
    func startCodexSession(_ request: PaceCodexSessionRequest) -> PaceActionExecutionObservation {
        guard actionsAreEnabled else {
            return .init(toolName: "codex_session", summary: "Would open Codex in Warp at \(request.directory).")
        }
        guard let directory = request.resolvedDirectory() else {
            return .init(
                toolName: "codex_session",
                summary: "Could not find folder: \(request.directory). Specify an existing absolute path or ~/ path.")
        }
        guard Self.findApplicationURL(named: "Warp") != nil,
            let executable = PaceLocalCLIPlannerClient.resolveExecutable(named: "codex")
        else {
            return .init(
                toolName: "codex_session",
                summary: "Could not start session: Warp and Codex CLI must both be installed.")
        }
        do {
            let configurationDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".warp/tab_configs", isDirectory: true)
            try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
            let configurationIdentity = Data((directory.path + "\n" + executable.path).utf8)
            let configurationName =
                "pace_codex_" + SHA256.hash(data: configurationIdentity).map { String(format: "%02x", $0) }.joined()
            let configurationURL = configurationDirectory.appendingPathComponent(configurationName + ".toml")
            try PaceCodexSessionRequest.warpConfiguration(directory: directory, executable: executable)
                .write(to: configurationURL, atomically: true, encoding: .utf8)
            guard let launchURL = URL(string: "warp://tab_config/" + configurationName),
                NSWorkspace.shared.open(launchURL)
            else {
                try? FileManager.default.removeItem(at: configurationURL)
                return .init(toolName: "codex_session", summary: "Failed to open the Codex tab in Warp.")
            }
            return .init(
                toolName: "codex_session",
                summary:
                    "Requested an interactive Codex tab in Warp at \(directory.path). Complete any Codex sign-in or folder trust prompt in that tab."
            )
        } catch {
            return .init(toolName: "codex_session", summary: "Failed to launch Codex: \(error.localizedDescription)")
        }
    }

    func openBrowser(_ request: PaceBrowserOpenRequest) async -> PaceActionExecutionObservation {
        guard actionsAreEnabled else {
            return .init(toolName: "open_url", summary: "Would open \(request.browserName).")
        }
        guard let applicationURL = Self.findApplicationURL(named: request.browserName) else {
            return .init(toolName: "open_url", summary: "Could not find app: \(request.browserName)")
        }
        let isChrome = ["chrome", "googlechrome", "comgooglechrome"].contains(
            Self.normalizeApplicationName(request.browserName))
        var arguments: [String] = []
        if isChrome, request.chromeProfile != nil || PaceLocalMemoryStore.string(for: .preferredChromeProfile) != nil {
            guard
                let profileDirectory = PaceBrowserOpenRequest.profileDirectory(
                    for: request.chromeProfile,
                    savedProfile: PaceLocalMemoryStore.string(for: .preferredChromeProfile)
                )
            else {
                return .init(
                    toolName: "open_url",
                    summary:
                        "Could not resolve the Chrome profile. Tell Pace 'my Chrome work profile is Profile 1' using your profile directory from chrome://version."
                )
            }
            arguments += ["--profile-directory=\(profileDirectory)"]
        } else if request.chromeProfile != nil {
            return .init(
                toolName: "open_url", summary: "Failed to open profile: profiles are supported only for Chrome.")
        }
        var urls: [URL] = []
        if let rawURL = request.url {
            guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return .init(toolName: "open_url", summary: "Could not parse website URL: \(rawURL)")
            }
            if isChrome { arguments.append(url.absoluteString) } else { urls = [url] }
        } else if isChrome, !arguments.isEmpty {
            arguments.append("--new-window")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = isChrome && !arguments.isEmpty
        let openError: String? = await withCheckedContinuation { continuation in
            if urls.isEmpty {
                NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                    continuation.resume(returning: error?.localizedDescription)
                }
            } else {
                NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) {
                    _, error in
                    continuation.resume(returning: error?.localizedDescription)
                }
            }
        }
        if let openError {
            return .init(toolName: "open_url", summary: "Failed to open \(request.browserName): \(openError)")
        }
        return .init(
            toolName: "open_url",
            summary:
                "Opened \(request.url ?? request.browserName) in \(request.browserName)\(request.chromeProfile.map { " (\($0) profile)" } ?? "")."
        )
    }

    func openScreenCaptureControls(_ kind: PaceScreenCaptureKind) -> PaceActionExecutionObservation {
        guard actionsAreEnabled else {
            return .init(toolName: "screen_capture", summary: "Would open \(kind.rawValue) controls.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = kind.arguments
        // macOS owns region selection, save location, and the Record/Capture
        // button. Do not claim that recording started merely by opening it.
        process.terminationHandler = { _ in }
        do { try process.run() } catch {
            return .init(
                toolName: "screen_capture",
                summary: "Failed to open screen capture controls: \(error.localizedDescription)")
        }
        return .init(
            toolName: "screen_capture",
            summary: kind == .recording
                ? "Opened screen recording controls. Choose the area and press Record; use the stop button in the menu bar to finish."
                : "Opened screenshot controls. Choose the area and press Capture.")
    }

    func controlMeeting(_ command: PaceMeetingModeCommand) async -> PaceActionExecutionObservation {
        guard actionsAreEnabled else { return .init(toolName: "meeting", summary: "Would change meeting recording.") }
        let controller = PaceMeetingModeController.shared
        switch command {
        case .start(let profileSlug):
            controller.isEnabled = true
            if let profileSlug { controller.selectedProfileSlug = profileSlug }
            await controller.start()
        case .stop:
            controller.isEnabled = false
            await controller.stop()
        case .status: break
        }
        switch controller.state {
        case .active: return .init(toolName: "meeting", summary: "Meeting recording is active.")
        case .failed(let reason): return .init(toolName: "meeting", summary: "Failed to record meeting: \(reason)")
        case .starting, .transcribing, .synthesizing:
            return .init(toolName: "meeting", summary: "Meeting recording is processing.")
        case .inactive:
            return .init(
                toolName: "meeting",
                summary: "Meeting recording is stopped. Audio and available transcripts stay on this Mac.")
        }
    }
}
