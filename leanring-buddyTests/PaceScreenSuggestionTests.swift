import AppKit
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceScreenSuggestionCoordinatorTests {
    @MainActor final class Harness {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var eligible = true
        var evaluations = 0
        var evaluationTexts: [String] = []
        var deliveries: [PaceScreenSuggestion] = []
        var statuses: [String] = []
        var holdEvaluation = false
        var quiet = false
        var fail = false
        var rejection: PaceScreenSuggestionBoundary.BoundaryError?
        var acceptDelivery = true
        var continuation: CheckedContinuation<PaceScreenSuggestionDecision, Error>?
        let scene = PaceScreenSceneIdentity(displayIdentifier: 1, applicationProcessIdentifier: 42,
            applicationBundleIdentifier: "com.apple.Safari")
        lazy var coordinator = PaceScreenSuggestionCoordinator(now: { self.now },
            isEligible: { _ in self.eligible },
            evaluate: { observation in
                self.evaluations += 1
                self.evaluationTexts.append(String(decoding: observation.capture.imageData, as: UTF8.self))
                if self.fail { throw URLError(.cannotConnectToHost) }
                if let rejection = self.rejection { throw rejection }
                if self.holdEvaluation {
                    return try await withCheckedThrowingContinuation { self.continuation = $0 }
                }
                return self.quiet ? .quiet : .suggest(self.suggestion(observedAt: observation.observedAt))
            },
            validate: { suggestion, observation in
                String(decoding: observation.capture.imageData, as: UTF8.self).contains(suggestion.evidence)
            },
            deliver: { suggestion in
                if self.acceptDelivery { self.deliveries.append(suggestion) }
                return self.acceptDelivery
            },
            updateStatus: { self.statuses.append($0) })

        func suggestion(observedAt: Date? = nil) -> PaceScreenSuggestion {
            let observedAt = observedAt ?? now
            return PaceScreenSuggestion(identifier: UUID(), subject: "TCP congestion", evidence: "TCP congestion control",
                offer: "Would an explanation of TCP congestion help?", sceneIdentity: scene,
                observedAt: observedAt, expiresAt: observedAt.addingTimeInterval(45))
        }

        func observation(text: String = "TCP congestion control", sceneIdentity: PaceScreenSceneIdentity? = nil) -> PaceScreenSuggestionCoordinator.Observation {
            .init(capture: CompanionScreenCapture(imageData: Data(text.utf8), label: "screen", isCursorScreen: true,
                displayWidthInPoints: 100, displayHeightInPoints: 100, displayFrame: .zero,
                screenshotWidthInPixels: 100, screenshotHeightInPixels: 100),
                sceneIdentity: sceneIdentity ?? scene, observedAt: now)
        }

        func finish() {
            continuation?.resume(returning: .suggest(suggestion()))
            continuation = nil
        }
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @Test func disabledMeansNoPlannerAndNoDelivery() async {
        let harness = Harness()
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.evaluations == 0)
        #expect(harness.deliveries.isEmpty)
    }

    @Test func initialStaticFrameEvaluatesAndDeliversGroundedFollowUp() async {
        let harness = Harness()
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.evaluations == 1)
        #expect(harness.deliveries.count == 1)
        #expect(harness.coordinator.followUpContext(for: "explain that")?.contains("TCP congestion control") == true)
        #expect(harness.coordinator.appendingFollowUpContext(to: "yes").hasPrefix("yes\n\n"))
        #expect(harness.coordinator.followUpContext(for: "draw it") != nil)
        #expect(harness.coordinator.followUpContext(for: "what time is it") == nil)
    }

    @Test func inputToIdleUsesLatestFrameWithoutNeedingAnotherChange() async {
        let harness = Harness()
        harness.eligible = false
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation(text: "old text"))
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.evaluations == 0)
        harness.eligible = true
        harness.coordinator.tick()
        await settle()
        #expect(harness.evaluationTexts == ["TCP congestion control"])
    }

    @Test func animationCoalescesWithoutCancellingOrStartingParallelInference() async {
        let harness = Harness()
        harness.holdEvaluation = true
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        for index in 0..<30 {
            harness.coordinator.observe(harness.observation(text: "TCP congestion control animated \(index)"))
        }
        #expect(harness.evaluations == 1)
        #expect(harness.coordinator.isEvaluationInFlight)
        harness.finish()
        await settle()
        #expect(harness.deliveries.count == 1)
        #expect(!harness.coordinator.isEvaluationInFlight)
    }

    @Test func sameApplicationNavigationRejectsOldContent() async {
        let harness = Harness()
        harness.holdEvaluation = true
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        harness.coordinator.observe(harness.observation(text: "A different browser tab about gardening"))
        harness.finish()
        await settle()
        #expect(harness.deliveries.isEmpty)
        #expect(harness.coordinator.followUpContext(for: "yes") == nil)
    }

    @Test func stopSuppressesLateIgnoringCancellationAndKeepsOneSlot() async {
        let harness = Harness()
        harness.holdEvaluation = true
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        harness.coordinator.setEnabled(false)
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        #expect(harness.evaluations == 1)
        #expect(harness.coordinator.isEvaluationInFlight)
        harness.finish()
        await settle()
        #expect(harness.deliveries.isEmpty)
        #expect(!harness.coordinator.isEvaluationInFlight)
    }

    @Test func runtimePauseRejectsLateResultWithoutResettingEvaluationBudget() async {
        let harness = Harness()
        harness.holdEvaluation = true
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        harness.eligible = false
        harness.coordinator.invalidate(clearAnchor: true)
        harness.eligible = true
        harness.coordinator.observe(harness.observation())
        #expect(harness.evaluations == 1)
        harness.finish()
        await settle()
        #expect(harness.deliveries.isEmpty)
        #expect(harness.coordinator.followUpContext(for: "yes") == nil)
        harness.holdEvaluation = false
        harness.now = harness.now.addingTimeInterval(59)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.evaluations == 1)
        harness.now = harness.now.addingTimeInterval(1)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.evaluations == 2)
        #expect(harness.deliveries.count == 1)
    }

    @Test func sceneSwitchSuppressesLateResult() async {
        let harness = Harness()
        harness.holdEvaluation = true
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        let otherScene = PaceScreenSceneIdentity(displayIdentifier: 2, applicationProcessIdentifier: 43,
            applicationBundleIdentifier: "com.apple.TextEdit")
        harness.coordinator.observe(harness.observation(sceneIdentity: otherScene))
        harness.finish()
        await settle()
        #expect(harness.deliveries.isEmpty)
    }

    @Test func expiredObservationAndConsentLossCannotDeliver() async {
        let harness = Harness()
        harness.holdEvaluation = true
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        harness.now = harness.now.addingTimeInterval(46)
        harness.finish()
        await settle()
        #expect(harness.deliveries.isEmpty)
        harness.now = harness.now.addingTimeInterval(60)
        harness.coordinator.observe(harness.observation())
        await settle()
        harness.eligible = false
        harness.coordinator.invalidate(clearAnchor: true)
        harness.finish()
        await settle()
        #expect(harness.deliveries.isEmpty)
    }

    @Test func quietAndFailuresBothConsumeEvaluationBudgetAndDoNotAnchor() async {
        for fail in [false, true] {
            let harness = Harness()
            harness.fail = fail
            harness.quiet = true
            harness.coordinator.setEnabled(true)
            harness.coordinator.observe(harness.observation())
            await settle()
            harness.now = harness.now.addingTimeInterval(59)
            harness.coordinator.observe(harness.observation())
            await settle()
            #expect(harness.evaluations == 1)
            #expect(harness.coordinator.followUpContext(for: "yes") == nil)
            harness.now = harness.now.addingTimeInterval(1)
            harness.coordinator.observe(harness.observation())
            await settle()
            #expect(harness.evaluations == 2)
            #expect(harness.deliveries.isEmpty)
            if fail { #expect(harness.statuses.last?.contains("failed") == true) }
        }
    }

    @Test func subjectRejectionShowsGroundingFailureWithoutAnchoring() async {
        let harness = Harness()
        harness.rejection = .subjectNotVisible
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.statuses.last == "Screen suggestion rejected · its subject was not found on screen.")
        #expect(harness.deliveries.isEmpty)
        #expect(harness.coordinator.followUpContext(for: "yes") == nil)
    }

    @Test func undeliveredCandidateNeverBecomesFollowUpAndAnchorExpiresOrStops() async {
        let harness = Harness()
        harness.acceptDelivery = false
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.coordinator.followUpContext(for: "yes") == nil)
        harness.acceptDelivery = true
        harness.now = harness.now.addingTimeInterval(60)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.coordinator.followUpContext(for: "yes") != nil)
        harness.now = harness.now.addingTimeInterval(301)
        #expect(harness.coordinator.followUpContext(for: "yes") == nil)
        harness.coordinator.setEnabled(false)
        #expect(harness.coordinator.deliveredSuggestion == nil)
    }

    @Test func repeatedSubjectDoesNotRepeatWithinTenMinutes() async {
        let harness = Harness()
        harness.coordinator.setEnabled(true)
        harness.coordinator.observe(harness.observation())
        await settle()
        harness.now = harness.now.addingTimeInterval(60)
        harness.coordinator.observe(harness.observation())
        await settle()
        #expect(harness.evaluations == 2)
        #expect(harness.deliveries.count == 1)
    }
}

