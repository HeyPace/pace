# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Mac users who want to control applications, retrieve information, and automate
recurring work through voice without giving a cloud service access to their
screen, audio, or local context.

## Product Purpose

Pace is a menu-bar voice agent for macOS. It listens, can read the current
screen through a local vision model, plans locally, speaks responses, and—with
explicit action enablement—executes approved macOS actions. Success means the
user can complete useful computer work conversationally while retaining local
control of their data and model runtime.

## Positioning

Pace combines screen-aware voice control with an on-device inference and
execution stack. Local processing is the product's primary trust boundary, not
an optional privacy mode.

## Operating Context

The native product lives in the macOS menu bar and notch rather than a
traditional application window. Users invoke it by hotkey or enabled
background modes, interact through its capsule and floating panel, and can
connect local models, macOS integrations, MCP servers, recipes, flows, and
taught skills. The public website explains the product, its privacy model,
capabilities, comparisons, pricing, and release path.

## Capabilities and Constraints

- Local ASR, TTS, vision, planning, memory, and execution are the default.
- Non-local planner paths are explicit exceptions with consent, visible amber
  state, audit logging, and fail-loud behavior.
- Risky or non-undoable actions can require approval; reversible mutations
  expose undo.
- The app is macOS-native. The marketing and documentation surface is web.
- Hardware-bound behavior and signed releases require manual validation.

## Brand Commitments

The product name is Pace. The public promise centers on direct voice control,
useful screen awareness, and on-device privacy. Product claims must not imply
unmeasured grounding accuracy, fictional customer proof, or cloud-free behavior
for explicitly enabled off-device planner paths.

## Evidence on Hand

- Native product implementation and tests under `leanring-buddy/` and
  `leanring-buddyTests/`.
- Public landing and documentation under `website/`.
- Product and release history in `PROJECT_STATUS.md`.
- Architecture, privacy, capability, evaluation, and operations evidence under
  `docs/`.
- Demonstration media in `pace-demo.gif` and `website/public/`.

Real attributed customer quotations remain pending permission. Hardware smoke
evidence is release-specific and must not be inferred from unit tests.

## Product Principles

1. Keep the useful default on-device.
2. Make trust boundaries and risky actions visible.
3. Prefer grounded execution and honest failure over confident guessing.
4. Preserve user control through consent, auditability, and undo.
5. Treat measured evidence as the limit of public claims.

## Accessibility & Inclusion

The native app and website must support keyboard access, visible focus,
reduced-motion preferences, clear status communication, and readable contrast.
