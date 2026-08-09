# Skills and automation

Pace automates repeated work through distinct execution modes. **Typed local
automations** compile fixed tool calls; **Pace Programs** add bounded local
branching and repetition; **recorded flows** replay literal demonstrations;
**skills** ask the local planner to re-ground natural-language steps; and
**Shortcuts** execute opaque workflows owned by macOS. The unified read-only
catalog labels those modes instead of flattening them into one claim.

## Deterministic local automation providers
- What: Bundled manifests under `Resources/automations/` name canonical Pace tools and bounded JSON arguments. `PaceAutomationCompiler` serializes those calls into the existing parser dialect and refuses partial parses, so execution reuses normal preflight, approval, executor, observation, and audit behavior without invoking a planner.
- Catalog: `PaceAutomationCatalog` discovers typed manifests, Pace Programs, saved flows, skills, and installed Shortcuts without persisting a duplicate index. “List my automations” labels each entry as deterministic local, deterministic program, deterministic replay, local-planner grounded, or externally opaque. “Run automation &lt;name&gt;” remains an exact normalized management command; ordinary text can use an exact authored alias or a paraphrase through local semantic embeddings. Token overlap never authorizes execution. Close semantic candidates can use the on-device `PaceAutomationIntentResolver`, which may select only from the embedding shortlist, decline, or ask the user to clarify.
- Shortcuts: `PaceShortcutsAutomationProvider` queries `/usr/bin/shortcuts`, caches only successful catalogs for five minutes, and supports explicit source-specific list/run commands.
- Privacy: Catalog names and listing responses are not added to planner prompts or conversation memory. Only running a planner-grounded skill enters that skill's existing execution path.
- Where: `PaceAutomationDefinition.swift`, `PaceAutomationCatalog.swift`, `PaceAutomationIntentResolver.swift`, `PaceShortcutsAutomationProvider.swift`, and pre-planner dispatch in `CompanionManager+AgentLoop.swift`.

## Natural-language selection
- What: `PaceAutomationNaturalLanguageMatcher` checks normalized authored aliases first, then uses cosine similarity from the local Nomic/Apple embedding chain. A clear winner dispatches directly; a bounded near-threshold shortlist can go to the on-device resolver. Token overlap has no execution authority.
- Why here: Embeddings retrieve paraphrases but are not authority. Weak scores, close Calendar/read-vs-mutate candidates, catalog failures, and embedding failures preserve the existing planner path instead of guessing an automation.
- Latency: Exact triggers make no embedding call. Semantic routing uses the bundled MLX Nomic embedder when enabled or gives LM Studio's Nomic endpoint 750 ms before the always-local Apple NaturalLanguage fallback.
- Text seam: Typed chat, `pace://chat`, and finalized speech transcripts all call `sendTranscriptToPlannerWithScreenshotAsync`, so pure word fixtures cover routing before microphone E2E.

## Natural-language creation
- What: “create an automation …” and “teach a skill …” use the same least-powerful-complete ladder. A privacy-pinned local text planner first proposes fixed allowlisted calls, then a bounded Pace Program, then a planner-grounded skill. Each structured result is untrusted until its representation-specific validator accepts it.
- Pace Programs: The version-1 graph supports typed action steps, weekday/hour/frontmost-app conditions over one pre-run snapshot, and literal repetition. It requires real conditional/repeat logic, validates every inactive branch, and caps depth at 4, source nodes at 50, repeats at 10, and worst-case action steps at 50. It compiles into the existing typed executor and never calls a model during a run.
- Authority boundary: A program document cannot add tools or execute Lua, JavaScript, shell, imports, network access, arbitrary files, or direct Accessibility APIs. General source syntax would need to compile entirely into the same inert graph before installation.
- Storage: User typed definitions live under `~/Library/Application Support/Pace/automations/`; programs live under `~/Library/Application Support/Pace/programs/`; prose skills remain separate. Atomic writes refuse cross-catalog normalized-name and identifier collisions, and invalid files are skipped independently.
- Where: `PaceProgrammableSkill.swift` owns the program model, strict decoder, validator, context evaluator, compiler, store, and authoring contract. `CompanionManager+AgentLoop.swift` owns the privacy-pinned authoring calls; `CompanionManager+LocalMemoryCommands.swift` owns discovery and model-free dispatch.

## Teachable skills (`.skill.md`)
- What: A skill is a numbered step list stored as a `.skill.md` file (YAML frontmatter + `## Steps` body) that the planner **re-grounds every run** rather than replaying recorded UI actions.
- Why here: The most flexible automation tier — resilient to UI changes because each run re-interprets the steps against the current screen, unlike a recorded flow's verbatim role-path replay.
- Where: `PaceSkillLoader.swift` — `PaceSkillFile` (parsed model: `name`, `slug`, `description`, `category`, `requiredPreferences`, `trigger`, `steps: [PaceSkillStep]`, `notes`); `PaceSkillLoader.parse`/`serialize` round-trip the format; `toPlannerPrompt` turns steps into a numbered instruction prompt for the agent loop.
- Source: internal — `.skill.md` format compatible with common agent skill files (see file header comment).

