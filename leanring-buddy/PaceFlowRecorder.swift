//
//  PaceFlowRecorder.swift
//  leanring-buddy
//
//  Listen-only CGEventTap that turns live user input into a typed
//  `PaceRecordedStep` stream so the user can record a demonstration
//  once and replay it later via `run_flow`.
//
//  Design notes (RAM budget — CRITICAL)
//  ------------------------------------
//  This recorder sits behind a feature gate that flips a global event
//  tap on, so it MUST be cheap to keep running and MUST release every
//  resource as soon as it stops.
//
//   - The CGEventTap is created with `.listenOnly` and only listens
//     for the four event types we actually use (`.leftMouseDown`,
//     `.keyDown`, `.flagsChanged`, `.rightMouseDown`). Each event
//     allocates exactly one `PaceRecordedStep` enum value plus a few
//     small string fields — there is no per-event buffer growth on
//     the hot path.
//   - The recorder auto-stops after 60s of idle to release the tap so
//     LM Studio + Apple FM + Kokoro don't compete with a dormant event
//     pump for system resources. A user who wanted to keep recording
//     can simply restart with another voice command.
//   - Typing buffers are capped per focus context (`typingBufferMax
//     CharacterCount = 256`). Once the cap is hit the buffer is
//     flushed immediately as a `typeText` step and a fresh buffer is
//     started, so a runaway autocomplete loop can't OOM us.
//   - Secure (`AXSecureTextField`) focus suppresses the live keystroke
//     buffer entirely. The buffer stays empty and the eventual flush
//     emits a single `typeText(secure: true)` placeholder. The actual
//     keystrokes never enter Pace's memory.
//
//  State machine
//  -------------
//  `idle → recording → stoppedReason(...)`. There is no `paused`
//  state; the only way to resume after a stop is `start(flowName:)`.
//
//  The class is `@MainActor` because the CGEventTap source is
//  attached to `CFRunLoopGetMain()` and because `PaceAXTargeter`'s
//  AX-tree calls are documented as main-thread-safe — running both on
//  the same actor keeps state mutations simple and audit-able.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

// MARK: - Output types

/// A single hop in the AX ancestor chain captured at the moment of an
/// `axPress`. Stored separately from `PaceRecordedStep.axPress`'s
/// existing `rolePath: [String]` so the replayer can re-target by
/// (role, identifier, label) instead of brittle pixel coordinates.
///
/// `PaceRecordedStep` already exists and ships in the on-disk schema;
/// we don't widen its shape here because doing so would break recipe
/// JSON. Wave 3b's replayer reconstructs a `PaceAXRolePath` from the
/// recorded `rolePath` + `label` on demand.
struct PaceAXRolePath: Equatable {
    struct Hop: Equatable {
        let role: String
        let identifier: String?
        let label: String?
    }

    let hops: [Hop]

    /// Returns the flat `[role]` array we serialize into the existing
    /// `PaceRecordedStep.axPress(rolePath:)` field. Identifier + label
    /// are folded back into the `label` field so older replay code
    /// keeps working.
    var serializedRolePath: [String] {
        hops.map { $0.role }
    }

    /// Returns the most useful display label across the hops — the
    /// pressed element's own label/identifier preferred over an
    /// ancestor's. Used to populate the existing `label` field.
    var primaryLabel: String {
        for hop in hops {
            if let label = hop.label, !label.isEmpty {
                return label
            }
        }
        for hop in hops {
            if let identifier = hop.identifier, !identifier.isEmpty {
                return identifier
            }
        }
        return hops.first?.role ?? ""
    }
}

/// Reason the recorder stopped. The `appQuit` case is reserved for
/// the AppDelegate to call `stop(reason: .appQuit)` during graceful
/// teardown; the recorder itself only ever stops with `.userCommand`
/// or `.idleTimeout`.
enum PaceFlowRecorderStopReason: Equatable {
    case userCommand
    case idleTimeout
    case appQuit
}

/// Recorder state. Exposed on `PaceFlowRecorder.state` so SwiftUI
/// status surfaces (Wave 3b's Flows tab) can observe the lifecycle
/// without reaching into the recorder's internals.
enum PaceFlowRecorderState: Equatable {
    case idle
    case recording(flowName: String, startedAt: Date)
    case stopped(reason: PaceFlowRecorderStopReason, recordedFlow: PaceRecordedFlow?)
}

