import Combine
import CoreGraphics
import Testing
@testable import Pace

@MainActor
struct GlobalPushToTalkShortcutMonitorTests {
    @Test func missedPhysicalModifierReleaseRecoversWithoutCancellingHandsFreeCapture() throws {
        let monitor = GlobalPushToTalkShortcutMonitor(shortcutOption: .controlOption)
        let event = try #require(CGEvent(source: nil))
        event.flags = [.maskControl, .maskAlternate]
        var transitions = 0
        let observation = monitor.shortcutTransitionPublisher.sink { _ in transitions += 1 }
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        #expect(monitor.isShortcutCurrentlyPressed && !monitor.isSimulatedPressActive)
        monitor.recoverMissedModifierRelease(modifierFlagsRawValue: event.flags.rawValue)
        #expect(monitor.isShortcutCurrentlyPressed)
        monitor.recoverMissedModifierRelease(modifierFlagsRawValue: 0)
        monitor.recoverMissedModifierRelease(modifierFlagsRawValue: 0)
        #expect(!monitor.isShortcutCurrentlyPressed && transitions == 2)
        monitor.simulateShortcutPressed()
        monitor.recoverMissedModifierRelease(modifierFlagsRawValue: 0)
        #expect(monitor.isShortcutCurrentlyPressed && monitor.isSimulatedPressActive)
        event.flags = [.maskShift]
        _ = monitor.handleGlobalEventTap(eventType: .flagsChanged, event: event)
        #expect(monitor.isShortcutCurrentlyPressed && monitor.isSimulatedPressActive && transitions == 3)
        monitor.simulateShortcutReleased()
        withExtendedLifetime(observation) { }
    }
    @Test func rightControlHoldCancelsForOtherInputAndReleasesWhenUsedAlone() async throws {
        let monitor = GlobalPushToTalkShortcutMonitor(shortcutOption: .rightControl)
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let observation = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        let rightControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
        let leftControl = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x0001)
        monitor.handleRightControlEvent(.flagsChanged, keyCode: 59, flags: leftControl)
        monitor.handleRightControlEvent(.flagsChanged, keyCode: 62, flags: rightControl)
        monitor.handleRightControlEvent(.keyDown, keyCode: 0, flags: rightControl)
        monitor.handleRightControlEvent(.flagsChanged, keyCode: 62, flags: [])
        try await Task.sleep(for: .milliseconds(220))
        #expect(transitions.isEmpty)

        monitor.handleRightControlEvent(.flagsChanged, keyCode: 62, flags: rightControl)
        try await Task.sleep(for: .milliseconds(220))
        monitor.handleRightControlEvent(.leftMouseDown, keyCode: 0, flags: rightControl)
        monitor.handleRightControlEvent(.flagsChanged, keyCode: 62, flags: [])
        #expect(transitions == [.pressed, .cancelled])