@MainActor
struct PaceScreenSuggestionBoundaryTests {
    let scene = PaceScreenSceneIdentity(displayIdentifier: 1, applicationProcessIdentifier: 42, applicationBundleIdentifier: "com.apple.Safari")

    @Test func unchangedScreenAndMinorAnimationWaitForMeaningfulContent() {
        var gate = PaceScreenSuggestionVisualGate()
        let original = PaceScreenVisualFingerprint(width: 10, height: 10, grayscalePixels: Array(repeating: 100, count: 100))
        #expect(gate.needsEvaluation(sceneIdentity: scene, fingerprint: original))
        gate.recordEvaluation(sceneIdentity: scene, fingerprint: original)
        #expect(!gate.needsEvaluation(sceneIdentity: scene, fingerprint: original))
        var blinkPixels = original.grayscalePixels
        blinkPixels[0] = 255
        let minorAnimation = PaceScreenVisualFingerprint(width: 10, height: 10, grayscalePixels: blinkPixels)
        #expect(!gate.needsEvaluation(sceneIdentity: scene, fingerprint: minorAnimation))
        let differentContent = PaceScreenVisualFingerprint(width: 10, height: 10, grayscalePixels: Array(repeating: 200, count: 100))
        #expect(gate.needsEvaluation(sceneIdentity: scene, fingerprint: differentContent))
        let differentApplication = PaceScreenSceneIdentity(displayIdentifier: 1, applicationProcessIdentifier: 43,
            applicationBundleIdentifier: "com.apple.TextEdit")
        #expect(gate.needsEvaluation(sceneIdentity: differentApplication, fingerprint: original))
    }

