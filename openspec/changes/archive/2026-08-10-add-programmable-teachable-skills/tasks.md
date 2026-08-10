## 1. Program Model And Compiler

- [x] 1.1 Add the versioned Pace Program metadata, tagged action/condition/repeat node types, supported predicates, and injectable pre-run context model.
- [x] 1.2 Implement whole-graph validation for metadata, predicate values, every branch, nesting, node, repeat, and worst-case expansion budgets while reusing typed-action validation for every action node.
- [x] 1.3 Implement deterministic context evaluation and bounded graph expansion into a transient typed automation definition, including an explicit no-actions-matched outcome.
- [x] 1.4 Add pure tests for Codable round trips, all budget boundaries, inactive-branch rejection, weekday/hour/frontmost-app branches, repetition, order preservation, no-action outcomes, and complete typed compiler reuse.

## 2. Persistence And Catalog Execution

- [x] 2.1 Add isolated atomic user-program storage with save-time and load-time validation, invalid-file isolation, deletion, and identifier/name collision protection.
- [x] 2.2 Extend automation source, execution-mode, catalog-reference, discovery, matching metadata, and spoken listing behavior so valid programs appear as deterministic programs.
- [x] 2.3 Dispatch catalog program references by reloading, validating, compiling against one current-context snapshot, and handing non-empty plans to the existing fast local action path.
- [x] 2.4 Add temporary-directory and catalog tests for valid discovery, malformed-file isolation, collision refusal, deletion, honest labels, stale references, compilation failure, and no-action feedback.

## 3. Local Natural-Language Authoring

- [x] 3.1 Add the constrained privacy-pinned program-authoring prompt and untrusted structured-output decoder for the exact version-1 graph schema.
- [x] 3.2 Create one reusable-work authoring pipeline that attempts fixed typed automation, then validated Pace Program, then the existing planner-grounded skill fallback.
- [x] 3.3 Route both explicit “create an automation” and “teach a skill” transcript commands through the shared pipeline with cross-catalog collision checks and representation-specific confirmation or refusal copy.
- [x] 3.4 Add text-only fixtures for fixed/program/skill selection, planner unavailability, fenced source-code rejection, invented capability rejection, collision handling, and complete validation before persistence.

## 4. Teachable-Skills Surface

- [x] 4.1 List valid programmed automations in the existing “Your skills” section with deterministic-program labeling, invocation phrase, bounded action summary, search support, and pointer-cursor deletion.
- [x] 4.2 Preserve the manual prose-skill form and bundled-skill behavior, and add focused view-model or pure formatting tests for mixed skill/program rows where practical.

## 5. Documentation And Verification

- [x] 5.1 Update architecture, capability, teachable-skill, learning, key-file, and test-coverage documentation without claiming raw Lua or JavaScript support.
- [x] 5.2 Run the smallest focused isolated test groups after each implementation layer, followed by strict validation for all active OpenSpec changes, documentation validation, and `git diff --check`.
- [x] 5.3 Update `PROJECT_STATUS.md` only after the implementation and automated checks establish durable current product truth.
- [x] 5.4 Exercise creation and invocation through typed chat in an Xcode-launched app, record the exact phrases and observed representations, and leave microphone testing pending until the text path is verified on real hardware. (2026-08-10 Xcode Cmd+R dogfood: typed `Create an automation that when I say pace acceptance check, open Calculator`; with LM Studio offline, Pace transparently persisted `pace-acceptance-check.skill.md` as the flexible-skill fallback. Typing `pace acceptance check` resolved the exact trigger and entered the skill invocation path. The action correctly remained behind the unavailable local-planner boundary; no microphone result is claimed.)
