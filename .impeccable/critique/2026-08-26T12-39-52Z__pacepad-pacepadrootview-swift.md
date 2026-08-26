---
target: full-screen always-on PacePad ambient mode
score: 35
maximum: 40
p0: 0
p1: 0
audit_score: 20
audit_maximum: 20
timestamp: 2026-08-26T12-39-52Z
slug: pacepad-pacepadrootview-swift
---
# PacePad full-screen ambient companion critique

The iPad is now the character body rather than a frame around a mascot. The
ambient composition is edge-to-edge with hidden system chrome, a quiet privacy
rail, warm-white idle signal, and blue or amber light reserved for active local
or off-device work. Detailed controls remain hidden until requested.

## Final assessment

- Nielsen score: 35/40
- Native audit score: 20/20
- P0: 0
- P1: 0
- Detector findings: 0; browser-only overlays are not applicable to compiled
  native SwiftUI.

## Handoff blockers closed

- Removed the inset screen-within-screen outline and routed active state light
  along the physical display edges while suppressing persistent system chrome.
- Replaced decorative idle blue, cheeks, and catchlights with a neutral routed
  signal grammar. Blue now means active local work; amber means off-device.
- The full face stops active speech. Processing and transcription can be
  truthfully dismissed on the iPad, including suppression of a late response;
  the interface states that Mac-side work may continue in V1.
- Permission, capture, and connection failures expose relevant recovery actions
  and announce their guidance to VoiceOver.
- Five-minute low-energy dimming, one-minute ambient animation cadence, and
  eight-minute pixel relocation reduce always-on display risk. Night-mode
  brightness is restored through background transitions using the exact screen
  that Pace dimmed.
- VoiceOver and Switch Control prevent automatic drawer dismissal. Compact and
  accessibility layouts use a two-column control grid, wrapped labels, expanded
  control height, and matching message clearance.

## Remaining evidence boundary

The screenshot is a direct SwiftUI simulator render and production iPad source
type-checks successfully. Physical-device permissions, signing, thermal load,
burn-in behavior, reconnection, and the 12-hour foreground soak remain dogfood
gates rather than design blockers. True Mac-side turn cancellation is a P2
protocol capability; V1 does not claim it.
