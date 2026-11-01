import AppKit
import Combine
import Foundation

nonisolated enum PaceScreenWatchPauseReason: Hashable {
    case screenLocked
    case systemSleeping
    case userSessionInactive
}

nonisolated struct PaceScreenWatchSessionSnapshot {
    let isScreenLocked: Bool?
    let isOnConsole: Bool?

    init(sessionDictionary: [String: Any]?, currentUserIdentifier: UInt32) {
        guard let sessionDictionary,
              let sessionUserIdentifier = sessionDictionary[kCGSessionUserIDKey as String] as? NSNumber,
              sessionUserIdentifier.uint32Value == currentUserIdentifier else {
            isScreenLocked = nil
            isOnConsole = nil
            return
        }
        isOnConsole = sessionDictionary[kCGSessionOnConsoleKey as String] as? Bool
        // macOS omits the lock key for an unlocked session. Only a verified
        // current-user console session can turn that absence into permission.
        if let lockValue = sessionDictionary["CGSSessionScreenIsLocked"] {
            isScreenLocked = lockValue as? Bool
        } else {
            isScreenLocked = false
        }
    }

    var allowsScreenWatch: Bool { isScreenLocked == false && isOnConsole == true }

    static func current() -> Self {
        Self(sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any],
            currentUserIdentifier: getuid())
    }
}

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
                guard let freshOCR = PaceScreenSuggestionBoundary.redactedBackgroundOCR(boxes.map(\.text).joined(separator: "\n")) else { return false }
                return freshOCR.localizedCaseInsensitiveContains(suggestion.subject)
                    && freshOCR.localizedCaseInsensitiveContains(suggestion.evidence)
            },
            deliver: { [weak self] suggestion in self?.deliverScreenSuggestion(suggestion) ?? false },
            updateStatus: { [weak self] status in self?.latestWatchModeSummary = status }
        )
    }

    func makeScreenWatchNoteCoordinator() -> PaceScreenWatchNoteCoordinator {
        PaceScreenWatchNoteCoordinator(
            isEligible: { [weak self] observation in
                self?.screenWatchNoteCaptureAllowed(observation) ?? false
            },
            sourceRevision: { [weak self] in self?.localRetriever.screenWatchHistoryAccessGeneration ?? 0 },
            recognizeText: { [weak self] observation in
                guard let self else { return [] }
                return try await visionOCRClient.recognizeText(in: observation.capture.imageData,
                    screenshotWidthInPixels: observation.capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: observation.capture.screenshotHeightInPixels)
            },
            persist: { [weak self] observation, excerpt in
                _ = self?.persistScreenWatchNote(observation, excerpt: excerpt)
            },
            onDelayedRecognition: {
                PaceAPIAuditLog.shared.record(subsystem: "screen", operation: "screen_watch_note",
                    target: "local_screen_history", durationMilliseconds: 0, outcome: "ocr_delayed")
            }
        )
    }

    @discardableResult
    func persistScreenWatchNote(_ observation: PaceScreenWatchObservation, excerpt: String) -> Bool {
        guard localRetriever.recordScreenWatchObservation(screenLabel: observation.capture.label,
            categoryDisplayName: "observed screen text",
            frontmostApplicationName: observation.applicationDisplayName ?? observation.sceneIdentity.applicationBundleIdentifier,
            screenDescription: excerpt, now: observation.observedAt) else { return false }
        refreshLocalRetrievalPublishedState(sourceSubset: [.screenWatchHistory])
        PaceAPIAuditLog.shared.record(subsystem: "screen", operation: "screen_watch_note",
            target: "local_screen_history", durationMilliseconds: 0, outcome: "stored",
            inputCharacterCount: excerpt.count)
        return true
    }

    func screenWatchNoteCaptureAllowed(_ observation: PaceScreenWatchObservation) -> Bool {
        guard localRetriever.isSourceEnabled(.screenWatchHistory), screenSuggestionCaptureAllowed(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == observation.sceneIdentity.applicationProcessIdentifier,
              application.bundleIdentifier == observation.sceneIdentity.applicationBundleIdentifier else { return false }
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let displayIdentifier = cursorScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        return displayIdentifier == observation.sceneIdentity.displayIdentifier
    }

    func observeWatchSample(_ observation: PaceScreenWatchObservation) {
        screenSuggestionCoordinator.observe(observation)
        screenWatchNoteCoordinator.observe(observation)
    }

    func screenSuggestionCaptureAllowed() -> Bool {
        if !screenSuggestionNotificationPresentationAllowed() { screenSuggestionNotification.discard() }
        if let pauseSummary = screenWatchRuntimePauseSummary() {
            if isWatchModeEnabled {
                latestWatchModeSummary = pauseSummary
                screenSuggestionCoordinator.invalidate(clearAnchor: true)
                screenWatchNoteCoordinator.invalidate()
                cancelWatchSuggestionSpeech()
            }
            return false
        }
        guard !activeCallDetector.isOnActiveCall else {
            screenSuggestionCoordinator.invalidate()
            screenWatchNoteCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · active call"
            return false
        }
        guard !focusModeMonitor.isCurrentlyInUserFocus else {
            screenSuggestionCoordinator.invalidate()
            screenWatchNoteCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · macOS Focus is active"
            return false
        }
        guard thermalStateAdvisor.currentRecommendation != .suspendBackground,
              thermalStateAdvisor.currentRecommendation != .dampenBackgroundLoops else {
            screenSuggestionCoordinator.invalidate()
            screenWatchNoteCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · thermal pressure"
            return false
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            screenSuggestionCoordinator.invalidate()
            screenWatchNoteCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · no foreground application"
            return false
        }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            screenSuggestionCoordinator.invalidate()
            screenWatchNoteCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · switch from Pace to another app"
            return false
        }
        guard !PaceScreenSuggestionPrivacy.isSensitiveApplication(application.bundleIdentifier) else {
            screenSuggestionCoordinator.invalidate()
            screenWatchNoteCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · protected application"
            return false
        }
        return true
    }

    func screenSuggestionEvaluationAllowed(_ sceneIdentity: PaceScreenSceneIdentity) -> Bool {
        guard screenSuggestionCaptureAllowed() else { return false }
        guard voiceState == .idle else {
            latestWatchModeSummary = "Watch paused · voice turn in progress"
            return false
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == sceneIdentity.applicationProcessIdentifier,
              application.bundleIdentifier == sceneIdentity.applicationBundleIdentifier else {
            latestWatchModeSummary = "Watch waiting · foreground application changed"
            return false
        }
        guard userInputActivityMonitor.lastUserInputAt.map({ Date().timeIntervalSince($0) >= 3 }) ?? true else {
            latestWatchModeSummary = "Watch waiting · waiting for a brief pause"
            return false
        }
        let cursorScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let displayIdentifier = cursorScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        guard displayIdentifier == sceneIdentity.displayIdentifier else {
            latestWatchModeSummary = "Watch waiting · pointer display changed"
            return false
        }
        switch PaceRestraintGate.decide(screenSuggestionRestraintContext(sceneIdentity)) {
        case .speak:
            return true
        case .stayQuiet(let reason), .queueUntilIdle(let reason):
            latestWatchModeSummary = "Watch waiting · \(reason)"
            return false
        }
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

    func evaluateScreenSuggestion(_ observation: PaceScreenWatchObservation) async throws -> PaceScreenSuggestionDecision {
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
        guard let ocr = PaceScreenSuggestionBoundary.redactedBackgroundOCR(boxes.map(\.text).joined(separator: "\n")),
              ocr.count >= 30 else { return .quiet }
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
        let outcome: String
        switch decision {
        case .quiet: outcome = "quiet"
        case .suggest: outcome = "suggest"
        }
        PaceAPIAuditLog.shared.record(subsystem: "screen", operation: "screen_suggestion_decision",
            target: "screen_suggestion_boundary", durationMilliseconds: 0, outcome: outcome,
            inputCharacterCount: ocr.count)
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
        guard screenSuggestionEvaluationAllowed(suggestion.sceneIdentity),
              !screenSuggestionNotification.hasPresented(suggestionIdentifier: suggestion.identifier) else { return false }
        let deliveredAt = Date()
        lastScreenSuggestionDeliveryAt = deliveredAt
        proactivityPipeline.recordExternalProactiveDelivery(at: deliveredAt)
        recordAssistantNarration(suggestion.offer, origin: .proactive,
            eventIdentifier: suggestion.conversationEventIdentifier, recordedAt: deliveredAt,
            plannerContext: "(system) screen suggestion. " + suggestion.untrustedFollowUpContext)
        screenSuggestionNotification.present(suggestion)
        if areWatchObservationNudgesEnabled {
            let speechGeneration = watchSuggestionSpeechGeneration
            let speechTask = Task { [weak self] in
                guard let self, !Task.isCancelled,
                      watchSuggestionSpeechGeneration == speechGeneration,
                      screenSuggestionEvaluationAllowed(suggestion.sceneIdentity) else { return }
                await speakAcceptedWatchSuggestion(suggestion, speechGeneration: speechGeneration)
            }
            watchSuggestionSpeechTask = speechTask
            currentResponseTask = speechTask
        }
        return true
    }

    func speakAcceptedWatchSuggestion(_ suggestion: PaceScreenSuggestion, speechGeneration: UInt64) async {
        guard !Task.isCancelled, watchSuggestionSpeechGeneration == speechGeneration,
              voiceState == .idle else { return }
        streamingSentenceTTSPipeline.resetForNewTurn()
        isWatchSuggestionSpeaking = true
        defer {
            if watchSuggestionSpeechGeneration == speechGeneration {
                streamingSentenceTTSPipeline.finalizeInFlightStreamedTextForTurn()
                watchSuggestionSpeechTask = nil
                isWatchSuggestionSpeaking = false
                if voiceState == .responding { voiceState = .idle }
            }
        }
        voiceState = .responding
        await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: suggestion.offer)
        while ttsClient.isPlaying && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    func screenSuggestionNotificationPresentationAllowed() -> Bool {
        screenWatchRuntimePauseSummary() == nil
            && !activeCallDetector.isOnActiveCall
            && !focusModeMonitor.isCurrentlyInUserFocus
            && thermalStateAdvisor.currentRecommendation != .suspendBackground
            && thermalStateAdvisor.currentRecommendation != .dampenBackgroundLoops
            && !PaceScreenSuggestionPrivacy.isSensitiveApplication(watchForegroundApplicationIdentifierProvider())
    }

    func recordUnavailableScreenSuggestionFeedback(_ suggestion: PaceScreenSuggestion, eventIdentifier: String? = nil,
                                                   message: String = "I can’t open that explanation right now. Watch is paused or privacy protections are active.") {
        let feedbackIdentifier = "screen-suggestion-unavailable-" + (eventIdentifier ?? suggestion.identifier.uuidString)
        if conversationRecorder.event(withIdentifier: feedbackIdentifier) == nil {
            recordAssistantNarration(message, origin: .failure, eventIdentifier: feedbackIdentifier, turnIdentifier: eventIdentifier)
        }
        NotificationCenter.default.post(name: .paceShowPanel, object: PaceConversationPanelPresentationIntent.preview)
    }

    func screenSuggestionContextForCurrentPrivacyGate(_ context: PaceScreenSuggestionRequestContext?) -> PaceScreenSuggestionRequestContext? {
        if let context, case .followUp = context, !screenSuggestionNotificationPresentationAllowed() { return nil }
        return context
    }

    func discardScreenSuggestionRequestIfUnavailable(_ context: PaceScreenSuggestionRequestContext?,
                                                     eventIdentifier: String?) -> Bool {
        guard let context, case .notification = context,
              !screenSuggestionNotificationPresentationAllowed() else { return false }
        if let eventIdentifier {
            conversationRecorder.updateDeliveryState(.cancelled, eventIdentifier: eventIdentifier)
        }
        recordUnavailableScreenSuggestionFeedback(context.suggestion, eventIdentifier: eventIdentifier)
        return true
    }

    func validateScreenSuggestionRequestForPlanner(_ context: PaceScreenSuggestionRequestContext?,
                                                   turnLease: PaceTurnLease) -> Bool {
        guard isActiveTurn(turnLease) else { return false }
        guard let context, !screenSuggestionNotificationPresentationAllowed() else { return true }
        if case .followUp = context {
            recordUnavailableScreenSuggestionFeedback(context.suggestion, eventIdentifier: activeConversationUserEvent?.eventID,
                message: "I stopped that screen follow-up because Watch is unavailable. Restate the topic to continue.")
        } else {
            _ = discardScreenSuggestionRequestIfUnavailable(context, eventIdentifier: activeConversationUserEvent?.eventID)
        }
        cancelActiveTurnTasks()
        streamingSentenceTTSPipeline.stopForUserDismissal()
        streamingSentenceTTSPipeline.finalizeInFlightStreamedTextForTurn()
        responseOverlayManager.finishStreaming()
        voiceState = .idle
        currentTurnHUDState = .idle
        return false
    }

    func handleScreenSuggestionNotificationAction(_ suggestion: PaceScreenSuggestion,
                                                 action: PaceScreenSuggestionNotificationAction) {
        if action == .dismiss {
            cancelWatchSuggestionSpeech()
            chatSession.acknowledgeScreenSuggestion(eventIdentifier: suggestion.conversationEventIdentifier)
            return
        }
        guard let request = action.request(for: suggestion) else { return }
        guard screenSuggestionNotificationPresentationAllowed() else {
            recordUnavailableScreenSuggestionFeedback(suggestion)
            return
        }
        chatSession.acknowledgeScreenSuggestion(eventIdentifier: suggestion.conversationEventIdentifier)
        cancelWatchSuggestionSpeech()
        NotificationCenter.default.post(name: .paceShowPanel, object: PaceConversationPanelPresentationIntent.interactive)
        submitScreenSuggestionRequest(request, suggestion: suggestion)
    }

    func cancelWatchSuggestionSpeech() {
        watchSuggestionSpeechGeneration &+= 1
        watchSuggestionSpeechTask?.cancel()
        watchSuggestionSpeechTask = nil
        if isWatchSuggestionSpeaking {
            ttsClient.stopPlayback()
            if voiceState == .responding { voiceState = .idle }
        }
        isWatchSuggestionSpeaking = false
    }

    func startWatchRuntime() {
        guard !isWatchRuntimeStarted else {
            reconcileWatchRuntime()
            return
        }
        isWatchRuntimeStarted = true
        watchRuntimeGeneration &+= 1
        watchPauseReasons.removeAll()
        let sessionSnapshot = watchSessionSnapshotProvider()
        if sessionSnapshot.isScreenLocked == true { watchPauseReasons.insert(.screenLocked) }
        if sessionSnapshot.isOnConsole == false { watchPauseReasons.insert(.userSessionInactive) }
        installWatchLifecycleObservers()
        screenSuggestionCoordinator.setEnabled(isWatchModeEnabled)
        reconcileWatchRuntime()
    }

    func stopWatchRuntime() {
        isWatchRuntimeStarted = false
        watchRuntimeGeneration &+= 1
        screenWatchModeController.stopWatching()
        screenSuggestionCoordinator.setEnabled(false)
        screenWatchNoteCoordinator.invalidate()
        cancelWatchSuggestionSpeech()
        screenSuggestionNotification.discard()
        removeWatchLifecycleObservers()
        watchPauseReasons.removeAll()
        latestWatchModeSummary = isWatchModeEnabled ? "Watch paused · Pace is stopped" : nil
    }

    func setWatchRuntimePaused(_ reason: PaceScreenWatchPauseReason, isPaused: Bool) {
        guard isWatchRuntimeStarted else { return }
        if isPaused {
            watchPauseReasons.insert(reason)
        } else {
            watchPauseReasons.remove(reason)
        }
        reconcileWatchRuntime()
    }

    func screenWatchRuntimePauseSummary() -> String? {
        guard isWatchModeEnabled else { return "Watch is off" }
        guard isWatchRuntimeStarted else { return "Watch paused · Pace is stopped" }
        guard useLocalVLMForScreenContext else { return "Watch paused · Read My Screen is required" }
        if watchPauseReasons.contains(.systemSleeping) { return "Watch paused · Mac is sleeping" }
        if watchPauseReasons.contains(.screenLocked) { return "Watch paused · screen is locked" }
        if watchPauseReasons.contains(.userSessionInactive) { return "Watch paused · user session is inactive" }
        let sessionSnapshot = watchSessionSnapshotProvider()
        guard sessionSnapshot.allowsScreenWatch else {
            return sessionSnapshot.isScreenLocked == true
                ? "Watch paused · screen is locked" : "Watch paused · waiting for an active unlocked user session"
        }
        guard watchScreenPermissionProvider() else { return "Watch paused · Screen Recording permission is required" }
        guard watchPlannerConsentProvider() else { return "Watch paused · selected planner consent is required" }
        return nil
    }

    func reconcileWatchRuntime() {
        if !screenSuggestionNotificationPresentationAllowed() { screenSuggestionNotification.discard() }
        if let pauseSummary = screenWatchRuntimePauseSummary() {
            screenWatchModeController.stopWatching()
            screenSuggestionCoordinator.invalidate(clearAnchor: true)
            screenWatchNoteCoordinator.invalidate()
            cancelWatchSuggestionSpeech()
            latestWatchModeSummary = isWatchModeEnabled ? pauseSummary : nil
            return
        }
        guard !screenWatchModeController.isWatching else { return }
        latestWatchModeSummary = "Watching · suggestions use the selected planner"
        screenWatchModeController.startWatching(
            shouldCapture: { [weak self] in self?.screenSuggestionCaptureAllowed() ?? false },
            onSample: { [weak self] observation in self?.observeWatchSample(observation) },
            onMeaningfulChange: { _ in }
        )
    }

    func installWatchLifecycleObservers() {
        removeWatchLifecycleObservers()
        let runtimeGeneration = watchRuntimeGeneration
        for eventName in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: eventName,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenWatchNoteCoordinator.invalidate() }
            }
            watchWorkspaceLifecycleObservers.append(observer)
        }
        activeCallDetector.$isOnActiveCall.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.screenWatchNoteCoordinator.invalidate()
        }.store(in: &watchPrivacySubscriptions)
        focusModeMonitor.$isCurrentlyInUserFocus.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.screenWatchNoteCoordinator.invalidate()
        }.store(in: &watchPrivacySubscriptions)
        thermalStateAdvisor.$currentRecommendation.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.screenWatchNoteCoordinator.invalidate()
        }.store(in: &watchPrivacySubscriptions)
        let workspaceEvents: [(Notification.Name, PaceScreenWatchPauseReason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleeping, true),
            (NSWorkspace.didWakeNotification, .systemSleeping, false),
            (NSWorkspace.sessionDidResignActiveNotification, .userSessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .userSessionInactive, false)
        ]
        let distributedEvents: [(Notification.Name, PaceScreenWatchPauseReason, Bool)] = [
            (Notification.Name("com.apple.screenIsLocked"), .screenLocked, true),
            (Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, false)
        ]
        for (notificationName, pauseReason, isPaused) in workspaceEvents {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: notificationName,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isWatchRuntimeStarted, self.watchRuntimeGeneration == runtimeGeneration else { return }
                    self.setWatchRuntimePaused(pauseReason, isPaused: isPaused)
                }
            }
            watchWorkspaceLifecycleObservers.append(observer)
        }
        for (notificationName, pauseReason, isPaused) in distributedEvents {
            let observer = DistributedNotificationCenter.default().addObserver(forName: notificationName,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isWatchRuntimeStarted, self.watchRuntimeGeneration == runtimeGeneration else { return }
                    self.setWatchRuntimePaused(pauseReason, isPaused: isPaused)
                }
            }
            watchDistributedLifecycleObservers.append(observer)
        }
    }

    func removeWatchLifecycleObservers() {
        watchPrivacySubscriptions.removeAll()
        for observer in watchWorkspaceLifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in watchDistributedLifecycleObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        watchWorkspaceLifecycleObservers.removeAll()
        watchDistributedLifecycleObservers.removeAll()
    }
}
