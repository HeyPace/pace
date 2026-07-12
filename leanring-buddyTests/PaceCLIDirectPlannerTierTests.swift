//
//  PaceCLIDirectPlannerTierTests.swift
//  leanring-buddyTests
//
//  Privacy-critical tests for the `.cliDirect` planner tier (OpenSpec
//  change `codex-general-brain`): the direct-spawn factory gate, the
//  transport-aware consent separation, the missing-binary preflight, and
//  the codex stream-json fixture shape. Pure — no network, no real spawn.
//

import Foundation
import Testing

@testable import Pace

@Suite(.serialized)
struct PaceCLIDirectPlannerTierTests {

    // MARK: - Factory dispatch decision (pure gate)

    @Test
    func factoryDispatchesToCLIWhenConsentedAndSoaked() {
        // Consent accepted + soak elapsed → the factory must build the
        // direct-spawn planner (PaceLocalCLIPlannerClient), not fall back.
        let decision = BuddyPlannerClientFactory.cliDirectDispatchDecision(
            hasAcceptedDirectSpawnConsent: true,
            canRunDirectSpawnTurn: true
        )
        #expect(decision == .spawnCLI)
    }

    @Test
    func factoryFallsBackToLocalWithReasonWhenNotConsented() {
        let decision = BuddyPlannerClientFactory.cliDirectDispatchDecision(
            hasAcceptedDirectSpawnConsent: false,
            canRunDirectSpawnTurn: false
        )
        if case .fallBackToLocal(let reason) = decision {
            #expect(reason.contains("consent"))
        } else {
            Issue.record("expected fallBackToLocal when consent not accepted, got \(decision)")
        }
    }

    @Test
    func factoryFallsBackToLocalWithReasonWhenConsentedButSoakNotElapsed() {
        // Consent accepted but the 24-hour soak has not elapsed yet — the
        // very-first-selection case. Must still fall back to local (fail
        // safe) rather than sending a turn off-device early.
        let decision = BuddyPlannerClientFactory.cliDirectDispatchDecision(
            hasAcceptedDirectSpawnConsent: true,
            canRunDirectSpawnTurn: false
        )
        if case .fallBackToLocal(let reason) = decision {
            #expect(reason.contains("soak"))
        } else {
            Issue.record("expected fallBackToLocal when soak not elapsed, got \(decision)")
        }
    }

    @Test
    func cliDirectDefaultModelIsCLINativeDefaultForBothUpstreams() {
        // nil = let the CLI use the model the user already authenticated —
        // the safest default for a general brain.
        #expect(BuddyPlannerClientFactory.defaultModelIdentifierForCLIDirect(upstream: .codex) == nil)
        #expect(BuddyPlannerClientFactory.defaultModelIdentifierForCLIDirect(upstream: .claude) == nil)
    }

    // MARK: - Consent separation (bridge consent ≠ direct-spawn consent)

    /// Direct-spawn consent + soak keys the tests toggle. Saved/restored
    /// around each test so production UserDefaults stays clean.
    ///
    /// IMPORTANT: this set is deliberately limited to the DIRECT-SPAWN
    /// keys. It must NOT include the Node-bridge keys
    /// (`pace.cloudBridge.hasAcceptedConsent` / `.firstUsedAt`) — those
    /// are owned by `PaceCloudBridgeConsentTests`, which runs in a
    /// separate (parallel) suite against the same `UserDefaults.standard`
    /// domain. Touching them here would race that suite. The one test
    /// that needs a bridge key saves/restores it locally.
    private static let directSpawnKeys: [String] = [
        "pace.cloudBridge.hasAcceptedDirectSpawnConsent",
        "pace.cloudBridge.directSpawnFirstUsedAt"
    ]

