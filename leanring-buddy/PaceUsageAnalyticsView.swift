//
//  PaceUsageAnalyticsView.swift
//  leanring-buddy
//
//  Usage analytics dashboard. Reads the local audit-log JSONL stream
//  (~/Library/Application Support/Pace/api-audit.jsonl) and renders
//  Power events, workflow runs and diagnostic latency for the last 24 hours.
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
    let p99Milliseconds: Int
    let timedCount: Int
}

struct PaceUsageAnalyticsView: View {
    private enum Breakdown: String, CaseIterable, Identifiable {
        case powers = "Powers"
        case workflows = "Workflows"
        case diagnostics = "Diagnostics"
        var id: Self { self }
    }
    @State private var breakdown = Breakdown.powers
    @State private var hasLoaded = false
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
                metric("Tracked turns", value: snapshot.turnCount.formatted())
                metric("MCP tools used", value: snapshot.toolCount.formatted())
                metric("Event error rate", value: rate(snapshot.failureCount, of: snapshot.eventCount))
                    .help("\(snapshot.failureCount) failures across \(snapshot.eventCount) recorded events")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Picker("Group usage by", selection: $breakdown) {
                ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .pointerCursor()
            .padding(.horizontal, 24)
            Text(caption)
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.vertical, 8)
            if !hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if breakdown == .workflows {
                if snapshot.workflowRows.isEmpty {
                    empty(
                        "No workflow activity",
                        detail: "A saved workflow will appear here when Pace records a run or dispatch.")
                } else {
                    Table(snapshot.workflowRows) {
                        TableColumn("Workflow") { row in
                            VStack(alignment: .leading) {
                                Text(row.name).lineLimit(1).help(row.name)
                                Text(workflowKind(row.id)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        TableColumn("Starts only") { Text(($0.dispatches + $0.unfinished).formatted()) }.width(70)
                        TableColumn("Finished") { Text($0.finished.formatted()) }.width(56)
                        TableColumn("Error rate") { Text(rate($0.failures, of: $0.finished)) }.width(65)
                        TableColumn("Median") { Text(latency($0.durations, 0.50)) }.width(65)
                        TableColumn("P95") { Text(latency($0.durations, 0.95)) }.width(65)
                        TableColumn("P99") { Text(latency($0.durations, 0.99)) }.width(65)
                    }
                }
            } else {
                let rows = breakdown == .powers ? snapshot.powerRows : snapshot.rows
                if rows.isEmpty {
                    empty(
                        breakdown == .powers ? "No attributed Power activity" : "No recent events",
                        detail: breakdown == .powers
                            ? "Calls with a known Power appear here. Other activity is available in Diagnostics."
                            : "Recorded events from the last 24 hours appear here.")
                } else {
                    Table(rows) {
                        TableColumn(breakdown == .powers ? "Power" : "Source") { row in
                            VStack(alignment: .leading) {
                                Text(row.subsystem)
                                if !row.target.isEmpty {
                                    Text(row.target).lineLimit(1).font(.caption).foregroundStyle(.secondary).help(
                                        row.target)
                                }
                            }
                        }
                        TableColumn("Events") { Text($0.callCount.formatted()) }.width(54)
                        TableColumn("Errors") { Text($0.failureCount.formatted()) }.width(46)
                        TableColumn("Error rate") { Text(rate($0.failureCount, of: $0.callCount)) }.width(65)
                        TableColumn("Median") { Text(duration($0.p50Milliseconds, measured: $0.timedCount)) }.width(65)
                        TableColumn("P95") { Text(duration($0.p95Milliseconds, measured: $0.timedCount)) }.width(65)
                        TableColumn("P99") { Text(duration($0.p99Milliseconds, measured: $0.timedCount)) }.width(65)
                    }
                }
            }
        }
        .task(id: refreshSequence) {
            let result = await Task.detached(priority: .utility) {
                PaceUsageSnapshot(
                    logData: PaceAPIAuditLog.shared.retainedLogData(), now: Date(),
                    workflowRecords: PaceSkillRunJournal.shared.readAllRecords())
            }.value
            if !Task.isCancelled {
                snapshot = result
                hasLoaded = true
            }
        }
    }

    private var caption: String {
        switch breakdown {
        case .powers:
            "Error rate uses attributed events. Median, P95 and P99 measure individual actions and tool calls."
        case .workflows:
            "Starts only includes dispatches and unfinished runs. Error rate uses finished runs. Times use paired records. Older runs have one-second precision."
        case .diagnostics: "Error rate is the share of events with a recorded failure. Times measure individual events."
        }
    }

    private func empty(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "clock", description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workflowKind(_ id: String) -> String {
        switch id.split(separator: ":").first {
        case "skill": "Workflow"
        case "flow": "Recorded workflow"
        case "program", "automation": "Saved Power"
        case "bundled": "Installed workflow"
        case "shortcut": "Apple Shortcut"
        default: "Workflow"
        }
    }

    private func rate(_ errors: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return (Double(errors) / Double(total)).formatted(.percent.precision(.fractionLength(0...1)))
    }

    private func latency(_ sorted: [Int], _ fraction: Double) -> String {
        duration(PaceUsageSnapshot.percentile(sorted, fraction: fraction), measured: sorted.count)
    }

    private func duration(_ milliseconds: Int, measured: Int) -> String {
        guard measured > 0 else { return "—" }
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return "\((Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(0...1)))) s"
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
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

    var powerRows: [PaceSubsystemUsageStats] = []
    var workflowRows: [PaceWorkflowUsage] = []
    var eventCount = 0

    private struct PowerMetadata: Decodable {
        let title: String
        let operations: [String]
    }

    private static let actionOwners: [String: String] = {
        let bundle = Bundle.main
        let url =
            bundle.url(forResource: "usage-powers", withExtension: "json")
            ?? bundle.url(forResource: "usage-powers", withExtension: "json", subdirectory: "Resources")
        guard let url, let data = try? Data(contentsOf: url),
            let powers = try? JSONDecoder().decode([String: PowerMetadata].self, from: data)
        else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: powers.values.flatMap { power in
                power.operations.map { ($0, power.title) }
            })
    }()

    private struct Group: Hashable {
        let subsystem: String
        let target: String
    }

    private struct Samples {
        var durations: [Int] = []
        var count = 0
        var failures = 0

        mutating func record(duration: Int?, failed: Bool) {
            count += 1
            if failed { failures += 1 }
            if let duration, duration >= 0 { durations.append(duration) }
        }
    }

    private static func statistics(_ groups: [Group: Samples]) -> [PaceSubsystemUsageStats] {
        groups.map { group, samples in
            let durations = samples.durations.sorted()
            return PaceSubsystemUsageStats(
                id: "\(group.subsystem.utf8.count):\(group.subsystem)\(group.target)",
                subsystem: group.subsystem, target: group.target, callCount: samples.count,
                failureCount: samples.failures, p50Milliseconds: percentile(durations, fraction: 0.50),
                p95Milliseconds: percentile(durations, fraction: 0.95),
                p99Milliseconds: percentile(durations, fraction: 0.99), timedCount: durations.count)
        }.sorted { first, second in
            first.callCount == second.callCount ? first.id < second.id : first.callCount > second.callCount
        }
    }

    init(logData: [Data], now: Date, workflowRecords: [PaceSkillRunRecord] = []) {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let seconds = Date.ISO8601FormatStyle()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var groups: [Group: Samples] = [:]
        var powers: [Group: Samples] = [:]
        var dispatches: [String: Int] = [:]
        var usedTools = Set<String>()
        var turns = Set<String>()
        for generation in logData {
            for line in generation.split(separator: 0x0A) {
                guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let timestamp = entry["at"] as? String,
                    let date = try? (timestamp.contains(".") ? fractional : seconds).parse(timestamp),
                    date >= cutoff, date <= now, let subsystem = entry["subsystem"] as? String,
                    let operation = entry["operation"] as? String
                else { continue }
                let target = entry["target"] as? String ?? ""
                let outcome = entry["outcome"] as? String ?? ""
                let recordedDuration = entry["durationMilliseconds"] as? Int
                // Several legacy producers used zero for lifecycle notifications without a timer.
                let timedZero =
                    entry["durationWasMeasured"] as? Bool == true
                    || (subsystem == "action" && (operation == "mcp_call" || Self.actionOwners[operation] != nil))
                    || (subsystem == "mcp" && operation == "tools/call")
                let duration = recordedDuration == 0 && !timedZero ? nil : recordedDuration
                let failed = PaceAPIAuditEntry.isRecordedFailure(outcome)
                if let turn = entry["turnId"] as? String, !turn.isEmpty { turns.insert(turn) }
                let dispatch = subsystem == "workflow" && operation == "dispatch" && outcome == "dispatched"
                groups[Group(subsystem: subsystem, target: target), default: Samples()].record(
                    duration: dispatch ? nil : duration, failed: failed)
                if dispatch, !target.isEmpty { dispatches[target, default: 0] += 1 }
                let power: String?
                if subsystem == "mcp", operation == "tools/call", !target.isEmpty {
                    usedTools.insert(target)
                    power = "Integrations"
                } else if subsystem == "action" {
                    power = Self.actionOwners[operation]
                } else if subsystem == "reminders", ["list", "add", "complete"].contains(operation) {
                    power = "To-do List"
                } else {
                    power = nil
                }
                if let power {
                    powers[Group(subsystem: power, target: ""), default: Samples()].record(
                        duration: duration, failed: failed)
                }
            }
        }
        rows = Self.statistics(groups)
        powerRows = Self.statistics(powers)
        workflowRows = PaceWorkflowUsage.aggregate(workflowRecords, dispatches: dispatches, cutoff: cutoff, now: now)
        turnCount = turns.count
        toolCount = usedTools.count
        failureCount = rows.reduce(0) { $0 + $1.failureCount }
        eventCount = rows.reduce(0) { $0 + $1.callCount }
    }

    static func percentile(_ sortedSamples: [Int], fraction: Double) -> Int {
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

nonisolated struct PaceWorkflowUsage: Identifiable {
    let id: String
    var dispatches = 0
    var unfinished = 0
    var finished = 0
    var failures = 0
    var durations: [Int] = []

    var total: Int { dispatches + unfinished + finished }
    var name: String {
        String(id.split(separator: ":", maxSplits: 1).last ?? Substring(id))
    }

    static func aggregate(_ records: [PaceSkillRunRecord], dispatches: [String: Int], cutoff: Date, now: Date)
        -> [Self]
    {
        struct RunKey: Hashable {
            let workflow: String
            let run: String
        }
        struct Run {
            var start: PaceSkillRunRecord?
            var finish: PaceSkillRunRecord?
        }
        var runs: [RunKey: Run] = [:]
        for record in records where record.measuredAt <= now && !record.skillSlug.isEmpty && !record.runId.isEmpty {
            let key = RunKey(workflow: "skill:" + record.skillSlug, run: record.runId)
            switch record.phase {
            case "started":
                if runs[key]?.start.map({ record.measuredAt >= $0.measuredAt }) != true {
                    runs[key, default: Run()].start = record
                }
            case "completed", "failed":
                if runs[key]?.finish.map({ record.measuredAt >= $0.measuredAt }) != true {
                    runs[key, default: Run()].finish = record
                }
            default: continue
            }
        }
        var result = [String: Self]()
        for (id, count) in dispatches { result[id] = Self(id: id, dispatches: count) }
        for (key, run) in runs {
            guard let activityDate = run.finish?.measuredAt ?? run.start?.measuredAt, activityDate >= cutoff else {
                continue
            }
            var workflow = result[key.workflow] ?? Self(id: key.workflow)
            if let finish = run.finish {
                workflow.finished += 1
                if finish.phase == "failed" { workflow.failures += 1 }
                if let start = run.start, start.measuredAt <= finish.measuredAt,
                    start.measuredAt < finish.measuredAt
                        || (start.millisecondsSince1970 != nil && finish.millisecondsSince1970 != nil)
                {
                    workflow.durations.append(
                        Int((finish.measuredAt.timeIntervalSince(start.measuredAt) * 1000).rounded()))
                }
            } else {
                workflow.unfinished += 1
            }
            result[key.workflow] = workflow
        }
        return result.values.map { workflow in
            var sorted = workflow
            sorted.durations.sort()
            return sorted
        }.sorted { $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total }
    }
}
