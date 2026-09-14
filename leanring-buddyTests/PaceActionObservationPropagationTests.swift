//
//  PaceActionObservationPropagationTests.swift
//  leanring-buddyTests
//
//  Regression coverage for the fire-and-forget observation-propagation
//  defect: `dispatchSingleAction` used to discard the result of `.click`,
//  `.doubleClick`, `.type`, `.pressKey`, `.scroll`, `.adjustVolume`, and
//  `.adjustBrightness`, falling through to a blanket `return nil`. Because
//  `CompanionManager+AgentLoop.swift` only reports completion / raises the
//  undo banner / records outcome-feedback telemetry when its
//  `toolObservations` array is non-empty, a plan consisting solely of one
//  of these actions could execute (or fail) while producing zero visible
//  feedback — exactly the real dogfood transcript that surfaced this bug
//  ("1 tool planned" / "Step 1: [input injection] Click at 182,504", with
//  no completion evidence ever shown).
//
//  These tests deliberately avoid touching live AX/CGEvent state:
//  - The click failure path uses an EMPTY `screenCaptures` array, which
//    makes `convertScreenshotPixelToDisplayGlobalPoint` return nil
//    deterministically, before `clickAtScreenshotLocation` ever reaches
//    AX or CGEvent code.
//  - The click dry-run path uses `actionsAreEnabledOverride: false`, which
//    short-circuits `clickAtScreenshotLocation` immediately after
//    (successful) coordinate resolution, before any AX/CGEvent call.
//  - `observationForCoordinateClick` — the pure text-construction function
//    that is the actual fix — is tested directly for all three branches
//    (failure / dry-run / live-success), since its output for the
//    live-success branch is a deterministic function of its inputs and
//    does not depend on what a real click would do on screen.
//  - `pressKey`'s failure branch (an unrecognized key name) returns before
//    any CGEvent is posted, so it is safe to exercise live
//    (`actionsAreEnabledOverride: true`) without touching real keyboard
//    input.
//  - Every other fire-and-forget action is exercised only in dry-run,
//    where its own `guard actionsAreEnabled else { ... }` is the very
//    first statement and no real input is ever synthesized.
//
//  None of this re-tests the AX-first / CGEvent-fallback click mechanism
//  itself (PaceAXTargeter, PaceActionExecutor+Mouse.swift) — that was
//  already audited as compliant and is intentionally untouched by this
//  fix. These tests only prove that whatever that mechanism reports is
//  now actually returned, instead of being silently discarded.
//

