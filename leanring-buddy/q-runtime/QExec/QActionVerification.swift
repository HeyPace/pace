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
    /// Phase 2L: re-resolves the same top-level menu bar item and item title a
    /// ui.select_menu_item step just selected and evaluates `QMenuItemSelectionEvidence` — the
    /// item becoming unresolvable (the menu closed) is the expected, benign post-selection
    /// lifecycle and is treated as `.verified`; the item remaining resolvable and unchanged, or
    /// the application/menu-bar-item itself becoming unavailable, is treated as `.failed`. Never
    /// invents a stronger verification claim than AX alone can generically provide — see
    /// `QMenuItemSelectionEvidence`'s own documentation for the full evidence contract.
    case axMenuItemSelectionEvidence(
        applicationName: String,
        menuBarTitle: String,
        itemTitle: String,
        targetIdentity: String
    )
    /// Phase 2M: re-resolves the same semantic slider/stepper target a ui.set_slider_value step
    /// just set (or correctly no-op'd) and confirms its CURRENT value matches `desiredValue`
    /// using the same tolerance rule (`QBridgeAccessibility.sliderValuesAreEqual`) idempotency
    /// used — plain numeric comparison, since a slider's value is not sensitive content. A
    /// successful set is not itself evidence of goal success; this is the independent closed-loop
    /// check that supplies the real evidence. Like `axTextValueChanged`/
    /// `axElementStateMatchesDesired`, an unresolvable target after the change is `.failed`, not
    /// assumed success; an internally-inconsistent post-change range is likewise `.failed`.
    case axSliderValueMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredValue: Double
    )
    /// Phase 2N: re-observes `NSWorkspace.shared.frontmostApplication` independently of whatever
    /// `executeActivateApplication` itself observed (including its own bounded poll) and confirms
    /// it matches the resolved target's stable `processIdentifier` — never `localizedName`, which
    /// a same-named replacement process could otherwise satisfy. A successful `activate()` call
    /// (or an idempotent already-frontmost no-op) is not itself evidence of goal success; this is
    /// the independent closed-loop check that supplies the real evidence, and it fails — never
    /// assumes — if no frontmost application can be observed at all, or if the observed frontmost
    /// application's pid does not match.
    case processIsFrontmost(applicationName: String, targetProcessIdentifier: pid_t)
    /// Phase 2O: re-resolves the same semantic target a ui.focus_element step just focused (or
    /// correctly no-op'd) and independently re-reads `kAXFocusedUIElementAttribute` — a
    /// successful `AXUIElementSetAttributeValue` call is never itself treated as proof of
    /// success; this is the closed-loop check that supplies the real evidence. Like
    /// `axTextValueChanged`/`axElementStateMatchesDesired`/`axSliderValueMatchesDesired`
    /// (and deliberately unlike `axElementStateChanged`'s click-based model), an unresolvable
    /// target after the change is `.failed`, not assumed success — nothing about being focused
    /// should make an element disappear.
    case axElementIsFocused(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String
    )
    /// Phase 2P: re-resolves the same semantic `AXPopUpButton` target a ui.select_popup_item
    /// step just selected (or correctly no-op'd) and independently re-reads its OWN
    /// `kAXValueAttribute` — a successful open+select press sequence is never itself treated as
    /// proof of success; this is the closed-loop check that supplies the real evidence. Unlike
    /// `axMenuItemSelectionEvidence`'s indirect "item disappeared" model, a popup's value is
    /// directly comparable, so this compares `currentValue` against `requestedItemTitle` plainly
    /// — the same direct-comparison model `axSliderValueMatchesDesired` already established. Like
    /// `axSliderValueMatchesDesired`/`axElementStateMatchesDesired` (and deliberately unlike
    /// `axElementStateChanged`'s click-based model), an unresolvable target after the change is
    /// `.failed`, not assumed success.
    case axPopupValueMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        requestedItemTitle: String
    )
    /// Phase 2Q: re-resolves the same semantic `AXDisclosureTriangle` target a
    /// ui.toggle_disclosure step just toggled (or correctly no-op'd) and independently re-reads
    /// its `kAXValueAttribute` — a successful press is never itself treated as proof of success;
    /// this is the closed-loop check that supplies the real evidence. Structurally the same
    /// direct-comparison model `axElementStateMatchesDesired`/`axPopupValueMatchesDesired`
    /// already establish. Like those (and deliberately unlike `axElementStateChanged`'s
    /// click-based model), an unresolvable target after the change is `.failed`, not assumed
    /// success; an unreadable/indeterminate state is likewise `.failed`, never defaulted to
    /// either expanded or collapsed.
    case axDisclosureStateMatchesDesired(
        applicationName: String,
        role: String,
        matchIdentifier: String?,
        matchTitle: String?,
        targetIdentity: String,
        desiredState: QAXDisclosureState
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

        case .axMenuItemSelectionEvidence(let applicationName, let menuBarTitle, let itemTitle, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.observeMenuItemSelectionEvidence(
                applicationName: applicationName,
                menuBarTitle: menuBarTitle,
                itemTitle: itemTitle
            )
            switch evidence {
            case .itemNoLongerResolvable:
                // The expected, benign post-selection lifecycle — selecting an item closes its
                // menu. This is the strongest generic evidence AX alone can provide for this
                // capability; no stronger claim is made.
                return .verified(evidence: "target=\(targetIdentity) evidenceType=itemDisappeared status=verified")
            case .itemStillResolvable:
                return .failed(
                    reason: "Target menu item (\(itemTitle)) remained resolvable and unchanged after selection — no evidence the selection took effect.",
                    evidence: "target=\(targetIdentity) evidenceType=itemUnchanged status=failed"
                )
            case .applicationOrTargetUnavailable:
                return .failed(
                    reason: "Application or menu bar item (\(menuBarTitle)) became unavailable during verification — physical state is uncertain.",
                    evidence: "target=\(targetIdentity) evidenceType=uncertainLifecycle status=failed"
                )
            }

        case .axSliderValueMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredValue):
            let evidence = await QBridgeAccessibility.shared.observeSliderValueEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentValue):
                if QBridgeAccessibility.sliderValuesAreEqual(currentValue, desiredValue) {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) desiredValue=\(desiredValue) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target element (role=\(role)) current value does not match the desired value after the change.",
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) desiredValue=\(desiredValue) status=failed"
                    )
                }
            case .rangeInvalid(let currentValue):
                return .failed(
                    reason: "Target element (role=\(role)) reported an internally inconsistent range after the change — verification cannot be trusted.",
                    evidence: "target=\(targetIdentity) currentValue=\(currentValue) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .processIsFrontmost(let applicationName, let targetProcessIdentifier):
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                return .failed(
                    reason: "No frontmost application could be observed after activating '\(applicationName)'.",
                    evidence: "NSWorkspace.shared.frontmostApplication returned nil."
                )
            }
            if frontmost.processIdentifier == targetProcessIdentifier {
                return .verified(
                    evidence: "target=\(applicationName) pid=\(targetProcessIdentifier) status=verified frontmost=true"
                )
            } else {
                return .failed(
                    reason: "Application '\(applicationName)' is not the frontmost application after activation.",
                    evidence: "target=\(applicationName) expectedPid=\(targetProcessIdentifier) actualFrontmostPid=\(frontmost.processIdentifier) actualFrontmostName=\(frontmost.localizedName ?? "unknown") status=failed"
                )
            }

        case .axElementIsFocused(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity):
            let evidence = await QBridgeAccessibility.shared.observeFocusedElementIdentity(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .focused:
                return .verified(
                    evidence: "target=\(targetIdentity) status=verified focused=true"
                )
            case .notFocused:
                return .failed(
                    reason: "Target element (role=\(role)) is not the currently focused Accessibility element after the change.",
                    evidence: "target=\(targetIdentity) status=failed focused=false"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target element (role=\(role)) is no longer resolvable for verification after the focus change.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axPopupValueMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let requestedItemTitle):
            let evidence = await QBridgeAccessibility.shared.observePopupValueEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentValue):
                if currentValue == requestedItemTitle {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) requestedItemTitle=\(requestedItemTitle) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target popup (role=\(role)) current value does not match the requested item after the selection.",
                        evidence: "target=\(targetIdentity) currentValue=\(currentValue) requestedItemTitle=\(requestedItemTitle) status=failed"
                    )
                }
            case .targetUnavailable:
                return .failed(
                    reason: "Target popup (role=\(role)) is no longer resolvable, or its value could not be read, for verification after the selection.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            }

        case .axDisclosureStateMatchesDesired(let applicationName, let role, let matchIdentifier, let matchTitle, let targetIdentity, let desiredState):
            let evidence = await QBridgeAccessibility.shared.observeDisclosureStateEvidence(
                applicationName: applicationName,
                role: role,
                identifier: matchIdentifier,
                title: matchTitle
            )
            switch evidence {
            case .resolved(let currentState):
                if currentState == desiredState {
                    return .verified(
                        evidence: "target=\(targetIdentity) currentState=\(currentState.rawValue) desiredState=\(desiredState.rawValue) status=verified"
                    )
                } else {
                    return .failed(
                        reason: "Target disclosure triangle (role=\(role)) current state does not match the desired state after the toggle.",
                        evidence: "target=\(targetIdentity) currentState=\(currentState.rawValue) desiredState=\(desiredState.rawValue) status=failed"
                    )
                }
            case .stateUnreadable:
                return .failed(
                    reason: "Target disclosure triangle (role=\(role)) current state could not be read or interpreted after the toggle — unknown state fails closed.",
                    evidence: "target=\(targetIdentity) status=failed"
                )
            case .targetUnavailable:
                return .failed(
                    reason: "Target disclosure triangle (role=\(role)) is no longer resolvable for verification after the toggle.",
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
