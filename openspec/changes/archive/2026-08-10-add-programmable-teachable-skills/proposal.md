## Why

Pace can currently teach either fixed typed calls or planner-grounded prose, but
it cannot represent reusable logic such as bounded repetition or branching.
Using an LLM again on every run is unnecessary for that middle class of work;
the local authoring model should compile it once into a constrained Pace-owned
program that executes deterministically thereafter.

## What Changes

- Add a versioned, declarative Pace Program representation for user-taught
  automations, with allowlisted typed tool calls plus bounded condition and
  repetition nodes.
- Let the privacy-pinned local authoring planner choose this representation
  when a request needs simple logic but not live planner judgment.
- Validate the complete program, including inactive branches, before saving;
  reject unsupported tools, invalid arguments, excessive nesting, and work
  budgets that exceed fixed limits.
- Compile each run into the existing typed action plan so current preference
  checks, action approval, execution, observation, and audit behavior remain
  authoritative.
- Surface programmed automations alongside teachable skills and the unified
  automation catalog with an honest deterministic-program execution label.
- Keep raw Lua, JavaScript, shell, AppleScript, JXA, imports, network access,
  arbitrary file access, and direct Accessibility access outside the runtime.
  A future language frontend may compile source into the same validated Pace
  Program representation, but source code will not execute with host authority.
- Preserve the existing fallback ladder: fixed typed definition first, bounded
  Pace Program second, planner-grounded skill last.

## Capabilities

### New Capabilities

- `programmable-teachable-skills`: Author, validate, store, discover, and run
  bounded deterministic programs as a teachable-skill representation.

### Modified Capabilities

- None.

## Impact

- Affects natural-language automation structuring, user-authored automation
  persistence, unified catalog metadata and dispatch, and the Skills settings
  surface.
- Adds a small interpreter/compiler over existing `PaceAutomationToolCall`
  validation and `PaceActionExecutionPlan`; it does not add a second action
  executor.
- Stores program definitions separately under Pace Application Support so
  existing `.skill.md`, flow, Shortcut, and typed-definition data require no
  migration.
- Adds no production dependency and no off-device model or telemetry path.
