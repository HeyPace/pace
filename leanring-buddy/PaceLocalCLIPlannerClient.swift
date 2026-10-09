//
//  PaceLocalCLIPlannerClient.swift
//  leanring-buddy
//
//  Direct-spawn planner that talks to the user's already-authenticated
//  `claude` or `codex` CLI without going through the sibling local-ai
//  Node bridge. Ported from CodeVetter's
//  `apps/desktop/src-tauri/src/agent/cli_brain.rs` — same stream-json
//  parsing, same `--bare` optimization when `ANTHROPIC_API_KEY` is set,
//  same session-id resume contract. Replaces the localhost:3456 bridge
//  requirement for Pace's `.research` lane: now the only prerequisite
//  is `claude` (or `codex`) on PATH.
//
//  Why a sibling planner instead of folding into CloudBridgePlannerClient:
//  the bridge planner talks SSE-over-HTTP to a Node server that itself
//  spawns the CLI; we now do the spawn ourselves. Different transport,
//  different lifetime model, different test surface — cleaner as its
//  own conformer.
//

import Foundation

// MARK: - Upstream + errors

/// CLI upstream the planner will spawn. Mirrors the `claude`/`codex`
/// case names CodeVetter uses; gemini is intentionally not supported in
/// the bundled path (gemini-cli's headless contract is too different;
/// users wanting it stay on the Node bridge via the legacy path).
nonisolated enum PaceLocalCLIUpstream: String, Equatable, Codable {
    case claude
    case codex

    /// Human-readable label used in Settings and logs.
    var displayLabel: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }

    /// Executable name `Process` looks up on PATH. Stays in sync with
    /// CodeVetter's `Command::new("claude")` / `Command::new("codex")`.
    var executableName: String {
        rawValue
    }
}

enum PaceLocalCLIPlannerError: LocalizedError {
    case spawnFailed(executable: String, underlying: String)
    case missingStdoutPipe(executable: String)
    case nonZeroExit(executable: String, status: Int32, stderrExcerpt: String)
    case stdinWriteFailed(executable: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let executable, let underlying):
            return "Couldn't launch `\(executable)`. Is it on PATH? Underlying: \(underlying)"
        case .missingStdoutPipe(let executable):
            return "`\(executable)` had no stdout pipe."
        case .nonZeroExit(let executable, let status, let stderrExcerpt):
            return "`\(executable)` exited with status \(status). \(stderrExcerpt)"
        case .stdinWriteFailed(let executable, let underlying):
            return "Couldn't write to `\(executable)` stdin: \(underlying)"
        }
    }
}

// MARK: - Stream-json parser (pure helpers)

/// Pure helpers that consume one JSON-encoded line at a time from a
/// `claude` / `codex` stream-json process. Ported function-for-function
/// from CodeVetter's `cli_brain.rs` (`parse_claude_line`,
/// `parse_codex_line`, `extract_session_id`) so behavior stays in sync
/// across the two projects.
nonisolated enum PaceLocalCLIStreamJSONParser {

    /// Returns the text fragments contained in a single `claude -p`
    /// stream-json line, if any. Tolerant of unrelated event types and
    /// malformed lines (returns empty string). Matches CodeVetter's
    /// `parse_claude_line` exactly:
    ///   - `type=assistant` → walks `message.content[]` for `type=text`
    ///     blocks
    ///   - `type=content_block_delta` → reads `delta.text`
    ///   - everything else returns ""
    static func extractClaudeChunk(fromLine rawLine: String) -> String {
        guard let payloadData = rawLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return ""
        }
        guard let eventType = payload["type"] as? String else { return "" }
        switch eventType {
        case "assistant":
            guard let message = payload["message"] as? [String: Any],
                  let contentBlocks = message["content"] as? [[String: Any]] else {
                return ""
            }
            var assembledFragment = ""
            for block in contentBlocks {
                if (block["type"] as? String) == "text",
                   let textFragment = block["text"] as? String {
                    assembledFragment += textFragment
                }
            }
            return assembledFragment
        case "content_block_delta":
            guard let delta = payload["delta"] as? [String: Any],
                  let textFragment = delta["text"] as? String else {
                return ""
            }
            return textFragment
        default:
            return ""
        }
    }

    /// Reads `session_id` off any claude stream-json line. Per
    /// Anthropic's headless docs, the `system/init` event includes it,
    /// and the field also appears on later events as a safety net.
    /// Returns nil for lines without the field. Matches CodeVetter's
    /// `extract_session_id`.
    static func extractClaudeSessionId(fromLine rawLine: String) -> String? {
        guard let payloadData = rawLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload["session_id"] as? String
    }

    /// Returns the text fragment contained in a `codex exec --json`
    /// line, if any. We only emit on
    /// `type=item.completed → item.type=agent_message`. Matches
    /// CodeVetter's `parse_codex_line`.
    static func extractCodexChunk(fromLine rawLine: String) -> String {
        guard let payloadData = rawLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return ""
        }
        guard (payload["type"] as? String) == "item.completed",
              let item = payload["item"] as? [String: Any],
              (item["type"] as? String) == "agent_message",
              let textFragment = item["text"] as? String else {
            return ""
        }
        return textFragment
    }
}

