# Phase 2BN — Semantic Element Title Reference Read (`ui.read_element_title_reference`)

## Overview
- **Capability Identifier**: `ui.read_element_title_reference`
- **Tool Family**: `ui` (title/identifier are short structural labels — never free-form typed content requiring the `perception` sanitize-before-persist boundary)
- **Risk Level**: Level 0 Read-Only (`.level0ReadOnly`)
- **Baseline Commit**: `0802216`
- **Pre-Phase Capability Count**: `61`
- **Post-Phase Capability Count**: `62`
- **Mutability**: None — purely observational, zero AX writes, zero AX actions, zero interaction with either element.
- **User Approval**: None required (Level 0).
- **Recovery Requirement**: None — a read that does not throw IS its own result; a retry is always safe.

**Why this capability closes a real gap**: no existing capability reads any cross-element semantic relationship — every existing read capability reads an element's own attributes (`ui.read_element_value`, `ui.list_element_attributes`) or lists its own children/rows/items (the twenty-odd `ui.list_*` capabilities). `kAXTitleUIElementAttribute` — the AX reference to whichever element serves as a target's title/label — was identified in Phase 2BN's discovery (98/100, the highest-scoring candidate across all nine considered) as a structurally new category of information: it lets the model resolve labels for otherwise-untitled controls (e.g. a text field labeled by a preceding `AXStaticText`) without OCR, screenshots, or coordinate-based visual proximity guessing — directly aligned with this program's on-device, semantic-only automation posture.

---

