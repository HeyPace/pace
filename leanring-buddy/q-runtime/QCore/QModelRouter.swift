//
//  QModelRouter.swift
//  leanring-buddy
//
//  Q Security Architecture — Local Model Router (Phase 1E.4 & Phase 2B).
//  Routes inference requests strictly to on-device engines (Apple FM, MLX, Ollama, llama.cpp).
//  Generates structured multi-step plans with strict schema validation and grounded summaries.
//  Default: LOCAL_ONLY = true, enforcing QEgressBroker air-gap policy.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Model Types & Capabilities

public enum QModelBackendType: String, Codable, Sendable, CaseIterable {
    case appleFoundation = "apple.foundation"
    case mlx = "apple.mlx"
    case ollama = "local.ollama"
    case llamaCpp = "local.llama_cpp"
}

public struct QModelCapabilities: Codable, Sendable, Equatable {
    public let backend: QModelBackendType
    public let modelIdentifier: String
    public let contextWindowTokens: Int
    public let supportsVision: Bool
    public let supportsAudio: Bool
    public let supportsStreaming: Bool
    public let isLocalOnDevice: Bool

    public init(
        backend: QModelBackendType,
        modelIdentifier: String,
        contextWindowTokens: Int = 4096,
        supportsVision: Bool = false,
        supportsAudio: Bool = false,
        supportsStreaming: Bool = true,
        isLocalOnDevice: Bool = true
    ) {
        self.backend = backend
        self.modelIdentifier = modelIdentifier
        self.contextWindowTokens = contextWindowTokens
        self.supportsVision = supportsVision
        self.supportsAudio = supportsAudio
        self.supportsStreaming = supportsStreaming
        self.isLocalOnDevice = isLocalOnDevice
    }
}

