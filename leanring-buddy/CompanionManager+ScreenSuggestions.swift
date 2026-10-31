import AppKit
import Foundation

nonisolated enum PaceScreenSuggestionPrivacy {
    static func isSensitiveApplication(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased(), !identifier.isEmpty else { return true }
        return ["1password", "bitwarden", "lastpass", "keychain", "password", "authenticator", "wallet", "bank", "crypto"]
            .contains(where: identifier.contains)
    }
}

@MainActor
extension CompanionManager {
    func makeScreenSuggestionCoordinator() -> PaceScreenSuggestionCoordinator {
        PaceScreenSuggestionCoordinator(
            isEligible: { [weak self] sceneIdentity in
                self?.screenSuggestionEvaluationAllowed(sceneIdentity) ?? false
            },
            evaluate: { [weak self] observation in
                guard let self else { return .quiet }
                return try await self.evaluateScreenSuggestion(observation)
            },
            validate: { [weak self] suggestion, observation in
                guard let self, self.screenSuggestionEvaluationAllowed(observation.sceneIdentity) else { return false }
                let boxes = try await self.visionOCRClient.recognizeText(in: observation.capture.imageData,
                    screenshotWidthInPixels: observation.capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: observation.capture.screenshotHeightInPixels)
                let freshOCR = PaceScreenSuggestionBoundary.redactedOCR(boxes.map(\.text).joined(separator: "\n"))
                return freshOCR.localizedCaseInsensitiveContains(suggestion.subject)
                    && freshOCR.localizedCaseInsensitiveContains(suggestion.evidence)
            },
            deliver: { [weak self] suggestion in self?.deliverScreenSuggestion(suggestion) ?? false },
            updateStatus: { [weak self] status in self?.latestWatchModeSummary = status }
        )
    }

