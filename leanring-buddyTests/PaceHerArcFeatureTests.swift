//
//  PaceHerArcFeatureTests.swift
//  leanring-buddyTests
//

import XCTest
@testable import Pace

private final class HerArcNoOpEmbeddingClient: PaceTextEmbedding {
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
}

final class PaceRestraintGateTests: XCTestCase {
    func testPushToTalkBypassesGate() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: now,
            lastEpisodicRecallAt: now,
            lastUserInputAt: now,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: true,
            wakeWordConfidence: 0.1,
            intent: .unknown,
            proactiveSource: .userPushToTalk
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .speak)
    }

    func testActiveCallSilencesProactiveSpeech() {
        let context = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: false,
            wakeWordConfidence: 0.9,
            intent: .pureKnowledge,
            proactiveSource: .wakeWord
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .stayQuiet(reason: "active call"))
    }

    func testWeakWakeWordDoesNotReprompt() {
        let context = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: 0.5,
            intent: .pureKnowledge,
            proactiveSource: .wakeWord
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .stayQuiet(reason: "wake word confidence below threshold"))
    }

    func testRecentInputQueuesUntilIdle() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-1),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .queueUntilIdle(reason: "recent user input"))
    }
}

final class PaceAlwaysListeningCommandParserTests: XCTestCase {
    func testStartAndStopCommandsParse() {
        XCTAssertEqual(PaceAlwaysListeningCommandParser.parse("turn on always listening"), .start)
        XCTAssertEqual(PaceAlwaysListeningCommandParser.parse("pace stop always listening"), .stop)
    }

    func testNonCommandsReturnNil() {
        XCTAssertNil(PaceAlwaysListeningCommandParser.parse("what is always listening"))
    }
}

final class PaceWakeWordSpotterTests: XCTestCase {
    func testSpotterOnlyFiresWhenEnabledAndConfident() {
        let spotter = PaceWakeWordSpotter()

        XCTAssertFalse(spotter.detectWakeWord(in: "hey pace", confidence: 1.0))

        spotter.setEnabled(true)
        XCTAssertFalse(spotter.detectWakeWord(in: "hey pace", confidence: 0.4))
        XCTAssertTrue(spotter.detectWakeWord(in: "hey pace can you hear me", confidence: 0.9))
        XCTAssertTrue(spotter.detectWakeWord(in: "pace listen", confidence: 0.9))
        XCTAssertFalse(spotter.detectWakeWord(in: "space bar", confidence: 0.9))
    }
}

final class PaceBargeInVADTests: XCTestCase {
    func testSustainedSpeechFires() {
        var detector = PaceBargeInVAD(configuration: PaceBargeInVADConfiguration(
            speechLevelThreshold: 0.2,
            sustainedSpeechDuration: 0.6,
            maximumInterSampleGap: 0.3
        ))
        let start = Date()

        XCTAssertFalse(detector.observe(normalizedLevel: 0.25, at: start))
        XCTAssertFalse(detector.observe(normalizedLevel: 0.25, at: start.addingTimeInterval(0.2)))
        XCTAssertFalse(detector.observe(normalizedLevel: 0.25, at: start.addingTimeInterval(0.4)))
        XCTAssertTrue(detector.observe(normalizedLevel: 0.25, at: start.addingTimeInterval(0.61)))
    }

    func testLowEnergyDoesNotFire() {
        var detector = PaceBargeInVAD()
        let start = Date()

        XCTAssertFalse(detector.observe(normalizedLevel: 0.02, at: start))
        XCTAssertFalse(detector.observe(normalizedLevel: 0.02, at: start.addingTimeInterval(1)))
    }
}

@MainActor
final class PaceEpisodicMemoryTests: XCTestCase {
    func testDurableHealthFactExtracts() {
        let extractor = PaceEpisodicFactExtractor(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let facts = extractor.extractFacts(from: "my mom is in the hospital with pneumonia", sourceTurnId: "turn-1")

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.subject, "user's mom")
        XCTAssertEqual(facts.first?.predicate, "is in")
        XCTAssertEqual(facts.first?.value, "the hospital")
        XCTAssertGreaterThanOrEqual(facts.first?.confidence ?? 0, 0.7)
    }

    func testEphemeralAndActionTurnsDoNotExtract() {
        let extractor = PaceEpisodicFactExtractor()

        XCTAssertEqual(extractor.extractFacts(from: "I'm hungry"), [])
        XCTAssertEqual(extractor.extractFacts(from: "open Safari"), [])
    }

