import CoreGraphics
import Foundation

nonisolated struct PaceFunctionPChord {
    private var ownsKeyPair = false
    private var isPressed = false

    mutating func handle(_ type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool)
        -> (consumesEvent: Bool, transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        if type == .flagsChanged {
            return (false, releaseIfNeeded(functionHeld: flags.contains(.maskSecondaryFn)))
        }
        guard keyCode == BuddyPushToTalkShortcut.functionPKeyCode else { return (false, .none) }
        if type == .keyUp {
            let consumed = ownsKeyPair
            ownsKeyPair = false
            return (consumed, releaseIfNeeded(functionHeld: false))
        }
        guard type == .keyDown else { return (false, .none) }
        if isRepeat { return (ownsKeyPair, .none) }
        let modifiers: CGEventFlags = [.maskSecondaryFn, .maskShift, .maskControl, .maskAlternate, .maskCommand]
        guard flags.intersection(modifiers) == .maskSecondaryFn else {
            ownsKeyPair = false
            return (false, releaseIfNeeded(functionHeld: false))
        }
        ownsKeyPair = true
        guard !isPressed else { return (true, .none) }
        isPressed = true
        return (true, .pressed)
    }

    mutating func releaseIfNeeded(functionHeld: Bool) -> BuddyPushToTalkShortcut.ShortcutTransition {
        guard isPressed, !functionHeld else { return .none }
        isPressed = false
        return .released
    }
}

// The worker owns the active tap and its chord state on one run loop. Only the
// transition callback crosses to the main queue, so unrelated typing never waits on SwiftUI.
nonisolated final class PaceFunctionPEventTap: @unchecked Sendable {
    private var chord = PaceFunctionPChord()
    private var tap: CFMachPort?
    private let didTransition: @Sendable (BuddyPushToTalkShortcut.ShortcutTransition) -> Void

    init(didTransition: @escaping @Sendable (BuddyPushToTalkShortcut.ShortcutTransition) -> Void) {
        self.didTransition = didTransition
    }

    func run() -> Bool {
        guard !Thread.current.isCancelled else { return true }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard !Thread.current.isCancelled, let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<PaceFunctionPEventTap>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        tap = port
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        defer {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            CFMachPortInvalidate(port)
            tap = nil
        }
        CGEvent.tapEnable(tap: port, enable: true)
        while !Thread.current.isCancelled, CFMachPortIsValid(port) {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
            if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
            let functionHeld = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
            if chord.releaseIfNeeded(functionHeld: functionHeld) == .released { didTransition(.released) }
        }
        return Thread.current.isCancelled
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let result = chord.handle(type, keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        if result.transition != .none { didTransition(result.transition) }
        return result.consumesEvent ? nil : Unmanaged.passUnretained(event)
    }
}