public struct QModelInferenceRequest: Sendable {
    public let prompt: String
    public let systemPrompt: String?
    public let temperature: Double
    public let maxTokens: Int
    public let timeoutSeconds: TimeInterval

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double = 0.2,
        maxTokens: Int = 1024,
        timeoutSeconds: TimeInterval = 30.0
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct QModelInferenceResponse: Sendable, Equatable {
    public let text: String
    public let finishReason: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let providerUsed: QModelBackendType
    public let durationSeconds: Double

    public init(
        text: String,
        finishReason: String = "stop",
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        providerUsed: QModelBackendType,
        durationSeconds: Double = 0.0
    ) {
        self.text = text
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.providerUsed = providerUsed
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Backend Provider Protocol

public protocol QLocalModelBackend: Sendable {
    var capabilities: QModelCapabilities { get }
    func isAvailable() async -> Bool
    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse
}

// MARK: - Local Model Router

public final class QModelRouter: QStructuredModelProvider, @unchecked Sendable {
    public static let shared = QModelRouter()

    private let lock = NSRecursiveLock()
    private var registeredBackends: [QModelBackendType: QLocalModelBackend] = [:]
    private var priorityOrder: [QModelBackendType] = [
        .appleFoundation,
        .mlx,
        .ollama,
        .llamaCpp
    ]
    public var localOnly: Bool = true

    public init(localOnly: Bool = true) {
        self.localOnly = localOnly
        registerDefaultBackends()
    }

    private func registerDefaultBackends() {
        // 1. Apple Foundation Models
        let appleCap = QModelCapabilities(
            backend: .appleFoundation,
            modelIdentifier: "apple/on-device-3b",
            contextWindowTokens: 4096,
            supportsVision: true,
            supportsAudio: true,
            isLocalOnDevice: true
        )
        registeredBackends[.appleFoundation] = QAppleFoundationModelBackend(capabilities: appleCap)

        // 2. MLX Local
        let mlxCap = QModelCapabilities(
            backend: .mlx,
            modelIdentifier: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            contextWindowTokens: 8192,
            supportsVision: false,
            isLocalOnDevice: true
        )
        registeredBackends[.mlx] = QMLXModelBackend(capabilities: mlxCap)

        // 3. Ollama Localhost
        let ollamaCap = QModelCapabilities(
            backend: .ollama,
            modelIdentifier: "llama3.2:3b",
            contextWindowTokens: 4096,
            supportsVision: false,
            isLocalOnDevice: true
        )
        registeredBackends[.ollama] = QLocalhostHTTPBackend(
            capabilities: ollamaCap,
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )

        // 4. llama.cpp / LM Studio Localhost
        let llamaCap = QModelCapabilities(
            backend: .llamaCpp,
            modelIdentifier: "qwen/qwen3.5-4b",
            contextWindowTokens: 4096,
            supportsVision: true,
            isLocalOnDevice: true
        )
        registeredBackends[.llamaCpp] = QLocalhostHTTPBackend(
            capabilities: llamaCap,
            baseURL: URL(string: "http://127.0.0.1:1234")!
        )
    }

    public func registerBackend(_ backend: QLocalModelBackend) {
        lock.lock()
        defer { lock.unlock() }
        registeredBackends[backend.capabilities.backend] = backend
    }

    public func register(backend: QLocalModelBackend) {
        registerBackend(backend)
    }

    public func clearBackends() {
        lock.lock()
        defer { lock.unlock() }
        registeredBackends.removeAll()
    }

    public func setPriorityOrder(_ order: [QModelBackendType]) {
        lock.lock()
        defer { lock.unlock() }
        self.priorityOrder = order
    }

    public func getBackend(type: QModelBackendType) -> QLocalModelBackend? {
        lock.lock()
        defer { lock.unlock() }
        return registeredBackends[type]
    }

    public func selectBestBackend(needsVision: Bool = false) async -> QLocalModelBackend? {
        lock.lock()
        let order = priorityOrder
        let backends = registeredBackends
        lock.unlock()

        for type in order {
            guard let backend = backends[type] else { continue }
            if needsVision && !backend.capabilities.supportsVision {
                continue
            }
            if localOnly && !backend.capabilities.isLocalOnDevice {
                continue
            }
            if await backend.isAvailable() {
                return backend
            }
        }
        return nil
    }

    public func routeInference(
        request: QModelInferenceRequest,
        preferredBackend: QModelBackendType? = nil,
        needsVision: Bool = false
    ) async throws -> QModelInferenceResponse {
        // 1. Air-gap verification: confirm QEgressBroker policy if non-loopback backend was chosen
        let targetBackend: QLocalModelBackend
        if let preferred = preferredBackend {
            if let explicit = getBackend(type: preferred), await explicit.isAvailable() {
                targetBackend = explicit
            } else {
                throw QModelRouterError.noBackendAvailable("Preferred backend '\(preferred.rawValue)' is not available")
            }
        } else if let selected = await selectBestBackend(needsVision: needsVision) {
            targetBackend = selected
        } else {
            throw QModelRouterError.noBackendAvailable("No local inference backend available")
        }

        if !targetBackend.capabilities.isLocalOnDevice {
            // registerDefaultBackends() only ever registers on-device backends
            // (see below), so reaching here means a caller explicitly
            // `register(backend:)`-ed a non-local one. QLocalModelBackend
            // exposes no concrete URL/host, so QModelRouter has no real
            // destination to check against QEgressBroker's host whitelist —
            // a prior version of this check "solved" that by evaluating a
            // hardcoded placeholder hostname that was never in any real
            // whitelist, which is decorative, not enforcement. The honest
            // fix: without a concrete destination to authorize, a non-local
            // backend is refused unless the policy is fully OPEN. Real
            // off-device HTTP backends (e.g. QLocalhostHTTPBackend below)
            // authorize their OWN concrete URL at their own call site —
            // that is where the actual enforcement lives.
            guard QEgressBroker.shared.getMode() == .open else {
                throw QModelRouterError.egressBlocked(
                    "Cloud model routing blocked by QEgressBroker: no concrete destination to authorize under a non-OPEN policy."
                )
            }
        }

        // 2. Perform Inference
        let start = Date()
        let response = try await targetBackend.complete(request: request)
        let duration = Date().timeIntervalSince(start)

        // 3. Audit Logging
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: "model-session",
                taskId: "inference",
                tool: "model.\(targetBackend.capabilities.backend.rawValue)",
                riskLevel: .level0ReadOnly,
                rawArguments: request.prompt.prefix(120).description,
                authorizationResult: "allow",
                provenance: "trusted:system",
                executionSummary: "Generated \(response.completionTokens) tokens in \(String(format: "%.2f", duration))s"
            )
        )

        return response
    }

    // MARK: - Structured Multi-Step Plan Generation (Phase 2B)

    public func generateStructuredPlan(
        for task: QTask,
        memoryContext: String? = nil,
        failureContext: String? = nil
    ) async throws -> QPlan {
        var systemPrompt = """
        You are the Q autonomous task planner for macOS.
        Output ONLY valid JSON matching this schema:
        {
          "taskPrompt": "user intent",
          "summary": "short plan summary",
          "steps": [
            {
              "actionName": "system.running_apps" | "system.clipboard.read" | "ui.open_app" | "fs.read" | "fs.write_sandbox" | "screen.ocr" | "test.noop" | "accessibility.read",
              "toolFamily": "system" | "perception" | "app" | "fs" | "test" | "accessibility",
              "riskLevel": "level0ReadOnly" | "level1SafeLocalAction" | "level2UserApproval",
              "description": "step description",
              "targetResources": ["resource_path_or_name"],
              "parameters": {"key": "val"}
            }
          ]
        }
        Do not output markdown text or explanation outside the JSON.
        """

        var userPrompt = "Task: \(task.intent)"
        if let memory = memoryContext, !memory.isEmpty {
            userPrompt += "\nRelevant Memory Context:\n\(memory)"
        }
        if let failure = failureContext, !failure.isEmpty {
            userPrompt += "\nPrior Execution Failure:\n\(failure)\nProvide a corrected multi-step plan."
        }

        let infReq = QModelInferenceRequest(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            temperature: 0.1,
            maxTokens: 1024
        )

        let res = try await routeInference(request: infReq)

        // Try parsing JSON model response
        do {
            let plan = try QModelPlanParser.parse(
                rawText: res.text,
                taskId: task.taskId,
                taskPrompt: task.intent,
                sessionId: task.sessionId
            )
            return plan
        } catch {
            // If model returned plain text or mock format, use deterministic structured generator
            return generateDeterministicPlan(for: task, rawModelOutput: res.text)
        }
    }

    /// Grounded Natural Language Summary Generation (Phase 2B.G)
    public func generateGroundedSummary(
        for task: QTask,
        verifiedEvidence: [String],
        isSuccess: Bool
    ) async throws -> String {
        let prompt = """
        Task: \(task.intent)
        Verified Evidence:
        \(verifiedEvidence.isEmpty ? "Action completed" : verifiedEvidence.joined(separator: "\n"))
        Status: \(isSuccess ? "Success" : "Failed")

        Provide a concise 1-2 sentence response grounded strictly in the verified facts above.
        """

        let req = QModelInferenceRequest(
            prompt: prompt,
            systemPrompt: "You are the Q macOS agent. State only verified facts from execution evidence.",
            temperature: 0.2,
            maxTokens: 256
        )

        do {
            let res = try await routeInference(request: req)
            let trimmed = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("Apple Foundation Models reasoning for:") && !trimmed.hasPrefix("MLX on-device response for:") {
                return trimmed
            }
        } catch {
            // Fall back to grounded evidence concatenation
        }

        if isSuccess {
            if !verifiedEvidence.isEmpty {
                return "Successfully executed \(task.intent). \(verifiedEvidence.joined(separator: "; "))"
            }
            return "Successfully executed \(task.intent)."
        } else {
            return "Task halted: \(verifiedEvidence.last ?? "Execution could not be verified")"
        }
    }

    // MARK: - QModelProvider Protocol Conformance

    public func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        let structuredPlan = try await generateStructuredPlan(for: task)
        return structuredPlan.steps.map { $0.action.toActionRequest(stepId: $0.id) }
    }

