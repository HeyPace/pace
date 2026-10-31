//
//  PaceScreenWatchMode.swift
//  leanring-buddy
//
//  Explicit watch-mode loop. The user-facing trigger is still future UI,
//  but the runtime primitive is here: sample screens, diff fingerprints,
//  and emit only meaningful visual changes.
//

import AppKit
import Combine
import Foundation

nonisolated struct PaceScreenWatchConfiguration {
    let sampleIntervalInSeconds: TimeInterval
    let minimumSecondsBetweenEvents: TimeInterval

    static let `default` = PaceScreenWatchConfiguration(
        sampleIntervalInSeconds: 3.0,
        minimumSecondsBetweenEvents: 2.5
    )
}

enum PaceScreenWatchEventCategory: Equatable {
    case majorScreenChange
    case contentUpdate
    case focusedRegionChange

    var displayName: String {
        switch self {
        case .majorScreenChange:
            return "major screen change"
        case .contentUpdate:
            return "content update"
        case .focusedRegionChange:
            return "focused region changed"
        }
    }
}

struct PaceScreenWatchEvent {
    let screenLabel: String
    let diff: PaceScreenImageDiff
    let category: PaceScreenWatchEventCategory
    let capture: CompanionScreenCapture
    let detectedAt: Date
}

struct PaceScreenWatchChangeDetector {
    private var previousFingerprintByScreenLabel: [String: PaceScreenVisualFingerprint] = [:]
    private var lastEventDateByScreenLabel: [String: Date] = [:]
    private let configuration: PaceScreenWatchConfiguration

    init(configuration: PaceScreenWatchConfiguration = .default) {
        self.configuration = configuration
    }

    mutating func meaningfulChanges(
        in captures: [CompanionScreenCapture],
        now: Date = Date()
    ) -> [PaceScreenWatchEvent] {
        var events: [PaceScreenWatchEvent] = []

        for capture in captures {
            guard let currentFingerprint = PaceScreenImageDiffer.fingerprint(for: capture.imageData) else {
                continue
            }

            defer {
                previousFingerprintByScreenLabel[capture.label] = currentFingerprint
            }

            guard let previousFingerprint = previousFingerprintByScreenLabel[capture.label],
                  let diff = PaceScreenImageDiffer.diff(
                    from: previousFingerprint,
                    to: currentFingerprint
                  ),
                  diff.isMeaningful else {
                continue
            }

            if let lastEventDate = lastEventDateByScreenLabel[capture.label],
               now.timeIntervalSince(lastEventDate) < configuration.minimumSecondsBetweenEvents {
                continue
            }

            lastEventDateByScreenLabel[capture.label] = now
            events.append(PaceScreenWatchEvent(
                screenLabel: capture.label,
                diff: diff,
                category: Self.category(for: diff),
                capture: capture,
                detectedAt: now
            ))
        }

        return events
    }

    mutating func reset() {
        previousFingerprintByScreenLabel.removeAll()
        lastEventDateByScreenLabel.removeAll()
    }

    static func category(for diff: PaceScreenImageDiff) -> PaceScreenWatchEventCategory {
        if diff.changedPixelRatio >= 0.35 || diff.meanPixelDelta >= 30 {
            return .majorScreenChange
        }

        if diff.changedPixelRatio >= 0.12 || diff.meanPixelDelta >= 14 {
            return .contentUpdate
        }

        return .focusedRegionChange
    }
}

@MainActor
final class PaceScreenWatchModeController {
    typealias EventHandler = @MainActor (PaceScreenWatchEvent) async -> Void

    private var watchTask: Task<Void, Never>?
    private var watchGeneration: UInt64 = 0
    private var changeDetector: PaceScreenWatchChangeDetector
    private let configuration: PaceScreenWatchConfiguration

    /// Combine multiplex of meaningful watch events. Sibling consumers
    /// like the proactive nudge generator subscribe here so the
    /// callback-based `startWatching(onMeaningfulChange:)` consumer
    /// keeps its single-handler shape unchanged.
    let eventPublisher = PassthroughSubject<PaceScreenWatchEvent, Never>()

    init(configuration: PaceScreenWatchConfiguration = .default) {
        self.configuration = configuration
        self.changeDetector = PaceScreenWatchChangeDetector(configuration: configuration)
    }


    func startWatching(
        for durationInSeconds: TimeInterval? = nil,
        shouldCapture: @escaping @MainActor () -> Bool = { true },
        onSample: (@MainActor (CompanionScreenCapture, PaceScreenSceneIdentity, Date) -> Void)? = nil,
        onMeaningfulChange: @escaping EventHandler
    ) {
        stopWatching()
        changeDetector.reset()

        let watchStartDate = Date()
        let generationForWatch = watchGeneration
        watchTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                if let durationInSeconds,
                   Date().timeIntervalSince(watchStartDate) >= durationInSeconds {
                    break
                }

                do {
                    guard shouldCapture() else {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        continue
                    }
                    let applicationBeforeCapture = NSWorkspace.shared.frontmostApplication
                    let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(watchOnly: onSample != nil)
                    guard !Task.isCancelled, shouldCapture(),
                          applicationBeforeCapture?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else { continue }
                    if let applicationBeforeCapture, let bundleIdentifier = applicationBeforeCapture.bundleIdentifier {
                        for capture in captures {
                            onSample?(capture, PaceScreenSceneIdentity(displayIdentifier: capture.displayIdentifier,
                                applicationProcessIdentifier: applicationBeforeCapture.processIdentifier,
                                applicationBundleIdentifier: bundleIdentifier), Date())
                        }
                    }
                    let events = self.changeDetector.meaningfulChanges(in: captures)
                    for event in events {
                        self.eventPublisher.send(event)
                        await onMeaningfulChange(event)
                    }
                } catch {
                    print("⚠️ Pace watch mode capture failed: \(error.localizedDescription)")
                }

                let sleepNanoseconds = UInt64(configuration.sampleIntervalInSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }

            if self.watchGeneration == generationForWatch { self.watchTask = nil }
        }
    }

    func stopWatching() {
        watchGeneration &+= 1
        watchTask?.cancel()
        watchTask = nil
        changeDetector.reset()
    }
}
