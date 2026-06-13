//
//  PaceClickCandidateScorerTests.swift
//  leanring-buddyTests
//
//  Deterministic fixture suite for the click-candidate top-K scorer
//  (`PaceClickCandidateSet.orderedCandidates` / `bestCandidate`) and the
//  recency-hint boost (`PaceClickCandidateRecency.scoreBoost`). This is
//  the "turn the manual ambiguity eval set into a unit-test fixture
//  suite so regressions in the top-K scorer/recency-hint logic surface
//  in CI" item from docs/prds/click-executor-improvements.md.
//
//  The scorer takes an injected coordinate converter, so the whole
//  suite runs without a real screen capture: a candidate's screenshot-
//  pixel location is mapped 1:1 to a global CGPoint and `screenCaptures`
//  is empty. Every expected ordering below is derived from the scoring
//  weights in `PaceClickCandidateSet.score(...)`:
//    base = confidence
//    + recency boost (≤ 0.12)
//    + cursor proximity (≤ 3.0, linear falloff within a 200pt radius)
//    + focused-window membership (+0.18)
//    + labelled bonus (+0.01)
//  with a >0.80-confidence shortcut that skips runtime scoring entirely.
//

import CoreGraphics
import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceClickCandidateScorerTests {

    // Maps a screenshot-pixel location straight to a global point so the
    // scorer's proximity/focus math is exercised without a live capture.
    private let identityCoordinateConverter:
        (ScreenshotPixelLocation, [CompanionScreenCapture]) -> CGPoint? = { location, _ in
            CGPoint(
                x: CGFloat(location.xInScreenshotPixels),
                y: CGFloat(location.yInScreenshotPixels)
            )
        }

    private func candidate(
        x: Int? = nil,
        y: Int? = nil,
        label: String? = nil,
        confidence: Double,
        recencyRank: Int? = nil,
        lastSeenMsAgo: Double? = nil
    ) -> PaceClickCandidate {
        let location: ScreenshotPixelLocation? = {
            guard let x, let y else { return nil }
            return ScreenshotPixelLocation(
                xInScreenshotPixels: x,
                yInScreenshotPixels: y,
                screenNumber: 1
            )
        }()
        let recency: PaceClickCandidateRecency? = {
            guard recencyRank != nil || lastSeenMsAgo != nil else { return nil }
            return PaceClickCandidateRecency(
                rank: recencyRank,
                lastSeenMillisecondsAgo: lastSeenMsAgo
            )
        }()
        return PaceClickCandidate(
            location: location,
            label: label,
            confidence: confidence,
            expectStateChange: true,
            recency: recency
        )
    }

    private func ordered(
        _ candidates: [PaceClickCandidate],
        cursor: CGPoint? = nil,
        focusedWindow: CGRect? = nil
    ) -> [PaceClickCandidate] {
        PaceClickCandidateSet(candidates: candidates, clickCount: 1)
            .orderedCandidates(
                currentGlobalCursorPoint: cursor,
                focusedWindowGlobalFrame: focusedWindow,
                screenCaptures: [],
                coordinateConverter: identityCoordinateConverter
            )
    }

    // MARK: - Structural

    @Test func emptySetReturnsNoCandidates() {
        #expect(ordered([]).isEmpty)
    }

    @Test func bestCandidateEqualsOrderedFirst() {
        let candidates = [
            candidate(x: 5000, y: 5000, label: "Far", confidence: 0.50),
            candidate(x: 100, y: 100, label: "Near", confidence: 0.50),
        ]
        let set = PaceClickCandidateSet(candidates: candidates, clickCount: 1)
        let best = set.bestCandidate(
            currentGlobalCursorPoint: CGPoint(x: 100, y: 100),
            screenCaptures: [],
            coordinateConverter: identityCoordinateConverter
        )
        let first = set.orderedCandidates(
            currentGlobalCursorPoint: CGPoint(x: 100, y: 100),
            screenCaptures: [],
            coordinateConverter: identityCoordinateConverter
        ).first
        #expect(best?.sortDescription == first?.sortDescription)
        #expect(best?.label == "Near")
    }

    // MARK: - High-confidence shortcut

    @Test func aboveThresholdConfidenceSkipsRuntimeScoring() {
        // The 0.85 candidate sits far from the cursor; the 0.60 candidate
        // is right under it. Because the top candidate clears the 0.80
        // shortcut, proximity is NOT consulted and confidence order wins.
        let result = ordered(
            [
                candidate(x: 5000, y: 5000, label: "Far", confidence: 0.85),
                candidate(x: 100, y: 100, label: "Near", confidence: 0.60),
            ],
            cursor: CGPoint(x: 100, y: 100)
        )
        #expect(result.first?.label == "Far")
        #expect(result.map(\.label) == ["Far", "Near"])
    }

    @Test func atExactlyThresholdStillRunsRuntimeScoring() {
        // 0.80 is NOT > 0.80, so the shortcut does not fire and the
        // near-cursor candidate wins on proximity.
        let result = ordered(
            [
                candidate(x: 5000, y: 5000, label: "Far", confidence: 0.80),
                candidate(x: 100, y: 100, label: "Near", confidence: 0.80),
            ],
            cursor: CGPoint(x: 100, y: 100)
        )
        #expect(result.first?.label == "Near")
    }

    // MARK: - Cursor proximity

    @Test func cursorProximityDominatesAmongLowConfidenceTies() {
        let result = ordered(
            [
                candidate(x: 5000, y: 5000, label: "Far", confidence: 0.50),
                candidate(x: 100, y: 100, label: "Near", confidence: 0.50),
            ],
            cursor: CGPoint(x: 100, y: 100)
        )
        #expect(result.first?.label == "Near")
    }

    @Test func nearerOfTwoInRadiusCandidatesWinsViaLinearFalloff() {
        // Both within the 200pt radius; the closer one must still win
        // because the proximity bonus falls off linearly with distance.
        let result = ordered(
            [
                candidate(x: 250, y: 100, label: "Closer", confidence: 0.40),   // 50pt away
                candidate(x: 320, y: 100, label: "Farther", confidence: 0.40),  // 120pt away
            ],
            cursor: CGPoint(x: 200, y: 100)
        )
        #expect(result.first?.label == "Closer")
    }

    // MARK: - Focused window

    @Test func focusedWindowMembershipBreaksTieWhenNoCursorSignal() {
        let focusedWindow = CGRect(x: 100, y: 100, width: 200, height: 200)
        let result = ordered(
            [
                candidate(x: 5000, y: 5000, confidence: 0.50),  // outside window
                candidate(x: 150, y: 150, confidence: 0.50),    // inside window
            ],
            cursor: nil,
            focusedWindow: focusedWindow
        )
        #expect(result.first?.location?.xInScreenshotPixels == 150)
    }

    // MARK: - Recency hint

    @Test func recencyRankBreaksTieBetweenEqualConfidenceLabels() {
        let result = ordered([
            candidate(label: "Stale", confidence: 0.50),
            candidate(label: "JustSeen", confidence: 0.50, recencyRank: 0),
        ])
        #expect(result.first?.label == "JustSeen")
    }

    @Test func recencyBoostIsTooSmallToOverrideCursorProximity() {
        // Recency tops out at 0.12; proximity can add up to 3.0. A recency
        // hint must NEVER pull a far candidate over one under the cursor.
        let result = ordered(
            [
                candidate(x: 5000, y: 5000, label: "FarButRecent", confidence: 0.50, recencyRank: 0),
                candidate(x: 100, y: 100, label: "NearNoHint", confidence: 0.50),
            ],
            cursor: CGPoint(x: 100, y: 100)
        )
        #expect(result.first?.label == "NearNoHint")
    }

    // MARK: - Recency boost weighting (pure)

    @Test func recencyRankBoostDecaysPerRankAndFloorsAtZero() {
        #expect(approxEqual(PaceClickCandidateRecency(rank: 0, lastSeenMillisecondsAgo: nil).scoreBoost, 0.12))
        #expect(approxEqual(PaceClickCandidateRecency(rank: 1, lastSeenMillisecondsAgo: nil).scoreBoost, 0.10))
        #expect(approxEqual(PaceClickCandidateRecency(rank: 6, lastSeenMillisecondsAgo: nil).scoreBoost, 0.0))
        #expect(approxEqual(PaceClickCandidateRecency(rank: 99, lastSeenMillisecondsAgo: nil).scoreBoost, 0.0))
    }

    @Test func lastSeenBoostDecaysLinearlyToZeroAtFiveSeconds() {
        #expect(approxEqual(PaceClickCandidateRecency(rank: nil, lastSeenMillisecondsAgo: 0).scoreBoost, 0.12))
        #expect(approxEqual(PaceClickCandidateRecency(rank: nil, lastSeenMillisecondsAgo: 2_500).scoreBoost, 0.06))
        #expect(approxEqual(PaceClickCandidateRecency(rank: nil, lastSeenMillisecondsAgo: 5_000).scoreBoost, 0.0))
        // Past 5s clamps to 0, never negative.
        #expect(approxEqual(PaceClickCandidateRecency(rank: nil, lastSeenMillisecondsAgo: 10_000).scoreBoost, 0.0))
    }

    @Test func recencyBoostTakesMaxOfRankAndLastSeen() {
        // rank 3 → 0.06; lastSeen 0 → 0.12; the boost is the larger.
        let boost = PaceClickCandidateRecency(rank: 3, lastSeenMillisecondsAgo: 0).scoreBoost
        #expect(approxEqual(boost, 0.12))
    }

    // MARK: - Determinism

    @Test func equalScoresBreakTieByStableSortDescription() {
        // Two label-only candidates, identical confidence, no recency:
        // equal score ⇒ deterministic alphabetical tiebreak so ordering
        // never flickers between runs.
        let result = ordered([
            candidate(label: "Banana", confidence: 0.50),
            candidate(label: "Apple", confidence: 0.50),
        ])
        #expect(result.map(\.label) == ["Apple", "Banana"])
    }

    private func approxEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }
}
