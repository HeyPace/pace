## 1. Typed Automation Core

- [x] 1.1 Add versioned automation definitions, typed tool-call steps, provenance, and execution-mode models.
- [x] 1.2 Add strict validation against `PaceToolRegistry` and the deterministic local allowlist.
- [x] 1.3 Add the compiler from manifest steps to the existing `PaceActionExecutionPlan` parser seam.
- [x] 1.4 Add focused tests for valid compilation, partial parse rejection, forbidden tools, and schema drift.

## 2. Bundled Recipe Audit

- [x] 2.1 Audit all five existing recipe descriptions against their complete runtime behavior.
- [x] 2.2 Convert useful fully representable recipes to typed manifests with accurate descriptions.
- [x] 2.3 Retire misleading or unavailable recipes and document each decision in `docs/knowledge/failed-approaches.md`.
- [x] 2.4 Update recipe tests and docs to derive surviving inventory rather than assume five entries.

## 3. Unified Local Catalog And Routing

- [x] 3.1 Discover typed manifests, recorded flows, skills, and Shortcuts as labeled catalog entries without persisting a duplicate index.
- [x] 3.2 Add pure deterministic parsing for “list my automations” and “run automation <name>.”
- [x] 3.3 Dispatch unique exact matches through their existing source-specific execution paths and reject collisions locally.
- [x] 3.4 Keep catalog responses out of conversation memory and planner prompts.
- [x] 3.5 Add focused discovery, execution-mode, collision, fallthrough, and dispatch tests.

## 4. Documentation And Verification

- [x] 4.1 Update key-file, capability, architecture, automation-learning, and failed-approaches documentation.
- [x] 4.2 Validate both related OpenSpec changes, run the smallest relevant isolated tests through `scripts/test-pace.sh`, run `scripts/validate-docs.sh`, and run `git diff --check`. (2026-08-10: 73/73 focused tests, strict validation for all five active changes, and `git diff --check` pass; docs validation reports only the six pre-existing generated-mirror links.)

## 5. Starter Automation Library

- [x] 5.1 Define a 10–20 entry starter inventory using only complete, reusable native-tool outcomes.
- [x] 5.2 Add indexed manifests for note templates, calendar reads, timers, Finder locations, current-window layouts, and bounded media control.
- [x] 5.3 Add inventory-wide tests that compile every indexed manifest and assert category coverage without maintaining a second hard-coded inventory.
- [x] 5.4 Update product and learning documentation with the starter-library scope and the explicit rule that flows, skills, Shortcuts, and schedulers remain separate executors.
