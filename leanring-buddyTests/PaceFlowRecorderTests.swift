//
//  PaceFlowRecorderTests.swift
//  leanring-buddyTests
//
//  Drives `PaceFlowRecorder` via its synthetic-event test seam so the
//  per-event branching (mouse / key / focus change / shortcut /
//  secure-field) is verifiable without installing a real CGEventTap
//  (which would require Accessibility permission in CI).
//
//  The tests intentionally do NOT touch AX-tree lookup — that path
//  requires a live macOS UI element at a point, which a unit-test
//  process doesn't have. The mouse-down test verifies the "no AX
//  element → drop the step" branch instead, which is the
//  conservative-by-default contract the recorder advertises.
//

import AppKit
import CoreGraphics
import XCTest
@testable import Pace

@MainActor
final class PaceFlowRecorderTests: XCTestCase {

    // MARK: - Lifecycle

    func testFreshRecorderIsIdle() {
        let recorder = PaceFlowRecorder()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(recorder.isRecording)
    }

    func testStartTransitionsIntoRecording() {
        let recorder = PaceFlowRecorder()
        recorder.start(flowName: "compose mail")
        XCTAssertTrue(recorder.isRecording)
        if case .recording(let flowName, _) = recorder.state {
            XCTAssertEqual(flowName, "compose mail")
        } else {
            XCTFail("expected .recording state after start, got \(recorder.state)")
        }
    }

    /// Regression test for a real EXC_BAD_ACCESS crash (objc_release,
    /// inside AutoreleasePoolPage::releaseUntil / objc_autoreleasePoolPop
    /// on the main run loop, matching several prior `Pace-*.ips` crash
    /// reports): `start(flowName:)` installs a real, system-wide
    /// CGEventTap whose C `userInfo` used to be
    /// `Unmanaged.passUnretained(self)`. `PaceFlowRecorder` is
    /// `@MainActor`, but Swift does not isolate `deinit` to the actor —
    /// if the last strong reference to a recorder is dropped off-main
    /// (e.g. a `Task` finishing on a background executor, which is
    /// exactly what happens to every `recorder` local in this file:
    /// there is no `tearDown()`, so every recorder is torn down by
    /// `deinit` alone), a CGEventTap callback already in flight on the
    /// main run loop could dereference `self` while it was
    /// mid-deallocation — a use-after-free.
    ///
    /// The fix routes the callback through `EventTapCallbackContext`,
    /// a small box the tap retains independently of `self` and which
    /// only holds a `weak` reference back to the recorder. This test
    /// proves the exact safety property deterministically — no real
    /// CGEventTap, no scheduling race, no flakiness — by capturing the
    /// same context object the C callback would (via
    /// `eventTapCallbackContextForTesting()`), deallocating the
    /// recorder without ever calling `stop(reason:)` (the precise path
    /// that used to leave a dangling pointer live), and asserting the
    /// context still exists and safely observes `nil` rather than a
    /// dangling recorder.
    func testEventTapCallbackContextSafelyObservesNilAfterRecorderDeallocatesWithoutStop() {
        var recorder: PaceFlowRecorder? = PaceFlowRecorder()
        recorder?.start(flowName: "context capture")

        guard let capturedCallbackContext = recorder?.eventTapCallbackContextForTesting() else {
            XCTFail("Expected start(flowName:) to install a callback context")
            return
        }
        XCTAssertNotNil(
            capturedCallbackContext.recorder,
            "Sanity: the context should observe the live recorder before deallocation"
        )

        // Deallocate WITHOUT calling stop(reason:) first — the exact
        // path a Task dropping the last strong reference off the main
        // actor takes, and the exact path that used to leave a
        // dangling `Unmanaged.passUnretained(self)` pointer for an
        // in-flight CGEventTap callback to dereference.
        recorder = nil

        XCTAssertNil(
            capturedCallbackContext.recorder,
            "Callback context must observe nil, not a dangling recorder, once the recorder has deallocated without stop(reason:)"
        )
    }