        monitor.handleRightControlEvent(.flagsChanged, keyCode: 62, flags: rightControl)
        try await Task.sleep(for: .milliseconds(220))
        monitor.handleRightControlEvent(.flagsChanged, keyCode: 62, flags: [])
        #expect(transitions == [.pressed, .cancelled, .pressed, .released])
        withExtendedLifetime(observation) { }
    }

    @Test func functionPConsumesOnlyItsOwnKeyPairAndReleasesInEitherOrder() {
        var chord = PaceFunctionPChord()
        let keyCode = BuddyPushToTalkShortcut.functionPKeyCode
        let function: CGEventFlags = .maskSecondaryFn
        let plain = chord.handle(.keyDown, keyCode: keyCode, flags: [], isRepeat: false)
        #expect(!plain.consumesEvent && plain.transition == .none)
        #expect(!chord.handle(.keyDown, keyCode: keyCode, flags: function, isRepeat: true).consumesEvent)
        #expect(!chord.handle(.keyUp, keyCode: keyCode, flags: function, isRepeat: false).consumesEvent)
        let command = chord.handle(.keyDown, keyCode: keyCode, flags: [function, .maskCommand], isRepeat: false)
        #expect(!command.consumesEvent && command.transition == .none)
        #expect(!chord.handle(.keyUp, keyCode: keyCode, flags: function, isRepeat: false).consumesEvent)

        let press = chord.handle(.keyDown, keyCode: keyCode, flags: function, isRepeat: false)
        #expect(press.consumesEvent && press.transition == .pressed)
        let repeatPress = chord.handle(.keyDown, keyCode: keyCode, flags: function, isRepeat: true)
        #expect(repeatPress.consumesEvent && repeatPress.transition == .none)
        let functionRelease = chord.handle(.flagsChanged, keyCode: 63, flags: [], isRepeat: false)
        #expect(!functionRelease.consumesEvent && functionRelease.transition == .released)
        let pairedRelease = chord.handle(.keyUp, keyCode: keyCode, flags: [], isRepeat: false)
        #expect(pairedRelease.consumesEvent && pairedRelease.transition == .none)

        #expect(chord.handle(.keyDown, keyCode: keyCode, flags: function, isRepeat: false).transition == .pressed)
        let keyRelease = chord.handle(.keyUp, keyCode: keyCode, flags: function, isRepeat: false)
        #expect(keyRelease.consumesEvent && keyRelease.transition == .released)
    }

    @Test func functionPStopsHandsFreeWithoutStartingAnotherCapture() {
        let monitor = GlobalPushToTalkShortcutMonitor(shortcutOption: .functionP)
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let observation = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        monitor.simulateShortcutPressed()
        monitor.handleFunctionPTransition(.pressed)
        monitor.handleFunctionPTransition(.released)
        #expect(transitions == [.pressed, .released])
        #expect(!monitor.isShortcutCurrentlyPressed && !monitor.isSimulatedPressActive)
        withExtendedLifetime(observation) { }
    }

    @Test
    func simulatedPressAndReleasePublishOneBoundedTransitionPair() {
        let monitor = GlobalPushToTalkShortcutMonitor()
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let cancellable = monitor.shortcutTransitionPublisher.sink {
            transitions.append($0)
        }

        monitor.simulateShortcutPressed()
        monitor.simulateShortcutPressed()
        #expect(monitor.isShortcutCurrentlyPressed == true)

        monitor.simulateShortcutReleased()
        monitor.simulateShortcutReleased()
        #expect(monitor.isShortcutCurrentlyPressed == false)
        #expect(transitions.count == 2)
        #expect(transitionName(transitions[0]) == "pressed")
        #expect(transitionName(transitions[1]) == "released")

        cancellable.cancel()
    }

    @Test
    func stopClearsSyntheticPressState() {
        let monitor = GlobalPushToTalkShortcutMonitor()

        monitor.simulateShortcutPressed()
        #expect(monitor.isShortcutCurrentlyPressed == true)

        monitor.stop()
        #expect(monitor.isShortcutCurrentlyPressed == false)
    }

    @Test
    func discardedFailedCaptureAllowsAnotherStartWithoutPublishingARelease() {
        let monitor = GlobalPushToTalkShortcutMonitor()
        var transitions: [BuddyPushToTalkShortcut.ShortcutTransition] = []
        let cancellable = monitor.shortcutTransitionPublisher.sink { transitions.append($0) }
        monitor.simulateShortcutPressed()
        #expect(monitor.isSimulatedPressActive)
        monitor.discardSimulatedPress()
        monitor.discardSimulatedPress()
        #expect(!monitor.isShortcutCurrentlyPressed)
        #expect(!monitor.isSimulatedPressActive)
        #expect(transitions.count == 1)
        monitor.simulateShortcutPressed()
        #expect(monitor.isShortcutCurrentlyPressed)
        #expect(transitions.count == 2)
        cancellable.cancel()
    }

    private func transitionName(
        _ transition: BuddyPushToTalkShortcut.ShortcutTransition
    ) -> String {
        switch transition {
        case .none: "none"
        case .pressed: "pressed"
        case .released: "released"
        case .cancelled: "cancelled"
        }
    }
}
