---
title: Pace docs
description: Index of Pace documentation — the on-device macOS menu-bar voice agent.
---

# Pace documentation

This is the canonical documentation index for **Pace** — the on-device macOS
menu-bar voice agent. Markdown committed to this repository is the source of
truth. [Blume](../blume.config.ts) renders it as a searchable site; it is the
presentation layer, not the truth.

Agent instructions live in [`AGENTS.md`](../AGENTS.md) (concise bootloader).
Current state lives in [`../STATUS.md`](../STATUS.md) (lean) and
[`../PROJECT_STATUS.md`](../PROJECT_STATUS.md) (full history).

## Architecture

How Pace is built and why.

- [`architecture/overview.md`](architecture/overview.md) — doctrine (tinygpt's
  role, "steal from anywhere that runs local", the 100 ms / 500 ms latency
  budget, all-data-local) and the high-level constellation diagram.
- [`architecture/systems.md`](architecture/systems.md) — the per-system
  reference: planner tiers, STT/TTS/VLM, memory, actions, tools, MCP, watch
  mode, journals, proactivity, meeting notes, deeplinks, the plan-act-observe
  loop, and the speculative planner race. This is the canonical detailed
  architecture narrative.
- [`architecture/decisions/`](architecture/decisions/) — Architecture Decision
  Records (ADRs), numbered `NNNN-slug.md`.
  - [`0001-meeting-audio-capture.md`](architecture/decisions/0001-meeting-audio-capture.md) —
    in-process SCStream for two-track meeting capture (vs out-of-process
    CoreAudio tap).

## Product

What Pace does and where it's going.

- [`product/capabilities.md`](product/capabilities.md) — the tool catalog and
  capability classes ("what can I ask it").
- [`product/conversation-model.md`](product/conversation-model.md) — the
  two-tier in-context memory mental model (verbatim window + rolling summary).
- [`product/roadmap.md`](product/roadmap.md) — local roadmap and priorities.
- [`product/prds/`](product/prds/) — product briefs:
  - [`on-device-meeting-notes.md`](product/prds/on-device-meeting-notes.md) —
    two-track capture → segmentation → on-device transcription → structured
    notes. Wedge against Granola/Otter/Fireflies.
  - [`premium-chat-panel.md`](product/prds/premium-chat-panel.md) —
    Claude-Desktop-style primary chat surface (phase 1 shipped, phase 2
    deferred).
  - [`teachable-skills.md`](product/prds/teachable-skills.md) — teach a
    `.skill.md` skill by describing it; structured on-device.
- [`product/companion-mode-privacy.md`](product/companion-mode-privacy.md) —
  Always-On Companion Mode data boundaries and indicators.
- [`product/companion-mode-dogfood.md`](product/companion-mode-dogfood.md) —
  the live/hardware dogfood gate for Companion Mode.
- [`product/pace-wake-word-classifier.md`](product/pace-wake-word-classifier.md) —
  the bundled Core ML wake model's runtime contract.
- [`product/brand/`](product/brand/) — mascot SVGs and brand assets.
- [`product/landing/`](product/landing/) — landing-page copy drafts.

## Development

Building, testing, and navigating the codebase.

- [`development/key-files.md`](development/key-files.md) — per-file reference
  table (every source file, script, and bundled resource with purpose + line
  count). The canonical map of the codebase.
- [`development/info-plist-switches.md`](development/info-plist-switches.md) —
  every Info.plist switch that gates local VLM / planner / TTS-sidecar /
  transcription behavior, with defaults.
- [`development/test-coverage.md`](development/test-coverage.md) — EXEMPLARY
  coverage tier goals, per-component targets, local extraction, CI enforcement.
- [`../SETUP_LOCAL.md`](../SETUP_LOCAL.md) — full local-mode setup recipe
  (LM Studio, models, permissions).

## Operations

Releasing and running Pace.

