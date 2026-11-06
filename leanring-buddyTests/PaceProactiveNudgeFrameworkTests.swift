//
//  PaceProactiveNudgeFrameworkTests.swift
//  leanring-buddyTests
//
//  Unit tests for the proactive nudge framework introduced in Wave 1b.
//  Covers orchestrator dispatch, gate-aware routing (emit vs queue
//  vs drop), and the three concrete generators in isolation.
//

import Combine
import XCTest
@testable import Pace

@MainActor
final class PaceProactiveNudgeFrameworkOrchestratorTests: XCTestCase {
    func testOrchestratorStartsAndStopsEveryGenerator() {
        let firstGenerator = RecordingNudgeGenerator(identifier: "first-generator")
        let secondGenerator = RecordingNudgeGenerator(identifier: "second-generator")
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: [firstGenerator, secondGenerator]
        )

        orchestrator.start(emit: { _ in }, queueForLater: { _ in })

        XCTAssertEqual(firstGenerator.startCalls, 1)
        XCTAssertEqual(secondGenerator.startCalls, 1)

        orchestrator.stop()

        XCTAssertEqual(firstGenerator.stopCalls, 1)
        XCTAssertEqual(secondGenerator.stopCalls, 1)
    }

    func testRouteEvaluationStayQuietDoesNotEmitOrQueue() {
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: []
        )
        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        orchestrator.routeEvaluationForTesting(
            (.stayQuiet(reason: "test"), nil),
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testRouteEvaluationQueueUntilIdleSendsToQueueForLater() {
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: []
        )
        let queuedUtterance = PaceProactiveUtterance(
            spokenText: "queued",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        orchestrator.routeEvaluationForTesting(
            (.queueUntilIdle(reason: "test"), queuedUtterance),
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty)
        XCTAssertEqual(queuedUtterances.map(\.spokenText), ["queued"])
    }

    func testRouteEvaluationSpeakSendsToEmit() {
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: []
        )
        let spokenUtterance = PaceProactiveUtterance(
            spokenText: "go",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        orchestrator.routeEvaluationForTesting(
            (.speak, spokenUtterance),
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.map(\.spokenText), ["go"])
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testPerGeneratorToggleOnlyTouchesOneGenerator() {
        let firstGenerator = RecordingNudgeGenerator(identifier: "first-generator")
        let secondGenerator = RecordingNudgeGenerator(identifier: "second-generator")
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: [firstGenerator, secondGenerator]
        )

        orchestrator.start(emit: { _ in }, queueForLater: { _ in })
        orchestrator.setGeneratorEnabled(
            identifier: "second-generator",
            enabled: false,
            emit: { _ in },
            queueForLater: { _ in }
        )

        XCTAssertEqual(firstGenerator.stopCalls, 0)
        XCTAssertEqual(secondGenerator.stopCalls, 1)
    }

    private func stableRestraintContextProvider() -> () -> PaceRestraintContext {
        return {
            PaceRestraintContext(
                now: Date(),
                lastProactiveUtteranceAt: nil,
                lastEpisodicRecallAt: nil,
                lastUserInputAt: nil,
                frontmostAppBundleIdentifier: nil,
                isOnActiveCall: false,
                wakeWordConfidence: nil,
                intent: .pureKnowledge,
                proactiveSource: .watchNudge,
                profile: .balanced
            )
        }
    }
}

@MainActor
final class PaceFocusFatigueNudgeGeneratorTests: XCTestCase {
    func testGeneratorEmitsWhenForegroundLongAndGateAllows() {
        let now = Date()
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-60),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let generator = PaceFocusFatigueNudgeGenerator(
            restraintContextProvider: { restraintContext },
            frontmostApplicationNameProvider: { "Figma" },
            nowProvider: { now }
        )
        generator.injectFrontmostApplicationActivationForTesting(
            applicationName: "Figma",
            activatedAt: now.addingTimeInterval(-60 * 60)
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.count, 1)
        XCTAssertTrue(emittedUtterances.first?.spokenText.contains("Figma") == true)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testGeneratorDoesNotEmitDuringActiveCall() {
        let now = Date()
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: true,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let generator = PaceFocusFatigueNudgeGenerator(
            restraintContextProvider: { restraintContext },
            frontmostApplicationNameProvider: { "Figma" },
            nowProvider: { now }
        )
        generator.injectFrontmostApplicationActivationForTesting(
            applicationName: "Figma",
            activatedAt: now.addingTimeInterval(-60 * 60)
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty, "Active call must suppress the focus-fatigue nudge")
        XCTAssertTrue(queuedUtterances.isEmpty, "Gate returns queue, but utterance is nil for active-call")
    }
}