## Teaching a skill by voice or form
- What: Completed teach/create transcripts can become a typed automation, Pace Program, or prose `PaceSkillFile`; typed chat and finalized voice share that transcript seam. The Settings form remains a deterministic manual editor for planner-grounded prose steps.
- Why here: “Teachable by telling” describes the product surface, not one storage format. Fixed work should not pay a model on every run, bounded logic should remain deterministic, and only genuinely contextual work should use a planner-grounded skill.
- Where: `PaceProgrammableSkill.swift` and the shared reusable-work handler in `CompanionManager+AgentLoop.swift`; prose persistence remains in `PaceSkillLoader.save`/`deleteUserSkill`/`listUserSkills`.
- Source: internal — no external spec.

## Skill command parser
- What: A pure, deterministic parser that recognizes "teach a skill…", "list skills", "install/run the `<name>` skill" before the transcript ever reaches the planner.
- Why here: Fast-path routing — teaching, installing, and running a skill are all one-shot deterministic intents that would otherwise burn a planner round-trip; the create-phrase check runs first so "teach a skill that lists my tasks" doesn't get misrouted to the list branch.
- Where: `PaceAutomationCommandParser.swift` — `PaceSkillCommand` (enum: `.list`, `.run`, `.install`, `.create(rawDescription:)`), `PaceSkillCommandParser.parse`.
- Source: internal — no external spec.

## Recorded flows (pixel tier)
- What: A flow records a literal sequence of AX-tree clicks/keystrokes during a user demonstration (`PaceAXRolePath` per step), then replays them verbatim by walking the same recorded accessibility role-paths, with adaptive retry (delay grows ×1.5, capped, per the file header) if a step's target hasn't resolved yet.
- Why here: The least flexible but most literal automation tier — exact reproduction of a demonstrated sequence, used when a skill's re-grounded interpretation would be too loose (e.g. a precise multi-field form fill).
- Where: `PaceFlowReplayer.swift` — `PaceFlowReplayer` (replay engine), `PaceFlowReplayOutcome`, `PaceAXPressResolution`, `PaceLiveFlowReplayActionSink`; recording side in `PaceFlowRecorder.swift` — `PaceFlowRecorder`, `PaceAXRolePath`; the stored model, `PaceRecordedFlow`, lives in `PaceFlowReplay.swift`.
- Source: internal — no external spec.

## Flow store
- What: Atomic JSON persistence for recorded flows — one file per flow, keyed by a slug derived from the flow's display name.
- Why here: Recorded demonstrations retain literal replay semantics and stay separate from bundled typed automations.
- Where: `PaceFlowStore.swift` — `PaceFlowStore` (`slug(for:)`, atomic `writeAtomically`), `PaceFlowStoreError`; the Settings surface for browsing/deleting flows is `PaceFlowsSettingsTab.swift`.
- Source: internal — no external spec.

## Bundled typed automations
- What: Seventeen honest, model-free starter workflows ship across Notes templates, local Calendar reads, standard focus/break timers, Finder locations, current-window layouts, bounded media control, weekly review, and end-of-day reset.
- Why here: Native Notes and EventKit actions express the complete outcome more reliably than recorded keystrokes. Every manifest is versioned, registry-validated, allowlisted, and compiled completely at startup.
- Where: `Resources/automations/<identifier>.json`, loaded and validated by `PaceAutomationDefinitionLibrary`.
- Boundary: This library does not replace the other execution tiers. App-specific demonstrations remain flows, contextual procedures remain planner-grounded skills, user-owned OS workflows remain Shortcuts, and cron/background agents remain schedulers.
- Source: internal typed manifest contract.

## Voice command parsers (pre-planner fast path)
- What: A family of small, pure, deterministic parsers that each recognize one automation surface's trigger phrases and short-circuit before the transcript reaches the planner or intent classifier.
- Why here: Listing or selecting an automation, running an installed Shortcut, toggling watch mode, starting a profiled meeting, or teaching/running a skill should not burn a planner round-trip merely to choose a route.
- Where: `PaceAutomationCatalog.swift` — `PaceAutomationCatalogCommandParser`; `PaceWatchModeCommandParser.swift`; `PaceShortcutsAutomationProvider.swift`; and `PaceAutomationCommandParser.swift` for meeting, skill, cron, and background-agent commands.
- Source: internal — no external spec.

