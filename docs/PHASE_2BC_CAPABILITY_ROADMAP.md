# Phase 2BC — Semantic Capability Discovery & Roadmap

## Baseline

- **Baseline Commit**: `78de5e1` (`feat: add semantic combo box enumeration`)
- **Authoritative Capability Count Before Phase 2BC**: `50` (derived directly from `QModelPlanSchema.swift`)
- **Target Capability Count After Phase 2BC**: `51`

## Discovery Methodology

1. Inspected actual capability registry in `QModelPlanSchema.swift`.
2. Inspected macOS SDK headers (`HIServices/AXRoleConstants.h`, `AXAttributeConstants.h`, `AXActionConstants.h`).
3. Evaluated AppKit controls (`NSRulerView`, `NSDatePicker`, `NSComboBox`, `NSStepper`, etc.) and their accessibility interfaces.
4. Scored all discovered candidates using the standard 9-dimension model (total 100 points).

## Candidate Scoring Matrix

| Candidate | Role | Type | AX Authority (20) | Target Identity (15) | Verification (15) | Usefulness (15) | Security (10) | Testability (10) | Recovery (5) | Privacy (5) | Architecture Fit (5) | Total (/100) | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `ui.list_rulers` | `AXRuler` | Read-Only | 20 | 15 | 15 | 15 | 10 | 10 | 5 | 5 | 5 | **100** | **SELECTED** |
| `ui.set_incrementor_value` | `AXIncrementor` | Mutation | 18 | 14 | 14 | 13 | 9 | 10 | 4 | 5 | 5 | **92** | Deferred |
| `ui.select_combo_box_item` | `AXComboBox` | Mutation | 18 | 14 | 14 | 13 | 8 | 9 | 4 | 5 | 5 | **90** | Deferred |
| `ui.list_help_tags` | `AXHelpTag` | Read-Only | 17 | 12 | 13 | 10 | 10 | 9 | 5 | 5 | 4 | **85** | Deferred |
| `ui.list_matte_controls` | `AXMatte` | Read-Only | 16 | 12 | 12 | 8 | 10 | 9 | 5 | 5 | 4 | **81** | Deferred |
| `ui.list_handles` | `AXHandle` | Read-Only | 16 | 12 | 12 | 8 | 10 | 8 | 5 | 5 | 4 | **80** | Deferred |
| `ui.scroll_page` | `AXScrollArea` | Mutation | 15 | 11 | 11 | 12 | 8 | 8 | 4 | 5 | 4 | **78** | Deferred |

## Selected Capability

- **Identifier**: `ui.list_rulers`
- **Security Level**: Level 0 (Read-Only)
- **AX Role**: `kAXRulerRole` (`"AXRuler"`)
- **Reason for Selection**: Highest scoring candidate (100/100) with complete deterministic identity, authoritative native AppKit backing (`NSRulerView`), high agent utility for document / canvas layout inspection and unit verification, and zero mutation risk.
