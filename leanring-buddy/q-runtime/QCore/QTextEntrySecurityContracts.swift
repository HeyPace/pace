//
//  QTextEntrySecurityContracts.swift
//  leanring-buddy
//
//  Q Security Architecture — Text-Entry Privacy Contract (Phase 2I).
//
//  These structural guards were written ahead of `ui.set_text_value`'s implementation (see
//  docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md for the original privacy pre-check) and are
//  now consumed by it: `QExecutionService.executeSetTextValue`, `QBridgeAccessibility
//  .setTextValue`, and `QActionVerifier`'s `.axTextValueChanged` case all route their evidence
//  through this file's types rather than hand-building `QActionResult.summary` /
//  `QVerificationOutcome` strings, so the literal entered/read text structurally cannot reach
//  `QActionResult`, `QAuditRecord`, durable persistence, `QMemoryStore`, the approval HUD, or
//  model/replan context.
//

import Foundation

// MARK: - Verification Evidence Contract (pre-check Part 3 / mission item 3)

/// The verification outcome of a future `ui.set_text_value`-style capability.
///
/// This type deliberately has NO field capable of holding the literal text that was read from,
/// or written into, an Accessibility element — only length and identity metadata. A future
/// executor/verifier for that capability MUST produce its evidence through this type (via
/// `toActionResultOutputData()` / `safeEvidenceDescription`) rather than hand-building
/// `QActionResult.summary` / `QVerificationOutcome` strings itself, so the literal value
/// structurally cannot reach `QActionResult`, `QAuditRecord`, durable persistence, `QMemoryStore`,
/// the approval HUD, or model/replan context — every one of which the Phase 2I pre-check traced
/// as a real path a hand-built evidence string could otherwise leak through.
public struct QSafeTextEntryVerificationEvidence: Sendable, Equatable {
    /// Whether the target's value differs from what it was before the write. Never the values
    /// themselves — only whether they differ.
    public let valueChanged: Bool
    /// Character count of the target's value before the write. Length is not sensitive content.
    /// Optional: a recovery/verification path that cannot safely establish the prior length
    /// (e.g. the target became unresolvable) omits it rather than guessing.
    public let previousLength: Int?
    /// Character count of the target's value after the write (or after re-observation, for the
    /// closed-loop verification step).
    public let currentLength: Int
    /// Non-secret targeting metadata only — e.g. "role=AXTextField identifier=searchField" or
    /// "role=AXTextArea title=Notes body" — never the field's value.
    public let targetIdentity: String
    public let verificationStatus: QSafeTextEntryVerificationStatus

    public init(
        valueChanged: Bool,
        previousLength: Int?,
        currentLength: Int,
        targetIdentity: String,
        verificationStatus: QSafeTextEntryVerificationStatus
    ) {
        self.valueChanged = valueChanged
        self.previousLength = previousLength
        self.currentLength = currentLength
        self.targetIdentity = targetIdentity
        self.verificationStatus = verificationStatus
    }

    /// The only sanctioned way to turn this evidence into `QActionResult.outputData`. Because
    /// this type has no literal-text field, this conversion structurally cannot leak one.
    /// `previousLength` is omitted entirely (not encoded as an empty/sentinel string) when unknown.
    public func toActionResultOutputData() -> [String: String] {
        var data: [String: String] = [
            "valueChanged": valueChanged ? "true" : "false",
            "currentLength": String(currentLength),
            "targetIdentity": targetIdentity,
            "verificationStatus": verificationStatus.rawValue
        ]
        if let previousLength {
            data["previousLength"] = String(previousLength)
        }
        return data
    }

    /// The only sanctioned way to turn this evidence into a `QVerificationOutcome` evidence
    /// string (the `evidence:` payload of `.verified`/`.failed`).
    public var safeEvidenceDescription: String {
        let previousLengthDescription = previousLength.map(String.init) ?? "unknown"
        return "target=\(targetIdentity) valueChanged=\(valueChanged) previousLength=\(previousLengthDescription) currentLength=\(currentLength) status=\(verificationStatus.rawValue)"
    }
}

