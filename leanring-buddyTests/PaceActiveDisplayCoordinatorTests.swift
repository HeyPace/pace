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

    private final class MicrophoneCheckPlanner: BuddyPlannerClient {
        let displayName = "Microphone check test planner"
        let supportsImageInput = false
        var callCount = 0

        func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
            conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
            callCount += 1
            onTextChunk("yes, i can hear you.")
            return ("yes, i can hear you.", 0)
        }
    }

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

    func testClickRetiresRouteReadWithoutRetiringTheNewApplicationsObserver() async throws {
        for usesExplicitAnchor in [false, true] {
            let gate = FocusReadGate()
            let observerProbe = FocusObserverProbe()
            var frontmostProcessIdentifier: pid_t = 99
            var systemUptime: TimeInterval = 0
            let coordinator = PaceActiveDisplayCoordinator(
                screens: { [self.laptop, self.leftDisplay, self.upperDisplay] },
                pointerLocation: { CGPoint(x: 700, y: 500) },
                systemUptime: { systemUptime },
                frontmostProcessIdentifier: { frontmostProcessIdentifier }, ownProcessIdentifier: 42,
                focusedWindowReader: { processIdentifier, _ in await gate.read(processIdentifier: processIdentifier) },
                focusedWindowObservationFactory: { processIdentifier, onChange in
                    await observerProbe.makeBinding(processIdentifier: processIdentifier, onChange: onChange)
                })
            coordinator.handleSystemEvent(.applicationActivated)
            try await gate.waitForReadCount(1)
            await gate.completeNext(with: CGRect(x: 100, y: 100, width: 900, height: 700))
            try await observerProbe.waitForObservedProcessIdentifier(99)

            frontmostProcessIdentifier = 100
            coordinator.handleSystemEvent(.applicationActivated)
            try await gate.waitForReadCount(2)
            if usesExplicitAnchor {
                coordinator.selectDisplay(containing: CGRect(x: -1000, y: 900, width: 24, height: 24))
            } else {
                coordinator.pointerDidClick(at: CGPoint(x: -900, y: 400))
            }
            let clickedRoute = coordinator.route
            await gate.completeNext(with: CGRect(x: 100, y: 100, width: 900, height: 700))
            try await observerProbe.waitForObservedProcessIdentifier(100)
            XCTAssertEqual(coordinator.route, clickedRoute)

            systemUptime = 1
            await observerProbe.sendFocusedWindowChange()
            try await gate.waitForReadCount(3)
            await gate.completeNext(with: CGRect(x: 100, y: 1500, width: 1200, height: 700))
            await drainTasks()
            let readProcessIdentifiers = await gate.readProcessIdentifiers
            XCTAssertEqual(readProcessIdentifiers, [99, 100, 100])
            XCTAssertEqual(coordinator.route.displayID, upperDisplay.displayID)
            XCTAssertEqual(coordinator.route.reason, .focusedWindowChanged)
        }
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

    func testImmediateFocusedWindowChangeAfterClickFollowsTheNewWindow() async throws {
        let gate = FocusReadGate()
        let coordinator = PaceActiveDisplayCoordinator(
            screens: { [self.laptop, self.leftDisplay, self.upperDisplay] },
            pointerLocation: { CGPoint(x: 700, y: 500) }, systemUptime: { 100 },
            frontmostProcessIdentifier: { 99 }, ownProcessIdentifier: 42,
            focusedWindowReader: { _, _ in await gate.read() })
        coordinator.pointerDidClick(at: CGPoint(x: 700, y: 500))
        coordinator.handleSystemEvent(.focusedWindowChanged)
        try await gate.waitForReadCount(1)
        await gate.completeNext(with: CGRect(x: -1800, y: 200, width: 900, height: 600))
        await drainTasks()
        XCTAssertEqual(coordinator.route.displayID, leftDisplay.displayID)
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

    func testTextOnlyVoiceReplyPresentsItsConversationWithoutTakingKeyboardFocus() async throws {
        let fixture = try makeTwoPlacementFixture()
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
        defer { panelManager.hidePanelForSmokeTest() }
        manager.chatSession.draftMessageText = "Keep this unfinished typed question"
        manager.chatSession.isChatTTSMuted = true
        let planner = MicrophoneCheckPlanner()
        manager.plannerClient = planner
        manager.textOnlyPlannerClient = planner
        let originalKeyWindow = NSApp.keyWindow
        let originalApplicationActivity = NSApp.isActive

        manager.beginConversationRequest("Can you hear me?")
        _ = manager.turnLeaseRegistry.beginTurn()
        let acceptedEvent = try XCTUnwrap(manager.activeConversationUserEvent)
        XCTAssertEqual(panelManager.presentation, .hidden)
        manager.handleTextOnlyPlannerFastPath(transcript: "Can you hear me?")
        await manager.currentResponseTask?.value
        await drainTasks()

        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == PaceExplanationAutoClose.windowIdentifier && $0.isVisible
        })
        XCTAssertEqual(acceptedEvent.origin, .voice)
        XCTAssertEqual(panelManager.presentation, .preview)
        XCTAssertNil(panelManager.presentation.composerFocusRequestID)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
        XCTAssertEqual(NSApp.isActive, originalApplicationActivity)
        XCTAssertEqual(manager.chatSession.draftMessageText, "Keep this unfinished typed question")
        XCTAssertTrue(manager.chatSession.messages.contains { $0.body == "yes, i can hear you." })
        XCTAssertEqual(planner.callCount, 1)
        XCTAssertTrue(manager.conversationHistory.isEmpty)
        XCTAssertTrue(manager.memoryIndex.allEntries().isEmpty)
    }

    func testTypedAndPacePadEntryDoNotOpenTheMacConversationPanel() async throws {
        for isPacePadRequest in [false, true] {
            let fixture = try makeTwoPlacementFixture()
            let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
            let panelManager = MenuBarPanelManager(
                companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
                panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
            defer { panelManager.hidePanelForSmokeTest() }
            let transcript = "Can you hear me?"
            let planner = MicrophoneCheckPlanner()
            manager.plannerClient = planner
            manager.textOnlyPlannerClient = planner
            let originalKeyWindow = NSApp.keyWindow
            let originalApplicationActivity = NSApp.isActive

            if isPacePadRequest {
                XCTAssertTrue(manager.submitPacePadTranscript(
                    transcript, turnIdentifier: "ipad-turn", physicalSceneContext: nil))
            } else {
                manager.submitChatTranscriptFromDeepLink(transcript)
            }
            let acceptedOrigin = manager.activeConversationUserEvent?.origin
            manager.currentTurnDispatchTask?.cancel()
            manager.handleTextOnlyPlannerFastPath(transcript: transcript)
            await manager.currentResponseTask?.value
            manager.cancelActiveTurnTasks()

            XCTAssertEqual(acceptedOrigin, .typed)
            XCTAssertEqual(planner.callCount, 1)
            XCTAssertEqual(panelManager.presentation, .hidden)
            XCTAssertTrue(NSApp.keyWindow === originalKeyWindow)
            XCTAssertEqual(NSApp.isActive, originalApplicationActivity)
        }
    }

    func testVoicePreviewIsOwnedByItsManagerAndDoesNotReopenAfterDismissal() async throws {
        let fixture = try makeTwoPlacementFixture()
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let (otherManager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
        let otherPanelManager = MenuBarPanelManager(
            companionManager: otherManager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
        defer {
            panelManager.hidePanelForSmokeTest()
            otherPanelManager.hidePanelForSmokeTest()
        }

        manager.beginConversationRequest("Can you hear me?")
        let turnLease = manager.turnLeaseRegistry.beginTurn()
        manager.presentVoiceConversationPreviewIfCurrentTurn(turnLease)
        XCTAssertEqual(panelManager.presentation, .preview)
        XCTAssertEqual(otherPanelManager.presentation, .hidden)
        manager.voiceState = .responding
        NotificationCenter.default.post(
            name: .paceDismissPanel, object: PaceExplanationDismissalIntent.userInitiated)
        await drainTasks()
        XCTAssertEqual(panelManager.presentation, .hidden)

        manager.updateAssistantStreamingText("A delayed response chunk.")
        manager.voiceState = .idle
        manager.presentVoiceConversationPreviewIfCurrentTurn(turnLease)
        await drainTasks()
        XCTAssertEqual(panelManager.presentation, .hidden)
        XCTAssertEqual(otherPanelManager.presentation, .hidden)
    }

    func testAcceptedVoiceRequestAndIdlePointingStateDoNotOpenTheConversation() async throws {
        let fixture = try makeTwoPlacementFixture()
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
        defer { panelManager.hidePanelForSmokeTest() }

        manager.beginConversationRequest("Click the top button")
        _ = manager.turnLeaseRegistry.beginTurn()
        manager.voiceState = .processing
        manager.updateAssistantStreamingText("Clicking the top button.")
        manager.voiceState = .idle
        await drainTasks()

        XCTAssertEqual(panelManager.presentation, .hidden)
    }

    func testDeterministicVoiceAnswerPresentsTheConversation() async throws {
        let fixture = try makeTwoPlacementFixture()
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
        defer { panelManager.hidePanelForSmokeTest() }
        let transcript = "What is 17 + 25? Reply with only the number."
        manager.beginConversationRequest(transcript)
        _ = manager.turnLeaseRegistry.beginTurn()

        manager.handleDeterministicAnswerPath(
            transcript: transcript,
            parseResult: try XCTUnwrap(PaceDeterministicAnswerParser.parse(transcript: transcript)))
        await manager.currentResponseTask?.value

        XCTAssertEqual(panelManager.presentation, .preview)
        XCTAssertTrue(manager.chatSession.messages.contains { $0.body == "42" })
    }

    func testVoicePreviewDoesNotReopenWithinTheSameTurnAfterAutomaticDismissal() throws {
        let fixture = try makeTwoPlacementFixture()
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true })
        defer { panelManager.hidePanelForSmokeTest() }
        manager.beginConversationRequest("Can you hear me?")
        let turnLease = manager.turnLeaseRegistry.beginTurn()
        manager.presentVoiceConversationPreviewIfCurrentTurn(turnLease)
        XCTAssertEqual(panelManager.presentation, .preview)

        panelManager.hidePanelForSmokeTest()
        manager.presentVoiceConversationPreviewIfCurrentTurn(turnLease)

        XCTAssertEqual(panelManager.presentation, .hidden)
    }

    func testUnfocusedVoicePreviewAutoClosesWhilePreservingAnOlderDraft() async throws {
        let fixture = try makeTwoPlacementFixture()
        let recorderFixture = PaceConversationRecorderTests()
        let (manager, _, _) = recorderFixture.makeDismissalFixture()
        let sleepGate = PaceConversationRecorderTests.ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true },
            waitForExplanationAutoClose: { await sleepGate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            panelManager.hidePanelForSmokeTest()
            sleepGate.resumeAll()
        }
        manager.chatSession.draftMessageText = "Keep this unfinished question"
        manager.beginConversationRequest("Can you hear me?")
        let turnLease = manager.turnLeaseRegistry.beginTurn()
        manager.presentVoiceConversationPreviewIfCurrentTurn(turnLease)
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == PaceExplanationAutoClose.windowIdentifier && $0.isVisible
        })
        XCTAssertFalse(window.isKeyWindow)
        panelManager.handleExplanationVoiceStateChange(.idle)
        try await recorderFixture.waitForAutoCloseSleeps(1, gate: sleepGate)

        sleepGate.resumeNext()
        await drainTasks()

        XCTAssertEqual(panelManager.presentation, .hidden)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(manager.chatSession.draftMessageText, "Keep this unfinished question")
        XCTAssertEqual(sleepGate.requestedDurations, [.seconds(30)])
    }

    func testVoicePreviewKeepsAnUnsentDraftWhileItsWindowOwnsKeyboardFocus() async throws {
        let fixture = try makeTwoPlacementFixture()
        let recorderFixture = PaceConversationRecorderTests()
        let (manager, _, _) = recorderFixture.makeDismissalFixture()
        let sleepGate = PaceConversationRecorderTests.ExplanationAutoCloseSleepGate()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            panelPlacementResolver: fixture.placement, shouldReducePanelMotion: { true },
            waitForExplanationAutoClose: { await sleepGate.wait($0) })
        defer {
            panelManager.handleExplanationVoiceStateChange(.processing)
            panelManager.hidePanelForSmokeTest()
            sleepGate.resumeAll()
        }
        manager.beginConversationRequest("Can you hear me?")
        let turnLease = manager.turnLeaseRegistry.beginTurn()
        manager.presentVoiceConversationPreviewIfCurrentTurn(turnLease)
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == PaceExplanationAutoClose.windowIdentifier && $0.isVisible
        })
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isKeyWindow)
        manager.chatSession.draftMessageText = "Explain the next part"
        panelManager.handleExplanationVoiceStateChange(.idle)
        try await recorderFixture.waitForAutoCloseSleeps(1, gate: sleepGate)

        sleepGate.resumeNext()
        try await recorderFixture.waitForAutoCloseSleeps(2, gate: sleepGate)

        XCTAssertEqual(panelManager.presentation, .preview)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(manager.chatSession.draftMessageText, "Explain the next part")
        XCTAssertEqual(sleepGate.requestedDurations, [.seconds(30), .seconds(30)])
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

    func testOutsideClickKeepsTheConversationOnItsOldDisplayUntilDismissal() async throws {
        let fixture = try makeTwoPlacementFixture()
        var scheduledDismissals: [@MainActor () -> Void] = []
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, activeDisplayCoordinator: fixture.coordinator,
            usesChatPanelAsPrimarySurface: false,
            panelPlacementResolver: fixture.placement,
            scheduleOutsideClickDismissal: { scheduledDismissals.append($0) },
            shouldReducePanelMotion: { true })
        defer { panelManager.hidePanelForSmokeTest() }
        panelManager.showPanelForSmokeTest()
        await drainTasks()
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == PaceExplanationAutoClose.windowIdentifier && $0.isVisible
        })
        let oldFrame = window.frame
        let firstResponder = window.firstResponder
        let keyWindow = NSApp.keyWindow
        let applicationWasActive = NSApp.isActive
        let outsideClick = CGPoint(x: -900, y: 400)
        panelManager.dismissPanelIfClickIsOutside(at: outsideClick, currentDate: Date().addingTimeInterval(1))
        XCTAssertEqual(scheduledDismissals.count, 1)
        fixture.coordinator.pointerDidClick(at: outsideClick)
        fixture.coordinator.handleSystemEvent(.activeSpaceChanged)
        XCTAssertEqual(window.frame, oldFrame)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.firstResponder === firstResponder)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, applicationWasActive)
        scheduledDismissals[0]()
        XCTAssertEqual(panelManager.presentation, .hidden)
        XCTAssertFalse(window.isVisible)
    }

    func testCompactConversationFitsBelowThePhysicalNotchWithoutChangingWideDefaults() {
        let housingFrame = CGRect(x: 760, y: 1085, width: 200, height: 32)
        let notchGeometry = PaceLivingNotchGeometry(physicalHousingFrame: housingFrame, presentationFrame: housingFrame)
        let compactContentSize = CGSize(width: 320, height: 460)
        let compactPlacement = PaceConversationPanelPlacement.resolve(
            notchGeometry: notchGeometry, anchorFrame: housingFrame, screenFrame: laptop.frame,
            contentSize: compactContentSize, notchContentSize: compactContentSize)
        XCTAssertEqual(compactPlacement.frame.height, housingFrame.height + compactContentSize.height)
        XCTAssertGreaterThanOrEqual(compactPlacement.frame.width, compactContentSize.width)
        XCTAssertEqual(compactPlacement.frame.maxY, housingFrame.maxY)
        let widePlacement = PaceConversationPanelPlacement.resolve(
            notchGeometry: notchGeometry, anchorFrame: housingFrame, screenFrame: laptop.frame,
            contentSize: CGSize(width: PaceQuickPanelMetrics.width, height: PaceQuickPanelMetrics.height))
        XCTAssertEqual(widePlacement.frame.size, CGSize(width: 520, height: 412))
    }

    private func makeTwoPlacementFixture() throws -> (
        coordinator: PaceActiveDisplayCoordinator,
        placement: @MainActor (PaceActiveDisplayRoute) -> PaceConversationPanelPlacement?
    ) {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let housingFrame = CGRect(x: screen.frame.midX - 100, y: screen.frame.maxY - 32, width: 200, height: 32)
        let notchGeometry = PaceLivingNotchGeometry(physicalHousingFrame: housingFrame, presentationFrame: housingFrame)
        let notchPlacement = PaceConversationPanelPlacement.resolve(
            notchGeometry: notchGeometry, anchorFrame: housingFrame, screenFrame: screen.frame,
            contentSize: CGSize(width: PaceQuickPanelMetrics.width, height: PaceQuickPanelMetrics.height))
        let anchoredPlacement = PaceConversationPanelPlacement.anchored(CGRect(
            x: screen.frame.midX - 260, y: screen.frame.midY - 270, width: 520, height: 540))
        let coordinator = PaceActiveDisplayCoordinator(
            screens: { [self.laptop, self.leftDisplay] }, pointerLocation: { CGPoint(x: 700, y: 500) },
            frontmostProcessIdentifier: { 42 }, ownProcessIdentifier: 42)
        return (coordinator, { route in route.displayID == self.laptop.displayID ? notchPlacement : anchoredPlacement })
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
    private(set) var readProcessIdentifiers: [pid_t] = []
    private var continuations: [CheckedContinuation<CGRect?, Never>] = []

    func read(processIdentifier: pid_t? = nil) async -> CGRect? {
        readCount += 1
        if let processIdentifier { readProcessIdentifiers.append(processIdentifier) }
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

private actor FocusObserverProbe {
    private var observedProcessIdentifier: pid_t?
    private var callbacks: [pid_t: @MainActor @Sendable () -> Void] = [:]

    func makeBinding(
        processIdentifier: pid_t, onChange: @escaping @MainActor @Sendable () -> Void
    ) -> PaceFocusedWindowObserverBinding {
        callbacks[processIdentifier] = onChange
        return PaceFocusedWindowObserverBinding(
            start: { Task { await self.didStartObserving(processIdentifier) } }, stop: {})
    }

    func sendFocusedWindowChange() async {
        guard let observedProcessIdentifier else { return }
        await callbacks[observedProcessIdentifier]?()
    }

    private func didStartObserving(_ processIdentifier: pid_t) {
        observedProcessIdentifier = processIdentifier
    }

    func waitForObservedProcessIdentifier(_ processIdentifier: pid_t) async throws {
        for _ in 0..<1000 {
            if observedProcessIdentifier == processIdentifier { return }
            await Task.yield()
        }
        throw NSError(domain: "PaceActiveDisplayCoordinatorTests", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Focused-window observer did not bind to the frontmost app"])
    }
}
