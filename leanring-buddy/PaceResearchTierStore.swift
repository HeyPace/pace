//
//  PaceResearchTierStore.swift
//  leanring-buddy
//
//  Pure state module for the "research escalation" tier picker. Mirrors
//  PacePlannerTierStore but with its own UserDefaults prefix
//  (`pace.research.tier.`) and a different default — `.off`, so existing
//  users see zero behavior change until they opt in via Settings →
//  Research. Persona/system-prompt/tool-dialect remain identical across
//  tiers; only the model + step budget differs.
//
//  When the user says "research X" / "look into Y" / "compare A vs B",
//  `PaceIntentClassifier` flags the turn `.research`. CompanionManager
//  reads THIS store, swaps in a per-turn planner client (direct-spawn to
//  the local Codex CLI by default, or Direct API to Anthropic Opus), and
//  runs the agent loop with `maximumAgentSteps` and `perTurnTokenBudgetCap`
//  from the configuration here. When `.off`, the turn falls back to the
//  existing `.phoneLargeModel` route — no surprise model switch.
//
//  Keychain: API keys live in `PaceKeychainStore` (same Direct-API
//  storage the main planner uses). Reusing the same Keychain entry
//  means a user with Opus already configured for their main tier never
//  needs to paste their key twice. This module touches NO Keychain
//  state directly.
//

import Foundation

// MARK: - PaceResearchTier

/// The three user-selectable backend tiers for research-escalation
/// turns. **Default is `.cliBridge`, direct-spawning the Codex CLI** —
/// research is supposed to "just call the local CLI" (Codex by default,
/// Claude Code selectable) so the user gets a real answer without manual
/// configuration. Users without a working CLI can flip to `.off` (falls
/// back to `.phoneLargeModel`) or `.directAPI` in Settings → Research.
nonisolated enum PaceResearchTier: String, Equatable, Codable, CaseIterable {
    /// Direct-spawn the user's authenticated CLI for a one-turn research
    /// escalation, bound to the configured upstream + model. **Default,
    /// with Codex as the default upstream.** Free when the user already
    /// has Codex / Claude Code installed and authenticated; the deprecated
    /// `.gemini` upstream still routes through the local-ai Node bridge on
    /// localhost:3456.
    case cliBridge
    /// Spawn a one-turn DirectAPIPlannerClient against the user's
    /// stored Direct-API key. Real money per turn, capped by
    /// `perTurnTokenBudgetCap`.
    case directAPI
    /// No research escalation. `.research` intents fall back to the
    /// normal `.phoneLargeModel` route (Cloud Bridge if configured,
    /// "I can't" message otherwise). Pick this when the user prefers
    /// the local Qwen for research too.
    case off
}

// MARK: - PaceResearchTierConfiguration

/// Immutable snapshot of the research tier picker preferences at one
/// point in time. CompanionManager loads this at the top of every
/// `.research`-classified turn, swaps in the matching planner, then
/// continues into the normal agent loop.
nonisolated struct PaceResearchTierConfiguration: Equatable {
    let tier: PaceResearchTier
    let directAPIProvider: PaceDirectAPIProvider
    let directAPIModelIdentifier: String
    /// Used only when `directAPIProvider == .custom`. Empty otherwise.
    let directAPICustomEndpointURLString: String
    let cliBridgeUpstream: PaceCloudBridgeUpstream
    let cliBridgeModel: String
    /// Per-turn ceiling on the plan-act-observe loop. Default 16 (vs.
    /// 8 for normal turns) so a research turn can fetch + read +
    /// synthesize across several MCP tool calls without bailing early.
    /// Clamped to [4, 32] on read.
    let maximumAgentSteps: Int
    /// Hard backstop against a runaway research loop. Coarse
    /// chars→tokens estimate (chars / 4); once cumulative output
    /// tokens cross this, the loop bails with a "hit token budget"
    /// HUD message. Default 200 000 output tokens. Clamped
    /// [50 000, 500 000] on read.
    let perTurnTokenBudgetCap: Int
}

// MARK: - UserDefaults keys

private enum ResearchTierUserDefaultsKey: String {
    case selectedTier                       = "pace.research.tier.selectedTier"
    case directAPIProvider                  = "pace.research.tier.directAPI.provider"
    case directAPIModelIdentifier           = "pace.research.tier.directAPI.model"
    case directAPICustomEndpointURLString   = "pace.research.tier.directAPI.customEndpointURL"
    case cliBridgeUpstream                  = "pace.research.tier.cliBridge.upstream"
    case cliBridgeModel                     = "pace.research.tier.cliBridge.model"
    case maximumAgentSteps                  = "pace.research.tier.maximumAgentSteps"
    case perTurnTokenBudgetCap              = "pace.research.tier.perTurnTokenBudgetCap"
}

