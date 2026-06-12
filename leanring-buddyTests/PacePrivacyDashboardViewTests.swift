//
//  PacePrivacyDashboardViewTests.swift
//  leanring-buddyTests
//
//  Tests the pure aggregation + byte-formatting helpers behind the
//  Privacy dashboard. The SwiftUI view itself is exercised indirectly
//  (any compile failure in the view shows up here as a missing type),
//  but the meaningful coverage is the per-tier byte/turn math that the
//  headline card depends on.
//

import Foundation
import Testing

@testable import Pace

struct PacePrivacyDashboardViewTests {

    private func makeAuditEntry(
        subsystem: String,
        target: String = "model/v1",
        inputCharacterCount: Int? = nil,
        outputCharacterCount: Int? = nil,
        outcome: String = "ok",
        at timestamp: Date = Date()
    ) -> PaceAPIAuditEntry {
        PaceAPIAuditEntry(
            at: timestamp,
            turnId: UUID().uuidString,
            subsystem: subsystem,
            operation: "chat.completions",
            target: target,
            durationMilliseconds: 100,
            outcome: outcome,
            inputCharacterCount: inputCharacterCount,
            outputCharacterCount: outputCharacterCount,
            detail: nil
        )
    }

    // MARK: - Tier classification

    @Test func directAPISubsystemIsClassifiedAsDirectAPITier() {
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "planner.directAPI") == .directAPI)
    }

    @Test func cloudBridgeSubsystemIsClassifiedAsCloudBridgeTier() {
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "planner.cloudBridge") == .cloudBridge)
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "cloudBridge.transport") == .cloudBridge)
    }

    @Test func localPlannerAndOtherSubsystemsAreNotOffDevice() {
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "planner") == nil)
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "vlm") == nil)
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "tts") == nil)
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "mcp") == nil)
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "embeddings") == nil)
        #expect(PacePrivacyDashboardAggregator.tier(forSubsystem: "dictation") == nil)
    }

    // MARK: - Zero-traffic snapshot

    @Test func zeroOffDeviceTrafficYieldsZeroBytesAndZeroCalls() {
        let auditEntries = [
            makeAuditEntry(subsystem: "planner", inputCharacterCount: 500),
            makeAuditEntry(subsystem: "vlm", inputCharacterCount: 1024),
            makeAuditEntry(subsystem: "mcp"),
            makeAuditEntry(subsystem: "tts")
        ]
        let snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: auditEntries)
        #expect(snapshot.totalOffDeviceBytesSent == 0)
        #expect(snapshot.totalOffDeviceCallCount == 0)
        #expect(snapshot.localPlannerEntryCount == 1)
    }

    // MARK: - Non-zero traffic snapshot

    @Test func directAPIEntriesAccumulateIntoDirectAPITier() {
        let auditEntries = [
            makeAuditEntry(
                subsystem: "planner.directAPI",
                target: "anthropic/claude-sonnet-4.7",
                inputCharacterCount: 1500
            ),
            makeAuditEntry(
                subsystem: "planner.directAPI",
                target: "anthropic/claude-sonnet-4.7",
                inputCharacterCount: 500
            ),
            makeAuditEntry(subsystem: "planner", inputCharacterCount: 100)
        ]
        let snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: auditEntries)
        #expect(snapshot.totalOffDeviceBytesSent == 2000)
        #expect(snapshot.totalOffDeviceCallCount == 2)

        let directAPIStats = snapshot.perTierStats.first { $0.tier == .directAPI }
        #expect(directAPIStats?.callCount == 2)
        #expect(directAPIStats?.bytesSent == 2000)

        let cloudBridgeStats = snapshot.perTierStats.first { $0.tier == .cloudBridge }
        #expect(cloudBridgeStats?.callCount == 0)
        #expect(cloudBridgeStats?.bytesSent == 0)
    }

    @Test func cloudBridgeEntriesAccumulateIntoCloudBridgeTier() {
        let auditEntries = [
            makeAuditEntry(
                subsystem: "planner.cloudBridge",
                target: "claude/sonnet",
                inputCharacterCount: 3000
            )
        ]
        let snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: auditEntries)
        #expect(snapshot.totalOffDeviceBytesSent == 3000)
        let cloudBridgeStats = snapshot.perTierStats.first { $0.tier == .cloudBridge }
        #expect(cloudBridgeStats?.callCount == 1)
        #expect(cloudBridgeStats?.bytesSent == 3000)
    }

    @Test func perTargetBytesSortDescendingByVolume() {
        let auditEntries = [
            makeAuditEntry(
                subsystem: "planner.directAPI",
                target: "anthropic/claude-sonnet-4.7",
                inputCharacterCount: 100
            ),
            makeAuditEntry(
                subsystem: "planner.directAPI",
                target: "openai/gpt-4o-mini",
                inputCharacterCount: 5000
            ),
            makeAuditEntry(
                subsystem: "planner.directAPI",
                target: "openai/gpt-4o-mini",
                inputCharacterCount: 2000
            )
        ]
        let snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: auditEntries)
        let topTarget = snapshot.perTargetStats.first
        #expect(topTarget?.target == "openai/gpt-4o-mini")
        #expect(topTarget?.bytesSent == 7000)
    }

    // MARK: - Cutoff filter

    @Test func cutoffFilterDropsEntriesOlderThanWindow() {
        let oldTimestamp = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        let recentTimestamp = Date(timeIntervalSinceNow: -10 * 60)
        let cutoffTimestamp = Date(timeIntervalSinceNow: -24 * 3600)

        let auditEntries = [
            makeAuditEntry(
                subsystem: "planner.directAPI",
                inputCharacterCount: 999_999,
                at: oldTimestamp
            ),
            makeAuditEntry(
                subsystem: "planner.directAPI",
                inputCharacterCount: 100,
                at: recentTimestamp
            )
        ]
        let snapshot = PacePrivacyDashboardAggregator.aggregate(
            auditEntries: auditEntries,
            sinceCutoff: cutoffTimestamp
        )
        #expect(snapshot.totalOffDeviceBytesSent == 100)
        #expect(snapshot.totalOffDeviceCallCount == 1)
    }

    // MARK: - Byte formatter

    @Test func byteFormatterRendersZeroAsZeroBytes() {
        #expect(PacePrivacyByteFormatter.format(bytes: 0) == "0 bytes")
        #expect(PacePrivacyByteFormatter.format(bytes: -5) == "0 bytes")
    }

    @Test func byteFormatterRendersBytesUnderOneKilobyte() {
        #expect(PacePrivacyByteFormatter.format(bytes: 1) == "1 bytes")
        #expect(PacePrivacyByteFormatter.format(bytes: 1023) == "1023 bytes")
    }

    @Test func byteFormatterRendersKilobytesWithOneDecimal() {
        #expect(PacePrivacyByteFormatter.format(bytes: 1024) == "1.0 KB")
        #expect(PacePrivacyByteFormatter.format(bytes: 2048) == "2.0 KB")
    }

    @Test func byteFormatterRendersMegabytesWithTwoDecimals() {
        let twoMegabytes = 2 * 1024 * 1024
        #expect(PacePrivacyByteFormatter.format(bytes: twoMegabytes) == "2.00 MB")
    }
}
