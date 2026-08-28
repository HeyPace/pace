//
//  CompanionManager+LocalMemoryCommands.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition):
//  voice-command handlers for remember-site, local memory, reusable
//  automations, and MCP prompt augmentation.
//

import AppKit
import Foundation

nonisolated struct PaceDiscoveredAutomationCatalog {
    let catalog: PaceAutomationCatalog
    let typedDefinitions: [PaceAutomationDefinition]
    let programs: [PaceProgramDefinition]
    let recordedFlows: [PaceRecordedFlow]
    let skills: [PaceSkillFile]
}

@MainActor
extension CompanionManager {

    // MARK: - Local memory & fast-path commands

    func handleRememberSiteCommand(
        _ command: PaceRememberSiteCommand,
        transcript: String
    ) {
        let spokenText: String
        switch command {
        case .forget(let name):
            let didForget = PaceNamedDestinationStore.shared.forget(displayName: name)
            spokenText =
                didForget
                ? "forgotten."
                : "i don't have a saved site called \(name)."
        case .remember(let requestedName):
            if let captured = PaceBrowserURLReader.currentTab() {
                let displayName =
                    requestedName
                    ?? PaceBrowserURLReader.defaultName(forURL: captured.url)
                PaceNamedDestinationStore.shared.save(
                    displayName: displayName,
                    url: captured.url
                )
                spokenText = "got it — i'll remember \(displayName)."
            } else {
                // Frontmost app isn't a scriptable browser, or the read failed.
                spokenText =
                    "i couldn't read this page's address — make sure the site is open in your browser and try again."
            }
        }

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled else { return }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
            currentTurnHUDState = .done("done")
        }
    }

    func handleLocalMemoryCommand(_ command: PaceLocalMemoryCommand) {
        let spokenText: String
        switch command {
        case .set(let key, let value):
            PaceLocalMemoryStore.setString(value, for: key)
            spokenText = "remembered \(value)."
        case .forget(let key):
            PaceLocalMemoryStore.setString(nil, for: key)
            spokenText = "forgot that preference."
        }

        localMemorySummary = PaceLocalMemoryStore.summaryText
        localRetriever.refreshPreferenceDocuments()
        refreshLocalRetrievalPublishedState()
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled else { return }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    func handleAlwaysListeningCommand(_ command: PaceAlwaysListeningCommand, transcript: String) {
        let spokenText: String
        switch command {
        case .start:
            setAlwaysListeningEnabled(true)
            spokenText = "always listening is on."
        case .stop:
            setAlwaysListeningEnabled(false)
            spokenText = "always listening is off."
        }
        handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
    }

    func handleAutomationCatalogCommand(
        _ command: PaceAutomationCatalogCommand,
        transcript: String
    ) async {
        let discoveredCatalog = await discoverAutomationCatalog()
        guard !Task.isCancelled else { return }
        let automationCatalog = discoveredCatalog.catalog

        switch command {
        case .list:
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: automationCatalog.spokenListResponse(),
                shouldRecordConversationTurn: false
            )

        case .run(let requestedName):
            switch automationCatalog.exactMatch(for: requestedName) {
            case .notFound:
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i don't see an automation called \(requestedName).",
                    shouldRecordConversationTurn: false
                )

            case .collision(let matchingEntries):
                let conflictingSources = Set(matchingEntries.map { $0.source.displayName })
                    .sorted()
                    .joined(separator: ", ")
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText:
                        "\(requestedName) matches multiple entries from \(conflictingSources). say the source-specific command instead.",
                    shouldRecordConversationTurn: false
                )

            case .unique(let matchingEntry):
                dispatchAutomationCatalogEntry(
                    matchingEntry,
                    typedDefinitions: discoveredCatalog.typedDefinitions,
                    programs: discoveredCatalog.programs,
                    recordedFlows: discoveredCatalog.recordedFlows,
                    skills: discoveredCatalog.skills,
                    transcript: transcript
                )
            }
        }
    }

    /// Attempts local natural-language selection for a completed transcript.
    /// Returning false means "keep routing"; weak, ambiguous, and failed
    /// matches never consume the user's turn.
    func dispatchNaturalLanguageAutomationIfConfident(transcript: String) async -> Bool {
        // Information-seeking questions belong to the answer router. Skip
        // even catalog discovery here: loading Shortcuts and reusable-work
        // metadata added more than a second before basic factual answers.
        // Explicit catalog commands are already handled by the parser above.
        guard
            PaceAutomationNaturalLanguageMatcher.shouldAttemptImplicitCatalogMatch(
                transcript: transcript
            )
        else {
            return false
        }

        let discoveredCatalog = await discoverAutomationCatalog(
            refreshShortcutCatalog: false
        )
        guard !Task.isCancelled else { return false }
        let match = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: transcript,
            catalog: discoveredCatalog.catalog,
            embedder: PaceChainedTextEmbeddingClient.makeAutomationRoutingDefault()
        )
        guard !Task.isCancelled else { return false }

        let matchingEntry: PaceAutomationCatalogEntry
        let evidenceDescription: String
        let scoreDescription: String
        switch match {
        case .unique(let uniqueEntry, let evidence, let score):
            matchingEntry = uniqueEntry
            evidenceDescription = String(describing: evidence)
            scoreDescription = String(format: "%.3f", score)

        case .ambiguous(let ambiguousEntries, let ambiguousEvidence):
            let names = ambiguousEntries.map(\.name).joined(separator: ", ")
            print("⚙️ Natural automation match ambiguous: \(names)")
            if ambiguousEvidence == .exactInvocationPhrase {
                let choices = ambiguousEntries.prefix(3).map(\.name).joined(separator: ", ")
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "which automation did you mean: \(choices)?",
                    shouldRecordConversationTurn: false
                )
                return true
            }
            let resolution = await PaceAutomationIntentResolver.resolve(
                transcript: transcript,
                ambiguousEntries: ambiguousEntries,
                catalog: discoveredCatalog.catalog
            )
            guard !Task.isCancelled else { return false }
            switch resolution {
            case .run(let resolvedEntry):
                matchingEntry = resolvedEntry
                evidenceDescription = "localLanguageModel"
                scoreDescription = "resolved"
            case .needsClarification:
                let choices = ambiguousEntries.prefix(3).map(\.name).joined(separator: ", ")
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "which automation did you mean: \(choices)?",
                    shouldRecordConversationTurn: false
                )
                return true
            case .noMatch, .unavailable:
                return false
            }

        case .noMatch:
            return false
        }

        print(
            "⚙️ Natural automation match: \(matchingEntry.name) "
                + "evidence=\(evidenceDescription) score=\(scoreDescription)"
        )
        dispatchAutomationCatalogEntry(
            matchingEntry,
            typedDefinitions: discoveredCatalog.typedDefinitions,
            programs: discoveredCatalog.programs,
            recordedFlows: discoveredCatalog.recordedFlows,
            skills: discoveredCatalog.skills,
            transcript: transcript
        )
        return true
    }

    func discoverAutomationCatalog(
        refreshShortcutCatalog: Bool = true
    ) async -> PaceDiscoveredAutomationCatalog {
        let bundledDefinitions = PaceAutomationDefinitionLibrary.loadBundledDefinitions()
        let userDefinitions = PaceUserAutomationStore().listValidDefinitions()
        let typedDefinitions = bundledDefinitions + userDefinitions
        let programs = PaceUserProgramStore().listValidPrograms()
        let recordedFlows = flowStore.listAll()
        let skills = PaceSkillLoader.loadAllSkills()
        let shortcutNames: [String]
        if refreshShortcutCatalog {
            let shortcutCatalogDiscoveryResult = await PaceShortcutsAutomationProvider.shared.catalog()
            switch shortcutCatalogDiscoveryResult {
            case .success(let shortcutCatalog):
                shortcutNames = shortcutCatalog.shortcutNames
            case .failure(let failureDescription):
                print("⚠️ Shortcuts catalog discovery failed: \(failureDescription)")
                shortcutNames = []
            }
        } else if let cachedShortcutCatalog = PaceShortcutsAutomationProvider.shared
            .cachedCatalogIfFresh()
        {
            shortcutNames = cachedShortcutCatalog.shortcutNames
        } else {
            shortcutNames = []
            // Warm discovery for a later turn without adding up to the CLI's
            // ten-second timeout to this latency-sensitive transcript.
            Task { @MainActor in
                _ = await PaceShortcutsAutomationProvider.shared.catalog()
            }
        }

        return PaceDiscoveredAutomationCatalog(
            catalog: PaceAutomationCatalog(
                typedDefinitions: typedDefinitions,
                recordedFlows: recordedFlows,
                skills: skills,
                shortcutNames: shortcutNames,
                programs: programs
            ),
            typedDefinitions: typedDefinitions,
            programs: programs,
            recordedFlows: recordedFlows,
            skills: skills
        )
    }

    private func dispatchAutomationCatalogEntry(
        _ catalogEntry: PaceAutomationCatalogEntry,
        typedDefinitions: [PaceAutomationDefinition],
        programs: [PaceProgramDefinition],
        recordedFlows: [PaceRecordedFlow],
        skills: [PaceSkillFile],
        transcript: String
    ) {
        switch catalogEntry.reference {
        case .typedDefinition(let identifier):
            guard let definition = typedDefinitions.first(where: { $0.identifier == identifier }) else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "that automation is no longer available.",
                    shouldRecordConversationTurn: false
                )
                return
            }
            if let missingPreferenceKey =
                PaceAutomationDefinitionLibrary
                .missingRequiredPreference(for: definition)
            {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i need \(missingPreferenceKey) set first.",
                    shouldRecordConversationTurn: false
                )
                return
            }
            do {
                let executionPlan = try PaceAutomationCompiler.compile(definition)
                handleFastLocalActionPath(
                    transcript: transcript,
                    fastActionParseResult: PaceFastActionParseResult(
                        spokenText: "running \(definition.name).",
                        executionPlan: executionPlan
                    ),
                    shouldRecordConversationTurn: false
                )
            } catch {
                print("⚠️ Typed automation compilation failed for \(identifier): \(error)")
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i couldn't validate that automation, so i didn't run it.",
                    shouldRecordConversationTurn: false
                )
            }

        case .program(let identifier):
            guard
                let program = PaceProgramLibrary.resolve(
                    identifier: identifier,
                    in: programs
                )
            else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "that programmed automation is no longer available.",
                    shouldRecordConversationTurn: false
                )
                return
            }
            if let missingPreferenceKey = PaceProgramLibrary.missingRequiredPreference(
                for: program
            ) {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i need \(missingPreferenceKey) set first.",
                    shouldRecordConversationTurn: false
                )
                return
            }
            do {
                switch try PaceProgramCompiler.compile(
                    program,
                    context: PaceProgramContext.current()
                ) {
                case .executionPlan(let executionPlan):
                    handleFastLocalActionPath(
                        transcript: transcript,
                        fastActionParseResult: PaceFastActionParseResult(
                            spokenText: "running \(program.name).",
                            executionPlan: executionPlan
                        ),
                        shouldRecordConversationTurn: false
                    )
                case .noActionsMatched:
                    handleImmediateLocalModeResponse(
                        transcript: transcript,
                        spokenText: "\(program.name) didn't have any actions for the current conditions.",
                        shouldRecordConversationTurn: false
                    )
                }
            } catch {
                print("⚠️ Program compilation failed for \(identifier): \(error)")
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i couldn't validate that programmed automation, so i didn't run it.",
                    shouldRecordConversationTurn: false
                )
            }

        case .recordedFlow(let name):
            guard let storedFlow = recordedFlows.first(where: { $0.name == name }) else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "that recorded flow is no longer available.",
                    shouldRecordConversationTurn: false
                )
                return
            }
            flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "replaying \(storedFlow.name) now.",
                shouldRecordConversationTurn: false
            )
            beginFlowReplay(storedFlow)

        case .skill(let slug, let name):
            guard skills.contains(where: { $0.slug == slug }) else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "that skill is no longer available.",
                    shouldRecordConversationTurn: false
                )
                return
            }
            handleSkillCommand(.run(slug: slug, name: name), transcript: transcript)

        case .shortcut(let name):
            handleFastLocalActionPath(
                transcript: transcript,
                fastActionParseResult: PaceShortcutCommandParser.fastActionParseResult(for: name),
                shouldRecordConversationTurn: false
            )
        }
    }

    func handleShortcutAutomationCommand(
        _ command: PaceShortcutCommand,
        transcript: String
    ) async {
        let catalogDiscoveryResult = await PaceShortcutsAutomationProvider.shared.catalog()
        guard !Task.isCancelled else { return }

        guard case .success(let shortcutCatalog) = catalogDiscoveryResult else {
            if case .failure(let failureDescription) = catalogDiscoveryResult {
                print("⚠️ Shortcuts catalog discovery failed: \(failureDescription)")
            }
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "i couldn't read your Shortcuts library.",
                shouldRecordConversationTurn: false
            )
            return
        }

        switch command {
        case .list:
            let spokenText = shortcutCatalogListResponse(shortcutCatalog)
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: spokenText,
                shouldRecordConversationTurn: false
            )

        case .run(let requestedShortcutName):
            guard
                let installedShortcutDisplayName = shortcutCatalog.exactDisplayName(
                    matching: requestedShortcutName
                )
            else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i don't see a shortcut called \(requestedShortcutName).",
                    shouldRecordConversationTurn: false
                )
                return
            }

            handleFastLocalActionPath(
                transcript: transcript,
                fastActionParseResult: PaceShortcutCommandParser.fastActionParseResult(
                    for: installedShortcutDisplayName
                ),
                shouldRecordConversationTurn: false
            )
        }
    }

    private func shortcutCatalogListResponse(
        _ shortcutCatalog: PaceShortcutAutomationCatalog
    ) -> String {
        guard !shortcutCatalog.shortcutNames.isEmpty else {
            return "you don't have any shortcuts yet. create or import one in the Shortcuts app first."
        }

        let maximumSpokenShortcutCount = 8
        let spokenShortcutNames = shortcutCatalog.shortcutNames
            .prefix(maximumSpokenShortcutCount)
            .joined(separator: ", ")
        let remainingShortcutCount = max(
            0,
            shortcutCatalog.shortcutNames.count - maximumSpokenShortcutCount
        )

        if remainingShortcutCount > 0 {
            return "your shortcuts are \(spokenShortcutNames), and \(remainingShortcutCount) more."
        }
        return "your shortcuts are \(spokenShortcutNames)."
    }

    func handleImmediateLocalModeResponse(
        transcript: String,
        spokenText: String,
        shouldRecordConversationTurn: Bool = true
    ) {
        currentTurnHUDState = .done(spokenText)
        if shouldRecordConversationTurn {
            recordConversationTurn(userTranscript: transcript, assistantResponse: spokenText)
        }
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(spokenText)
        currentResponseTask = Task {
            voiceState = .responding
            await streamingSentenceTTSPipeline.flushFinal(finalSpokenText: spokenText)
            while ttsClient.isPlaying {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled else { return }
            responseOverlayManager.finishStreaming()
            voiceState = .idle
        }
    }

    func currentToolPreflightEnvironment() -> PaceToolPreflightEnvironment {
        PaceToolPreflightEnvironment(
            actionsAreEnabled: actionExecutor.actionsAreEnabled,
            hasAccessibilityPermission: hasAccessibilityPermission,
            hasCalendarPermission: hasCalendarPermission,
            hasRemindersPermission: hasRemindersPermission,
            configuredMCPServerNames: Set(PaceMCPServerRegistry.loadConfiguredServers().keys)
        )
    }

    func appendConfiguredMCPContext(to userPrompt: String) -> String {
        let configuredServerNames =
            PaceMCPServerRegistry
            .loadConfiguredServers()
            .keys
            .sorted()

        guard !configuredServerNames.isEmpty else {
            return userPrompt
        }

        return """
            \(userPrompt)

            Configured MCP servers:
            \(configuredServerNames.map { "- \($0)" }.joined(separator: "\n"))

            Use MCP only when a task is better handled by one of these configured external servers.
            """
    }
}
