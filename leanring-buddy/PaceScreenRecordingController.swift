import AVFoundation
import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PaceScreenRecordingController {
    static let shared = PaceScreenRecordingController()

    private let recordingsDirectory: URL
    private let screenRecordingPermissionCheck: () -> Bool
    private var recordingProcess: Process?
    private var recordingURL: URL?
    private var lastSavedRecordingURL: URL?
    private var stoppingTask: Task<PaceActionExecutionObservation, Never>?

    init(
        recordingsDirectory: URL? = nil,
        screenRecordingPermissionCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.recordingsDirectory =
            recordingsDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pace/screen-recordings", isDirectory: true)
        self.screenRecordingPermissionCheck = screenRecordingPermissionCheck
    }

    func start() async -> PaceActionExecutionObservation {
        guard stoppingTask == nil else {
            return observation("Screen recording is finishing; wait before starting another.")
        }
        if recordingProcess?.isRunning == true { return status() }
        guard screenRecordingPermissionCheck() else {
            return observation(
                "Could not start screen recording: grant Pace Screen Recording access in Privacy & Security.")
        }
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            let outputURL = recordingsDirectory.appendingPathComponent("Pace-" + UUID().uuidString + ".mov")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-v", "-D", "1", "-x", outputURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            recordingProcess = process
            recordingURL = outputURL
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return await stop() }
            guard process.isRunning else {
                recordingProcess = nil
                recordingURL = nil
                return observation("Could not start screen recording (exit \(process.terminationStatus)).")
            }
            return observation(
                "Screen recording is active on the main display. Say 'stop screen recording' to save it.")
        } catch {
            return observation("Failed to start screen recording: \(error.localizedDescription)")
        }
    }

    func stop() async -> PaceActionExecutionObservation {
        if let stoppingTask { return await stoppingTask.value }
        guard let process = recordingProcess, let outputURL = recordingURL else {
            return status()
        }
        let task = Task { await finishRecording(process: process, outputURL: outputURL) }
        stoppingTask = task
        let result = await task.value
        stoppingTask = nil
        return result
    }

    func status() -> PaceActionExecutionObservation {
        if stoppingTask != nil { return observation("Screen recording is finishing and saving locally.") }
        if recordingProcess?.isRunning == true {
            return observation(
                "Screen recording is active on the main display. Say 'stop screen recording' to save it.")
        }
        if let lastSavedRecordingURL {
            return observation("Screen recording is stopped. Last saved movie: \(lastSavedRecordingURL.path)")
        }
        return observation("Pace has no active screen recording.")
    }

    func shutdown() {
        guard let process = recordingProcess, process.isRunning else { return }
        // Request the recorder's normal finish, rather than killing a writer
        // mid-file when Pace quits. Only touch a recording this instance owns.
        if !pressNativeStopRecordingButton() { process.interrupt() }
    }

    private func finishRecording(process: Process, outputURL: URL) async -> PaceActionExecutionObservation {
        if process.isRunning, !pressNativeStopRecordingButton() { process.interrupt() }
        for _ in 0..<60 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !process.isRunning else {
            return observation(
                "Could not finish screen recording yet. It remains active; try stop screen recording again.")
        }
        if recordingProcess === process {
            recordingProcess = nil
            recordingURL = nil
        }
        do {
            let asset = AVURLAsset(url: outputURL)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard duration.seconds.isFinite, duration.seconds > 0, !videoTracks.isEmpty else {
                return observation(
                    "Could not verify the saved screen recording. The output is preserved at \(outputURL.path)")
            }
            lastSavedRecordingURL = outputURL
            return observation(
                "Screen recording stopped and saved (\(Int(duration.seconds.rounded())) seconds): \(outputURL.path)")
        } catch {
            return observation(
                "Failed to verify the screen recording: \(error.localizedDescription). Output: \(outputURL.path)")
        }
    }

    private func pressNativeStopRecordingButton() -> Bool {
        guard
            let application = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.screencaptureui"
            })
        else { return false }
        var pendingElements = [AXUIElementCreateApplication(application.processIdentifier)]
        var inspectedElementCount = 0
        while !pendingElements.isEmpty, inspectedElementCount < 64 {
            let element = pendingElements.removeFirst()
            inspectedElementCount += 1
            let title = PaceActionExecutor.stringAttribute(kAXTitleAttribute as CFString, of: element)
            let description = PaceActionExecutor.stringAttribute(kAXDescriptionAttribute as CFString, of: element)
            if title == "Stop Screen Recording" || description == "Stop Screen Recording" {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            pendingElements.append(contentsOf: PaceActionExecutor.children(of: element))
        }
        return false
    }

    private func observation(_ summary: String) -> PaceActionExecutionObservation {
        .init(toolName: "screen_capture", summary: summary)
    }
}
