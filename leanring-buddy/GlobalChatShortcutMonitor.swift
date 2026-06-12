//
//  GlobalChatShortcutMonitor.swift
//  leanring-buddy
//
//  Mirrors `GlobalPushToTalkShortcutMonitor` but for the notch chat-
//  input shortcut (default `cmd+shift+P`, configurable via Info.plist
//  key `NotchChatShortcut`). Uses the same listen-only CGEvent tap so
//  the shortcut fires regardless of which app is frontmost — opening
//  the chat input is intentionally always reachable.
//
//  Unlike push-to-talk, the chat shortcut is a single edge event
//  (press), not a hold. The monitor still uses a CGEvent tap so the
//  behavior matches the rest of Pace's keyboard interception layer.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

enum PaceNotchChatShortcut {
    /// The shortcut options we accept in Info.plist `NotchChatShortcut`.
    /// All are reasonable, conflict-free defaults; the user picks one
    /// to avoid clashes with their other tools (VS Code/Cursor use
    /// cmd+shift+P for the command palette, for instance).
    enum ShortcutOption {
        case commandShiftP
        case commandShiftK
        case commandShiftSpace
        case controlShiftP
        case controlShiftSpace

        /// AppKit key codes for the non-modifier key in the shortcut.
        /// 35 = P, 40 = K, 49 = Space.
        fileprivate var keyCode: UInt16 {
            switch self {
            case .commandShiftP, .controlShiftP:
                return 35
            case .commandShiftK:
                return 40
            case .commandShiftSpace, .controlShiftSpace:
                return 49
            }
        }

        fileprivate var requiredModifierFlags: NSEvent.ModifierFlags {
            switch self {
            case .commandShiftP, .commandShiftK, .commandShiftSpace:
                return [.command, .shift]
            case .controlShiftP, .controlShiftSpace:
                return [.control, .shift]
            }
        }
    }

    /// Resolved once at app launch from Info.plist key `NotchChatShortcut`.
    /// Accepted values (case-insensitive, hyphens/underscores ignored):
    ///   - `commandShiftP` / `cmd+shift+p`    (DEFAULT)
    ///   - `commandShiftK` / `cmd+shift+k`
    ///   - `commandShiftSpace` / `cmd+shift+space`
    ///   - `controlShiftP` / `ctrl+shift+p`
    ///   - `controlShiftSpace` / `ctrl+shift+space`
    /// Unknown or missing values fall back to `commandShiftP`.
    static let currentShortcutOption: ShortcutOption = {
        let rawConfiguredValue = AppBundleConfiguration
            .stringValue(forKey: "NotchChatShortcut")?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch rawConfiguredValue {
        case "commandshiftk", "cmd+shift+k", "cmdshiftk":
            return .commandShiftK
        case "commandshiftspace", "cmd+shift+space", "cmdshiftspace":
            return .commandShiftSpace
        case "controlshiftp", "ctrl+shift+p", "ctrlshiftp":
            return .controlShiftP
        case "controlshiftspace", "ctrl+shift+space", "ctrlshiftspace":
            return .controlShiftSpace
        case "commandshiftp", "cmd+shift+p", "cmdshiftp", .none:
            return .commandShiftP
        default:
            print("⚠️ Unknown NotchChatShortcut '\(rawConfiguredValue ?? "nil")', falling back to cmd+shift+p")
            return .commandShiftP
        }
    }()

    /// Pure helper used by the live event tap and by unit tests so the
    /// detection logic can be verified without simulating real CGEvents.
    /// Returns `true` when the (keyCode, modifierFlags) pair matches the
    /// active configured chat shortcut on a keyDown event.
    static func isChatShortcutPressed(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        eventType: CGEventType
    ) -> Bool {
        guard eventType == .keyDown else { return false }
        let option = currentShortcutOption
        guard keyCode == option.keyCode else { return false }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return modifierFlags.isSuperset(of: option.requiredModifierFlags)
    }
}

final class GlobalChatShortcutMonitor: ObservableObject {
    /// Fires once per accepted `cmd+shift+P` (or the user-configured
    /// alternative). Subscribers are expected to flip
    /// `CompanionManager.isNotchChatInputFocused` and bring the panel
    /// forward.
    let chatShortcutPressed = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    deinit {
        stop()
    }

    /// Programmatic simulation hook so the deeplink layer (or future
    /// alt entry points) can fold into the same `chatShortcutPressed`
    /// subscriber path as a real key press.
    func simulateShortcutPressed() {
        chatShortcutPressed.send(())
    }

    func start() {
        guard globalEventTap == nil else { return }

        // The chat shortcut is a key-plus-modifier combo, so we only
        // need `keyDown` events (modifier-only flagsChanged would fire
        // far more often and never resolve to our shortcut).
        let monitoredEventTypes: [CGEventType] = [.keyDown]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalChatShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return monitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global chat shortcut: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global chat shortcut: couldn't create event tap run loop source")
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

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isMatch = PaceNotchChatShortcut.isChatShortcutPressed(
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            eventType: eventType
        )

        if isMatch {
            chatShortcutPressed.send(())
        }

        return Unmanaged.passUnretained(event)
    }
}
