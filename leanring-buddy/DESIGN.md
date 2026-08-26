# Pace Native Design System

## North Star

**Local Signal Desk** — Pace feels like a quiet instrument already built into
the Mac. The interface makes one request visibly travel from listening, through
local understanding, into an observable action. It does not look like a chat
website, a generic AI dashboard, or a developer console.

## Surface Hierarchy

1. **Living Notch:** the idle surface is the physical camera housing, not Pace
   chrome. Hover reveals Pace; real listening, understanding, action, approval,
   speaking, permission trouble, and off-device states grow into compact wings
   attached to the measured housing's left and right sides. A deliberate click
   resizes that same clipped black surface into the complete command tray; no
   second panel is visually joined underneath it.
2. **Quick panel:** the present turn. It contains the live transcript, current
   action state, latest result, and composer. Management UI does not accumulate
   here.
3. **Command Center:** durable history and management. Conversations,
   automations, activity, privacy, permissions, and configuration share one
   navigational shell.
4. **Onboarding:** a cinematic first-use path that becomes the real product. It
   earns its motion by getting the user to a successful local command.

## Color And Material

- **Canvas:** near-black graphite (`#080A0D`), not featureless pure black.
- **Primary surface:** `#101318` with a quiet top-edge highlight.
- **Raised surface:** `#171B22`.
- **Border:** `#2A3039` at low contrast.
- **Primary text:** warm off-white (`#F1F0EC`).
- **Secondary text:** cool gray (`#A7AFBA`).
- **Muted text:** `#8B9590`, lifted above the original muted value so 9–12pt
  metadata remains above 4.5:1 on every graphite surface.
- **Local signal:** electric Pace blue (`#4F8BFF`). Blue means active local
  input, focus, selection, or the primary safe action; it is not decoration.
- **PacePad expression:** deep ocean blue (`#2A94E1`) is reserved for the
  companion face's idle eye and smile glyphs, with an ink-blue mouth core
  (`#156EAE`) on the dedicated navy canvas (`#06121E`). Electric Pace blue
  still owns active local work, controls, and trust state; the expression blue
  is not an action color.
- **Off-device:** amber (`#FFB347`) across every surface and transition.
- **Success:** green (`#34D399`) only after a completed outcome.
- **Failure:** system red only for an actual error or denied destructive state.

Depth comes from material and light rather than gradients. Native material may
soften the quick panel over the desktop, but content surfaces stay legible and
do not become translucent glass cards nested inside other glass cards.

## Typography

Use the macOS system family throughout the native product. Large moments may
use SF Pro Display semantics through SwiftUI system fonts; body, labels, and
controls use SF Pro Text semantics. SF Mono is reserved for model identifiers,
keyboard shortcuts, durations, and audit details. The editorial serif used by
the public website does not enter native controls.

Hierarchy uses semantic SwiftUI text styles so system text-size changes remain
readable: large title for rare onboarding statements, title for window and
scene titles, body/callout for working content, and caption for metadata.

## Shape And Components

- Window and panel geometry follows native macOS conventions.
- Working surfaces use 10–14pt continuous corners; pills are reserved for
  status, filters, and short values.
- The shared signal mark is a waveform or single routed line, never sparkles.
- PacePad's idle expression uses two happy signal arcs and one scanlined smile
  on the physical display. It stays abstract and screen-native rather than
  reproducing a robot chassis or a licensed character.
- PacePad renders those features as one coherent CRT material: a shallow
  full-screen bezel, low-contrast static raster, layered phosphor edges, and a
  compact state capsule. The eyes and mouth share the same light treatment;
  they must not read as unrelated flat SwiftUI symbols floating on a canvas.
- The Living Notch reads its closed width and height from the current display's
  auxiliary safe areas. Idle remains hardware-exact. Hover and runtime states
  add short horizontal wings at menu-bar height: state sits beside the left edge
  and signal beside the right, leaving the physical center visually clear. A
  deliberate click resizes the same surface symmetrically into the complete
  quick panel, clamped to display bounds. Pace never invents a center notch on
  a display without one.
- Primary buttons are compact rounded rectangles with a blue fill and dark
  label. Secondary buttons are tonal or bordered.
- Every interactive element has default, hover, pressed, focus, disabled, and
  loading behavior, plus an explicit pointer cursor where project conventions
  require it.
- Empty states teach one useful next action using real Pace language.

## Motion Grammar

Motion explains state, position, and continuity.

- **Micro interaction:** 120–180ms ease-out for hover, press, and selection.
- **State transition:** 220–360ms spring or ease-in-out for voice-state and
  panel changes.
- **Onboarding scene:** up to 700ms for the signal-path reveal and up to 1100ms
  for the final full-window-to-notch collapse. The user never waits for a
  decorative sequence before a control becomes available.
- The waveform reacts to measured audio power. Understanding and action motion
  advances only when the underlying state advances.
- A simulated shared signal shape may collapse inside the onboarding window;
  after the window closes, the real notch surface appears in the same state.
  Cross-window matched geometry is not implied.
- Under Reduce Motion, replace travel, scale, and morph effects with short
  opacity changes and immediate state labels. The complete flow remains usable.

No looping decorative animation, particle field, parallax, autonomous camera
move, or ornamental shimmer belongs in the operating interface.

## Onboarding Contract

The first-run path has four purposeful beats:

1. **Ignition:** Pace's signal wakes from the notch and states the local value
   proposition. Continue and Skip are immediately available.
2. **Permissions:** Accessibility, Screen Recording, and Microphone are
   explained in place, deep-link to the correct macOS surface, update live, and
   remain resumable. Optional permissions wait until relevant.
3. **First command:** the user speaks or types one real request. Submission uses
   the production finalized-transcript path; the UI shows Listen → Understand →
   Act without exposing internal planner jargon.
4. **Handoff:** the successful request contracts into the everyday panel and
   notch signal. Completion is persisted once and the introduction is
   replayable from Help or Settings.

The experience is skippable and never fabricates execution. If models,
permissions, or actions are unavailable, the user gets an honest readiness
state and can finish setup later.

## Command Center Information Architecture

Use one resizable management window with plain-language grouped navigation:

- **Use Pace:** Conversations, Automations, Multi-step automations, Scheduled
  tasks.
- **Activity & Privacy:** Activity history, Privacy, Permissions.
- **Customize:** General, Voice, Local models, Memory.
- **Help:** Help & diagnostics, About.

Reasoning internals, optional integrations, experimental modes, usage detail,
and developer tools live behind one Advanced controls disclosure but remain
searchable by both their visible names and descriptions. Each primary group
shows no more than four choices. The most recently selected destination is
restored, and every destination exposes a contextual plain-language
explanation. Settings remain stable, searchable, keyboard accessible, and
sized for their content.

## References And Anti-References

Material references:

- Energy's first-run journey for full-window focus, one idea per scene, and a
  visible transformation into the product.
- Raycast for command-first density and a consistent native extension surface.
- Apple macOS conventions for settings, permissions, keyboard control, and
  reduced motion.

Anti-references:

- Generic AI chat sidebars with decorative gradient bubbles.
- A flat rail of sixteen equally weighted settings destinations.
- Literal recording-studio skeuomorphism, neon cyberpunk HUDs, and motion that
  continues when nothing in the product is changing.
