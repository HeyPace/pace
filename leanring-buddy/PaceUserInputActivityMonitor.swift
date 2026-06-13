//
//  PaceUserInputActivityMonitor.swift
//  leanring-buddy
//
//  Listen-only global CGEventTap that publishes the timestamp of the
//  most recent user-driven mouse / keyboard / scroll event. The
//  restraint policy reads this so a proactive nudge that lands while
//  the user is mid-input gets queued until the user actually pauses,
//  instead of stepping on a keystroke.
//
//  Lifecycle mirrors `GlobalPushToTalkShortcutMonitor`: a single tap
//  on the HID event tap with a passthrough run-loop source. The tap
//  callback is intentionally cheap — it stamps a `Date()` and
//  publishes through `@Published`. Nothing per-event is allocated
//  beyond that.
//
//  Accessibility permission is the same prerequisite the push-to-talk
//  monitor relies on; if AX is not granted, `start()` logs and no-ops
//  rather than failing repeatedly inside the macOS sandbox.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class PaceUserInputActivityMonitor: ObservableObject {
    /// Timestamp of the most recent observed user-driven input event.
    /// `nil` until the first event lands or `recordEventForTesting`
    /// is called. Read by `PaceRestraintGate` (via the manager-built
    /// context) to decide whether a proactive utterance should be
    /// queued instead of spoken.
    @Published private(set) var lastUserInputAt: Date?

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    deinit {
        // `stop()` only touches CoreFoundation handles — safe to call
        // from a non-main isolation domain during dealloc.
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
        }
    }

    func start() {
        guard globalEventTap == nil else { return }

        // Accessibility is required for a session-wide CGEvent tap on
        // user input. If we don't have it yet, log and bail; the
        // permission poller will call `start()` again once granted.
        guard AXIsProcessTrusted() else {
            print("⚠️ PaceUserInputActivityMonitor: Accessibility not granted — input activity monitoring disabled until permission is given.")
            return
        }

        // `CGEventMaskBit(.foo)` from the C headers doesn't bridge to
        // Swift; build the mask the same way `GlobalPushToTalkShortcut
        // Monitor` does (left-shift the raw event type into a
        // `CGEventMask`). Mouse-down events come in via the
        // left/right/other variants — we cover all three so a touchpad
        // right-click or middle-click stamps `lastUserInputAt` too.
        let monitoredEventTypes: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown,
            .scrollWheel,
        ]
        let monitoredEventMask: CGEventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, _, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let userInputActivityMonitor = Unmanaged<PaceUserInputActivityMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            userInputActivityMonitor.handleObservedInputEventFromTapCallback(at: Date())
            return Unmanaged.passUnretained(event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: monitoredEventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ PaceUserInputActivityMonitor: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ PaceUserInputActivityMonitor: couldn't create event tap run-loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    /// Test seam: drives the same `lastUserInputAt` publication path
    /// the live CGEvent callback uses, without requiring a real
    /// system-wide event tap (which needs Accessibility and a CFRunLoop
    /// turn). XCTests call this directly so input-activity behavior
    /// stays unit-testable.
    func recordEventForTesting(at timestamp: Date) {
        lastUserInputAt = timestamp
    }

    /// CGEvent tap callback entry point. The tap's run-loop source is
    /// attached to `CFRunLoopGetMain()`, so this is already on the main
    /// thread; the `nonisolated` lets us skip an extra Task hop while
    /// keeping the rest of the class @MainActor-isolated for state
    /// publication and lifecycle calls.
    private nonisolated func handleObservedInputEventFromTapCallback(at timestamp: Date) {
        MainActor.assumeIsolated {
            self.lastUserInputAt = timestamp
        }
    }
}
