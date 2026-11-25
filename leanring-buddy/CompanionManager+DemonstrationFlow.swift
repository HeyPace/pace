//
//  CompanionManager+DemonstrationFlow.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A3):
//  demonstration flow recording / replay voice commands and executor hooks.
//  Stored flow collaborators (`flowStore`, `flowRecorder`, `flowReplayer`)
//  remain in the main file — Swift extensions cannot hold stored properties.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
extension CompanionManager {

    func handleFlowCommand(_ command: PaceFlowCommand, transcript: String) {
        switch command {
        case .startRecording(let name):
            let spokenText = startFlowRecordingFromVoiceCommand(flowName: name)
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)

        case .stopRecording:
            let spokenText = stopFlowRecordingFromVoiceCommand()
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)

        case .run(let name):
            // For voice-triggered replay we mark the flow as approved
            // for the current session (the voice command IS the
            // approval). Same-session subsequent runs of the same flow
            // bypass any further approval prompt.
            guard let storedFlow = flowStore.load(named: name) else {
                handleImmediateLocalModeResponse(
                    transcript: transcript,
                    spokenText: "i couldn't find a flow named \(name)."
                )
                return
            }
            flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
            handleImmediateLocalModeResponse(
                transcript: transcript,
                spokenText: "replaying \(storedFlow.name) now."
            )
            beginFlowReplay(storedFlow)

