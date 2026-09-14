//
//  PaceNowSettingsTab.swift
//  leanring-buddy
//
//  Command Center → Now tab content — the Gap #5 "product-surface
//  consolidation" read-only dashboard
//  (docs/current/plans/autonomous-companion-consolidation.md, "5.
//  Product-surface consolidation"). Answers "what is Que aware of right
//  now?" across three sections: Now (current activity + at most one
//  active opportunity), Working (background agent tasks), and Memory (a
//  bounded, sensitive-topic-filtered preview of remembered facts).
//
//  This view is a pure PRESENTATION layer. Every field it renders comes
//  from PaceSurfaceProjection.swift's existing pure projection functions
//  (via CompanionManager+SurfaceProjection.swift's `nowSurfaceState` /
//  `workingSurfaceState` / `memorySurfaceState`) — it never reads
//  `activityGoalStore`, `episodicFactStore`, or `PaceBackgroundAgentRunner`
//  directly, so the privacy filtering and bounding those projections
//  already implement (sensitive-topic exclusion, the 20/50 caps, the
//  exclusion of literal resultSummary/failure-detail text) cannot be
//  bypassed or duplicated here.
//
//  This is deliberately NOT a replacement for the existing, separate
//  "Activity history" (thread-memory config + recent actions log) or
//  "Memory" (full episodic-fact roster with delete/reset) Settings tabs —
//  those remain the deep management surfaces. This tab is the lightweight,
//  read-only, at-a-glance counterpart the consolidation plan describes;
//  it links out to "Memory" in Settings for management rather than
//  duplicating delete/reset controls here.
//
//  Refresh model: matches PacePrivacyDashboardView's existing convention
//  exactly — `.onAppear(perform: refresh)` reads the current projection
//  snapshots into local `@State`, so opening the tab always shows current
//  data without introducing a new timer/polling mechanism. The Working
//  section additionally observes `PaceBackgroundAgentRunner.shared`
//  directly (the same pattern PaceTasksSettingsTab already uses for
//  PaceCronScheduler.shared) purely so SwiftUI re-renders while a
//  background task's state changes with the tab open — the data itself
//  still only ever comes from `PaceWorkingSurfaceProjection.project(...)`.
//

import SwiftUI

struct PaceNowSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var backgroundAgentRunner = PaceBackgroundAgentRunner.shared

    @State private var nowSurfaceState: PaceNowSurfaceState = .empty
    @State private var memorySurfaceState: PaceMemorySurfaceState = .empty

    private var workingSurfaceState: PaceWorkingSurfaceState {
        PaceWorkingSurfaceProjection.project(backgroundAgentTasks: backgroundAgentRunner.tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local only. Composed from what Que already observed on this Mac — no new capture, no cloud fallback.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .background(DS.Colors.borderSubtle)

            nowSection

            Divider()
                .background(DS.Colors.borderSubtle)

            workingSection

            Divider()
                .background(DS.Colors.borderSubtle)

            memorySection
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        nowSurfaceState = companionManager.nowSurfaceState
        memorySurfaceState = companionManager.memorySurfaceState
    }

    // MARK: - Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Now")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            if let activity = nowSurfaceState.activity {
                paceSettingsInfoRow(
                    title: "Current activity",
                    value: "\(activity.subject) · \(Int(activity.confidence * 100))% confidence"
                )
            } else {
                Text("No current activity detected.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }

            if let opportunity = nowSurfaceState.opportunity {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DS.Colors.accent)
                            .frame(width: 6, height: 6)
                        Text(opportunity.category)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.accent)
                    }
                    Text(opportunity.spokenText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } else {
                Text("Nothing to suggest right now.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Working

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            if workingSurfaceState.tasks.isEmpty {
                Text("No background work right now.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(workingSurfaceState.tasks) { task in
                        workingTaskRow(task)
                    }
                }
            }
        }
    }

    private func workingTaskRow(_ task: PaceWorkingSurfaceTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let currentStepDescription = task.currentStepDescription {
                    Text(currentStepDescription)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if task.hasResult {
                    Text("Has a result")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer(minLength: 0)
            workingStateBadge(task.state)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    private func workingStateBadge(_ state: PaceWorkingSurfaceTaskState) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case .queued: return ("Queued", DS.Colors.textTertiary)
            case .running: return ("Running", DS.Colors.accent)
            case .completed: return ("Completed", DS.Colors.success)
            case .cancelled: return ("Cancelled", DS.Colors.textTertiary)
            case .failed: return ("Failed", DS.Colors.failure)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Memory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("· Safe preview")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Text("A bounded, filtered preview. Manage or delete remembered facts in Settings → Memory.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if memorySurfaceState.facts.isEmpty {
                Text("Nothing remembered yet.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(memorySurfaceState.facts) { fact in
                        memoryFactRow(fact)
                    }
                }
            }
        }
    }

    private func memoryFactRow(_ fact: PaceMemorySurfaceFact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(fact.subject) \(fact.predicate) \(fact.value)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(String(format: "%.0f%% conf", fact.confidence * 100))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }
}
