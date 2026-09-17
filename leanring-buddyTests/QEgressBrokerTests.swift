//
//  QEgressBrokerTests.swift
//  leanring-buddyTests
//
//  Unit tests for QEgressBroker (Phase 1c.8)
//

import Testing
import Foundation
@testable import Pace

@Suite("QEgressBrokerTests")
struct QEgressBrokerTests {

    @Test("Offline mode blocks all external network egress by default")
    func offlineDenial() {
        let broker = QEgressBroker(initialMode: .offline)

        let decision1 = broker.evaluate(host: "api.openai.com")
        #expect(decision1.isBlocked)
        if case .blocked(let host, let reason, let violation) = decision1 {
            #expect(host == "api.openai.com")
            #expect(violation == .policyDeny)
            #expect(reason.contains("OFFLINE"))
        }

        let url = URL(string: "https://github.com/HeyPace/pace")!
        let decision2 = broker.evaluate(url: url)
        #expect(decision2.isBlocked)
    }

    @Test("Offline mode permits local loopback traffic for on-device sidecars")
    func offlinePermitsLoopback() {
        let broker = QEgressBroker(initialMode: .offline)

        #expect(broker.evaluate(host: "127.0.0.1").isAllowed)
        #expect(broker.evaluate(host: "localhost").isAllowed)
        #expect(broker.evaluate(host: "::1").isAllowed)
        #expect(broker.evaluate(url: URL(string: "http://127.0.0.1:11434/api/tags")!).isAllowed)
    }

    @Test("Approved mode allows only whitelisted hosts and wildcards")
    func approvedHostMode() {
        let broker = QEgressBroker(initialMode: .approved(whitelist: ["api.anthropic.com", "*.github.com"]))

        // Explicit match
        let d1 = broker.evaluate(host: "api.anthropic.com")
        #expect(d1.isAllowed)

        // Wildcard subdomain match
        let d2 = broker.evaluate(host: "raw.githubusercontent.com")
        #expect(d2.isBlocked) // Not github.com

        let d3 = broker.evaluate(host: "api.github.com")
        #expect(d3.isAllowed)

        let d4 = broker.evaluate(host: "github.com")
        #expect(d4.isAllowed)

        // Unapproved host
        let d5 = broker.evaluate(host: "evil-tracker.com")
        #expect(d5.isBlocked)
        if case .blocked(_, _, let violation) = d5 {
            #expect(violation == .scopeViolation)
        }
    }

    @Test("Open mode permits all external hosts with logging")
    func openModePermitsAll() {
        let broker = QEgressBroker(initialMode: .open)

        #expect(broker.evaluate(host: "example.com").isAllowed)
        #expect(broker.evaluate(host: "api.weather.gov").isAllowed)
    }
}

// MARK: - QEgressBroker.authorize (C-2 enforcement primitive)

/// `authorize(url:)` is the mandatory checkpoint every real network client
/// now calls immediately before sending — these tests exist because a
/// policy engine that's merely *correct in isolation* (already covered
/// above) isn't the same as one that's actually wired to fail closed at the
/// point of use, which is exactly the gap the original audit found.
@Suite("QEgressBrokerAuthorizeTests")
struct QEgressBrokerAuthorizeTests {

    @Test("authorize(url:) throws for a denied host — fails closed")
    func authorizeThrowsWhenDenied() {
        let broker = QEgressBroker(initialMode: .offline)
        #expect(throws: QEgressAuthorizationError.self) {
            try broker.authorize(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        }
    }

