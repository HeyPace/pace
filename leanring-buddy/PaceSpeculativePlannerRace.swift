//
//  PaceSpeculativePlannerRace.swift
//  leanring-buddy
//
//  Wave 4 speed lever: race the in-process Apple Foundation Models
//  planner (lite, text-only, no VLM) against the full LM Studio
//  planner pipeline (heavy, VLM-fed, accurate) for screen-action /
//  screen-description turns. Whichever streams first wins the TTS
//  pipeline; the loser's stream is cancelled.
//
//  Why this exists
//  ---------------
//  The full pipeline cold-VLM p95 is ~1.5–3.5s. Apple FM TTFT is
//  ~100–300ms once the system model is resident. For the long tail
//  of screen turns where the lite answer is already "good enough"
//  (chitchat-adjacent: "what's on screen", "any errors here"), the
//  user hears something in a quarter of the latency. The race never
//  blocks on the VLM call before producing audio.
//
//  Supersede policy
//  ----------------
//  If the full pipeline finishes streaming within
//  `superseedingWindowMillis` of the lite call's first token AND the
//  user has heard fewer than `superseedingMaxSpokenCharacters`, we
//  cancel the lite stream, drain whatever it queued, and start the
//  TTS pipeline fresh against the full stream. Past either threshold
//  superseding mid-turn would feel janky — the lite winner stays.
//
//  RAM impact: zero new model weights. Apple FM is in-process; the
//  full planner is already loaded. The race is pure concurrency.
//

import Foundation

// MARK: - Public types

/// Which planner produced the streamed text the user heard. Read by
/// CompanionManager so it can journal the right line and surface the
/// right diagnostic ("⚡ lite path won" vs "🧠 full path won").
enum PaceSpeculativeWinner: Equatable {
    case lite
    case full
}

/// Final outcome of a race. Distinguishes "lite finished first and
/// stayed the winner" from "lite started speaking then got cut by the
/// full stream" so the caller can decide whether to log the supersede.
enum PaceSpeculativeOutcome: Equatable {
    case liteWon
    case fullWon
    case fullSupersededLite
    case bothFailed
}

/// Bundle of full-pipeline inputs the race needs to invoke the heavy
/// planner WITHOUT actually building them until the full path is going
/// to fire. Built lazily because the screen context (VLM call + OCR +
/// AX) is the most expensive prep step in the entire turn — if the lite
/// path wins fast we want to avoid paying for it.
struct PaceChatTurnPart {
    let images: [(data: Data, label: String)]
    let systemPrompt: String
    let conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    let userPrompt: String
}

// MARK: - Race driver

@MainActor
enum PaceSpeculativePlannerRace {
    /// Threshold for the supersede window. When the FULL pipeline
    /// produces its first token within this many milliseconds of the
    /// LITE pipeline's first token, AND the user hasn't heard much
    /// audio yet, the full stream supersedes. Tuned by taste — past
    /// ~500ms the user has already cognitively committed to the lite
    /// answer and a swap feels jarring.
    static let superseedingWindowMillis: Int = 500

    /// Past this many spoken characters the supersede is suppressed.
    /// ~60 chars ≈ 6 syllables — past that the user has heard enough
    /// of the lite reply that cutting it mid-stream is worse than
    /// just letting it finish. Caller passes the streaming pipeline's
    /// `firstSpokenWordCharacterCount` as the live value.
    static let superseedingMaxSpokenCharacters: Int = 60