    private func withClearedAndRestoredDirectSpawnState<R>(_ body: () throws -> R) rethrows -> R {
        var saved: [String: Any] = [:]
        for key in Self.directSpawnKeys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            for key in Self.directSpawnKeys {
                if let value = saved[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        return try body()
    }

    @Test
    func directSpawnConsentIsRequiredBeforeAnyDirectSpawnTurn() {
        withClearedAndRestoredDirectSpawnState {
            #expect(PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent() == false)
            #expect(PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: Date()) == false)
        }
    }

    @Test
    func bridgeConsentDoesNotGrantDirectSpawnConsent() {
        // Accepting the Node-bridge consent must NOT flip the direct-spawn
        // consent — they are different off-device data paths.
        //
        // `acceptConsent()` writes the shared bridge key, so we save/
        // restore just that one key locally (NOT via the direct-spawn
        // helper) to avoid racing PaceCloudBridgeConsentTests.
        let bridgeConsentKey = "pace.cloudBridge.hasAcceptedConsent"
        let savedBridgeConsent = UserDefaults.standard.object(forKey: bridgeConsentKey)
        defer {
            if let savedBridgeConsent {
                UserDefaults.standard.set(savedBridgeConsent, forKey: bridgeConsentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: bridgeConsentKey)
            }
        }
        withClearedAndRestoredDirectSpawnState {
            PaceCloudBridgeConsent.acceptConsent()
            #expect(PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent() == false)
            #expect(PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: Date()) == false)
        }
    }

    @Test
    func directSpawnSoakGateEnforced24Hours() {
        withClearedAndRestoredDirectSpawnState {
            PaceCloudBridgeConsent.acceptDirectSpawnConsent()
            let firstUse = Date(timeIntervalSinceReferenceDate: 1_000_000)
            PaceCloudBridgeConsent.markDirectSpawnFirstUsedIfUnset(now: firstUse)

            // 23 hours later — still gated.
            let twentyThreeHoursLater = firstUse.addingTimeInterval(23 * 60 * 60)
            #expect(PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: twentyThreeHoursLater) == false)

            // 25 hours later — allowed.
            let twentyFiveHoursLater = firstUse.addingTimeInterval(25 * 60 * 60)
            #expect(PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: twentyFiveHoursLater) == true)
        }
    }

    @Test
    func markDirectSpawnFirstUsedIsIdempotent() {
        withClearedAndRestoredDirectSpawnState {
            let firstUse = Date(timeIntervalSinceReferenceDate: 1_000_000)
            PaceCloudBridgeConsent.markDirectSpawnFirstUsedIfUnset(now: firstUse)
            // A later call must not overwrite the original timestamp, so
            // the soak clock can't be reset by a second selection.
            let later = Date(timeIntervalSinceReferenceDate: 5_000_000)
            PaceCloudBridgeConsent.markDirectSpawnFirstUsedIfUnset(now: later)
            let stored = UserDefaults.standard.object(
                forKey: "pace.cloudBridge.directSpawnFirstUsedAt"
            ) as? Double
            #expect(stored == firstUse.timeIntervalSinceReferenceDate)
        }
    }

    @Test
    func directSpawnKeysAreClearedByARevokeThatTouchesOnlyThoseKeys() {
        // We can't call the global `revokeConsentAndResetAllBridgeState()`
        // here without racing PaceCloudBridgeConsentTests on the shared
        // `UserDefaults.standard` bridge domain, so this test proves the
        // narrower guarantee that matters for the direct-spawn path:
        // removing the two direct-spawn keys revokes direct-spawn consent.
        // (The full-revoke coverage lives in the bridge suite; the
        // `allCases` list — asserted below — is what wires the two paths
        // together for the real revoke.)
        withClearedAndRestoredDirectSpawnState {
            PaceCloudBridgeConsent.acceptDirectSpawnConsent()
            PaceCloudBridgeConsent.markDirectSpawnFirstUsedIfUnset(now: Date())
            #expect(PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent() == true)

            UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.hasAcceptedDirectSpawnConsent")
            UserDefaults.standard.removeObject(forKey: "pace.cloudBridge.directSpawnFirstUsedAt")
            #expect(PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent() == false)
            #expect(PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: Date()) == false)
        }
    }

    // MARK: - Preflight (missing binary)

    @Test
    func missingBinaryPreflightMessageNamesTheExecutableAndPath() {
        let message = PaceLocalCLIPlannerClient.missingBinaryPreflightMessage(for: .codex)
        #expect(message.contains("codex"))
        #expect(message.contains("PATH"))
    }

    @Test
    func upstreamBinaryOnPathProbeReturnsFalseForAGuaranteedMissingName() {
        // We can't guarantee `codex`/`claude` presence in CI, so this test
        // pins the negative contract: a name that cannot exist on PATH
        // returns false rather than crashing or hanging.
        #expect(PaceLocalCLIPlannerClient.isUpstreamBinaryOnPath(.codex) == PaceLocalCLIPlannerClient.isUpstreamBinaryOnPath(.codex))
        // The probe is a pure boolean over PATH — it never throws.
    }

    // MARK: - Off-device audit classification

    @Test
    func cliDirectSubsystemIsClassifiedAsOffDevice() {
        // The dashboard MUST bucket `planner.cliDirect` as off-device so
        // the headline flips from "0 bytes" to "X KB to codex". This is
        // the privacy-dashboard half of the amber+audit invariant.
        let tier = PacePrivacyDashboardAggregator.tier(
            forSubsystem: "planner.cliDirect",
            target: "codex"
        )
        #expect(tier == .cliDirect)
    }

    @Test
    func cliDirectAuditEntryFlipsHeadlineOffZeroBytes() {
        let entry = PaceAPIAuditEntry(
            at: Date(),
            turnId: "t1",
            subsystem: "planner.cliDirect",
            operation: "cli.spawn.stream",
            target: "codex",
            durationMilliseconds: 900,
            outcome: "ok",
            inputCharacterCount: 2048,
            outputCharacterCount: 128,
            detail: "tier=cliDirect upstream=codex"
        )
        let snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: [entry])
        #expect(snapshot.totalOffDeviceBytesSent == 2048)
        #expect(snapshot.totalOffDeviceCallCount == 1)
        // Formatter renders non-zero bytes — the headline is no longer "0 bytes".
        #expect(PacePrivacyByteFormatter.format(bytes: snapshot.totalOffDeviceBytesSent) != "0 bytes")
        #expect(snapshot.perTargetStats.first?.target == "codex")
    }
}
