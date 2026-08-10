## Why

Pace's native surfaces have grown independently. The notch has a bespoke
animated identity, the quick panel is a compact chat surface, the main window
uses a six-item navigation shell, Settings exposes sixteen flat destinations,
and first-run onboarding is a functional five-page permission form. Each piece
works, but they do not yet feel like one product or demonstrate Pace's local
listen-to-action loop at the moment a new user decides whether to trust it.

The overhaul should make the on-device signal the shared visual and interaction
language. First launch can be cinematic, but the spectacle must become the real
notch and quick-panel surfaces and get the user to one useful command quickly.

## What Changes

- Establish the Local Signal Desk design system for native Pace surfaces,
  including shared colors, typography, surface styles, status semantics, and a
  reduced-motion-aware animation grammar.
- Replace the current first-run permission walkthrough with a resumable native
  journey: ignition splash, consolidated permission channels, one real first
  command, and a full-window-to-notch handoff.
- Use the existing finalized-transcript and action paths for the first command;
  onboarding never simulates a successful action or introduces a second
  executor.
- Redesign the shipped quick panel around the present turn and the shared
  signal state while preserving voice, typed input, streaming reply, inline
  action outcome, and off-device amber disclosure.
- Replace the hard-coded decorative notch overlay with a Living Notch whose
  closed bounds come from the current display's camera-housing safe areas and
  whose hover and active states expand downward from that physical geometry.
- Consolidate the main and Settings information architecture into one Command
  Center shell with grouped destinations instead of parallel windows and a flat
  sixteen-tab rail.
- Keep onboarding skippable, replayable, keyboard accessible, truthful when a
  dependency is unavailable, and complete under macOS Reduce Motion.
- Add pure state-model and formatting tests plus Xcode-run visual and hardware
  verification. No new production dependency is required.

## Capabilities

### New Capabilities

- `native-interface-system`: One coherent native hierarchy, visual system, and
  state-driven motion language across onboarding, notch, quick panel, and the
  management window.
- `first-command-onboarding`: Resumable first launch that reaches a real local
  command and hands off into the everyday product.

### Modified Capabilities

- None.

## Impact

- Affects first-launch state and window management, native design tokens,
  permission presentation, typed/voice onboarding submission, the menu-bar
  panel, the main management window, and Settings navigation.
- Preserves the current permission service, chat session, finalized transcript
  seam, action executor, approval policy, audit behavior, and privacy boundary.
- Existing users do not see onboarding again. Their settings, conversations,
  skills, automations, and permissions require no migration.
- The public website keeps its existing editorial design system; the native
  product has a separate design authority at `leanring-buddy/DESIGN.md`.
- No deploy, migration, release, cloud service, telemetry, or production
  dependency is introduced.
