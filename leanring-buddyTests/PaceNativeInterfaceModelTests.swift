import AppKit
//
//  PaceNativeInterfaceModelTests.swift
//  leanring-buddyTests
//

import SwiftUI
import XCTest
@testable import Pace

final class PaceNativeInterfaceModelTests: XCTestCase {
    func testCrowdedMenusYieldOnlyWhenTheirBoundsReachTheNotchControls() {
        let housing = CGRect(x: 770, y: 1085, width: 185, height: 32)
        let controls = CGRect(x: 726, y: 1085, width: 273, height: 32)
        var occupancy = PaceMenuBarOccupancy(
            itemFrames: [CGRect(x: 0, y: 1085, width: 700, height: 32),
                         CGRect(x: 1020, y: 1085, width: 700, height: 32)],
            isReliable: true)
        XCTAssertFalse(occupancy.overlaps(controls, housingFrame: housing))
        occupancy.itemFrames.append(CGRect(x: 710, y: 1085, width: 35, height: 32))
        XCTAssertTrue(occupancy.overlaps(controls, housingFrame: housing))
        occupancy.itemFrames.removeLast()
        occupancy.itemFrames.append(CGRect(x: 990, y: 1085, width: 35, height: 32))
        XCTAssertTrue(occupancy.overlaps(controls, housingFrame: housing))
    }

    func testCrowdingChecksExpandedChatWidthButIgnoresWindowsBelowMenuRow() {
        let housing = CGRect(x: 770, y: 1085, width: 185, height: 32)
        let controls = CGRect(x: 726, y: 1085, width: 273, height: 32)
        let conversation = CGRect(x: 602.5, y: 705, width: 520, height: 412)
        var occupancy = PaceMenuBarOccupancy(
            itemFrames: [CGRect(x: 650, y: 1085, width: 45, height: 32)], isReliable: true)
        XCTAssertFalse(occupancy.overlaps(controls, housingFrame: housing))
        XCTAssertTrue(occupancy.overlaps(conversation, housingFrame: housing))
        occupancy.itemFrames = [CGRect(x: 650, y: 800, width: 500, height: 100)]
        XCTAssertFalse(occupancy.overlaps(conversation, housingFrame: housing))
    }

    func testUncertainMenuGeometryYieldsAndFreshClearGeometryRestoresControls() {
        let housing = CGRect(x: -430, y: 1265, width: 185, height: 32)
        let controls = CGRect(x: -474, y: 1265, width: 273, height: 32)
        var occupancy = PaceMenuBarOccupancy()
        XCTAssertTrue(occupancy.overlaps(controls, housingFrame: housing))
        occupancy = PaceMenuBarOccupancy(itemFrames: [], isReliable: true)
        XCTAssertFalse(occupancy.overlaps(controls, housingFrame: housing))
        occupancy.itemFrames = [CGRect(x: -480, y: 1265, width: 30, height: 32)]
        XCTAssertTrue(occupancy.overlaps(controls, housingFrame: housing))
        occupancy.itemFrames = []
        XCTAssertFalse(occupancy.overlaps(controls, housingFrame: housing))
    }

    func testMenuBoundsConversionUsesPrimaryDisplayOriginForSecondaryDisplays() {
        XCTAssertEqual(
            PaceMenuBarOccupancy.appKitFrame(
                from: CGRect(x: -1200, y: -180, width: 400, height: 32), primaryScreenTop: 1117),
            CGRect(x: -1200, y: 1265, width: 400, height: 32))
    }

    func testHoverPreviewShowsPanelWithoutRequestingKeyboardOrComposerFocus() {
        let presentation = PaceConversationPanelPresentation.hidden.presenting(.preview)

        XCTAssertEqual(presentation, .preview)
        XCTAssertTrue(presentation.isPresented)
        XCTAssertFalse(PaceConversationPanelPresentationIntent.preview.requestsKeyboardFocus)
        XCTAssertNil(presentation.composerFocusRequestID)
    }

