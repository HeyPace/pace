# Q × PACE — Phase 2G: Real Screen OCR

## 1. Objective

Replace the fabricated `screen.ocr` implementation (a hardcoded string since
Phase 2B) with genuine, on-device screen capture and text recognition,
reusing the existing security/execution architecture unchanged —
`QPermissionGate`, `QApprovalCoordinator`, `QResourceGuard`,
`QExecutionIdentity`, `QAgentBudget`, `QGoalEvaluator`, `QDurableTaskStore`
— and the audit-boundary redaction closed in the Phase 2G security
remediation (commit `08ca120`). No new capability architecture was
introduced; only `QBridgeScreenCapture` and `QBridgeVision` were made real.

## 2. Architecture

`screen.ocr` remains Level 0 (read-only, per `QCapabilityModel`'s doctrine —
reading the screen mutates no state) and flows through the exact same
pipeline every other Q tool does:

```
QModelPlanParser (untrusted model output → allowlisted QPlan)
        │
        ▼
QPlanExecutor  — QResourceGuard → QExecutionIdentity → QPermissionGate (auto-
                  allow at Level 0, unchanged) → QExecutionService.executeAction
        │
        ▼
QExecutionService.executeScreenOCR
        │
        ├─► QBridgeScreenCapture.captureScreens()   [NEW: real ScreenCaptureKit]
        │     Level 0 QPermissionGate check (unchanged) → CGPreflightScreenCaptureAccess
        │     (read-only status check, never requests access) → SCShareableContent →
        │     SCScreenshotManager.captureImage per display → QScreenCaptureFrame(image:)
        │
        └─► QBridgeVision.performOCR(on: frame)     [NEW: real Vision.framework]
              VNRecognizeTextRequest (.accurate, on-device) → QVisionOCRResult
        │
        ▼
QActionResult.summary = "...recognized: <real text>"
        │
        ▼
QPlanExecutor step G — isScreenDerivedStep redaction (Phase 2G remediation,
  commit 08ca120, UNCHANGED by this phase) → QPlanStepResult, .untrustedScreen
  taint propagation (raw, on-device only) → QDurablePlanStepSnapshot backstop
  redaction → QDurableTaskStore
        │
        ▼
QGoalEvaluator (evidence-first, unchanged) → QReplanController (unchanged)
```

Nothing above `QBridgeScreenCapture`/`QBridgeVision` changed. The redaction
boundary these two bridges now feed real data into was already built and
tested against simulated real content in the prior commit; this phase
re-verifies it against **actually Vision-recognized** text (see §9).

## 3. ScreenCaptureKit implementation

`QBridgeScreenCapture.captureScreens()`:

1. Existing Level 0 `QPermissionGate` authorization check — unchanged.
2. `CGPreflightScreenCaptureAccess()` — a **read-only status check**. It
   never triggers a system prompt and never requests access (the same API
   `PacePermissionService` already uses elsewhere in the app). Absence →
   `QScreenCaptureError.permissionDenied`, thrown immediately, no capture
   attempted.
3. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly:
   true)` — the same call Pace's own production
   `CompanionScreenCaptureUtility.captureAllScreensAsJPEG()` already uses
   successfully. A thrown error here (a real capture-availability issue
   distinct from the preflight check above) becomes
   `QScreenCaptureError.captureUnavailable`.
4. Empty `content.displays` → `QScreenCaptureError.noDisplayAvailable`.
5. Per display: `SCContentFilter(display:excludingWindows:)` +
   `SCStreamConfiguration` (full display resolution, cursor excluded) +
   `SCScreenshotManager.captureImage(contentFilter:configuration:)` — the
   macOS 14+ one-shot screenshot API, not a streaming session. A thrown
   error becomes `QScreenCaptureError.captureFailed`.

No frame is ever fabricated. Every failure mode throws a distinct,
deterministic `QScreenCaptureError` case rather than returning degenerate or
placeholder data.

## 4. Vision OCR implementation

`QBridgeVision.performOCR(on:)`:

- `VNRecognizeTextRequest` with `.recognitionLevel = .accurate` and
  `usesLanguageCorrection = true` — deterministic configuration (no
  auto-language-detection surprises across runs; the same request
  configuration every call).
- Runs inside `Task.detached(priority: .userInitiated)` — `VNImageRequestHandler
  .perform` is synchronous and can take real time for a dense full-screen
  capture, and this module defaults to MainActor isolation
  (`-default-isolation=MainActor`); detaching mirrors the exact pattern
  `CompanionScreenCaptureUtility` already uses for its own CPU-heavy,
  state-independent work over an immutable `CGImage`, so a screen-read turn
  cannot freeze the UI.
- **Ordering preserved**: observations are sorted top-to-bottom
  (`boundingBox.origin.y`, descending — Vision's origin is bottom-left) then
  left-to-right, and joined with newlines. `QVisionOCRResult` has no
  geometry field (reusing the existing model rather than introducing one),
  so reading order is expressed through line order in `detectedText`
  instead of separate coordinates.
- **Partial results**: an observation with no usable top candidate is
  skipped individually — one bad detection does not fail the whole
  recognition pass.
- **Very large results**: bounded at 20,000 characters
  (`QBridgeVision.maxDetectedTextCharacters`), with an explicit
  `[…truncated: …]` marker appended rather than a silent cut — the caller
  can tell a truncation happened.
- **No text found**: a successful, empty `QVisionOCRResult` (`detectedText:
  ""`) — not a failure. `QExecutionService.executeScreenOCR` reports this as
  a successful "no text was recognized" summary.
- Confidence is reported for observability only and is never treated as an
  authorization signal — authorization is `QPermissionGate`'s job alone.
- Purely on-device: no network call, no external OCR service, no cloud
  dependency anywhere in this path.

## 5. Permission / error behavior

| Failure mode | Result |
| --- | --- |
| Screen Recording permission denied/unavailable | `QScreenCaptureError.permissionDenied` → `QActionResult(success: false, error: "SCREEN_RECORDING_PERMISSION_DENIED")` |
| No display available | `QScreenCaptureError.noDisplayAvailable` → `error: "ENODISPLAY"` (same code the pre-2G stub already used for this case) |
| `SCShareableContent` enumeration fails | `QScreenCaptureError.captureUnavailable` → `error: "CAPTURE_UNAVAILABLE"` |
| `SCScreenshotManager.captureImage` fails | `QScreenCaptureError.captureFailed` → `error: "CAPTURE_FAILED"` |
| No image data reaches Vision | `QScreenCaptureError.captureFailed` → `error: "CAPTURE_FAILED"` |
| `VNImageRequestHandler.perform` fails | `QScreenCaptureError.visionFailed` → `error: "VISION_FAILED"` |
| Empty frame / no text recognized | Successful `QActionResult`, empty text — not an error |
| Partial recognition (some regions unreadable) | Recognized regions included; unreadable ones skipped |
| Very large recognized text | Truncated at 20,000 characters with an explicit marker |

Every failure is a deterministic, non-throwing `QActionResult(success:
false, ...)` from `QExecutionService`'s perspective (the errors are caught
and converted inside `executeScreenOCR`), which `QPlanExecutor`,
`QGoalEvaluator`, and `QAgentBudget` already handle exactly like any other
tool failure — no special-casing was added anywhere above the bridge layer.
None of these paths crash; none fabricates a result.

## 6. Privacy boundary

Unchanged from the Phase 2G security remediation (commit `08ca120`), now
exercised against real Vision output instead of simulated text:

- Raw recognized text exists temporarily in memory and is used as local
  planner context (`QTaskContext`, `.untrustedScreen` provenance) — this is
  intentional and necessary for the on-device planner to reason about the
  screen, and never leaves the device or reaches a logged/persisted sink.
- Everything that IS persisted, audited, or spoken back to the user passes
  through `QSecretRedactor` at two layers (source, in `QPlanExecutor`;
  unconditional backstop, in `QDurablePlanStepSnapshot`) before it can reach
  `QDurableTaskStore`.
- Redaction is never treated as authorization, and never downgrades or
  removes `.untrustedScreen` taint.

## 7. Taint / provenance

`.untrustedScreen` propagation is untouched by this phase — it was already
correct in Phase 2E/2F and re-verified here against real content:
`QRealScreenOCRTests.realVisionThroughApprovalAndExecutionPipeline` proves a
real Vision-recognized secret-pattern string still forces a subsequent Level
2 step to require fresh approval, exactly as it did with synthetic data in
the prior commit. Taint survives plan execution, the resulting
`QTaskContext`, and (for the redacted representation) durable persistence —
`QDurableTaskState.provenance` continues to record `"untrusted"` for a
tainted task exactly as before.

## 8. TCC test strategy

Screen Recording permission cannot be assumed inside the isolated-DerivedData
XCTest runner used by `scripts/test-pace.sh` — empirically confirmed during
this phase's own test runs (`CGPreflightScreenCaptureAccess()` returns
`false` in this development environment's test process). Rather than mock
this away, every test that depends on live capture branches on the actual,
live permission state and asserts the correct outcome for whichever state is
true:

- **Deterministic, TCC-independent (`QRealScreenOCRTests`, category A)**:
  Vision recognition tested directly against locally-rendered synthetic
  images — no ScreenCaptureKit call at all, so no permission dependency.
  Covers: known-text recognition, blank-image empty result, nil-image
  fail-closed, multi-line ordering.
- **Live-permission-branching (`QRealScreenOCRTests` category C,
  `QPlanExecutionTests`, `QAgentE2ETests`, `QFirstRealRunTests`,
  `QBridgeAdaptersTests`)**: call the real bridge/agent path and assert
  success if `CGPreflightScreenCaptureAccess()` is true, deterministic
  fail-closed if false. These tests exercise whichever branch this
  environment's real state produces — they do not skip or weaken either
  branch.
- **Hardware/release smoke checklist** (`docs/operations/release-smoke-checklist.md`,
  new "Q real screen OCR" section): the one place genuine
  grant → real-text-recognized and revoke → fail-closed behavior on real
  hardware with real TCC prompts gets verified, per this project's existing,
  established pattern for exactly this class of hardware-boundary behavior
  (the same rationale already documented at the top of that checklist).

## 9. E2E test and its limitation

`QRealScreenOCRTests.realVisionThroughApprovalAndExecutionPipeline` is the
closest deterministic approximation of the full requested E2E path achievable
inside CI:

```
Real Vision OCR (rendered synthetic image, secret-pattern text)
  → .untrustedScreen taint
  → forced Level 2 approval on a subsequent step
  → real QCoreRuntime.resolveApproval
  → real execution (verified via the live macOS pasteboard)
  → real QGoalEvaluator-based completion
  → durable state containing no plaintext secret