// MARK: - Recorder

@MainActor
final class PaceFlowRecorder: ObservableObject {

    // MARK: Tunables

    /// Idle timeout. After this many seconds without an event the
    /// recorder auto-stops to release the CGEventTap. Tunable per
    /// instance for testability.
    let idleTimeoutSeconds: TimeInterval

    /// Per-focus typing-buffer hard cap. Once a buffer reaches this
    /// many characters it is flushed as a `typeText` step and a new
    /// buffer starts. Defends against runaway keystrokes (autoclicker,
    /// stuck key) OOMing the recorder.
    static let typingBufferMaxCharacterCount: Int = 256

    // MARK: Published state

    @Published private(set) var state: PaceFlowRecorderState = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: Private state

    /// Steps recorded for the in-progress flow. Cleared on start;
    /// returned (and emptied) on stop.
    private var recordedSteps: [PaceRecordedStep] = []

    /// Active typing buffer. Stored alongside the AX element it began
    /// in so we can detect focus changes by comparing AXUIElements.
    private struct TypingBuffer {
        var characters: String
        var focusedElement: AXUIElement?
        var isSecureField: Bool
    }
    private var activeTypingBuffer: TypingBuffer?

    /// Workspace activation notification token. Held so we can remove
    /// the observer on stop.
    private var workspaceActivationObserver: NSObjectProtocol?

    /// CGEventTap handles. Both nil while not recording.
    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Idle-timeout timer. Restarted on every observed event so the
    /// recorder stops 60s after the LAST event, not 60s after start.
    private var idleTimeoutTimer: Timer?

    /// Now-provider for unit tests. Production code uses `Date()`; the
    /// test harness injects a controllable clock so the 60s timeout is
    /// verifiable in milliseconds.
    private let currentDateProvider: () -> Date

    /// AX targeter for the same AX-tree climbing pattern
    /// `PaceAXTargeter` already uses. We don't reuse the targeter
    /// itself because we only need the read-side (no press).
    private let systemWideAXElement: AXUIElement = AXUIElementCreateSystemWide()

    init(
        idleTimeoutSeconds: TimeInterval = 60,
        currentDateProvider: @escaping () -> Date = { Date() }
    ) {
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.currentDateProvider = currentDateProvider
    }

