import Darwin
import Foundation

final class PacePowerJavaScriptService: NSObject, NSXPCListenerDelegate, PaceJavaScriptPowerServiceProtocol, @unchecked Sendable {
    private struct Evaluation {
        let request: PaceJavaScriptPowerRequest
        let requestData: Data
        let reply: (Data) -> Void
    }

    private final class ChildJob: @unchecked Sendable {
        let evaluation: Evaluation
        let processIdentifier: pid_t
        var reaped = false
        var output: Data?
        var failure: String?
        var watchdog: DispatchSourceTimer?
        var reapTimer: DispatchSourceTimer?

        init(evaluation: Evaluation, processIdentifier: pid_t) {
            self.evaluation = evaluation
            self.processIdentifier = processIdentifier
        }
    }

    private let controlQueue = DispatchQueue(label: "com.pace.power-javascript.control")
    private var activeJob: ChildJob?
    private var pendingEvaluation: Evaluation?
    private var cancelledRunIdentifiers: [String] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PaceJavaScriptPowerServiceProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func evaluate(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        controlQueue.async { [self] in
            guard requestData.count <= PaceJavaScriptPowerLimits.maximumSourceBytes * 8,
                  let request = try? JSONDecoder().decode(PaceJavaScriptPowerRequest.self, from: requestData),
                  request.source.utf8.count <= PaceJavaScriptPowerLimits.maximumSourceBytes,
                  !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0...23).contains(request.localHour), (1...7).contains(request.weekday),
                  UUID(uuidString: request.runIdentifier) != nil else {
                reply(Self.response(failure: "Invalid JavaScript evaluation request.")); return
            }
            guard !cancelledRunIdentifiers.contains(request.runIdentifier) else {
                reply(Self.response(failure: "JavaScript evaluation was cancelled.")); return
            }
            let evaluation = Evaluation(request: request, requestData: requestData, reply: reply)
            if activeJob != nil {
                guard pendingEvaluation == nil else {
                    reply(Self.response(failure: "JavaScript worker is busy.")); return
                }
                pendingEvaluation = evaluation
                return
            }
            start(evaluation)
        }
    }

    func cancel(_ runIdentifier: String) {
        controlQueue.async { [self] in
            if let activeJob, activeJob.evaluation.request.runIdentifier == runIdentifier {
                terminate(activeJob, failure: "JavaScript evaluation was cancelled.")
            } else if let pendingEvaluation, pendingEvaluation.request.runIdentifier == runIdentifier {
                self.pendingEvaluation = nil
                pendingEvaluation.reply(Self.response(failure: "JavaScript evaluation was cancelled."))
            }
            // A cancellation may arrive before evaluate on another XPC connection.
            cancelledRunIdentifiers.append(runIdentifier)
            if cancelledRunIdentifiers.count > 64 { cancelledRunIdentifiers.removeFirst() }
        }
    }

    private func start(_ evaluation: Evaluation) {
        let executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PacePowerJavaScriptWorker")
        let input = Pipe()
        let output = Pipe()
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            evaluation.reply(Self.response(failure: "JavaScript helper launch setup failed.")); return
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&fileActions)
            evaluation.reply(Self.response(failure: "JavaScript helper launch setup failed.")); return
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }
        // Only the three explicitly duplicated descriptors cross into generated-code computation.
        guard posix_spawn_file_actions_adddup2(&fileActions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            evaluation.reply(Self.response(failure: "JavaScript helper descriptor setup failed.")); return
        }
        let executablePath = strdup(executableURL.path)!
        defer { free(executablePath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [executablePath, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var processIdentifier: pid_t = 0
        let spawnResult = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&processIdentifier, executablePath, &fileActions, &attributes,
                    argumentBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        guard spawnResult == 0 else {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            evaluation.reply(Self.response(failure: "The isolated JavaScript compute helper could not start."))
            return
        }
        let job = ChildJob(evaluation: evaluation, processIdentifier: processIdentifier)
        activeJob = job
        let watchdog = DispatchSource.makeTimerSource(queue: controlQueue)
        watchdog.schedule(deadline: .now() + PaceJavaScriptPowerLimits.executionSeconds)
        watchdog.setEventHandler { [weak self, weak job] in
            guard let self, let job else { return }
            self.terminate(job, failure: "The Power exceeded its two-second computation time limit. No Power actions ran.")
        }
        job.watchdog = watchdog
        watchdog.resume()
        let reapTimer = DispatchSource.makeTimerSource(queue: controlQueue)
        reapTimer.schedule(deadline: .now(), repeating: .milliseconds(10))
        reapTimer.setEventHandler { [weak self, weak job] in
            guard let self, let job else { return }
            self.reap(job)
        }
        job.reapTimer = reapTimer
        reapTimer.resume()
        let inputHandle = input.fileHandleForWriting
        _ = fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async { [self, job] in
            do { try inputHandle.write(contentsOf: evaluation.requestData) }
            catch {
                controlQueue.async { [self, job] in terminate(job, failure: "JavaScript helper input failed.") }
            }
            try? inputHandle.close()
        }
        let outputHandle = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self, job] in
            var data = Data()
            var failure: String?
            do {
                while let chunk = try outputHandle.read(upToCount: 4096), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count > PaceJavaScriptPowerLimits.maximumOutputBytes {
                        failure = "JavaScript output exceeded 64 KiB."
                        data = Data()
                        break
                    }
                }
            } catch { failure = "JavaScript helper output failed." }
            try? outputHandle.close()
            let completedOutput = data
            let completedFailure = failure
            controlQueue.async { [self, job] in
                job.output = completedOutput
                if let completedFailure { terminate(job, failure: completedFailure) }
                finishIfReady(job)
            }
        }
    }

    private func terminate(_ job: ChildJob, failure: String) {
        guard activeJob === job else { return }
        if job.failure == nil { job.failure = failure }
        // This queue alone reaps the child. Its PID cannot be recycled before this owned kill.
        if !job.reaped { kill(job.processIdentifier, SIGKILL) }
        finishIfReady(job)
    }

    private func reap(_ job: ChildJob) {
        guard activeJob === job, !job.reaped else { return }
        var status: Int32 = 0
        let result = waitpid(job.processIdentifier, &status, WNOHANG)
        if result == 0 || (result < 0 && errno == EINTR) { return }
        job.reaped = true
        job.reapTimer?.cancel()
        job.reapTimer = nil
        job.watchdog?.cancel()
        job.watchdog = nil
        if (result < 0 || status != 0), job.failure == nil { job.failure = "JavaScript compute helper stopped before completing." }
        finishIfReady(job)
    }

    private func finishIfReady(_ job: ChildJob) {
        guard activeJob === job, job.reaped, let output = job.output else { return }
        let response = job.failure.map { Self.response(failure: $0) } ?? output
        activeJob = nil
        job.evaluation.reply(response)
        if let pendingEvaluation {
            self.pendingEvaluation = nil
            start(pendingEvaluation)
        }
    }

    private static func response(failure: String) -> Data {
        (try? JSONEncoder().encode(PaceJavaScriptPowerResponse(actions: [], failure: failure))) ?? Data()
    }
}

let service = PacePowerJavaScriptService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
