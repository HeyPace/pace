## 1. Local Matching Core

- [x] 1.1 Add invocation phrases to typed definitions and unified catalog entries while preserving existing manifests.
- [x] 1.2 Implement exact-trigger and injected-embedding scoring with dispatch threshold and ambiguity margin outcomes; matcher failure must never fall back to token overlap.
- [x] 1.4 Resolve close semantic candidates with a fresh on-device typed-output language-model session that can run, decline, or ask for clarification.
- [x] 1.3 Add pure word fixtures for exact, semantic, weak, collision, and embedding-failure behavior.

## 2. Transcript Routing

- [x] 2.1 Discover the complete local catalog once per completed transcript and evaluate ordinary text after explicit management commands.
- [x] 2.2 Dispatch unique matches through existing typed, flow, skill, and Shortcut paths; preserve planner fallthrough for all other outcomes.
- [x] 2.3 Add narrow integration coverage proving typed text and finalized voice transcripts share the same routing seam without audio dependencies.

## 3. Natural-Language Creation

- [x] 3.1 Add an explicit create-automation parser and a constrained privacy-pinned local structuring contract.
- [x] 3.2 Add isolated atomic storage for valid user-authored typed definitions with collision protection and per-file invalid-definition isolation.
- [x] 3.3 Validate and fully compile structured typed output before persistence; fall back to an explicitly planner-grounded skill when fixed calls are not representable.
- [x] 3.4 Add pure text fixtures for deterministic creation, invalid-call rejection, name collision, planner failure, and skill fallback.

## 4. Documentation And Verification

- [x] 4.1 Update architecture, capabilities, learning, key-file, and test-coverage documentation for natural matching and user-created definitions.
- [x] 4.2 Run focused isolated tests, strict validation for all active OpenSpec changes, docs validation, and `git diff --check`. (2026-08-10: 73/73 focused tests, strict validation for all five active changes, and `git diff --check` pass; docs validation reports only the six pre-existing generated-mirror links.)
- [x] 4.3 Leave microphone end-to-end validation explicitly pending until transcript fixtures pass on the supported local build environment.