- [`operations/release-smoke-checklist.md`](operations/release-smoke-checklist.md) —
  the hardware smoke checklist walked before every release. The unit suite is
  blind to hardware-boundary defects; this catches what it can't.
- [`operations/runbooks/`](operations/runbooks/) — operational runbooks:
  - [`voice-mail-latency-demo.md`](operations/runbooks/voice-mail-latency-demo.md) —
    reproducible `<700 ms` voice→Mail TTFSW measurement runbook.
- [`operations/release-notes/`](operations/release-notes/) — per-release notes.
  - [`0.3.20.md`](operations/release-notes/0.3.20.md)

## Knowledge

Durable learnings and competitive context.

- [`knowledge/learnings/`](knowledge/learnings/) — the learning roadmap: every
  novel framework, algorithm, API, and non-obvious pattern in Pace, grouped by
  theme. Start at [`knowledge/learnings/README.md`](knowledge/learnings/README.md).
  Covers: foundational frameworks, memory & retrieval, screen & vision, actions
  & accessibility, audio pipeline, planning & latency, skills & automation,
  proactive surfaces, infra & patterns.
- [`knowledge/competitive/`](knowledge/competitive/) — competitive snapshots
  and the steal-catalog (ideas to adopt, with the constraint "runs local").
  - [`steal-catalog.md`](knowledge/competitive/steal-catalog.md)
  - [`littlebird.md`](knowledge/competitive/littlebird.md)
  - [`dayflow-work-journal-snapshot.md`](knowledge/competitive/dayflow-work-journal-snapshot.md)
  - [`local-voice-assistant-snapshot.md`](knowledge/competitive/local-voice-assistant-snapshot.md)
  - [`project-minimi-rag-snapshot.md`](knowledge/competitive/project-minimi-rag-snapshot.md)
- [`knowledge/failed-approaches.md`](knowledge/failed-approaches.md) —
  approaches that were tried and rejected or deferred, with the reason. Read
  this before retrying a dead end.

## Current

The active cycle: objective, plans, and recommendation context.

- [`../STATUS.md`](../STATUS.md) — lean current-state view (objective, active
  work, blockers, open questions, next steps).
- [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md) — the full durable status
  record (timeline, shipped features, deferred/blocked, dependencies).
- [`current/PROJECT_RECOMMENDATION_CONTEXT.md`](current/PROJECT_RECOMMENDATION_CONTEXT.md) —
  fleet-wide product context for Starboard recommendations.
- [`current/plans/`](current/plans/) — active plans:
  - [`autonomous-companion-consolidation.md`](current/plans/autonomous-companion-consolidation.md) —
    the canonical handoff for the remaining companion integration gaps and five
    acceptance stories.
  - [`pace-tuned-model-v1.md`](current/plans/pace-tuned-model-v1.md) —
    pace-tuned turn collection → LoRA training pipeline.

## Archive

Point-in-time snapshots preserved for history (not maintained).

- [`archive/`](archive/) — dated local-project-state and smoke-test snapshots.
  Prefer `PROJECT_STATUS.md` for current state.

## Adjacent surfaces (not under `docs/`)

- [`../openspec/`](../openspec/) — OpenSpec specs and archived changes
  (spec-driven workflow). Specs: `ambient-perception`, `codex-direct-brain`,
  `companion-memory-policy`, `companion-mode-controls`, `meeting-note-profiles`,
  `proactive-companion-policy`, `temporal-world-model`,
  `transcript-grounded-actions`.
- [`../evals/`](../evals/) — eval fixtures and harnesses. Start at
  [`../evals/README.md`](../evals/README.md).
- [`../scripts/`](../scripts/) — build/release/eval/smoke scripts. Start at
  [`../scripts/README.md`](../scripts/README.md).
- [`../website/`](../website/) — Astro marketing site (Cloudflare Pages).
  Start at [`../website/README.md`](../website/README.md).
- [`../SETUP_LOCAL.md`](../SETUP_LOCAL.md) — local-mode setup.
