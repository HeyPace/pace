---
target: PacePad deep-blue CRT companion face
total_score: 36
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 0
audit_score: 20
audit_maximum: 20
timestamp: 2026-08-26T14-45-14Z
slug: pacepad-pacepadrootview-swift
---
# PacePad deep-blue CRT companion critique

Method: dual-agent (A: fullscreen_design_review; B: fullscreen_detector_audit)

## Design health

| Heuristic | Score | Result |
| --- | ---: | --- |
| Visibility of system status | 4 | Connection, privacy, pause, state, and off-device trust remain explicit. |
| Match with the real world | 4 | The happy screen expression and full-face tap are understood immediately. |
| User control and freedom | 3 | Speech stops immediately; pending iPad output is truthfully dismissible. |
| Consistency and standards | 4 | Native controls and Pace signal semantics remain coherent. |
| Error prevention | 3 | Permission and recovery safeguards remain strong. |
| Recognition rather than recall | 4 | One obvious primary action and labeled privacy state. |
| Flexibility and efficiency | 3 | Full-face interaction is immediate; detailed controls stay secondary. |
| Aesthetic and minimalist design | 4 | Rich blue light and a restrained CRT smile own the viewport without becoming ominous. |
| Error recognition and recovery | 4 | Failures stay announced and actionable. |
| Help and documentation | 3 | Ambient guidance is contextual; broader help stays off this screen. |
| **Total** | **36/40** | **Excellent** |

## Design specificity

The refinement preserves the supplied reference's emotional cues—happy crescent
eyes, an open luminous smile, and CRT scanlines—while moving from bright cyan to
an inkier Pace-specific palette. The iPad remains the physical body rather than
reproducing a robot shell. The navy screen, ocean-blue idle expression, brighter
electric-blue active state, and amber off-device state maintain a semantic color
hierarchy instead of treating blue as decoration.

## Technical audit

- Native audit: 20/20.
- P0: 0.
- P1: 0.
- Idle blue contrast: 5.77:1 on the companion canvas.
- Active blue contrast: 5.81:1; off-device amber contrast: 10.59:1.
- The darker mouth core is 3.48:1 as a large decorative shape and retains a
  brighter outline. Scanline opacity was reduced after review to protect the
  happy open-mouth mass in brighter rooms.
- Native SwiftUI target: browser overlay and web aesthetic detector are not
  applicable.
- Motion, rendering cadence, ambient dimming, and pixel relocation remain
  bounded for an always-on foreground surface.

## Remaining evidence boundary

The portrait and listening-state images are direct simulator renders. A real
iPad still needs landscape, Display Zoom, permission, thermal, burn-in, and
12-hour foreground validation. Those are hardware gates, not source-visible
design blockers.
