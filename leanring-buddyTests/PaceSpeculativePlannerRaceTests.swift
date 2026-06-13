//
//  PaceSpeculativePlannerRaceTests.swift
//  leanring-buddyTests
//
//  Wave 4 unit tests for the speculative-planner race + its gating.
//
//  These tests intentionally drive the race coordinator through fake
//  BuddyPlannerClient conformers so we can pin which path produces a
//  token first, how fast, and what payload arrives — without spinning
//  up Apple FM or LM Studio. The coordinator's supersede + winner
//  bookkeeping is what's under test.
//

import Foundation
import Testing

@testable import Pace

// MARK: - Gate

@MainActor
struct PaceSpeculativeRaceGateTests {
    @Test func gateAllowsScreenActionWithAllConditionsMet() async {
        let shouldFire = CompanionManager.speculativeRaceShouldFire(
            intent: .screenAction,
            isToggleEnabled: true,
            isLocalVLMConfigured: true,
            appleFoundationModelsIsAvailable: true
        )
        #expect(shouldFire == true)
    }

    @Test func gateAllowsScreenDescriptionWithAllConditionsMet() async {
        let shouldFire = CompanionManager.speculativeRaceShouldFire(
            intent: .screenDescription,
            isToggleEnabled: true,
            isLocalVLMConfigured: true,
            appleFoundationModelsIsAvailable: true
        )
        #expect(shouldFire == true)
    }

    @Test func gateBlocksWhenToggleOff() async {
        let shouldFire = CompanionManager.speculativeRaceShouldFire(
            intent: .screenAction,
            isToggleEnabled: false,
            isLocalVLMConfigured: true,
            appleFoundationModelsIsAvailable: true
        )
        #expect(shouldFire == false)
    }

    @Test func gateBlocksWhenAppleFMUnavailable() async {
        let shouldFire = CompanionManager.speculativeRaceShouldFire(
            intent: .screenAction,
            isToggleEnabled: true,
            isLocalVLMConfigured: true,
            appleFoundationModelsIsAvailable: false
        )
        #expect(shouldFire == false)
    }

    @Test func gateBlocksWhenVLMNotConfigured() async {
        let shouldFire = CompanionManager.speculativeRaceShouldFire(
            intent: .screenAction,
            isToggleEnabled: true,
            isLocalVLMConfigured: false,
            appleFoundationModelsIsAvailable: true
        )
        #expect(shouldFire == false)
    }

    @Test func gateBlocksPureKnowledgeAndChitchat() async {
        for nonSlowIntent in [PaceIntent.pureKnowledge, .chitchat, .phoneLargeModel, .unknown] {
            let shouldFire = CompanionManager.speculativeRaceShouldFire(
                intent: nonSlowIntent,
                isToggleEnabled: true,
                isLocalVLMConfigured: true,
                appleFoundationModelsIsAvailable: true
            )
            #expect(shouldFire == false, "intent \(nonSlowIntent) must not trigger speculative race")
        }
    }
}

// MARK: - Fake planner

/// Test planner that emits a fixed sequence of accumulated-text chunks
/// at controlled delays. Lets each test pin the relative ordering of
/// lite vs full first-token events without timing flakiness.
@MainActor
final class FakeStreamingPlannerClient: BuddyPlannerClient {
    let displayName: String
    let supportsImageInput: Bool

    private let chunks: [(text: String, delayMs: Int)]
    private let shouldThrow: Bool

    init(
        displayName: String,
        chunks: [(text: String, delayMs: Int)],
        supportsImageInput: Bool = false,
        shouldThrow: Bool = false
    ) {
        self.displayName = displayName
        self.chunks = chunks
        self.supportsImageInput = supportsImageInput
        self.shouldThrow = shouldThrow
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        var accumulated = ""
        for chunk in chunks {
            try await Task.sleep(nanoseconds: UInt64(chunk.delayMs) * 1_000_000)
            accumulated += chunk.text
            onTextChunk(accumulated)
        }
        if shouldThrow {
            throw FakePlannerError.intentionalFailure
        }
        return (text: accumulated, duration: 0)
    }
}

enum FakePlannerError: Error {
    case intentionalFailure
}

// MARK: - Coordinator behavior

@MainActor
struct PaceSpeculativeRaceCoordinatorTests {

    /// Coordinator-only test — we don't need a real Apple FM client for
    /// the winner-selection logic, just two fake planner clients with
    /// controlled timing fed into the race.
    ///
    /// Lite produces text quickly (10ms), full produces text much later
    /// (200ms). Lite should win, AND the supersede window has closed
    /// (200ms > 500ms? no — actually 200 < 500 so it would qualify),
    /// BUT the user has heard 10+ chars by then in real spoken state.
    /// To keep this test free of an end-to-end TTS dependency, we drive
    /// the spoken-character probe directly.

