//
//  PaceActiveCallDetector.swift
//  leanring-buddy
//
//  Polls every five seconds for evidence the user is on a call. The
//  restraint policy reads `isOnActiveCall` so proactive nudges stay
//  silent (and get queued) during Zoom, Teams, FaceTime, Slack
//  huddles, etc.
//
//  With a call app open, other processes’ audio I/O pauses Watch. This
//  includes unrelated playback: helper ownership is not reliable enough to
//  exclude it safely. Silent idle apps no longer pause Watch indefinitely.
//  Metadata reads never record audio; unavailable reads retain the pause.
//

import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class PaceActiveCallDetector: ObservableObject {
    enum ProcessAudioSnapshot: Equatable {
        case idle
        case active
        case unavailable
    }

    enum ProcessAudioReadError: Error {
        case exited
        case unavailable
    }

    struct ProcessAudioActivity: Equatable {
        let processIdentifier: pid_t
        let inputIsRunning: Bool
        let outputIsRunning: Bool
    }

    @Published private(set) var isOnActiveCall: Bool = false

    /// Bundle identifiers Pace treats as "the user might be on a call".
    /// Match is case-insensitive. Keep this list intentionally narrow:
    /// the cost of a false positive is silenced proactive speech.
    ///
    /// Browser-only calls need a separate page-aware signal; no browser
    /// bundle alone identifies a call.
    nonisolated static let callBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.facetime",
        "com.tinyspeck.slackmacgap",
    ]

    private static let pollIntervalSeconds: TimeInterval = 5

    private let runningApplicationBundleIdentifiersProvider: () -> Set<String>
    private let processAudioSnapshotProvider: () -> ProcessAudioSnapshot
    private var pollTimer: Timer?

    init(
        runningApplicationBundleIdentifiersProvider: @escaping () -> Set<String> = PaceActiveCallDetector.liveRunningApplicationBundleIdentifiers,
        processAudioSnapshotProvider: @escaping () -> ProcessAudioSnapshot = PaceActiveCallDetector.liveProcessAudioSnapshot
    ) {
        self.runningApplicationBundleIdentifiersProvider = runningApplicationBundleIdentifiersProvider
        self.processAudioSnapshotProvider = processAudioSnapshotProvider
    }

    func start() {
        // Run one synchronous poll immediately so `isOnActiveCall` is
        // accurate the first time anyone reads it — without waiting
        // five seconds for the timer to tick.
        recomputeForTesting()

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeForTesting()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Public for tests. Runs one classification pass synchronously
    /// using whatever the injected provider returns. Production code
    /// can also call this manually after a known event (e.g., the
    /// menu-bar panel opening) to refresh without waiting for the
    /// next timer tick.
    func recomputeForTesting() {
        let currentlyRunningBundleIdentifiers = runningApplicationBundleIdentifiersProvider()
        guard currentlyRunningBundleIdentifiers.contains(where: { Self.callBundleIdentifiers.contains($0.lowercased()) }) else {
            isOnActiveCall = false
            return
        }
        isOnActiveCall = Self.hasActiveCall(
            runningBundleIdentifiers: currentlyRunningBundleIdentifiers,
            processAudioSnapshot: processAudioSnapshotProvider()
        )
    }

    static func hasActiveCall(
        runningBundleIdentifiers: Set<String>,
        processAudioSnapshot: ProcessAudioSnapshot
    ) -> Bool {
        guard runningBundleIdentifiers.contains(where: { callBundleIdentifiers.contains($0.lowercased()) }) else { return false }
        switch processAudioSnapshot {
        case .idle: return false
        case .active, .unavailable: return true
        }
    }

    nonisolated static func liveProcessAudioSnapshot() -> ProcessAudioSnapshot {
        var processListAddress = audioPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        var processListSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &processListAddress, 0, nil, &processListSize) == noErr,
              processListSize % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return .unavailable }
        guard processListSize > 0 else { return .idle }
        var processObjects = [AudioObjectID](repeating: 0, count: Int(processListSize) / MemoryLayout<AudioObjectID>.size)
        let processListStatus = processObjects.withUnsafeMutableBytes { processBytes in
            AudioObjectGetPropertyData(systemObject, &processListAddress, 0, nil, &processListSize, processBytes.baseAddress!)
        }
        guard processListStatus == noErr else { return .unavailable }
        return processAudioSnapshot(
            processObjects: Array(processObjects.prefix(Int(processListSize) / MemoryLayout<AudioObjectID>.size)),
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            processActivityProvider: processAudioActivity
        )
    }

    nonisolated static func processAudioSnapshot(
        processObjects: [AudioObjectID],
        ownProcessIdentifier: pid_t,
        processActivityProvider: (AudioObjectID) throws -> ProcessAudioActivity
    ) -> ProcessAudioSnapshot {
        for processObject in processObjects {
            do {
                let activity = try processActivityProvider(processObject)
                if activity.processIdentifier != ownProcessIdentifier,
                   activity.inputIsRunning || activity.outputIsRunning { return .active }
            } catch ProcessAudioReadError.exited {
                continue
            } catch {
                return .unavailable
            }
        }
        return .idle
    }

    private nonisolated static func processAudioActivity(_ processObject: AudioObjectID) throws -> ProcessAudioActivity {
        var processAddress = audioPropertyAddress(kAudioProcessPropertyPID)
        var processIdentifier: pid_t = 0
        var processSize = UInt32(MemoryLayout<pid_t>.size)
        let processStatus = AudioObjectGetPropertyData(processObject, &processAddress, 0, nil, &processSize, &processIdentifier)
        try validateProcessReadStatus(processStatus)
        guard processSize == MemoryLayout<pid_t>.size, processIdentifier > 0 else { throw ProcessAudioReadError.unavailable }
        if processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return ProcessAudioActivity(processIdentifier: processIdentifier, inputIsRunning: false, outputIsRunning: false)
        }
        let inputIsRunning = try audioActivity(processObject, selector: kAudioProcessPropertyIsRunningInput)
        let outputIsRunning = try audioActivity(processObject, selector: kAudioProcessPropertyIsRunningOutput)
        return ProcessAudioActivity(processIdentifier: processIdentifier, inputIsRunning: inputIsRunning, outputIsRunning: outputIsRunning)
    }

    private nonisolated static func audioActivity(_ processObject: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Bool {
        var propertyAddress = audioPropertyAddress(selector)
        var value: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &propertyAddress, 0, nil, &valueSize, &value)
        try validateProcessReadStatus(status)
        guard valueSize == MemoryLayout<UInt32>.size, value <= 1 else { throw ProcessAudioReadError.unavailable }
        return value == 1
    }

    private nonisolated static func validateProcessReadStatus(_ status: OSStatus) throws {
        if status == kAudioHardwareBadObjectError { throw ProcessAudioReadError.exited }
        guard status == noErr else { throw ProcessAudioReadError.unavailable }
    }

    private nonisolated static func audioPropertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Default live provider. Snapshots `NSWorkspace.runningApplications`
    /// into a `Set<String>` of bundle identifiers; nil identifiers (rare
    /// — typically agents without an Info.plist) are skipped.
    nonisolated static func liveRunningApplicationBundleIdentifiers() -> Set<String> {
        var collectedBundleIdentifiers: Set<String> = []
        for runningApplication in NSWorkspace.shared.runningApplications {
            if let bundleIdentifier = runningApplication.bundleIdentifier {
                collectedBundleIdentifiers.insert(bundleIdentifier)
            }
        }
        return collectedBundleIdentifiers
    }
}
