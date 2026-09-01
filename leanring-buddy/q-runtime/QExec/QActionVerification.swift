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
