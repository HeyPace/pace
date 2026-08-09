## 1. Local Shortcuts Provider

- [x] 1.1 Add typed catalog success/failure results and a Shortcuts provider with injected command and clock seams.
- [x] 1.2 Parse, normalize, sort, and cache successful `/usr/bin/shortcuts list` results for five minutes without caching failures.
- [x] 1.3 Add deterministic provider tests for parsing, normalization, cache reuse/expiry, empty success, and command failure.

## 2. Deterministic Command Routing

- [x] 2.1 Add the pure explicit Shortcut list/run command parser with exact normalized catalog matching.
- [x] 2.2 Route explicit Shortcut commands before screenshot, VLM, and planner work.
- [x] 2.3 Reuse `handleFastLocalActionPath` for matched runs and the immediate local-response surface for listing, not-found, and discovery-failure outcomes.
- [x] 2.4 Add focused tests proving non-Shortcut requests fall through and matched execution reuses the typed `.runShortcut` plan.
- [x] 2.5 Move Shortcut list/run processes off the main actor with bounded timeouts and cancellation propagation.
- [x] 2.6 Align the Apple Foundation Models typed tool guide with the canonical registry so `shortcuts` and the other registered local tools are selectable.

## 3. Documentation And Verification

- [x] 3.1 Update `docs/development/key-files.md`, `docs/product/capabilities.md`, and the canonical automation learning page for the implemented local provider lane.
- [x] 3.2 Validate the OpenSpec change, run the smallest relevant isolated tests through `scripts/test-pace.sh`, run `scripts/validate-docs.sh`, and run `git diff --check`. (2026-08-10: 73/73 focused automation, Shortcut, program, chat-session, skill-execution, and chat-shortcut tests pass; all five active changes pass strict validation; `git diff --check` passes. Docs validation reports only the same six pre-existing generated-mirror links.)