## Semantic Accessibility Contract
- **Source element**: exactly one element on `QAXElementReadRolePolicy`'s existing allowlist (Phase 2J, reused unmodified — `AXTextField, AXTextArea, AXStaticText, AXButton, AXCheckBox, AXRadioButton, AXPopUpButton, AXMenuButton, AXMenuItem, AXComboBox, AXSlider, AXStepper, AXLink, AXTab, AXDisclosureTriangle`), resolved via the existing `collectMatches`/`snapshotIfMatches` bounded-search primitives (caller-supplied `role` + `identifier`/`title`) — identical pattern to `ui.read_element_value`/`ui.list_element_actions`.
- **Referenced title element**: the `AXUIElementRef` value of `kAXTitleUIElementAttribute`, independently re-validated against the SAME `QAXElementReadRolePolicy` allowlist — no new, broader, or artificial allowlist is introduced for either side of the relationship.
- **AX API**: `AXUIElementCopyAttributeValue(targetElement, kAXTitleUIElementAttribute, ...)` — a single, purely observational call yielding an `AXUIElementRef` reference (or absence), followed by exactly two further reads on the referenced element (`kAXRoleAttribute` for role validation, then `kAXTitleAttribute`/`AXIdentifier` for structural identity) — never descending into the referenced element's own children.
- **Mutation primitives**: none. `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `CGEvent`, keyboard/mouse simulation, coordinates, OCR, screenshots, and network access are all absent from the implementation — confirmed by direct diff audit (0 actual usages of any kind, including in comments).

---

## The Missing-vs-Failure Design Decision
Following the exact discipline established in Phase 2BM, macOS's `AXError` distinguishes genuine attribute absence from an actual communication/API failure:

| `AXError` | Meaning | Treatment |
|---|---|---|
| `kAXErrorNoValue` | The attribute conceptually applies but currently has no value | **Genuine, expected absence** — this element has no title-UI-element reference. Produces `nil`. Never an error. |
| `kAXErrorAttributeUnsupported` | The element does not support this attribute at all | **Genuine, expected absence** — same treatment as `kAXErrorNoValue`. |
| Anything else (`kAXErrorFailure`, `kAXErrorCannotComplete`, `kAXErrorInvalidUIElement`, `kAXErrorIllegalArgument`, `kAXErrorNotImplemented`, `kAXErrorAPIDisabled`, ...) | A genuine communication/API failure | **Never folded into "absent."** Throws `AX_TITLE_REFERENCE_READ_FAILED`, carrying the underlying `AXError`. |

Additionally, even when the copy call itself reports `.success`:
- If the returned value is not an `AXUIElement` (a malformed result) → `AX_TITLE_REFERENCE_MALFORMED`.
- If the referenced element's own `kAXRoleAttribute` is not on `QAXElementReadRolePolicy`'s allowlist (the mere existence of a reference is never sufficient) → `AX_TITLE_REFERENCE_DISALLOWED_ROLE`. This is also the path that forecloses a referenced `AXSecureTextField` (never on the allowlist) from ever being surfaced as a "safe" reference.

**Deliberate scope decision (implementation-time refinement)**: Phase 2BN's approved discovery preview had originally sketched "no role restriction on the referenced element — a title element can legitimately be `AXStaticText`, `AXGroup`, or others." The approved implementation instructions explicitly required reusing an existing generic read/element role policy rather than accepting an arbitrary AX object merely because `kAXTitleUIElementAttribute` returned one. This implementation therefore independently re-validates the referenced element's role against `QAXElementReadRolePolicy` — the same allowlist the source element itself must satisfy — and fails the whole read closed on a disallowed role, rather than the discovery preview's original "accept any role" sketch. This refinement is documented here explicitly per this program's convention of never silently expanding (or in this case, tightening) scope without recording the decision.

---

## Target Resolution & Fail-Closed Gates
1. **Match criteria**: at least one of `identifier`/`title` required → `AX_MISSING_MATCH_CRITERIA` otherwise.
2. **Source role gate**: `AXSecureTextField` → dedicated `AX_SECURE_FIELD_READ_DENIED`; any other role not on `QAXElementReadRolePolicy`'s allowlist → `AX_READ_ROLE_NOT_ALLOWED`.
3. **Accessibility trust**: `AXIsProcessTrusted()` checked before application resolution. Absent trust → `AX_PERMISSION_DENIED`.
4. **Application resolution**: exact matching via `resolveExactRunningApplication(named:)` (unmodified) — zero matches → `AX_APPLICATION_NOT_AVAILABLE`; multiple matches → `AX_AMBIGUOUS_TARGET`.
5. **Target resolution**: `collectMatches` bounded search for the one target element — zero matches → `AX_NO_MATCHING_ELEMENT`; multiple matches → `AX_AMBIGUOUS_TARGET`, never `.first`.
6. **Staleness check**: the resolved target is re-snapshotted immediately before the title-reference read and compared against the search-time snapshot — any drift → `AX_STALE_TARGET`.
7. **Reference gates** (see table above): absence is valid; failure/malformed/disallowed-role are not, and fail the whole read closed.
8. **Bound enforcement**: the reference's title/identifier is checked against `maxTitleReferenceMetadataLength` (256 characters) — exceeding it → `AX_TITLE_REFERENCE_METADATA_EXCEEDS_SAFE_LENGTH`, never silently truncated.

---

## Output Contract
`QAXElementTitleReference` (new type, `QBridgeAdapters.swift`):

| Field | Type | Notes |
|---|---|---|
| `role` | `String` | The referenced element's own `kAXRoleAttribute`, independently re-validated against `QAXElementReadRolePolicy`. |
| `title` | `String?` | The referenced element's own `kAXTitleAttribute`, or `nil` if empty/absent. |
| `identifier` | `String?` | The referenced element's own `AXIdentifier`, or `nil` if absent. |

The overall result is `QAXElementTitleReference?` — `nil` is a valid, honestly-reported "no title-UI-element reference" result, never an error.

No `AXUIElement`, no coordinates, no attribute values beyond role/title/identifier, ever appear in this type.

---

## Closed-Loop Verification Strategy
- **Strategy**: `QVerificationStrategy.elementTitleReferenceReadSucceeded(applicationName: String, role: String, hasTitleReference: Bool)`
- **Evaluation**: like every other Level 0 read's verification, there is no separate physical state to re-observe after the fact — the read's own success/failure, established entirely inside `QBridgeAccessibility.readElementTitleReference`, already IS the ground truth. The strategy checks the execution result's own `success` flag as a genuine assertion, never a bare `{ true }`; it never interacts with either element as part of verification.
- **Evidence**: `application=<name> role=<role> hasTitleReference=<bool> status=verified` (or `status=failed`) — never the referenced element's title/identifier themselves.

---

## Approval, Recovery & Resource Bounds
- **Approval**: none. Level 0 is routed by `QPermissionGate.evaluate` straight to `.allow` — proven directly in the test suite, and proven *independent* of `ui.focus_element`'s own, entirely separate Level 2 approval requirement (test 27).
- **Recovery**: an uncertain in-flight step fails closed to `pending` — a retry is always safe; no raw reference metadata is ever persisted into any field a recovery replay could read back.
- **Resource Bounds** (all enforced structurally or by explicit runtime check):
  - `maxTargetElementsResolved = 1`.
  - `maxElementsInspected = 2` (the target plus its title reference).
  - `maxReferencedElements = 1`.
  - `maxTraversalDepth = 0` beyond the single direct reference follow — no descent into the referenced element's own children.
  - `maxChildren = 0`.
  - `maxActionsPerformed = 0` — `AXUIElementPerformAction` is never called anywhere in the implementation.
  - `maxPolling = 0` — a fixed set of synchronous calls.
  - `maxRetries = 0`.
  - `maxReturnedRecords = 1` (never a collection); `maxStringLength = 256` per title/identifier.

---

## Privacy & Security Architecture
- **May leave the immediate reasoning boundary**: the referenced element's role/title/identifier (structural UI labels like `"Name:"`) and presence/absence — never content, never an `AXValue`.
- **Must never be persisted beyond identity**: individual reference title/identifier strings are deliberately excluded from durable verification evidence, audit `executionSummary` text, memory, and recovery/replan state — proven directly in the test suite against distinctively-named label values (tests 28, 29, 30).
- **Discovered relationships are DATA, not AUTHORIZATION**: the model observing that element X labels element Y gains zero authorization to interact with either — proven directly (test 27): `ui.read_element_title_reference`'s own `QPermissionGate` evaluation and `ui.focus_element`'s entirely separate, still-required Level 2 approval evaluation are wholly disjoint decisions.
- **No new privacy mechanism introduced**: reuses `QAXElementReadRolePolicy`'s existing allowlist verbatim for BOTH the source element and the referenced element — including its existing `AXSecureTextField` exclusion, which therefore also forecloses a referenced secure field from ever being surfaced as a "safe" reference.
- **No durable pointer/content leaks**: `QAXElementTitleReference`'s stored properties are `String`/`String?` only — no `AXUIElement`-typed field exists anywhere in the declaration.
- **Zero physical automation**: strictly no `CGEvent`, `NSEvent`, keyboard/mouse simulation, coordinate targeting, OCR, screenshots, or network fallback — confirmed by direct diff audit (0 actual usages of any kind).

---

## Test Coverage (`QSemanticElementTitleReferenceReadTests.swift`)
38 focused tests, covering: capability registration (anti-downgrade both directions); exact application resolution; zero/ambiguous application match; exact target match (by identifier and title); zero/ambiguous target match; disallowed source role and secure-field source role each fail closed with their own distinct, dedicated error code; title reference exists (real `setAccessibilityTitleUIElement(_:)` fixture) and correctly resolves; title reference genuinely absent reports `nil`, never an error; read-failure/malformed/invalid-reference each fail closed with their own distinct, dedicated error code, structurally distinct from absence; a valid `AXStaticText` title element is accepted with correct role/title/identifier extraction; a disallowed-role reference (including a referenced `AXSecureTextField`) fails closed; no recursive traversal of the referenced element occurs; reference title/identifier extraction; missing title/identifier handled safely; 256-character metadata accepted (bound inclusive); 257-character metadata fails closed, never truncated; **neither element is ever mutated**, proven via a real fixture whose fields remain unchanged; `QPermissionGate` never requires approval, and is proven independent of `ui.focus_element`'s own separate requirement; no persistent authorization is ever constructed; individual reference metadata absent from durable-plan snapshots, audit records, and recovery/replan state (three dedicated tests against distinctively-named label values); evidence-based verification success/failure contents; normal `QPlanExecutor` pipeline integration with a dedicated (non-bypassed) verification strategy; forbidden API audit (structural, and confirmed zero matches of any kind for `AXUIElementPerformAction`/`AXUIElementSetAttributeValue`); no polling/child-traversal (structural); real macOS E2E (TCC-guarded, two `NSTextField`s wired via the public `setAccessibilityTitleUIElement(_:)` API, with both the "labeled" and "genuinely unlabeled" paths proven against real, live `AXUIElement`s — the strongest native E2E fixture of any phase to date, with no workaround or known limitation, unlike Phase 2BM's incomplete cancel-button gap).

---

## Real macOS E2E — No Known Limitation
Unlike Phase 2BM's window-button capability (which could only build a complete fixture for the default button, not the cancel button, due to no public `NSWindow.cancelButtonCell` equivalent), this capability has a complete, first-party, zero-workaround fixture path: two real `NSTextField` views wired via the standard, fully public `setAccessibilityTitleUIElement(_:)` AppKit API — no custom subclassing, no private API needed. Test 37 builds both a labeled and a genuinely-unlabeled `NSTextField` fixture and dispatches through `QBridgeAccessibility.shared.readElementTitleReference` end-to-end for both, asserting the labeled case resolves the exact label title/role and the unlabeled case reports genuine `nil` absence, while independently confirming neither field's own content was mutated. In this session's isolated, ad-hoc-signed test host (`scripts/test-pace.sh`), `AXIsProcessTrusted()` evaluates `false` — confirmed directly from the test run: this test (and every other `AXIsProcessTrusted()`-guarded test in the new suite) completed in well under the time a real window creation and AX round-trip would require. This is the same, honestly-reported **BLOCKED — TCC / Accessibility permission** finding every prior phase's equivalent real-fixture test in this codebase has documented — never fabricated as a real-world pass.

---

## Regression Results
- **Filtered suite** (`QSemanticElementTitleReferenceReadTests`): 38/38 passed.
- **Related suites**: `QSemanticElementActionEnumerationTests` 33/33, `QSemanticElementAttributeEnumerationTests` 33/33, `QSemanticWindowDefaultButtonReadTests` 39/39, `QApplicationResolutionHardeningTests` 27/27, `QPersistenceSecurityTests` 4/4, `QPermissionGateTests` 5/5 — all green, zero regressions.
- **Full regression** (`scripts/test-pace.sh`, 3 consecutive official runs): 3339/3339, 3339/3339, 3339/3339 — no flakes, no regressions in code touched by this phase. One transient, unrelated timing flake was observed in `PaceProactiveQueueDrainTests` during an earlier exploratory (non-official) run under full-suite load, before the 3 official runs began; re-running that suite in isolation immediately afterward passed 3/3, and all 3 official full-regression runs that followed were entirely clean — classified as an environmental flake in an untouched test, not a regression from this change (the same class of flake documented in Phase 2BG for an unrelated test).

---

## Release Build Verification
- `scripts/prepare-release.sh` (isolated Release build, no version bump, no publish): **BUILD SUCCEEDED**.
- `file Pace.app/Contents/MacOS/Pace` → `Mach-O 64-bit executable arm64`.
- `codesign --verify --verbose` → `valid on disk`, `satisfies its Designated Requirement` (ad-hoc signed, as this script's default configures — no unrelated signing or architecture change).

---

## Known Limitations
None. Unlike Phase 2BM's window-button capability, every state this capability's contract defines (title reference present with a valid role, title reference genuinely absent) is fully provable against real, live `AXUIElement`s via a standard, public AppKit fixture. The disallowed-role and malformed/read-failure paths are proven at the error-contract level (exact `QAXInteractionError` case, error code, and message format) rather than via a live fixture — standard AppKit's title-reference wiring does not offer a way to legitimately construct a disallowed-role or malformed reference, the same class of limitation documented for equivalent structural failure paths in every prior phase (e.g. Phase 2BM's wrong-role/malformed button reference tests).
