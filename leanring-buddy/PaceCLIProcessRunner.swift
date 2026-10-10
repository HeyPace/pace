import Darwin
import Foundation

nonisolated enum PaceCLIProcessError: LocalizedError {
    case timedOut
    case failed(Int32, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The planner timed out. Try again or cancel the turn."
        case .failed(let status, let message): return "Planner exited with status \(status). \(message)"
        case .emptyResponse: return "The planner returned no answer. Check the CLI sign-in and try again."
        }
    }
}

// Cancellation also covers the interval before Process.run(), so an already
// cancelled voice turn cannot launch a new CLI after the UI has returned idle.
nonisolated final class PaceCLIProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var timeoutReached = false

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested else { throw CancellationError() }
        self.process = process
        try process.run()
    }

    func stop(timedOut: Bool = false) {
        lock.lock()
        cancellationRequested = true
        timeoutReached = timeoutReached || timedOut
        let runningProcess = process
        lock.unlock()
        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if runningProcess.isRunning {
                kill(runningProcess.processIdentifier, SIGKILL)
            }
        }
    }

    func checkCancellation() throws {
        lock.lock()
        let wasCancelled = cancellationRequested
        let wasTimedOut = timeoutReached
        lock.unlock()
        if wasTimedOut { throw PaceCLIProcessError.timedOut }
        if wasCancelled { throw CancellationError() }
    }
}

nonisolated enum PaceCLIProcessRunner {
    static func lines(
        executableURL: URL,
        arguments: [String],
        stdinPayload: String,
        workingDirectoryURL: URL,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<String, Error> {
        let processControl = PaceCLIProcessControl()
        return AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try runBlocking(
                        executableURL: executableURL,
                        arguments: arguments,
                        stdinPayload: stdinPayload,
                        workingDirectoryURL: workingDirectoryURL,
                        environment: environment,
                        timeout: timeout,
                        processControl: processControl,
                        onLine: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    processControl.stop()
                    worker.cancel()
                }
            }
        }
    }

    private static func runBlocking(
        executableURL: URL,
        arguments: [String],
        stdinPayload: String,
        workingDirectoryURL: URL,
        environment: [String: String]?,
        timeout: TimeInterval,
        processControl: PaceCLIProcessControl,
        onLine: @escaping @Sendable (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe

        // A file avoids the classic full-stderr-pipe deadlock while stdout is
        // being read. It is private, per-call, and removed after the call.
        let errorFileURL = workingDirectoryURL.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorFileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errorFile = try FileHandle(forWritingTo: errorFileURL)
        process.standardError = errorFile
        defer {
            try? errorFile.close()
            try? FileManager.default.removeItem(at: errorFileURL)
        }

        try processControl.launch(process)
        let timeoutWork = DispatchWorkItem { processControl.stop(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout), execute: timeoutWork)
        defer {
            timeoutWork.cancel()
            if process.isRunning { processControl.stop() }
            try? inputPipe.fileHandleForWriting.close()
        }

        try inputPipe.fileHandleForWriting.write(contentsOf: Data(stdinPayload.utf8))
        try inputPipe.fileHandleForWriting.close()
        var pendingBytes = Data()
        while true {
            try processControl.checkCancellation()
            let availableBytes = outputPipe.fileHandleForReading.availableData
            if availableBytes.isEmpty { break }
            pendingBytes.append(availableBytes)
            while let newlineIndex = pendingBytes.firstIndex(of: 10) {
                onLine(String(decoding: pendingBytes[..<newlineIndex], as: UTF8.self))
                pendingBytes.removeSubrange(...newlineIndex)
            }
        }
        if !pendingBytes.isEmpty { onLine(String(decoding: pendingBytes, as: UTF8.self)) }
        process.waitUntilExit()
        try processControl.checkCancellation()
        guard process.terminationStatus == 0 else {
            let errorReader = try FileHandle(forReadingFrom: errorFileURL)
            defer { try? errorReader.close() }
            let excerpt = try errorReader.read(upToCount: 300) ?? Data()
            throw PaceCLIProcessError.failed(process.terminationStatus, String(decoding: excerpt, as: UTF8.self))
        }
    }
}
