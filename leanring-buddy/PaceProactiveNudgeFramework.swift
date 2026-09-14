//
//  PaceProactiveNudgeFramework.swift
//  leanring-buddy
//
//  Generator + orchestrator scaffolding for the three proactive
//  nudge surfaces (focus fatigue, calendar pre-meeting, watch-mode
//  observation). Each generator subscribes to an ALREADY-running
//  source (PaceAppUsageTracker, PaceCalendarRetrievalConnector, or
//  PaceScreenWatchModeController) and emits gate-aware decisions.
//
//  The orchestrator wires the generators together, supplies the
//  live restraint-context snapshot, and routes results through the
//  emit / queueForLater closures the CompanionManager owns.
//
//  RAM discipline: per-generator state is the source's `Cancellable`
//  plus a `Date` (last-emit timestamp). No caches, no timers we own
//  beyond the cooldown bookkeeping.
//

import Combine
import Foundation

/// Generic generator surface. Each generator owns one source-side
/// subscription, calls into the matching `Pace*NudgeDecision.evaluate`
/// pure helper, and routes the resulting decision through the
/// closures the orchestrator provides.
@MainActor
protocol PaceProactiveNudgeGenerator: AnyObject {
    var identifier: String { get }
    /// Begins listening to the underlying source. Calls `emit` for
    /// `.speak` decisions and `queueForLater` for `.queueUntilIdle`
    /// decisions. `.stayQuiet` results are dropped silently.
    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    )
    func stop()
}

/// Owns a set of generators, hands each a live restraint-context
/// snapshot, and exposes the same start/stop contract individual
/// generators do so CompanionManager can toggle them per preference.
///
/// Slice 2 of the opportunity-ranking proposal
/// (openspec/changes/2026-09-13-add-opportunity-ranking): every
/// generator's `emit`/`queueForLater` closures are wrapped so an
/// already-restraint-gate-approved utterance passes through
/// `PaceOpportunityRanker` (coalesce/category-cooldown/rank/cap) before
/// actually reaching the caller's `emit`/`queueForLater`. Per that
/// proposal's D2 (owner-confirmed 2026-09-13): generators' own trigger
/// conditions and their own `PaceRestraintGate.decide` calls
/// (`PaceProactiveNudges.swift`) are completely untouched — ranking can
/// only narrow what already passed the gate, never widen it.
@MainActor
final class PaceProactiveNudgeOrchestrator {
    private let restraintContextProvider: () -> PaceRestraintContext
    private let activityGoalStateProvider: () -> PaceActiveGoalState
    private let nowProvider: () -> Date
    private let generators: [PaceProactiveNudgeGenerator]
    private var categoryCooldownTracker = PaceOpportunityCategoryCooldownTracker()
    private(set) var isRunning = false

