import AppKit
import Combine
import XCTest
@testable import Pace

@MainActor
final class PaceActiveDisplayCoordinatorTests: XCTestCase {
    private let laptop = PaceDisplayGeometry(
        displayID: PaceDisplayID(rawValue: 1), frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    private let leftDisplay = PaceDisplayGeometry(
        displayID: PaceDisplayID(rawValue: 2), frame: CGRect(x: -1920, y: -120, width: 1920, height: 1080))
    private let upperDisplay = PaceDisplayGeometry(
        displayID: PaceDisplayID(rawValue: 3), frame: CGRect(x: 0, y: 1117, width: 2560, height: 1440))

    func testQuartzBoundsConvertAcrossNegativeAndUpperDisplayOrigins() {
        XCTAssertEqual(
            PaceDisplayGeometry.appKitFrame(
                from: CGRect(x: -1800, y: 277, width: 1000, height: 700), primaryScreenTop: 1117),
            CGRect(x: -1800, y: 140, width: 1000, height: 700))
        XCTAssertEqual(
            PaceDisplayGeometry.appKitFrame(
                from: CGRect(x: 300, y: -1340, width: 1600, height: 1000), primaryScreenTop: 1117),
            CGRect(x: 300, y: 1457, width: 1600, height: 1000))
    }

    func testFocusedWindowWinsOverPointerAndPreviousNotchedDisplay() {
        XCTAssertEqual(PaceDisplayGeometry.selectedDisplay(
            screens: [laptop, leftDisplay, upperDisplay],
            focusedWindowFrame: CGRect(x: -1800, y: 100, width: 1200, height: 700),
            pointerLocation: CGPoint(x: 700, y: 700), previousDisplayID: laptop.displayID), leftDisplay.displayID)
    }

    func testLargestWindowIntersectionSelectsTheDisplayContainingMostOfTheWindow() {
        XCTAssertEqual(PaceDisplayGeometry.selectedDisplay(
            screens: [laptop, leftDisplay],
            focusedWindowFrame: CGRect(x: -1000, y: 100, width: 1200, height: 700),
            pointerLocation: CGPoint(x: 700, y: 700), previousDisplayID: laptop.displayID), leftDisplay.displayID)
    }

    func testEqualWindowIntersectionKeepsThePreviouslySelectedDisplay() {
        let windowAcrossSeam = CGRect(x: -100, y: 200, width: 200, height: 500)
        for previousDisplayID in [laptop.displayID, leftDisplay.displayID] {
            XCTAssertEqual(PaceDisplayGeometry.selectedDisplay(
                screens: [laptop, leftDisplay], focusedWindowFrame: windowAcrossSeam,
                pointerLocation: CGPoint(x: 500, y: 500), previousDisplayID: previousDisplayID), previousDisplayID)
        }
    }

    func testWindowOnlyTouchingADisplayEdgeDoesNotSelectThatDisplay() {
        XCTAssertEqual(PaceDisplayGeometry.selectedDisplay(
            screens: [laptop, leftDisplay],
            focusedWindowFrame: CGRect(x: 1728, y: 100, width: 500, height: 500),
            pointerLocation: CGPoint(x: -900, y: 400), previousDisplayID: laptop.displayID), leftDisplay.displayID)
    }

    func testMissingOrOffscreenFocusedWindowFallsBackToPointerThenExistingDisplay() {
        for focusedWindowFrame in [nil, CGRect.zero, CGRect(x: 8000, y: 8000, width: 300, height: 300)] {
            XCTAssertEqual(PaceDisplayGeometry.selectedDisplay(
                screens: [laptop, leftDisplay], focusedWindowFrame: focusedWindowFrame,
                pointerLocation: CGPoint(x: -700, y: 500), previousDisplayID: laptop.displayID), leftDisplay.displayID)
        }
        XCTAssertEqual(PaceDisplayGeometry.selectedDisplay(
            screens: [laptop, leftDisplay], focusedWindowFrame: nil,
            pointerLocation: CGPoint(x: 9000, y: 9000), previousDisplayID: leftDisplay.displayID), leftDisplay.displayID)
    }

    func testLateFocusedWindowReadCannotUndoAUserClickOnAnotherDisplay() async throws {
        let gate = FocusReadGate()
        let coordinator = makeCoordinator(gate: gate)
        coordinator.handleSystemEvent(.applicationActivated)
        try await gate.waitForReadCount(1)
        coordinator.pointerDidClick(at: CGPoint(x: -900, y: 400))
        await gate.completeNext(with: CGRect(x: 100, y: 100, width: 900, height: 700))
        await drainTasks()
        XCTAssertEqual(coordinator.route.displayID, leftDisplay.displayID)
        XCTAssertEqual(coordinator.route.reason, .pointerDown)
    }

    func testSpaceChangeOnTheSameDisplayReassertsAndRetiresOldFocusedWindowRead() async throws {
        let gate = FocusReadGate()
        let coordinator = makeCoordinator(gate: gate)
        coordinator.handleSystemEvent(.applicationActivated)
        try await gate.waitForReadCount(1)
        let previousRevision = coordinator.route.revision
        coordinator.handleSystemEvent(.activeSpaceChanged)
        XCTAssertEqual(coordinator.route.revision, previousRevision + 1)
        XCTAssertEqual(coordinator.route.reason, .activeSpaceChanged)
        await gate.completeNext(with: CGRect(x: -1800, y: 100, width: 1200, height: 700))
        try await gate.waitForReadCount(2)
        XCTAssertEqual(coordinator.route.displayID, laptop.displayID)
        await gate.completeNext(with: CGRect(x: 100, y: 100, width: 900, height: 700))
        await drainTasks()
        XCTAssertEqual(coordinator.route.displayID, laptop.displayID)
    }

    func testOwnActivationAndFocusNeverBounceToThePointerDisplayOrReadPaceWindows() async {
        let gate = FocusReadGate()
        let coordinator = makeCoordinator(gate: gate, frontmostProcessIdentifier: { 42 })
        coordinator.selectDisplay(containing: CGRect(x: -1000, y: 900, width: 24, height: 24))
        let selectedRoute = coordinator.route
        coordinator.handleSystemEvent(.applicationActivated)
        coordinator.handleSystemEvent(.focusedWindowChanged)
        await drainTasks()
        XCTAssertEqual(coordinator.route, selectedRoute)
        let readCount = await gate.readCount
        XCTAssertEqual(readCount, 0)
    }

    func testDisplayRemovalUsesAConnectedDisplayAndStillReasserts() async {
        var connectedScreens = [laptop, leftDisplay]
        let coordinator = PaceActiveDisplayCoordinator(
            screens: { connectedScreens }, pointerLocation: { CGPoint(x: -900, y: 300) },
            frontmostProcessIdentifier: { 42 }, ownProcessIdentifier: 42)
        XCTAssertEqual(coordinator.route.displayID, leftDisplay.displayID)
        connectedScreens = [laptop]
        coordinator.handleSystemEvent(.screensChanged)
        XCTAssertEqual(coordinator.route.displayID, laptop.displayID)
        XCTAssertEqual(coordinator.route.reason, .screensChanged)
    }

    func testRapidFocusNotificationsCoalesceAndUseOnlyTheLatestRead() async throws {
        let gate = FocusReadGate()
        let coordinator = makeCoordinator(gate: gate)
        coordinator.handleSystemEvent(.applicationActivated)
        try await gate.waitForReadCount(1)
        for _ in 0..<30 { coordinator.handleSystemEvent(.focusedWindowChanged) }
        await gate.completeNext(with: CGRect(x: -1800, y: 100, width: 1200, height: 700))
        try await gate.waitForReadCount(2)
        XCTAssertEqual(coordinator.route.displayID, laptop.displayID)
        await gate.completeNext(with: CGRect(x: 100, y: 1500, width: 1200, height: 700))
        await drainTasks()
        let readCount = await gate.readCount
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(coordinator.route.displayID, upperDisplay.displayID)
    }

    func testRepeatedSpaceEventsPublishEvenWhenDisplayIDDoesNotChange() {
        let coordinator = PaceActiveDisplayCoordinator(
            screens: { [self.laptop] }, pointerLocation: { CGPoint(x: 100, y: 100) },
            frontmostProcessIdentifier: { 42 }, ownProcessIdentifier: 42)
        var routeReasons: [PaceDisplayRouteReason] = []
        let subscription = coordinator.routeChanges.sink { routeReasons.append($0.reason) }
        coordinator.handleSystemEvent(.activeSpaceChanged)
        coordinator.handleSystemEvent(.activeSpaceChanged)
        XCTAssertEqual(routeReasons, [.activeSpaceChanged, .activeSpaceChanged])
        withExtendedLifetime(subscription) {}
    }

    func testRoutingRetainsVisibleConversationDraftFocusRequestAndExplanationCountdown() async throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let coordinator = PaceActiveDisplayCoordinator(
            screens: { [PaceDisplayGeometry(displayID: PaceDisplayID(rawValue: displayID), frame: screen.frame)] },
            pointerLocation: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            frontmostProcessIdentifier: { 42 }, ownProcessIdentifier: 42)
        let recorderFixture = PaceConversationRecorderTests()
        let (manager, _, _) = recorderFixture.makeDismissalFixture()
        let sleepGate = PaceConversationRecorderTests.ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: coordinator,
            shouldReducePanelMotion: { true }, waitForExplanationAutoClose: { await sleepGate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            panelManager.hidePanelForSmokeTest()
            sleepGate.resumeAll()
        }
        panelManager.showPanelForSmokeTest()
        manager.chatSession.draftMessageText = "Keep this unfinished question"
        let presentation = panelManager.presentation
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier == PaceExplanationAutoClose.windowIdentifier && $0.isVisible })
        let session = manager.chatSession
        let hadUnreadScreenSuggestion = session.hasUnreadScreenSuggestion
        panelManager.handleExplanationVoiceStateChange(.idle)
        try await recorderFixture.waitForAutoCloseSleeps(1, gate: sleepGate)
        let firstResponder = window.firstResponder
        let keyWindow = NSApp.keyWindow
        let applicationWasActive = NSApp.isActive
        coordinator.handleSystemEvent(.activeSpaceChanged)
        coordinator.handleSystemEvent(.screensChanged)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(NSApp.windows.contains { $0 === window })
        XCTAssertTrue(manager.chatSession === session)
        XCTAssertEqual(manager.chatSession.draftMessageText, "Keep this unfinished question")
        XCTAssertEqual(panelManager.presentation, presentation)
        XCTAssertTrue(window.firstResponder === firstResponder)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, applicationWasActive)
        XCTAssertEqual(session.hasUnreadScreenSuggestion, hadUnreadScreenSuggestion)
        XCTAssertEqual(sleepGate.requestedDurations, [.seconds(30)])
    }

    func testRoutingCannotOpenAHiddenConversationOrActivatePace() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let coordinator = PaceActiveDisplayCoordinator(
            screens: { [PaceDisplayGeometry(displayID: PaceDisplayID(rawValue: displayID), frame: screen.frame)] },
            pointerLocation: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            frontmostProcessIdentifier: { 42 }, ownProcessIdentifier: 42)
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(companionManager: manager, activeDisplayCoordinator: coordinator)
        let originalKeyWindow = NSApp.keyWindow
        let originalApplicationActivity = NSApp.isActive
        coordinator.handleSystemEvent(.activeSpaceChanged)
        coordinator.handleSystemEvent(.screensChanged)
        XCTAssertEqual(panelManager.presentation, .hidden)
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
        XCTAssertEqual(NSApp.isActive, originalApplicationActivity)
    }

    private func makeCoordinator(
        gate: FocusReadGate, frontmostProcessIdentifier: @escaping @MainActor () -> pid_t? = { 99 }
    ) -> PaceActiveDisplayCoordinator {
        PaceActiveDisplayCoordinator(
            screens: { [self.laptop, self.leftDisplay, self.upperDisplay] },
            pointerLocation: { CGPoint(x: 700, y: 500) },
            frontmostProcessIdentifier: frontmostProcessIdentifier, ownProcessIdentifier: 42,
            focusedWindowReader: { _, _ in await gate.read() })
    }

    private func drainTasks() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private actor FocusReadGate {
    private(set) var readCount = 0
    private var continuations: [CheckedContinuation<CGRect?, Never>] = []

    func read() async -> CGRect? {
        readCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func completeNext(with frame: CGRect?) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: frame)
    }

    func waitForReadCount(_ expectedCount: Int) async throws {
        for _ in 0..<1000 {
            if readCount >= expectedCount { return }
            await Task.yield()
        }
        throw NSError(domain: "PaceActiveDisplayCoordinatorTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Focused-window read did not start"])
    }
}
