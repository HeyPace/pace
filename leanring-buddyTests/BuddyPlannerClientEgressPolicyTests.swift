//
//  BuddyPlannerClientEgressPolicyTests.swift
//  leanring-buddyTests
//
//  Unit tests for BuddyPlannerClientFactory.applyEgressPolicy (C-2).
//
//  This is the pure mapping from "what host, if any, does the tier being
//  constructed need" to QEgressBroker's mode, tested directly rather than
//  through `makeDefault()` (which reads real UserDefaults/Keychain state and
//  would make these tests environment-dependent).
//

import Testing
import Foundation
@testable import Pace

@Suite("BuddyPlannerClientEgressPolicyTests")
@MainActor
struct BuddyPlannerClientEgressPolicyTests {

    @Test("nil host sets the broker to offline (loopback-only)")
    func nilHostSetsOffline() {
        QEgressBroker.shared.setMode(.approved(whitelist: ["stale-host.example.com"]))
        BuddyPlannerClientFactory.applyEgressPolicy(forOffDeviceHost: nil)
        #expect(QEgressBroker.shared.getMode() == .offline)
    }

    @Test("A concrete host sets an approved whitelist containing ONLY that host")
    func concreteHostSetsExactWhitelist() {
        BuddyPlannerClientFactory.applyEgressPolicy(forOffDeviceHost: "api.anthropic.com")
        #expect(QEgressBroker.shared.getMode() == .approved(whitelist: ["api.anthropic.com"]))
    }

    @Test("Host is lowercased so case differences never create two distinct whitelist entries")
    func hostIsLowercased() {
        BuddyPlannerClientFactory.applyEgressPolicy(forOffDeviceHost: "API.Anthropic.COM")
        #expect(QEgressBroker.shared.getMode() == .approved(whitelist: ["api.anthropic.com"]))
    }

    @Test("An empty-string host is treated as no host — sets offline, not an empty-string whitelist entry")
    func emptyHostSetsOffline() {
        QEgressBroker.shared.setMode(.approved(whitelist: ["stale-host.example.com"]))
        BuddyPlannerClientFactory.applyEgressPolicy(forOffDeviceHost: "")
        #expect(QEgressBroker.shared.getMode() == .offline)
    }

    @Test("Switching from an off-device host back to nil clears the previous whitelist — no stale entries persist")
    func switchingBackToLocalClearsPriorWhitelist() {
        BuddyPlannerClientFactory.applyEgressPolicy(forOffDeviceHost: "api.openai.com")
        #expect(QEgressBroker.shared.getMode() == .approved(whitelist: ["api.openai.com"]))

        BuddyPlannerClientFactory.applyEgressPolicy(forOffDeviceHost: nil)
        #expect(QEgressBroker.shared.getMode() == .offline)

        // The previously-approved host must not still be reachable.
        #expect(throws: QEgressAuthorizationError.self) {
            try QEgressBroker.shared.authorize(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        }
    }
}