    func testFactsBecomeRetrievableDocuments() {
        let store = PaceInMemoryRetrievalStore()
        let retriever = PaceLocalRetriever(
            store: store,
            appliesPersistedSourcePreferences: false,
            embeddingClient: HerArcNoOpEmbeddingClient()
        )
        let fact = PaceEpisodicFact(
            identifier: "episodic-test",
            extractedAt: Date(),
            subject: "user's mom",
            predicate: "is in",
            value: "the hospital",
            confidence: 0.9,
            expiresAt: nil,
            topicHashtags: ["#family", "#health"],
            sourceTurnId: "turn-1"
        )

        retriever.recordEpisodicFacts([fact])
        let context = retriever.localContextBlock(for: PaceRetrievalQuery(text: "how is my mom doing hospital"))

        XCTAssertTrue(context?.contains("Episodic memory") == true)
        XCTAssertTrue(context?.contains("hospital") == true)
    }
}

final class PaceProactiveNudgeDecisionTests: XCTestCase {
    func testFocusFatigueRequiresLongActiveSession() {
        let now = Date()
        XCTAssertNil(PaceFocusFatigueNudgeDecision.utterance(
            appName: "Figma",
            continuousForegroundSeconds: 20 * 60,
            lastUserInputAt: now,
            now: now
        ))

        let utterance = PaceFocusFatigueNudgeDecision.utterance(
            appName: "Figma",
            continuousForegroundSeconds: 50 * 60,
            lastUserInputAt: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertEqual(utterance?.source, .watchNudge)
        XCTAssertTrue(utterance?.spokenText.contains("Figma") == true)
    }

    func testCalendarNudgeFiltersByKeywordAndLeadTime() {
        let now = Date()
        XCTAssertNil(PaceCalendarPreMeetingNudgeDecision.utterance(
            eventTitle: "Take dog out",
            startsInSeconds: 300,
            now: now
        ))

        XCTAssertNotNil(PaceCalendarPreMeetingNudgeDecision.utterance(
            eventTitle: "Design review",
            startsInSeconds: 300,
            now: now
        ))
    }

    func testWatchObservationNudgeTriggersOnBuildFailure() {
        let utterance = PaceWatchModeObservationNudgeDecision.utterance(
            screenDescription: "terminal with build failed",
            ocrText: "",
            now: Date()
        )

        XCTAssertEqual(utterance?.source, .watchNudge)
    }
}

final class PaceFlowReplayTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-flow-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        super.tearDown()
    }

    func testFlowStoreRoundTripsAndRedactsSecureText() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let flow = PaceRecordedFlow(
            name: "Morning Standup",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: [
                .activateApp(bundleIdentifier: "com.apple.mail"),
                .typeText(text: "secret", secure: true),
                .keyShortcut(key: "cmd+s"),
            ]
        )

        try store.save(flow)

        let loadedFlow = try XCTUnwrap(store.load(named: "Morning Standup"))
        XCTAssertEqual(loadedFlow.name, "Morning Standup")
        XCTAssertEqual(loadedFlow.steps.count, 3)

        let rawJSON = try String(
            contentsOf: temporaryDirectoryURL.appendingPathComponent("morning-standup.json"),
            encoding: .utf8
        )
        XCTAssertFalse(rawJSON.contains("secret"))
        XCTAssertTrue(rawJSON.contains("<password redacted>"))
    }

    func testFlowCommandParser() {
        XCTAssertEqual(
            PaceFlowCommandParser.parse("remember this flow as morning standup"),
            .startRecording(name: "morning standup")
        )
        XCTAssertEqual(PaceFlowCommandParser.parse("stop recording"), .stopRecording)
        XCTAssertEqual(PaceFlowCommandParser.parse("run morning standup"), .run(name: "morning standup"))
        XCTAssertEqual(PaceFlowCommandParser.parse("delete the flow morning standup"), .delete(name: "morning standup"))
    }

    func testFlowRecorderProducesFlowAndReplayPlannerPausesBeforeSend() {
        var recorder = PaceFlowRecorder()
        recorder.startRecording(name: "mail draft")
        recorder.record(.activateApp(bundleIdentifier: "com.apple.mail"))
        recorder.record(.axPress(rolePath: ["window", "button"], label: "Send"))

        let flow = recorder.stopRecording(now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(flow?.name, "mail draft")
        XCTAssertEqual(flow?.steps.count, 2)
        XCTAssertEqual(PaceFlowReplayPlanner.replayObservations(for: try XCTUnwrap(flow)).last, "ready to send - say go ahead")
    }

    func testFlowToolsParseThroughActionLayer() {
        let parseResult = PaceActionTagParser.parseActions(from: """
        recording.
        <tool_calls>
        [
          [
            {"tool":"record_flow","name":"morning standup"},
            {"tool":"run_flow","name":"morning standup"}
          ]
        ]
        </tool_calls>
        """)

        XCTAssertEqual(parseResult.actions.count, 2)
        guard case .recordFlow(let recordRequest) = parseResult.actions[0] else {
            XCTFail("Expected record flow action")
            return
        }
        XCTAssertEqual(recordRequest.name, "morning standup")

        guard case .runFlow(let runRequest) = parseResult.actions[1] else {
            XCTFail("Expected run flow action")
            return
        }
        XCTAssertEqual(runRequest.name, "morning standup")
    }
}
