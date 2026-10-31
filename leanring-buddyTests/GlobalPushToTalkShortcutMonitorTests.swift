import Combine
import Testing
@testable import Pace

@MainActor
struct GlobalPushToTalkShortcutMonitorTests {
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
        }
    }
}
