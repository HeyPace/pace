//
//  PaceClickFollowAlongMonitor.swift
//  leanring-buddy
//
//  Listen-only `CGEventTap` that feeds global left-mouse-down
//  events into a `PaceClickFollowAlongController`. Translates the
//  CG-global click point into screenshot-pixel coordinates against
//  the correct NSScreen so the controller's matcher can check the
//  click against the current step's bbox.
//
//  This mirrors `GlobalPushToTalkShortcutMonitor`'s machinery —
//  same tap creation pattern, same `.listenOnly` posture so we
//  never preempt the user's real click. The user always sees the
//  click hit the underlying app; the monitor just observes whether
//  the click also matched the active step's target.
//
//  Lifecycle:
//   • `start()` — installs the tap on the main run loop.
//   • `stop()`  — invalidates the tap; safe to call when not started.
//   • Internally idempotent — multiple `start()` calls are no-ops.
//
//  Touch + accessibility: the tap doesn't fire on Touch-Bar taps
//  or trackpad gestures that don't produce a real click event.
//  That's the correct posture — we only auto-advance on actual
//  clicks the user took intentionally.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class PaceClickFollowAlongMonitor {

    private let followAlongController: PaceClickFollowAlongController
    private let screenLabelResolver: (CGPoint) -> String?

    private var installedEventTap: CFMachPort?
    private var installedRunLoopSource: CFRunLoopSource?

    init(
        controller: PaceClickFollowAlongController,
        screenLabelResolver: @escaping (CGPoint) -> String?
    ) {
        self.followAlongController = controller
        self.screenLabelResolver = screenLabelResolver
    }

    /// Install the CGEventTap on the main run loop. Idempotent —
    /// calling twice without a `stop()` in between just returns.
    func start() {
        guard installedEventTap == nil else { return }
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue)

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitorInstance = Unmanaged<PaceClickFollowAlongMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            monitorInstance.handleGlobalEventTap(eventType: eventType, event: event)
            // Always pass the event through unchanged — we're
            // listen-only, never preempting the user's click.
            return Unmanaged.passUnretained(event)
        }

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ PaceClickFollowAlongMonitor: couldn't create CGEvent tap (Accessibility permission?)")
            return
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            createdTap,
            0
        ) else {
            CFMachPortInvalidate(createdTap)
            print("⚠️ PaceClickFollowAlongMonitor: couldn't create event tap run loop source")
            return
        }

        self.installedEventTap = createdTap
        self.installedRunLoopSource = createdRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
    }

    func stop() {
        if let installedRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), installedRunLoopSource, .commonModes)
            self.installedRunLoopSource = nil
        }
        if let installedEventTap {
            CGEvent.tapEnable(tap: installedEventTap, enable: false)
            CFMachPortInvalidate(installedEventTap)
            self.installedEventTap = nil
        }
    }

    private func handleGlobalEventTap(eventType: CGEventType, event: CGEvent) {
        guard eventType == .leftMouseDown else { return }
        // Only do the (potentially expensive) coordinate mapping
        // when there's actually a follow-along sequence active.
        // Idle clicks pay zero cost.
        guard followAlongController.isAwaitingClick else { return }

        let clickPointInCGGlobal = event.location
        guard let screenLabel = screenLabelResolver(clickPointInCGGlobal) else {
            return
        }
        guard let clickPointInScreenshotPixels = Self.convertCGGlobalPointToScreenshotPixels(
            cgGlobalPoint: clickPointInCGGlobal
        ) else {
            return
        }
        followAlongController.handleGlobalClick(
            clickPointInScreenshotPixels: clickPointInScreenshotPixels,
            clickedScreenLabel: screenLabel
        )
    }

    // MARK: - Coordinate conversion (pure, testable)

    /// Convert a CG-global mouse-down location to screenshot-pixel
    /// coordinates within whichever NSScreen contains the point.
    ///
    /// CGEvent.location uses screen-points (NOT pixels) in a
    /// top-left-origin global coordinate space anchored to the
    /// primary display. NSScreen.frame uses bottom-left-origin
    /// AppKit globals in points. ScreenCaptureKit screenshots are
    /// captured in PIXELS at the screen's backing scale factor.
    ///
    /// So we:
    ///   1. Find the NSScreen whose `frame` (converted to top-
    ///      left) contains the click point in points.
    ///   2. Compute the point's offset from that screen's top-left
    ///      in points.
    ///   3. Multiply by the screen's `backingScaleFactor` to get
    ///      screenshot pixels.
    ///
    /// Returns nil when no screen contains the point (e.g. the
    /// user yanked an external display mid-click).
    nonisolated static func convertCGGlobalPointToScreenshotPixels(
        cgGlobalPoint: CGPoint
    ) -> CGPoint? {
        guard let screens = NSScreen.screens as [NSScreen]?,
              let primaryScreen = screens.first else {
            return nil
        }
        let primaryScreenHeight = primaryScreen.frame.height

        // Convert the CG-global TOP-LEFT-origin point into AppKit
        // BOTTOM-LEFT-origin so we can match it against
        // NSScreen.frame.
        let pointInAppKitGlobal = CGPoint(
            x: cgGlobalPoint.x,
            y: primaryScreenHeight - cgGlobalPoint.y
        )

        for screen in screens {
            if screen.frame.contains(pointInAppKitGlobal) {
                // Screen's TOP-LEFT in AppKit globals = (frame.minX,
                // frame.maxY). Offset of point from top-left:
                //   dx = point.x - frame.minX
                //   dy = frame.maxY - point.y
                let offsetXInPoints = pointInAppKitGlobal.x - screen.frame.minX
                let offsetYInPoints = screen.frame.maxY - pointInAppKitGlobal.y
                let backingScale = screen.backingScaleFactor
                return CGPoint(
                    x: offsetXInPoints * backingScale,
                    y: offsetYInPoints * backingScale
                )
            }
        }
        return nil
    }
}
