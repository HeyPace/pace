import AppKit
import Foundation

@MainActor
extension CompanionManager {
    func bindPowerToolCallbacks() {
        buddyDictationManager.additionalContextualPhrases = { [weak self] in
            self?.managedPowerStore.savedPowerNames() ?? []
        }
        actionExecutor.managedPowerExecutionCheck = { [weak self] in self?.managedPowerExecutionIsAuthorized == true }
        actionExecutor.presentLocalMedia = { [weak self] request in
            guard let self else {
                return .init(
                    toolName: "present_media", summary: "Media unavailable.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            let turnLease = self.turnLeaseRegistry.currentLease
            let dismissOwnedTurn: (UUID) -> Void = { [weak self] _ in
                guard let self, self.turnLeaseRegistry.isCurrent(turnLease) else { return }
                self.cancelCurrentTurnFromPanel()
            }
            if let card = request.card {
                let presentedPower = self.activeManagedPower
                let userEventIdentifier = self.activeConversationUserEvent?.eventID
                var recordedPageIndices: Set<Int> = [0]
                var recordedChoiceEventIdentifiers: [String: (selection: String, feedback: String)] = [:]
                let isAuthorized: () -> Bool = { [weak self] in
                    guard let self, self.turnLeaseRegistry.isCurrent(turnLease) else { return false }
                    guard let presentedPower else { return true }
                    return self.managedPowerStore.isEnabled(presentedPower.identifier)
                        && (try? self.managedPowerStore.validateCurrent(presentedPower)) != nil
                }
                let observation = await self.mediaOverlayController.presentCard(
                    request, mayPresent: isAuthorized,
                    authorizeInteraction: { [weak self] interaction in
                        guard let self, isAuthorized() else { return false }
                        switch interaction {
                        case .select(let pageIndex, let choiceIndex):
                            guard card.pages.indices.contains(pageIndex),
                                card.pages[pageIndex].choices.indices.contains(choiceIndex)
                            else { return false }
                            let page = card.pages[pageIndex]
                            let choice = page.choices[choiceIndex]
                            let choiceKey = "\(pageIndex):\(choiceIndex)"
                            let eventIdentifiers =
                                recordedChoiceEventIdentifiers[choiceKey]
                                ?? (selection: UUID().uuidString, feedback: UUID().uuidString)
                            recordedChoiceEventIdentifiers[choiceKey] = eventIdentifiers
                            self.recordAssistantNarration(
                                "Selected “" + choice.label + "” in “" + page.title + "” (" + card.title + ").",
                                origin: .progress, eventIdentifier: eventIdentifiers.selection,
                                turnIdentifier: userEventIdentifier, recordsDerivedMemory: false)
                            self.recordAssistantNarration(
                                choice.feedback, eventIdentifier: eventIdentifiers.feedback,
                                turnIdentifier: userEventIdentifier, recordsDerivedMemory: false)
                            self.chatSession.orderMessagesChronologically()
                        case .navigate(let pageIndex):
                            guard card.pages.indices.contains(pageIndex) else { return false }
                            if recordedPageIndices.insert(pageIndex).inserted {
                                self.recordAssistantNarration(
                                    card.pages[pageIndex].transcript,
                                    turnIdentifier: userEventIdentifier, recordsDerivedMemory: false)
                            }
                        }
                        PaceAPIAuditLog.shared.record(
                            subsystem: "power-ui", operation: "card_interaction",
                            target: presentedPower?.identifier ?? "interactive-card", durationMilliseconds: 0,
                            outcome: "ok",
                            detail: String(describing: interaction))
                        return true
                    }, onDismiss: dismissOwnedTurn)
                if observation.terminalReason == nil {
                    self.recordAssistantNarration(
                        card.title + "\n" + card.pages[0].transcript,
                        turnIdentifier: userEventIdentifier, recordsDerivedMemory: false)
                }
                return observation
            }
            if case .generatedSVG = request.source {
                return await self.mediaOverlayController.presentGenerated(
                    request,
                    mayPresent: { [weak self] in
                        guard let self else { return false }
                        return self.isActiveTurn(turnLease) && self.managedPowerExecutionIsAuthorized
                    }, onDismiss: dismissOwnedTurn)
            }
            return self.mediaOverlayController.present(request, onDismiss: dismissOwnedTurn)
        }
        actionExecutor.speakLocalText = { [weak self] request in
            let text = request.text
            let displayedText = request.englishSubtitle ?? text
            guard let self, self.managedPowerExecutionIsAuthorized else {
                return .init(
                    toolName: "speak", summary: "Speech stopped: power authorization changed.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            let turnLease = self.turnLeaseRegistry.currentLease
            guard !self.streamingSentenceTTSPipeline.isMutedForCurrentTurn, !self.chatSession.isChatTTSMuted else {
                return .init(
                    toolName: "speak", summary: "Speech is muted; no speech was played.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            guard self.ttsClient.supportsUtteranceCompletion else {
                return .init(
                    toolName: "speak", summary: "This speech backend cannot verify playback completion.",
                    terminalReason: .managedWorkflowUnavailable)
            }
            do {
                try await self.ttsClient.speakUtterance(
                    request,
                    onStarted: { [weak self] in
                        guard let self, self.isActiveTurn(turnLease) else { return }
                        let userContext =
                            self.hasRecordedCurrentTurnSpeechUserContext
                            ? "" : (self.activeConversationUserEvent?.text ?? "")
                        let eventIdentifier = self.recordAssistantNarration(
                            displayedText, origin: .assistant,
                            turnIdentifier: self.activeConversationUserEvent?.eventID, plannerContext: userContext,
                            speechRequest: request)
                        self.hasRecordedCurrentTurnSpeechUserContext = true
                        if self.recordsDerivedConversationMemory, self.activeConversationUserEvent?.threadRootID == nil
                        {
                            self.recordUnifiedMemoryTurn(
                                userTranscript: userContext, assistantResponse: displayedText,
                                turnId: eventIdentifier, recordedAt: Date())
                        }
                        self.noteLastSpokenReply(text, profile: request.profile)
                        self.lastSpokenReplyRequest = request
                        self.responseOverlayManager.updateStreamingText(displayedText)
                    })
                guard self.isActiveTurn(turnLease) else { throw CancellationError() }
                return .init(toolName: "speak", summary: "Spoke the requested text locally.")
            } catch {
                return .init(
                    toolName: "speak", summary: "Local speech did not complete: \(error.localizedDescription)",
                    terminalReason: .managedWorkflowUnavailable)
            }
        }
    }

    var managedPowerExecutionIsAuthorized: Bool {
        guard let activeManagedPower else { return true }
        let store = managedPowerStore
        return store.isEnabled(activeManagedPower.identifier) && (try? store.validateCurrent(activeManagedPower)) != nil
    }

    @discardableResult
    func authorizeManagedPower(_ entry: PaceAutomationCatalogEntry, transcript: String) -> Bool {
        let catalog = PaceAutomationCatalog(entries: [entry])
        guard let power = managedPowerStore.list(catalog: catalog).first(where: { $0.reference == entry.reference })
        else { return false }
        if let stateError = power.managementStateError {
            handleImmediateLocalModeResponse(
                transcript: transcript, spokenText: stateError, shouldRecordConversationTurn: true)
            return false
        }
        guard power.isEnabled else {
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "\(power.name) is disabled. Say enable power \(power.identifier) first.",
                shouldRecordConversationTurn: true)
            return false
        }
        if power.isUserOwned {
            activeManagedPower = power
        } else if power.isManagedUserArtifact {
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "That saved power's artifact is unavailable or unsafe to access, so I didn't run it.",
                shouldRecordConversationTurn: true)
            return false
        }
        return true
    }

    func handlePowerCommand(_ command: PacePowerCommand, transcript: String, expectedPower: PaceManagedPower? = nil)
        async
    {
        pendingPowerDescription = nil
        if command == .dismissMedia {
            mediaOverlayController.dismiss(cancelOwnedRun: true)
            handleImmediateLocalModeResponse(
                transcript: transcript, spokenText: "media stopped.", shouldRecordConversationTurn: true)
            return
        }
        if case .importMedia(let path, let identifier) = command {
            do {
                try localMediaCatalog.importAsset(from: URL(fileURLWithPath: path), identifier: identifier)
                PaceAPIAuditLog.shared.record(
                    subsystem: "power-management", operation: "import_media", target: identifier,
                    durationMilliseconds: 0, outcome: "ok")
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "Imported local media \(identifier). Use that asset ID when creating a power.",
                    shouldRecordConversationTurn: true)
            } catch {
                handleImmediateLocalModeResponse(
                    transcript: transcript, spokenText: error.localizedDescription, shouldRecordConversationTurn: true)
            }
            return
        }
        if case .add(let description) = command {
            guard !description.isEmpty else {
                pendingPowerDescription = .init(requestedAt: Date())
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText:
                        "What should your Power do? For example, say: Call it Hello and greet me with a GIF. It can show interactive lessons and quizzes, compute, speak, draw animated SVG, and show saved media.",
                    shouldRecordConversationTurn: true)
                return
            }
            handleCreateReusableWork(
                rawDescription: description, transcript: transcript,
                setupSpokenText: "let me write and test that power.", generateJavaScript: true)
            return
        }
        if case .create(let description) = command {
            handleCreateReusableWork(
                rawDescription: description, transcript: transcript,
                setupSpokenText: "let me structure and validate that power.")
            return
        }
        let turnLease = turnLeaseRegistry.currentLease
        let store = managedPowerStore
        let isSavedPowerRun: Bool
        if case .run(let target) = command {
            isSavedPowerRun = store.hasExactSavedPowerName(target)
        } else {
            isSavedPowerRun = false
        }
        let discovered = await discoverAutomationCatalog(
            refreshShortcutCatalog: expectedPower == nil && !isSavedPowerRun)
        guard isActiveTurn(turnLease) else { return }
        do {
            let feedback: String
            var spokenSummary: String? = nil
            switch command {
            case .list:
                let powers = store.list(catalog: discovered.catalog)
                let builtIn = powers.filter { $0.reference == nil }
                let builtInNames = builtIn.map(\.name).joined(separator: ", ")
                let custom = powers.filter(\.isUserOwned)
                let installed = powers.filter { $0.reference != nil && !$0.isUserOwned }
                let customNames = custom.prefix(8).map {
                    $0.name
                        + ($0.managementStateError != nil
                            ? " (settings unreadable)" : ($0.isEnabled ? "" : " (disabled)"))
                }.joined(separator: ", ")
                let installedNames = installed.prefix(8).map(\.name).joined(separator: ", ")
                let countSummary =
                    "\(builtIn.count) built-in powers, \(custom.count) saved \(custom.count == 1 ? "power" : "powers"), \(installed.count) installed \(installed.count == 1 ? "workflow" : "workflows")."
                spokenSummary = countSummary
                feedback =
                    countSummary + "\nBuilt-in powers: \(builtInNames)."
                    + (custom.isEmpty
                        ? " No saved powers yet."
                        : " Saved powers: \(customNames)\(custom.count > 8 ? ", and \(custom.count - 8) more" : "").")
                    + (installed.isEmpty
                        ? ""
                        : " Installed workflows: \(installedNames)\(installed.count > 8 ? ", and \(installed.count - 8) more" : "").")
                    + " Say show power followed by an exact name for its steps and controls."
            case .show(let target):
                let power = try store.resolve(target, catalog: discovered.catalog)
                let stateSummary =
                    power.managementStateError
                    ?? "\(power.name) is \(power.isEnabled ? "enabled" : "disabled"); its steps are in chat."
                spokenSummary = stateSummary
                feedback =
                    stateSummary
                    + "\n\(power.name) [\(power.identifier)]. \(try store.contentSummary(power))\nAvailable controls: \(power.capabilities)."
            case .update(let target, let description):
                let power = try store.resolve(target, catalog: discovered.catalog)
                _ = try store.validateCurrent(power)
                let usesJavaScript: Bool
                if case .program = power.reference {
                    let data = try Data(contentsOf: store.validateCurrent(power))
                    usesJavaScript = try JSONDecoder().decode(PaceProgramDefinition.self, from: data).nodes
                        .containsJavaScript
                } else {
                    usesJavaScript = false
                }
                handleCreateReusableWork(
                    rawDescription: description, transcript: transcript,
                    setupSpokenText: "let me validate that update.", replacingPower: power,
                    generateJavaScript: usesJavaScript)
                return
            case .setEnabled(let target, let enabled):
                let power = try store.resolve(target, catalog: discovered.catalog)
                try store.setEnabled(enabled, power: power)
                feedback = "\(power.name) is now \(enabled ? "enabled" : "disabled")."
            case .remove(let target):
                let power = try store.resolve(target, catalog: discovered.catalog)
                _ = try store.archive(power)
                feedback = "Archived \(power.name). Its history and assets are preserved."
            case .run(let target):
                let power = try store.resolve(target, catalog: discovered.catalog)
                if let expectedPower {
                    guard power == expectedPower, power.isEnabled, power.managementStateError == nil else {
                        throw PaceManagedPowerError.changed
                    }
                    _ = try store.validateCurrent(expectedPower)
                }
                guard let reference = power.reference,
                    let entry = discovered.catalog.entries.first(where: { $0.reference == reference })
                else {
                    throw PaceManagedPowerError.protected
                }
                dispatchAutomationCatalogEntry(
                    entry, typedDefinitions: discovered.typedDefinitions,
                    programs: discovered.programs, recordedFlows: discovered.recordedFlows, skills: discovered.skills,
                    transcript: transcript)
                return
            case .add, .create, .dismissMedia, .importMedia: return
            }
            handleImmediateLocalModeResponse(
                transcript: transcript, spokenText: feedback, shouldRecordConversationTurn: true,
                spokenSummary: spokenSummary)
        } catch {
            if expectedPower == nil, activeConversationUserEvent?.origin == .voice,
                case .run(let target) = command, let powerError = error as? PaceManagedPowerError,
                case .missing = powerError
            {
                let candidates = PaceSpokenPowerRecovery.candidates(
                    for: transcript,
                    powers: store.list(catalog: discovered.catalog), explicitRunTarget: target)
                if !candidates.isEmpty {
                    offerSpokenPowerClarification(candidates, transcript: transcript)
                    return
                }
            }
            handleImmediateLocalModeResponse(
                transcript: transcript, spokenText: error.localizedDescription, shouldRecordConversationTurn: true)
        }
    }

    func commitPowerDraft(
        _ draft: PacePowerDraft, replacing power: PaceManagedPower?, transcript: String,
        turnLease: PaceTurnLease
    ) async {
        do {
            var previewFeedback = ""
            if case .program(let program) = draft, program.nodes.containsJavaScript {
                switch try await PaceJavaScriptPowerRuntime.compile(program, context: PaceProgramContext.current()) {
                case .executionPlan(let plan): try validateJavaScriptPowerMedia(plan)
                case .noActionsMatched: previewFeedback = " Its test produced no actions in the current context."
                }
            }
            let discovered = await discoverAutomationCatalog()
            guard isActiveTurn(turnLease) else { return }
            try Task.checkCancellation()
            let name = try managedPowerStore.commit(draft, replacing: power, catalog: discovered.catalog)
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText:
                    "\(power == nil ? "Saved" : "Updated") \(name). Say run power \(name) to use it.\(draft.javaScriptCapabilitySummary)\(previewFeedback)",
                shouldRecordConversationTurn: true)
            await currentResponseTask?.value
        } catch {
            guard isActiveTurn(turnLease) else { return }
            handleImmediateLocalModeResponse(
                transcript: transcript, spokenText: error.localizedDescription, shouldRecordConversationTurn: true)
            await currentResponseTask?.value
        }
    }

