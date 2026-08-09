//
//  PaceNativeInterfaceModelTests.swift
//  leanring-buddyTests
//

import XCTest
@testable import Pace

final class PaceNativeInterfaceModelTests: XCTestCase {
    func testLivingNotchDisplayModeUsesIdleHoverAndActivePriority() {
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .ready,
                isHovering: false,
                showsPersistentRuntimeIndicator: false
            ),
            .hardwareIdle
        )
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .ready,
                isHovering: true,
                showsPersistentRuntimeIndicator: false
            ),
            .hover
        )

        for signalState in PaceSignalState.allCases where signalState != .ready {
            XCTAssertEqual(
                PaceLivingNotchDisplayMode.resolve(
                    signalState: signalState,
                    isHovering: false,
                    showsPersistentRuntimeIndicator: false
                ),
                .active
            )
        }

        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .ready,
                isHovering: false,
                showsPersistentRuntimeIndicator: true
            ),
            .active
        )

        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .blocked,
                isHovering: false,
                showsPersistentRuntimeIndicator: true,
                isPanelOpen: true
            ),
            .panelOpen
        )
    }

    func testLivingNotchGeometryMatchesReportedMacBookHousing() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_728, height: 1_117)
        let auxiliaryTopLeftArea = CGRect(x: 0, y: 1_085, width: 771.5, height: 32)
        let auxiliaryTopRightArea = CGRect(x: 956.5, y: 1_085, width: 771.5, height: 32)

        let idleGeometry = PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .hardwareIdle
        )
        let hoverGeometry = PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .hover
        )
        let activeGeometry = PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .active
        )
        let panelOpenGeometry = PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .panelOpen
        )

        let expectedPhysicalHousingFrame = CGRect(
            x: 771.5,
            y: 1_085,
            width: 185,
            height: 32
        )
        XCTAssertEqual(idleGeometry?.physicalHousingFrame, expectedPhysicalHousingFrame)
        XCTAssertEqual(idleGeometry?.presentationFrame, expectedPhysicalHousingFrame)
        XCTAssertEqual(
            hoverGeometry?.presentationFrame,
            CGRect(x: 714, y: 1_085, width: 300, height: 32)
        )
        XCTAssertEqual(
            activeGeometry?.presentationFrame,
            CGRect(x: 694, y: 1_085, width: 340, height: 32)
        )
        XCTAssertEqual(
            panelOpenGeometry?.presentationFrame,
            CGRect(x: 604, y: 765, width: 520, height: 352)
        )
    }

    func testLivingNotchExpansionKeepsTheHardwareHousingCenteredAndTopAligned() throws {
        let screenFrame = CGRect(x: -1_200, y: 180, width: 1_728, height: 1_117)
        let auxiliaryTopLeftArea = CGRect(x: -1_200, y: 1_265, width: 771.5, height: 32)
        let auxiliaryTopRightArea = CGRect(x: -243.5, y: 1_265, width: 771.5, height: 32)

        let idleGeometry = try XCTUnwrap(PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .hardwareIdle
        ))
        let activeGeometry = try XCTUnwrap(PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .active
        ))

        XCTAssertEqual(activeGeometry.physicalHousingFrame, idleGeometry.physicalHousingFrame)
        XCTAssertEqual(activeGeometry.presentationFrame.midX, idleGeometry.presentationFrame.midX)
        XCTAssertGreaterThan(activeGeometry.presentationFrame.width, idleGeometry.presentationFrame.width)
        XCTAssertEqual(activeGeometry.presentationFrame.maxY, idleGeometry.presentationFrame.maxY)
        XCTAssertEqual(activeGeometry.presentationFrame.minY, idleGeometry.presentationFrame.minY)
    }

    func testOpenPanelExpandsEquallyFromTheHousingCenterAndStaysOnScreen() throws {
        let screenFrame = CGRect(x: -1_200, y: 180, width: 1_728, height: 1_117)
        let auxiliaryTopLeftArea = CGRect(x: -1_200, y: 1_265, width: 771.5, height: 32)
        let auxiliaryTopRightArea = CGRect(x: -243.5, y: 1_265, width: 771.5, height: 32)

        let openGeometry = try XCTUnwrap(PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 32,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .panelOpen
        ))

        XCTAssertEqual(openGeometry.presentationFrame.width, PaceQuickPanelMetrics.width)
        XCTAssertEqual(
            openGeometry.presentationFrame.height,
            openGeometry.physicalHousingFrame.height + PaceQuickPanelMetrics.height
        )
        XCTAssertEqual(
            openGeometry.presentationFrame.midX,
            openGeometry.physicalHousingFrame.midX
        )
        XCTAssertEqual(openGeometry.presentationFrame.maxY, screenFrame.maxY)
        XCTAssertGreaterThanOrEqual(openGeometry.presentationFrame.minX, screenFrame.minX + 8)
        XCTAssertLessThanOrEqual(openGeometry.presentationFrame.maxX, screenFrame.maxX - 8)
    }

    func testLivingNotchGeometryRejectsDisplaysWithoutReliableHousingBounds() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let leftArea = CGRect(x: 0, y: 876, width: 620, height: 24)
        let rightArea = CGRect(x: 820, y: 876, width: 620, height: 24)

        XCTAssertNil(PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea,
            displayMode: .hardwareIdle
        ))
        XCTAssertNil(PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 24,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            displayMode: .hardwareIdle
        ))
        XCTAssertNil(PaceLivingNotchGeometry.resolve(
            screenFrame: screenFrame,
            safeAreaTopInset: 24,
            auxiliaryTopLeftArea: rightArea,
            auxiliaryTopRightArea: leftArea,
            displayMode: .active
        ))
    }

    func testEverySignalStateHasStableSemanticCopy() {
        let expectedLabels: [PaceSignalState: String] = [
            .ready: "Ready",
            .listening: "Listening",
            .understanding: "Understanding",
            .awaitingApproval: "Waiting for approval",
            .acting: "Acting",
            .speaking: "Speaking",
            .completed: "Complete",
            .blocked: "Needs attention",
            .failed: "Couldn’t complete",
        ]
        let expectedCompactLabels: [PaceSignalState: String] = [
            .ready: "Ready",
            .listening: "Listening",
            .understanding: "Thinking",
            .awaitingApproval: "Approval",
            .acting: "Acting",
            .speaking: "Speaking",
            .completed: "Complete",
            .blocked: "Attention",
            .failed: "Failed",
        ]

        XCTAssertEqual(expectedLabels.count, PaceSignalState.allCases.count)
        for signalState in PaceSignalState.allCases {
            let presentation = PaceSignalPresentation.resolve(
                state: signalState,
                isOffDeviceTurn: false,
                reduceMotion: false
            )
            XCTAssertEqual(presentation.label, expectedLabels[signalState])
            XCTAssertEqual(presentation.compactLabel, expectedCompactLabels[signalState])
            XCTAssertTrue(presentation.accessibilityValue.contains("Processing on this Mac"))
        }
    }

    func testOffDeviceBoundaryOverridesEveryStateColorRole() {
        for signalState in PaceSignalState.allCases {
            let presentation = PaceSignalPresentation.resolve(
                state: signalState,
                isOffDeviceTurn: true,
                reduceMotion: false
            )
            XCTAssertEqual(presentation.colorRole, .offDevice)
            XCTAssertTrue(presentation.accessibilityValue.contains("Off-device planner active"))
        }
    }

    func testLocalSemanticStatesUseDistinctOutcomeRoles() {
        XCTAssertEqual(localPresentation(for: .ready).colorRole, .local)
        XCTAssertEqual(localPresentation(for: .awaitingApproval).colorRole, .approval)
        XCTAssertEqual(localPresentation(for: .completed).colorRole, .success)
        XCTAssertEqual(localPresentation(for: .blocked).colorRole, .blocked)
        XCTAssertEqual(localPresentation(for: .failed).colorRole, .failure)
    }

    func testMotionPolicyFollowsSignalState() {
        XCTAssertEqual(localPresentation(for: .ready).motionPolicy, .still)
        XCTAssertEqual(localPresentation(for: .listening).motionPolicy, .audioReactive)
        XCTAssertEqual(localPresentation(for: .understanding).motionPolicy, .crossfade)
        XCTAssertEqual(localPresentation(for: .awaitingApproval).motionPolicy, .crossfade)
        XCTAssertEqual(localPresentation(for: .acting).motionPolicy, .crossfade)
        XCTAssertEqual(localPresentation(for: .speaking).motionPolicy, .crossfade)
        XCTAssertEqual(localPresentation(for: .completed).motionPolicy, .still)
        XCTAssertEqual(localPresentation(for: .blocked).motionPolicy, .still)
        XCTAssertEqual(localPresentation(for: .failed).motionPolicy, .still)
    }

    func testEveryActiveSignalStateHasAPlainLanguageAccessibilityAnnouncement() {
        XCTAssertNil(
            PaceSignalPresentation.accessibilityAnnouncement(
                for: .ready,
                isOffDeviceTurn: false
            )
        )

        for signalState in PaceSignalState.allCases where signalState != .ready {
            let localAnnouncement = PaceSignalPresentation.accessibilityAnnouncement(
                for: signalState,
                isOffDeviceTurn: false
            )
            XCTAssertFalse(localAnnouncement?.isEmpty ?? true)
        }

        XCTAssertEqual(
            PaceSignalPresentation.accessibilityAnnouncement(
                for: .understanding,
                isOffDeviceTurn: true
            ),
            "Pace is understanding your request using the off-device model you enabled."
        )
    }

    func testReduceMotionReplacesActiveMotionWithCrossfade() {
        for signalState in PaceSignalState.allCases where signalState != .ready {
            let presentation = PaceSignalPresentation.resolve(
                state: signalState,
                isOffDeviceTurn: false,
                reduceMotion: true
            )
            XCTAssertEqual(presentation.motionPolicy, .crossfade)
        }
        XCTAssertEqual(
            PaceSignalPresentation.resolve(
                state: .ready,
                isOffDeviceTurn: false,
                reduceMotion: true
            ).motionPolicy,
            .still
        )
    }

    func testSignalInterruptionSettlesToNewestVisibleState() {
        XCTAssertEqual(
            PaceSignalInterruptionOutcome.resolve(
                latestState: .awaitingApproval,
                surfaceIsVisible: true
            ),
            .settle(.awaitingApproval)
        )
        XCTAssertEqual(
            PaceSignalInterruptionOutcome.resolve(
                latestState: .speaking,
                surfaceIsVisible: false
            ),
            .hidden
        )
    }

    func testPanelPresentationMapsEveryRuntimeState() {
        let fixtures: [(PaceRuntimeVoicePhase, PaceRuntimeHUDPhase, PaceActionRunStatus?, PaceSignalState)] = [
            (.idle, .idle, nil, .ready),
            (.idle, .listening, nil, .listening),
            (.idle, .understanding, nil, .understanding),
            (.processing, .acting, .planned, .awaitingApproval),
            (.processing, .acting, nil, .acting),
            (.responding, .idle, nil, .speaking),
            (.idle, .done, .completed, .completed),
            (.idle, .needsClarification, nil, .blocked),
            (.idle, .failed, .failed, .failed),
        ]

        for fixture in fixtures {
            let presentation = PacePanelPresentationModel.resolve(
                voicePhase: fixture.0,
                hudPhase: fixture.1,
                latestActionStatus: fixture.2,
                hasConversationContent: true,
                hasLiveTranscript: false,
                hasStreamedResponse: false
            )
            XCTAssertEqual(presentation.signalState, fixture.3)
        }
    }

    func testPanelEmptyStateRequiresNoConversationOrLiveTurnContent() {
        let emptyPresentation = PacePanelPresentationModel.resolve(
            voicePhase: .idle,
            hudPhase: .idle,
            latestActionStatus: nil,
            hasConversationContent: false,
            hasLiveTranscript: false,
            hasStreamedResponse: false
        )
        XCTAssertTrue(emptyPresentation.showsEmptyState)

        let livePresentation = PacePanelPresentationModel.resolve(
            voicePhase: .listening,
            hudPhase: .listening,
            latestActionStatus: nil,
            hasConversationContent: false,
            hasLiveTranscript: true,
            hasStreamedResponse: false
        )
        XCTAssertFalse(livePresentation.showsEmptyState)
    }

    func testLegacyCompletionMigratesWithoutReplayingOnboarding() {
        let stateModel = PaceOnboardingStateModel(
            storedCompletionVersion: nil,
            legacyCompletionFlag: true,
            storedCheckpoint: PaceOnboardingStage.firstCommand.rawValue
        )

        XCTAssertEqual(stateModel.stage, .complete)
        XCTAssertFalse(stateModel.shouldPresentAutomatically)
    }

    func testOnboardingResumesAtStoredCheckpoint() {
        let stateModel = PaceOnboardingStateModel(
            storedCompletionVersion: nil,
            legacyCompletionFlag: false,
            storedCheckpoint: PaceOnboardingStage.permissions.rawValue
        )

        XCTAssertEqual(stateModel.stage, .permissions)
        XCTAssertTrue(stateModel.shouldPresentAutomatically)
    }

    func testOnboardingProgressesOnlyAfterTruthfulFirstValue() {
        var stateModel = PaceOnboardingStateModel(
            storedCompletionVersion: nil,
            legacyCompletionFlag: false,
            storedCheckpoint: nil
        )
        stateModel.send(.continueForward)
        stateModel.send(.continueForward)

        stateModel.send(.firstValue(.failed))
        XCTAssertEqual(stateModel.stage, .firstCommand)

        stateModel.send(.firstValue(.responseReceived))
        XCTAssertEqual(stateModel.stage, .handoff)

        stateModel.send(.handoffFinished)
        XCTAssertEqual(stateModel.stage, .complete)
    }

    func testOnboardingSupportsBackNavigationBeforeHandoff() {
        var stateModel = PaceOnboardingStateModel(
            storedCompletionVersion: nil,
            legacyCompletionFlag: false,
            storedCheckpoint: nil
        )

        stateModel.send(.continueForward)
        stateModel.send(.continueForward)
        XCTAssertEqual(stateModel.stage, .firstCommand)

        stateModel.send(.goBack)
        XCTAssertEqual(stateModel.stage, .permissions)

        stateModel.send(.goBack)
        XCTAssertEqual(stateModel.stage, .ignition)

        stateModel.send(.goBack)
        XCTAssertEqual(stateModel.stage, .ignition)
    }

    func testPermissionAutoAdvanceIsScheduledOnlyForThePermissionStage() {
        var stateModel = PaceOnboardingStateModel(
            storedCompletionVersion: nil,
            legacyCompletionFlag: false,
            storedCheckpoint: nil
        )
        XCTAssertFalse(
            stateModel.shouldSchedulePermissionAutoAdvance(
                allCorePermissionsGranted: true
            )
        )

        stateModel.send(.continueForward)
        XCTAssertFalse(
            stateModel.shouldSchedulePermissionAutoAdvance(
                allCorePermissionsGranted: false
            )
        )
        XCTAssertTrue(
            stateModel.shouldSchedulePermissionAutoAdvance(
                allCorePermissionsGranted: true
            )
        )
    }

    func testCancelledDelayedTransitionCannotAdvanceAStaleStage() {
        var delayedTransitionGate = PaceOnboardingDelayedTransitionGate()
        let permissionTransitionToken = delayedTransitionGate.schedule(for: .permissions)
        XCTAssertTrue(
            delayedTransitionGate.shouldApply(
                permissionTransitionToken,
                currentStage: .permissions
            )
        )

        delayedTransitionGate.cancel()
        XCTAssertFalse(
            delayedTransitionGate.shouldApply(
                permissionTransitionToken,
                currentStage: .permissions
            )
        )

        let firstCommandTransitionToken = delayedTransitionGate.schedule(for: .firstCommand)
        XCTAssertFalse(
            delayedTransitionGate.shouldApply(
                firstCommandTransitionToken,
                currentStage: .handoff
            )
        )
    }

    func testSkipCompletesJourneyAndReplayDoesNotClearCompletionHistory() {
        var stateModel = PaceOnboardingStateModel(
            storedCompletionVersion: PaceOnboardingStateModel.currentVersion,
            legacyCompletionFlag: true,
            storedCheckpoint: nil
        )
        XCTAssertEqual(stateModel.stage, .complete)

        stateModel.send(.replayRequested)
        XCTAssertEqual(stateModel.stage, .ignition)
        XCTAssertTrue(stateModel.isReplay)

        stateModel.send(.skipJourney)
        XCTAssertEqual(stateModel.stage, .complete)
        XCTAssertTrue(stateModel.isReplay)
    }

    @MainActor
    func testProgressStoreWritesVersionAndMigratesLegacyFlag() {
        let suiteName = "PaceNativeInterfaceModelTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let progressStore = PaceOnboardingProgressStore(userDefaults: userDefaults)
        XCTAssertTrue(progressStore.loadState().shouldPresentAutomatically)

        progressStore.markCompleted()

        XCTAssertEqual(
            userDefaults.integer(forKey: PaceOnboardingProgressStore.completionVersionKey),
            PaceOnboardingStateModel.currentVersion
        )
        XCTAssertTrue(userDefaults.bool(forKey: PaceOnboardingProgressStore.legacyCompletionKey))
        XCTAssertEqual(progressStore.loadState().stage, .complete)
    }

    func testFirstCommandOutcomeClassificationUsesProductionResultPriority() {
        XCTAssertEqual(
            classifyFirstCommand(latestActionStatus: .completed),
            .actionCompleted
        )
        XCTAssertEqual(
            classifyFirstCommand(latestActionStatus: .planned),
            .awaitingApproval
        )
        XCTAssertEqual(
            classifyFirstCommand(latestActionStatus: .denied),
            .blocked
        )
        XCTAssertEqual(
            classifyFirstCommand(latestActionStatus: .failed),
            .failed
        )
        XCTAssertEqual(
            classifyFirstCommand(
                hasNewAssistantResponse: true,
                latestActionStatus: nil
            ),
            .responseReceived
        )
    }

    func testCommandCenterDestinationsHaveOneDeterministicGroup() {
        let groupedDestinations = PaceCommandCenterGroup.allCases.flatMap {
            PaceCommandCenterDestination.destinations(in: $0)
        }

        XCTAssertEqual(groupedDestinations.count, PaceCommandCenterDestination.allCases.count)
        XCTAssertEqual(Set(groupedDestinations).count, PaceCommandCenterDestination.allCases.count)
        XCTAssertEqual(PaceCommandCenterDestination.conversations.group, .work)
        XCTAssertEqual(PaceCommandCenterDestination.privacy.group, .observe)
        XCTAssertEqual(PaceCommandCenterDestination.models.group, .configure)
        XCTAssertEqual(PaceCommandCenterDestination.doctor.group, .diagnostics)
    }

    func testCommandCenterPrimaryGroupsExposeAtMostFourChoices() {
        for group in PaceCommandCenterGroup.allCases {
            let primaryDestinations = PaceCommandCenterDestination.primaryDestinations(in: group)
            XCTAssertFalse(primaryDestinations.isEmpty)
            XCTAssertLessThanOrEqual(primaryDestinations.count, 4)
            XCTAssertTrue(primaryDestinations.allSatisfy { !$0.isAdvanced })
        }

        XCTAssertEqual(
            Set(PaceCommandCenterDestination.primaryDestinations(in: .configure)),
            Set([.general, .models, .voice, .memory])
        )
        XCTAssertTrue(PaceCommandCenterDestination.advancedDestinations.allSatisfy(\.isAdvanced))
    }

    func testCommandCenterDestinationsHavePlainLanguageGuidance() {
        for destination in PaceCommandCenterDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertFalse(destination.subtitle.isEmpty)
        }

        XCTAssertEqual(PaceCommandCenterDestination.planner.title, "How Pace thinks")
        XCTAssertEqual(PaceCommandCenterDestination.mcp.title, "Connected apps & tools")
        XCTAssertEqual(PaceCommandCenterDestination.doctor.title, "Help & diagnostics")
    }

    func testCommandCenterRoutingPrefersRequestThenStoredThenDefault() {
        XCTAssertEqual(
            PaceCommandCenterDestination.resolve(
                requestedDestination: .models,
                storedDestinationRawValue: PaceCommandCenterDestination.activity.rawValue
            ),
            .models
        )
        XCTAssertEqual(
            PaceCommandCenterDestination.resolve(
                requestedDestination: nil,
                storedDestinationRawValue: PaceCommandCenterDestination.activity.rawValue
            ),
            .activity
        )
        XCTAssertEqual(
            PaceCommandCenterDestination.resolve(
                requestedDestination: nil,
                storedDestinationRawValue: "removed-destination"
            ),
            .conversations
        )
    }

    @MainActor
    func testCommandCenterRouterPersistsAndHonorsRequestedDestination() {
        let suiteName = "PaceCommandCenterRouterTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(
            PaceCommandCenterDestination.activity.rawValue,
            forKey: PaceCommandCenterRouter.storedDestinationKey
        )

        let restoredRouter = PaceCommandCenterRouter(
            requestedDestination: nil,
            userDefaults: userDefaults
        )
        XCTAssertEqual(restoredRouter.selectedDestination, .activity)

        let requestedRouter = PaceCommandCenterRouter(
            requestedDestination: .models,
            userDefaults: userDefaults
        )
        XCTAssertEqual(requestedRouter.selectedDestination, .models)
        requestedRouter.select(.privacy)
        XCTAssertEqual(
            userDefaults.string(forKey: PaceCommandCenterRouter.storedDestinationKey),
            PaceCommandCenterDestination.privacy.rawValue
        )
    }

    private func localPresentation(for signalState: PaceSignalState) -> PaceSignalPresentation {
        PaceSignalPresentation.resolve(
            state: signalState,
            isOffDeviceTurn: false,
            reduceMotion: false
        )
    }

    private func classifyFirstCommand(
        hasNewAssistantResponse: Bool = false,
        latestActionStatus: PaceActionRunStatus?,
        isAwaitingApproval: Bool = false,
        hasFailureNarration: Bool = false,
        requestIsInFlight: Bool = false
    ) -> PaceFirstCommandOutcome {
        PaceFirstCommandOutcome.classify(
            hasNewAssistantResponse: hasNewAssistantResponse,
            latestActionStatus: latestActionStatus,
            isAwaitingApproval: isAwaitingApproval,
            hasFailureNarration: hasFailureNarration,
            requestIsInFlight: requestIsInFlight
        )
    }
}
