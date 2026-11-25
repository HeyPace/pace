import Darwin
import Foundation

nonisolated enum PacePlannerCredentialError: Error, LocalizedError {
    case invalidConfiguration
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Pace's Infisical credential source is not configured correctly."
        case .unavailable:
            return "Pace could not load the configured API credential from Infisical. Check the CLI sign-in."
        }
    }
}

nonisolated struct PaceInfisicalCredentialConfiguration: Equatable, Sendable {
    static let defaultsKey = "pace.planner.infisicalCredentialSource"
    let projectID: String
    let organizationID: String
    let environment: String
    let secretPath: String
    let secretName: String

    static func load(defaults: UserDefaults = .standard) throws -> Self? {
        guard let storedValue = defaults.object(forKey: defaultsKey) else { return nil }
        guard let values = storedValue as? [String: String],
            Set(values.keys).isSubset(of: ["projectID", "organizationID", "environment", "secretPath", "secretName"]),
            let projectID = values["projectID"], let organizationID = values["organizationID"],
            let environment = values["environment"], let secretPath = values["secretPath"]
        else {
            throw PacePlannerCredentialError.invalidConfiguration
        }
        let configuration = Self(
            projectID: projectID,
            organizationID: organizationID,
            environment: environment,
            secretPath: secretPath,
            secretName: values["secretName"] ?? "OPENAI_API_KEY"
        )
        guard UUID(uuidString: projectID) != nil, UUID(uuidString: organizationID) != nil,
            environment.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
            secretPath.count <= 256,
            secretPath.range(of: "^/(?:[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)?$", options: .regularExpression) != nil,
            configuration.secretName.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil
        else {
            throw PacePlannerCredentialError.invalidConfiguration
        }
        return configuration
    }

    var arguments: [String] {
        [
            "secrets", "get", secretName, "--plain", "--include-imports=false", "--expand=false",
            "--projectId=\(projectID)", "--org=\(organizationID)", "--env=\(environment)", "--path=\(secretPath)",
            "--silent", "--telemetry=false", "--log-level=error", "--log-destination=stderr",
        ]
    }
}

nonisolated enum PacePlannerCredentialClock {
    private static let origin = ContinuousClock.now

    static func seconds() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    }
}

@MainActor
final class PacePlannerCredentialStore {
    static let shared = PacePlannerCredentialStore()
    private struct CachedKey {
        let value: String
        let expiresAt: TimeInterval
    }

    private struct PendingKey {
        let identifier: UUID
        let task: Task<String, Error>
        var waiters: Set<UUID>
    }

    @MainActor
    private final class Waiter {
        private var completedResult: Result<String, Error>?
        private var continuation: CheckedContinuation<Result<String, Error>, Never>?

        func finish(_ result: Result<String, Error>) {
            guard completedResult == nil else { return }
            completedResult = result
            continuation?.resume(returning: result)
            continuation = nil
        }

        func result(for task: Task<String, Error>) async -> Result<String, Error> {
            await withCheckedContinuation { continuation in
                if let completedResult {
                    continuation.resume(returning: completedResult)
                } else {
                    self.continuation = continuation
                    Task { finish(await task.result) }
                }
            }
        }
    }

    private let loadConfiguration: () throws -> PaceInfisicalCredentialConfiguration?
    private let loadKeychain: @MainActor () -> String?
    private let loadInfisicalKey: @Sendable (PaceInfisicalCredentialConfiguration) async throws -> String
    private let now: () -> TimeInterval
    private let cacheLifetime: TimeInterval
    private let auditLog: PaceAPIAuditLog
    private var configuration: PaceInfisicalCredentialConfiguration?
    private var generation = UUID()
    private var cachedKey: CachedKey?
    private var pendingKey: PendingKey?
    private var failedFetchRetryAt: TimeInterval?

    init(
        loadConfiguration: @escaping () throws -> PaceInfisicalCredentialConfiguration? = {
            try PaceInfisicalCredentialConfiguration.load()
        },
        loadKeychain: @escaping @MainActor () -> String? = { PaceKeychainStore.loadAPIKey(for: .openai) },
        loadInfisicalKey: @escaping @Sendable (PaceInfisicalCredentialConfiguration) async throws -> String = {
            try await PaceInfisicalCredentialProcess.loadKey(configuration: $0)
        },
        now: @escaping () -> TimeInterval = { PacePlannerCredentialClock.seconds() },
        cacheLifetime: TimeInterval = 30 * 60,
        auditLog: PaceAPIAuditLog? = nil
    ) {
        self.loadConfiguration = loadConfiguration
        self.loadKeychain = loadKeychain
        self.loadInfisicalKey = loadInfisicalKey
        self.now = now
        self.cacheLifetime = cacheLifetime
        self.auditLog = auditLog ?? .shared
    }

    func clearCachedKey() {
        generation = UUID()
        cachedKey = nil
        failedFetchRetryAt = nil
        pendingKey?.task.cancel()
        pendingKey = nil
    }

