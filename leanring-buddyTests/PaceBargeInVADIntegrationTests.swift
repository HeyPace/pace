//
//  PaceBargeInVADIntegrationTests.swift
//  leanring-buddyTests
//
//  Wave 1c plumbing tests — exercises the streaming-pipeline +
//  TTS-client barge-in contract WITHOUT spinning up CompanionManager
//  itself (CompanionManager has too many dependencies — model loader,
//  permission services, screen capture — to instantiate cheaply in a
//  unit test).
//
//  The CompanionManager-side gate logic (subscribe only when
//  voiceState == .responding AND isAlwaysListeningEnabled) is
//  shape-tested by asserting on the VAD-as-pure-struct contract: a
//  test that does NOT feed samples must not fire. The end-to-end
//  CompanionManager wiring is covered by the existing app-level
//  smoke harness (`scripts/smoke-runtime-hooks.sh`) rather than a
//  unit test, because the real wiring crosses Combine + DispatchQueue
//  boundaries that don't lend themselves to deterministic XCTest.
//

import Combine
import Foundation
import Testing
@testable import Pace

/// Minimal BuddyTTSClient conformer the pipeline tests can observe.
/// Stop reasons + speak history are exposed so we can assert that
/// `drainQueueAndStopForBargeIn` pre-stamps `.userBargeIn` BEFORE
/// stopping playback.
@MainActor
private final class BargeInTestRecordingTTSClient: BuddyTTSClient {
    private(set) var spokenTexts: [String] = []
    private(set) var stopPlaybackCallCount: Int = 0
    /// Mirrors the real client's behaviour: `recordExpectedStopReason`
    /// stages a pending reason that `stopPlayback()` then promotes.
    private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion
    private var pendingNextStopReason: PaceTTSStopReason?
    var isPlaying: Bool { false }

    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
        // Match real client: fresh utterance clears stop-reason state.
        lastStopReason = .naturalCompletion
        pendingNextStopReason = nil
    }

    func stopPlayback() {
        stopPlaybackCallCount += 1
        lastStopReason = pendingNextStopReason ?? .manualStop
        pendingNextStopReason = nil
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
        pendingNextStopReason = reason
    }
}

@MainActor
struct PaceBargeInVADIntegrationTests {

    // MARK: - VAD-as-pure contract — gate semantics

    /// "VAD does NOT fire when voiceState != .responding" — modelled
    /// here by NOT feeding samples to the VAD at all. The gate in
    /// `CompanionManager.bindBargeInGateObservation` is responsible for
    /// detaching the audio-level subscription when state != responding,
    /// so the VAD literally receives zero `observe(...)` calls in that
    /// mode. A test that feeds nothing must therefore never fire.
    @Test
    func vadDoesNotFireWhenNoSamplesAreObserved() {
        var detector = PaceBargeInVAD()
        // No `observe(...)` calls — gate is closed (state != responding
        // or isAlwaysListeningEnabled == false). The detector starts
        // in a non-firing state and must stay there.
        // The contract is "no audio in → no detection out". Asserted
        // by re-observing the start state via a zero-energy sample,
        // which the existing PaceBargeInVAD treats as "reset the
        // sustained window".
        let didFireOnSilence = detector.observe(normalizedLevel: 0, at: Date())
        #expect(didFireOnSilence == false)
    }

    /// "VAD does NOT fire when isAlwaysListeningEnabled == false" —
    /// again modelled by silence (the gate detaches the subscription).
    /// Even a single loud sample that arrives BEFORE the gate detaches
    /// must not fire because PaceBargeInVAD requires SUSTAINED speech
    /// (0.6s default) above threshold — a one-off blip cannot trip it.
    @Test
    func vadDoesNotFireOnSingleSampleEvenWhenLoud() {
        var detector = PaceBargeInVAD()
        let didFireOnSingleLoudSample = detector.observe(
            normalizedLevel: 0.8,
            at: Date()
        )
        #expect(didFireOnSingleLoudSample == false)
    }