// MARK: - PaceResearchTierStore

enum PaceResearchTierStore {

    /// Sensible defaults the resolver fills in when no UserDefaults
    /// state exists. These are the values the PRD calls out — Anthropic
    /// Opus for Direct API, Claude CLI bridge upstream, 16 steps, 200k
    /// tokens.
    static let defaultDirectAPIProvider: PaceDirectAPIProvider = .anthropic
    static let defaultDirectAPIModelIdentifier = "claude-opus-4-7"
    static let defaultCLIBridgeUpstream: PaceCloudBridgeUpstream = .codex
    /// Empty by design. The research lane direct-spawns
    /// `PaceLocalCLIPlannerClient(upstream:modelIdentifier:)`, which only
    /// forwards `--model` when the identifier is non-empty; an empty
    /// identifier lets Codex use its own already-authenticated model
    /// (correct — a hard-coded Claude model id would be wrong for Codex).
    static let defaultCLIBridgeModel = ""
    static let defaultMaximumAgentSteps = 16
    static let defaultPerTurnTokenBudgetCap = 200_000

    /// Clamping ranges so a corrupted UserDefaults value can never push
    /// the loop into "thousand-step runaway" or "one-step zero-budget"
    /// territory.
    static let maximumAgentStepsRange = 4...32
    static let perTurnTokenBudgetCapRange = 50_000...500_000

    // MARK: Load

    /// First-launch detection: returns true iff none of the research-
    /// tier UserDefaults keys are set. New installs get `.cliBridge` as
    /// the default ("just call the local CLI" goal); users who have
    /// ever opened Settings → Research and explicitly picked a tier
    /// see that pick honored verbatim.
    static func hasAnyResearchTierUserDefaultsState() -> Bool {
        let researchTierUserDefaultsKeys: [ResearchTierUserDefaultsKey] = [
            .selectedTier,
            .directAPIProvider,
            .directAPIModelIdentifier,
            .directAPICustomEndpointURLString,
            .cliBridgeUpstream,
            .cliBridgeModel,
            .maximumAgentSteps,
            .perTurnTokenBudgetCap
        ]
        for key in researchTierUserDefaultsKeys {
            if UserDefaults.standard.object(forKey: key.rawValue) != nil {
                return true
            }
        }
        return false
    }

    static func loadConfiguration() -> PaceResearchTierConfiguration {
        // Brand-new installs get .cliBridge so research "just calls
        // the local CLI" out of the box; existing users with any
        // prior research-tier UserDefaults state see their pick
        // honored unchanged.
        let firstLaunchFallbackTier: PaceResearchTier =
            hasAnyResearchTierUserDefaultsState() ? .off : .cliBridge

        let rawSelectedTier = UserDefaults.standard.string(
            forKey: ResearchTierUserDefaultsKey.selectedTier.rawValue
        ) ?? firstLaunchFallbackTier.rawValue
        let resolvedTier = PaceResearchTier(rawValue: rawSelectedTier) ?? firstLaunchFallbackTier

        let rawDirectAPIProvider = UserDefaults.standard.string(
            forKey: ResearchTierUserDefaultsKey.directAPIProvider.rawValue
        ) ?? defaultDirectAPIProvider.rawValue
        let resolvedDirectAPIProvider = PaceDirectAPIProvider(rawValue: rawDirectAPIProvider) ?? defaultDirectAPIProvider

        let resolvedDirectAPIModelIdentifier = UserDefaults.standard.string(
            forKey: ResearchTierUserDefaultsKey.directAPIModelIdentifier.rawValue
        ) ?? defaultDirectAPIModelIdentifier

        let resolvedDirectAPICustomEndpointURLString = UserDefaults.standard.string(
            forKey: ResearchTierUserDefaultsKey.directAPICustomEndpointURLString.rawValue
        ) ?? ""

        let rawCLIBridgeUpstream = UserDefaults.standard.string(
            forKey: ResearchTierUserDefaultsKey.cliBridgeUpstream.rawValue
        ) ?? defaultCLIBridgeUpstream.rawValue
        let resolvedCLIBridgeUpstream = PaceCloudBridgeUpstream(rawValue: rawCLIBridgeUpstream) ?? defaultCLIBridgeUpstream

        let resolvedCLIBridgeModel = UserDefaults.standard.string(
            forKey: ResearchTierUserDefaultsKey.cliBridgeModel.rawValue
        ) ?? defaultCLIBridgeModel

        let rawMaximumAgentSteps = UserDefaults.standard.object(
            forKey: ResearchTierUserDefaultsKey.maximumAgentSteps.rawValue
        ) as? Int ?? defaultMaximumAgentSteps
        let resolvedMaximumAgentSteps = clamp(rawMaximumAgentSteps, in: maximumAgentStepsRange)

        let rawPerTurnTokenBudgetCap = UserDefaults.standard.object(
            forKey: ResearchTierUserDefaultsKey.perTurnTokenBudgetCap.rawValue
        ) as? Int ?? defaultPerTurnTokenBudgetCap
        let resolvedPerTurnTokenBudgetCap = clamp(rawPerTurnTokenBudgetCap, in: perTurnTokenBudgetCapRange)

        return PaceResearchTierConfiguration(
            tier: resolvedTier,
            directAPIProvider: resolvedDirectAPIProvider,
            directAPIModelIdentifier: resolvedDirectAPIModelIdentifier,
            directAPICustomEndpointURLString: resolvedDirectAPICustomEndpointURLString,
            cliBridgeUpstream: resolvedCLIBridgeUpstream,
            cliBridgeModel: resolvedCLIBridgeModel,
            maximumAgentSteps: resolvedMaximumAgentSteps,
            perTurnTokenBudgetCap: resolvedPerTurnTokenBudgetCap
        )
    }

