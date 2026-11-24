# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Native macOS brain with a native iPad companion surface, plus a web marketing
and documentation surface.

## Users

Mac users who want to learn an unfamiliar interface or get work done across apps while keeping their hands free. They choose when Pace may read a screen, act on an app, or send context to a provider.

## Product Purpose

Pace gives the user one conversation for asking about the current screen, learning with visual explanations, and operating Mac apps. Local execution connects the selected planner to desktop controls and tools. A paired iPad can act as an input and output surface while the Mac owns execution and history.

## Product availability

The public 0.3.20 preview supports typed screen questions, visible pointing, desktop and browser actions, research, reusable routines, meeting notes, and opening Codex in Warp. It targets Apple Silicon on macOS 26 or later.

The 0.3.21 development build adds Right Option voice input, interactive labeled diagrams, named Powers, Apple Reminders task management, and retained coding sessions. The website and README identify development features separately from the public download.

## Operating Context

A user can type into the notch or speak a request. A Power gives the assistant a capability, such as teaching on screen or working with Reminders. A workflow saves a sequence of actions. In the development build, “Add a Power” can turn a description into a reusable behavior backed by the supported runtime. Developers can also connect applications through MCP.

## Capabilities and Constraints

- Screen context and background observation require explicit enablement. Users can dismiss explanations and stop speech.
- External planning is opt-in. Off-device turns display an amber indicator and write to the local audit log. Screen permission controls whether images can accompany those requests.
- Local speech and storage are available. Meeting-note synthesis stays local when another planner is selected for general questions.
- macOS permissions and action approvals apply to enabled tools. Reversible changes can expose undo.
- Hardware checks, latency measurements, and release claims apply to the specific build exercised.

## Brand Commitments

The product name is Pace. The public promise centers on direct voice control,
useful screen awareness, and on-device privacy. Product claims must not imply
unmeasured grounding accuracy, fictional customer proof, or cloud-free behavior
for explicitly enabled off-device planner paths.

The native product uses a Local Signal Desk world: calm graphite surfaces,
system typography, and an electric-blue signal reserved for active local work.
Amber always means an explicitly enabled off-device path. Cinematic motion is
welcome during first-run activation, but it must explain real state and collapse
into the same notch and panel surfaces the user operates afterward.

## Evidence on Hand

- Native product implementation and tests under `leanring-buddy/`, `PacePad/`,
  `PaceShared/`, and `leanring-buddyTests/`.
- Public landing and documentation under `website/`.
- Product and release history in `PROJECT_STATUS.md`.
- Architecture, privacy, capability, evaluation, and operations evidence under
  `docs/`.
- [Pace Command Center screenshot](website/src/assets/command-center-960.webp).

Real attributed customer quotations remain pending permission. Hardware smoke
evidence is release-specific and must not be inferred from unit tests.

## Product Principles

1. Keep local operation available and make the selected provider clear.
2. Make trust boundaries and risky actions visible.
3. Prefer grounded execution and honest failure over confident guessing.
4. Preserve user control through consent, auditability, and undo.
5. Treat measured evidence as the limit of public claims.

## Accessibility & Inclusion

The native app and website must support keyboard access, visible focus,
reduced-motion preferences, clear status communication, and readable contrast.