public enum QSafeTextEntryVerificationStatus: String, Sendable, Equatable {
    case verified
    case failed
}

// MARK: - AX Mutation Outcome (execution-time contract)

/// The outcome of one `QBridgeAccessibility.setTextValue` mutation attempt.
///
/// Like `QSafeTextEntryVerificationEvidence`, this type has no field capable of holding the
/// literal text that was read from, or written into, the target element — only lengths,
/// non-secret target identity, and SHA-256 hex digests (never the plaintext they were computed
/// from) used solely so the later, independent closed-loop verification step
/// (`QVerificationStrategy.axTextValueChanged`) can confirm the write both took effect and
/// matches what was intended, without either the execution or verification layer ever handling
/// the literal value outside `setTextValue`'s own local scope.
public struct QAXTextValueMutationOutcome: Sendable, Equatable {
    /// Whether a mutation was actually performed. `false` means the target's value already
    /// equaled the intended value — a deliberate no-op, not a failure.
    public let valueChanged: Bool
    public let previousLength: Int
    public let currentLength: Int
    /// Non-secret targeting metadata — application, role, and identifier-or-title. Never the
    /// field's value.
    public let targetIdentity: String
    /// SHA-256 hex digest of the value immediately BEFORE this call (the value the intended
    /// write is being compared against) — never the plaintext.
    public let previousValueHash: String
    /// SHA-256 hex digest of the value this call intended the target to hold afterward — never
    /// the plaintext. Threaded through to the later closed-loop verification step so it can
    /// confirm the live target's current value hashes to the same digest, without ever comparing
    /// or transmitting the plaintext itself.
    public let intendedValueHash: String

    public init(
        valueChanged: Bool,
        previousLength: Int,
        currentLength: Int,
        targetIdentity: String,
        previousValueHash: String,
        intendedValueHash: String
    ) {
        self.valueChanged = valueChanged
        self.previousLength = previousLength
        self.currentLength = currentLength
        self.targetIdentity = targetIdentity
        self.previousValueHash = previousValueHash
        self.intendedValueHash = intendedValueHash
    }
}

// MARK: - Recovery Readback Scoping (pre-check Part G / mission item 6)

/// The result of comparing a live-read `kAXValueAttribute` against the intended value during
/// crash-recovery resolution for a future text-entry capability.
///
/// This type deliberately carries NO string field — only the boolean outcome of the equality
/// check. The live-read value that produced this result must be consumed exclusively inside the
/// function that constructs this type and must never itself be assigned to `QActionResult`,
/// included in evidence, logged, persisted, or passed to model/replan context. Because this
/// struct has no field that could hold it, any future recovery code that returns this type
/// instead of the raw comparison strings structurally cannot leak the readback.
public struct QTextEntryRecoveryEqualityResult: Sendable, Equatable {
    /// Whether the live-read current value already equals the intended value — i.e. whether the
    /// write from a prior, possibly-crashed attempt already landed and this step can be treated
    /// as already-done rather than re-executed.
    public let alreadyMatchesIntendedValue: Bool

    public init(alreadyMatchesIntendedValue: Bool) {
        self.alreadyMatchesIntendedValue = alreadyMatchesIntendedValue
    }
}

// MARK: - Accessibility Target Role Policy (pre-check Part F / mission item 5)

/// Fail-closed allowlist of Accessibility roles a future text-entry capability may ever target.
///
/// An explicit allowlist, not a denylist: only the two roles below are ever eligible. This also
/// means `AXSecureTextField` (password/secure fields), `AXStaticText`, and any role this policy
/// does not explicitly recognize — including a role that doesn't exist yet, or a custom-drawn
/// field claiming an unexpected role — are all rejected by the same default-deny check, per the
/// Phase 2I pre-check's "strictest practical policy" recommendation (allowlist over denylist,
/// since a denylist alone cannot cover an unknown or custom-rolled secure field).
public enum QAXTextEntryRolePolicy {
    public static let allowedRoles: Set<String> = ["AXTextField", "AXTextArea"]

    public static func isAllowedTextEntryRole(_ role: String) -> Bool {
        allowedRoles.contains(role)
    }
}