// MARK: - Planner

/// BuddyPlannerClient conformer that spawns the local CLI per turn.
/// Stateful across calls inside one PTT release: the captured
/// `session_id` from the first claude call drives `--resume <id>` on
/// followups so the conversation prefix stays in Anthropic's prompt
/// cache (per CodeVetter's observation: ~500ms-2s faster + 90% cheaper
/// cached input on subsequent steps).
@MainActor
final class PaceLocalCLIPlannerClient: BuddyPlannerClient {
    let displayName: String
    /// Codex can reason over screenshots when Read My Screen is enabled.
    /// Research turns stay text-only so they do not upload ambient screens.
    var supportsImageInput: Bool { upstream == .codex && !isResearchTurn }

    private let upstream: PaceLocalCLIUpstream
    private let isResearchTurn: Bool
    /// Optional model override forwarded as `--model <id>`. nil = let
    /// the CLI pick its default.
    private let modelIdentifier: String?
    /// `claude --bare` skips auto-discovery overhead (hooks, skills,
    /// plugins, MCP, CLAUDE.md) but requires API-key auth — it doesn't
    /// read OAuth/keychain. Enabled when `ANTHROPIC_API_KEY` is set so
    /// subscription users keep working without the flag.
    private let useBareModeForClaude: Bool
    /// Captured from the first claude `-p` invocation's system/init
    /// event. Subsequent calls within the same turn pass
    /// `--resume <id>`. Reset on `resetForNewTurn`.
    private var capturedClaudeSessionId: String?

    init(
        upstream: PaceLocalCLIUpstream,
        modelIdentifier: String?,
        isResearchTurn: Bool = false
    ) {
        self.upstream = upstream
        self.isResearchTurn = isResearchTurn
        // Treat an empty / whitespace-only identifier as "no override" so
        // `--model` is only ever forwarded when the user (or a caller like
        // the research lane, whose default is now empty for Codex) actually
        // named a model. Otherwise the CLI uses its own authenticated
        // default — the correct behavior for a general brain.
        let trimmedModelIdentifier = modelIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelIdentifier = (trimmedModelIdentifier?.isEmpty ?? true)
            ? nil
            : trimmedModelIdentifier
        self.modelIdentifier = normalizedModelIdentifier
        self.useBareModeForClaude = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil
        let suffix = normalizedModelIdentifier.map { " · \($0)" } ?? ""
        self.displayName = "CLI (\(upstream.displayLabel))\(suffix)"
    }

