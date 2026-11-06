//
//  CompanionSystemPrompt.swift
//  leanring-buddy
//
//  The system prompt Pace sends to the local planner on every turn.
//
//  Why this file
//  -------------
//  The prompt is a behavior contract — small wording changes here
//  change end-to-end behavior, so it lives in its own diff-able file.
//  And it's the single largest constant prefill cost the planner pays
//  every turn. Sub-second TTFT depends on keeping this lean.
//
//  Why it's now a builder
//  ----------------------
//  Previous version was a 60-line static `let` (~3,000 tokens) that
//  shipped agent-mode rules + plan-act-observe loop wording to *every*
//  request regardless of whether `EnableActions=true`. That added
//  ~800-1,000 tokens of pure waste prefill on every turn for the
//  default (non-action) user.
//
//  Preinstalled powers own their tool and instruction definitions. This
//  assembler adds per-turn memory, ambient context and loop guidance.

import Foundation

enum CompanionSystemPrompt {
    static let desktopToolRecoveryGuidance = PaceComputerUsePower.desktopToolRecoveryGuidance

    /// Build the system prompt for the next request.
    /// - Parameters:
    ///   - includeAgentMode: pass `true` only when
    ///     `EnableActions=true` is set in Info.plist. Adds ~700
    ///     tokens of action-tag + plan-act-observe instructions.
    ///     Skipped in the default (read-only) configuration to keep
    ///     TTFT down.
    ///   - threadSummaryInjection: optional leading addendum that
    ///     summarizes everything older than the verbatim window. When
    ///     non-nil this is the literal block
    ///     `<conversation_so_far>...</conversation_so_far>` produced
    ///     by `PaceThreadMemory.injectionPrefix()`. Same wrapper tags
    ///     flow through every planner tier so the tier picker never
    ///     forks per-tier behavior.
    static func build(
        includeAgentMode: Bool,
        isTuitionModeEnabled: Bool = false,
        threadSummaryInjection: String? = nil,
        ambientContextInjection: String? = nil,
        usesIterativeComputerUse: Bool = false,
        includeInteractiveDiagrams: Bool = false
    ) -> String {
        var assembledPrompt = PacePowerCatalog.preinstalled.prompt(for: .init(
            turnKind: .screen,
            includeAgentMode: includeAgentMode,
            isTuitionModeEnabled: isTuitionModeEnabled,
            includeInteractiveDiagrams: includeInteractiveDiagrams
        ))
        if includeAgentMode && usesIterativeComputerUse {
            assembledPrompt += """

                Computer-use loop for this planner: Pace WILL call you again after executing your tools, with fresh screen context and tool observations. This overrides the single-envelope rule above for tasks that depend on changing UI. Emit only the next grounded action or independent action group, then inspect the next observation before choosing a dependent click or key. Once the requested result is verified, answer briefly without actions. Do not replay completed actions. Direct app/URL launches may be grouped when independent. Respect Tuition Mode if enabled.

                Read-only inspection and pointing: a Peekaboo see result with an incomplete AX tree can still contain valid screenshot/OCR evidence. "not actionable" denies mutation authority; it does not forbid reading visible text or showing Pace's own pointer/annotation overlay. If a warning asks you to retry once, inspect the completed requests/results and retry the same target at most once. After persistent AX failure, answer from the supplied screenshot/OCR when sufficient instead of repeating see or inventing inspection arguments. For a point-only request, use [POINT:x,y:label:desktop] inside spokenText with the center of the freshly observed global desktop bounds. Draw.annotation is also overlay-only, but its geometry must use the supplied Pace screenshot pixels. Neither overlay grants permission to click, type, focus, or mutate the inspected app. Never use an input action to simulate highlighting. If the evidence is insufficient, say what could not be read or located.
                """
        }
        // Ambient context (frontmost app, window title, time of day)
        // is appended AFTER the static blocks so the KV-cache prefix
        // stays stable — only the tail changes per-turn. The ambient
        // block is small (~50 tokens) and gives the planner instant
        // context without a VLM round-trip.
        if let ambient = ambientContextInjection, !ambient.isEmpty {
            assembledPrompt += "\n\n" + ambient
        }
        return prependingThreadSummaryInjection(
            threadSummaryInjection,
            to: assembledPrompt
        )
    }

    /// Prompt for text-only answer turns (pure knowledge, journal recall).
    /// Deliberately excludes the pointing rules: those mandate a "i can't
    /// see X on this screen" refusal for targets missing from the element
    /// list, and on a screenless turn there IS no element list — a small
    /// greedy-sampled model will follow that drilled template even when
    /// LOCAL CONTEXT holds the answer. Also saves ~250 tokens of prefill.
    /// - Parameter threadSummaryInjection: see `build(includeAgentMode:
    ///   threadSummaryInjection:)`.
    static func buildTextOnly(
        threadSummaryInjection: String? = nil,
        ambientContextInjection: String? = nil,
        includeInteractiveDiagrams: Bool = false
    ) -> String {
        var prompt = PacePowerCatalog.preinstalled.prompt(for: .init(
            turnKind: .textOnly, includeInteractiveDiagrams: includeInteractiveDiagrams
        ))
        if let ambient = ambientContextInjection, !ambient.isEmpty {
            prompt += "\n\n" + ambient
        }
        return prependingThreadSummaryInjection(
            threadSummaryInjection,
            to: prompt
        )
    }

