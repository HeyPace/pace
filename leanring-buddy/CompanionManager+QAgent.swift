//
//  CompanionManager+QAgent.swift
//  leanring-buddy
//
//  Q Security Architecture — Companion QAgent Execution Pipeline (Phase 1F).
//  Connects user chat/voice input to QAgent, manages UI state transitions,
//  and speaks verified results via the local TTS engine.
//

import Foundation
import AppKit

extension CompanionManager: QAgentStateObserver {

    public func agentDidTransition(state: QAgentUIState, message: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.qRuntimeState = state
            switch state {
            case .offline:
                self.currentTurnHUDState = .idle
            case .starting:
                self.currentTurnHUDState = .understanding("Q Starting…")
            case .ready:
                self.currentTurnHUDState = .idle
            case .thinking:
                self.currentTurnHUDState = .understanding(message)
            case .requestingPermission:
                self.currentTurnHUDState = .clarification(question: message, options: ["Allow", "Deny"])
            case .executing:
                self.currentTurnHUDState = .acting(message)
            case .verifying:
                self.currentTurnHUDState = .acting("Verifying action…")
            case .completed:
                self.currentTurnHUDState = .done(message)
            case .blocked, .error:
                self.currentTurnHUDState = .failed(message)
            }
        }
    }

    /// Primary execution method for local agent turns via QAgent.
    @discardableResult
    public func executeQAgentTurn(transcript: String) async -> QAgentResult {
        qRuntimeState = .thinking
        currentTurnHUDState = .understanding("Q Agent Thinking…")

        do {
            let result = try await QAgent.shared.run(task: transcript, observer: self)

            // Post turn to chat session transcript
            chatSession.appendCompletedTurn(userTranscript: transcript, assistantResponse: result.summary)

            // Speak result via existing TTS pipeline
            if !chatSession.isChatTTSMuted {
                try? await ttsClient.speakText(result.summary)
            }

            voiceState = .idle
            return result
        } catch {
            qRuntimeState = .error
            currentTurnHUDState = .failed(error.localizedDescription)
            chatSession.appendCompletedTurn(userTranscript: transcript, assistantResponse: "Q Error: \(error.localizedDescription)")
            voiceState = .idle
            return QAgentResult(
                taskId: UUID().uuidString,
                sessionId: "error_session",
                intent: transcript,
                status: .failed(reason: error.localizedDescription),
                summary: "Error: \(error.localizedDescription)"
            )
        }
    }
}
