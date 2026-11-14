import AppKit
import Foundation

@MainActor
extension CompanionManager {
    func handleRetainedCodingRequest(transcript: String, turnLease: PaceTurnLease) async {
        currentTurnHUDState = .understanding("preparing coding request")
        foregroundOffDeviceTurnInFlight = activePlannerTierIsOffDevice
        defer { if isActiveTurn(turnLease) { foregroundOffDeviceTurnInFlight = false } }
        do {
            plannerClient.resetForNewTurn()
            let response = try await plannerClient.generateResponseStreaming(images: [],
                systemPrompt: "Return one Pace v10 action envelope for the requested retained coding operation. Ask a clarification if its explicit workspace, session ID or task is missing. Never claim the coding work is done. "
                    + PaceCodingPower.definition.promptContributions.map { $0.render(.preinstalled) }.joined(separator: "\n")
                    + " Reply with {\"spokenText\":\"...\",\"intent\":\"action\",\"payload\":{\"name\":\"coding_session\",\"args\":{...}}}.",
                conversationHistory: [], userPrompt: transcript, onTextChunk: { _ in })
            guard isActiveTurn(turnLease) else { return }
            let parsed = PaceActionTagParser.parseActions(from: response.text)
            let message: String
            if parsed.actions.count == 1, case .codingSession(let command) = parsed.actions[0] {
                var approved = true
                if command.requiresExecutionConsent {
                    codingApprovalIsPresented = true
                    approved = requestUserApprovalForActionPlan(parsed.executionPlan)
                    codingApprovalIsPresented = false
                }
                guard isActiveTurn(turnLease), !Task.isCancelled else { return }
                if !approved {
                    message = "Coding request cancelled."
                } else {
                    message = await actionExecutor.executeSingleAction(.codingSession(command), screenCaptures: [])?.summary ?? "Coding is unavailable."
                }
            } else if parsed.actions.isEmpty, !parsed.spokenText.isEmpty {
                message = parsed.spokenText
            } else { message = "Specify the existing coding workspace, the task, or an exact retained session ID." }
            guard isActiveTurn(turnLease) else { return }
            await deliverCodingForegroundReply(message, transcript: transcript, turnLease: turnLease)
        } catch {
            guard isActiveTurn(turnLease) else { return }
            let message = "Coding request failed: " + error.localizedDescription
            await deliverCodingForegroundReply(message, transcript: transcript, turnLease: turnLease, failed: true)
        }
    }

    func handleCodingSessionEvent(_ event: PaceCodingSessionEvent) {
        switch event {
        case .changed(let session):
            if session.state.isBusy { codingSessionsInFlight.insert(session.id) }
            else { codingSessionsInFlight.remove(session.id) }
            refreshOffDeviceIndicator()
        case .conversation(let event):
            guard conversationRecorder.event(withIdentifier: event.eventID) == nil else { return }
            // Coding has its original canonical turn association and never acquires speech/foreground ownership.
            conversationRecorder.record(event)
        }
    }

    func executeRetainedCoding(_ command: PaceCodingSessionCommand) async -> PaceActionExecutionObservation {
        let turnIdentifier = activeConversationUserEvent?.eventID
        let authorized = actionExecutor.actionsAreEnabled && PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent()
            && PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: Date())
        if command.requiresExecutionConsent { codingSetupCallCount += 1; refreshOffDeviceIndicator() }
        defer {
            if command.requiresExecutionConsent { codingSetupCallCount -= 1; refreshOffDeviceIndicator() }
        }
        do {
            let result = try await codingSessionCoordinator.execute(command,
                conversationTurnIdentifier: turnIdentifier, authorized: authorized)
            return .init(toolName: "coding_session", summary: result)
        } catch {
            return .init(toolName: "coding_session", summary: "Coding failed: " + error.localizedDescription)
        }
    }

    func handleLocalCodingControl(_ command: PaceCodingSessionCommand, transcript: String, turnLease: PaceTurnLease) async {
        let observation = await executeRetainedCoding(command)
        guard isActiveTurn(turnLease) else { return }
        await deliverCodingForegroundReply(observation.summary, transcript: transcript, turnLease: turnLease)
    }

    func deliverCodingForegroundReply(_ message: String, transcript: String, turnLease: PaceTurnLease, failed: Bool = false) async {
        guard isActiveTurn(turnLease) else { return }
        let spokenSummary = Self.shortCodingAcknowledgement(message)
        let writtenResponse = spokenSummary == message ? message : spokenSummary + "\n\n" + message
        recordConversationTurn(userTranscript: transcript, assistantResponse: writtenResponse)
        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(writtenResponse)
        guard await beginFinalSpeechIfCurrentTurn(spokenText: spokenSummary, turnLease: turnLease) else { return }
        while ttsClient.isPlaying && isActiveTurn(turnLease) {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        }
        guard isActiveTurn(turnLease) else { return }
        responseOverlayManager.finishStreaming()
        currentTurnHUDState = failed ? .failed(message) : .done(message)
        voiceState = .idle
    }

    nonisolated static func shortCodingAcknowledgement(_ message: String) -> String {
        let summaries = message.components(separatedBy: "\n").filter { $0.hasPrefix("Coding session ") }
        if summaries.count > 1 { return "You have \(summaries.count) retained coding sessions. Their details are in chat." }
        guard let summary = summaries.first else { return message }
        let fields = summary.components(separatedBy: " · ")
        if fields.count == 3 {
            let workspaceName = URL(fileURLWithPath: fields[1]).lastPathComponent
            let state = fields[2].replacingOccurrences(of: "needsResume", with: "waiting for explicit resume")
                .replacingOccurrences(of: "awaitingApproval", with: "waiting for your approval")
            return "Coding in \(workspaceName) is \(state)."
        }
        if summary.contains("cancellation is requested") { return "Cancellation is requested. Waiting for Codex to confirm." }
        if summary.contains("has not confirmed terminal interruption") { return "Coding is cancelling. Codex has not confirmed it stopped yet." }
        return message
    }

    func requestCodingApproval(_ request: PaceActionApprovalRequest) -> PaceActionApprovalDecision {
        guard !Task.isCancelled, actionExecutor.actionsAreEnabled,
              PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent(),
              PaceCloudBridgeConsent.canRunDirectSpawnTurn(now: Date()) else { return .cancel }
        codingApprovalIsPresented = true
        defer { codingApprovalIsPresented = false }
        return presentActionApproval(request) ? .allowOnce : .cancel
    }

    func dismissCodingApprovals() {
        if codingApprovalIsPresented { NSApp.abortModal() }
        Task { await codingSessionCoordinator.dismissApprovals() }
    }
}