    func testExplicitPresentationUpgradesVisiblePreviewAndRequestsComposerFocus() {
        let preview = PaceConversationPanelPresentation.hidden.presenting(.preview)
        let presentation = preview.presenting(.interactive)

        XCTAssertTrue(presentation.isPresented)
        XCTAssertTrue(PaceConversationPanelPresentationIntent.interactive.requestsKeyboardFocus)
        XCTAssertNotNil(presentation.composerFocusRequestID)
    }

    func testHoverCannotDowngradeInteractivePresentationOrRequestFocusAgain() {
        let interactivePresentation = PaceConversationPanelPresentation.hidden.presenting(.interactive)
        let presentationAfterHover = interactivePresentation.presenting(.preview)

        XCTAssertEqual(presentationAfterHover, interactivePresentation)
        XCTAssertEqual(
            presentationAfterHover.composerFocusRequestID,
            interactivePresentation.composerFocusRequestID)
        XCTAssertFalse(PaceConversationPanelPresentationIntent.preview.requestsKeyboardFocus)
    }

    func testExplicitPresentationRequestsComposerFocusAgainWhenAlreadyVisible() {
        let firstPresentation = PaceConversationPanelPresentation.hidden.presenting(.interactive)
        let secondPresentation = firstPresentation.presenting(.interactive)

        XCTAssertTrue(secondPresentation.isPresented)
        XCTAssertNotNil(secondPresentation.composerFocusRequestID)
        XCTAssertNotEqual(secondPresentation.composerFocusRequestID, firstPresentation.composerFocusRequestID)
    }

    func testHidingClearsComposerFocusBeforeNextHoverPreview() {
        var presentation = PaceConversationPanelPresentation.hidden.presenting(.interactive)
        XCTAssertNotNil(presentation.composerFocusRequestID)

        presentation = .hidden
        XCTAssertFalse(presentation.isPresented)
        XCTAssertNil(presentation.composerFocusRequestID)

        presentation = presentation.presenting(.preview)
        XCTAssertEqual(presentation, .preview)
        XCTAssertNil(presentation.composerFocusRequestID)
    }

