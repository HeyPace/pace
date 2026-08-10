## Why

Pace's first automation-provider slice can discover and run existing macOS
Shortcuts without a model, but the local machine currently has no installed
Shortcuts or recorded flows and no third-party automation engine. An adapter to
an empty catalog does not reduce planner dependence.

Pace does ship five bundled recipes, but they reuse the recorded-flow schema,
which only knows app activation, Accessibility presses, literal typing, and key
shortcuts. Several recipe descriptions therefore claim outcomes their steps do
not produce: `focus mode on` only opens Music, `inbox triage pass` never performs
triage, and `morning standup setup` never retrieves calendar data. These should
not be presented as completed deterministic automations.

The next slice should give Pace a typed, provider-neutral local automation
catalog whose deterministic steps reuse the canonical tool registry and action
executor. The catalog must also distinguish deterministic automations from
planner-grounded skills and opaque external workflows so Pace can prefer code
when code is sufficient without pretending every task is model-free.

## What Changes

- Add a versioned `PaceAutomationDefinition` manifest with identity,
  provenance, execution mode, required preferences, and ordered typed tool-call
  steps.
- Validate bundled deterministic automations against `PaceToolRegistry` and an
  explicit local allowlist. Reject scripts, MCP, downloads, destructive tools,
  and unknown tool names at startup.
- Convert honest bundled recipes to typed native actions that execute through
  the existing `PaceActionExecutionPlan`, preflight, approval, observation, and
  audit surfaces.
- Retire recipes whose advertised outcome requires planner judgment or an
  unavailable external dependency; record why rather than preserving dead
  theatre.
- Add a unified local catalog over typed bundled automations, recorded flows,
  skills, and installed Shortcuts. Every entry exposes whether execution is
  deterministic, planner-grounded, or externally opaque.
- Add deterministic “list my automations” and “run automation <name>” routing.
  Only exact unique names run; collisions are reported locally and execute
  nothing.
- Keep catalog metadata local and out of planner prompts and conversation
  memory.
- Ship a useful starter library across Notes templates, Calendar reads,
  standard timers, Finder locations, window layouts, and media controls. Each
  entry must describe only the literal native-tool outcome it performs.

## Capabilities

### New Capabilities

- `typed-local-automation-catalog`: Discover, classify, validate, and execute
  reusable local automations while preferring deterministic typed actions over
  model planning.

### Modified Capabilities

- `local-automation-routing`: Expand deterministic routing from Shortcuts-only
  commands to a unified catalog with explicit execution-mode labels.

## Impact

- Runtime: new automation definition/catalog/validator/execution components;
  pre-planner routing in `CompanionManager+AgentLoop.swift`.
- Existing systems: reuses `PaceToolRegistry`, `PaceActionTagParser`,
  `PaceActionExecutionPlan`, `PaceToolPreflight`, `PaceActionApprovalPolicy`,
  `PaceActionExecutor`, `PaceFlowStore`, `PaceSkillLoader`, and the Shortcuts
  provider.
- Bundled content: replace or retire the current five recipe JSON files based
  on whether their outcome can be represented honestly with allowed typed
  local tools, then expand the same typed format into a practical starter
  library.
- Privacy: catalog discovery and exact matching stay on-device; no automation
  names are appended to planner or provider requests.
- Dependencies and deployment: no new dependency, entitlement, network path,
  migration, production configuration, or release action.
- Out of scope: Hammerspoon/Keyboard Maestro/BetterTouchTool adapters, arbitrary
  scripts, semantic or embedding matching, event triggers, and a new Settings
  UI.
