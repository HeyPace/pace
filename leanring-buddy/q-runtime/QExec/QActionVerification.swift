//
//  QActionVerification.swift
//  leanring-buddy
//
//  Q Security Architecture — Closed-Loop Action Verification (Phase 1D.7).
//  Guarantees that state changes are empirically observed and verified
//  before an action is marked as successful.
//

import Foundation
import AppKit

// MARK: - Verification Strategy & Outcome

public enum QVerificationStrategy: Sendable {
    case fileExists(path: String, expectedContent: String? = nil)
    case fileDeleted(path: String)
    case windowOrAppActive(appName: String)
    case appNotRunning(appName: String)
    /// Phase 2H: re-resolves the same semantic target a ui.click_element step just pressed and
    /// diffs its own Accessibility state (identifier/title/enabled) against the pre-click
    /// snapshot. A successful AX press is not itself evidence of goal success — this is the
    /// closed loop that supplies the actual evidence, and it fails (never fabricates) when no
    /// change is observed.
    case axElementStateChanged(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        beforeSnapshot: QAXElementSnapshot
    )
    /// Phase 2I: re-resolves the same semantic target a ui.set_text_value step just wrote to and
    /// confirms its CURRENT value hashes to the intended value's hash — never comparing or
    /// transmitting the plaintext itself. A successful AX write is not itself evidence of goal
    /// success; this is the independent closed-loop check that supplies the real evidence, and
    /// (deliberately, unlike axElementStateChanged) it FAILS rather than assumes success if the
    /// target becomes unresolvable — a text field disappearing after a value write is a more
    /// concerning signal than a button's identity changing after a press.
    case axTextValueChanged(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        previousLength: Int,
        previousValueHash: String,
        intendedValueHash: String
    )
    /// Phase 2K: re-resolves the same semantic checkbox/radio-button target a
    /// ui.set_element_state step just pressed (or correctly no-op'd) and confirms its CURRENT
    /// state hashes to the desired state's hash — never comparing or transmitting the raw AX
    /// value itself (only the small "on"/"off" enum and its hash ever exist). A successful press
    /// is not itself evidence of goal success; this is the independent closed-loop check that
    /// supplies the real evidence. Like `axTextValueChanged` (and deliberately unlike
    /// `axElementStateChanged`), an unresolvable target after the change is treated as `.failed`,
    /// not assumed success — a checkbox/radio's identity is not expected to change as a direct
    /// result of being toggled the way some buttons' identity does after a press.
    case axElementStateMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        previousStateHash: String,
        desiredStateHash: String
    )
    case customCheck(description: String, check: @Sendable () async -> Bool)
}

