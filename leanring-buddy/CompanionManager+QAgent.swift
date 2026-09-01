//
//  CompanionManager+QAgent.swift
//  leanring-buddy
//
//  Q Security Architecture — Companion QAgent & QPlan UI Pipeline (Phase 2A.2).
//  Connects live QPlanExecutor events to the Pace Notch / Turn HUD, manages read-only
//  UI snapshots, and routes user permission decisions strictly through QPermissionGate.
//

import Foundation
import AppKit

extension CompanionManager: QAgentStateObserver, QPlanExecutionObserver {

    // MARK: - QAgentStateObserver

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
                self.currentTurnHUDState = PaceTurnHUDState(status: .idle, title: "Q", detail: "READY", options: [])
            case .thinking:
                self.currentTurnHUDState = PaceTurnHUDState(status: .understanding, title: "Q THINKING", detail: message, options: [])
            case .requestingPermission:
                self.currentTurnHUDState = PaceTurnHUDState.clarification(question: message, options: ["Allow", "Deny"])
            case .executing:
                self.currentTurnHUDState = PaceTurnHUDState(status: .acting, title: "Q EXECUTING", detail: message, options: [])
            case .verifying:
                self.currentTurnHUDState = PaceTurnHUDState(status: .acting, title: "Q VERIFYING", detail: message, options: [])
            case .completed:
                self.currentTurnHUDState = PaceTurnHUDState.done(message)
            case .blocked:
                self.currentTurnHUDState = PaceTurnHUDState.unsupported(message)
            case .error:
                self.currentTurnHUDState = PaceTurnHUDState.failed(message)
            }
        }
    }

    // MARK: - QPlanExecutionObserver

    public func planDidUpdate(plan: QPlan) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = QRuntimeUISnapshot.from(plan: plan)
            self.activeQPlanSnapshot = snapshot
            self.applyPlanSnapshotToHUD(snapshot: snapshot)
        }
    }

    public func stepDidTransition(step: QPlanStep, planId: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let currentSnapshot = self.activeQPlanSnapshot, currentSnapshot.planId == planId {
                var updatedSteps = currentSnapshot.steps
                if let idx = updatedSteps.firstIndex(where: { $0.id == step.id }) {
                    updatedSteps[idx] = QRuntimeStepSnapshot(
                        id: step.id,
                        index: step.index,
                        description: step.description,
                        actionName: step.action.actionName,
                        riskLevel: step.action.riskLevel.description,
                        state: step.state,
                        verifiedEvidence: step.result?.verifiedEvidence
                    )
                    self.activeQPlanSnapshot = QRuntimeUISnapshot(
                        planId: currentSnapshot.planId,
                        taskId: currentSnapshot.taskId,
                        taskPrompt: currentSnapshot.taskPrompt,
                        planState: currentSnapshot.planState,
                        currentStepIndex: step.index,
                        totalSteps: currentSnapshot.totalSteps,
                        currentStepDescription: step.description,
                        currentStepState: step.state,
                        statusMessage: currentSnapshot.statusMessage,
                        steps: updatedSteps,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    // MARK: - HUD Mapping

    private func applyPlanSnapshotToHUD(snapshot: QRuntimeUISnapshot) {
        guard let planState = snapshot.planState else { return }

        switch planState {
        case .pending:
            currentTurnHUDState = PaceTurnHUDState(
                status: .understanding,
                title: "Q",
                detail: "Planning \(snapshot.totalSteps) step(s)…",
                options: []
            )

        case .running:
            currentTurnHUDState = PaceTurnHUDState(
                status: .understanding,
                title: "Q THINKING",
                detail: "Planning \(snapshot.totalSteps) step(s)…",
                options: []
            )

        case .waitingForPermission(let idx, _):
            let stepName = snapshot.steps.indices.contains(idx) ? snapshot.steps[idx].description : "Action"
            currentTurnHUDState = PaceTurnHUDState.clarification(
                question: "Q needs permission: \(stepName)",
                options: ["Allow", "Deny"]
            )

        case .executing(let idx):
            let desc = snapshot.steps.indices.contains(idx) ? snapshot.steps[idx].description : "Executing…"
            currentTurnHUDState = PaceTurnHUDState(
                status: .acting,
                title: "STEP \(idx + 1) / \(snapshot.totalSteps)",
                detail: desc,
                options: []
            )

        case .verifying(let idx):
            let desc = snapshot.steps.indices.contains(idx) ? snapshot.steps[idx].description : "Verifying…"
            currentTurnHUDState = PaceTurnHUDState(
                status: .acting,
                title: "VERIFYING (\(idx + 1)/\(snapshot.totalSteps))",
                detail: desc,
                options: []
            )

        case .completed(let summary):
            currentTurnHUDState = PaceTurnHUDState.done(summary)

        case .blocked(let reason, _):
            currentTurnHUDState = PaceTurnHUDState.unsupported("Security Blocked: \(reason)")

        case .failed(let reason, _):
            currentTurnHUDState = PaceTurnHUDState.failed("Failed: \(reason)")

        case .cancelled(let reason):
            currentTurnHUDState = PaceTurnHUDState.failed("Cancelled: \(reason)")
        }
    }

    // MARK: - Permission UX Resolution

    /// Handles user clicking "Allow" or "Deny" in the permission HUD.
    /// Passes the decision strictly to QPermissionGate without touching execution directly.
    public func resolveQPermissionApproval(approved: Bool) {
        guard let snapshot = activeQPlanSnapshot,
              case .waitingForPermission(let idx, _) = snapshot.planState,
              snapshot.steps.indices.contains(idx) else {
            return
        }

        let step = snapshot.steps[idx]
        if approved {
            // User explicitly approved — register temporary grant in QPermissionGate
            let cap = QCapability(
                toolFamily: step.actionName.components(separatedBy: ".").first ?? step.actionName,
                toolName: step.actionName,
                scope: .global,
                maxRiskLevel: .level2UserApproval,
                grantedBy: .userInteractive,
                expiresAt: Date().addingTimeInterval(300),
                provenanceCeiling: .trustedOnly
            )
            QPermissionGate.shared.addGrant(cap)

            currentTurnHUDState = PaceTurnHUDState(
                status: .acting,
                title: "STEP \(idx + 1) / \(snapshot.totalSteps)",
                detail: "Permission granted, resuming…",
                options: []
            )
        } else {
            // User denied — fail closed
            currentTurnHUDState = PaceTurnHUDState.unsupported("User denied permission for \(step.description)")
        }
    }

    // MARK: - Agent Execution Dispatch

    /// Primary execution method for local agent turns via QAgent.
    @discardableResult
    public func executeQAgentTurn(transcript: String) async -> QAgentResult {
        qRuntimeState = .thinking
        currentTurnHUDState = PaceTurnHUDState(status: .understanding, title: "Q THINKING", detail: "Reasoning locally…", options: [])

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
            currentTurnHUDState = PaceTurnHUDState.failed(error.localizedDescription)
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