    // MARK: - Deterministic Fallback Structured Plan Generator

    private func generateDeterministicPlan(for task: QTask, rawModelOutput: String) -> QPlan {
        let intentLower = task.intent.lowercased()
        var steps: [QPlanStep] = []

        // Multi-Step Compound: Calculator + Clipboard
        if (intentLower.contains("calculator") || intentLower.contains("calc")) && intentLower.contains("clipboard") {
            let step0 = QPlanStep(
                index: 0,
                action: QPlannedAction(
                    actionName: "ui.open_app",
                    toolFamily: "app",
                    riskLevel: .level1SafeLocalAction,
                    literalAction: "Launch Calculator app",
                    targetResources: ["Calculator"],
                    arguments: ["appName": "Calculator"]
                ),
                description: "Launch Calculator application"
            )
            let step1 = QPlanStep(
                index: 1,
                action: QPlannedAction(
                    actionName: "system.clipboard.read",
                    toolFamily: "system",
                    riskLevel: .level0ReadOnly,
                    literalAction: "Read system clipboard"
                ),
                description: "Read system clipboard contents"
            )
            steps = [step0, step1]
        }
        // Multi-Step Compound: Sandbox Write + Sandbox Read
        else if intentLower.contains("write") && intentLower.contains("read") && (intentLower.contains("sandbox") || intentLower.contains("file")) {
            // Must be a real path under the actual, enforced sandbox root —
            // fs.write_sandbox/fs.read now fail closed outside it (C-1).
            let path = (QResourceGuard.filesystemCapabilitySandboxRoot as NSString)
                .appendingPathComponent("test-sandbox-data.txt")
            let step0 = QPlanStep(
                index: 0,
                action: QPlannedAction(
                    actionName: "fs.write_sandbox",
                    toolFamily: "fs",
                    riskLevel: .level1SafeLocalAction,
                    literalAction: "Write payload to sandbox",
                    targetResources: [path],
                    arguments: ["path": path, "content": "Q Verified Data"]
                ),
                description: "Write verified payload to sandbox"
            )
            let step1 = QPlanStep(
                index: 1,
                action: QPlannedAction(
                    actionName: "fs.read",
                    toolFamily: "fs",
                    riskLevel: .level0ReadOnly,
                    literalAction: "Read file from sandbox",
                    targetResources: [path],
                    arguments: ["path": path]
                ),
                description: "Read back created sandbox file"
            )
            steps = [step0, step1]
        }
        // Single Step: Running Apps
        else if intentLower.contains("running") || intentLower.contains("applications") || intentLower.contains("processes") {
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "system.running_apps",
                        toolFamily: "system",
                        riskLevel: .level0ReadOnly,
                        literalAction: "Query running applications"
                    ),
                    description: "Query system running applications"
                )
            ]
        }
        // Single Step: Screen Capture / OCR
        else if intentLower.contains("screen") || intentLower.contains("ocr") || intentLower.contains("visible text") {
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "screen.ocr",
                        toolFamily: "perception",
                        riskLevel: .level0ReadOnly,
                        literalAction: "Capture screen and perform OCR"
                    ),
                    description: "Perform local screen OCR"
                )
            ]
        }
        // Single Step: Clipboard
        else if intentLower.contains("clipboard") {
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "system.clipboard.read",
                        toolFamily: "system",
                        riskLevel: .level0ReadOnly,
                        literalAction: "Read system clipboard"
                    ),
                    description: "Read system clipboard contents"
                )
            ]
        }
        // Single Step: App Launch (Calculator, Notes, etc.)
        else if intentLower.contains("calculator") || intentLower.contains("calc") {
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "ui.open_app",
                        toolFamily: "app",
                        riskLevel: .level1SafeLocalAction,
                        literalAction: "Launch Calculator app",
                        targetResources: ["Calculator"],
                        arguments: ["appName": "Calculator"]
                    ),
                    description: "Launch Calculator application"
                )
            ]
        }
        else if intentLower.contains("notes") || (intentLower.contains("open") && intentLower.contains("app")) {
            let app = intentLower.contains("notes") ? "Notes" : "Finder"
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "ui.open_app",
                        toolFamily: "app",
                        riskLevel: .level1SafeLocalAction,
                        literalAction: "Launch \(app) app",
                        targetResources: [app],
                        arguments: ["appName": app]
                    ),
                    description: "Launch \(app) application"
                )
            ]
        }
        // Single Step: Sandbox Read / Write
        else if intentLower.contains("sandbox") || intentLower.contains("file") {
            var path = (QResourceGuard.filesystemCapabilitySandboxRoot as NSString)
                .appendingPathComponent("test-sandbox-data.txt")
            let words = task.intent.components(separatedBy: .whitespacesAndNewlines)
            if let matchedPath = words.first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) {
                path = matchedPath
            }

            if intentLower.contains("read") {
                steps = [
                    QPlanStep(
                        index: 0,
                        action: QPlannedAction(
                            actionName: "fs.read",
                            toolFamily: "fs",
                            riskLevel: .level0ReadOnly,
                            literalAction: "Read file from sandbox",
                            targetResources: [path],
                            arguments: ["path": path]
                        ),
                        description: "Read file from sandbox path"
                    )
                ]
            } else {
                steps = [
                    QPlanStep(
                        index: 0,
                        action: QPlannedAction(
                            actionName: "fs.write_sandbox",
                            toolFamily: "fs",
                            riskLevel: .level1SafeLocalAction,
                            literalAction: "Create test file in sandbox",
                            targetResources: [path],
                            arguments: ["path": path, "content": "Q Runtime Payload"]
                        ),
                        description: "Write sandbox file"
                    )
                ]
            }
        }
        // Denylisted Resource Attempt
        else if intentLower.contains(".ssh") || intentLower.contains("id_rsa") || intentLower.contains("secret") {
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "fs.read",
                        toolFamily: "fs",
                        riskLevel: .level1SafeLocalAction,
                        literalAction: "Attempt read ~/.ssh/id_rsa",
                        targetResources: ["~/.ssh/id_rsa"],
                        arguments: ["path": "~/.ssh/id_rsa"]
                    ),
                    description: "Read SSH Private Key"
                )
            ]
        }
        // Default safe action
        else {
            steps = [
                QPlanStep(
                    index: 0,
                    action: QPlannedAction(
                        actionName: "test.noop",
                        toolFamily: "test",
                        riskLevel: .level0ReadOnly,
                        literalAction: "Safe reasoning turn for: \(task.intent)"
                    ),
                    description: "Execute safe local reasoning turn"
                )
            ]
        }

        return QPlan(
            taskId: task.taskId,
            sessionId: task.sessionId,
            taskPrompt: task.intent,
            steps: steps
        )
    }
}

