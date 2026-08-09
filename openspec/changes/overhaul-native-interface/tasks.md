## 1. Native Foundation

- [x] 1.1 Add the Local Signal Desk native tokens, shared signal-state mapping, boundary color roles, and reduced-motion-aware motion policy.
- [x] 1.2 Add the code-native reusable signal/notch visuals with explicit idle teardown and accessibility-hidden decorative geometry.
- [x] 1.3 Add pure tests for every signal state, local/off-device precedence, motion policy, semantic label, and interruption outcome.

## 2. Cinematic First-Command Onboarding

- [x] 2.1 Replace Boolean-only onboarding progression with a versioned, resumable pure state model that migrates existing completion without replaying onboarding.
- [x] 2.2 Build the ignition and consolidated live-permission scenes with immediate skip/continue controls, cancellable auto-advance, keyboard focus, and honest permission recovery.
- [x] 2.3 Build the editable first-command scene and submit through the existing finalized-transcript path without adding a parser or executor.
- [x] 2.4 Classify real response, action, approval, blocked, and failure outcomes; play the handoff only for a truthful first-value outcome.
- [x] 2.5 Implement the in-window signal-to-notch collapse, real overlay reveal, reduced-motion alternative, replay entry point, and safe teardown.
- [x] 2.6 Add pure tests for persistence migration, resume/skip, permission events, delayed-task cancellation, first-command outcome classification, and replay behavior.

## 3. Everyday Notch And Quick Panel

- [x] 3.1 Apply the shared signal roles and motion grammar to the real menu-bar overlay while preserving amber off-device disclosure and current permission status.
- [x] 3.2 Redesign the shipped `PacePanelChatView` around the live turn, signal stage, transcript, inline outcomes, and composer using the native design authority.
- [x] 3.3 Route management actions to exact Command Center destinations and keep the panel's focus, dismissal, scroll, and voice/typed transcript behavior intact.
- [x] 3.4 Add focused pure/view-model tests for idle, listening, understanding, approval, acting, speaking, completed, blocked, failed, and empty panel states.
- [x] 3.5 Replace the rejected fixed-width notch treatments with hardware-derived Living Notch geometry, downward hover/active expansion, panel anchoring, display/wake recalculation, and a no-notch fallback.
- [x] 3.6 Add pure geometry and display-mode tests for valid housing bounds, hover/active sizing, invalid/no-notch displays, and state-driven expansion.
- [x] 3.7 Make click presentation resize one clipped notch surface symmetrically into the complete quick panel and collapse on every dismissal path.
- [x] 3.8 Reserve the measured housing width in the header, place state and signal beside it, and route notched-display panel requests into the integrated surface.

## 4. Grouped Command Center

- [x] 4.1 Define grouped Command Center destinations and deterministic restoration/routing behavior with pure tests.
- [x] 4.2 Replace the main-window shell with Work, Observe, Configure, and Diagnostics groups while reusing existing content views.
- [x] 4.3 Turn `PaceSettingsWindowManager` into a compatibility router to the same Command Center window and migrate existing call sites.
- [x] 4.4 Add search or direct destination affordances so all current settings remain reachable without a flat sixteen-tab list.
- [x] 4.5 Verify window reuse, requested-destination routing, keyboard navigation, resizing, and last-selection restoration.
  - Xcode dogfood kept one Command Center window across close/reopen, routed the panel's Open Permissions action to the exact Permissions destination, selected Automations through keyboard search, and resized from 1040 x 700 to 900 x 600 and back. The stored `skills` destination and request-overrides-store behavior also passed the focused router tests. Dogfood exposed and fixed the unbounded Automations catalog layout before closure.

## 5. Documentation And Verification

- [x] 5.1 Update architecture, native key-file, test-coverage, capability, and onboarding documentation after implementation behavior settles.
- [x] 5.2 Run focused isolated test groups after each layer, strict OpenSpec validation, documentation validation, and `git diff --check`.
- [x] 5.3 Run the full isolated suite and update `PROJECT_STATUS.md` only after automated checks establish durable current truth.
- [x] 5.4 From an Xcode-launched app, exercise fresh install, legacy completion migration, partial permissions, skip/resume, typed first command, voice first command, reduced motion, VoiceOver focus order, action approval/failure, off-device amber, and existing-user startup.
  - The reversible Xcode matrix covered first-run ignition, a 0-of-3 partial-permission state, checkpoint resume, skip completion, legacy-complete startup without replay, and existing-user startup; the three onboarding defaults were restored exactly afterward. `Open Calculator` exercised the typed production path and surfaced the honest local-planner-unavailable recovery state. The voice path reached the real missing-permission boundary without claiming a transcript. AX traversal verified the first-command reading order and keyboard field entry. The real runtime smoke displayed and cancelled the native approval dialog, recorded denial, and exercised the synthetic failure path. The protected system Reduce Motion switch and off-device boundary were not mutated; their crossfade and amber-precedence branches passed the focused pure model coverage in the same build.
- [x] 5.5 Capture final native onboarding, panel, and Command Center evidence; run Impeccable critique, polish, and native audit; fix all P0/P1 findings and complete the design-review receipt with owner feedback.
  - Final evidence includes the onboarding, Living Notch panel, and `artifacts/design/native-overhaul/command-center-automations-final.png`. The stored dual-agent Impeccable critique is 36/40, the independent native audit is 18/20, and both report zero P0/P1 defects. The design-review receipt passes and records the owner's final `keep` decision from “Nice now it looks good.”