    func resetForNewTurn() {
        capturedClaudeSessionId = nil
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startedAt = Date()
        // Off-device egress size: the CLI ships the system prompt (first
        // step), the accumulated history, and the new user prompt off the
        // Mac via its provider. This is the byte count the privacy
        // dashboard aggregates for the "0 bytes → X KB to <upstream>"
        // headline, so it MUST be recorded on every turn — direct-spawn
        // is off-device and cannot be silent about egress.
        let estimatedInputCharacterCount =
            systemPrompt.utf8.count
            + conversationHistory.reduce(0) { $0 + $1.userPlaceholder.utf8.count + $1.assistantResponse.utf8.count }
            + userPrompt.utf8.count
            + (supportsImageInput ? images.reduce(0) { $0 + $1.data.count } : 0)
        do {
            let assembledText: String
            switch upstream {
            case .claude:
                assembledText = try await spawnClaude(
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
            case .codex:
                assembledText = try await spawnCodex(
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
            }
            let duration = Date().timeIntervalSince(startedAt)
            recordAuditEntry(
                durationMilliseconds: Int(duration * 1000),
                outcome: "ok",
                inputCharacterCount: estimatedInputCharacterCount,
                outputCharacterCount: assembledText.count
            )
            return (text: assembledText, duration: duration)
        } catch {
            // Fail-loud path still logs the off-device attempt: bytes left
            // the Mac (or tried to) even on error, and the dashboard must
            // reflect that. Outcome carries the error so the audit trail
            // shows why the turn failed.
            recordAuditEntry(
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                outcome: "error",
                inputCharacterCount: estimatedInputCharacterCount,
                outputCharacterCount: nil,
                detail: error.localizedDescription
            )
            throw error
        }
    }

    /// Records one direct-spawn planner turn to the local audit log under
    /// the `planner.cliDirect` subsystem so
    /// `PacePrivacyDashboardAggregator` classifies it as off-device egress
    /// (target = the upstream label the dashboard renders in "X KB to
    /// <target>"). Privacy: sizes only, never content — same posture as
    /// every other audit call site.
    private func recordAuditEntry(
        durationMilliseconds: Int,
        outcome: String,
        inputCharacterCount: Int,
        outputCharacterCount: Int?,
        detail: String? = nil
    ) {
        PaceAPIAuditLog.shared.record(
            subsystem: "planner.cliDirect",
            operation: "cli.spawn.stream",
            target: upstream.executableName,
            durationMilliseconds: durationMilliseconds,
            outcome: outcome,
            inputCharacterCount: inputCharacterCount,
            outputCharacterCount: outputCharacterCount,
            detail: detail ?? "tier=cliDirect upstream=\(upstream.rawValue)"
        )
    }

    // MARK: claude

    private func spawnClaude(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let resumedSessionId = capturedClaudeSessionId
        let isFollowup = (resumedSessionId != nil)
        // On a resumed turn, claude already has the system prompt +
        // accumulated history in conversation memory; sending it again
        // doubles up the prompt and wastes prefix cache. Just send the
        // new user message.
        let promptForStdin = isFollowup
            ? userPrompt
            : Self.composeInitialUserPrompt(
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )

        var arguments: [String] = ["-p", "--output-format", "stream-json", "--verbose"]
        if useBareModeForClaude {
            arguments.append("--bare")
        }
        if let modelIdentifier {
            arguments.append(contentsOf: ["--model", modelIdentifier])
        }
        if let resumedSessionId {
            arguments.append(contentsOf: ["--resume", resumedSessionId])
        } else {
            arguments.append(contentsOf: ["--system-prompt", systemPrompt])
        }

        let (assembledOutput, capturedSessionId) = try await runStreamingCLI(
            executable: PaceLocalCLIUpstream.claude.executableName,
            arguments: arguments,
            stdinPayload: promptForStdin,
            captureChunk: { line in
                PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: line)
            },
            captureSessionIdFromLine: { line in
                PaceLocalCLIStreamJSONParser.extractClaudeSessionId(fromLine: line)
            },
            onTextChunk: onTextChunk
        )

        // Only persist the session id on the FIRST call — claude
        // returns the resumed id on followups too, but sticking with
        // the original keeps the conversation linear if claude ever
        // chains internally.
        if !isFollowup, let capturedSessionId {
            capturedClaudeSessionId = capturedSessionId
        }
        return assembledOutput
    }

    // MARK: codex

    private func spawnCodex(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        // Each Pace step supplies its complete history; keep CLI sessions
        // ephemeral rather than retaining screen context in Codex history.
        let promptForStdin = Self.composeCodexPrompt(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let workingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-planner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workingDirectoryURL) }

        var arguments = Self.codexArguments(modelIdentifier: modelIdentifier, isResearchTurn: isResearchTurn)
        if supportsImageInput {
            for (imageIndex, image) in images.enumerated() {
                let imageURL = workingDirectoryURL.appendingPathComponent("screen-\(imageIndex).jpg")
                try image.data.write(to: imageURL, options: .atomic)
                arguments.append(contentsOf: ["--image", imageURL.path])
            }
        }

        let (assembledOutput, _) = try await runStreamingCLI(
            executable: PaceLocalCLIUpstream.codex.executableName,
            arguments: arguments,
            stdinPayload: promptForStdin,
            workingDirectoryURL: workingDirectoryURL,
            captureChunk: { line in
                PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: line)
            },
            captureSessionIdFromLine: { _ in nil },
            onTextChunk: onTextChunk
        )
        return assembledOutput
    }

    // MARK: Subprocess runner

    /// Spawns the executable, writes the stdin payload, drains stdout
    /// line-by-line into an assembled buffer via the caller's chunk
    /// extractor, and returns `(assembled, capturedSessionId)`.
    /// `captureSessionIdFromLine` may return nil for every line — that
    /// just means the upstream doesn't expose a session id we'd resume.
    ///
    /// `onTextChunk` is the protocol's non-escaping closure; we use
    /// the async stream to keep callbacks within the caller lifetime
    /// without violating its lifetime contract. The stream is consumed
    /// before this function returns.
    private func runStreamingCLI(
        executable: String,
        arguments: [String],
        stdinPayload: String,
        workingDirectoryURL: URL? = nil,
        captureChunk: @escaping @Sendable (String) -> String,
        captureSessionIdFromLine: @escaping @Sendable (String) -> String?,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (assembled: String, capturedSessionId: String?) {
        guard let executableURL = Self.resolveExecutable(named: executable) else {
            throw PaceLocalCLIPlannerError.spawnFailed(
                executable: executable, underlying: "not found on PATH or standard CLI install locations")
        }
        let directoryURL =
            workingDirectoryURL
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-planner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            if workingDirectoryURL == nil { try? FileManager.default.removeItem(at: directoryURL) }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.executableSearchDirectories().joined(separator: ":")
        // Claude rejects nested launches based on this inherited marker even
        // though Pace owns an independent, user-requested conversation.
        environment.removeValue(forKey: "CLAUDECODE")
        var assembledOutput = ""
        var capturedSessionId: String?
        let lines = PaceCLIProcessRunner.lines(
            executableURL: executableURL,
            arguments: arguments,
            stdinPayload: stdinPayload,
            workingDirectoryURL: directoryURL,
            environment: environment,
            timeout: isResearchTurn ? 300 : 120
        )
        for try await line in lines {
            try Task.checkCancellation()
            let chunk = captureChunk(line)
            if !chunk.isEmpty {
                assembledOutput += chunk
                onTextChunk(assembledOutput)
            }
            if capturedSessionId == nil { capturedSessionId = captureSessionIdFromLine(line) }
        }
        try Task.checkCancellation()
        guard !assembledOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PaceCLIProcessError.emptyResponse
        }
        return (assembledOutput, capturedSessionId)
    }

    nonisolated static func codexArguments(modelIdentifier: String?, isResearchTurn: Bool) -> [String] {
        // Pace approves and executes Mac actions. The CLI only plans; do not
        // inherit a coding workspace, hooks, MCP integrations, or shell tools.
        var arguments = [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral",
            "--ignore-user-config", "--sandbox", "read-only",
            "--disable", "shell_tool", "--disable", "hooks",
            "--disable", "apps", "--disable", "browser_use",
            "--disable", "computer_use", "--disable", "multi_agent",
            "--config", "web_search=\"\(isResearchTurn ? "live" : "disabled")\"",
        ]
        if let modelIdentifier, !modelIdentifier.isEmpty {
            arguments.append(contentsOf: ["--model", modelIdentifier])
        }
        return arguments
    }

    // MARK: Prompt composition

    /// First call within a turn: send `User: <history + new message>`
    /// to stdin alongside `--system-prompt`. Matches CodeVetter's
    /// `format_user_message_initial`.
    nonisolated static func composeInitialUserPrompt(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        var assembledPrompt = "User: "
        if !conversationHistory.isEmpty {
            assembledPrompt += "Previous steps:\n"
            for (turnIndex, turnPair) in conversationHistory.enumerated() {
                assembledPrompt += "  \(turnIndex + 1). \(turnPair.userPlaceholder) → \(turnPair.assistantResponse)\n"
            }
            assembledPrompt += "\n"
        }
        assembledPrompt += userPrompt
        return assembledPrompt
    }

    /// codex doesn't take `--system-prompt`, so we embed it inline.
    /// Matches CodeVetter's `build_codex_prompt`.
    nonisolated static func composeCodexPrompt(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        let userBody = composeInitialUserPrompt(
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        return "System instructions: \(systemPrompt)\n\n\(userBody)"
    }

    // MARK: Executable resolution

    /// `Process.executableURL` won't search PATH on its own — it wants
    /// an absolute URL. We walk the parent process's PATH ourselves,
    /// same way the existing `PaceMCPClient.executableURL(for:)` does.
    /// Falls back to /opt/homebrew/bin/<exec> for the common Homebrew
    /// install location when PATH is empty (LaunchAgents sometimes hit
    /// that case).
    nonisolated static func executableSearchDirectories(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let standardDirectories = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        var directories: [String] = []
        for directory in (path ?? "").split(separator: ":").map(String.init) + standardDirectories {
            if directory.hasPrefix("/"), !directories.contains(directory) { directories.append(directory) }
        }
        return directories
    }

    nonisolated static func resolveExecutable(named executableName: String) -> URL? {
        for directory in executableSearchDirectories() {
            let candidateURL = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidateURL.path) { return candidateURL }
        }
        if executableName == "codex" {
            let bundledCLI = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
            if FileManager.default.isExecutableFile(atPath: bundledCLI.path) { return bundledCLI }
        }
        return nil
    }

    nonisolated static func isUpstreamBinaryOnPath(_ upstream: PaceLocalCLIUpstream) -> Bool {
        resolveExecutable(named: upstream.executableName) != nil
    }

    /// The plain-language message shown when the chosen upstream binary is
    /// not on PATH. Reuses the `spawnFailed` error copy so the preflight
    /// hint and the runtime error read consistently.
    nonisolated static func missingBinaryPreflightMessage(
        for upstream: PaceLocalCLIUpstream
    ) -> String {
        return PaceLocalCLIPlannerError.spawnFailed(
            executable: upstream.executableName,
            underlying: "not found on PATH"
        ).errorDescription ?? "Couldn't launch `\(upstream.executableName)`. Is it on PATH?"
    }
}
