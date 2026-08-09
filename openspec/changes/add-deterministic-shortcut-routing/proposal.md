## Why

Pace can already run a named macOS Shortcut, but discovering the installed
shortcut and deciding to use it still depends on the planner unless the user
uses the exact tool-oriented wording the prompt expects. That spends model
latency and can lead the planner to recreate an automation with brittle UI
actions even when the user has already built a deterministic local workflow.

The first automation-provider slice should prove that Pace can discover an
existing local automation and route an explicit command to it without a VLM or
LLM while preserving the current approval, preflight, observation, and audit
surfaces.

## What Changes

- Add a local Shortcuts automation provider that discovers installed shortcut
  names through `/usr/bin/shortcuts list` and returns a bounded cached catalog.
- Add a deterministic parser for explicit commands such as "run my Morning
  Routine shortcut" and "list my shortcuts."
- Route an exact installed-shortcut match through the existing
  `PaceActionExecutionPlan` and `.runShortcut` executor path before screen
  capture, VLM, or planner dispatch.
- Keep installed shortcut names on-device and out of planner prompts.
- Return clear local feedback when Shortcuts discovery fails or the requested
  name does not exactly match an installed shortcut.
- Add focused parser, catalog, failure, and routing tests plus the required
  source-file documentation.

## Capabilities

### New Capabilities

- `local-automation-routing`: Discover and invoke an explicitly named local
  automation without model reasoning while retaining Pace's action policy.

### Modified Capabilities

None.

## Impact

- Runtime: pre-planner routing in `CompanionManager+AgentLoop.swift` and a small
  Shortcuts provider/parser beside the existing automation command parsers.
- Existing execution: reuses `.runShortcut`, `PaceToolPreflight`, action
  approval, observations, user feedback, and debug tracing unchanged.
- Privacy: installed shortcut names remain local and are not appended to
  prompts or sent through MCP, Direct API, CLI, or cloud planner tiers.
- Dependencies and deployment: no dependency, entitlement, migration,
  production configuration, release, or network path.
- Follow-up boundary: semantic selection among automations, Hammerspoon,
  Keyboard Maestro, BetterTouchTool, file/device triggers, and generic imported
  scripts remain out of this first slice.
