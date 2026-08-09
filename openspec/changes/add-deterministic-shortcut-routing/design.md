## Context

Pace's typed action registry already exposes a `shortcuts` tool, and
`PaceActionExecutor.runShortcut(named:)` already validates the requested name
against `/usr/bin/shortcuts list` before running it. The missing seam is
pre-planner discovery and routing: an explicit user command currently reaches
the general planner even though resolving an exact installed name is a local,
deterministic operation.

This slice establishes the smallest automation-provider contract around the
built-in macOS Shortcuts runtime. It does not attempt to inspect shortcut
steps, infer side effects, parse `.shortcut` files, or translate arbitrary
scripts into Pace actions.

## Goals / Non-Goals

**Goals:**

- Resolve explicit run/list Shortcut commands without screen capture or model
  inference.
- Discover installed shortcut names without blocking the main actor.
- Cache discovery briefly so ordinary turns do not launch a process.
- Preserve the existing action toggle, preflight, approval, observation,
  feedback, and debug-record behavior.
- Keep shortcut-name metadata local even when an off-device planner tier is
  configured.
- Create a provider seam that can later support additional local automation
  products without teaching the planner their native script formats.

**Non-Goals:**

- Automatically choosing a shortcut for a request that does not explicitly
  mention Shortcuts.
- Fuzzy or embedding-based matching.
- Reading, editing, importing, exporting, or translating shortcut steps.
- Running Hammerspoon Lua, AppleScript, shell, Keyboard Maestro XML, or
  BetterTouchTool JSON.
- Adding event triggers, a workflow editor, or an automation gallery.

## Flow

```mermaid
flowchart LR
    U[Voice or typed transcript] --> P[Deterministic Shortcut command parser]
    P -->|not an explicit Shortcut command| L[Existing Pace routing]
    P -->|list or run| C[Local Shortcuts provider cache]
    C --> S[/usr/bin/shortcuts list]
    C -->|exact installed match| E[Existing PaceActionExecutionPlan]
    E --> G[Preflight and approval]
    G --> R[Existing runShortcut executor]
    R --> O[Observation, feedback, and audit]
```

## Decisions

### Use an actor-backed provider with injected command execution

Add a small `PaceShortcutsAutomationProvider` actor. It owns a catalog snapshot
and refresh timestamp, and accepts an injected command runner and clock for
deterministic tests. Production discovery executes `/usr/bin/shortcuts list`
away from the main actor.

The provider returns a typed result rather than an empty array on failure, so
the caller can distinguish "no shortcuts installed" from "discovery failed."
The successful catalog contains normalized lookup keys while preserving the
original display names for execution and feedback.

### Cache successful discovery, not failures

A successful catalog is reused for five minutes. A failure is returned to the
caller and may be retried on the next explicit Shortcut command. This avoids a
transient Shortcuts failure poisoning the process while preventing every Pace
turn from spawning `/usr/bin/shortcuts`.

The cache is memory-only. Pace does not need another persisted index, migration,
or source of truth because Shortcuts already owns the catalog.

### Match only explicit commands and exact normalized names

The pure `PaceShortcutCommandParser` recognizes a narrow grammar:

- `list my shortcuts` / `what shortcuts do I have`
- `run shortcut <name>`
- `run <name> shortcut`
- `run my <name> shortcut`

Matching folds case, diacritics, and repeated whitespace, consistent with the
executor's current name check. It does not use substring or fuzzy matching.
An exact match runs; no match gets a local not-found response. This prevents a
shortcut named "Mail" or "Timer" from hijacking ordinary commands.

### Reuse the fast local action path

For a run match, the router creates a `PaceFastActionParseResult` containing a
serial `.runShortcut(displayName)` action and passes it to
`handleFastLocalActionPath`. That path already performs preflight, asks for
approval, executes through `PaceActionExecutor`, records observations, speaks
feedback, and writes a no-planner debug trace.

Listing and discovery errors use the existing immediate local-response helper
because they do not mutate the system.

### Keep the catalog out of prompts

Shortcut names can reveal projects, clients, health routines, or personal
habits. This slice never appends them to `CompanionSystemPrompt` or any planner
request. Later semantic automation selection must define a separate local-only
matching policy and explicit behavior for off-device planner tiers.

## Risks / Trade-offs

- **Explicit wording is narrower than the eventual product** -> This is the
  safe proof that automation can bypass the LLM. Semantic reuse follows after
  provider behavior and audit evidence are measured.
- **Installed shortcuts can contain arbitrary side effects** -> Pace cannot
  inspect their internals, so the existing action approval remains mandatory;
  Pace reports the named shortcut it will run rather than claiming its effects.
- **The first lookup launches a process** -> It runs outside the main actor and
  successful results are cached for five minutes.
- **The Shortcuts catalog can change during the cache window** -> The executor
  performs its existing fresh validation before execution, so a deleted or
  renamed shortcut fails safely.
- **Exact matching may reject natural variants** -> A clear not-found response
  is safer than executing the wrong automation; aliases and user-approved
  semantic metadata can be added later.

## Migration Plan

1. Add the provider, catalog result, and pure command parser with injected
   seams.
2. Add focused unit tests for grammar, normalization, caching, failure, and
   exact matching.
3. Route explicit Shortcut commands before screen/model work and reuse the
   existing local action path.
4. Update the key-file and capability documentation, validate the OpenSpec
   change, run focused tests through `scripts/test-pace.sh`, validate docs, and
   run `git diff --check`.

Rollback removes the pre-planner branch and provider/parser. The existing
planner-generated `shortcuts` tool and executor remain unchanged, and no stored
data requires migration.