    @Test("authorize(url:) does not throw for an allowed host")
    func authorizeSucceedsWhenAllowed() throws {
        let broker = QEgressBroker(initialMode: .approved(whitelist: ["api.anthropic.com"]))
        try broker.authorize(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    }

    @Test("authorize(url:) always succeeds for loopback regardless of mode")
    func authorizeAlwaysSucceedsForLoopback() throws {
        let offlineBroker = QEgressBroker(initialMode: .offline)
        try offlineBroker.authorize(url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!)

        let approvedBroker = QEgressBroker(initialMode: .approved(whitelist: []))
        try approvedBroker.authorize(url: URL(string: "http://localhost:11434/api/tags")!)
    }

    @Test("authorize(url:) re-checks every call — a mode change mid-session takes effect immediately")
    func authorizeReflectsLiveModeChanges() throws {
        let broker = QEgressBroker(initialMode: .offline)
        let host = URL(string: "https://api.anthropic.com/v1/messages")!

        func attemptAuthorize() -> Bool {
            do {
                try broker.authorize(url: host)
                return true
            } catch {
                return false
            }
        }

        #expect(attemptAuthorize() == false)

        // Simulates a retry/replan re-entering the same send call after the
        // user switches tiers mid-session — the very next check must reflect
        // the new mode, not a decision cached from the earlier attempt.
        broker.setMode(.approved(whitelist: ["api.anthropic.com"]))
        #expect(attemptAuthorize() == true)

        // And switching back to offline blocks it again immediately.
        broker.setMode(.offline)
        #expect(attemptAuthorize() == false)
    }

    @Test("authorize(url:) rejects a malformed URL with no host")
    func authorizeRejectsHostlessURL() {
        let broker = QEgressBroker(initialMode: .open)
        // A file:// URL has no host component.
        let hostless = URL(string: "file:///etc/passwd")!
        #expect(throws: QEgressAuthorizationError.self) {
            try broker.authorize(url: hostless)
        }
    }
}

// MARK: - QEgressRedirectGuard (redirect escape prevention)

@Suite("QEgressRedirectGuardTests")
struct QEgressRedirectGuardTests {

    /// A no-op URLSessionTask, sufficient for exercising the redirect
    /// delegate callback in isolation without any real network I/O.
    private func makeDummyTask() -> URLSessionTask {
        URLSession.shared.dataTask(with: URL(string: "https://example.com")!)
    }

    private func makeRedirectResponse(url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test("Redirect to an approved host is followed")
    func allowsRedirectToApprovedHost() async {
        QEgressBroker.shared.setMode(.approved(whitelist: ["api.anthropic.com"]))
        defer { QEgressBroker.shared.setMode(.offline) }

        let guardDelegate = QEgressRedirectGuard()
        let newRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        let followedRequest: URLRequest? = await withCheckedContinuation { continuation in
            guardDelegate.urlSession(
                .shared,
                task: makeDummyTask(),
                willPerformHTTPRedirection: makeRedirectResponse(url: newRequest.url!),
                newRequest: newRequest,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
        #expect(followedRequest != nil)
    }

    @Test("Redirect to a non-approved host is refused, not followed — closes the redirect-escape class")
    func blocksRedirectToUnapprovedHost() async {
        QEgressBroker.shared.setMode(.approved(whitelist: ["api.anthropic.com"]))
        defer { QEgressBroker.shared.setMode(.offline) }

        let guardDelegate = QEgressRedirectGuard()
        // Simulates an approved endpoint 302-ing the request somewhere else
        // entirely — the exact escape this delegate exists to close.
        let newRequest = URLRequest(url: URL(string: "https://evil-tracker.example.com/collect")!)
        let followedRequest: URLRequest? = await withCheckedContinuation { continuation in
            guardDelegate.urlSession(
                .shared,
                task: makeDummyTask(),
                willPerformHTTPRedirection: makeRedirectResponse(url: newRequest.url!),
                newRequest: newRequest,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
        #expect(followedRequest == nil)
    }

    @Test("Redirect to loopback is always followed regardless of mode")
    func allowsRedirectToLoopback() async {
        QEgressBroker.shared.setMode(.offline)
        defer { QEgressBroker.shared.setMode(.offline) }

        let guardDelegate = QEgressRedirectGuard()
        let newRequest = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!)
        let followedRequest: URLRequest? = await withCheckedContinuation { continuation in
            guardDelegate.urlSession(
                .shared,
                task: makeDummyTask(),
                willPerformHTTPRedirection: makeRedirectResponse(url: newRequest.url!),
                newRequest: newRequest,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
        #expect(followedRequest != nil)
    }
}
