//
//  PaceProactiveNudges.swift
//  leanring-buddy
//
//  Pure nudge decision helpers. Runtime generators can subscribe to app
//  usage, calendar, or watch-mode events and call these decisions before
//  passing the utterance through PaceRestraintGate.
//

import Foundation

nonisolated struct PaceProactiveUtterance: Equatable {
    let spokenText: String
    let source: PaceProactiveSource
    let confidence: Double
    let relevanceWindowExpiresAt: Date?
}

nonisolated protocol PaceProactiveNudgeGenerator: AnyObject {
    var identifier: String { get }
    var preferenceKey: PaceUserPreferenceKey { get }
}

nonisolated enum PaceFocusFatigueNudgeDecision {
    static func utterance(
        appName: String,
        continuousForegroundSeconds: TimeInterval,
        lastUserInputAt: Date?,
        now: Date
    ) -> PaceProactiveUtterance? {
        guard continuousForegroundSeconds >= 45 * 60 else { return nil }
        guard let lastUserInputAt, now.timeIntervalSince(lastUserInputAt) <= 10 * 60 else { return nil }
        return PaceProactiveUtterance(
            spokenText: "you've been on \(appName) for a while. quick break?",
            source: .watchNudge,
            confidence: 0.74,
            relevanceWindowExpiresAt: now.addingTimeInterval(5 * 60)
        )
    }
}

nonisolated enum PaceCalendarPreMeetingNudgeDecision {
    private static let meetingKeywords = ["meeting", "call", "sync", "review", "1:1", "one on one"]

    static func utterance(eventTitle: String, startsInSeconds: TimeInterval, now: Date) -> PaceProactiveUtterance? {
        let normalizedTitle = eventTitle.lowercased()
        guard meetingKeywords.contains(where: normalizedTitle.contains) else { return nil }
        guard startsInSeconds >= 0, startsInSeconds <= 5 * 60 else { return nil }
        let minutes = max(1, Int((startsInSeconds / 60).rounded()))
        return PaceProactiveUtterance(
            spokenText: "\(eventTitle) is in \(minutes) minute\(minutes == 1 ? "" : "s").",
            source: .backgroundReminder,
            confidence: 0.86,
            relevanceWindowExpiresAt: now.addingTimeInterval(startsInSeconds)
        )
    }
}

nonisolated enum PaceWatchModeObservationNudgeDecision {
    private static let triggerPhrases = [
        "build failed", "error dialog", "stack trace", "exception", "test failed",
    ]

    static func utterance(screenDescription: String, ocrText: String, now: Date) -> PaceProactiveUtterance? {
        let combinedText = "\(screenDescription) \(ocrText)".lowercased()
        guard triggerPhrases.contains(where: combinedText.contains) else { return nil }
        return PaceProactiveUtterance(
            spokenText: "looks like something failed over there. want me to look at the error?",
            source: .watchNudge,
            confidence: 0.78,
            relevanceWindowExpiresAt: now.addingTimeInterval(10 * 60)
        )
    }
}
