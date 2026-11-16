import Foundation

@MainActor
extension CompanionManager {
    func bindPowerToolCallbacks() {
        actionExecutor.managedPowerExecutionCheck = { [weak self] in self?.managedPowerExecutionIsAuthorized == true }
        actionExecutor.presentLocalMedia = { [weak self] request in
            guard let self else { return .init(toolName: "present_media", summary: "Media unavailable.", terminalReason: .managedWorkflowUnavailable) }
            let turnLease = self.turnLeaseRegistry.currentLease
            let observation = self.mediaOverlayController.present(request)
            let presentationGeneration = self.mediaOverlayController.presentationGeneration
            self.mediaOverlayController.onUserDismiss = { [weak self] dismissedGeneration in
                guard let self, dismissedGeneration == presentationGeneration,
                      self.turnLeaseRegistry.isCurrent(turnLease) else { return }
                self.cancelCurrentTurnFromPanel()
            }
            return observation
        }
        actionExecutor.speakLocalText = { [weak self] request in
            let text = request.text
            let displayedText = request.englishSubtitle ?? text
            guard let self, self.managedPowerExecutionIsAuthorized else {
                return .init(toolName: "speak", summary: "Speech stopped: power authorization changed.", terminalReason: .managedWorkflowUnavailable)
            }
            let turnLease = self.turnLeaseRegistry.currentLease
            guard !self.streamingSentenceTTSPipeline.isMutedForCurrentTurn, !self.chatSession.isChatTTSMuted else {
                return .init(toolName: "speak", summary: "Speech is muted; no speech was played.", terminalReason: .managedWorkflowUnavailable)
            }
            guard self.ttsClient.supportsUtteranceCompletion else {
                return .init(toolName: "speak", summary: "This speech backend cannot verify playback completion.", terminalReason: .managedWorkflowUnavailable)
            }
            do {
                try await self.ttsClient.speakUtterance(request, onStarted: { [weak self] in
                    guard let self, self.isActiveTurn(turnLease) else { return }
                    let userContext = self.hasRecordedCurrentTurnSpeechUserContext ? "" : (self.activeConversationUserEvent?.text ?? "")
                    let eventIdentifier = self.recordAssistantNarration(displayedText, origin: .assistant,
                        turnIdentifier: self.activeConversationUserEvent?.eventID, plannerContext: userContext, speechRequest: request)
                    self.hasRecordedCurrentTurnSpeechUserContext = true
                    if self.recordsDerivedConversationMemory {
                        self.recordUnifiedMemoryTurn(userTranscript: userContext, assistantResponse: displayedText,
                            turnId: eventIdentifier, recordedAt: Date())
                    }
                    self.noteLastSpokenReply(text, profile: request.profile)
                    self.lastSpokenReplyRequest = request
                    self.responseOverlayManager.updateStreamingText(displayedText)
                })
                guard self.isActiveTurn(turnLease) else { throw CancellationError() }
                return .init(toolName: "speak", summary: "Spoke the requested text locally.")
            } catch {
                return .init(toolName: "speak", summary: "Local speech did not complete: \(error.localizedDescription)", terminalReason: .managedWorkflowUnavailable)
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
        guard let power = managedPowerStore.list(catalog: catalog).first(where: { $0.reference == entry.reference }) else { return false }
        if let stateError = power.managementStateError {
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: stateError, shouldRecordConversationTurn: true)
            return false
        }
        guard power.isEnabled else {
            handleImmediateLocalModeResponse(transcript: transcript,
                spokenText: "\(power.name) is disabled. Say enable power \(power.identifier) first.", shouldRecordConversationTurn: true)
            return false
        }
        if power.isUserOwned {
            activeManagedPower = power
        } else if power.isManagedUserArtifact {
            handleImmediateLocalModeResponse(transcript: transcript,
                spokenText: "That saved power's artifact is unavailable or unsafe to access, so I didn't run it.", shouldRecordConversationTurn: true)
            return false
        }
        return true
    }

    func handlePowerCommand(_ command: PacePowerCommand, transcript: String) async {
        if command == .dismissMedia {
            mediaOverlayController.dismiss(cancelOwnedRun: true)
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: "media stopped.", shouldRecordConversationTurn: true)
            return
        }
        if case .importMedia(let path, let identifier) = command {
            do {
                try localMediaCatalog.importAsset(from: URL(fileURLWithPath: path), identifier: identifier)
                PaceAPIAuditLog.shared.record(subsystem: "power-management", operation: "import_media", target: identifier, durationMilliseconds: 0, outcome: "ok")
                handleImmediateLocalModeResponse(transcript: transcript,
                    spokenText: "Imported local media \(identifier). Use that asset ID when creating a power.", shouldRecordConversationTurn: true)
            } catch {
                handleImmediateLocalModeResponse(transcript: transcript, spokenText: error.localizedDescription, shouldRecordConversationTurn: true)
            }
            return
        }
        if case .create(let description) = command {
            handleCreateReusableWork(rawDescription: description, transcript: transcript,
                setupSpokenText: "let me structure and validate that power.")
            return
        }
        let turnLease = turnLeaseRegistry.currentLease
        let discovered = await discoverAutomationCatalog()
        guard isActiveTurn(turnLease) else { return }
        let store = managedPowerStore
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
                let customNames = custom.prefix(8).map { $0.name + ($0.managementStateError != nil ? " (settings unreadable)" : ($0.isEnabled ? "" : " (disabled)")) }.joined(separator: ", ")
                let installedNames = installed.prefix(8).map(\.name).joined(separator: ", ")
                let countSummary = "\(builtIn.count) built-in powers, \(custom.count) custom \(custom.count == 1 ? "power" : "powers"), \(installed.count) installed \(installed.count == 1 ? "workflow" : "workflows")."
                spokenSummary = countSummary
                feedback = countSummary + "\nBuilt-in powers: \(builtInNames)."
                    + (custom.isEmpty ? " No saved custom powers yet." : " Custom powers: \(customNames)\(custom.count > 8 ? ", and \(custom.count - 8) more" : "").")
                    + (installed.isEmpty ? "" : " Other installed workflows: \(installedNames)\(installed.count > 8 ? ", and \(installed.count - 8) more" : "").")
                    + " Say show power followed by an exact name for its steps and controls."
            case .show(let target):
                let power = try store.resolve(target, catalog: discovered.catalog)
                let stateSummary = power.managementStateError ?? "\(power.name) is \(power.isEnabled ? "enabled" : "disabled"); its steps are in chat."
                spokenSummary = stateSummary
                feedback = stateSummary + "\n\(power.name) [\(power.identifier)]. \(try store.contentSummary(power))\nAvailable controls: \(power.capabilities)."
            case .update(let target, let description):
                let power = try store.resolve(target, catalog: discovered.catalog)
                _ = try store.validateCurrent(power)
                handleCreateReusableWork(rawDescription: description, transcript: transcript,
                    setupSpokenText: "let me validate that update.", replacingPower: power)
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
                guard let reference = power.reference,
                      let entry = discovered.catalog.entries.first(where: { $0.reference == reference }) else {
                    throw PaceManagedPowerError.protected
                }
                dispatchAutomationCatalogEntry(entry, typedDefinitions: discovered.typedDefinitions,
                    programs: discovered.programs, recordedFlows: discovered.recordedFlows, skills: discovered.skills,
                    transcript: transcript)
                return
            case .create, .dismissMedia, .importMedia: return
            }
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: feedback, shouldRecordConversationTurn: true,
                spokenSummary: spokenSummary)
        } catch {
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: error.localizedDescription, shouldRecordConversationTurn: true)
        }
    }

    func commitPowerDraft(_ draft: PacePowerDraft, replacing power: PaceManagedPower?, transcript: String,
                          turnLease: PaceTurnLease) async {
        let discovered = await discoverAutomationCatalog()
        guard isActiveTurn(turnLease) else { return }
        do {
            let name = try managedPowerStore.commit(draft, replacing: power, catalog: discovered.catalog)
            handleImmediateLocalModeResponse(transcript: transcript,
                spokenText: "\(power == nil ? "Saved" : "Updated") \(name). Say run power \(name) to use it.", shouldRecordConversationTurn: true)
        } catch {
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: error.localizedDescription, shouldRecordConversationTurn: true)
        }
    }
}