    func loadOpenAIKey() async throws -> String? {
        let startedAt = now()
        var source = "configuration"
        var outcome = "unavailable"
        defer {
            auditLog.record(
                subsystem: "credentials",
                operation: "credential.load",
                target: source,
                durationMilliseconds: max(0, Int((now() - startedAt) * 1000)),
                outcome: outcome
            )
        }
        do {
            try Task.checkCancellation()
            let requestedConfiguration: PaceInfisicalCredentialConfiguration?
            do { requestedConfiguration = try loadConfiguration() } catch {
                clearCachedKey()
                throw PacePlannerCredentialError.invalidConfiguration
            }
            if configuration != requestedConfiguration {
                clearCachedKey()
                configuration = requestedConfiguration
            }
            guard let requestedConfiguration else {
                source = "keychain"
                let key = loadKeychain()
                try Task.checkCancellation()
                outcome = key == nil ? "missing" : "loaded"
                return key
            }
            source = "infisical"
            if let cachedKey, cachedKey.expiresAt > now() {
                try Task.checkCancellation()
                outcome = "cacheHit"
                return cachedKey.value
            }
            if let failedFetchRetryAt, failedFetchRetryAt > now() {
                outcome = "backoff"
                throw PacePlannerCredentialError.unavailable
            }
            let requestedGeneration = generation
            let waiterIdentifier = UUID()
            if pendingKey == nil {
                let loader = loadInfisicalKey
                pendingKey = PendingKey(
                    identifier: UUID(),
                    task: Task {
                        let key = try await loader(requestedConfiguration)
                        try Task.checkCancellation()
                        guard PaceInfisicalCredentialProcess.isValidKey(key) else {
                            throw PacePlannerCredentialError.unavailable
                        }
                        return key
                    }, waiters: []
                )
            }
            pendingKey!.waiters.insert(waiterIdentifier)
            let request = pendingKey!
            let waiter = Waiter()
            defer { removeWaiter(waiterIdentifier, requestIdentifier: request.identifier) }
            let result = await withTaskCancellationHandler {
                await waiter.result(for: request.task)
            } onCancel: {
                Task { @MainActor [weak self] in
                    waiter.finish(.failure(CancellationError()))
                    self?.removeWaiter(waiterIdentifier, requestIdentifier: request.identifier)
                }
            }
            try Task.checkCancellation()
            guard generation == requestedGeneration else { throw PacePlannerCredentialError.unavailable }
            let currentConfiguration: PaceInfisicalCredentialConfiguration?
            do { currentConfiguration = try loadConfiguration() } catch {
                clearCachedKey()
                throw PacePlannerCredentialError.invalidConfiguration
            }
            guard currentConfiguration == requestedConfiguration else {
                clearCachedKey()
                throw PacePlannerCredentialError.unavailable
            }
            switch result {
            case .success(let key):
                if pendingKey?.identifier == request.identifier {
                    cachedKey = CachedKey(value: key, expiresAt: now() + cacheLifetime)
                    failedFetchRetryAt = nil
                    pendingKey = nil
                }
                outcome = "loaded"
                return key
            case .failure(let error):
                if pendingKey?.identifier == request.identifier {
                    pendingKey = nil
                    if !(error is CancellationError) {
                        cachedKey = nil
                        failedFetchRetryAt = now() + 30
                    }
                }
                if error is CancellationError {
                    throw CancellationError()
                }
                throw PacePlannerCredentialError.unavailable
            }
        } catch is CancellationError {
            outcome = "cancelled"
            throw CancellationError()
        } catch let error as PacePlannerCredentialError {
            throw error
        } catch {
            throw PacePlannerCredentialError.unavailable
        }
    }

    private func removeWaiter(_ waiterIdentifier: UUID, requestIdentifier: UUID) {
        guard pendingKey?.identifier == requestIdentifier else { return }
        pendingKey?.waiters.remove(waiterIdentifier)
        if pendingKey?.waiters.isEmpty == true {
            pendingKey?.task.cancel()
            pendingKey = nil
        }
    }
}

nonisolated enum PaceInfisicalCredentialProcess {
    static func isValidKey(_ value: String) -> Bool {
        value.count >= 40 && value.utf8.count <= 16384 && value.hasPrefix("sk-")
            && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    static func loadKey(configuration: PaceInfisicalCredentialConfiguration) async throws -> String {
        guard
            let executablePath = ["/opt/homebrew/bin/infisical", "/usr/local/bin/infisical"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw PacePlannerCredentialError.unavailable
        }
        return try await run(executableURL: URL(fileURLWithPath: executablePath), arguments: configuration.arguments)
    }

    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval = 8) async throws -> String {
        let processControl = PaceCLIProcessControl()
        let worker = Task.detached(priority: .userInitiated) {
            defer { processControl.finished() }
            do {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                defer { try? outputPipe.fileHandleForReading.close() }
                try processControl.launch(process)
                let timeoutWork = DispatchWorkItem { processControl.stop(timedOut: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout), execute: timeoutWork)
                defer {
                    timeoutWork.cancel()
                    processControl.stop()
                    process.waitUntilExit()
                    processControl.waitForStoppedProcessGroup()
                }
                var output = Data()
                while true {
                    try processControl.checkCancellation()
                    var descriptor = pollfd(
                        fd: outputPipe.fileHandleForReading.fileDescriptor,
                        events: Int16(POLLIN | POLLHUP),
                        revents: 0
                    )
                    let readiness = Darwin.poll(&descriptor, 1, 50)
                    if readiness < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw PacePlannerCredentialError.unavailable
                    }
                    try processControl.checkCancellation()
                    if readiness == 0 {
                        continue
                    }
                    guard descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                        throw PacePlannerCredentialError.unavailable
                    }
                    guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
                    let chunk = try outputPipe.fileHandleForReading.read(upToCount: 4096) ?? Data()
                    if chunk.isEmpty {
                        break
                    }
                    guard output.count + chunk.count <= 16384 else { throw PacePlannerCredentialError.unavailable }
                    output.append(chunk)
                }
                process.waitUntilExit()
                try processControl.checkCancellation()
                guard process.terminationStatus == 0,
                    let value = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    isValidKey(value)
                else { throw PacePlannerCredentialError.unavailable }
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PacePlannerCredentialError.unavailable
            }
        }
        let value = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            processControl.stop()
            worker.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}
