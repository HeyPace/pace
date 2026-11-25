//
//  PacePlannerBrainPickerTests.swift
//  leanring-buddyTests
//
//  Tests the shared planner-brain selection helper
//  (`CompanionManager.selectPlannerTierWithConsent`) that both the
//  Planner tab and the RAM-aware budget picker in the Models tab call.
//  The consent tests dismiss the real gate through a headless alert presenter.
//

import AppKit
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

    @Test(arguments: [PacePlannerTier.cliBridge, .cliDirect])
    func cancellingConsentPreservesPriorPlanner(_ requestedTier: PacePlannerTier) {
        withRestoredSelectedTier {
            let consentKey =
                requestedTier == .cliBridge
                ? "pace.cloudBridge.hasAcceptedConsent" : "pace.cloudBridge.hasAcceptedDirectSpawnConsent"
            let defaults = UserDefaults.standard
            let savedConsent = defaults.object(forKey: consentKey)
            defer {
                if let savedConsent {
                    defaults.set(savedConsent, forKey: consentKey)
                } else {
                    defaults.removeObject(forKey: consentKey)
                }
            }
            defaults.set(false, forKey: consentKey)
            PacePlannerTierStore.saveTier(.appleFoundationModels)
            let manager = CompanionManager()
            let previousClient = manager.plannerClient
            let previousMode = manager.cloudBridgeMode
            var presentations = 0
            let applied = manager.selectPlannerTierWithConsent(requestedTier) { alert in
                presentations += 1
                #expect(alert.buttons.last?.title == "Cancel")
                return .alertSecondButtonReturn
            }

            #expect(presentations == 1)
            #expect(!applied)
            #expect(!defaults.bool(forKey: consentKey))
            #expect(manager.activePlannerTier == .appleFoundationModels)
            #expect(PacePlannerTierStore.loadConfiguration().tier == .appleFoundationModels)
            #expect(manager.plannerClient === previousClient)
            #expect(manager.cloudBridgeMode == previousMode)
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
