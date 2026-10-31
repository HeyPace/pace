import AppKit
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
                let freshOCR = PaceScreenSuggestionBoundary.redactedOCR(boxes.map(\.text).joined(separator: "\n"))
                return freshOCR.localizedCaseInsensitiveContains(suggestion.subject)
                    && freshOCR.localizedCaseInsensitiveContains(suggestion.evidence)
            },
            deliver: { [weak self] suggestion in self?.deliverScreenSuggestion(suggestion) ?? false },
            updateStatus: { [weak self] status in self?.latestWatchModeSummary = status }
        )
    }

    func screenSuggestionCaptureAllowed() -> Bool {
        if let pauseSummary = screenWatchRuntimePauseSummary() {
            if isWatchModeEnabled {
                latestWatchModeSummary = pauseSummary
                screenSuggestionCoordinator.invalidate(clearAnchor: true)
                cancelWatchSuggestionSpeech()
            }
            return false
        }
        guard !activeCallDetector.isOnActiveCall else {
            screenSuggestionCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · active call"
            return false
        }
        guard !focusModeMonitor.isCurrentlyInUserFocus else {
            screenSuggestionCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · macOS Focus is active"
            return false
        }
        guard thermalStateAdvisor.currentRecommendation != .suspendBackground,
              thermalStateAdvisor.currentRecommendation != .dampenBackgroundLoops else {
            screenSuggestionCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · thermal pressure"
            return false
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            screenSuggestionCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · no foreground application"
            return false
        }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            screenSuggestionCoordinator.invalidate()
            latestWatchModeSummary = "Watch paused · switch from Pace to another app"
            return false
        }
        guard !PaceScreenSuggestionPrivacy.isSensitiveApplication(application.bundleIdentifier) else {
            screenSuggestionCoordinator.invalidate()
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
        guard screenSuggestionEvaluationAllowed(suggestion.sceneIdentity) else { return false }
        let deliveredAt = Date()
        lastScreenSuggestionDeliveryAt = deliveredAt
        proactivityPipeline.recordExternalProactiveDelivery(at: deliveredAt)
        recordAssistantNarration(suggestion.offer, origin: .proactive,
            eventIdentifier: "screen-suggestion-" + suggestion.identifier.uuidString, recordedAt: deliveredAt,
            plannerContext: "(system) screen suggestion. " + suggestion.untrustedFollowUpContext)
        // This existing nonactivating bubble makes a quiet offer discoverable without
        // opening chat or taking focus. Only accepted offers reach this path.
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(suggestion.offer)
        responseOverlayManager.finishStreaming()
        if areWatchObservationNudgesEnabled {
            let speechGeneration = watchSuggestionSpeechGeneration
            let speechTask = Task { [weak self] in
                guard let self, !Task.isCancelled,
                      watchSuggestionSpeechGeneration == speechGeneration,
                      screenSuggestionEvaluationAllowed(suggestion.sceneIdentity) else { return }
                isWatchSuggestionSpeaking = true
                defer {
                    if watchSuggestionSpeechGeneration == speechGeneration {
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
            watchSuggestionSpeechTask = speechTask
            currentResponseTask = speechTask
        }
        return true
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
        cancelWatchSuggestionSpeech()
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
        if let pauseSummary = screenWatchRuntimePauseSummary() {
            screenWatchModeController.stopWatching()
            screenSuggestionCoordinator.invalidate(clearAnchor: true)
            cancelWatchSuggestionSpeech()
            latestWatchModeSummary = isWatchModeEnabled ? pauseSummary : nil
            return
        }
        guard !screenWatchModeController.isWatching else { return }
        latestWatchModeSummary = "Watching · suggestions use the selected planner"
        screenWatchModeController.startWatching(
            shouldCapture: { [weak self] in self?.screenSuggestionCaptureAllowed() ?? false },
            onSample: { [weak self] capture, sceneIdentity, observedAt in
                self?.screenSuggestionCoordinator.observe(.init(capture: capture,
                    sceneIdentity: sceneIdentity, observedAt: observedAt))
            },
            onMeaningfulChange: { [weak self] event in await self?.handleWatchModeEvent(event) }
        )
    }

    func installWatchLifecycleObservers() {
        removeWatchLifecycleObservers()
        let runtimeGeneration = watchRuntimeGeneration
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