    @discardableResult
    func handlePendingPowerDescription(_ transcript: String, now: Date = Date()) -> Bool {
        guard let pendingPowerDescription else { return false }
        self.pendingPowerDescription = nil
        switch pendingPowerDescription.resolve(transcript, now: now) {
        case .description(let description):
            handleCreateReusableWork(
                rawDescription: description, transcript: transcript,
                setupSpokenText: "let me write and test that power.", generateJavaScript: true)
            return true
        case .cancelled:
            handleImmediateLocalModeResponse(
                transcript: transcript, spokenText: "Cancelled adding the Power.", shouldRecordConversationTurn: true)
            return true
        case .unrelated: return false
        }
    }

    func validateJavaScriptPowerMedia(_ plan: PaceActionExecutionPlan, assetIsValid: ((String) -> Bool)? = nil) throws {
        let assetIsValid =
            assetIsValid ?? { identifier in
                guard let url = self.localMediaCatalog.resourceURL(for: identifier),
                    let image = NSImage(contentsOf: url)
                else { return false }
                return image.isValid
            }
        for action in plan.flattenedActions {
            if case .presentMedia(let request) = action, case .catalogAsset(let identifier) = request.source,
                !assetIsValid(identifier)
            {
                throw PaceJavaScriptPowerError.invalid("the local media asset is unavailable")
            }
        }
    }
}

nonisolated extension PacePowerDraft {
    var javaScriptCapabilitySummary: String {
        if case .program(let program) = self, program.nodes.containsJavaScript {
            return " It runs locally and can show interactive cards, speak, draw animated SVG, or show saved media."
        }
        return ""
    }
}
