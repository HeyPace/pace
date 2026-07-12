//
//  PacePlannerBrainPickerTests.swift
//  leanring-buddyTests
//
//  Tests the shared planner-brain selection helper
//  (`CompanionManager.selectPlannerTierWithConsent`) that both the
//  Planner tab and the RAM-aware budget picker in the Models tab call.
//  We exercise only the tiers that DON'T raise an NSAlert (`.local`,
//  `.appleFoundationModels`) so the test stays headless — the consent-
//  gated tiers show a modal dialog and their gate is covered separately
//  in PaceCLIDirectPlannerTierTests / PaceCloudBridgeConsentTests.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite(.serialized)
struct PacePlannerBrainPickerTests {

    private static let plannerTierKey = "pace.planner.tier.selectedTier"

    private func withRestoredSelectedTier<R>(_ body: () throws -> R) rethrows -> R {
        let saved = UserDefaults.standard.object(forKey: Self.plannerTierKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: Self.plannerTierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.plannerTierKey)
            }
        }
        return try body()
    }

    @Test
    func selectingLocalBrainAppliesAndPersistsTheTier() {
        withRestoredSelectedTier {
            // Build a bare CompanionManager (no start() — no CGEvent taps /
            // screen capture). Only the tier picker API is exercised.
            let companionManager = CompanionManager()

            let applied = companionManager.selectPlannerTierWithConsent(.local)
            #expect(applied)
            #expect(companionManager.activePlannerTier == .local)
            #expect(PacePlannerTierStore.loadConfiguration().tier == .local)
        }
    }

    @Test
    func selectingAppleFoundationModelsBrainAppliesTheTier() {
        withRestoredSelectedTier {
            let companionManager = CompanionManager()

            // Apple FM is an on-device tier with no consent dialog, so the
            // picker applies it directly — the same path the RAM budget
            // section's brain picker takes when the user frees planner RAM.
            let applied = companionManager.selectPlannerTierWithConsent(.appleFoundationModels)
            #expect(applied)
            #expect(companionManager.activePlannerTier == .appleFoundationModels)
            #expect(PacePlannerTierStore.loadConfiguration().tier == .appleFoundationModels)
        }
    }
}
