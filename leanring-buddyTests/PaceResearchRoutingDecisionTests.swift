//
//  PaceResearchRoutingDecisionTests.swift
//  leanring-buddyTests
//
//  CompanionManager's research-routing branch can't be tested in
//  isolation (the agent loop is 800+ lines coupled to AVAudio,
//  ScreenCaptureKit, AX, etc.). What we CAN pin without driving
//  voice is the pure decision the branch makes: given an intent
//  prediction and a tier configuration, what's the resulting route?
//
//  This file mirrors the exact logic in
//  `CompanionManager.sendTranscriptToPlannerWithScreenshotAsync`
//  (lines ~5117–5210) as a pure helper so any future refactor that
//  changes that decision must update these tests too.
//

import Foundation
import Testing
@testable import Pace

/// Pure mirror of the decision CompanionManager makes when a
/// `.research` intent arrives. The real method side-effects (Settings
/// HUD, TTS announcement, `isOffDeviceTurnInFlight` flag) are NOT
/// modeled — only the routing decision.
@MainActor
enum PaceResearchRoutingDecision: Equatable {
    /// Tier is .off — research falls back to the .phoneLargeModel
    /// route via PaceCloudBridgeConsent.
    case fallBackToPhoneLargeModel
    /// Spawn a one-turn CloudBridgePlannerClient with this upstream +
    /// model. Free if the user has Claude Code / Codex / Gemini.
    case cliBridge(upstream: PaceCloudBridgeUpstream, modelIdentifier: String)
    /// Spawn a one-turn DirectAPIPlannerClient with this provider +
    /// model. Real money per turn.
    case directAPI(provider: PaceDirectAPIProvider, modelIdentifier: String)

    static func resolve(
        researchConfiguration: PaceResearchTierConfiguration
    ) -> PaceResearchRoutingDecision {
        switch researchConfiguration.tier {
        case .off:
            return .fallBackToPhoneLargeModel
        case .cliBridge:
            return .cliBridge(
                upstream: researchConfiguration.cliBridgeUpstream,
                modelIdentifier: researchConfiguration.cliBridgeModel
            )
        case .directAPI:
            // Direct API requires a resolvable endpoint URL.
            // CompanionManager's branch falls back to
            // .phoneLargeModel when the URL is empty/invalid (e.g.
            // .custom with no endpoint set yet). Mirror that here.
            let resolvedEndpointURLString = PaceResearchTierStore
                .resolvedDirectAPIEndpointURLString(for: researchConfiguration)
            if resolvedEndpointURLString.isEmpty || URL(string: resolvedEndpointURLString) == nil {
                return .fallBackToPhoneLargeModel
            }
            return .directAPI(
                provider: researchConfiguration.directAPIProvider,
                modelIdentifier: researchConfiguration.directAPIModelIdentifier
            )
        }
    }
}

@MainActor
struct PaceResearchRoutingDecisionTests {

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

    @Test func freshInstallRoutesResearchToCLIBridgeCodex() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        // Fresh installs now route research to the Codex CLI with an empty
        // model identifier (let Codex use its own authenticated model).
        let configuration = PaceResearchTierStore.loadConfiguration()
        let decision = PaceResearchRoutingDecision.resolve(researchConfiguration: configuration)
        #expect(decision == .cliBridge(upstream: .codex, modelIdentifier: ""))
    }

    @Test func explicitOffTierFallsBackToPhoneLargeModel() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.off)
        let configuration = PaceResearchTierStore.loadConfiguration()
        let decision = PaceResearchRoutingDecision.resolve(researchConfiguration: configuration)
        #expect(decision == .fallBackToPhoneLargeModel)
    }

    @Test func directAPITierWithBuiltInProviderRoutesToDirectAPI() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.directAPI)
        PaceResearchTierStore.saveDirectAPIProvider(.anthropic)
        PaceResearchTierStore.saveDirectAPIModelIdentifier("claude-opus-4-7")
        let configuration = PaceResearchTierStore.loadConfiguration()
        let decision = PaceResearchRoutingDecision.resolve(researchConfiguration: configuration)
        #expect(decision == .directAPI(provider: .anthropic, modelIdentifier: "claude-opus-4-7"))
    }

    @Test func directAPICustomWithEmptyURLFallsBackToPhoneLargeModel() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.directAPI)
        PaceResearchTierStore.saveDirectAPIProvider(.custom)
        // Custom endpoint not set → resolved URL is empty → must
        // fall back rather than constructing a broken planner.
        let configuration = PaceResearchTierStore.loadConfiguration()
        let decision = PaceResearchRoutingDecision.resolve(researchConfiguration: configuration)
        #expect(decision == .fallBackToPhoneLargeModel)
    }

    @Test func directAPICustomWithValidURLRoutesToDirectAPI() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.directAPI)
        PaceResearchTierStore.saveDirectAPIProvider(.custom)
        PaceResearchTierStore.saveDirectAPICustomEndpointURL("https://my-proxy.example.com/v1/chat/completions")
        PaceResearchTierStore.saveDirectAPIModelIdentifier("custom-opus")
        let configuration = PaceResearchTierStore.loadConfiguration()
        let decision = PaceResearchRoutingDecision.resolve(researchConfiguration: configuration)
        #expect(decision == .directAPI(provider: .custom, modelIdentifier: "custom-opus"))
    }

    @Test func cliBridgeRespectsExplicitCodexUpstream() async throws {
        Self.cleanUserDefaults()
        defer { Self.cleanUserDefaults() }

        PaceResearchTierStore.saveTier(.cliBridge)
        PaceResearchTierStore.saveCLIBridgeUpstream(.codex)
        PaceResearchTierStore.saveCLIBridgeModel("gpt-5-turbo")
        let configuration = PaceResearchTierStore.loadConfiguration()
        let decision = PaceResearchRoutingDecision.resolve(researchConfiguration: configuration)
        #expect(decision == .cliBridge(upstream: .codex, modelIdentifier: "gpt-5-turbo"))
    }
}
