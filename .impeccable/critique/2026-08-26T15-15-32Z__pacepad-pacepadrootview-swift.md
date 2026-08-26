---
target: PacePad cohesive CRT material
total_score: 36
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 0
audit_score: 20
audit_maximum: 20
timestamp: 2026-08-26T15-15-32Z
slug: pacepad-pacepadrootview-swift
---
# PacePad cohesive CRT material critique

Method: dual-agent (A: fullscreen_design_review; B: fullscreen_detector_audit)

## Design health

| Heuristic | Score | Result |
| --- | ---: | --- |
| Visibility of system status | 4 | Connection, privacy, pause, and trust state remain explicit. |
| Match with the real world | 4 | The full iPad now reads as one friendly CRT display rather than loose symbols. |
| User control and freedom | 3 | Full-face talk/interrupt behavior and immediate privacy pause remain available. |
| Consistency and standards | 4 | One raster plane and one core-plus-bloom language unify every expression. |
| Error prevention | 3 | Recovery paths remain guarded and amber is no longer overloaded. |
| Recognition rather than recall | 4 | The face and compact state readout make the primary action immediate. |
| Flexibility and efficiency | 3 | The whole face is the primary control; detailed controls stay secondary. |
| Aesthetic and minimalist design | 4 | The asymmetric bezel, restrained raster, and phosphor marks feel authored without adding chassis ornament. |
| Error recognition and recovery | 4 | Recoverable failures use system red and actionable recovery. |
| Help and documentation | 3 | Contextual guidance remains visible without turning the companion into a dashboard. |
| **Total** | **36/40** | **Excellent** |

## Resolved polish gap

The first material pass still rendered separate background, eye, and mouth
effects. The final pass removes feature-local scanline loops and white outline
stacks, then places one display-scale-aware raster over the complete face plane.
Every phosphor mark now uses one crisp core and one soft bloom. The state readout
is flattened into the screen, and the bezel uses an upper reflection with a
darker lower falloff instead of two equal rounded borders.

## Technical audit

- Native audit: 20/20.
- P0: 0.
- P1: 0.
- The raster is a single batched asynchronous Canvas outside `TimelineView`,
  tied to display scale, non-interactive, and accessibility-hidden.
- Reduce Motion, bounded frame cadence, ambient dimming, and pixel relocation
  remain intact.
- Amber is exclusive to off-device planning/speaking; unavailable and
  disconnected states are neutral, while recoverable errors use system red.
- Native SwiftUI target: browser overlay and web aesthetic detector are not
  applicable.

## Remaining evidence boundary

Portrait idle and listening evidence are direct simulator renders. Physical
iPad brightness, camera-capture moire, thermal behavior, landscape rotation,
Display Zoom, and 12-hour foreground longevity remain hardware gates rather
than source-visible design blockers.