    @Test func liteWinsWhenItStreamsFirstAndSupersedeDoesNotFire() async throws {
        // Spoken count probe stays past the supersede threshold so the
        // race coordinator commits to lite even when the full text
        // arrives within the window.
        let liteFakeStream = FakeStreamingPlannerClient(
            displayName: "lite-stub",
            chunks: [(text: "yes.", delayMs: 5)]
        )
        let fullFakeStream = FakeStreamingPlannerClient(
            displayName: "full-stub",
            chunks: [(text: "the file menu is closed.", delayMs: 250)]
        )

        var capturedTokens: [(text: String, winner: PaceSpeculativeWinner)] = []
        var finalOutcome: PaceSpeculativeOutcome?

        await PaceSpeculativePlannerRace.raceSpeculative(
            transcript: "what's on screen?",
            systemPrompt: "system",
            threadMemoryPrefix: "",
            intent: .screenDescription,
            liteClient: liteFakeStream,
            fullClient: fullFakeStream,
            fullPlannerInputBuilder: {
                PaceChatTurnPart(
                    images: [],
                    systemPrompt: "system",
                    conversationHistory: [],
                    userPrompt: "what's on screen?"
                )
            },
            spokenCharacterCountProbe: { 80 },  // past the 60-char supersede cap
            onToken: { text, winner in
                capturedTokens.append((text: text, winner: winner))
            },
            onCompletion: { outcome in
                finalOutcome = outcome
            }
        )

        #expect(finalOutcome == .liteWon)
        #expect(capturedTokens.first?.winner == .lite)
        #expect(capturedTokens.contains { $0.winner == .full } == false,
                "Full path tokens must be suppressed once lite wins and supersede is blocked by spoken-char threshold.")
    }

    @Test func fullSupersedesLiteWhenWindowOpenAndSpokenCharsLow() async throws {
        // Spoken count probe returns a small number so the supersede
        // can fire when full arrives within the window.
        let liteFakeStream = FakeStreamingPlannerClient(
            displayName: "lite-stub",
            chunks: [(text: "sure.", delayMs: 5)]
        )
        let fullFakeStream = FakeStreamingPlannerClient(
            displayName: "full-stub",
            chunks: [(text: "the save button is in the top right.", delayMs: 100)]
        )

        var capturedTokens: [(text: String, winner: PaceSpeculativeWinner)] = []
        var finalOutcome: PaceSpeculativeOutcome?

        await PaceSpeculativePlannerRace.raceSpeculative(
            transcript: "where is save?",
            systemPrompt: "system",
            threadMemoryPrefix: "",
            intent: .screenDescription,
            liteClient: liteFakeStream,
            fullClient: fullFakeStream,
            fullPlannerInputBuilder: {
                PaceChatTurnPart(
                    images: [],
                    systemPrompt: "system",
                    conversationHistory: [],
                    userPrompt: "where is save?"
                )
            },
            spokenCharacterCountProbe: { 5 },  // way below the 60-char threshold
            onToken: { text, winner in
                capturedTokens.append((text: text, winner: winner))
            },
            onCompletion: { outcome in
                finalOutcome = outcome
            }
        )

        #expect(finalOutcome == .fullSupersededLite,
                "Full streaming within 500ms while user heard <60 chars should supersede.")
        #expect(capturedTokens.contains { $0.winner == .full })
    }

    @Test func bothFailedWhenBothPlannersThrow() async throws {
        let liteFakeStream = FakeStreamingPlannerClient(
            displayName: "lite-stub",
            chunks: [],
            shouldThrow: true
        )
        let fullFakeStream = FakeStreamingPlannerClient(
            displayName: "full-stub",
            chunks: [],
            shouldThrow: true
        )

        var finalOutcome: PaceSpeculativeOutcome?
        await PaceSpeculativePlannerRace.raceSpeculative(
            transcript: "do something",
            systemPrompt: "system",
            threadMemoryPrefix: "",
            intent: .screenAction,
            liteClient: liteFakeStream,
            fullClient: fullFakeStream,
            fullPlannerInputBuilder: {
                PaceChatTurnPart(
                    images: [],
                    systemPrompt: "system",
                    conversationHistory: [],
                    userPrompt: "do something"
                )
            },
            spokenCharacterCountProbe: { 0 },
            onToken: { _, _ in },
            onCompletion: { outcome in
                finalOutcome = outcome
            }
        )

        #expect(finalOutcome == .bothFailed)
    }

    @Test func fullWonWhenItStreamsBeforeLiteEver() async throws {
        let liteFakeStream = FakeStreamingPlannerClient(
            displayName: "lite-stub",
            chunks: [(text: "ok.", delayMs: 500)]
        )
        let fullFakeStream = FakeStreamingPlannerClient(
            displayName: "full-stub",
            chunks: [(text: "the toolbar is empty.", delayMs: 10)]
        )

        var capturedTokens: [(text: String, winner: PaceSpeculativeWinner)] = []
        var finalOutcome: PaceSpeculativeOutcome?

        await PaceSpeculativePlannerRace.raceSpeculative(
            transcript: "what's there?",
            systemPrompt: "system",
            threadMemoryPrefix: "",
            intent: .screenDescription,
            liteClient: liteFakeStream,
            fullClient: fullFakeStream,
            fullPlannerInputBuilder: {
                PaceChatTurnPart(
                    images: [],
                    systemPrompt: "system",
                    conversationHistory: [],
                    userPrompt: "what's there?"
                )
            },
            spokenCharacterCountProbe: { 0 },
            onToken: { text, winner in
                capturedTokens.append((text: text, winner: winner))
            },
            onCompletion: { outcome in
                finalOutcome = outcome
            }
        )

        #expect(finalOutcome == .fullWon)
        #expect(capturedTokens.first?.winner == .full)
    }
}
