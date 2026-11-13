//
//  PaceRuntimeSmokeTestHooks.swift
//  leanring-buddy
//
//  Runtime smoke-test hooks for app-level verification that is otherwise
//  fragile to drive through SwiftUI Accessibility. Disabled unless the app is
//  launched with PACE_ENABLE_SMOKE_HOOKS=1.
//

import Foundation

extension Notification.Name {
    static let paceSmokeTeachNextToken = Notification.Name("com.pace.smoke.teachNextToken")
    static let paceSmokeTeachLiftSystem = Notification.Name("com.pace.smoke.teachLiftSystem")
    static let paceSmokeTeachPiCamera = Notification.Name("com.pace.smoke.teachPiCamera")
    static let paceSmokeShowDiagram = Notification.Name("com.pace.smoke.showDiagram")
    static let paceSmokeSelectDiagramPart = Notification.Name("com.pace.smoke.selectDiagramPart")
    static let paceSmokeDismissDiagram = Notification.Name("com.pace.smoke.dismissDiagram")
    static let paceSmokeSpeakFixedPhrase = Notification.Name("com.pace.smoke.speakFixedPhrase")
    static let paceSmokeRequestSpokenReply = Notification.Name("com.pace.smoke.requestSpokenReply")
    static let paceSmokeShowPanel = Notification.Name("com.pace.smoke.showPanel")
    static let paceSmokeHidePanel = Notification.Name("com.pace.smoke.hidePanel")
    static let paceSmokeShowSettings = Notification.Name("com.pace.smoke.showSettings")
    static let paceSmokeCursorAnnotationsOn = Notification.Name("com.pace.smoke.cursorAnnotationsOn")
    static let paceSmokeCursorAnnotationsOff = Notification.Name("com.pace.smoke.cursorAnnotationsOff")
    static let paceSmokeRequestApproval = Notification.Name("com.pace.smoke.requestApproval")
    static let paceSmokeShowClarification = Notification.Name("com.pace.smoke.showClarification")
    static let paceSmokeResolveClarification = Notification.Name("com.pace.smoke.resolveClarification")
    static let paceSmokeShowClickTargetClarification = Notification.Name("com.pace.smoke.showClickTargetClarification")
    static let paceSmokeResolveClickTargetClarification = Notification.Name("com.pace.smoke.resolveClickTargetClarification")
    static let paceSmokeSimulateClickAllFailObservation = Notification.Name("com.pace.smoke.simulateClickAllFailObservation")
}