    deinit {
        // `stop(...)` is @MainActor; deinit may not be. Do the
        // minimum CF teardown inline so we never leak the tap.
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
        }
    }

    // MARK: - Lifecycle

    /// Begin recording into a fresh flow named `flowName`. If a
    /// recording was already in progress it is silently stopped first
    /// (the previous flow is discarded — voice commands explicitly
    /// only start a new recording after `stop recording`).
    func start(flowName: String) {
        if isRecording {
            stop(reason: .userCommand)
        }
        recordedSteps = []
        activeTypingBuffer = nil
        state = .recording(flowName: flowName, startedAt: currentDateProvider())
        installCGEventTapIfNeeded()
        installWorkspaceActivationObserverIfNeeded()
        rearmIdleTimer()
    }

    /// Stop the current recording. Returns the assembled flow if one
    /// was in progress and had a non-empty name; otherwise `nil`.
    @discardableResult
    func stop(reason: PaceFlowRecorderStopReason) -> PaceRecordedFlow? {
        flushActiveTypingBuffer()

        let assembledFlow: PaceRecordedFlow?
        switch state {
        case .recording(let flowName, _):
            let trimmedFlowName = flowName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedFlowName.isEmpty {
                assembledFlow = nil
            } else {
                assembledFlow = PaceRecordedFlow(
                    name: trimmedFlowName,
                    createdAt: currentDateProvider(),
                    steps: recordedSteps
                )
            }
        default:
            assembledFlow = nil
        }

        recordedSteps = []
        activeTypingBuffer = nil
        removeWorkspaceActivationObserver()
        removeCGEventTap()
        invalidateIdleTimer()
        state = .stopped(reason: reason, recordedFlow: assembledFlow)
        return assembledFlow
    }

    // MARK: - Test seam

    /// Drive the recorder with a synthesized `CGEvent` without
    /// installing the system-wide event tap. Used by unit tests so
    /// they can verify the per-event branching (mouse / key / focus
    /// change / shortcut / secure) without requesting AX permission
    /// from the CI harness.
    func recordEventForTesting(_ event: CGEvent, eventType: CGEventType, at observedDate: Date) {
        handleObservedEvent(eventType: eventType, event: event, observedAt: observedDate)
    }

    /// Drive an app-activation step from a unit test without standing
    /// up a real `NSWorkspace` notification. Mirrors the
    /// `recordEventForTesting` seam.
    func recordAppActivationForTesting(bundleIdentifier: String, at observedDate: Date) {
        handleWorkspaceActivation(
            bundleIdentifier: bundleIdentifier,
            observedAt: observedDate
        )
    }

    /// Trigger the idle-timeout flow from a unit test. The production
    /// code path goes through `Timer.scheduledTimer`, which is hard to
    /// drive deterministically; this method directly fires the same
    /// teardown the timer would have.
    func fireIdleTimeoutForTesting() {
        stop(reason: .idleTimeout)
    }

    // MARK: - Event handling

    private func handleObservedEvent(
        eventType: CGEventType,
        event: CGEvent,
        observedAt: Date
    ) {
        guard isRecording else { return }
        rearmIdleTimer()

        switch eventType {
        case .leftMouseDown, .rightMouseDown:
            handleMouseDown(event: event)
        case .keyDown:
            handleKeyDown(event: event)
        case .flagsChanged:
            // A modifier press alone doesn't produce a step. We still
            // rearm the idle timer (above) so a long ⌘-held shortcut
            // doesn't trip the timeout mid-press.
            break
        default:
            break
        }
    }

    private func handleMouseDown(event: CGEvent) {
        // A click is itself a focus boundary for the typing buffer —
        // even if the user clicks elsewhere within the SAME element,
        // the semantic intent is "a new step starts here".
        flushActiveTypingBuffer()

        let cursorGlobalPoint = event.location
        guard let focusedAXElement = copyAXElementAtGlobalPoint(cursorGlobalPoint) else {
            // No AX element at the click point. We deliberately do NOT
            // record a coordinate-only click — Wave 3a's contract is
            // "AX role path only, never pixels". The replayer can't
            // do anything useful with a bare CGPoint.
            return
        }

        let rolePath = buildAXRolePath(startingAt: focusedAXElement)
        guard !rolePath.hops.isEmpty else { return }

        recordedSteps.append(
            .axPress(
                rolePath: rolePath.serializedRolePath,
                label: rolePath.primaryLabel
            )
        )
    }

    private func handleKeyDown(event: CGEvent) {
        let modifierFlags = event.flags
        let isCommandHeld = modifierFlags.contains(.maskCommand)
        let isControlHeld = modifierFlags.contains(.maskControl)
        let isAlternateHeld = modifierFlags.contains(.maskAlternate)

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let typedCharacters = unicodeCharactersForEvent(event)
        let keyLiteral = PaceFlowRecorderKeyNames.literal(
            forKeyCode: keyCode,
            typedCharacters: typedCharacters
        )

        // ⌘ / ⌃ / ⌥ + key = shortcut, regardless of what character (if
        // any) the OS resolved. Shift alone is NOT a shortcut modifier
        // because shift-letter is just "capital letter" — capturing
        // those as shortcuts would mangle every sentence the user types.
        if isCommandHeld || isControlHeld || isAlternateHeld {
            flushActiveTypingBuffer()
            let comboString = PaceFlowRecorderKeyNames.shortcutCombo(
                command: isCommandHeld,
                control: isControlHeld,
                alternate: isAlternateHeld,
                shift: modifierFlags.contains(.maskShift),
                keyLiteral: keyLiteral
            )
            recordedSteps.append(.keyShortcut(key: comboString))
            return
        }

        // Special bare keys (return, escape, tab, arrows) are emitted
        // as `keyShortcut` so the replayer doesn't try to type them
        // as literal characters.
        if PaceFlowRecorderKeyNames.bareKeyEmitsAsShortcut(keyLiteral: keyLiteral) {
            flushActiveTypingBuffer()
            recordedSteps.append(.keyShortcut(key: keyLiteral))
            return
        }

        // Regular character. Append to the active buffer, flushing
        // first if the focus has changed since the last keystroke.
        let currentFocusedElement = copyCurrentFocusedAXElement()
        let currentFocusIsSecure = elementIsSecureTextField(currentFocusedElement)

        if activeTypingBuffer == nil {
            activeTypingBuffer = TypingBuffer(
                characters: "",
                focusedElement: currentFocusedElement,
                isSecureField: currentFocusIsSecure
            )
        } else if !focusedElementsMatch(
            activeTypingBuffer?.focusedElement,
            currentFocusedElement
        ) {
            flushActiveTypingBuffer()
            activeTypingBuffer = TypingBuffer(
                characters: "",
                focusedElement: currentFocusedElement,
                isSecureField: currentFocusIsSecure
            )
        }

        // Secure-field input: never store the actual characters.
        // The flush will emit a single placeholder step.
        if currentFocusIsSecure {
            activeTypingBuffer?.isSecureField = true
            return
        }

        guard !typedCharacters.isEmpty else { return }
        activeTypingBuffer?.characters.append(typedCharacters)

        // Hard cap: flush so a runaway keystroke loop can't grow the
        // buffer forever.
        if let bufferCharacterCount = activeTypingBuffer?.characters.count,
           bufferCharacterCount >= Self.typingBufferMaxCharacterCount {
            flushActiveTypingBuffer()
        }
    }

    private func handleWorkspaceActivation(
        bundleIdentifier: String,
        observedAt: Date
    ) {
        guard isRecording else { return }
        rearmIdleTimer()

        let trimmedBundleIdentifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleIdentifier.isEmpty else { return }

        // App switch = focus boundary. Flush whatever was being typed
        // into the previous app before recording the activate step.
        flushActiveTypingBuffer()

        // Deduplicate consecutive activations of the same bundle —
        // macOS fires `didActivateApplicationNotification` for both
        // "user clicked the app" and various secondary activations.
        if case .activateApp(let lastBundleIdentifier) = recordedSteps.last,
           lastBundleIdentifier == trimmedBundleIdentifier {
            return
        }

        recordedSteps.append(.activateApp(bundleIdentifier: trimmedBundleIdentifier))
    }

    // MARK: - Typing buffer

    private func flushActiveTypingBuffer() {
        guard let buffer = activeTypingBuffer else { return }
        activeTypingBuffer = nil

        if buffer.isSecureField {
            // We never captured the keystrokes — emit the placeholder
            // step. The empty-text guard does NOT apply here because
            // a secure-field flush is meaningful even with zero
            // captured characters (the user typed *something* but we
            // intentionally didn't store it).
            recordedSteps.append(.typeText(text: "", secure: true))
            return
        }

        guard !buffer.characters.isEmpty else { return }
        recordedSteps.append(.typeText(text: buffer.characters, secure: false))
    }

    private func focusedElementsMatch(
        _ leftElement: AXUIElement?,
        _ rightElement: AXUIElement?
    ) -> Bool {
        switch (leftElement, rightElement) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case (let left?, let right?):
            // CFEqual is the only safe identity for AXUIElement; the
            // header documents `AXUIElement` as a CFType.
            return CFEqual(left, right)
        }
    }

    // MARK: - AX helpers

    private func copyAXElementAtGlobalPoint(_ globalCGPoint: CGPoint) -> AXUIElement? {
        var elementAtPosition: AXUIElement?
        let copyResult = AXUIElementCopyElementAtPosition(
            systemWideAXElement,
            Float(globalCGPoint.x),
            Float(globalCGPoint.y),
            &elementAtPosition
        )
        guard copyResult == .success else { return nil }
        return elementAtPosition
    }

    private func copyCurrentFocusedAXElement() -> AXUIElement? {
        var focusedElementValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWideAXElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard copyResult == .success,
              let focusedElementObject = focusedElementValue,
              CFGetTypeID(focusedElementObject) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedElementObject as! AXUIElement)
    }

    private func elementIsSecureTextField(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        guard let roleString = stringAXAttribute(kAXRoleAttribute as String, of: element) else {
            return false
        }
        return roleString == "AXSecureTextField"
    }

    /// Roles we consider "pressable enough" to record as the leaf of
    /// an axPress step. AX button/link/menu-item are the obvious ones;
    /// text fields are included because clicking into a text field IS
    /// a meaningful step the replayer needs to reproduce before
    /// typing.
    private static let recordablePressableRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXMenuItem",
        "AXMenuButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXTextField",
        "AXSecureTextField",
        "AXTextArea",
        "AXDisclosureTriangle",
        "AXTab",
        "AXTabGroup"
    ]

    private func buildAXRolePath(startingAt startElement: AXUIElement) -> PaceAXRolePath {
        var collectedHops: [PaceAXRolePath.Hop] = []

        // Climb at most 8 hops. Beyond that we're inside the window
        // chrome, which the replayer can't usefully target.
        var currentElement: AXUIElement = startElement
        var foundPressableLeaf = false
        for _ in 0..<8 {
            let role = stringAXAttribute(kAXRoleAttribute as String, of: currentElement) ?? "AXUnknown"
            let identifier = stringAXAttribute(kAXIdentifierAttribute as String, of: currentElement)
            let label = stringAXAttribute(kAXTitleAttribute as String, of: currentElement)
                ?? stringAXAttribute(kAXDescriptionAttribute as String, of: currentElement)

            collectedHops.append(
                PaceAXRolePath.Hop(role: role, identifier: identifier, label: label)
            )

            if !foundPressableLeaf, Self.recordablePressableRoles.contains(role) {
                foundPressableLeaf = true
            }

            var parentValue: CFTypeRef?
            let parentResult = AXUIElementCopyAttributeValue(
                currentElement,
                kAXParentAttribute as CFString,
                &parentValue
            )
            guard parentResult == .success,
                  let parentObject = parentValue,
                  CFGetTypeID(parentObject) == AXUIElementGetTypeID() else {
                break
            }
            currentElement = (parentObject as! AXUIElement)
        }

        // If the entire chain produced nothing pressable, drop the
        // step. We never want to record a path that targets, say, an
        // AXImage with no surrounding button.
        guard foundPressableLeaf else {
            return PaceAXRolePath(hops: [])
        }
        return PaceAXRolePath(hops: collectedHops)
    }

    private func stringAXAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            element,
            attributeName as CFString,
            &attributeValue
        )
        guard copyResult == .success else { return nil }
        return attributeValue as? String
    }

    private func unicodeCharactersForEvent(_ event: CGEvent) -> String {
        // CGEvent gives us the Unicode chars the OS thinks were typed
        // — accounts for IME and dead keys. The buffer is small (we
        // ask for max 4 Unicode units which covers any single key).
        var unicodeStringBuffer = [UniChar](repeating: 0, count: 4)
        var actualUnicodeCount: Int = 0
        event.keyboardGetUnicodeString(
            maxStringLength: unicodeStringBuffer.count,
            actualStringLength: &actualUnicodeCount,
            unicodeString: &unicodeStringBuffer
        )
        guard actualUnicodeCount > 0 else { return "" }
        return String(utf16CodeUnits: unicodeStringBuffer, count: actualUnicodeCount)
    }

    // MARK: - CGEventTap lifecycle

    private func installCGEventTapIfNeeded() {
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .keyDown,
            .flagsChanged,
        ]
        let monitoredEventMask: CGEventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let recorder = Unmanaged<PaceFlowRecorder>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            recorder.handleObservedEventFromTapCallback(eventType: eventType, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let installedTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: monitoredEventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ PaceFlowRecorder: couldn't create CGEvent tap — flow recording disabled until Accessibility is granted")
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            installedTap,
            0
        ) else {
            CFMachPortInvalidate(installedTap)
            print("⚠️ PaceFlowRecorder: couldn't create event tap run-loop source")
            return
        }

        self.globalEventTap = installedTap
        self.globalEventTapRunLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: installedTap, enable: true)
    }

    private func removeCGEventTap() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    /// `nonisolated` because CGEventTap callbacks fire on the run-loop
    /// the source is attached to (main, in our case); we hop back into
    /// MainActor explicitly to mutate state.
    private nonisolated func handleObservedEventFromTapCallback(
        eventType: CGEventType,
        event: CGEvent
    ) {
        // The CGEvent isn't retained past the callback return, so we
        // need to copy any state we'll read inside the MainActor hop.
        // Today we read everything inside `handleObservedEvent`, so a
        // direct `assumeIsolated` call is safe — the callback already
        // runs on the main thread.
        let capturedEvent = event.copy() ?? event
        MainActor.assumeIsolated {
            self.handleObservedEvent(
                eventType: eventType,
                event: capturedEvent,
                observedAt: self.currentDateProvider()
            )
        }
    }

    // MARK: - Workspace activation

    private func installWorkspaceActivationObserverIfNeeded() {
        guard workspaceActivationObserver == nil else { return }
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceActivationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let runningApplication = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            guard let bundleIdentifier = runningApplication.bundleIdentifier else { return }
            // Closure captured on main queue → already on MainActor.
            MainActor.assumeIsolated {
                self?.handleWorkspaceActivation(
                    bundleIdentifier: bundleIdentifier,
                    observedAt: self?.currentDateProvider() ?? Date()
                )
            }
        }
    }

    private func removeWorkspaceActivationObserver() {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }

    // MARK: - Idle timeout

    private func rearmIdleTimer() {
        invalidateIdleTimer()
        guard idleTimeoutSeconds > 0 else { return }
        idleTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: idleTimeoutSeconds,
            repeats: false
        ) { [weak self] _ in
            // Timer fires on the run loop that scheduled it (main).
            MainActor.assumeIsolated {
                _ = self?.stop(reason: .idleTimeout)
            }
        }
    }

    private func invalidateIdleTimer() {
        idleTimeoutTimer?.invalidate()
        idleTimeoutTimer = nil
    }
}