public enum QVerificationOutcome: Equatable, Sendable {
    case verified(evidence: String)
    case failed(reason: String, evidence: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

// MARK: - Closed-Loop Action Verifier

public final class QActionVerifier: Sendable {
    public static let shared = QActionVerifier()

    public func verify(
        action: QActionRequest,
        result: QActionResult,
        strategy: QVerificationStrategy
    ) async -> QVerificationOutcome {
        // If execution result already failed, verification confirms failure
        guard result.success else {
            return .failed(
                reason: "Action execution returned error: \(result.error ?? "unknown")",
                evidence: "Execution failed prior to post-observation."
            )
        }

        switch strategy {
        case .fileExists(let path, let expectedContent):
            let stdPath = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: stdPath) else {
                return .failed(
                    reason: "Verification failed: file '\(path)' does not exist on disk.",
                    evidence: "stat(\(path)) returned ENOENT"
                )
            }

            if let expectedContent {
                let actual = (try? String(contentsOfFile: stdPath, encoding: .utf8)) ?? ""
                if actual == expectedContent || actual.contains(expectedContent) {
                    return .verified(evidence: "File '\(path)' exists and content matches expected value (\(actual.count) chars).")
                } else {
                    return .failed(
                        reason: "Verification failed: file content mismatch in '\(path)'.",
                        evidence: "Expected '\(expectedContent)', found '\(actual.prefix(80))'"
                    )
                }
            }
            return .verified(evidence: "File '\(path)' exists on filesystem.")

        case .fileDeleted(let path):
            let stdPath = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: stdPath) {
                return .failed(
                    reason: "Verification failed: file '\(path)' still exists.",
                    evidence: "File was observed on disk after deletion attempt."
                )
            }
            return .verified(evidence: "File '\(path)' is confirmed deleted from disk.")

        case .windowOrAppActive(let appName):
            let runningApps = NSWorkspace.shared.runningApplications
            let isRunning = runningApps.contains { app in
                (app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame) ||
                (app.bundleIdentifier?.caseInsensitiveCompare(appName) == .orderedSame)
            }
            if isRunning {
                return .verified(evidence: "Application '\(appName)' verified running in NSWorkspace.")
            } else {
                // In headless tests or if app not launched, return empirical failure
                return .failed(
                    reason: "Application '\(appName)' not found among running applications.",
                    evidence: "NSWorkspace runningApplications query returned negative."
                )
            }

        case .appNotRunning(let appName):
            let runningApps = NSWorkspace.shared.runningApplications
            let stillRunning = runningApps.contains { app in
                (app.localizedName?.caseInsensitiveCompare(appName) == .orderedSame) ||
                (app.bundleIdentifier?.caseInsensitiveCompare(appName) == .orderedSame)
            }
            if stillRunning {
                return .failed(
                    reason: "Application '\(appName)' is still running after a termination request.",
                    evidence: "NSWorkspace runningApplications query returned positive after quit dispatch."
                )
            } else {
                return .verified(evidence: "Application '\(appName)' verified terminated (absent from NSWorkspace runningApplications).")
            }

        case .axElementStateChanged(let applicationName, let role, let matchIdentifier, let matchTitle, let beforeSnapshot):
            guard let afterSnapshot = await QBridgeAccessibility.shared.observeElement(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            ) else {
                // The element is no longer uniquely resolvable by the same criteria used to find
                // it before the click — a legitimate, common outcome for a control whose own
                // identity changes when pressed (see docs/PHASE_2H_SEMANTIC_CLICK.md), so this
                // counts as an observed state change, not a failure.
                return .verified(
                    evidence: "Target element (role=\(role)) is no longer resolvable by its pre-click identity after the press — its state visibly changed."
                )
            }
            guard afterSnapshot != beforeSnapshot else {
                return .failed(
                    reason: "No observable Accessibility state change on the target element after the press.",
                    evidence: "role=\(role) identifier=\(afterSnapshot.identifier ?? "none") label=\(afterSnapshot.titleOrDescription ?? "none") enabled=\(afterSnapshot.isEnabled) unchanged before/after."
                )
            }
            return .verified(
                evidence: "Target element (role=\(role)) state changed after press: identifier \(beforeSnapshot.identifier ?? "none") -> \(afterSnapshot.identifier ?? "none"), label \(beforeSnapshot.titleOrDescription ?? "none") -> \(afterSnapshot.titleOrDescription ?? "none")."
            )

        case .axTextValueChanged(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let previousLength, let previousValueHash, let intendedValueHash):
            guard let (currentValueHash, currentLength) = await QBridgeAccessibility.shared.observeTextValueHashAndLength(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            ) else {
                // Unlike axElementStateChanged, an unresolvable text-entry target after a write
                // is NOT treated as an observed success — a text field disappearing after having
                // its value set is a more concerning signal than a control's identity changing as
                // a direct, expected effect of being pressed. Fail closed rather than assume.
                let evidence = QSafeTextEntryVerificationEvidence(
                    valueChanged: false,
                    previousLength: previousLength,
                    currentLength: 0,
                    targetIdentity: targetIdentity,
                    verificationStatus: .failed
                )
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the write.",
                    evidence: evidence.safeEvidenceDescription
                )
            }

            if currentValueHash == intendedValueHash {
                let evidence = QSafeTextEntryVerificationEvidence(
                    valueChanged: currentValueHash != previousValueHash,
                    previousLength: previousLength,
                    currentLength: currentLength,
                    targetIdentity: targetIdentity,
                    verificationStatus: .verified
                )
                return .verified(evidence: evidence.safeEvidenceDescription)
            } else {
                let evidence = QSafeTextEntryVerificationEvidence(
                    valueChanged: currentValueHash != previousValueHash,
                    previousLength: previousLength,
                    currentLength: currentLength,
                    targetIdentity: targetIdentity,
                    verificationStatus: .failed
                )
                return .failed(
                    reason: "Target element (role=\(role)) current value does not match the intended value after the write.",
                    evidence: evidence.safeEvidenceDescription
                )
            }

        case .axElementStateMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let previousStateHash, let desiredStateHash):
            guard let currentStateHash = await QBridgeAccessibility.shared.observeElementStateHash(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            ) else {
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the state change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

            if currentStateHash == desiredStateHash {
                return .verified(
                    evidence: "target=\(targetIdentity) stateChanged=\(currentStateHash != previousStateHash) status=verified"
                )
            } else {
                return .failed(
                    reason: "Target element (role=\(role)) current state does not match the desired state after the change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .customCheck(let description, let check):
            let passed = await check()
            if passed {
                return .verified(evidence: "Custom assertion passed: \(description)")
            } else {
                return .failed(
                    reason: "Custom assertion failed: \(description)",
                    evidence: "Predicate returned false."
                )
            }
        }
    }
}
