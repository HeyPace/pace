//
//  CompanionManager+SurfaceProjection.swift
//  leanring-buddy
//
//  Read-only Gap #5 surface projections
//  (docs/current/plans/autonomous-companion-consolidation.md, "5.
//  Product-surface consolidation"). Each computed property calls a pure
//  function in PaceSurfaceProjection.swift against CompanionManager's own
//  existing stores — no new state is introduced or mutated here.
//

import Foundation

@MainActor
extension CompanionManager {
    /// Current activity subject (if known) and at most one active
    /// opportunity, derived on demand from `activityGoalStore` and the
    /// proactive-nudge orchestrator's most recent ranking decision.
    var nowSurfaceState: PaceNowSurfaceState {
        PaceNowSurfaceProjection.project(
            activityGoalState: activityGoalStore.currentGoalState(),
            mostRecentOpportunityRankingResult: proactivityPipeline.mostRecentOpportunityRankingResult
        )
    }

    /// Background/scheduled work, derived on demand from the shared
    /// `PaceBackgroundAgentRunner`.
    var workingSurfaceState: PaceWorkingSurfaceState {
        PaceWorkingSurfaceProjection.project(backgroundAgentTasks: PaceBackgroundAgentRunner.shared.tasks)
    }

    /// Durable facts, derived on demand from `episodicFactStore`.
    /// Sensitive-topic facts are excluded by the projection itself (see
    /// `PaceMemorySurfaceProjection.project`), independent of whatever the
    /// caller passes in.
    var memorySurfaceState: PaceMemorySurfaceState {
        PaceMemorySurfaceProjection.project(episodicFacts: episodicFactStore.allFacts)
    }
}