@MainActor
final class PaceCalendarPreMeetingNudgeGeneratorTests: XCTestCase {
    func testGeneratorEmitsWhenEventStartsSoonAndGateAllows() {
        let now = Date()
        let upcomingEvent = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-1",
            title: "Design review",
            startDate: now.addingTimeInterval(240),
            endDate: now.addingTimeInterval(240 + 30 * 60)
        )
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .calendarEvent,
            profile: .balanced
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { restraintContext },
            upcomingEventSnapshotsProvider: { _ in [upcomingEvent] },
            nowProvider: { now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.first?.source, .calendarEvent)
        XCTAssertTrue(emittedUtterances.first?.spokenText.contains("Design review") == true)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testGeneratorQueuesWhenInputRecent() {
        let now = Date()
        let upcomingEvent = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-1",
            title: "Sync with team",
            startDate: now.addingTimeInterval(180),
            endDate: now.addingTimeInterval(180 + 30 * 60)
        )
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-1),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .calendarEvent,
            profile: .balanced
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { restraintContext },
            upcomingEventSnapshotsProvider: { _ in [upcomingEvent] },
            nowProvider: { now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty)
        XCTAssertEqual(queuedUtterances.count, 1, "Recent input under .balanced should queue, not drop")
    }

    func testGeneratorDeduplicatesSameEventAcrossTicks() {
        let now = Date()
        let upcomingEvent = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-1",
            title: "Sync",
            startDate: now.addingTimeInterval(180),
            endDate: now.addingTimeInterval(180 + 30 * 60)
        )
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .calendarEvent,
            profile: .balanced
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { restraintContext },
            upcomingEventSnapshotsProvider: { _ in [upcomingEvent] },
            nowProvider: { now }
        )

        var emittedCount = 0
        generator.evaluateNow(
            emit: { _ in emittedCount += 1 },
            queueForLater: { _ in }
        )
        generator.evaluateNow(
            emit: { _ in emittedCount += 1 },
            queueForLater: { _ in }
        )

        XCTAssertEqual(emittedCount, 1, "Same event must not nudge twice in one session")
    }

    func testSkippedEventsDoNotBlockOrdinaryTimedEvent() {
        let now = Date()
        let dentist = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "dentist", title: "Dentist",
            startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(1800)
        )
        let skippedEvents = [
            PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "all-day", title: "Birthday",
                startDate: now.addingTimeInterval(60), endDate: now.addingTimeInterval(86400),
                isAllDay: true
            ),
            PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "started", title: "Earlier call",
                startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(1800)
            ),
            PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "invalid", title: "Invalid event",
                startDate: now.addingTimeInterval(60), endDate: now
            ),
            PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "later", title: "Later flight",
                startDate: now.addingTimeInterval(600), endDate: now.addingTimeInterval(1800)
            ),
        ]
        for skippedEvent in skippedEvents {
            let generator = PaceCalendarPreMeetingNudgeGenerator(
                restraintContextProvider: { self.calendarRestraintContext(now: now) },
                upcomingEventSnapshotsProvider: { _ in [skippedEvent, dentist] },
                nowProvider: { now }
            )
            var emitted: [PaceProactiveUtterance] = []
            var queued: [PaceProactiveUtterance] = []
            generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })

            XCTAssertEqual(emitted.map(\.spokenText), ["Dentist is in 4 minutes."], skippedEvent.stableIdentifier)
            XCTAssertTrue(queued.isEmpty)
        }
    }

    func testAllDayEventNeverEmitsOrQueues() {
        let now = Date()
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { self.calendarRestraintContext(now: now) },
            upcomingEventSnapshotsProvider: { _ in [PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "birthday", title: "Birthday",
                startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(86400),
                isAllDay: true
            )] },
            nowProvider: { now }
        )
        var utterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(emit: { utterances.append($0) }, queueForLater: { utterances.append($0) })
        XCTAssertTrue(utterances.isEmpty)
    }

    func testZeroDurationAndUntitledTimedEventsStillAnnounce() {
        let now = Date()
        let startDate = now.addingTimeInterval(180)
        for title in ["Medication", "   "] {
            let event = PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "event", title: title,
                startDate: startDate, endDate: startDate
            )
            let generator = PaceCalendarPreMeetingNudgeGenerator(
                restraintContextProvider: { self.calendarRestraintContext(now: now) },
                upcomingEventSnapshotsProvider: { _ in [event] },
                nowProvider: { now }
            )
            var emitted: [PaceProactiveUtterance] = []
            generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { _ in XCTFail("Idle event should announce.") })
            let expectedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled event" : title
            XCTAssertEqual(emitted.map(\.spokenText), ["\(expectedTitle) is in 3 minutes."])
        }
    }

    func testRecurringOccurrencesWithSameIdentifierEachAnnounceOnce() {
        var now = Date()
        var event = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "recurring-event", title: "Medication",
            startDate: now.addingTimeInterval(180), endDate: now.addingTimeInterval(240)
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { self.calendarRestraintContext(now: now) },
            upcomingEventSnapshotsProvider: { _ in [event] },
            nowProvider: { now }
        )
        var emitted: [PaceProactiveUtterance] = []
        var queued: [PaceProactiveUtterance] = []
        generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })
        generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })
        now = now.addingTimeInterval(3600)
        event = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "recurring-event", title: "Medication",
            startDate: now.addingTimeInterval(180), endDate: now.addingTimeInterval(240)
        )
        generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })
        generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })

        XCTAssertEqual(emitted.map(\.spokenText), Array(repeating: "Medication is in 3 minutes.", count: 2))
        XCTAssertTrue(queued.isEmpty)
    }

    func testOrdinaryEventQueuesDuringCallWithoutDuplicateQueueEntries() {
        let now = Date()
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { self.calendarRestraintContext(now: now, isOnActiveCall: true) },
            upcomingEventSnapshotsProvider: { _ in [PaceCalendarRetrievalEventSnapshot(
                stableIdentifier: "dentist", title: "Dentist",
                startDate: now.addingTimeInterval(180), endDate: now.addingTimeInterval(1800)
            )] },
            nowProvider: { now }
        )
        var emitted: [PaceProactiveUtterance] = []
        var queued: [PaceProactiveUtterance] = []
        generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })
        generator.evaluateNow(emit: { emitted.append($0) }, queueForLater: { queued.append($0) })

        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(queued.map(\.spokenText), ["Dentist is in 3 minutes."])
    }

    private func calendarRestraintContext(now: Date, isOnActiveCall: Bool = false) -> PaceRestraintContext {
        PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: isOnActiveCall,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .calendarEvent,
            profile: .balanced
        )
    }
}