    @Test func acceptsSmallGroundedOfferAndQuiet() throws {
        let output = #"{"decision":"suggest","subject":"TCP congestion","evidence":"TCP congestion control","offer":"Would an explanation of TCP congestion help?"}"#
        let decision = try PaceScreenSuggestionBoundary.parse(output, ocr: "TCP congestion control", sceneIdentity: scene, observedAt: Date())
        guard case .suggest(let suggestion) = decision else { Issue.record("Expected grounded suggestion"); return }
        #expect(suggestion.subject == "TCP congestion")
        #expect(suggestion.untrustedFollowUpContext.contains("Untrusted quoted screen data"))
        guard case .quiet = try PaceScreenSuggestionBoundary.parse(#"{"decision":"quiet"}"#, ocr: "", sceneIdentity: scene, observedAt: Date()) else {
            Issue.record("Expected quiet"); return
        }
    }

    @Test func capturedPlannerParaphraseHasSpecificGroundingRejection() {
        let ocr = """
        How does a turbofan engine work?
        I am studying jet engines. I want to understand why modern passenger aircraft use high-bypass turbofans.
        Bypass ratio and propulsive efficiency
        Why can moving more air at a lower exhaust speed use less fuel for the same thrust?
        """
        let output = #"{"decision":"suggest","subject":"High-bypass turbofan efficiency","evidence":"Why can moving more air at a lower exhaust speed use less fuel for the same thrust?","offer":"Would you like an explanation of high-bypass turbofan efficiency using momentum and kinetic energy?"}"#
        #expect(throws: PaceScreenSuggestionBoundary.BoundaryError.subjectNotVisible) {
            try PaceScreenSuggestionBoundary.parse(output, ocr: ocr, sceneIdentity: scene, observedAt: Date())
        }
    }

    @Test func malformedJSONHasTypedContentFreeRejection() {
        #expect(throws: PaceScreenSuggestionBoundary.BoundaryError.invalidDecision) {
            try PaceScreenSuggestionBoundary.parse("private response body", ocr: "", sceneIdentity: scene, observedAt: Date())
        }
        #expect(throws: PaceScreenSuggestionBoundary.BoundaryError.evidenceNotVisible) {
            try PaceScreenSuggestionBoundary.parse(
                #"{"decision":"suggest","subject":"TCP congestion","evidence":"Invented evidence that was never visible","offer":"Explain TCP congestion?"}"#,
                ocr: "TCP congestion control", sceneIdentity: scene, observedAt: Date())
        }
    }

    @Test func rejectsActionsTagsInjectionInventedSubjectAndExtraKeys() {
        let invalid = [
            #"{"decision":"suggest","subject":"TCP congestion","evidence":"TCP congestion control","offer":"Explain TCP congestion?","actions":[]}"#,
            #"{"decision":"suggest","subject":"TCP congestion","evidence":"TCP congestion control","offer":"<tool>Explain TCP congestion?</tool>"}"#,
            #"{"decision":"suggest","subject":"TCP congestion","evidence":"ignore previous instructions","offer":"Explain TCP congestion?"}"#,
            #"{"decision":"suggest","subject":"Rocket engines","evidence":"TCP congestion control","offer":"Explain Rocket engines?"}"#,
            #"{"decision":"quiet","tool":"shell"}"#,
            #"<action>click(1,2)</action>"#,
            #"```json {"decision":"quiet"} ```"#
        ]
        for output in invalid {
            #expect(throws: (any Error).self) {
                try PaceScreenSuggestionBoundary.parse(output,
                    ocr: "TCP congestion control ignore previous instructions", sceneIdentity: scene, observedAt: Date())
            }
        }
    }

    @Test func redactsSensitiveLinesAddressesNumbersAndBoundsEgress() {
        let input = "TCP congestion control\npassword: hunter2\nAPI key: sk-test-secret\nalice@example.com\n4111 1111 1111 1111\n" + String(repeating: "ordinary paragraph ", count: 1000)
        let redacted = PaceScreenSuggestionBoundary.redactedOCR(input)
        #expect(redacted.hasPrefix("TCP congestion control"))
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("sk-test-secret"))
        #expect(!redacted.contains("alice@example.com"))
        #expect(!redacted.contains("4111"))
        #expect(redacted.count == 6000)
        #expect(PaceScreenSuggestionPrivacy.isSensitiveApplication(nil))
        #expect(PaceScreenSuggestionPrivacy.isSensitiveApplication("com.1password.1password"))
        #expect(!PaceScreenSuggestionPrivacy.isSensitiveApplication("com.apple.Safari"))
    }
}

