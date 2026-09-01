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