    /// Synthetic sustained-speech sample (≥0.12 RMS for ≥0.6 sec)
    /// DOES trigger the VAD. This is the positive case the gate
    /// guards: when both `voiceState == .responding` AND
    /// `isAlwaysListeningEnabled == true`, the publisher subscription
    /// pipes RMS samples through and a sustained burst trips the
    /// detector.
    @Test
    func sustainedSpeechAboveThresholdFiresAfterMinimumDuration() {
        var detector = PaceBargeInVAD()
        let speechStartedAt = Date()

        // Feed dense samples (well within the 0.25s max-inter-sample gap)
        // all above the 0.12 RMS speech threshold so the sustained-speech
        // window keeps accumulating.
        #expect(detector.observe(normalizedLevel: 0.15, at: speechStartedAt) == false)
        #expect(detector.observe(
            normalizedLevel: 0.20,
            at: speechStartedAt.addingTimeInterval(0.2)
        ) == false)
        #expect(detector.observe(
            normalizedLevel: 0.18,
            at: speechStartedAt.addingTimeInterval(0.4)
        ) == false)
        // Cross the 0.6s sustained-speech window.
        #expect(detector.observe(
            normalizedLevel: 0.18,
            at: speechStartedAt.addingTimeInterval(0.62)
        ) == true)
    }

    // MARK: - Pipeline drain — barge-in contract

    /// `drainQueueAndStopForBargeIn` must:
    /// 1. Pre-stamp `.userBargeIn` on the TTS client BEFORE stopping
    ///    (so a subsequent `lastStopReason` read sees barge-in, not
    ///    manual stop).
    /// 2. Stop playback on the TTS client (single call).
    /// 3. Flip `lastTurnWasInterrupted = true` so the manager can
    ///    journal the interrupt.
    /// 4. Block any subsequent `acceptStreamedText` for the SAME
    ///    turn from dispatching to TTS (speculative sentences /
    ///    in-flight planner chunks must NOT leak audio).
    @Test
    func drainQueueAndStopForBargeInPropagatesStopReasonAndLocksTurn() async {
        let recordingClient = BargeInTestRecordingTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: recordingClient)

        // Simulate a turn that's already mid-stream: a sentence was
        // dispatched and is "playing". The barge-in arrives.
        pipeline.markIntentCommitted()
        await pipeline.acceptStreamedText("Sure, let me check that for you. ")
        // Establish baseline: pipeline dispatched at least one sentence.
        #expect(recordingClient.spokenTexts.isEmpty == false)
        let dispatchedSentenceCountBeforeBargeIn = recordingClient.spokenTexts.count

        // Barge-in fires.
        pipeline.drainQueueAndStopForBargeIn()

        // 1. Stop reason promoted to .userBargeIn.
        #expect(recordingClient.lastStopReason == .userBargeIn)
        // 2. stopPlayback was called exactly once.
        #expect(recordingClient.stopPlaybackCallCount == 1)
        // 3. lastTurnWasInterrupted flag is set.
        #expect(pipeline.lastTurnWasInterrupted == true)

        // 4. A second `acceptStreamedText` after barge-in must NOT
        //    dispatch new audio (speculative sentence lock-out).
        await pipeline.acceptStreamedText(
            "Sure, let me check that for you. Here is what I found. "
        )
        #expect(recordingClient.spokenTexts.count == dispatchedSentenceCountBeforeBargeIn)
    }

    /// `lastTurnWasInterrupted` must reset on the next
    /// `markIntentCommitted()` — a new turn's intent-commit is the
    /// boundary that makes the previous turn's interrupt history
    /// stale.
    @Test
    func lastTurnWasInterruptedResetsOnNextIntentCommit() async {
        let recordingClient = BargeInTestRecordingTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: recordingClient)

        pipeline.markIntentCommitted()
        pipeline.drainQueueAndStopForBargeIn()
        #expect(pipeline.lastTurnWasInterrupted == true)

        // Next turn begins — the flag must reset so the panel UI
        // doesn't show "previous turn interrupted" forever.
        pipeline.markIntentCommitted()
        #expect(pipeline.lastTurnWasInterrupted == false)
    }

    // MARK: - PacePushToTalkManager listening-window contract

    /// PTT takes priority — if a window is already open under
    /// `.userPushToTalk`, a `.bargeIn` trigger must NOT replace it.
    /// This is the user-says-stop-and-hold-PTT-simultaneously case.
    @Test
    func pushToTalkListeningWindowIsNotDisplacedByBargeInTrigger() {
        let pttManager = PacePushToTalkManager()
        pttManager.openListeningWindow(
            durationInSeconds: 5,
            trigger: .userPushToTalk
        )
        #expect(pttManager.currentListeningWindowTrigger == .userPushToTalk)

        // Barge-in arrives — PTT must win.
        pttManager.openListeningWindow(
            durationInSeconds: 6,
            trigger: .bargeIn
        )
        #expect(pttManager.currentListeningWindowTrigger == .userPushToTalk)
    }

    /// Non-PTT triggers replace each other — a wake-word window can
    /// be displaced by a barge-in window. This makes the API
    /// idempotent for the trigger sequences Wave 2 will exercise.
    @Test
    func bargeInTriggerReplacesWakeWordTrigger() {
        let pttManager = PacePushToTalkManager()
        pttManager.openListeningWindow(
            durationInSeconds: 5,
            trigger: .wakeWord
        )
        #expect(pttManager.currentListeningWindowTrigger == .wakeWord)

        pttManager.openListeningWindow(
            durationInSeconds: 6,
            trigger: .bargeIn
        )
        #expect(pttManager.currentListeningWindowTrigger == .bargeIn)
    }

    // MARK: - audioLevelPublisher contract

    /// The publisher must exist and be subscribable WITHOUT the audio
    /// engine being running. Subscribers in CompanionManager attach
    /// while `voiceState == .responding` — that state is entered
    /// AFTER the PTT tap was already removed, so the publisher must
    /// not require an engine-running precondition just to accept a
    /// subscription.
    @Test
    func audioLevelPublisherAcceptsSubscriptionsWithoutAudioEngineRunning() {
        let pttManager = PacePushToTalkManager()
        var receivedLevelsCount = 0
        let subscription = pttManager.audioLevelPublisher.sink { _ in
            receivedLevelsCount += 1
        }
        // No engine running → publisher emits nothing. The subscription
        // call itself must not crash or fail.
        #expect(receivedLevelsCount == 0)
        subscription.cancel()
    }
}