    func testLivingNotchDisplayModeUsesIdleHoverAndActivePriority() {
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .ready,
                isHovering: false,
                showsPersistentRuntimeIndicator: false
            ),
            .resting
        )
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .ready,
                isHovering: true,
                showsPersistentRuntimeIndicator: false
            ),
            .hover
        )

        for signalState in PaceSignalState.allCases where signalState != .ready && signalState != .completed {
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
    }

    func testCompletedNotchReturnsToRestUnlessCaptureOrOffDeviceWorkIsActive() {
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .completed, isHovering: false, showsPersistentRuntimeIndicator: false), .resting)
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .completed, isHovering: true, showsPersistentRuntimeIndicator: false), .hover)
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.resolve(
                signalState: .completed, isHovering: false, showsPersistentRuntimeIndicator: true), .active)
    }

    func testCompletedPanelKeepsActualVoiceActivityVisibleInAmbientNotch() {
        let examples: [(PaceRuntimeVoicePhase, PaceSignalState, PaceLivingNotchDisplayMode)] = [
            (.idle, .completed, .resting), (.listening, .listening, .active),
            (.processing, .understanding, .active), (.responding, .speaking, .active),
        ]
        for (voicePhase, expectedSignal, expectedMode) in examples {
            let signal = PaceLivingNotchDisplayMode.ambientSignalState(
                panelSignalState: .completed, voicePhase: voicePhase)
            XCTAssertEqual(signal, expectedSignal)
            XCTAssertEqual(
                PaceLivingNotchDisplayMode.resolve(
                    signalState: signal, isHovering: false, showsPersistentRuntimeIndicator: false), expectedMode)
        }
        XCTAssertEqual(
            PaceLivingNotchDisplayMode.ambientSignalState(
                panelSignalState: .failed, voicePhase: .responding), .failed)
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
            displayMode: .resting
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
        let expectedPhysicalHousingFrame = CGRect(
            x: 771.5,
            y: 1_085,
            width: 185,
            height: 32
        )
        XCTAssertEqual(idleGeometry?.physicalHousingFrame, expectedPhysicalHousingFrame)
        XCTAssertEqual(idleGeometry?.presentationFrame, hoverGeometry?.presentationFrame)
        XCTAssertEqual(idleGeometry?.presentationFrame.height, expectedPhysicalHousingFrame.height)
        XCTAssertEqual(
            hoverGeometry?.presentationFrame,
            CGRect(x: 727.5, y: 1_085, width: 273, height: 32)
        )
        XCTAssertEqual(
            activeGeometry?.presentationFrame,
            CGRect(x: 727.5, y: 1_053, width: 273, height: 64)
        )

    }

    func testLivingNotchExpansionKeepsTheHardwareHousingCenteredAndTopAligned() throws {
        let screenFrame = CGRect(x: -1_200, y: 180, width: 1_728, height: 1_117)
        let auxiliaryTopLeftArea = CGRect(x: -1_200, y: 1_265, width: 771.5, height: 32)
        let auxiliaryTopRightArea = CGRect(x: -243.5, y: 1_265, width: 771.5, height: 32)

        let idleGeometry = try XCTUnwrap(
            PaceLivingNotchGeometry.resolve(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                auxiliaryTopLeftArea: auxiliaryTopLeftArea,
                auxiliaryTopRightArea: auxiliaryTopRightArea,
                displayMode: .resting
            ))
        let activeGeometry = try XCTUnwrap(
            PaceLivingNotchGeometry.resolve(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                auxiliaryTopLeftArea: auxiliaryTopLeftArea,
                auxiliaryTopRightArea: auxiliaryTopRightArea,
            displayMode: .active
        ))

        XCTAssertEqual(activeGeometry.physicalHousingFrame, idleGeometry.physicalHousingFrame)
        XCTAssertEqual(activeGeometry.presentationFrame.midX, idleGeometry.presentationFrame.midX)
        XCTAssertEqual(activeGeometry.presentationFrame.width, idleGeometry.presentationFrame.width)
        XCTAssertEqual(activeGeometry.presentationFrame.maxY, idleGeometry.presentationFrame.maxY)
        XCTAssertLessThan(activeGeometry.presentationFrame.minY, idleGeometry.presentationFrame.minY)
        XCTAssertEqual(activeGeometry.presentationFrame.maxY, activeGeometry.physicalHousingFrame.maxY)
        XCTAssertTrue(activeGeometry.presentationFrame.contains(activeGeometry.physicalHousingFrame))
    }

    func testSeamKeepsReadableWingsBesideWiderHardwareHousing() throws {
        let geometry = try XCTUnwrap(
            PaceLivingNotchGeometry.resolve(
                screenFrame: CGRect(x: 0, y: 0, width: 1_728, height: 1_117),
                safeAreaTopInset: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1_085, width: 751.5, height: 32),
                auxiliaryTopRightArea: CGRect(x: 976.5, y: 1_085, width: 751.5, height: 32),
                displayMode: .active))
        XCTAssertEqual(geometry.physicalHousingFrame.width, 225)
        XCTAssertEqual(geometry.presentationFrame.width, 313)
        XCTAssertEqual(geometry.presentationFrame.midX, geometry.physicalHousingFrame.midX)
        XCTAssertGreaterThanOrEqual((geometry.presentationFrame.width - geometry.physicalHousingFrame.width) / 2, 44)
    }

    func testSeamlessConversationStaysConnectedToPhysicalHousing() throws {
        let screenFrame = CGRect(x: -1_200, y: 180, width: 1_728, height: 1_117)
        let housing = CGRect(x: -428.5, y: 1_265, width: 185, height: 32)
        let placement = PaceConversationPanelPlacement.resolve(
            notchGeometry: PaceLivingNotchGeometry(physicalHousingFrame: housing, presentationFrame: housing),
            anchorFrame: housing,
            screenFrame: screenFrame,
            contentSize: CGSize(width: 520, height: 540))
        guard case .physicalNotch = placement else { return XCTFail("Expected physical notch placement") }
        XCTAssertEqual(placement.frame.width, 520)
        XCTAssertEqual(placement.frame.height, 412)
        XCTAssertEqual(placement.frame.midX, housing.midX)
        XCTAssertEqual(placement.frame.maxY, housing.maxY)
        XCTAssertTrue(placement.frame.contains(housing))
        XCTAssertEqual(placement.collapsedFrame.midX, housing.midX)
        XCTAssertEqual(placement.collapsedFrame.maxY, housing.maxY)
        XCTAssertEqual(placement.collapsedFrame.height, housing.height)
        XCTAssertEqual(placement.collapsedFrame.width, 273)
    }

    func testSeamlessConversationKeepsWideCameraReservationReadable() {
        let housing = CGRect(x: 714, y: 1_085, width: 300, height: 32)
        let placement = PaceConversationPanelPlacement.resolve(
            notchGeometry: PaceLivingNotchGeometry(physicalHousingFrame: housing, presentationFrame: housing),
            anchorFrame: housing,
            screenFrame: CGRect(x: 0, y: 0, width: 1_728, height: 1_117),
            contentSize: CGSize(width: 520, height: 540))
        XCTAssertEqual(placement.collapsedFrame.width, 388)
        XCTAssertEqual((placement.collapsedFrame.width - housing.width) / 2, 44)
        XCTAssertEqual(placement.frame.maxY, housing.maxY)
    }

    func testConversationWithoutPhysicalHousingUsesClampedAnchorAndGap() {
        let placement = PaceConversationPanelPlacement.resolve(
            notchGeometry: nil,
            anchorFrame: CGRect(x: 1_400, y: 876, width: 24, height: 24),
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            contentSize: CGSize(width: 520, height: 540))
        XCTAssertEqual(placement, .anchored(CGRect(x: 912, y: 326, width: 520, height: 540)))
        XCTAssertEqual(placement.collapsedFrame.maxY, placement.frame.maxY)
        XCTAssertEqual(placement.collapsedFrame.height, 24)
    }

    func testNotchAndConversationStayAttachedToHardwareAcrossDisplayOrigins() throws {
        let menuHeights: [CGFloat] = [24, 32, 38]
        for screenOrigin in [CGPoint.zero, CGPoint(x: -1_728, y: 180), CGPoint(x: 240, y: -1_117)] {
            for menuHeight in menuHeights {
                let screenFrame = CGRect(origin: screenOrigin, size: CGSize(width: 1_728, height: 1_117))
                let menuRow = CGRect(
                    x: screenFrame.minX, y: screenFrame.maxY - menuHeight,
                    width: screenFrame.width, height: menuHeight)
                let leftArea = CGRect(x: menuRow.minX, y: menuRow.minY, width: 751.5, height: menuHeight)
                let rightArea = CGRect(x: menuRow.minX + 976.5, y: menuRow.minY, width: 751.5, height: menuHeight)
                for displayMode in [PaceLivingNotchDisplayMode.resting, .hover, .active] {
                    let geometry = try XCTUnwrap(PaceLivingNotchGeometry.resolve(
                        screenFrame: screenFrame, safeAreaTopInset: menuHeight,
                        auxiliaryTopLeftArea: leftArea, auxiliaryTopRightArea: rightArea,
                        displayMode: displayMode))
                    XCTAssertEqual(geometry.presentationFrame.maxY, screenFrame.maxY)
                    XCTAssertTrue(geometry.presentationFrame.contains(geometry.physicalHousingFrame))

                    let placement = PaceConversationPanelPlacement.resolve(
                        notchGeometry: geometry, anchorFrame: geometry.presentationFrame,
                        screenFrame: screenFrame, contentSize: CGSize(width: 520, height: 540))
                    XCTAssertEqual(placement.frame.maxY, screenFrame.maxY)
                    XCTAssertEqual(placement.collapsedFrame.maxY, screenFrame.maxY)
                    XCTAssertTrue(placement.frame.contains(geometry.physicalHousingFrame))
                    XCTAssertTrue(placement.collapsedFrame.contains(geometry.physicalHousingFrame))
                }
            }
        }
    }

    @MainActor
    func testSeamNativeRenderExamplesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["PACE_RENDER_SEAM_PREVIEWS"] == "1" else {
            throw XCTSkip("Native render export is an opt-in local visual check.")
        }
        let output = URL(fileURLWithPath: "/tmp/pace-seam-native-20261030", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let examples: [(String, PaceLivingNotchDisplayMode, PaceSignalState, String, Bool, CGFloat)] = [
            ("idle", .resting, .ready, "Ready", false, 185),
            ("completed-rest", .resting, .completed, "Done", false, 185),
            ("hover", .hover, .ready, "Ready", false, 185),
            ("listening", .active, .listening, "Listening…", false, 185),
            ("codex-image", .active, .acting, "Drawing a turbofan…", true, 185),
            ("wide-housing-privacy", .active, .understanding, "Thinking…", true, 225),
            ("claude-capture-privacy", .active, .acting, "Working…", true, 185),
            ("companion-paused", .active, .listening, "Listening…", false, 185),
            ("companion-paused-hover", .hover, .ready, "Ready", false, 185),
            ("companion-finishing", .active, .completed, "Finishing…", true, 185),
            ("wide-housing-hover", .hover, .ready, "Ready", false, 300),
        ]
        for (name, mode, signalState, label, isOffDeviceTurn, housingWidth) in examples {
            let width = max(
                mode.preferredWidth ?? housingWidth, housingWidth + 88)
            let height = 32 + mode.additionalHeight
            let surface = PaceSeamNotchSurface(
                displayMode: mode, physicalHousingWidth: housingWidth, physicalHousingHeight: 32,
                signalState: signalState, activityLabel: label, isOffDeviceTurn: isOffDeviceTurn,
                plannerLabel: name == "claude-capture-privacy" ? "Claude Code" : "Codex",
                isCameraActive: name.contains("privacy"), isScreenActive: name.contains("privacy"),
                persistentStatus: name == "companion-finishing"
                    ? "Observing"
                    : name.hasPrefix("companion-paused") ? "Paused" : nil,
                companionStatusColor: name.hasPrefix("companion-paused") ? Color.yellow : nil
            )
            if name == "companion-finishing" {
                XCTAssertEqual(surface.displayedActivityLabel, "Finishing…")
            }
            let renderer = ImageRenderer(content: surface.frame(width: width, height: height))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(width * 2))
            XCTAssertEqual(image.height, Int(height * 2))
            let bitmap = NSBitmapImageRep(cgImage: image)
            for pixelX in stride(from: 24, through: bitmap.pixelsWide - 24, by: 8) {
                XCTAssertGreaterThan(
                    bitmap.colorAt(x: pixelX, y: 32)?.alphaComponent ?? 0, 0.9,
                    "The icon wings must remain connected to the camera housing in \(name).")
            }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    func testLivingNotchGeometryRejectsDisplaysWithoutReliableHousingBounds() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let leftArea = CGRect(x: 0, y: 876, width: 620, height: 24)
        let rightArea = CGRect(x: 820, y: 876, width: 620, height: 24)

        XCTAssertNil(
            PaceLivingNotchGeometry.resolve(
                screenFrame: screenFrame,
                safeAreaTopInset: 0,
                auxiliaryTopLeftArea: leftArea,
                auxiliaryTopRightArea: rightArea,
                displayMode: .resting
            ))
        XCTAssertNil(
            PaceLivingNotchGeometry.resolve(
                screenFrame: screenFrame,
                safeAreaTopInset: 24,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil,
                displayMode: .resting
            ))
        XCTAssertNil(
            PaceLivingNotchGeometry.resolve(
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

    func testAmbientHomeUsesMenuBarFallbackWithoutPhysicalNotchGeometry() {
        XCTAssertEqual(
            PaceAmbientHomePresentation.resolve(hasReliablePhysicalNotchGeometry: true),
            .livingNotch
        )
        XCTAssertEqual(
            PaceAmbientHomePresentation.resolve(hasReliablePhysicalNotchGeometry: false),
            .menuBarItem
        )
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
