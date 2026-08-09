---
target: native Pace onboarding, panel, and Command Center
total_score: 36
max_score: 40
na_heuristics:
p0_count: 0
p1_count: 0
timestamp: 2026-08-09T13-17-25Z
slug: leanring-buddy-paceonboardingview-swift
---
Method: dual-agent (A: native_design_review · B: native_detector_review)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of System Status | 4 | State, boundary, progress, and results are consistently visible. |
| 2 | Match System / Real World | 4 | Plain language and native macOS concepts throughout. |
| 3 | User Control and Freedom | 4 | Back, skip, edit, stop, close, and retry paths are visible. |
| 4 | Consistency and Standards | 4 | One coherent graphite, blue, and amber native language. |
| 5 | Error Prevention | 3 | Risky-action prevention is source-backed but not shown in runtime evidence. |
| 6 | Recognition Rather Than Recall | 4 | Shortcuts, steps, labels, descriptions, search, and help stay visible. |
| 7 | Flexibility and Efficiency | 3 | No visible shortcut customization, favorites, or recents yet. |
| 8 | Aesthetic and Minimalist Design | 4 | Content-hugging status, grouped settings, and intentional transcript continuation. |
| 9 | Error Recovery | 3 | Failed actions route to diagnostics rather than action-specific repair. |
| 10 | Help and Documentation | 3 | Contextual help exists, but task help is not searchable. |
| **Total** | | **36/40** | **Excellent** |

## Design Specificity Verdict

The result feels authored for Pace rather than category-interchangeable. The signal/notch motif, local-versus-off-device boundary, first real command, and compact conversation panel express the product's on-device voice-agent model consistently.

The deterministic detector returned zero findings because Swift is outside its supported scan extensions. The independent native source audit found no P0 or P1 defects. Browser overlays were not applicable to the native AppKit and SwiftUI surfaces; five Xcode runtime captures were used instead.

## Overall Impression

Pace now reads as a deliberate native macOS product: cinematic where onboarding benefits, quiet during daily use, and explicit about privacy and action boundaries. The biggest remaining opportunity is deeper action-specific recovery rather than more visual polish.

## What's Working

- The onboarding journey teaches one clear loop: understand the boundary, grant only needed permissions, then run one real command.
- The panel preserves the notch signal while keeping text, voice, tool results, Stop, Settings, and Close within a compact surface.
- The Command Center makes a large capability set manageable through plain-language groups, native search, progressive disclosure, and contextual help.

## Priority Issues

- **[P2] Runtime certification for risky actions**
  - **Why it matters:** The strongest error-prevention states have not been visually exercised in the captured journey.
  - **Fix:** Capture approve, deny, and destructive-action confirmation flows from Xcode on real hardware.
  - **Suggested command:** `$impeccable audit`
- **[P2] Expert acceleration remains fixed**
  - **Why it matters:** Power users can discover the shortcut but cannot customize or favorite common paths in the visible UI.
  - **Fix:** Add shortcut customization only after validating conflicts and persistence behavior.
  - **Suggested command:** `$impeccable optimize`
- **[P2] Failure repair is generic**
  - **Why it matters:** Diagnostics helps explain a failure but does not shorten recovery for the exact failed action.
  - **Fix:** Map failed tool records to safe, action-specific retry or repair affordances.
  - **Suggested command:** `$impeccable harden`
- **[P3] Help is contextual, not task-searchable**
  - **Why it matters:** Replaying onboarding is heavier than answering a targeted setup question.
  - **Fix:** Extend Command Center search to help topics before adding a separate help center.
  - **Suggested command:** `$impeccable clarify`

## Persona Red Flags

- **First-time user:** No blocking red flag remains in the primary journey. The only gap is that a denied risky action was not part of the captured evidence.
- **Power user:** The entry shortcut is visible and configurable at launch, but not yet customizable from the UI.
- **Accessibility user:** Semantic type, keyboard actions, Reduce Motion behavior, and VoiceOver announcements are source-backed; full focus order and announcement cadence still need manual assistive-technology testing.

## Minor Observations

- Dense destinations now have section hierarchy, but future additions should not return General to a flat toggle list.
- High-priority VoiceOver announcements may need cadence tuning if rapid state transitions sound crowded in real use.

## Questions to Consider

- Should expert acceleration start with shortcut customization, recents, or favorite automations?
- Can failed actions expose one safe repair without turning the panel into a diagnostics dashboard?
- Can Command Center search answer setup questions before Pace gains a separate help surface?