// MARK: - Key name helper

/// Pure helper that turns a `(keyCode, modifierFlags, typedCharacters)`
/// triple into the wire-format string used in `keyShortcut(key:)`. Kept
/// separate from the recorder so the tests can drive it without
/// constructing a full CGEvent.
enum PaceFlowRecorderKeyNames {

    /// Map of CGKeyCode → canonical literal for keys whose Unicode
    /// translation is either empty (return, escape, tab, arrows) or
    /// ambiguous between OS layouts. Used by both the keyDown handler
    /// and the recipe schema, so a saved flow on a Dvorak keyboard
    /// replays correctly on QWERTY.
    static let bareKeyLiterals: [UInt16: String] = [
        0x24: "return",
        0x4C: "enter",
        0x35: "escape",
        0x30: "tab",
        0x33: "delete",
        0x75: "forward-delete",
        0x31: "space",
        0x7B: "left",
        0x7C: "right",
        0x7D: "down",
        0x7E: "up",
        0x73: "home",
        0x77: "end",
        0x74: "page-up",
        0x79: "page-down",
        0x7A: "f1",
        0x78: "f2",
        0x63: "f3",
        0x76: "f4",
        0x60: "f5",
        0x61: "f6",
        0x62: "f7",
        0x64: "f8",
        0x65: "f9",
        0x6D: "f10",
        0x67: "f11",
        0x6F: "f12",
    ]