```

**Documented limitation**: the literal first hop (`real screen/image →
ScreenCaptureKit`) is substituted with a locally-rendered synthetic image via
a test-only `HybridRealVisionExecutionProvider`, because genuine
`SCScreenshotManager` capture requires Screen Recording TCC permission this
automated environment cannot assume. Every step downstream of that
substitution — Vision recognition, taint, approval, execution, verification,
goal evaluation, durable persistence — is exercised for real, unmocked. The
literal full path (real screen → ScreenCaptureKit → Vision → …) is covered by
the release smoke checklist item added in §8 instead, on real hardware.

## 10. Security audit

Re-verified after implementation, all unchanged or strictly unaffected by
this phase:

- `QPermissionGate` — not modified.
- `QApprovalCoordinator` — not modified.
- `QActionAuthorizer` — not modified; `screen.ocr` never routes through it
  (that bridge is specific to Pace's separate `PaceActionExecutor` pipeline).
- `QResourceGuard` — not modified; remains authoritative for any
  path-bearing tool (unrelated to this phase).
- `QExecutionIdentity` — not modified; `screen.ocr` is Level 0 and never
  needs an approval grant, so this machinery isn't exercised by it, but it
  is untouched regardless.
- `QAgentBudget` — not modified; OCR failures consume step/failure budget
  exactly like any other tool failure, with no special-casing added.
- `QGoalEvaluator` — not modified; remains evidence-first, now evaluating
  real (sanitized) OCR evidence instead of simulated evidence.
- `QReplanController` — not modified.
- `.untrustedScreen` — cannot be downgraded; re-verified against real
  content (§7).
- Raw OCR text cannot reach durable state — re-verified against real
  content (§9), reusing the unmodified Phase 2G remediation.
- No cloud/network dependency introduced — `ScreenCaptureKit` and
  `Vision.framework` are both purely on-device Apple frameworks; no network
  API was added anywhere in this phase's code.

## 11. Known limitations

- No TCC entitlement/permission was requested or manipulated programmatically
  anywhere in this phase — by design, and this means a user who has never
  granted Pace Screen Recording access will see `screen.ocr` deterministically
  fail until they grant it themselves through System Settings.
- `QVisionOCRResult` still carries no geometry/bounding-box data — ordering is
  preserved through line order only, not exposed as structured coordinates,
  consistent with "reuse the existing model" rather than introducing a new one.
- The 20,000-character truncation ceiling is a fixed constant, not
  configurable via `QAgentBudget` or any other existing bound.
- The literal `real screen → ScreenCaptureKit` hop of the requested E2E path
  is not exercised by the automated suite — see §9's documented limitation
  and the corresponding hardware smoke-checklist item.
