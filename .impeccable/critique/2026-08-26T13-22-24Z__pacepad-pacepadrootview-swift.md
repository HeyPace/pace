---
target: friendly blue CRT PacePad face
total_score: 36
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 0
audit_score: 20
audit_maximum: 20
timestamp: 2026-08-26T13-22-24Z
slug: pacepad-pacepadrootview-swift
---
# PacePad friendly CRT companion critique

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
| Aesthetic and minimalist design | 4 | Cyan eye arcs and a raster smile own the viewport without copying the robot body. |
| Error recognition and recovery | 4 | Failures stay announced and actionable. |
| Help and documentation | 3 | Ambient guidance is contextual; broader help stays off this screen. |
| **Total** | **36/40** | **Excellent** |

## Design specificity

The expression carries the supplied reference's emotional cues: happy crescent
eyes, an open luminous smile, cyan emission, and CRT scanlines. The iPad remains
the physical body, so the result does not reproduce the reference robot shell.
Pace-specific trust HUD, edge signals, blue/amber state grammar, and ambient
behavior keep the complete surface from becoming a generic mascot.

## Technical audit

- Native audit: 20/20.
- Detector: zero findings for `PacePad/PacePadRootView.swift`.
- Browser overlay: not applicable to compiled native SwiftUI.
- P0: 0.
- P1: 0 after making the five-minute dimmed state wake-only. Hidden controls
  are now non-hittable and accessibility-hidden, and the first face tap only
  restores visibility without starting microphone capture.

## Remaining evidence boundary

The portrait and listening-state images are direct simulator renders. A real
iPad still needs landscape, Display Zoom, permission, thermal, burn-in, and
12-hour foreground validation. Those are hardware gates, not source-visible
design blockers.
