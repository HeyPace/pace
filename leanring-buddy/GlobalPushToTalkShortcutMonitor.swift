//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a CGEvent tap for push-to-talk and consumes only the dedicated Fn+P chord.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private let shortcutOption: BuddyPushToTalkShortcut.ShortcutOption
    private var rightOptionHoldTask: Task<Void, Never>?
    private var functionPThread: Thread?
    private var functionPTapGeneration = UUID()

    init(shortcutOption: BuddyPushToTalkShortcut.ShortcutOption = BuddyPushToTalkShortcut.currentShortcutOption) {
        self.shortcutOption = shortcutOption
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    private(set) var isSimulatedPressActive = false

    deinit {
        stop()
    }

    /// Programmatically simulate a press transition — used by alternate
    /// entry points like the walking avatar tap so they fold into the
    /// same start-dictation pipeline as a real keyboard press. Keeps the
    /// internal `isShortcutCurrentlyPressed` state consistent so a
    /// subsequent real keypress doesn't see stale state.
    func simulateShortcutPressed() {
        guard !isShortcutCurrentlyPressed else { return }
        isShortcutCurrentlyPressed = true
        isSimulatedPressActive = true
        shortcutTransitionPublisher.send(.pressed)
    }

    /// Programmatically simulate a release transition. Mirror of
    /// `simulateShortcutPressed`. Idempotent.
    func simulateShortcutReleased() {
        guard isShortcutCurrentlyPressed else { return }
        isShortcutCurrentlyPressed = false
        isSimulatedPressActive = false
        shortcutTransitionPublisher.send(.released)
    }

    func discardSimulatedPress() {
        guard isSimulatedPressActive else { return }
        isSimulatedPressActive = false
        isShortcutCurrentlyPressed = false
    }

    func start() {
        if shortcutOption == .functionP {
            startFunctionPTap()
            return
        }
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        if let globalEventTap {
            if !CGEvent.tapIsEnabled(tap: globalEventTap) {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            recoverMissedModifierRelease(
                modifierFlagsRawValue: CGEventSource.flagsState(.combinedSessionState).rawValue)
            return
        }

        var monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        if shortcutOption == .rightOption {
            monitoredEventTypes += [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        }
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
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
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        cancelPendingRightOptionHold()
        functionPTapGeneration = UUID()
        functionPThread?.cancel()
        functionPThread = nil
        isShortcutCurrentlyPressed = false
        isSimulatedPressActive = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard !isSimulatedPressActive else { return Unmanaged.passUnretained(event) }
        if shortcutOption == .rightOption {
            handleRightOptionEvent(
                eventType, keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags)
            return Unmanaged.passUnretained(event)
        }
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let transition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed,
            option: shortcutOption
        )
        publishHardwareTransition(transition)
        return Unmanaged.passUnretained(event)
    }

    // NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK and kVK_RightOption from the macOS SDK.
    private static let rightOptionFlags: CGEventFlags = [.maskAlternate, CGEventFlags(rawValue: 0x40)]
    private static let excludedModifiers: CGEventFlags = [
        .maskControl, .maskShift, .maskCommand, .maskSecondaryFn, CGEventFlags(rawValue: 0x20),
    ]
    private static let rightOptionKeyCode: UInt16 = 61

    func handleRightOptionEvent(_ type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        let isShortcutKeyEvent = type == .flagsChanged && keyCode == Self.rightOptionKeyCode
        if !flags.intersection(Self.excludedModifiers).isEmpty
            || [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(type)
        {
            cancelPendingRightOptionHold()
            publishHardwareTransition(.cancelled)
            return
        }
        guard isShortcutKeyEvent else { return }
        guard flags.contains(Self.rightOptionFlags) else {
            cancelPendingRightOptionHold()
            publishHardwareTransition(.released)
            return
        }
        guard !isShortcutCurrentlyPressed, rightOptionHoldTask == nil else { return }
        // Let normal key combinations arrive before opening the microphone.
        rightOptionHoldTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.rightOptionHoldTask = nil
            guard !self.isSimulatedPressActive else { return }
            self.publishHardwareTransition(.pressed)
        }
    }

    private func cancelPendingRightOptionHold() {
        rightOptionHoldTask?.cancel()
        rightOptionHoldTask = nil
    }

    private func startFunctionPTap() {
        guard functionPThread == nil else { return }
        let generation = functionPTapGeneration
        let tap = PaceFunctionPEventTap { [weak self] transition in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.functionPTapGeneration == generation else { return }
                self.handleFunctionPTransition(transition)
            }
        }
        let thread = Thread { [weak self] in
            if !tap.run() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.functionPTapGeneration == generation else { return }
                    self.functionPThread = nil
                    print("⚠️ Global push-to-talk: couldn't create Fn+P event tap")
                }
            }
        }
        thread.name = "Pace Fn+P event tap"
        thread.qualityOfService = .userInteractive
        functionPThread = thread
        thread.start()
    }

    func handleFunctionPTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        if isSimulatedPressActive {
            // Pressing the physical shortcut ends an existing hands-free capture.
            if transition == .pressed { simulateShortcutReleased() }
            return
        }
        publishHardwareTransition(transition)
    }

    private func publishHardwareTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .none:
            break
        case .pressed:
            guard !isShortcutCurrentlyPressed else { return }
            isShortcutCurrentlyPressed = true
            isSimulatedPressActive = false
            shortcutTransitionPublisher.send(.pressed)
            recordHardwareTransition("keyboard_pressed")
        case .released, .cancelled:
            guard isShortcutCurrentlyPressed else { return }
            isShortcutCurrentlyPressed = false
            isSimulatedPressActive = false
            shortcutTransitionPublisher.send(transition)
            recordHardwareTransition(transition == .cancelled ? "keyboard_cancelled" : "keyboard_released")
        }
    }

    private func recordHardwareTransition(_ operation: String) {
        // Never perform file I/O inside the event tap; keep keyboard dispatch fast.
        Task { @MainActor in
            PaceAPIAuditLog.shared.record(
                subsystem: "dictation", operation: operation,
                target: "push-to-talk", durationMilliseconds: 0, outcome: "received",
                detail: "pid=\(ProcessInfo.processInfo.processIdentifier)")
        }
    }

    func recoverMissedModifierRelease(modifierFlagsRawValue: UInt64) {
        if shortcutOption == .rightOption {
            let flags = CGEventFlags(rawValue: modifierFlagsRawValue)
            guard !isSimulatedPressActive, !flags.contains(Self.rightOptionFlags) else { return }
            cancelPendingRightOptionHold()
            publishHardwareTransition(.released)
            return
        }
        guard isShortcutCurrentlyPressed, !isSimulatedPressActive,
            BuddyPushToTalkShortcut.shortcutTransition(
                for: .flagsChanged, keyCode: 0,
                modifierFlagsRawValue: modifierFlagsRawValue, wasShortcutPreviouslyPressed: true, option: shortcutOption
            ) == .released
        else { return }
        isShortcutCurrentlyPressed = false
        shortcutTransitionPublisher.send(.released)
        recordHardwareTransition("keyboard_recovered_release")
    }
}