    /// Designated initializer. `restraintContextProvider` is captured
    /// (not snapshotted) so every gate decision sees the latest
    /// values for `lastUserInputAt`, `isOnActiveCall`, profile, etc.
    /// `activityGoalStateProvider` feeds the ranking layer's relevance
    /// factor (defaults to `.unknown` so existing tests that don't care
    /// about ranking need no changes).
    init(
        restraintContextProvider: @escaping () -> PaceRestraintContext,
        generators: [PaceProactiveNudgeGenerator],
        activityGoalStateProvider: @escaping () -> PaceActiveGoalState = { .unknown },
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.restraintContextProvider = restraintContextProvider
        self.generators = generators
        self.activityGoalStateProvider = activityGoalStateProvider
        self.nowProvider = nowProvider
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        for generator in generators {
            let rankedClosures = rankedDispatchClosures(
                category: generator.identifier,
                emit: emit,
                queueForLater: queueForLater
            )
            generator.start(emit: rankedClosures.emit, queueForLater: rankedClosures.queueForLater)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for generator in generators {
            generator.stop()
        }
    }

    /// Toggles a single generator without tearing down the rest.
    /// Used by CompanionManager when the user flips an individual
    /// per-source nudge toggle in Settings → Proactive.
    func setGeneratorEnabled(
        identifier: String,
        enabled: Bool,
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard let generator = generators.first(where: { $0.identifier == identifier }) else {
            return
        }
        if enabled {
            let rankedClosures = rankedDispatchClosures(
                category: identifier,
                emit: emit,
                queueForLater: queueForLater
            )
            generator.start(emit: rankedClosures.emit, queueForLater: rankedClosures.queueForLater)
        } else {
            generator.stop()
        }
    }

    /// Test seam: drives the routing path used by live generators
    /// without spinning up subscriptions. Verifies the
    /// emit / queueForLater wiring against an injected gate-aware
    /// evaluation result. Deliberately bypasses opportunity ranking
    /// (unchanged from before this slice) — it exists to prove
    /// `PaceProactiveNudgeFrameworkRouting.route`'s own dispatch, not the
    /// ranking layer, which `PaceOpportunityRankingTests.swift` covers
    /// directly.
    func routeEvaluationForTesting(
        _ evaluation: PaceProactiveNudgeEvaluation,
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        PaceProactiveNudgeFrameworkRouting.route(
            evaluation: evaluation,
            emit: emit,
            queueForLater: queueForLater
        )
    }

    /// Wraps the orchestrator-level `emit`/`queueForLater` closures with
    /// the opportunity-ranking layer for one generator's `category`
    /// (its own `identifier`). The generator never sees this wrapping —
    /// it still just calls `emit`/`queueForLater` exactly as before.
    private func rankedDispatchClosures(
        category: String,
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) -> (emit: (PaceProactiveUtterance) -> Void, queueForLater: (PaceProactiveUtterance) -> Void) {
        let rankedEmit: (PaceProactiveUtterance) -> Void = { [weak self] utterance in
            self?.rankAndDispatch(
                utterance: utterance,
                decision: .speak,
                category: category,
                emit: emit,
                queueForLater: queueForLater
            )
        }
        let rankedQueueForLater: (PaceProactiveUtterance) -> Void = { [weak self] utterance in
            self?.rankAndDispatch(
                utterance: utterance,
                decision: .queueUntilIdle(reason: "generator requested queue"),
                category: category,
                emit: emit,
                queueForLater: queueForLater
            )
        }
        return (rankedEmit, rankedQueueForLater)
    }

    /// Reconstructs the `PaceRestraintDecision` the generator's own gate
    /// call already reached (`.speak` if `emit` was invoked,
    /// `.queueUntilIdle` if `queueForLater` was — the specific `reason`
    /// text doesn't affect ranking, which only switches on the case),
    /// wraps it as a `PaceOpportunity` (impossible to construct for a
    /// gate-refused candidate — see that type's doc comment), ranks it
    /// against this tick's category-cooldown state, and only then calls
    /// through to the real `emit`/`queueForLater`.
    private func rankAndDispatch(
        utterance: PaceProactiveUtterance,
        decision: PaceRestraintDecision,
        category: String,
        emit: (PaceProactiveUtterance) -> Void,
        queueForLater: (PaceProactiveUtterance) -> Void
    ) {
        let now = nowProvider()
        guard let opportunity = PaceOpportunity(
            evaluation: (decision: decision, utterance: utterance),
            category: category,
            now: now
        ) else {
            return
        }

        let result = PaceOpportunityRanker.rank(
            candidates: [opportunity],
            activityGoalState: activityGoalStateProvider(),
            categoryCooldownTracker: &categoryCooldownTracker,
            now: now
        )
        guard let winner = result.winner else { return }

        switch winner.decision {
        case .speak:
            emit(winner.utterance)
        case .queueUntilIdle:
            queueForLater(winner.utterance)
        case .stayQuiet:
            break // unreachable — PaceOpportunity's failable init excludes this case
        }
    }
}

/// Shared routing helper used by every generator. Lives at the
/// type level so a future generator can adopt the same emit /
/// queue contract without re-implementing the switch.
enum PaceProactiveNudgeFrameworkRouting {
    static func route(
        evaluation: PaceProactiveNudgeEvaluation,
        emit: (PaceProactiveUtterance) -> Void,
        queueForLater: (PaceProactiveUtterance) -> Void
    ) {
        guard let utterance = evaluation.utterance else { return }
        switch evaluation.decision {
        case .speak:
            emit(utterance)
        case .queueUntilIdle:
            queueForLater(utterance)
        case .stayQuiet:
            return
        }
    }
}

// MARK: - Cooldown bookkeeping

/// Per-generator cooldown gate that the generators apply BEFORE
/// asking the restraint gate. Keeps a single `Date` in memory so the
/// RAM budget stays effectively zero.
@MainActor
struct PaceProactiveNudgeCooldown {
    private(set) var lastEmittedAt: Date?
    let minimumIntervalSeconds: TimeInterval

    init(minimumIntervalSeconds: TimeInterval) {
        self.minimumIntervalSeconds = minimumIntervalSeconds
    }

    func isCoolingDown(now: Date) -> Bool {
        guard let lastEmittedAt else { return false }
        return now.timeIntervalSince(lastEmittedAt) < minimumIntervalSeconds
    }

    mutating func markEmitted(at now: Date) {
        lastEmittedAt = now
    }
}
