//
//  PaceResearchTierStoreTests.swift
//  leanring-buddyTests
//
//  Pure tests for `PaceResearchTierStore` — defaults, clamping, and
//  round-trip persistence. Each test cleans up its own UserDefaults
//  state so re-runs don't leak settings across tests.
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceResearchTierStoreTests {

    /// All UserDefaults keys the store writes to; clean these before
    /// and after every test so re-runs don't leak across.
    private static let userDefaultsKeysToClean: [String] = [
        "pace.research.tier.selectedTier",
        "pace.research.tier.directAPI.provider",
        "pace.research.tier.directAPI.model",
        "pace.research.tier.directAPI.customEndpointURL",
        "pace.research.tier.cliBridge.upstream",
        "pace.research.tier.cliBridge.model",
        "pace.research.tier.maximumAgentSteps",
        "pace.research.tier.perTurnTokenBudgetCap"
    ]

    private static func cleanUserDefaults() {
        for key in userDefaultsKeysToClean {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func firstLaunchDefaultsToCLIBridgeForResearch() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        let configuration = PaceResearchTierStore.loadConfiguration()
        // Default tier on a brand-new install is .cliBridge so
        // research "just calls the local CLI" out of the box.
        #expect(configuration.tier == .cliBridge)
        #expect(configuration.directAPIProvider == .anthropic)
        #expect(configuration.directAPIModelIdentifier == "claude-opus-4-7")
        #expect(configuration.cliBridgeUpstream == .claude)
        #expect(configuration.cliBridgeModel == "claude-opus-4-7")
        #expect(configuration.maximumAgentSteps == PaceResearchTierStore.defaultMaximumAgentSteps)
        #expect(configuration.perTurnTokenBudgetCap == PaceResearchTierStore.defaultPerTurnTokenBudgetCap)
    }

    @Test func existingUserExplicitOffStaysOff() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        // Existing user who explicitly disabled research must keep
        // their pick. The first-launch detector must not override
        // a user's deliberate choice.
        PaceResearchTierStore.saveTier(.off)
        let configurationAfterOff = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterOff.tier == .off)
    }

    @Test func hasAnyResearchTierUserDefaultsStateFlipsAfterAnySave() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        #expect(!PaceResearchTierStore.hasAnyResearchTierUserDefaultsState())
        // Saving ANY field (even one unrelated to tier) should mark
        // the user as "having state" so the first-launch default
        // doesn't reapply on next load.
        PaceResearchTierStore.saveMaximumAgentSteps(20)
        #expect(PaceResearchTierStore.hasAnyResearchTierUserDefaultsState())
    }

    @Test func saveTierPersistsAcrossLoads() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.directAPI)
        let configuration = PaceResearchTierStore.loadConfiguration()
        #expect(configuration.tier == .directAPI)
    }

    @Test func maximumAgentStepsAreClampedHighAndLow() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveMaximumAgentSteps(9999)
        let configurationAfterHighSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterHighSave.maximumAgentSteps == PaceResearchTierStore.maximumAgentStepsRange.upperBound)

        PaceResearchTierStore.saveMaximumAgentSteps(0)
        let configurationAfterLowSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterLowSave.maximumAgentSteps == PaceResearchTierStore.maximumAgentStepsRange.lowerBound)
    }

    @Test func perTurnTokenBudgetCapIsClampedHighAndLow() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.savePerTurnTokenBudgetCap(99_999_999)
        let configurationAfterHighSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterHighSave.perTurnTokenBudgetCap == PaceResearchTierStore.perTurnTokenBudgetCapRange.upperBound)

        PaceResearchTierStore.savePerTurnTokenBudgetCap(1)
        let configurationAfterLowSave = PaceResearchTierStore.loadConfiguration()
        #expect(configurationAfterLowSave.perTurnTokenBudgetCap == PaceResearchTierStore.perTurnTokenBudgetCapRange.lowerBound)
    }

    @Test func directAPIProviderAndModelRoundTrip() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveDirectAPIProvider(.openrouter)
        PaceResearchTierStore.saveDirectAPIModelIdentifier("anthropic/claude-opus-4")
        let configuration = PaceResearchTierStore.loadConfiguration()
        #expect(configuration.directAPIProvider == .openrouter)
        #expect(configuration.directAPIModelIdentifier == "anthropic/claude-opus-4")
    }

    @Test func cliBridgeUpstreamAndModelRoundTrip() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveCLIBridgeUpstream(.codex)
        PaceResearchTierStore.saveCLIBridgeModel("gpt-5-turbo")
        let configuration = PaceResearchTierStore.loadConfiguration()
        #expect(configuration.cliBridgeUpstream == .codex)
        #expect(configuration.cliBridgeModel == "gpt-5-turbo")
    }

    @Test func customEndpointURLResolverFallsBackToProviderDefault() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveDirectAPIProvider(.anthropic)
        let configuration = PaceResearchTierStore.loadConfiguration()
        let resolvedEndpoint = PaceResearchTierStore.resolvedDirectAPIEndpointURLString(for: configuration)
        #expect(resolvedEndpoint == PaceDirectAPIProvider.anthropic.defaultEndpointURLString)
    }

    @Test func customEndpointURLResolverReturnsPastedURLForCustom() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveDirectAPIProvider(.custom)
        PaceResearchTierStore.saveDirectAPICustomEndpointURL("https://my-proxy.example.com/v1/chat/completions")
        let configuration = PaceResearchTierStore.loadConfiguration()
        let resolvedEndpoint = PaceResearchTierStore.resolvedDirectAPIEndpointURLString(for: configuration)
        #expect(resolvedEndpoint == "https://my-proxy.example.com/v1/chat/completions")
    }
}
