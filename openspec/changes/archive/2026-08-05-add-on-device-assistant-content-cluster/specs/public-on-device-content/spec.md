# Public on-device content

## ADDED Requirements

### Requirement: On-device assistant education cluster
The website SHALL expose canonical guides for on-device Mac assistance, screen awareness, private voice, approved Mac actions, and local meeting notes.

#### Scenario: Reader enters through a category question
- **WHEN** a reader opens any new guide
- **THEN** the page answers the question first, names relevant permissions and limitations, and links to adjacent guides and a product action

### Requirement: Trust boundaries stay explicit
The guides SHALL distinguish local processing from optional Apple, CLI, API, MCP, download, and other network paths.

#### Scenario: External planner paths are mentioned
- **WHEN** a guide describes an optional external path
- **THEN** consent, indication, auditability, and capability-specific local pins remain visible

### Requirement: Public-surface parity
Every new canonical route SHALL be registered once so the sitemap, public API, and Markdown routes expose the same path and substantive claims.

#### Scenario: Public catalogs are generated
- **WHEN** the site builds
- **THEN** all five canonical URLs and their Markdown counterparts appear without hand-maintained duplication

### Requirement: Search and accessibility integrity
Every guide SHALL include supported structured data, canonical metadata, semantic headings, keyboard-visible actions, reduced-motion-safe behavior, and responsive reading layout.

#### Scenario: Narrow and keyboard navigation
- **WHEN** a reader uses a 390-pixel viewport or keyboard navigation
- **THEN** content remains readable, no page-level horizontal overflow occurs, and focus remains visible
