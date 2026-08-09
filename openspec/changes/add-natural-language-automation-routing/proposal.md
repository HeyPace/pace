## Why

Pace currently discovers and runs reusable work only when the user names an
automation explicitly, even though typed chat and voice both arrive as the same
transcript. Users should be able to ask naturally, teach a reusable workflow in
their own words, and have Pace select or create the safest local representation
without requiring catalog command syntax.

## What Changes

- Add a local transcript matcher that considers exact authored aliases
  first, then local embeddings for semantic recall. Token overlap never
  authorizes execution.
- Dispatch only a unique high-confidence catalog match; ambiguous or weak
  matches fall through to the existing planner and execute nothing implicitly.
- Make authored skill triggers active invocation phrases instead of stored-only
  metadata.
- Add natural-language automation creation that structures a request with a
  privacy-pinned local planner, validates every proposed call against the typed
  automation allowlist, and saves only completely deterministic definitions.
- Fall back to the existing planner-grounded teachable-skill representation
  when the requested workflow cannot be represented by fixed typed calls.
- Exercise routing and creation through pure transcript/unit fixtures before
  any end-to-end microphone testing.

## Capabilities

### New Capabilities

- `natural-language-automation-routing`: Safe local selection and creation of
  reusable automations from ordinary text transcripts.

### Modified Capabilities

- None.

## Impact

- Affects the unified automation catalog, typed automation definition library,
  pre-planner transcript dispatch, and teachable-skill creation path.
- Adds user-authored typed automation persistence under Pace Application
  Support; no existing flow, skill, Shortcut, or bundled automation data is
  migrated.
- Reuses the existing local embedding chain, privacy-pinned local planner,
  typed compiler, preflight, approval, execution, observation, and audit paths.
- Adds no production dependency and no off-device data path.
