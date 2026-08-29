## Purpose

Let a user narrow intent by pointing at part of the screen and receive a bounded,
interaction-scoped, fully on-device evidence packet bound to the exact display,
window, and element they meant.

## ADDED Requirements

### Requirement: A highlight gesture produces a bound spatial packet
The system SHALL provide a configurable hold-to-highlight chord using a
listen-only event tap, SHALL render the sampled trail in a non-activating
overlay, and SHALL produce one versioned spatial context packet on release bound
to the display and to the exact hovered window identity.

#### Scenario: Chord is held and released
- **WHEN** the user holds the highlight chord, draws a trail, and releases
- **THEN** a visible trail is rendered during the gesture
- **AND** one packet is produced containing the display identity, the sampled trail, and the hovered window's process id, window id, bundle identifier, name, title, and frame

#### Scenario: Trail crosses displays
- **WHEN** a gesture spans more than one display
- **THEN** the packet records the display each sampled region belongs to
- **AND** does not silently attribute the gesture to the main display

#### Scenario: No window under the gesture
- **WHEN** the gesture ends over no identifiable window
- **THEN** Pace returns a typed refusal instead of an unbound packet

#### Scenario: Two regions in one interaction
- **WHEN** the user indicates a source and a destination within one bounded interaction
- **THEN** the packet represents them as two distinct named regions
- **AND** representing a destination does not by itself authorize any move or drag action

### Requirement: Every packet field carries provenance and a coordinate space
The system SHALL tag each packet field with its provenance and privacy
classification, and SHALL state the coordinate space of every geometric value.

#### Scenario: Geometry is recorded
- **WHEN** any point, region, or frame is written into a packet
- **THEN** its coordinate space and display are recorded with it

#### Scenario: Coordinate space is unknown
- **WHEN** the coordinate space of a value cannot be determined
- **THEN** the packet is invalid
- **AND** Pace refuses rather than assuming a default space

#### Scenario: Display scaling differs across displays
- **WHEN** displays have different backing scale factors
- **THEN** point-based and pixel-based evidence in the packet remain individually convertible to each other within the documented tolerance

#### Scenario: Evidence source is recorded
- **WHEN** a packet contains element, text, or image evidence
- **THEN** each item records whether it came from Accessibility, text selection, optical character recognition, or a screen capture

### Requirement: Accessibility evidence is preferred over pixels
The system SHALL prefer Accessibility element and text-selection evidence over
image evidence when both are available for the same region.

#### Scenario: Element is exposed through Accessibility
- **WHEN** the intersected region maps to an Accessibility element
- **THEN** the packet records its identifier, role, subrole, label, value shape, frame, and ancestor fingerprint
- **AND** image evidence is supplementary rather than primary

#### Scenario: Region is Accessibility-sparse
- **WHEN** the region exposes no useful Accessibility element, such as a canvas surface
- **THEN** the packet records the crop and local optical character recognition text
- **AND** marks the element evidence as absent rather than inferred

### Requirement: Secure and out-of-scope content is excluded from capture
The system SHALL exclude secure text from capture and serialization to the
extent macOS and the host application expose secure status, SHALL suppress
capture while system secure input mode is active, and SHALL refuse rather than
guess when secure status for a text-bearing field is unknown.

#### Scenario: Secure text field is targeted
- **WHEN** the intersected element is a secure text field or has a secure-marked ancestor
- **THEN** no value or selected-text evidence is captured or serialized for it

#### Scenario: System secure input mode is active
- **WHEN** system secure input mode is active
- **THEN** capture is suppressed
- **AND** the packet reports suppression rather than returning empty evidence as though nothing were present

#### Scenario: Secure status cannot be determined
- **WHEN** a text-bearing field's secure status cannot be determined
- **THEN** Pace refuses to capture its text content
- **AND** records that the field was skipped for that reason

#### Scenario: Pace's own surfaces are on screen
- **WHEN** a Pace overlay is within the captured region
- **THEN** it is excluded from the captured image

### Requirement: Packets are bounded, ephemeral, and local
The system SHALL scope a packet to its interaction, SHALL hold full-screen and
full-window captures in memory only, SHALL persist nothing beyond explicitly
approved evidence, and SHALL produce no network egress.

#### Scenario: Packet is created
- **WHEN** a packet is created
- **THEN** no full-screen or full-window image is written to disk
- **AND** the trail sample count, region count, text length, and crop size stay within fixed caps

#### Scenario: Interaction ends
- **WHEN** the interaction a packet serves ends
- **THEN** the packet and its in-memory captures are released

#### Scenario: Capture, interpretation, and reuse
- **WHEN** a packet is created, interpreted, or used to resolve a target
- **THEN** all processing happens on the Mac
- **AND** no packet content is sent to any network destination

### Requirement: A gesture narrows intent without granting authority
The system SHALL keep the existing action approval policy authoritative for any
request derived from a spatial packet.

#### Scenario: Read-only request
- **WHEN** the user asks what the highlighted thing is
- **THEN** Pace answers from packet evidence without performing an action

#### Scenario: Mutating request
- **WHEN** a request derived from a packet would perform a mutating action
- **THEN** it passes through the existing approval and preflight path unchanged
- **AND** the gesture alone does not authorize it

#### Scenario: Event tap is disabled or unauthorized
- **WHEN** the event tap is disabled, times out, or its authorization is revoked
- **THEN** Pace reports that the highlight chord is unavailable
- **AND** does not silently ignore the chord