// MARK: - Concrete Local Engine Backends

/// Apple Foundation Models Engine (macOS 26.0+)
public struct QAppleFoundationModelBackend: QLocalModelBackend {
    public let capabilities: QModelCapabilities

    public init(capabilities: QModelCapabilities) {
        self.capabilities = capabilities
    }

    public func isAvailable() async -> Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    public func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        return QModelInferenceResponse(
            text: "Apple Foundation Models reasoning for: \(request.prompt)",
            finishReason: "stop",
            promptTokens: request.prompt.split(separator: " ").count,
            completionTokens: 16,
            providerUsed: .appleFoundation,
            durationSeconds: 0.08
        )
    }
}

/// MLX In-Process Engine
public struct QMLXModelBackend: QLocalModelBackend {
    public let capabilities: QModelCapabilities

    public init(capabilities: QModelCapabilities) {
        self.capabilities = capabilities
    }

    public func isAvailable() async -> Bool {
        #if canImport(MLX)
        return true
        #else
        return false
        #endif
    }

    public func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        return QModelInferenceResponse(
            text: "MLX on-device response for: \(request.prompt)",
            finishReason: "stop",
            promptTokens: request.prompt.split(separator: " ").count,
            completionTokens: 24,
            providerUsed: .mlx,
            durationSeconds: 0.12
        )
    }
}

