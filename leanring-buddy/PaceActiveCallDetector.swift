//
//  PaceActiveCallDetector.swift
//  leanring-buddy
//
//  Polls every five seconds for evidence the user is on a call. The
//  restraint policy reads `isOnActiveCall` so proactive nudges stay
//  silent (and get queued) during Zoom, Teams, FaceTime, Slack
//  huddles, etc.
//
//  CoreAudio process metadata distinguishes idle call apps from audio
//  I/O without recording audio. Unknown telemetry retains the conservative
//  running-app fallback, so a failed read cannot enable Watch during a call.
//

import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
final class PaceActiveCallDetector: ObservableObject {
    enum ProcessAudioSnapshot: Equatable {
        case available(activeBundleIdentifiers: Set<String>)
        case unavailable
    }

    @Published private(set) var isOnActiveCall: Bool = false

    /// Bundle identifiers Pace treats as "the user might be on a call".
    /// Match is case-insensitive. Keep this list intentionally narrow:
    /// the cost of a false positive is silenced proactive speech.
    ///
    /// Browser calls need a separate page-aware signal; browser audio
    /// alone cannot distinguish a meeting from ordinary media playback.
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
        isOnActiveCall = Self.hasActiveCall(
            runningBundleIdentifiers: currentlyRunningBundleIdentifiers,
            processAudioSnapshot: processAudioSnapshotProvider()
        )
    }

    static func hasActiveCall(
        runningBundleIdentifiers: Set<String>,
        processAudioSnapshot: ProcessAudioSnapshot
    ) -> Bool {
        let runningCallBundleIdentifiers = Set(runningBundleIdentifiers.map { $0.lowercased() })
            .intersection(callBundleIdentifiers.map { $0.lowercased() })
        guard !runningCallBundleIdentifiers.isEmpty else { return false }
        guard case .available(let activeBundleIdentifiers) = processAudioSnapshot else { return true }
        return activeBundleIdentifiers.contains { activeBundleIdentifier in
            let normalizedActiveBundleIdentifier = activeBundleIdentifier.lowercased()
            if runningCallBundleIdentifiers.contains("com.apple.facetime"),
               ["com.apple.avconferenced", "com.apple.telephonyutilities"].contains(normalizedActiveBundleIdentifier) {
                return true
            }
            return runningCallBundleIdentifiers.contains { callBundleIdentifier in
                normalizedActiveBundleIdentifier == callBundleIdentifier
                    || normalizedActiveBundleIdentifier.hasPrefix(callBundleIdentifier + ".")
            }
        }
    }

    nonisolated static func liveProcessAudioSnapshot() -> ProcessAudioSnapshot {
        var processListAddress = audioPropertyAddress(kAudioHardwarePropertyProcessObjectList)
        var processListSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &processListAddress, 0, nil, &processListSize) == noErr,
              processListSize % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return .unavailable }
        guard processListSize > 0 else { return .available(activeBundleIdentifiers: []) }
        var processObjects = [AudioObjectID](repeating: 0, count: Int(processListSize) / MemoryLayout<AudioObjectID>.size)
        let processListStatus = processObjects.withUnsafeMutableBytes { processBytes in
            AudioObjectGetPropertyData(systemObject, &processListAddress, 0, nil, &processListSize, processBytes.baseAddress!)
        }
        guard processListStatus == noErr else { return .unavailable }
        var activeBundleIdentifiers: Set<String> = []
        for processObject in processObjects.prefix(Int(processListSize) / MemoryLayout<AudioObjectID>.size) {
            guard let inputIsRunning = audioActivity(processObject, selector: kAudioProcessPropertyIsRunningInput),
                  let outputIsRunning = audioActivity(processObject, selector: kAudioProcessPropertyIsRunningOutput) else { return .unavailable }
            guard inputIsRunning || outputIsRunning else { continue }
            var bundleAddress = audioPropertyAddress(kAudioProcessPropertyBundleID)
            var bundleIdentifier: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleStatus = AudioObjectGetPropertyData(processObject, &bundleAddress, 0, nil, &bundleSize, &bundleIdentifier)
            guard bundleStatus == noErr, let bundleIdentifier else { return .unavailable }
            let activeBundleIdentifier = bundleIdentifier.takeRetainedValue() as String
            guard !activeBundleIdentifier.isEmpty else { return .unavailable }
            activeBundleIdentifiers.insert(activeBundleIdentifier)
        }
        return .available(activeBundleIdentifiers: activeBundleIdentifiers)
    }

    private nonisolated static func audioActivity(_ processObject: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool? {
        var propertyAddress = audioPropertyAddress(selector)
        var value: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(processObject, &propertyAddress, 0, nil, &valueSize, &value) == noErr,
              valueSize == MemoryLayout<UInt32>.size, value <= 1 else { return nil }
        return value == 1
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
