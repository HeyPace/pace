import Foundation

@MainActor
extension CompanionManager {
    func offerSpokenPowerClarification(_ candidates: [PaceManagedPower], transcript: String, now: Date = Date()) {
        let pending = PacePendingSpokenPowerClarification(candidates: candidates, createdAt: now)
        guard !pending.candidates.isEmpty else { return }
        pendingSpokenPowerClarification = pending
        pendingIntentClarification = nil
        pendingClickTargetClarification = nil
        let question =
            pending.candidates.count == 1 ? "Did you mean \(pending.candidates[0].name)?" : "Which Power did you mean?"
        handleImmediateLocalModeResponse(transcript: transcript, spokenText: question)
        currentTurnHUDState = .clarification(question: question, options: pending.options + ["Cancel"])
        revealRequestFeedback()
    }

    @discardableResult
    func handleSpokenPowerRecoveryIfNeeded(_ transcript: String, now: Date = Date()) async -> Bool {
        let isDirectUserReply =
            activeConversationUserEvent?.origin == .voice || activeConversationUserEvent?.origin == .typed
        if let pending = pendingSpokenPowerClarification, isDirectUserReply {
            switch pending.resolve(transcript, now: now) {
            case .selected(let power):
                pendingSpokenPowerClarification = nil
                await handlePowerCommand(.run(power.identifier), transcript: transcript, expectedPower: power)
                return true
            case .cancelled:
                pendingSpokenPowerClarification = nil
                handleImmediateLocalModeResponse(transcript: transcript, spokenText: "Cancelled. No Power was run.")
                return true
            case .expired:
                pendingSpokenPowerClarification = nil
                handleImmediateLocalModeResponse(
                    transcript: transcript, spokenText: "That Power choice expired. Ask me to run it again.")
                return true
            case .needsSelection:
                offerSpokenPowerClarification(pending.candidates, transcript: transcript, now: pending.createdAt)
                return true
            case .unrelated: pendingSpokenPowerClarification = nil
            }
        }
        guard activeConversationUserEvent?.origin == .voice else {
            pendingSpokenPowerClarification = nil
            return false
        }
        let command = PacePowerCommandParser.parse(
            transcript, isKnownSavedPowerName: managedPowerStore.hasExactSavedPowerName)
        if command == nil,
            PaceAutomationCatalogCommandParser.parse(transcript) != nil
                || PaceShortcutCommandParser.parse(transcript) != nil
                || PaceSkillCommandParser.parse(transcript) != nil
        {
            pendingSpokenPowerClarification = nil
            return false
        }
        let explicitTarget: String?
        if let command {
            guard case .run(let target) = command else { return false }
            guard !managedPowerStore.hasExactSavedPowerName(target) else { return false }
            explicitTarget = target
        } else {
            if PaceFlowCommandParser.parse(transcript, isRecordedFlow: { self.flowStore.load(named: $0) != nil }) != nil
            {
                return false
            }
            let firstWord = PaceSpokenPowerRecovery.normalized(transcript).split(separator: " ").first
            guard firstWord == "run" || firstWord == "power" else { return false }
            explicitTarget = nil
        }
        let turnLease = turnLeaseRegistry.currentLease
        let discovered = await discoverAutomationCatalog(refreshShortcutCatalog: false)
        guard isActiveTurn(turnLease) else { return true }
        if let explicitTarget, (try? managedPowerStore.resolve(explicitTarget, catalog: discovered.catalog)) != nil {
            return false
        }
        switch await PaceAutomationNaturalLanguageMatcher.match(
            transcript: transcript, catalog: discovered.catalog, embedder: nil)
        {
        case .unique(_, .exactInvocationPhrase, _), .ambiguous(_, .exactInvocationPhrase): return false
        default: break
        }
        guard isActiveTurn(turnLease) else { return true }
        let candidates = PaceSpokenPowerRecovery.candidates(
            for: transcript,
            powers: managedPowerStore.list(catalog: discovered.catalog), explicitRunTarget: explicitTarget)
        guard !candidates.isEmpty else { return false }
        offerSpokenPowerClarification(candidates, transcript: transcript, now: now)
        return true
    }

    func resolveSpokenPowerClarification(option: String, expectedIdentifier: UUID?, now: Date = Date()) {
        guard let pending = pendingSpokenPowerClarification, pending.identifier == expectedIdentifier else { return }
        let resolution = pending.resolve(option, now: now)
        guard resolution != .unrelated, resolution != .needsSelection else { return }
        pendingSpokenPowerClarification = nil
        let clarificationThreadRootID = activeConversationUserEvent?.threadRootID
        cancelActiveTurnTasks()
        ttsClient.stopPlayback()
        streamingSentenceTTSPipeline.resetForNewTurn()
        clearLastSpokenReplyState()
        pendingTypedConversationEventIdentifier =
            acceptConversationRequest(option, origin: .typed, threadRootID: clarificationThreadRootID).eventID
        beginConversationRequest(option)
        let turnLease = turnLeaseRegistry.beginTurn()
        actionExecutor.beginUserTurn()
        voiceState = .processing
        currentTurnHUDState = .understanding("Checking the selected Power…")
        currentTurnDispatchTask = Task { [weak self] in
            guard let self, isActiveTurn(turnLease) else { return }
            switch resolution {
            case .selected(let power):
                await handlePowerCommand(.run(power.identifier), transcript: option, expectedPower: power)
            case .cancelled:
                handleImmediateLocalModeResponse(transcript: option, spokenText: "Cancelled. No Power was run.")
            case .expired:
                handleImmediateLocalModeResponse(
                    transcript: option, spokenText: "That Power choice expired. Ask me to run it again.")
            case .needsSelection, .unrelated: break
            }
        }
    }
}
