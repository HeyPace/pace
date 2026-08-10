# native-interface-system Specification

## Purpose
Give Pace one recognizable, accessible native interaction system from ambient
notch status through daily operation and deeper management.
## Requirements
### Requirement: Native surfaces share one truthful state language
The system SHALL represent the same voice, execution, permission, and planner
boundary states consistently across the notch, quick panel, onboarding, and
Command Center.

#### Scenario: Local request advances
- **WHEN** a request moves from listening to understanding to action and completion
- **THEN** each visible native surface uses the shared local-signal semantics
- **AND** no surface invents a conflicting label or color for the same state

#### Scenario: Off-device planner runs
- **WHEN** an explicitly enabled off-device planner tier is in flight
- **THEN** every visible active-state treatment uses the shared amber disclosure
- **AND** blue is not used in a way that implies the turn remained fully local

#### Scenario: Action fails or needs approval
- **WHEN** the production action path reports failure or requests approval
- **THEN** the interface shows that real state without a success animation
- **AND** the user can inspect or act on the existing result or approval control

### Requirement: The Living Notch follows physical display geometry
The system SHALL derive the notch surface from the current display's camera
housing rather than a hard-coded decorative width.

#### Scenario: Notched display is idle
- **WHEN** the selected display exposes a non-zero top safe inset and left and right auxiliary areas
- **THEN** Pace's idle surface matches the physical housing gap and height
- **AND** it adds no persistent waveform, outline, side wings, or status rail

#### Scenario: Pace becomes active
- **WHEN** Pace listens, understands, waits for approval, acts, speaks, becomes blocked, or fails
- **THEN** the surface grows compact horizontal wings from the physical housing's left and right edges
- **AND** state occupies the left wing while signal occupies the right wing
- **AND** it shows the shared state label and local or off-device signal role

#### Scenario: Pointer discovers Pace
- **WHEN** the pointer enters the idle physical notch bounds
- **THEN** compact wings extend from the physical housing's sides to expose a Pace affordance
- **AND** leaving returns it to the hardware-exact idle state when no runtime state is active

#### Scenario: User opens the quick panel
- **WHEN** the user clicks the Living Notch or invokes its accessibility action
- **THEN** the side wings extend equally left and right from the physical housing
- **AND** the same clipped surface extends downward to reveal the quick-panel content
- **AND** no second AppKit panel or joining seam is visible
- **AND** closing or outside-click dismissal returns the notch to the correct idle, hover, or active width

#### Scenario: Display has no camera housing
- **WHEN** no valid auxiliary safe-area gap exists
- **THEN** Pace does not draw a synthetic center notch
- **AND** the configured global shortcut remains available to open the quick panel

#### Scenario: Display geometry changes
- **WHEN** the Mac wakes or its display arrangement, scale, or primary display changes
- **THEN** Pace recomputes and repositions the Living Notch from current `NSScreen` geometry
- **AND** no stale fixed screen coordinate remains in use

### Requirement: Motion communicates state and respects accessibility
The system SHALL use motion only to explain state, continuity, or direct
interaction and SHALL provide a complete reduced-motion presentation.

#### Scenario: Voice state changes
- **WHEN** listening, understanding, acting, or speaking state changes
- **THEN** the shared signal animation advances in response to that state
- **AND** it does not continue as a decorative loop after the state becomes idle

#### Scenario: Reduce Motion is enabled
- **WHEN** macOS Reduce Motion is enabled
- **THEN** travel, morph, and scale animations are replaced by short opacity or immediate state changes
- **AND** all labels, controls, progress, and outcomes remain available

#### Scenario: Animation is interrupted
- **WHEN** a window closes, the app resigns active, or the underlying state changes during an animation
- **THEN** the animation resolves to the newest valid product state
- **AND** no delayed task restores a stale onboarding or voice state

### Requirement: The quick panel owns only the present turn
The system SHALL keep the menu-bar panel focused on the current interaction and
route durable management to the Command Center.

#### Scenario: User opens the idle panel
- **WHEN** there is no active turn
- **THEN** the panel shows readiness, one concise starter action, recent context only when useful, and the composer
- **AND** it does not expose a dashboard of unrelated configuration sections

#### Scenario: User speaks or types
- **WHEN** a voice or typed transcript is active
- **THEN** the panel gives the live transcript and current signal stage visual priority
- **AND** completed tool outcomes remain inline with the conversation

#### Scenario: User needs management
- **WHEN** the user opens history, automations, privacy, permissions, models, or other configuration
- **THEN** Pace opens the relevant Command Center destination
- **AND** the quick panel dismisses without losing the active conversation state

### Requirement: Management uses one grouped Command Center
The system SHALL provide one resizable native management shell for work,
observation, trust, and configuration destinations.

#### Scenario: User opens Pace management
- **WHEN** the user chooses Open Pace or Settings
- **THEN** Pace reuses one Command Center window
- **AND** navigates to the requested destination rather than opening parallel management windows

#### Scenario: User scans destinations
- **WHEN** the Command Center sidebar is visible
- **THEN** destinations are grouped by Work, Observe, and Configure
- **AND** the interface does not present all settings as one undifferentiated flat list

#### Scenario: User returns
- **WHEN** the Command Center reopens
- **THEN** it restores the most recently viewed valid destination
- **AND** window resizing and keyboard navigation follow macOS conventions

### Requirement: Native interface behavior is testable without hardware
The system SHALL isolate navigation, display-state, animation-policy, and
onboarding progression decisions from microphone, screen-recording, and
Accessibility hardware boundaries.

#### Scenario: Pure display-state fixture
- **WHEN** a test supplies a voice state, planner boundary, permission state, and Reduce Motion preference
- **THEN** the exact semantic label, color role, and animation policy are observable without launching a live subsystem

#### Scenario: Command Center routing fixture
- **WHEN** a test supplies a destination and prior selection
- **THEN** grouping, route resolution, and restored selection are deterministic
