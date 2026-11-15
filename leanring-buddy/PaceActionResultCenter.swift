//
//  PaceActionResultCenter.swift
//  leanring-buddy
//
//  Small, UI-friendly records for recent local tool plans and outcomes.
//  CompanionManager owns the actual list because it already coordinates
//  planning, approval, execution, and panel state.
//

import Foundation

// `nonisolated`: plain value DTOs whose dependencies
// (`PaceActionExecutionPlan`, `PaceToolPreflightIssue`,
// `PaceActionExecutionObservation`) are already nonisolated. The app
// target's default actor isolation is MainActor, which would otherwise
// pin them there — but the pure `PaceChatTranscriptModel` mapping layer
// (and its off-main-actor tests) needs to read them from a nonisolated
// context.
nonisolated enum PaceActionRunStatus: String, Equatable {
    case planned
    case completed
    case failed
    case denied
    case skipped

    var displayName: String {
        switch self {
        case .planned:
            return "Planned"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        case .denied:
            return "Denied"
        case .skipped:
            return "Skipped"
        }
    }
}

nonisolated struct PaceActionRunRecord: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let status: PaceActionRunStatus
    let title: String
    let detail: String
    let showsInConversation: Bool
    let diagnosticDetail: String?
    let targetResolution: PaceApplicationTargetResolution?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: PaceActionRunStatus,
        title: String,
        detail: String,
        showsInConversation: Bool = true,
        diagnosticDetail: String? = nil,
        targetResolution: PaceApplicationTargetResolution? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.title = title
        self.detail = detail
        self.showsInConversation = showsInConversation
        self.diagnosticDetail = diagnosticDetail
        self.targetResolution = targetResolution
    }

    static func planned(
        actionExecutionPlan: PaceActionExecutionPlan,
        preflightIssues: [PaceToolPreflightIssue]
    ) -> PaceActionRunRecord {
        let actionCount = actionExecutionPlan.flattenedActions.count
        let toolWord = actionCount == 1 ? "tool" : "tools"
        let preflightDetail = PaceToolPreflightIssue.formatForUser(preflightIssues)
        let detail = [actionExecutionPlan.approvalSummary, preflightDetail]
            .compactMap { text in
                let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedText?.isEmpty == false ? trimmedText : nil
            }
            .joined(separator: "\n\n")

        return PaceActionRunRecord(
            status: .planned,
            title: "\(actionCount) \(toolWord) planned",
            detail: detail
        )
    }

    static func completed(observations: [PaceActionExecutionObservation]) -> PaceActionRunRecord {
        func indicatesFailure(_ observation: PaceActionExecutionObservation) -> Bool {
            if observation.requiresFreshInspectionPlan { return false }
            let lowercasedSummary = observation.summary.lowercased()
            return observation.stopsAgentLoop || lowercasedSummary.contains("failed")
                || lowercasedSummary.contains("could not")
                || lowercasedSummary.contains("not granted")
                || lowercasedSummary.contains("does not exist")
        }
        let targetResolution = observations.compactMap(\.targetResolution).last
        let ordinaryObservations = observations.filter { $0.targetResolution == nil }
        let visibleObservations =
            targetResolution != nil && !ordinaryObservations.isEmpty
            ? ordinaryObservations : observations
        let hasFailure = visibleObservations.contains(where: indicatesFailure)
        let needsFreshInspection = visibleObservations.contains(where: \.requiresFreshInspectionPlan)
        let showsInConversation = targetResolution == nil || !ordinaryObservations.isEmpty
        let hasSeparateDiagnostics = observations.contains { $0.userFacingSummary != nil || $0.targetResolution != nil }
        let feedback =
            PaceActionExecutionObservation.formatForUserFeedback(visibleObservations)
            ?? targetResolution?.userFacingSummary ?? "No tool observations returned."
        let title: String
        if hasFailure {
            title = "Action needs attention"
        } else if needsFreshInspection {
            title = "Choosing a window"
        } else if targetResolution != nil && !ordinaryObservations.isEmpty {
            title = "Earlier actions completed"
        } else {
            title = "Action complete"
        }
        return PaceActionRunRecord(
            status: hasFailure ? .failed : (needsFreshInspection ? .skipped : .completed),
            title: title,
            detail: feedback,
            showsInConversation: showsInConversation,
            diagnosticDetail: hasSeparateDiagnostics
                ? PaceActionExecutionObservation.formatForPlanner(observations) : nil,
            targetResolution: targetResolution
        )
    }
}