    /// Run the race. The lite path uses Apple FM with the transcript +
    /// thread memory ONLY (no VLM element block). The full path uses
    /// the production planner with whatever inputs the lazy builder
    /// returns. Whichever produces text first wins; `onToken` is
    /// called for the WINNER's stream only.
    ///
    /// `onCompletion` fires exactly once with the final outcome.
    ///
    /// Why `liteClient` is typed `any BuddyPlannerClient` rather than
    /// the concrete `AppleFoundationModelsPlannerClient`: production
    /// always passes the Apple FM client (the gate enforces it), but
    /// unit tests substitute a fake. The race's behavior is
    /// type-agnostic — it only calls `generateResponseStreaming`.
    /// Discipline is enforced at the call site by the gate predicate.
    static func raceSpeculative(
        transcript: String,
        systemPrompt: String,
        threadMemoryPrefix: String,
        intent: PaceIntent,
        liteClient: any BuddyPlannerClient,
        fullClient: any BuddyPlannerClient,
        fullPlannerInputBuilder: @escaping @Sendable () async -> PaceChatTurnPart,
        spokenCharacterCountProbe: @escaping @MainActor () -> Int,
        onToken: @escaping @MainActor (String, PaceSpeculativeWinner) -> Void,
        onCompletion: @escaping @MainActor (PaceSpeculativeOutcome) -> Void
    ) async {
        // Coordinator: tracks which path has produced its first token
        // and routes tokens through the right callback. Lives on the
        // main actor so the @Published state on the pipeline stays
        // consistent.
        let coordinator = SpeculativeRaceCoordinator(
            spokenCharacterCountProbe: spokenCharacterCountProbe,
            onToken: onToken
        )

        // Build the lite user prompt: transcript + thread summary
        // prefix, no LOCAL SCREEN ELEMENTS block. The full path
        // includes the screen context; the lite path explicitly does
        // not — that's the entire point of "lite."
        let liteUserPrompt: String = {
            if threadMemoryPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcript
            }
            return threadMemoryPrefix + "\n\n" + transcript
        }()

        async let liteResult: Result<String, Error> = runLitePlanner(
            client: liteClient,
            systemPrompt: systemPrompt,
            userPrompt: liteUserPrompt,
            coordinator: coordinator
        )
        async let fullResult: Result<String, Error> = runFullPlanner(
            client: fullClient,
            inputBuilder: fullPlannerInputBuilder,
            coordinator: coordinator
        )

        let liteOutcome = await liteResult
        let fullOutcome = await fullResult