import CoreGraphics
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceActionObservationPropagationTests {

    // MARK: - Fixtures

    /// A `CompanionScreenCapture` whose geometry makes coordinate
    /// resolution succeed deterministically for `screenNumber: 1`
    /// (`ScreenshotPixelLocation`'s 1-based index).
    private static func resolvableScreenCapture() -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: Data(),
            label: "test-screen",
            isCursorScreen: true,
            displayWidthInPoints: 1000,
            displayHeightInPoints: 1000,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            screenshotWidthInPixels: 1000,
            screenshotHeightInPixels: 1000
        )
    }

    // MARK: - A. Click dispatch

    @Test func clickDispatchWithUnresolvableCoordinatesReturnsNonNilFailureObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let location = ScreenshotPixelLocation(
            xInScreenshotPixels: 182, yInScreenshotPixels: 504, screenNumber: nil
        )

        let observation = await executor.dispatchSingleAction(
            .click(location),
            screenCaptures: [] // empty -> coordinate resolution genuinely fails
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "click")
        #expect(observation?.summary.lowercased().contains("click failed") == true)
        // Must not be mistaken for success.
        #expect(observation?.summary.contains("Clicked at") == false)
    }

    @Test func doubleClickDispatchWithUnresolvableCoordinatesReturnsNonNilFailureObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let location = ScreenshotPixelLocation(
            xInScreenshotPixels: 50, yInScreenshotPixels: 60, screenNumber: nil
        )

        let observation = await executor.dispatchSingleAction(
            .doubleClick(location),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "double_click")
        #expect(observation?.summary.lowercased().contains("click failed") == true)
    }

    @Test func clickDispatchInDryRunReturnsNonNilWouldClickObservation() async {
        // actionsAreEnabledOverride: false short-circuits before any
        // AX/CGEvent call — this exercises the real success branch's text
        // construction with zero live side effects.
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let location = ScreenshotPixelLocation(
            xInScreenshotPixels: 182, yInScreenshotPixels: 504, screenNumber: 1
        )

        let observation = await executor.dispatchSingleAction(
            .click(location),
            screenCaptures: [Self.resolvableScreenCapture()]
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "click")
        #expect(observation?.summary == "Would click at 182, 504, screen 1.")
        #expect(observation?.summary.lowercased().contains("click failed") == false)
    }

    /// Directly exercises the pure observation-construction function —
    /// the actual fix — for all three branches, including live-success,
    /// without ever touching a real click.
    @Test func observationForCoordinateClickCoversAllThreeBranches() {
        let location = ScreenshotPixelLocation(
            xInScreenshotPixels: 10, yInScreenshotPixels: 20, screenNumber: nil
        )

        let failureExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let failureObservation = failureExecutor.observationForCoordinateClick(
            at: location, isDoubleClick: false, coordinatesResolved: false
        )
        #expect(failureObservation.summary.lowercased().contains("click failed"))

        let dryRunExecutor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let dryRunObservation = dryRunExecutor.observationForCoordinateClick(
            at: location, isDoubleClick: false, coordinatesResolved: true
        )
        #expect(dryRunObservation.summary == "Would click at 10, 20.")

        let liveSuccessExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let liveSuccessObservation = liveSuccessExecutor.observationForCoordinateClick(
            at: location, isDoubleClick: false, coordinatesResolved: true
        )
        #expect(liveSuccessObservation.summary == "Clicked at 10, 20.")

        let liveSuccessDoubleClickObservation = liveSuccessExecutor.observationForCoordinateClick(
            at: location, isDoubleClick: true, coordinatesResolved: true
        )
        #expect(liveSuccessDoubleClickObservation.summary == "Double-clicked at 10, 20.")
        #expect(liveSuccessDoubleClickObservation.toolName == "double_click")
    }

    // MARK: - B. Execution-plan propagation

    @Test func clickOnlyExecutionPlanProducesNonEmptyToolObservations() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)
        let location = ScreenshotPixelLocation(
            xInScreenshotPixels: 182, yInScreenshotPixels: 504, screenNumber: nil
        )
        let plan = PaceActionExecutionPlan.serial(actions: [.click(location)])

        // This is exactly the shape of the real dogfood plan that
        // surfaced the bug: a single click action, no other steps.
        let observations = await executor.executeActionPlan(
            plan,
            screenCaptures: [], // deterministic failure path
            approvalAlreadyObtained: true
        )

        #expect(!observations.isEmpty)
        #expect(observations.count == 1)
        #expect(observations.first?.summary.lowercased().contains("click failed") == true)
    }

    // MARK: - C. Fire-and-forget family (dry-run: zero live side effects)

    @Test func typeDispatchInDryRunReturnsNonNilObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)

        let observation = await executor.dispatchSingleAction(
            .type("hello"),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "type")
        #expect(observation?.summary == "Would type 5 characters.")
    }

    @Test func pressKeyDispatchInDryRunReturnsNonNilObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)

        let observation = await executor.dispatchSingleAction(
            .pressKey(name: "a", modifiers: []),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "key_press")
        #expect(observation?.summary == "Would press a.")
    }

    /// The unrecognized-key-name branch returns `false` before any
    /// CGEvent is posted, so this is safe to exercise live.
    @Test func pressKeyDispatchWithUnrecognizedKeyReturnsNonNilFailureObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true)

        let observation = await executor.dispatchSingleAction(
            .pressKey(name: "definitely-not-a-real-key-name", modifiers: []),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "key_press")
        #expect(observation?.summary.contains("Key press failed") == true)
        // Must not be mistaken for success.
        #expect(observation?.summary.contains("Pressed") == false)
    }

    @Test func scrollDispatchInDryRunReturnsNonNilObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)

        let observation = await executor.dispatchSingleAction(
            .scroll(.up, amountInLines: 3),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "scroll")
        #expect(observation?.summary == "Would scroll up by 3 lines.")
    }

    @Test func adjustVolumeDispatchInDryRunReturnsNonNilObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let adjustment = PaceSystemAdjustment(direction: .up, stepCount: 2)

        let observation = await executor.dispatchSingleAction(
            .adjustVolume(adjustment),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "volume")
        #expect(observation?.summary == "Would adjust volume up by 2 steps.")
    }

    @Test func adjustBrightnessDispatchInDryRunReturnsNonNilObservation() async {
        let executor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let adjustment = PaceSystemAdjustment(direction: .down, stepCount: 1)

        let observation = await executor.dispatchSingleAction(
            .adjustBrightness(adjustment),
            screenCaptures: []
        )

        #expect(observation != nil)
        #expect(observation?.toolName == "brightness")
        #expect(observation?.summary == "Would adjust brightness down by 1 step.")
    }
}