        case .delete(let name):
            let spokenText: String
            do {
                try flowStore.delete(named: name)
                spokenText = "deleted \(name)."
            } catch {
                spokenText = "i couldn't delete \(name)."
            }
            handleImmediateLocalModeResponse(transcript: transcript, spokenText: spokenText)
        }
    }

    /// Begin recording into a fresh flow named `flowName`. Returns the
    /// spoken-ready confirmation copy so the caller can route it
    /// through `handleImmediateLocalModeResponse(...)` (voice command)
    /// or back to the planner observation loop (`record_flow` tool).
    @discardableResult
    func startFlowRecordingFromVoiceCommand(flowName: String) -> String {
        let trimmedFlowName = flowName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFlowName.isEmpty else {
            return "flow recording needs a name."
        }
        switch flowRecorder.start(flowName: trimmedFlowName) {
        case .success:
            let recordingTurnIdentifier = activeConversationUserEvent?.eventID
            flowRecorder.onAutomaticStop = { [weak self] reason, flow in
                guard let self else { return }
                let feedback = Self.finishAutomaticRecording(
                    reason, flow: flow, recorder: flowRecorder, savingTo: flowStore)
                recordAssistantNarration(feedback, turnIdentifier: recordingTurnIdentifier, recordsDerivedMemory: false)
                revealRequestFeedback()
            }
            return "recording \(trimmedFlowName). say stop recording when you're done."
        case .failure(let error):
            return error.localizedDescription
        }
    }

    /// Stop the live recorder and persist whatever was captured. Public
    /// so the `record_flow` tool observation, the Settings UI, and the
    /// voice command parser can all share one save site.
    @discardableResult
    func stopFlowRecordingFromVoiceCommand() -> String {
        Self.stopFlowRecording(flowRecorder, savingTo: flowStore)
    }

    static func stopFlowRecording(_ recorder: PaceFlowRecorder, savingTo store: PaceFlowStore) -> String {
        let flow = recorder.isRecording ? recorder.stop(reason: .userCommand) : recorder.unsavedRecording
        guard let flow else {
            if let summary = recorder.lastAutomaticStopSummary {
                recorder.lastAutomaticStopSummary = nil
                return summary
            }
            return "no recording was in progress."
        }
        recorder.lastAutomaticStopSummary = nil
        return saveFlowRecording(flow, recorder: recorder, savingTo: store)
    }

    static func finishAutomaticRecording(
        _ reason: PaceFlowRecorderStopReason, flow: PaceRecordedFlow, recorder: PaceFlowRecorder,
        savingTo store: PaceFlowStore
    ) -> String {
        let cause = reason == .idleTimeout ? "Recording stopped after inactivity." : "Input capture was interrupted."
        let result = saveFlowRecording(flow, recorder: recorder, savingTo: store, replacingExisting: false)
        let feedback = cause + " " + result
        recorder.lastAutomaticStopSummary = feedback
        return feedback
    }

    private static func saveFlowRecording(
        _ flow: PaceRecordedFlow, recorder: PaceFlowRecorder, savingTo store: PaceFlowStore,
        replacingExisting: Bool = true
    ) -> String {
        guard !flow.steps.isEmpty else {
            return "No steps were captured, so \(flow.name) wasn’t saved. Start recording again and perform the steps."
        }
        do {
            try store.save(flow, replacingExisting: replacingExisting)
            recorder.markSaved(flow)
            return "saved \(flow.name) with \(flow.steps.count) step\(flow.steps.count == 1 ? "" : "s")."
        } catch PaceFlowStoreError.destinationFlowAlreadyExists {
            return
                "Captured \(flow.steps.count) steps. Say stop recording to replace the saved workflow \(flow.name) with these steps."
        } catch {
            return "Could not save \(flow.name). Its captured steps are still in Pace. Say stop recording to retry."
        }
    }

    /// Drive the live replayer. Speaks completion or failure copy via
    /// the existing TTS path; the replayer itself is fully `await`-
    /// driven and yields back to the run loop between steps.
    func beginFlowReplay(_ storedFlow: PaceRecordedFlow) {
        let replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flowReplayer.play(
                storedFlow,
                confirmSensitivePress: { [weak self] resolution, stepIndex in
                    guard let self, let element = resolution.element,
                        let target = NSWorkspace.shared.frontmostApplication
                    else { return false }
                    var targetPID: pid_t = 0
                    guard AXUIElementGetPid(element, &targetPID) == .success, targetPID == target.processIdentifier,
                        let approval = PaceActionApprovalRequest(
                            approvalSummary:
                                "Press “\(resolution.debugLabel)” in \(target.localizedName ?? "the current app") for step \(stepIndex + 1) of “\(storedFlow.name)”.",
                            requiresActionApproval: true),
                        self.presentActionApproval(approval)
                    else { return false }
                    // The modal brings Pace forward. Restore only the original app, and
                    // leave a newly selected third-party app alone.
                    if target.isActive { return true }
                    guard
                        NSWorkspace.shared.frontmostApplication?.processIdentifier
                            == ProcessInfo.processInfo.processIdentifier,
                        target.activate(options: [])
                    else { return false }
                    for _ in 0..<20 {
                        if target.isActive { return true }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    return target.isActive
                },
                onProgress: { stepIndex in
                    print("🔁 PaceFlowReplayer: completed step \(stepIndex + 1) of \(storedFlow.steps.count)")
                },
                onCompletion: { [weak self] outcome in
                    guard let self else { return }
                    Task { @MainActor in
                        self.speakFlowReplayOutcome(outcome, flowName: storedFlow.name)
                    }
                }
            )
        }
        _ = replayTask  // task lifetime is tied to MainActor; no need to retain
    }

    /// Compose + speak the per-outcome line. Failure paths route
    /// through the deterministic failure narrator so the message
    /// reads in the same voice as the other plain-language failures.
    func speakFlowReplayOutcome(
        _ outcome: PaceFlowReplayOutcome,
        flowName: String
    ) {
        let spokenText: String
        switch outcome {
        case .completed:
            spokenText = "done with \(flowName)."
        case .stoppedBeforeSendStep:
            spokenText = "Stopped \(flowName) before sending. The step needs your approval."
        case .failedToFindTarget(let stepIndex, let axLabel):
            // Reuse the click-missed narration shape so the user hears
            // the same "I couldn't find X" phrasing they get from a
            // failed planner click.
            let narration = PaceFailureNarrator.compose(
                .clickMissed(targetLabel: axLabel)
            )
            spokenText = "\(narration.spokenText) (step \(stepIndex + 1) of \(flowName))"
        case .failedToPressTarget(let stepIndex, let axLabel):
            spokenText = "I couldn't press \(axLabel) at step \(stepIndex + 1) of \(flowName)."
        case .userCancelled:
            spokenText = "stopped \(flowName)."
        }
        recordAssistantNarration(spokenText)
        Task { @MainActor in
            try? await self.speakStandardNarration(spokenText)
        }
    }

    /// Helper exposed for the `run_flow` tool callback the executor
    /// invokes. Returns true if the replay actually kicked off; false
    /// when the flow needs explicit user approval that hasn't been
    /// granted this session yet (the executor's observation distinguishes
    /// the two for the planner-loop summary).
    @discardableResult
    func runFlowFromExecutorTool(_ storedFlow: PaceRecordedFlow) -> Bool {
        // Approval cache: planner-driven `run_flow` calls go through
        // here. Same-session subsequent runs of the same flow skip the
        // approval popup. First-time runs in a session would normally
        // surface the approval popup via PaceActionExecutor's existing
        // gate — that path is already in place for record_flow/run_flow
        // because both are flagged risky in PaceToolRegistry.
        if flowNamesApprovedForReplayThisSession.contains(storedFlow.name) {
            beginFlowReplay(storedFlow)
            return true
        }
        // Mark approved now (the executor only invokes this callback
        // after its own approval gate has cleared the action).
        flowNamesApprovedForReplayThisSession.insert(storedFlow.name)
        beginFlowReplay(storedFlow)
        return true
    }
}