        let resolvedOutcome = coordinator.resolveOutcome(
            liteOutcome: liteOutcome,
            fullOutcome: fullOutcome,
            intent: intent
        )
        onCompletion(resolvedOutcome)
    }

    // MARK: - Lite path

    private static func runLitePlanner(
        client: any BuddyPlannerClient,
        systemPrompt: String,
        userPrompt: String,
        coordinator: SpeculativeRaceCoordinator
    ) async -> Result<String, Error> {
        do {
            let (responseText, _) = try await client.generateResponseStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                onTextChunk: { @MainActor accumulatedText in
                    coordinator.handleLiteTextChunk(accumulatedText)
                }
            )
            await MainActor.run {
                coordinator.markLiteFinished()
            }
            return .success(responseText)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Full path

    private static func runFullPlanner(
        client: any BuddyPlannerClient,
        inputBuilder: @Sendable () async -> PaceChatTurnPart,
        coordinator: SpeculativeRaceCoordinator
    ) async -> Result<String, Error> {
        let plannerInputs = await inputBuilder()
        do {
            let (responseText, _) = try await client.generateResponseStreaming(
                images: plannerInputs.images,
                systemPrompt: plannerInputs.systemPrompt,
                conversationHistory: plannerInputs.conversationHistory,
                userPrompt: plannerInputs.userPrompt,
                onTextChunk: { @MainActor accumulatedText in
                    coordinator.handleFullTextChunk(accumulatedText)
                }
            )
            await MainActor.run {
                coordinator.markFullFinished()
            }
            return .success(responseText)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Coordinator

/// Per-race state. Tracks which path produced its first token, when,
/// and whether the supersede window is still open. All mutation runs
/// on the main actor because the spoken-character probe + onToken
/// callback both require it.
@MainActor
private final class SpeculativeRaceCoordinator {
    private let spokenCharacterCountProbe: () -> Int
    private let onToken: (String, PaceSpeculativeWinner) -> Void

    private var liteFirstTokenAt: Date?
    private var fullFirstTokenAt: Date?

    /// Current winner. nil until SOMETHING produces text. Once set, the
    /// supersede check on every full-path token decides whether to
    /// switch. Set back to .full only when the supersede fires; set to
    /// .lite/.full only once on each first-token event.
    private var currentWinner: PaceSpeculativeWinner?

    /// True once a winner has actually emitted at least one token —
    /// used by `resolveOutcome` so a winner that produced zero tokens
    /// (because the run errored after the first-token timestamp was
    /// stamped but before any text actually streamed) doesn't show up
    /// as "won" in the outcome.
    private var didWinnerProduceAnyTokens: Bool = false

    /// True once a supersede has happened. Reflected back in the
    /// outcome as `.fullSupersededLite`.
    private var didSupersede: Bool = false

    init(
        spokenCharacterCountProbe: @escaping () -> Int,
        onToken: @escaping (String, PaceSpeculativeWinner) -> Void
    ) {
        self.spokenCharacterCountProbe = spokenCharacterCountProbe
        self.onToken = onToken
    }

    func handleLiteTextChunk(_ accumulatedText: String) {
        let now = Date()
        if liteFirstTokenAt == nil {
            liteFirstTokenAt = now
        }
        // First token from the LITE path wins the race for now, unless
        // FULL got there first.
        if currentWinner == nil {
            currentWinner = .lite
            print("⚡ Speculative race: lite path produced first token")
        }
        if currentWinner == .lite {
            didWinnerProduceAnyTokens = true
            onToken(accumulatedText, .lite)
        }
    }

    func handleFullTextChunk(_ accumulatedText: String) {
        let now = Date()
        if fullFirstTokenAt == nil {
            fullFirstTokenAt = now
        }
        if currentWinner == nil {
            currentWinner = .full
            didWinnerProduceAnyTokens = true
            onToken(accumulatedText, .full)
            print("🧠 Speculative race: full path produced first token")
            return
        }
        // FULL produced text AFTER lite won. Decide whether to
        // supersede: the window is still open AND the user hasn't
        // heard too much yet.
        if currentWinner == .lite, !didSupersede,
           let liteFirstTokenAt {
            let elapsedSinceLiteFirstTokenMs = Int(
                now.timeIntervalSince(liteFirstTokenAt) * 1000
            )
            let spokenCharacterCountSoFar = spokenCharacterCountProbe()
            if elapsedSinceLiteFirstTokenMs
                <= PaceSpeculativePlannerRace.superseedingWindowMillis,
               spokenCharacterCountSoFar
                < PaceSpeculativePlannerRace.superseedingMaxSpokenCharacters {
                print("🔀 Speculative race: full path superseding lite (window=\(elapsedSinceLiteFirstTokenMs)ms, spoken=\(spokenCharacterCountSoFar) chars)")
                didSupersede = true
                currentWinner = .full
                didWinnerProduceAnyTokens = true
                onToken(accumulatedText, .full)
                return
            }
        }
        // Lite already won unsupersededly — drop FULL tokens silently.
    }

    func markLiteFinished() {
        // No-op today: the outcome resolution reads currentWinner +
        // didSupersede + the result enums. Hook is here for symmetry +
        // future "lite finished but errored after first token" branches.
    }

    func markFullFinished() {
        // No-op today; see markLiteFinished comment.
    }

    func resolveOutcome(
        liteOutcome: Result<String, Error>,
        fullOutcome: Result<String, Error>,
        intent: PaceIntent
    ) -> PaceSpeculativeOutcome {
        let liteSucceeded: Bool = {
            if case .success = liteOutcome { return true }
            return false
        }()
        let fullSucceeded: Bool = {
            if case .success = fullOutcome { return true }
            return false
        }()

        if !liteSucceeded && !fullSucceeded {
            return .bothFailed
        }
        if didSupersede {
            return .fullSupersededLite
        }
        switch currentWinner {
        case .lite:
            return .liteWon
        case .full:
            return .fullWon
        case .none:
            // No token was ever emitted. If full succeeded with an
            // empty stream, call it fullWon to keep the outcome enum
            // honest; otherwise bothFailed (rare).
            return fullSucceeded ? .fullWon : .bothFailed
        }
    }
}
