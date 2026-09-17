//
//  QEgressBroker.swift
//  leanring-buddy
//
//  Q Security Architecture — Centralized Egress Broker (Phase 1c.8).
//  Enforces outbound network boundaries: OFFLINE (default), APPROVED, and OPEN.
//  Mediation point for all agent HTTP/socket network activity.
//

import Foundation

// MARK: - Egress Mode

public enum QEgressMode: Equatable, Sendable, CustomStringConvertible {
    case offline
    case approved(whitelist: Set<String>)
    case open

    public var description: String {
        switch self {
        case .offline:
            return "offline (Default Air-Gap)"
        case .approved(let whitelist):
            return "approved (\(whitelist.count) hosts whitelisted)"
        case .open:
            return "open (Unrestricted Egress with Audit)"
        }
    }
}

// MARK: - Egress Decision

public enum QEgressDecision: Equatable, Sendable {
    case allowed(host: String, reason: String)
    case blocked(host: String, reason: String, violation: QViolationKind)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

// MARK: - Central Egress Broker

public final class QEgressBroker: @unchecked Sendable {
    public static let shared = QEgressBroker()

    private let lock = NSLock()
    private var currentMode: QEgressMode = .offline
    private var approvedHosts: Set<String> = []

    public init(initialMode: QEgressMode = .offline) {
        self.currentMode = initialMode
        if case .approved(let whitelist) = initialMode {
            self.approvedHosts = whitelist
        }
    }

    public func setMode(_ mode: QEgressMode) {
        lock.lock()
        defer { lock.unlock() }
        currentMode = mode
        if case .approved(let whitelist) = mode {
            approvedHosts = whitelist
        }
    }

    public func getMode() -> QEgressMode {
        lock.lock()
        defer { lock.unlock() }
        return currentMode
    }

    public func addApprovedHost(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        approvedHosts.insert(host.lowercased())
        if case .approved = currentMode {
            currentMode = .approved(whitelist: approvedHosts)
        }
    }

    public func removeApprovedHost(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        approvedHosts.remove(host.lowercased())
        if case .approved = currentMode {
            currentMode = .approved(whitelist: approvedHosts)
        }
    }

    public func clearApprovedHosts() {
        lock.lock()
        defer { lock.unlock() }
        approvedHosts.removeAll()
        if case .approved = currentMode {
            currentMode = .approved(whitelist: [])
        }
    }

    // MARK: - Loopback / Localhost Detection

    public static func isLoopback(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "localhost" ||
               normalized == "127.0.0.1" ||
               normalized == "::1" ||
               normalized.hasPrefix("127.")
    }

    // MARK: - Host Matcher

    private func hostMatches(host: String, pattern: String) -> Bool {
        let h = host.lowercased()
        let p = pattern.lowercased()
        if p == "*" || p == h { return true }
        if p.hasPrefix("*.") {
            let suffix = p.dropFirst(2)
            return h == suffix || h.hasSuffix("." + suffix)
        }
        return false
    }

    // MARK: - Evaluation Engine

    public func evaluate(url: URL) -> QEgressDecision {
        guard let host = url.host else {
            return .blocked(
                host: url.absoluteString,
                reason: "Cannot extract valid hostname from URL '\(url.absoluteString)'.",
                violation: .scopeViolation
            )
        }
        return evaluate(host: host)
    }

    public func evaluate(host: String) -> QEgressDecision {
        lock.lock()
        defer { lock.unlock() }

        let normalizedHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Loopback addresses are always allowed for local sidecars (e.g. Ollama, LM Studio, Kokoro)
        if Self.isLoopback(host: normalizedHost) {
            return .allowed(
                host: normalizedHost,
                reason: "Local loopback host permitted for on-device services."
            )
        }

        // 2. Evaluate according to active Egress Mode
        switch currentMode {
        case .offline:
            return .blocked(
                host: normalizedHost,
                reason: "Outbound network egress is blocked by default in OFFLINE mode.",
                violation: .policyDeny
            )

        case .approved(let whitelist):
            let allApproved = whitelist.union(approvedHosts)
            let isWhitelisted = allApproved.contains { pattern in
                hostMatches(host: normalizedHost, pattern: pattern)
            }

            if isWhitelisted {
                return .allowed(
                    host: normalizedHost,
                    reason: "Host '\(normalizedHost)' is in the approved egress whitelist."
                )
            } else {
                return .blocked(
                    host: normalizedHost,
                    reason: "Host '\(normalizedHost)' is not in the approved whitelist.",
                    violation: .scopeViolation
                )
            }

        case .open:
            return .allowed(
                host: normalizedHost,
                reason: "Host permitted under OPEN egress policy."
            )
        }
    }

    // MARK: - Enforcement (C-2)
    //
    // `evaluate` above is the policy decision in isolation. `authorize`
    // is the actual enforcement primitive: every production network
    // client in this app calls it immediately before handing a request
    // to URLSession, and again on every HTTP redirect via
    // `RedirectGuardDelegate` below. A client that skips this call is a
    // defect to fix at that call site, not a reason to weaken this
    // function — there is deliberately no "soft" allow path here.

    /// Throws (fails closed) when `url`'s host is not currently permitted.
    /// Callers MUST call this immediately before every real network send —
    /// not once at startup, not once at client construction — so a mode
    /// change (e.g. the user switching planner tiers mid-session) takes
    /// effect on the very next request, and so retry/replan/recovery paths
    /// that re-enter the same send call are re-checked every single time
    /// rather than relying on a decision cached from an earlier attempt.
    public func authorize(url: URL) throws {
        let decision = evaluate(url: url)
        switch decision {
        case .allowed:
            return
        case .blocked(let host, let reason, let violation):
            throw QEgressAuthorizationError.blocked(host: host, reason: reason, violation: violation)
        }
    }
}

// MARK: - Egress Authorization Error

public enum QEgressAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case blocked(host: String, reason: String, violation: QViolationKind)

    public var errorDescription: String? {
        switch self {
        case .blocked(let host, let reason, _):
            return "Egress blocked for host '\(host)': \(reason)"
        }
    }
}

// MARK: - Redirect Guard

/// A `URLSessionTaskDelegate` that re-validates every HTTP redirect target
/// through `QEgressBroker` before the session is allowed to follow it. Wire
/// this into any `URLSession` call (`data(for:delegate:)`, `bytes(for:
/// delegate:)`) whose destination could conceivably redirect — without it,
/// an initially-approved host could redirect a request to an arbitrary,
/// non-approved one and the session would follow it with no further check.
/// Implements ONLY the redirect callback — it does not touch data/response
/// delegate methods, so it is safe to pass alongside code that consumes the
/// call's returned byte stream or data exactly as before.
public final class QEgressRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        do {
            try QEgressBroker.shared.authorize(url: url)
            completionHandler(request)
        } catch {
            // Fail closed: refuse the redirect. `completionHandler(nil)`
            // cancels following it — the original task then fails with a
            // cancellation-flavored error, it does NOT silently proceed.
            completionHandler(nil)
        }
    }
}