@MainActor
final class PaceWatchModeObservationNudgeGeneratorTests: XCTestCase {
    func testGeneratorEmitsOnMajorChangeWithErrorKeyword() {
        let restraintContext = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let publisher = PassthroughSubject<PaceScreenWatchEvent, Never>()
        let generator = PaceWatchModeObservationNudgeGenerator(
            restraintContextProvider: { restraintContext },
            watchEventPublisher: publisher.eraseToAnyPublisher(),
            screenDescriptionProvider: { _ in "build failed in xcode" },
            nowProvider: { restraintContext.now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        let majorChangeEvent = PaceScreenWatchEvent(
            screenLabel: "Built-in Display",
            diff: PaceScreenImageDiff(meanPixelDelta: 35, changedPixelRatio: 0.5),
            category: .majorScreenChange,
            capture: CompanionScreenCapture(
                imageData: Data(),
                label: "Built-in Display",
                isCursorScreen: true,
                displayWidthInPoints: 1440,
                displayHeightInPoints: 900,
                displayFrame: .zero,
                screenshotWidthInPixels: 1440,
                screenshotHeightInPixels: 900
            ),
            detectedAt: restraintContext.now
        )
        generator.handleWatchEvent(
            majorChangeEvent,
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.first?.source, .watchNudge)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testGeneratorSkipsContentUpdateCategory() {
        let restraintContext = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let publisher = PassthroughSubject<PaceScreenWatchEvent, Never>()
        let generator = PaceWatchModeObservationNudgeGenerator(
            restraintContextProvider: { restraintContext },
            watchEventPublisher: publisher.eraseToAnyPublisher(),
            screenDescriptionProvider: { _ in "build failed in xcode" },
            nowProvider: { restraintContext.now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        let contentUpdateEvent = PaceScreenWatchEvent(
            screenLabel: "Built-in Display",
            diff: PaceScreenImageDiff(meanPixelDelta: 15, changedPixelRatio: 0.2),
            category: .contentUpdate,
            capture: CompanionScreenCapture(
                imageData: Data(),
                label: "Built-in Display",
                isCursorScreen: true,
                displayWidthInPoints: 1440,
                displayHeightInPoints: 900,
                displayFrame: .zero,
                screenshotWidthInPixels: 1440,
                screenshotHeightInPixels: 900
            ),
            detectedAt: restraintContext.now
        )
        generator.handleWatchEvent(
            contentUpdateEvent,
            emit: { emittedUtterances.append($0) },
            queueForLater: { _ in }
        )

        XCTAssertTrue(emittedUtterances.isEmpty, "Only majorScreenChange should fire the observation nudge")
    }
}

// MARK: - Test doubles

@MainActor
private final class RecordingNudgeGenerator: PaceProactiveNudgeGenerator {
    let identifier: String
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(identifier: String) {
        self.identifier = identifier
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        startCalls += 1
    }

    func stop() {
        stopCalls += 1
    }
}
