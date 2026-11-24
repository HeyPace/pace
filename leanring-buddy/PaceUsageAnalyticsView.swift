//
//  PaceUsageAnalyticsView.swift
//  leanring-buddy
//
//  Usage analytics dashboard. Reads the local audit-log JSONL stream
//  (~/Library/Application Support/Pace/api-audit.jsonl) and renders
//  per-subsystem counts, error rates, and p50/p95 latency for the last
//  24h. Same data the audit-summary script shows from the command line.
//

import Foundation
import SaaSMakerUI
import SwiftUI

nonisolated struct PaceSubsystemUsageStats: Identifiable, Equatable {
    let id: String
    let subsystem: String
    let target: String
    let callCount: Int
    let failureCount: Int
    let p50Milliseconds: Int
    let p95Milliseconds: Int
}

struct PaceUsageAnalyticsView: View {
    @State private var snapshot = PaceUsageSnapshot()
    @State private var refreshSequence = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last 24 hours").font(.headline)
                    Text("Recorded on this Mac").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    refreshSequence += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 6)
                .pointerCursor()
                .accessibilityLabel("Refresh usage")
                .help("Refresh usage")
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)

            HStack(spacing: 30) {
                metric("Turns", value: snapshot.turnCount)
                metric("MCP tools used", value: snapshot.toolCount)
                metric("Failure records", value: snapshot.failureCount)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if snapshot.rows.isEmpty {
                ContentUnavailableView(
                    "No recent activity", systemImage: "clock",
                    description: Text("Requests and tool activity from the last 24 hours appear here."))
            } else {
                Table(snapshot.rows) {
                    TableColumn("Subsystem") { row in
                        Text(row.subsystem)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Target") { row in
                        Text(row.target.isEmpty ? "—" : row.target).font(DS.Typography.metadata)
                    }
                    TableColumn("Events") { row in
                        Text("\(row.callCount)")
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Failures") { row in
                        Text("\(row.failureCount)")
                            .foregroundColor(row.failureCount > 0 ? .orange : .secondary)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Median ms") { row in
                        Text("\(row.p50Milliseconds)")
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("P95 ms") { row in
                        Text("\(row.p95Milliseconds)")
                    }
                    .width(min: 60, ideal: 70)
                }
                .alternatingRowBackgrounds(.disabled)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .task(id: refreshSequence) {
            let result = await Task.detached(priority: .utility) {
                PaceUsageSnapshot(logData: PaceAPIAuditLog.shared.retainedLogData(), now: Date())
            }.value
            if !Task.isCancelled { snapshot = result }
        }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

nonisolated struct PaceUsageSnapshot {
    var rows: [PaceSubsystemUsageStats] = []
    var turnCount = 0
    var toolCount = 0
    var failureCount = 0

    init() {}

    init(logData: [Data], now: Date) {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFractional = ISO8601DateFormatter()
        let cutoffDate = now.addingTimeInterval(-24 * 3600)

        var statsBucket: [String: [(durationMilliseconds: Int, isError: Bool)]] = [:]
        var usedMCPTools = Set<String>()
        var seenTurnIds: Set<String> = []
        var keyToHumanLabel: [String: (subsystem: String, target: String)] = [:]
        for generation in logData {
            for entryData in generation.split(separator: 0x0A) {
                guard let entryDictionary = try? JSONSerialization.jsonObject(with: entryData) as? [String: Any] else {
                    continue
                }
                guard let timestampString = entryDictionary["at"] as? String,
                    let timestampDate = isoFormatter.date(from: timestampString)
                        ?? isoFormatterNoFractional.date(from: timestampString),
                    timestampDate >= cutoffDate, timestampDate <= now
                else {
                    continue
                }
                if let turnId = entryDictionary["turnId"] as? String, !turnId.isEmpty {
                    seenTurnIds.insert(turnId)
                }
                let subsystem = (entryDictionary["subsystem"] as? String) ?? "?"
                let target = (entryDictionary["target"] as? String) ?? "?"
                if subsystem == "mcp", entryDictionary["operation"] as? String == "tools/call",
                    !target.isEmpty, target != "?"
                {
                    usedMCPTools.insert(target)
                }
                let bucketKey = "\(subsystem)|\(target)"
                keyToHumanLabel[bucketKey] = (subsystem, target)
                let durationMilliseconds = (entryDictionary["durationMilliseconds"] as? Int) ?? 0
                let isError = PaceAPIAuditEntry.isRecordedFailure(entryDictionary["outcome"] as? String ?? "")
                statsBucket[bucketKey, default: []].append((durationMilliseconds, isError))
            }
        }

        rows = statsBucket.map { bucketKey, samples in
            let durations = samples.map(\.durationMilliseconds).sorted()
            let errorCount = samples.filter(\.isError).count
            let label = keyToHumanLabel[bucketKey]!
            return PaceSubsystemUsageStats(
                id: bucketKey,
                subsystem: label.subsystem,
                target: label.target,
                callCount: samples.count,
                failureCount: errorCount,
                p50Milliseconds: Self.percentile(durations, fraction: 0.50),
                p95Milliseconds: Self.percentile(durations, fraction: 0.95)
            )
        }.sorted { first, second in
            first.callCount == second.callCount ? first.id < second.id : first.callCount > second.callCount
        }

        turnCount = seenTurnIds.count
        toolCount = usedMCPTools.count
        failureCount = rows.reduce(0) { $0 + $1.failureCount }
    }

    private static func percentile(_ sortedSamples: [Int], fraction: Double) -> Int {
        guard !sortedSamples.isEmpty else { return 0 }
        if fraction == 0.50, sortedSamples.count.isMultiple(of: 2) {
            let middle = sortedSamples.count / 2
            let lower = sortedSamples[middle - 1]
            let upper = sortedSamples[middle]
            return lower + (upper - lower) / 2
        }
        let bucketIndex = Int(ceil(Double(sortedSamples.count) * fraction)) - 1
        return sortedSamples[bucketIndex]
    }
}