    /// Prompt for `.research` turns running through
    /// `PaceLocalCLIPlannerClient` against the user's authenticated
    /// `claude` or `codex` CLI. Three differences from the regular
    /// `build(...)` prompt:
    ///
    /// 1. **No agent-mode tool docs.** The CLI has its own built-in
    ///    web tools (`WebSearch`, `WebFetch`, file IO, etc.); we'd
    ///    only confuse it by listing Pace's local-execution tool
    ///    dialect on top. Saves ~700 tokens of prefill per call on
    ///    Opus (~$0.01 per turn).
    /// 2. **Explicit "use your own tools" instruction.** The CLI is
    ///    headless under `-p`, and some headless configurations
    ///    restrict tool access by default — tell it to use what it
    ///    has rather than refuse for lack of permissions Pace
    ///    doesn't actually need to grant.
    /// 3. **Spoken-answer shape.** Pace will speak the model's
    ///    response, so research output must stay tight: one or two
    ///    short paragraphs, no markdown bullets, no headers, no
    ///    code blocks unless absolutely necessary.
    ///
    /// - Parameter threadSummaryInjection: see `build(includeAgentMode:
    ///   threadSummaryInjection:)`.
    static func buildForResearchTurn(
        threadSummaryInjection: String? = nil,
        includeInteractiveDiagrams: Bool = false
    ) -> String {
        let assembledPrompt = PacePowerCatalog.preinstalled.prompt(for: .init(
            turnKind: .research, includeInteractiveDiagrams: includeInteractiveDiagrams
        ))
        return prependingThreadSummaryInjection(
            threadSummaryInjection,
            to: assembledPrompt
        )
    }

    /// Plan-then-execute wrapper for the in-process bundled MLX
    /// planner. The 4B model benefits materially from an explicit
    /// "intent → plan → action" scaffold before it commits to a
    /// response — accuracy on multi-step + ambiguous turns goes up
    /// without measurably hurting single-action latency, because
    /// the <think> block is short (3-7 word intent + optional steps)
    /// AND is stripped before TTS via the existing
    /// StreamingSentenceTTSPipeline thinking-block stripper.
    ///
    /// Wrapping (rather than replacing) the existing prompt keeps
    /// the v10 tool contract, pointing rules, and persona intact —
    /// the plan-then-execute addition is a structural overlay on
    /// top of the same downstream behavior.
    ///
    /// Used by `PaceMLXPlannerClient` only. The LM Studio path
    /// (qwen3-30b-a3b) doesn't need this scaffold; the larger model
    /// plans implicitly with no scaffolding cost.
    static func wrapWithPlanThenExecuteScaffoldForBundledMLX(_ basePrompt: String) -> String {
        return basePrompt + "\n\n" + planThenExecuteScaffoldForBundledMLX
    }

    /// The plan-then-execute scaffold itself. Pure constant so the
    /// wrapper helper above is trivially unit-testable AND so the
    /// scaffold text is diff-able as a behavior contract (small
    /// wording changes here measurably shift the 4B model's
    /// accuracy on the FM-fixture eval).
    ///
    /// Trimmed version (Lever #3 — ~700 → ~180 tokens of prefill).
    /// The two worked examples have been removed; the 4B model gets
    /// the structural rules without paying the prefill cost for the
    /// example turns on EVERY user message. The shape and the
    /// load-bearing rules (intent line shape, skip-on-simple,
    /// stripped-before-TTS, 1-2 sentence cap) are all preserved.
    /// PaceMLXPlannerEvalHarnessTests gates regressions.
    static let planThenExecuteScaffoldForBundledMLX: String = """
    PLAN-THEN-EXECUTE PROTOCOL (bundled-MLX 4B accuracy aid)

    Before every spoken response, write a short <think> block:

    <think>
    intent: <what the user wants in 3-7 words>
    plan:   <single-action OR numbered steps if multi-step>
    risk:   <none OR flag anything irreversible>
    </think>

    - Each <think> line ≤12 words.
    - Skip the `plan:` and `risk:` lines for a single no-risk action
      (e.g. "what time is it", "open Safari", "set a timer 5 min").
    - The <think> block is stripped before TTS — it's your scratchpad,
      not for the user. Do not reference its contents in the spoken
      reply.

    After </think>, produce 1-2 short sentences for TTS plus any tool
    calls per the standard contract above.
    """

    /// Stable prefix layout: the thread summary block always sits
    /// BEFORE the persona / tool / pointing rules so the v10 schema
    /// fixtures and prompt-cache stability can pin both ends.
    private static func prependingThreadSummaryInjection(
        _ threadSummaryInjection: String?,
        to assembledPrompt: String
    ) -> String {
        guard let threadSummaryInjection,
            !threadSummaryInjection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return assembledPrompt
        }
        return threadSummaryInjection + "\n\n" + assembledPrompt
    }

}