    func testStopReturnsAssembledFlow() {
        let recorder = PaceFlowRecorder(
            idleTimeoutSeconds: 0, // disables idle timer for the test
            currentDateProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        recorder.start(flowName: "test flow")
        recorder.recordAppActivationForTesting(
            bundleIdentifier: "com.apple.mail",
            at: Date()
        )

        let assembledFlow = recorder.stop(reason: .userCommand)

        let unwrappedFlow = try? XCTUnwrap(assembledFlow)
        XCTAssertEqual(unwrappedFlow?.name, "test flow")
        XCTAssertEqual(unwrappedFlow?.steps, [
            .activateApp(bundleIdentifier: "com.apple.mail")
        ])
        if case .stopped(let stopReason, let flowInStopState) = recorder.state {
            XCTAssertEqual(stopReason, .userCommand)
            XCTAssertNotNil(flowInStopState)
        } else {
            XCTFail("expected .stopped after stop(), got \(recorder.state)")
        }
    }

    func testStopWithoutStartingReturnsNil() {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        let result = recorder.stop(reason: .userCommand)
        XCTAssertNil(result)
        XCTAssertEqual(recorder.state, .stopped(reason: .userCommand, recordedFlow: nil))
    }

    func testRestartingDiscardsPreviousRecording() {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "first flow")
        recorder.recordAppActivationForTesting(
            bundleIdentifier: "com.apple.mail",
            at: Date()
        )

        recorder.start(flowName: "second flow")
        let assembledFlow = recorder.stop(reason: .userCommand)
        // First-flow steps must NOT survive the restart.
        XCTAssertEqual(assembledFlow?.name, "second flow")
        XCTAssertEqual(assembledFlow?.steps, [])
    }

    // MARK: - Workspace activation

