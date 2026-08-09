---
target: Pace native interface overhaul
total_score: 25
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 4
timestamp: 2026-08-09T10-41-16Z
slug: leanring-buddy-paceonboardingview-swift
---
# Native Interface Critique

Method: dual-agent (A: native_design_review · B: native_detector_review)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3 | Truthful states, but successful output auto-dismissed too quickly. |
| 2 | Match system / real world | 2 | Planner and integration terminology leaks into first-use copy. |
| 3 | User control and freedom | 2 | Skip and replay existed, but successful output had no user-controlled handoff. |
| 4 | Consistency and standards | 2 | Shared signal is strong; token and detail-wrapper drift remained. |
| 5 | Error prevention | 3 | Real path and disabled empty input prevent false tutorial success. |
| 6 | Recognition rather than recall | 3 | Suggestion, labels, search, and grouped navigation are visible. |
| 7 | Flexibility and efficiency | 3 | Voice, text, hotkeys, search, replay, and route persistence coexist. |
| 8 | Aesthetic and minimalist design | 3 | Focused surface hierarchy; Command Center still exposes many destinations. |
| 9 | Error recovery | 2 | Recovery routed every failure to Permissions. |
| 10 | Help and documentation | 2 | Replay and hints exist; contextual runtime recovery was weak. |
| **Total** | | **25/40** | **Acceptable before hardening** |

## Design Specificity Verdict

The Local Signal Desk is strongly authored for Pace. The persistent notch,
present-turn panel, real first command, shared blue/amber boundary language,
and grouped Command Center arise from the product's macOS and privacy model.
They would not transfer unchanged to a generic assistant.

The deterministic detector returned zero findings because its scanner omits
Swift files. Browser overlay work was inapplicable to AppKit/SwiftUI surfaces;
static native source inspection was the fallback.

## Overall Impression

The concept is distinctive and coherent, but the pre-hardening build cut off
its activation peak and contained several trust and accessibility defects. The
largest opportunity was to make the real result—not the animation—the climax.

## What's Working

- Nine semantic states, reduced-motion policy, and off-device amber form a real product language.
- Onboarding submits an editable typed or spoken request through the production path.
- The notch, present-turn panel, and Command Center have disciplined ownership boundaries.

## Priority Issues

1. **P1 — Boundary continuity:** Handoff hard-coded local blue and could claim an off-device answer ran on the Mac. Preserve the request boundary through completion.
2. **P1 — User-controlled activation peak:** The result auto-dismissed after 900 ms. Hold it until Continue to Pace, with a secondary retry.
3. **P1 — Accessibility:** Preserve permission-button semantics, label icon-only actions, enlarge compact targets, raise tertiary contrast, and expose a keyboard/accessibility notch action.
4. **P1 — Recovery intent:** Route permission, model, voice, MCP, bridge, and diagnostic failures to the relevant destination rather than always opening Permissions.
5. **P2 — Command Center density:** Twenty-one visible destinations still need progressive disclosure after dogfood evidence.

## Persona Red Flags

- **Alex:** The automatic result handoff prevented inspection and retry; the long destination list lacks recents or favorites.
- **Jordan:** Planner and bridge terminology requires prior knowledge, and generic permission recovery misdiagnosed failures.
- **Sam:** Compact unlabeled icon controls, combined permission rows, muted-text contrast, and a mouse-only notch blocked confident access.

## Minor Observations

- Generated probes are more neon and HUD-like than the quiet native authority.
- Continuous non-audio signal travel should be profiled and simplified if it costs idle energy.
- Fixed native window typography needs Xcode-run large-text and VoiceOver verification.

## Questions to Consider

- Is the activation peak the animation, or undeniable proof that Pace completed the request?
- Does a user need 21 subsystem nouns, or four questions: what can Pace do, what did it do, what can it access, and how should it behave?
- What remains distinctive after every non-semantic glow is removed?