    // MARK: Save

    static func saveTier(_ tier: PaceResearchTier) {
        UserDefaults.standard.set(
            tier.rawValue,
            forKey: ResearchTierUserDefaultsKey.selectedTier.rawValue
        )
    }

    static func saveDirectAPIProvider(_ provider: PaceDirectAPIProvider) {
        UserDefaults.standard.set(
            provider.rawValue,
            forKey: ResearchTierUserDefaultsKey.directAPIProvider.rawValue
        )
    }

    static func saveDirectAPIModelIdentifier(_ modelIdentifier: String) {
        UserDefaults.standard.set(
            modelIdentifier,
            forKey: ResearchTierUserDefaultsKey.directAPIModelIdentifier.rawValue
        )
    }

    static func saveDirectAPICustomEndpointURL(_ customEndpointURLString: String) {
        UserDefaults.standard.set(
            customEndpointURLString,
            forKey: ResearchTierUserDefaultsKey.directAPICustomEndpointURLString.rawValue
        )
    }

    static func saveCLIBridgeUpstream(_ upstream: PaceCloudBridgeUpstream) {
        UserDefaults.standard.set(
            upstream.rawValue,
            forKey: ResearchTierUserDefaultsKey.cliBridgeUpstream.rawValue
        )
    }

    static func saveCLIBridgeModel(_ modelIdentifier: String) {
        UserDefaults.standard.set(
            modelIdentifier,
            forKey: ResearchTierUserDefaultsKey.cliBridgeModel.rawValue
        )
    }

    static func saveMaximumAgentSteps(_ maximumAgentSteps: Int) {
        UserDefaults.standard.set(
            clamp(maximumAgentSteps, in: maximumAgentStepsRange),
            forKey: ResearchTierUserDefaultsKey.maximumAgentSteps.rawValue
        )
    }

    static func savePerTurnTokenBudgetCap(_ perTurnTokenBudgetCap: Int) {
        UserDefaults.standard.set(
            clamp(perTurnTokenBudgetCap, in: perTurnTokenBudgetCapRange),
            forKey: ResearchTierUserDefaultsKey.perTurnTokenBudgetCap.rawValue
        )
    }

    // MARK: Endpoint resolution

    /// Returns the endpoint URL string the Direct-API client should use
    /// for research turns. Mirrors `PacePlannerTierStore`'s resolver so
    /// the two tiers share their per-provider defaults.
    static func resolvedDirectAPIEndpointURLString(
        for configuration: PaceResearchTierConfiguration
    ) -> String {
        switch configuration.directAPIProvider {
        case .anthropic, .openai, .openrouter:
            return configuration.directAPIProvider.defaultEndpointURLString
        case .custom:
            return configuration.directAPICustomEndpointURLString
        }
    }

    // MARK: Helpers

    private static func clamp(_ value: Int, in range: ClosedRange<Int>) -> Int {
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