    func testActivateAppEmitsStepInOrder() {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "morning")
        recorder.recordAppActivationForTesting(bundleIdentifier: "com.apple.mail", at: Date())
        recorder.recordAppActivationForTesting(bundleIdentifier: "com.apple.iCal", at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [
            .activateApp(bundleIdentifier: "com.apple.mail"),
            .activateApp(bundleIdentifier: "com.apple.iCal"),
        ])
    }

    func testConsecutiveActivationsOfSameAppAreDeduplicated() {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "noisy switch")
        recorder.recordAppActivationForTesting(bundleIdentifier: "com.apple.mail", at: Date())
        recorder.recordAppActivationForTesting(bundleIdentifier: "com.apple.mail", at: Date())
        recorder.recordAppActivationForTesting(bundleIdentifier: "com.apple.mail", at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [
            .activateApp(bundleIdentifier: "com.apple.mail")
        ])
    }

    func testEmptyBundleIdentifierIsIgnored() {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "blank")
        recorder.recordAppActivationForTesting(bundleIdentifier: "   ", at: Date())
        recorder.recordAppActivationForTesting(bundleIdentifier: "", at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [])
    }

    // MARK: - Idle timeout

    func testIdleTimeoutStopsRecordingWithIdleReason() {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "timeout test")
        XCTAssertTrue(recorder.isRecording)

        recorder.fireIdleTimeoutForTesting()

        XCTAssertFalse(recorder.isRecording)
        if case .stopped(let stopReason, _) = recorder.state {
            XCTAssertEqual(stopReason, .idleTimeout)
        } else {
            XCTFail("expected .stopped state after idle timeout, got \(recorder.state)")
        }
    }

    // MARK: - Key shortcut helper

    func testCommandHeldKeyEmitsShortcutCombo() {
        // The Pace flow JSON stores shortcuts in a canonical form
        // "cmd+s" / "ctrl+shift+t". The helper is exercised through
        // its own pure surface here; the live keyDown handler uses
        // the same helper internally.
        let comboString = PaceFlowRecorderKeyNames.shortcutCombo(
            command: true,
            control: false,
            alternate: false,
            shift: false,
            keyLiteral: "s"
        )
        XCTAssertEqual(comboString, "cmd+s")
    }

    func testControlOptionShiftKeyEmitsCombinedShortcutCombo() {
        let comboString = PaceFlowRecorderKeyNames.shortcutCombo(
            command: false,
            control: true,
            alternate: true,
            shift: true,
            keyLiteral: "k"
        )
        XCTAssertEqual(comboString, "ctrl+opt+shift+k")
    }

    func testBareReturnEmitsAsShortcut() {
        let returnKeyCode: UInt16 = 0x24
        let keyLiteral = PaceFlowRecorderKeyNames.literal(
            forKeyCode: returnKeyCode,
            typedCharacters: ""
        )
        XCTAssertEqual(keyLiteral, "return")
        XCTAssertTrue(PaceFlowRecorderKeyNames.bareKeyEmitsAsShortcut(keyLiteral: keyLiteral))
    }

    func testBareArrowKeyEmitsAsShortcut() {
        XCTAssertEqual(
            PaceFlowRecorderKeyNames.literal(forKeyCode: 0x7C, typedCharacters: ""),
            "right"
        )
        XCTAssertTrue(
            PaceFlowRecorderKeyNames.bareKeyEmitsAsShortcut(keyLiteral: "right")
        )
    }

    func testTypedCharacterIsNotABareShortcut() {
        let typedKeyLiteral = PaceFlowRecorderKeyNames.literal(
            forKeyCode: 0x06, // 'z' on QWERTY
            typedCharacters: "z"
        )
        XCTAssertEqual(typedKeyLiteral, "z")
        XCTAssertFalse(
            PaceFlowRecorderKeyNames.bareKeyEmitsAsShortcut(keyLiteral: typedKeyLiteral)
        )
    }

    // MARK: - Synthetic key events

    func testCommandSKeyEmitsShortcutStep() throws {
        // Build a real CGEvent for ⌘+S and drive it through the test
        // seam. We can't test the typing-buffer branch this way because
        // the buffer flush peeks at the system-wide focused AX element,
        // which doesn't exist in the test process — so this verifies
        // ONLY the modifier-driven shortcut emission path.
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "save flow")

        let cmdSEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0x01, // ANSI 'S'
                keyDown: true
            )
        )
        var utf16S: [UniChar] = [0x0073]
        cmdSEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16S)
        cmdSEvent.flags = .maskCommand
        recorder.recordEventForTesting(cmdSEvent, eventType: .keyDown, at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [
            .keyShortcut(key: "cmd+s")
        ])
    }

    func testBareReturnEmitsKeyShortcutStep() throws {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "press enter")

        let returnEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0x24, // Return
                keyDown: true
            )
        )
        recorder.recordEventForTesting(returnEvent, eventType: .keyDown, at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [
            .keyShortcut(key: "return")
        ])
    }

    func testFlagsChangedAloneDoesNotEmitStep() throws {
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "modifier held")

        // A `flagsChanged` event with the command modifier flipping
        // on. By itself this must not produce a step — only the
        // accompanying keyDown does.
        let flagsEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0x37, // Command key
                keyDown: true
            )
        )
        flagsEvent.flags = .maskCommand
        recorder.recordEventForTesting(flagsEvent, eventType: .flagsChanged, at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [])
    }

    // MARK: - Mouse click without AX element

    func testMouseDownWithNoAXElementProducesNoStep() throws {
        // The test process has no UI windows, so
        // AXUIElementCopyElementAtPosition returns nil for every
        // point. The recorder should silently drop the step — never
        // record a pixel-only click — because Wave 3a's contract is
        // "AX role path only".
        let recorder = PaceFlowRecorder(idleTimeoutSeconds: 0)
        recorder.start(flowName: "click in void")

        let mouseEvent = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: -1000, y: -1000), // off-screen
                mouseButton: .left
            )
        )
        recorder.recordEventForTesting(mouseEvent, eventType: .leftMouseDown, at: Date())

        let assembledFlow = recorder.stop(reason: .userCommand)
        XCTAssertEqual(assembledFlow?.steps, [])
    }

    // MARK: - Secure-field helper

    func testTypeTextSecureFieldEncoding() {
        // Indirect test: build a `PaceRecordedStep.typeText(...)` with
        // secure=true, round-trip it through Codable, and verify the
        // disk representation never echoes the captured characters.
        // This pins the contract the recorder relies on when its
        // own flush path emits the placeholder.
        let secureStep: PaceRecordedStep = .typeText(text: "", secure: true)
        let encoder = JSONEncoder()
        let encoded = try? encoder.encode(secureStep)
        let encodedString = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(encodedString.contains("<password redacted>"))
        XCTAssertTrue(encodedString.contains("\"secure\":true"))
    }
}