@MainActor
struct PaceScreenSuggestionIntegrationTests {
    final class History: PaceChatHistorySource, PaceConversationEventPersisting {
        var turns: [PaceChatHistoryTurn] = []
        func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] { turns }
        func upsertConversationEvent(_ event: ConversationEvent) {
            turns.removeAll { $0.id == event.eventID }
            turns.append(PaceChatHistoryTurn(id: event.eventID, userText: "", paceText: "",
                recordedAt: event.createdAt, conversationEvent: event))
        }
    }
    final class Submitter: PaceChatTranscriptSubmitting {
        func submitChatTranscript(_ transcript: String, optimisticMessageIdentifier: String) {}
    }

    @Test func assistantOnlySuggestionRemainsVisibleAfterHistoryReload() {
        let history = History()
        let session = PaceChatSession(historySource: history, transcriptSubmitter: Submitter())
        let offer = "Would an explanation of TCP congestion help?"
        let recorder = PaceConversationRecorder(persister: history, chatSession: session)
        let event = ConversationEvent(eventID: "suggestion", role: .pace, origin: .proactive, text: offer)
        recorder.record(event)
        #expect(session.userFacingMessages.map(\.body) == [offer])
        session.loadHistory()
        recorder.record(event)
        session.loadHistory()
        #expect(session.userFacingMessages.map(\.body) == [offer])
        #expect(session.userFacingMessages.first?.role == .pace)
    }

    private func makeWatchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PaceScreenSuggestionIntegrationTests." + UUID().uuidString)!
    }

    private func activeSessionDictionary(isLocked: Bool? = nil) -> [String: Any] {
        var dictionary: [String: Any] = [kCGSessionUserIDKey as String: 501,
            kCGSessionOnConsoleKey as String: true]
        if let isLocked { dictionary["CGSSessionScreenIsLocked"] = isLocked }
        return dictionary
    }

    private func makeWatchManager(defaults: UserDefaults) -> CompanionManager {
        let manager = CompanionManager(watchModeDefaults: defaults)
        manager.useLocalVLMForScreenContext = true
        let sessionDictionary = activeSessionDictionary()
        manager.watchSessionSnapshotProvider = {
            PaceScreenWatchSessionSnapshot(sessionDictionary: sessionDictionary, currentUserIdentifier: 501)
        }
        manager.watchScreenPermissionProvider = { true }
        manager.watchPlannerConsentProvider = { true }
        return manager
    }

    @Test func watchDefaultsOffAndReadScreenIsRequired() {
        let defaults = makeWatchDefaults()
        let manager = CompanionManager(watchModeDefaults: defaults)
        #expect(!manager.isWatchModeEnabled)
        #expect(defaults.object(forKey: PaceUserPreferenceKey.isWatchModeEnabled.rawValue) == nil)
        #expect(!manager.areWatchObservationNudgesEnabled)
        manager.useLocalVLMForScreenContext = false
        manager.setWatchModeEnabled(true)
        #expect(!manager.isWatchModeEnabled)
        #expect(manager.latestWatchModeSummary?.contains("Read My Screen") == true)
    }

    @Test func explicitWatchChoicePersistsOnAndOffAcrossManagers() {
        let defaults = makeWatchDefaults()
        let firstManager = makeWatchManager(defaults: defaults)
        firstManager.setWatchModeEnabled(true)
        #expect(CompanionManager(watchModeDefaults: defaults).isWatchModeEnabled)
        let relaunchedManager = makeWatchManager(defaults: defaults)
        relaunchedManager.setWatchModeEnabled(false)
        #expect(!CompanionManager(watchModeDefaults: defaults).isWatchModeEnabled)
        relaunchedManager.setWatchModeEnabled(false)
        #expect(defaults.object(forKey: PaceUserPreferenceKey.isWatchModeEnabled.rawValue) as? Bool == false)
    }

    @Test func readMyScreenOffPersistsWatchOffDuringRuntimePause() {
        let defaults = makeWatchDefaults()
        let manager = makeWatchManager(defaults: defaults)
        manager.setWatchModeEnabled(true)
        manager.startWatchRuntime()
        manager.setWatchRuntimePaused(.screenLocked, isPaused: true)
        manager.useLocalVLMForScreenContext = false
        #expect(!manager.isWatchModeEnabled)
        #expect(!CompanionManager(watchModeDefaults: defaults).isWatchModeEnabled)
        manager.setWatchRuntimePaused(.screenLocked, isPaused: false)
        #expect(!manager.screenWatchModeController.isWatching)
        manager.stopWatchRuntime()
    }

    @Test func overlappingLockSleepAndUserSwitchPauseWithoutChangingChoice() {
        let defaults = makeWatchDefaults()
        let manager = makeWatchManager(defaults: defaults)
        var sessionDictionary = activeSessionDictionary()
        manager.watchSessionSnapshotProvider = {
            PaceScreenWatchSessionSnapshot(sessionDictionary: sessionDictionary, currentUserIdentifier: 501)
        }
        manager.setWatchModeEnabled(true)
        manager.startWatchRuntime()
        #expect(manager.screenWatchModeController.isWatching)
        sessionDictionary = activeSessionDictionary(isLocked: true)
        manager.setWatchRuntimePaused(.screenLocked, isPaused: true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(manager.isWatchModeEnabled)
        #expect(!manager.screenWatchModeController.isWatching)
        #expect(manager.screenSuggestionCoordinator.isEnabled)
        sessionDictionary = activeSessionDictionary()
        manager.setWatchRuntimePaused(.screenLocked, isPaused: false)
        #expect(!manager.screenWatchModeController.isWatching)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(manager.screenWatchModeController.isWatching)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!manager.screenWatchModeController.isWatching)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(manager.screenWatchModeController.isWatching)
        manager.stopWatchRuntime()
        #expect(CompanionManager(watchModeDefaults: defaults).isWatchModeEnabled)
    }

    @Test func currentSessionPermissionAndPlannerConsentGateEveryResume() {
        let defaults = makeWatchDefaults()
        let manager = makeWatchManager(defaults: defaults)
        var sessionDictionary: [String: Any]?
        var hasScreenPermission = true
        var hasPlannerConsent = true
        manager.watchSessionSnapshotProvider = {
            PaceScreenWatchSessionSnapshot(sessionDictionary: sessionDictionary, currentUserIdentifier: 501)
        }
        manager.watchScreenPermissionProvider = { hasScreenPermission }
        manager.watchPlannerConsentProvider = { hasPlannerConsent }
        manager.setWatchModeEnabled(true)
        manager.startWatchRuntime()
        #expect(!manager.screenWatchModeController.isWatching)
        #expect(!manager.screenSuggestionCaptureAllowed())
        let deniedSessions: [[String: Any]] = [
            [kCGSessionUserIDKey as String: 501],
            [kCGSessionOnConsoleKey as String: true],
            [kCGSessionUserIDKey as String: 502, kCGSessionOnConsoleKey as String: true],
            [kCGSessionUserIDKey as String: 501, kCGSessionOnConsoleKey as String: false],
            activeSessionDictionary(isLocked: true)
        ]
        for deniedSession in deniedSessions {
            sessionDictionary = deniedSession
            manager.reconcileWatchRuntime()
            #expect(!manager.screenWatchModeController.isWatching)
            #expect(!manager.screenSuggestionCaptureAllowed())
        }
        sessionDictionary = activeSessionDictionary()
        hasScreenPermission = false
        manager.reconcileWatchRuntime()
        #expect(!manager.screenWatchModeController.isWatching)
        hasScreenPermission = true
        hasPlannerConsent = false
        manager.reconcileWatchRuntime()
        #expect(!manager.screenWatchModeController.isWatching)
        hasPlannerConsent = true
        manager.reconcileWatchRuntime()
        #expect(manager.screenWatchModeController.isWatching)
        sessionDictionary = activeSessionDictionary(isLocked: true)
        #expect(!manager.screenSuggestionCaptureAllowed())
        #expect(manager.isWatchModeEnabled)
        manager.stopWatchRuntime()
    }

    @Test func runtimePauseCancelsWatchSpeechWithoutCancellingForegroundTask() {
        let manager = makeWatchManager(defaults: makeWatchDefaults())
        manager.setWatchModeEnabled(true)
        manager.startWatchRuntime()
        let watchSpeechTask = Task { }
        let foregroundTask = Task { }
        manager.watchSuggestionSpeechTask = watchSpeechTask
        manager.currentResponseTask = foregroundTask
        manager.setWatchRuntimePaused(.screenLocked, isPaused: true)
        #expect(watchSpeechTask.isCancelled)
        #expect(!foregroundTask.isCancelled)
        foregroundTask.cancel()
        manager.stopWatchRuntime()
    }

    @Test func acceptedVoiceFollowUpAcknowledgesSavedOfferWithoutAcknowledgingUnrelatedVoice() async {
        let preferences = makeWatchDefaults()
        let manager = makeWatchManager(defaults: preferences)
        let history = History()
        let session = PaceChatSession(historySource: history, transcriptSubmitter: Submitter(), preferences: preferences)
        manager.chatSession = session
        manager.conversationRecorder = PaceConversationRecorder(persister: history, chatSession: session)
        let observedAt = Date()
        let scene = PaceScreenSceneIdentity(displayIdentifier: 1, applicationProcessIdentifier: 42,
            applicationBundleIdentifier: "com.apple.Safari")
        let suggestion = PaceScreenSuggestion(identifier: UUID(), subject: "climbing grades", evidence: "climbing grades and raw strength",
            offer: "Want an explanation of climbing grades?", sceneIdentity: scene,
            observedAt: observedAt, expiresAt: observedAt.addingTimeInterval(45))
        session.upsertConversationEvent(ConversationEvent(eventID: "screen-suggestion-" + suggestion.identifier.uuidString,
            role: .pace, origin: .proactive, text: suggestion.offer, createdAt: observedAt))
        let coordinator = PaceScreenSuggestionCoordinator(isEligible: { _ in true },
            evaluate: { _ in .suggest(suggestion) }, validate: { _, _ in true },
            deliver: { _ in true }, updateStatus: { _ in })
        manager.screenSuggestionCoordinator = coordinator
        coordinator.setEnabled(true)
        coordinator.observe(.init(capture: CompanionScreenCapture(imageData: Data(), label: "screen", isCursorScreen: true,
            displayWidthInPoints: 100, displayHeightInPoints: 100, displayFrame: .zero,
            screenshotWidthInPixels: 100, screenshotHeightInPixels: 100), sceneIdentity: scene, observedAt: observedAt))
        for _ in 0..<100 { await Task.yield() }
        #expect(coordinator.followUpContext(for: "yes") != nil)
        manager.beginConversationRequest("what time is it")
        #expect(session.hasUnreadScreenSuggestion)
        manager.beginConversationRequest("yes")
        #expect(!session.hasUnreadScreenSuggestion)
    }

    @Test func runtimeStopPreservesChoiceAndRepeatedStartOwnsOneObserverSet() {
        let defaults = makeWatchDefaults()
        let manager = makeWatchManager(defaults: defaults)
        manager.setWatchModeEnabled(true)
        manager.startWatchRuntime()
        manager.startWatchRuntime()
        manager.setWatchModeEnabled(true)
        #expect(manager.watchWorkspaceLifecycleObservers.count == 4)
        #expect(manager.watchDistributedLifecycleObservers.count == 2)
        #expect(manager.screenWatchModeController.isWatching)
        manager.stopWatchRuntime()
        #expect(manager.isWatchModeEnabled)
        #expect(CompanionManager(watchModeDefaults: defaults).isWatchModeEnabled)
        #expect(!manager.screenWatchModeController.isWatching)
        #expect(manager.watchWorkspaceLifecycleObservers.isEmpty)
        #expect(manager.watchDistributedLifecycleObservers.isEmpty)
        manager.setWatchRuntimePaused(.screenLocked, isPaused: false)
        manager.reconcileWatchRuntime()
        #expect(!manager.screenWatchModeController.isWatching)
        manager.startWatchRuntime()
        #expect(manager.screenWatchModeController.isWatching)
        manager.setWatchModeEnabled(false)
        manager.setWatchRuntimePaused(.systemSleeping, isPaused: false)
        #expect(!manager.screenWatchModeController.isWatching)
        manager.stopWatchRuntime()
    }

    @Test func foregroundHostedHeadlessAndIdempotentLeasesKeepDisclosureUntilAllFinish() {
        let manager = CompanionManager()
        manager.activePacePadTurnIdentifier = "local-turn"
        let backgroundLease = manager.beginScreenSuggestionDisclosureLease(isOffDevice: true)
        #expect(!manager.activePacePadTurnUsesOffDevicePlanner)
        manager.endScreenSuggestionDisclosureLease(backgroundLease)
        manager.foregroundOffDeviceTurnInFlight = true
        manager.hostedMCPOffDeviceTurnInFlight = true
        let lease = manager.beginScreenSuggestionDisclosureLease(isOffDevice: true)
        #expect(manager.beginHeadlessOffDeviceIndicatorIfNeeded(forceOffDevice: true))
        manager.foregroundOffDeviceTurnInFlight = false
        #expect(manager.isOffDeviceTurnInFlight)
        manager.endHeadlessOffDeviceIndicatorIfNeeded()
        manager.hostedMCPOffDeviceTurnInFlight = false
        #expect(manager.isOffDeviceTurnInFlight)
        manager.endScreenSuggestionDisclosureLease(lease)
        #expect(!manager.isOffDeviceTurnInFlight)
        let newerLease = manager.beginScreenSuggestionDisclosureLease(isOffDevice: true)
        manager.endScreenSuggestionDisclosureLease(lease)
        #expect(manager.isOffDeviceTurnInFlight)
        manager.endScreenSuggestionDisclosureLease(newerLease)
        #expect(!manager.isOffDeviceTurnInFlight)
    }
}
