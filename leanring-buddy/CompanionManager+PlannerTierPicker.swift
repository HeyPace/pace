//
//  CompanionManager+PlannerTierPicker.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A5):
//  planner tier picker setters, Direct-API key management, and off-device tier checks.
//

import AppKit

@MainActor
extension CompanionManager {
    func setFastEverydayAnswersEnabled(_ enabled: Bool) {
        PacePlannerTierStore.setFastEverydayAnswersEnabled(enabled)
        fastEverydayAnswersEnabled = enabled
        if enabled {
            prewarmFastAnswerCredentialsIfNeeded()
        } else {
            invalidateFastAnswerCredentialPrewarm()
        }
    }

    private var canPrewarmFastAnswerCredentials: Bool {
        fastEverydayAnswersEnabled
            && activePlannerTier == .cliDirect
            && activePlannerTierCLIDirectUpstream == .codex
            && (plannerClient as? PaceLocalCLIPlannerClient)?.allowsBoundedEverydayAnswers == true
            && fastAnswerCredentialSourceIsReady()
    }

    func prewarmFastAnswerCredentialsIfNeeded() {
        guard fastAnswerCredentialPrewarmTask == nil, canPrewarmFastAnswerCredentials else { return }
        let generation = fastAnswerCredentialPrewarmGeneration
        fastAnswerCredentialPrewarmTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == fastAnswerCredentialPrewarmGeneration {
                    fastAnswerCredentialPrewarmTask = nil
                }
            }
            // Consent and the selected brain can change before this queued task starts.
            guard !Task.isCancelled, generation == fastAnswerCredentialPrewarmGeneration,
                canPrewarmFastAnswerCredentials
            else { return }
            _ = try? await fastAnswerCredentialStore.loadOpenAIKey()
        }
    }

    func invalidateFastAnswerCredentialPrewarm() {
        fastAnswerCredentialPrewarmGeneration = UUID()
        fastAnswerCredentialPrewarmTask?.cancel()
        fastAnswerCredentialPrewarmTask = nil
        fastAnswerCredentialStore.clearCachedKey()
    }

    /// The default action planner can differ from the configured tier after a
    /// local fallback or a legacy bridge override. The settings summary describes
    /// the instantiated client, without starting a request or checking credentials.
    var defaultPlannerBoundary: PacePlannerBoundary {
        switch plannerClient {
        case is HybridPlannerClient: return .hybrid
        case let client as DirectAPIPlannerClient: return client.usesLoopbackEndpoint ? .loopbackEndpoint : .offDevice
        case is CloudBridgePlannerClient, is PaceLocalCLIPlannerClient: return .offDevice
        case is LocalPlannerClient, is PaceMLXPlannerClient, is AppleFoundationModelsPlannerClient: return .onDevice
        default: return .unknown
        }
    }

    // MARK: - Planner tier picker state

    func setActivePlannerTier(_ newTier: PacePlannerTier) {
        if newTier != activePlannerTier {
            invalidateFastAnswerCredentialPrewarm()
            diagramOverlayController.dismiss()
            imageOverlayController.dismiss()
        }
        activePlannerTier = newTier
        PacePlannerTierStore.saveTier(newTier)
        // Rebuild planner so the next turn uses the freshly-picked tier
        // without requiring an app restart.
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
        if newTier == .cliDirect {
            prewarmFastAnswerCredentialsIfNeeded()
        } else {
            invalidateFastAnswerCredentialPrewarm()
        }
    }

    /// Apply the selection only after its consent flow finishes. Cancelling leaves the
    /// live client, saved preference, bridge mode and any open overlays untouched.
    @discardableResult
    func selectPlannerTierWithConsent(
        _ newPlannerTier: PacePlannerTier,
        presentConsentAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = CompanionManager
            .presentPlannerConsentAlert
    ) -> Bool {
        switch newPlannerTier {
        case .local, .appleFoundationModels:
            setActivePlannerTier(newPlannerTier)
            return true
        case .cliBridge:
            let consentAccepted = requestCloudBridgeConsentIfNeeded(presentConsentAlert: presentConsentAlert)
            guard consentAccepted else {
                return false
            }
            if cloudBridgeMode == .off {
                setCloudBridgeMode(.hybrid)
            }
            setActivePlannerTier(newPlannerTier)
            return true
        case .cliDirect:
            let consentAccepted = requestDirectSpawnConsentIfNeeded(
                upstream: activePlannerTierCLIDirectUpstream, presentConsentAlert: presentConsentAlert
            )
            guard consentAccepted else {
                return false
            }
            setActivePlannerTier(newPlannerTier)
            return true
        case .directAPI:
            setActivePlannerTier(newPlannerTier)
            return true
        }
    }

    /// Persists the `.cliDirect` upstream selection and rebuilds the
    /// planner so the next turn spawns the freshly-picked CLI without an
    /// app restart.
    func setCLIDirectUpstream(_ newUpstream: PaceLocalCLIUpstream) {
        if newUpstream != activePlannerTierCLIDirectUpstream {
            invalidateFastAnswerCredentialPrewarm()
            diagramOverlayController.dismiss()
            imageOverlayController.dismiss()
        }
        activePlannerTierCLIDirectUpstream = newUpstream
        PacePlannerTierStore.saveCLIDirectUpstream(newUpstream)
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
        if newUpstream == .codex {
            prewarmFastAnswerCredentialsIfNeeded()
        } else {
            invalidateFastAnswerCredentialPrewarm()
        }
    }

    func setDirectAPIProvider(_ newProvider: PaceDirectAPIProvider) {
        guard newProvider != directAPIProvider else { return }
        diagramOverlayController.dismiss()
        imageOverlayController.dismiss()
        PacePlannerTierStore.saveDirectAPIProvider(newProvider)
        directAPIProvider = newProvider
        directAPIModelIdentifier = PacePlannerTierStore.loadConfiguration().directAPIModelIdentifier
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
    }

    func setDirectAPIModelIdentifier(_ newModelIdentifier: String) {
        directAPIModelIdentifier = newModelIdentifier
        PacePlannerTierStore.saveDirectAPIModelIdentifier(newModelIdentifier)
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
    }

    func setDirectAPICustomEndpointURLString(_ newCustomEndpointURLString: String) {
        directAPICustomEndpointURLString = newCustomEndpointURLString
        PacePlannerTierStore.saveDirectAPICustomEndpointURL(newCustomEndpointURLString)
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
    }

    func setDirectAPIFallsBackToLocalOnCloudFailure(_ enabled: Bool) {
        directAPIFallsBackToLocalOnCloudFailure = enabled
        PacePlannerTierStore.saveFallsBackToLocalOnCloudFailure(enabled)
    }

    /// Whether the active planner tier is one that leaves the Mac.
    /// Cliff-edge gates: cliBridge requires consent AND a non-off mode;
    /// directAPI requires a stored key. Both checks mirror the factory
    /// so the UI flag stays honest.
    var activePlannerTierIsOffDevice: Bool {
        switch activePlannerTier {
        case .local, .appleFoundationModels:
            return false
        case .cliBridge:
            let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
            return bridgeConfiguration.hasUserAcceptedConsent
                && bridgeConfiguration.mode != .off
        case .cliDirect:
            return canRunForegroundDirectSpawnTurn()
        case .directAPI:
            return PaceKeychainStore.loadAPIKey(for: directAPIProvider) != nil
        }
    }

    /// Verifies that the configured Direct-API provider, model, and key
    /// can complete a single round trip. Builds a one-off
    /// `DirectAPIPlannerClient` rather than reusing the active
    /// `plannerClient` so the test does not disturb live state and is
    /// not blocked by the tier choice. Surfaces the upstream error
    /// verbatim on failure — users debugging API issues need to see the
    /// provider's actual error string to find it in provider docs.
    func runDirectAPITestRoundTrip() async -> Result<String, Error> {
        let configurationAtTestTime = PacePlannerTierStore.loadConfiguration()
        let resolvedEndpointURLString = PacePlannerTierStore
            .resolvedDirectAPIEndpointURLString(for: configurationAtTestTime)

        let validatedEndpointURL: URL
        do {
            validatedEndpointURL = try PaceLocalEndpointGuard.validatedDirectAPIURL(
                from: resolvedEndpointURLString
            )
        } catch {
            return .failure(error)
        }

        let testOnlyPlannerClient = DirectAPIPlannerClient(
            provider: configurationAtTestTime.directAPIProvider,
            endpointURL: validatedEndpointURL,
            modelIdentifier: configurationAtTestTime.directAPIModelIdentifier
        )

        do {
            let (responseText, _) = try await testOnlyPlannerClient.generateResponseStreaming(
                images: [],
                systemPrompt: "You are a connectivity-test echo. Respond with the model identifier you are, in exactly one word.",
                conversationHistory: [],
                userPrompt: "hi",
                onTextChunk: { _ in }
            )
            let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(String(trimmedResponseText.prefix(60)))
        } catch {
            return .failure(error)
        }
    }

    /// Stores the user-pasted API key for the active Direct-API provider
    /// and rebuilds the planner so the new key is picked up on the next
    /// turn. The key value is passed straight to `PaceKeychainStore` and
    /// is never persisted anywhere else.
    @discardableResult
    func saveDirectAPIKey(_ apiKey: String, for provider: PaceDirectAPIProvider) -> Bool {
        let didStore = PaceKeychainStore.storeAPIKey(apiKey, for: provider)
        if didStore {
            screenSuggestionCoordinator.invalidate(clearAnchor: true)
            screenWatchNoteCoordinator.invalidate()
            plannerClient = BuddyPlannerClientFactory.makeDefault()
            PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
        }
        return didStore
    }

    /// Removes the stored API key for the given provider and rebuilds the
    /// planner so the next turn either falls back to local (when no other
    /// key is present) or picks up a different stored provider.
    @discardableResult
    func deleteDirectAPIKey(for provider: PaceDirectAPIProvider) -> Bool {
        let didDelete = PaceKeychainStore.deleteAPIKey(for: provider)
        if didDelete {
            screenSuggestionCoordinator.invalidate(clearAnchor: true)
            screenWatchNoteCoordinator.invalidate()
            plannerClient = BuddyPlannerClientFactory.makeDefault()
            PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
        }
        return didDelete
    }

    /// Snapshot of which providers currently have an API key in Keychain.
    /// Settings UI calls this to show a green checkmark next to a saved
    /// provider.
    func providersWithStoredDirectAPIKeys() -> Set<PaceDirectAPIProvider> {
        return PaceKeychainStore.providersWithStoredKeys()
    }
}

enum PacePlannerBoundary {
    case onDevice, offDevice, hybrid, loopbackEndpoint, unknown

    var label: String {
        switch self {
        case .onDevice: return "On this Mac"
        case .offDevice: return "Off-device"
        case .hybrid: return "Local + off-device"
        case .loopbackEndpoint: return "Local API endpoint"
        case .unknown: return "Boundary unknown"
        }
    }
}