## Voice-command parser precedence (a chain, not independent parsers)
- What: The pre-planner routes are tried in a fixed sequence (`CompanionManager+AgentLoop.swift`: explicit automation → Shortcut → create automation/skill → conservative natural match → flow → remember-site → cron → background-agent → meeting-mode → skill), and an earlier route can match and short-circuit a phrase that was meant for a later one.
- Why here: `PaceFlowCommandParser`'s bare `"run "` / `"play back "` / `"do "` prefix match (`PaceFlowReplay.swift:128`) runs before `PaceSkillCommandParser`, and its `.run` case returns immediately — even on a miss ("i couldn't find a flow named X", `CompanionManager+DemonstrationFlow.swift:26-34`) — without falling through to try the skill parser next. A greedy bare prefix earlier in the chain can starve a more specific parser later in it; the fix is chain-level ordering/deferral discipline, not a fix to either parser in isolation. Regression-test the chain's dispatch order, not each parser alone.
- Where: dispatch order in `CompanionManager+AgentLoop.swift` (parser calls around lines 853-923); the starvable prefix match in `PaceFlowReplay.swift` (`PaceFlowCommandParser.parse`, line 128); the no-fallthrough `.run` handler in `CompanionManager+DemonstrationFlow.swift`.
- Source: internal — no external spec; general lesson (prefix-matching command chains need explicit ordering + deferral guards, not per-parser correctness alone).

## Meeting note profiles
- What: A selectable `PaceMeetingNoteProfile` (bundled `general`/`standup`/`one-on-one` in `Resources/meeting-note-profiles/`, plus user overrides) shapes how `PaceMeetingNotesBuilder` synthesizes a meeting's summary/action-items/decisions.
- Why here: Meetily-informed but Pace-native adaptive notes — the `general` profile reproduces the pre-profiles prompt byte-for-byte (the compat anchor), so adding profiles changed zero behavior for existing users by default.
- Where: `PaceMeetingNoteProfile.swift` — `PaceMeetingNoteProfile` (`.general` static value), `PaceMeetingNoteSection`; `PaceMeetingNoteProfileLibrary.swift` — `PaceMeetingNoteProfileLibrary.loadProfiles`/`resolveProfile`/`shouldInfer`. Selection precedence (`resolveProfile`): explicit per-meeting slug → non-`general` pinned default preference → locally-inferred slug (only when inference is enabled and no non-general default is pinned) → `general`.
- Source: internal — meetily-informed, no external spec.

## Cron scheduler
- What: A general-purpose recurring-task scheduler — "every 30 minutes check my calendar" — where each task is a stored interval + prompt that fires through the normal restraint-gated speaking pipeline.
- Why here: Extends automation from user-triggered reusable work to time-triggered tasks: a fired task sends its `taskPrompt` through the same planner pipeline a live voice turn would use, so scheduled automation gets the same tool/approval guarantees as a spoken command.
- Where: `PaceCronScheduler.swift` — `PaceCronScheduler` (`@MainActor` `ObservableObject`, `.shared`), `PaceCronTask`; voice grammar in `PaceAutomationCommandParser.swift` — `PaceCronCommandParser`/`PaceCronCommand`.
- Source: internal — no external spec.

## Consent-gated background automation (cron brain decision)
- What: A pure decision function that decides whether a scheduled/cron task fires through an off-device Codex brain or falls back to the user's normal local planner — gated on the SAME direct-spawn consent + 24-hour soak the interactive `.cliDirect` tier requires, never a lower bar just because no one is watching.
- Why here: A cron fire is unattended — the user isn't present to notice or object in the moment — so it must never silently escalate to a privilege (off-device CLI spawn) the user only granted for foreground use. If consent+soak aren't both satisfied, the task quietly runs on the local planner instead of failing or auto-escalating.
- Where: `BuddyPlannerClient.swift` — `BuddyPlannerClientFactory.cronTaskBrainDecision(hasAcceptedDirectSpawnConsent:canRunDirectSpawnTurn:)` returns `.useCodexDirectSpawn` or `.useDefaultPlanner(reason:)`, sharing the same `cliDirectDispatchDecision` gate the interactive `.cliDirect` tier uses (see [`planning-and-latency.md`](planning-and-latency.md) → `.cliDirect` general brain). Called from `CompanionManager+Lifecycle.swift`'s `PaceCronScheduler.shared.executeTaskCallback`, which passes `PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent()` and `.canRunDirectSpawnTurn(now:)`; on `.useCodexDirectSpawn` the amber off-device indicator is forced on and a fresh `PaceLocalCLIPlannerClient(upstream: .codex)` runs the task, otherwise the existing `self.plannerClient` (the user's pinned tier) runs it.
- Source: internal — no external spec.

## See also
- [`README.md`](README.md)