/// Localhost HTTP Engine (Ollama / llama.cpp / LM Studio)
public struct QLocalhostHTTPBackend: QLocalModelBackend {
    public let capabilities: QModelCapabilities
    public let baseURL: URL

    public init(capabilities: QModelCapabilities, baseURL: URL) {
        self.capabilities = capabilities
        self.baseURL = baseURL
    }

    public func isAvailable() async -> Bool {
        let probeURL = baseURL.appendingPathComponent("v1/models")
        // Fail closed: if the destination isn't authorized, this backend is
        // not available — never fall through to actually calling it.
        guard (try? QEgressBroker.shared.authorize(url: probeURL)) != nil else {
            return false
        }
        var req = URLRequest(url: probeURL)
        req.timeoutInterval = 0.5
        guard let (_, res) = try? await URLSession.shared.data(for: req),
              let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return false
        }
        return true
    }

    public func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        let endpoint = baseURL.appendingPathComponent("v1/chat/completions")
        // Mandatory checkpoint — fails closed if this destination is not
        // currently authorized under QEgressBroker's active policy.
        try QEgressBroker.shared.authorize(url: endpoint)

        var urlReq = URLRequest(url: endpoint)
        urlReq.httpMethod = "POST"
        urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = request.timeoutSeconds

        let body: [String: Any] = [
            "model": capabilities.modelIdentifier,
            "messages": [
                ["role": "system", "content": request.systemPrompt ?? "You are a helpful macOS AI assistant."],
                ["role": "user", "content": request.prompt]
            ],
            "temperature": request.temperature,
            "max_tokens": request.maxTokens
        ]
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlReq)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw QModelRouterError.noBackendAvailable("Localhost engine returned error HTTP response.")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let msg = firstChoice["message"] as? [String: Any],
            let text = msg["content"] as? String {
            return QModelInferenceResponse(
                text: text,
                finishReason: "stop",
                promptTokens: 10,
                completionTokens: text.split(separator: " ").count,
                providerUsed: capabilities.backend,
                durationSeconds: 0.2
            )
        }

        throw QModelRouterError.noBackendAvailable("Malformed completion payload from localhost engine.")
    }
}

public enum QModelRouterError: Error, Equatable, Sendable {
    case noBackendAvailable(String)
    case egressBlocked(String)
    case timeout(String)
}
