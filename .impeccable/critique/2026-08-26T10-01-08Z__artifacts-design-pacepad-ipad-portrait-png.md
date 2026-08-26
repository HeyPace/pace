---
score: 33
maximum: 40
p0: 0
p1: 0
audit_score: 16
audit_maximum: 20
timestamp: 2026-08-26T10-01-08Z
slug: artifacts-design-pacepad-ipad-portrait-png
---
# PacePad Companion Surface critique

The preserved Local Signal Desk direction is now recognizably Pace: a graphite
notch body, glowing tall eyes with catchlights, a gentle smile, local blue, and
off-device amber. The native iPad composition stays calm at room distance while
keeping privacy and recovery controls available at touch distance.

## Final assessment

- Nielsen score: 33/40
- Native audit score: 16/20
- P0: 0
- P1: 0 after the finishing fixes

## P1 fixes completed

- Processing turns receive the Mac trust tier immediately, so off-device work
  turns the face and state label amber before the answer arrives.
- The face is interactive only while idle or listening. Disconnected state has
  explicit retry, pairing, and stale-credential recovery actions.
- Response text persists until the next turn, scrolls without truncation, and
  is announced to VoiceOver.
- Pairing hides the underlying UI from accessibility, exposes modal semantics,
  moves accessibility focus to the labeled code field, and can be dismissed.
- AV capture configuration and start/stop work run on a utility queue. Sensor
  labels reflect actual recording/capture state and camera failures are visible.
- Vision and requested JPEG orientation follows the active iPad scene.
- Errors restore an actionable state, while pause and night mode suppress late
  assistant and proactive speech, including delayed proactive transitions.

## Remaining evidence boundary

The screenshot is a direct SwiftUI simulator render. Physical-iPad permissions,
signing, rotation, reconnection, thermals, and the 12-hour foreground soak remain
hardware dogfood gates, not design blockers.