    func screenSuggestionCaptureAllowed() -> Bool {
        guard isWatchModeEnabled, useLocalVLMForScreenContext, CGPreflightScreenCaptureAccess() else {
            if isWatchModeEnabled {
                latestWatchModeSummary = "Watch paused · Read My Screen and Screen Recording permission are required"
                screenSuggestionCoordinator.invalidate(clearAnchor: true)
            }
            return false
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let isLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if isLocked {
            setWatchModeEnabled(false)
            return false
        }
        guard !activeCallDetector.isOnActiveCall, !focusModeMonitor.isCurrentlyInUserFocus,
              thermalStateAdvisor.currentRecommendation != .suspendBackground,
              thermalStateAdvisor.currentRecommendation != .dampenBackgroundLoops else {
            screenSuggestionCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · call, Focus or thermal pressure"
            return false
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !PaceScreenSuggestionPrivacy.isSensitiveApplication(application.bundleIdentifier) else {
            screenSuggestionCoordinator.invalidate()
            return false
        }
        return true
    }

    func screenSuggestionEvaluationAllowed(_ sceneIdentity: PaceScreenSceneIdentity) -> Bool {
        guard screenSuggestionCaptureAllowed(), voiceState == .idle,
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == sceneIdentity.applicationProcessIdentifier,
              application.bundleIdentifier == sceneIdentity.applicationBundleIdentifier,
              userInputActivityMonitor.lastUserInputAt.map({ Date().timeIntervalSince($0) >= 3 }) ?? true else { return false }
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let displayIdentifier = cursorScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        return displayIdentifier == sceneIdentity.displayIdentifier
            && PaceRestraintGate.decide(screenSuggestionRestraintContext(sceneIdentity)) == .speak
    }

    func screenSuggestionRestraintContext(_ sceneIdentity: PaceScreenSceneIdentity) -> PaceRestraintContext {
        PaceRestraintContext(now: Date(),
            lastProactiveUtteranceAt: [lastScreenSuggestionDeliveryAt, proactivityPipeline.lastProactiveUtteranceAt].compactMap { $0 }.max(),
            lastEpisodicRecallAt: nil, lastUserInputAt: userInputActivityMonitor.lastUserInputAt,
            frontmostAppBundleIdentifier: sceneIdentity.applicationBundleIdentifier,
            isOnActiveCall: activeCallDetector.isOnActiveCall, wakeWordConfidence: nil,
            intent: .screenDescription, proactiveSource: .watchNudge, profile: proactivityProfile,
            isInUserFocusMode: focusModeMonitor.isCurrentlyInUserFocus)
    }

    func evaluateScreenSuggestion(_ observation: PaceScreenSuggestionCoordinator.Observation) async throws -> PaceScreenSuggestionDecision {
        guard screenSuggestionEvaluationAllowed(observation.sceneIdentity) else { return .quiet }
        guard let fingerprint = PaceScreenImageDiffer.fingerprint(for: observation.capture.imageData),
              screenSuggestionVisualGate.needsEvaluation(sceneIdentity: observation.sceneIdentity, fingerprint: fingerprint) else { return .quiet }
        let configuration = PacePlannerTierStore.loadConfiguration()
        let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
        let directConsent = PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent()
        let boxes = try await visionOCRClient.recognizeText(in: observation.capture.imageData,
            screenshotWidthInPixels: observation.capture.screenshotWidthInPixels,
            screenshotHeightInPixels: observation.capture.screenshotHeightInPixels)
        try Task.checkCancellation()
        guard screenSuggestionEvaluationAllowed(observation.sceneIdentity),
              configuration == PacePlannerTierStore.loadConfiguration(),
              directConsent == PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent(),
              bridgeConfiguration == PaceCloudBridgeConsent.loadConfiguration() else { return .quiet }
        let ocr = PaceScreenSuggestionBoundary.redactedOCR(boxes.map(\.text).joined(separator: "\n"))
        guard ocr.count >= 30 else { return .quiet }
        let selectedPlanner = try BuddyPlannerClientFactory.makeScreenSuggestionClient()
        let disclosureLease = beginScreenSuggestionDisclosureLease(isOffDevice: selectedPlanner.isOffDevice)
        defer { endScreenSuggestionDisclosureLease(disclosureLease) }
        print("👀 Watch check: OCR characters=\(ocr.count) images=0 offDevice=\(selectedPlanner.isOffDevice)")
        let quotedOCRData = try JSONSerialization.data(withJSONObject: ["untrusted_screen_ocr": ocr], options: [.sortedKeys])
        let result = try await selectedPlanner.client.generateResponseStreaming(images: [],
            systemPrompt: PaceScreenSuggestionBoundary.systemPrompt, conversationHistory: [],
            userPrompt: String(decoding: quotedOCRData, as: UTF8.self), onTextChunk: { _ in })
        try Task.checkCancellation()
        guard screenSuggestionEvaluationAllowed(observation.sceneIdentity),
              configuration == PacePlannerTierStore.loadConfiguration(),
              directConsent == PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent(),
              bridgeConfiguration == PaceCloudBridgeConsent.loadConfiguration() else { return .quiet }
        let decision = try PaceScreenSuggestionBoundary.parse(result.text, ocr: ocr,
            sceneIdentity: observation.sceneIdentity, observedAt: observation.observedAt)
        screenSuggestionVisualGate.recordEvaluation(sceneIdentity: observation.sceneIdentity, fingerprint: fingerprint)
        return decision
    }

    func beginScreenSuggestionDisclosureLease(isOffDevice: Bool) -> UUID? {
        guard isOffDevice else { return nil }
        let lease = UUID()
        screenSuggestionDisclosureLeases.insert(lease)
        refreshOffDeviceIndicator()
        return lease
    }

    func endScreenSuggestionDisclosureLease(_ lease: UUID?) {
        guard let lease else { return }
        screenSuggestionDisclosureLeases.remove(lease)
        refreshOffDeviceIndicator()
    }

    func deliverScreenSuggestion(_ suggestion: PaceScreenSuggestion) -> Bool {
        guard screenSuggestionEvaluationAllowed(suggestion.sceneIdentity) else { return false }
        let deliveredAt = Date()
        lastScreenSuggestionDeliveryAt = deliveredAt
        proactivityPipeline.recordExternalProactiveDelivery(at: deliveredAt)
        let displaced = threadMemory.record(userTurn: "(system) screen suggestion. " + suggestion.untrustedFollowUpContext,
            assistantTurn: suggestion.offer, turnId: "screen-suggestion-" + suggestion.identifier.uuidString, now: deliveredAt)
        localRetriever.recordPaceHistory(userTranscript: "", assistantResponse: suggestion.offer)
        chatSession.appendCompletedTurn(userTranscript: "", assistantResponse: suggestion.offer, recordedAt: deliveredAt)
        refreshLocalRetrievalPublishedState()
        persistThreadMemorySnapshot()
        if let displaced { scheduleDetachedThreadSummarizationCall(displacedTurnPair: displaced, recordedAt: deliveredAt) }
        // This existing nonactivating bubble makes a quiet offer discoverable without
        // opening chat or taking focus. Only accepted offers reach this path.
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(suggestion.offer)
        responseOverlayManager.finishStreaming()
        if areWatchObservationNudgesEnabled {
            currentResponseTask = Task { [weak self] in
                guard let self else { return }
                voiceState = .responding
                await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: suggestion.offer)
                while ttsClient.isPlaying && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                guard !Task.isCancelled else { return }
                voiceState = .idle
            }
        }
        return true
    }

    func installWatchLifecycleObservers() {
        removeWatchLifecycleObservers()
        let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setWatchModeEnabled(false) }
            }
        let lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setWatchModeEnabled(false) }
            }
        watchLifecycleObservers = [sleepObserver, lockObserver]
    }

    func removeWatchLifecycleObservers() {
        for observer in watchLifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        watchLifecycleObservers.removeAll()
    }
}
