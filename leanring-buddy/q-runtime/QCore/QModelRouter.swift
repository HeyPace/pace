//
//  QModelRouter.swift
//  leanring-buddy
//
//  Q Security Architecture — Local Model Router (Phase 1D.9).
//  Routes inference requests strictly to on-device engines (Apple FM, MLX, Ollama, llama.cpp).
//  Default: LOCAL_ONLY = true, enforcing QEgressBroker air-gap policy.
//

import Foundation

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

public final class QModelRouter: QModelProvider, @unchecked Sendable {
    public static let shared = QModelRouter()

    private let lock = NSRecursiveLock()
    private var backends: [QModelBackendType: QLocalModelBackend] = [:]
    public var localOnly: Bool = true

    public init(localOnly: Bool = true) {
        self.localOnly = localOnly
        registerDefaultLocalBackends()
    }

    private func registerDefaultLocalBackends() {
        // Register built-in local MLX mock/adapter
        let mlxCaps = QModelCapabilities(
            backend: .mlx,
            modelIdentifier: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            contextWindowTokens: 8192,
            supportsVision: true,
            isLocalOnDevice: true
        )
        register(backend: QMockLocalMLXBackend(capabilities: mlxCaps))
    }

    public func register(backend: QLocalModelBackend) {
        lock.lock()
        defer { lock.unlock() }
        backends[backend.capabilities.backend] = backend
    }

    public func getBackend(type: QModelBackendType) -> QLocalModelBackend? {
        lock.lock()
        defer { lock.unlock() }
        return backends[type]
    }

    public func selectBestBackend(needsVision: Bool = false) async -> QLocalModelBackend? {
        lock.lock()
        let available = Array(backends.values)
        lock.unlock()

        for backend in available {
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
        return available.first
    }

    public func routeInference(
        request: QModelInferenceRequest,
        preferredBackend: QModelBackendType? = nil,
        needsVision: Bool = false
    ) async throws -> QModelInferenceResponse {
        // 1. Air-gap verification: confirm QEgressBroker policy if non-loopback backend was chosen
        let targetBackend: QLocalModelBackend
        if let preferred = preferredBackend, let explicit = getBackend(type: preferred) {
            targetBackend = explicit
        } else if let selected = await selectBestBackend(needsVision: needsVision) {
            targetBackend = selected
        } else {
            throw QModelRouterError.noBackendAvailable("No suitable local model backend available.")
        }

        if !targetBackend.capabilities.isLocalOnDevice {
            let egressDecision = QEgressBroker.shared.evaluate(host: "api.cloud-model.internal")
            guard egressDecision.isAllowed else {
                throw QModelRouterError.egressBlocked("Cloud model routing blocked by QEgressBroker in OFFLINE mode.")
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

    // MARK: - QModelProvider Implementation (Planner)

    public func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        let infReq = QModelInferenceRequest(
            prompt: "Plan for user task: \(task.intent)",
            systemPrompt: "You are the Q autonomous task planner. Output safe execution actions."
        )
        let res = try await routeInference(request: infReq)

        // For safe demonstration in Phase 1D, return safe local action
        if task.intent.lowercased().contains("notes") || task.intent.lowercased().contains("app") {
            return [
                QActionRequest(
                    toolName: "ui.open_app",
                    toolFamily: "app",
                    riskLevel: .level1SafeLocalAction,
                    literalAction: "Open Notes app",
                    targetResources: ["Notes"],
                    parameters: ["appName": "Notes"]
                )
            ]
        } else if task.intent.lowercased().contains("sandbox") || task.intent.lowercased().contains("file") {
            let path = "/tmp/q-sandbox/test-\(task.taskId.prefix(8)).txt"
            return [
                QActionRequest(
                    toolName: "fs.write_sandbox",
                    toolFamily: "fs",
                    riskLevel: .level1SafeLocalAction,
                    literalAction: "Create test file in sandbox",
                    targetResources: [path],
                    parameters: ["path": path, "content": "Q Runtime Test Payload: \(res.text)"]
                )
            ]
        } else {
            return [
                QActionRequest(
                    toolName: "test.noop",
                    toolFamily: "test",
                    riskLevel: .level0ReadOnly,
                    literalAction: "Default no-op action for intent: \(task.intent)"
                )
            ]
        }
    }
}

// MARK: - Mock Local MLX Backend

public struct QMockLocalMLXBackend: QLocalModelBackend {
    public let capabilities: QModelCapabilities

    public init(capabilities: QModelCapabilities) {
        self.capabilities = capabilities
    }

    public func isAvailable() async -> Bool {
        true
    }

    public func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        return QModelInferenceResponse(
            text: "Local MLX response for: \(request.prompt)",
            finishReason: "stop",
            promptTokens: request.prompt.split(separator: " ").count,
            completionTokens: 8,
            providerUsed: capabilities.backend,
            durationSeconds: 0.05
        )
    }
}

public enum QModelRouterError: Error, Equatable, Sendable {
    case noBackendAvailable(String)
    case egressBlocked(String)
    case timeout(String)
}