    /// Bare keys (no modifier) that should still emit as a shortcut
    /// step because the replayer can't sensibly "type" them.
    static let bareKeyShortcutLiterals: Set<String> = [
        "return", "enter", "escape", "tab",
        "left", "right", "up", "down",
        "page-up", "page-down", "home", "end",
        "f1", "f2", "f3", "f4", "f5", "f6",
        "f7", "f8", "f9", "f10", "f11", "f12"
    ]

    static func literal(forKeyCode keyCode: UInt16, typedCharacters: String) -> String {
        if let bareKeyLiteral = bareKeyLiterals[keyCode] {
            return bareKeyLiteral
        }
        if !typedCharacters.isEmpty {
            return typedCharacters.lowercased()
        }
        return "key-\(keyCode)"
    }

    static func bareKeyEmitsAsShortcut(keyLiteral: String) -> Bool {
        bareKeyShortcutLiterals.contains(keyLiteral)
    }

    static func shortcutCombo(
        command: Bool,
        control: Bool,
        alternate: Bool,
        shift: Bool,
        keyLiteral: String
    ) -> String {
        var modifierTokens: [String] = []
        if command { modifierTokens.append("cmd") }
        if control { modifierTokens.append("ctrl") }
        if alternate { modifierTokens.append("opt") }
        if shift { modifierTokens.append("shift") }
        modifierTokens.append(keyLiteral)
        return modifierTokens.joined(separator: "+")
    }
}