@MainActor
final class PaceRuntimeSmokeTestHooks {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["PACE_ENABLE_SMOKE_HOOKS"] == "1"
    }()

    private let menuBarPanelManager: MenuBarPanelManager
    private let companionManager: CompanionManager
    private var observers: [NSObjectProtocol] = []

    init(menuBarPanelManager: MenuBarPanelManager, companionManager: CompanionManager) {
        self.menuBarPanelManager = menuBarPanelManager
        self.companionManager = companionManager
        installObservers()
        PaceSmokeTestStateStore.markSmokeHooksReady()
    }

    deinit {
        let distributedNotificationCenter = DistributedNotificationCenter.default()
        for observer in observers {
            distributedNotificationCenter.removeObserver(observer)
        }
    }

    private func installObservers() {
        if Self.isEnabled, Bundle.main.object(forInfoDictionaryKey: "PaceLocalDevelopmentBuild") as? Bool == true {
            observe(.paceSmokeTeachNextToken) { [weak self] in
                guard let self else { return }
                self.companionManager.cancelActiveTurnTasks()
                guard self.companionManager.diagramOverlayController.present(PaceTeachingArrayIllustration.nextTokenExample) else { return }
                self.companionManager.playTeachingLessonFromControls()
                PaceSmokeTestStateStore.recordDiagramState(PaceTeachingArrayIllustration.nextTokenExample.nodes.count, selectedPart: nil)
            }
            for (notification, template) in [(Notification.Name.paceSmokeTeachLiftSystem, PaceFigureScene.Template.liftSystem),
                                             (.paceSmokeTeachPiCamera, .piCamera)] {
                observe(notification) { [weak self] in
                    guard let self, let document = PaceTeachingTemplateCatalog.lessonDocument(for: template) else { return }
                    self.companionManager.cancelActiveTurnTasks()
                    guard self.companionManager.diagramOverlayController.present(document) else { return }
                    self.companionManager.playTeachingLessonFromControls()
                    PaceSmokeTestStateStore.recordDiagramState(document.nodes.count, selectedPart: nil)
                }
            }
        }
        #if DEBUG
            observe(.paceSmokeShowDiagram) { [weak self] in
                guard let self,
                    let example = PaceToolRegistry.definition(forToolName: "show_diagram")?.schemaExample,
                    let data = example.data(using: .utf8),
                    var arguments = try? JSONDecoder().decode([String: PaceMCPJSONValue].self, from: data)
                else { return }
                arguments.removeValue(forKey: "tool")
                guard let document = PaceDiagramDocument.parse(arguments: arguments) else { return }
                companionManager.diagramOverlayController.present(document)
                PaceSmokeTestStateStore.recordDiagramState(document.nodes.count, selectedPart: nil)
            }
            observe(.paceSmokeSelectDiagramPart) { [weak self] in
                guard let controller = self?.companionManager.diagramOverlayController,
                    let node = controller.document?.nodes.last
                else { return }
                controller.selectNode(id: node.id)
                PaceSmokeTestStateStore.recordDiagramState(
                    controller.document?.nodes.count ?? 0, selectedPart: controller.selectedNodeID)
            }
            observe(.paceSmokeDismissDiagram) { [weak self] in
                self?.companionManager.diagramOverlayController.dismiss()
                PaceSmokeTestStateStore.recordDiagramState(0, selectedPart: nil)
            }
        #endif
        observe(.paceSmokeSpeakFixedPhrase) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.companionManager.voiceState == .idle, !self.companionManager.ttsClient.isPlaying else {
                    self.recordSpeechSmokeResult(operation: "fixed_phrase", outcome: "busy")
                    return
                }
                self.recordSpeechSmokeResult(operation: "fixed_phrase", outcome: "requested")
                do {
                    try await self.companionManager.ttsClient.speakText("Pace local speech playback is working.")
                    let outcome = self.companionManager.ttsClient is LocalTTSClient ? "playback_started" : "enqueued"
                    self.recordSpeechSmokeResult(operation: "fixed_phrase", outcome: outcome)
                } catch {
                    self.recordSpeechSmokeResult(operation: "fixed_phrase", outcome: "error")
                }
            }
        }

        observe(.paceSmokeRequestSpokenReply) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.companionManager.voiceState == .idle, !self.companionManager.ttsClient.isPlaying else {
                    self.recordSpeechSmokeResult(operation: "spoken_reply", outcome: "busy")
                    return
                }
                self.companionManager.submitChatTranscriptFromDeepLink(
                    "What is two plus two? Reply with one short sentence. Do not use tools or perform any actions."
                )
                // Submission is not proof of speech. The regular planner and
                // speech audit events report the remainder of this turn.
                self.recordSpeechSmokeResult(operation: "spoken_reply", outcome: "submitted")
            }
        }

        observe(.paceSmokeShowPanel) { [weak self] in
            self?.menuBarPanelManager.showPanelForSmokeTest()
            PaceSmokeTestStateStore.recordLastPanelCommand("show")
        }

        observe(.paceSmokeHidePanel) { [weak self] in
            self?.menuBarPanelManager.hidePanelForSmokeTest()
            PaceSmokeTestStateStore.recordLastPanelCommand("hide")
        }

        observe(.paceSmokeShowSettings) { [weak self] in
            guard let self else { return }
            menuBarPanelManager.hidePanelForSmokeTest()
            PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            PaceSmokeTestStateStore.recordLastSettingsCommand("show")
        }

        observe(.paceSmokeCursorAnnotationsOn) { [weak self] in
            guard let self else { return }
            let isEnabled = companionManager.smokeSetCursorAnnotationsEnabled(true)
            PaceSmokeTestStateStore.recordLastCursorAnnotationsEnabled(isEnabled)
        }

        observe(.paceSmokeCursorAnnotationsOff) { [weak self] in
            guard let self else { return }
            let isEnabled = companionManager.smokeSetCursorAnnotationsEnabled(false)
            PaceSmokeTestStateStore.recordLastCursorAnnotationsEnabled(isEnabled)
        }

        observe(.paceSmokeRequestApproval) { [weak self] in
            guard let self else { return }
            let didApprove = companionManager.smokeRequestApprovalForSyntheticActionPlan()
            PaceSmokeTestStateStore.recordLastApprovalAllowed(didApprove)
        }

        observe(.paceSmokeShowClarification) { [weak self] in
            guard let self else { return }
            let didShowClarification = companionManager.smokeShowSyntheticClarification()
            PaceSmokeTestStateStore.recordLastClarificationState(
                didShowClarification ? "shown" : "failed"
            )
        }

        observe(.paceSmokeResolveClarification) { [weak self] in
            guard let self else { return }
            let clarifiedTranscript = companionManager.smokeResolveSyntheticClarification()
            PaceSmokeTestStateStore.recordLastClarifiedTranscript(
                clarifiedTranscript ?? "<failed>"
            )
        }

        observe(.paceSmokeShowClickTargetClarification) { [weak self] in
            guard let self else { return }
            let didShow = companionManager.smokeShowClickTargetClarification()
            PaceSmokeTestStateStore.recordLastClickTargetClarificationState(
                didShow ? "shown" : "failed"
            )
        }

        observe(.paceSmokeResolveClickTargetClarification) { [weak self] in
            guard let self else { return }
            let resolvedLabel = companionManager.smokeResolveClickTargetClarification()
            PaceSmokeTestStateStore.recordLastClickTargetResolution(
                resolvedLabel ?? "<failed>"
            )
        }

        observe(.paceSmokeSimulateClickAllFailObservation) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let summary = await self.companionManager.smokeSimulateClickAllFailObservation()
                PaceSmokeTestStateStore.recordLastClickAllFailSummary(summary ?? "<failed>")
            }
        }
    }

    private func recordSpeechSmokeResult(operation: String, outcome: String) {
        PaceAPIAuditLog.shared.record(
            subsystem: "tts",
            operation: "runtime_smoke.\(operation)",
            target: "configured_tts",
            durationMilliseconds: 0,
            outcome: outcome
        )
    }

    private func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
        observers.append(observer)
    }
}
