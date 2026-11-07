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
    static let paceSmokeShowDiagram = Notification.Name("com.pace.smoke.showDiagram")
    static let paceSmokeFocusFigure = Notification.Name("com.pace.smoke.focusFigure")
    static let paceSmokeShowFixtureImage = Notification.Name("com.pace.smoke.showFixtureImage")
    static let paceSmokeShowFlowchart = Notification.Name("com.pace.smoke.showFlowchart")
    static let paceSmokeSelectDiagramPart = Notification.Name("com.pace.smoke.selectDiagramPart")
    static let paceSmokeDismissDiagram = Notification.Name("com.pace.smoke.dismissDiagram")
    static let paceSmokeShowPanel = Notification.Name("com.pace.smoke.showPanel")
    static let paceSmokeHidePanel = Notification.Name("com.pace.smoke.hidePanel")
    static let paceSmokeShowSettings = Notification.Name("com.pace.smoke.showSettings")
    static let paceSmokeCursorAnnotationsOn = Notification.Name("com.pace.smoke.cursorAnnotationsOn")
    static let paceSmokeCursorAnnotationsOff = Notification.Name("com.pace.smoke.cursorAnnotationsOff")
    static let paceSmokeRequestApproval = Notification.Name("com.pace.smoke.requestApproval")
    static let paceSmokeShowClarification = Notification.Name("com.pace.smoke.showClarification")
    static let paceSmokeResolveClarification = Notification.Name("com.pace.smoke.resolveClarification")
    static let paceSmokeShowClickTargetClarification = Notification.Name("com.pace.smoke.showClickTargetClarification")
    static let paceSmokeResolveClickTargetClarification = Notification.Name(
        "com.pace.smoke.resolveClickTargetClarification")
    static let paceSmokeSimulateClickAllFailObservation = Notification.Name(
        "com.pace.smoke.simulateClickAllFailObservation")
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
        #if DEBUG
            observe(.paceSmokeShowFixtureImage) { [weak self] in
                guard Self.isVisualAcceptanceEnabled(),
                    let imagePath = ProcessInfo.processInfo.environment["PACE_VISUAL_ACCEPTANCE_IMAGE"]
                else { return }
                try? self?.companionManager.imageOverlayController.presentImageForSmokeTest(
                    at: URL(fileURLWithPath: imagePath))
            }
            observe(.paceSmokeShowFlowchart) { [weak self] in
                guard Self.isVisualAcceptanceEnabled() else { return }
                let fixture =
                    #"{"tool":"show_diagram","title":"A bounded local request","summary":"Task-owned flowchart fixture.","nodes":[{"id":"request","label":"Request","detail":"The user supplies a bounded request.","x":90,"y":220,"width":300,"height":140},{"id":"result","label":"Result","detail":"Pace returns the requested result.","x":610,"y":220,"width":300,"height":140}],"connections":[{"source":"request","target":"result","label":"respond"}]}"#
                guard case .showDiagram(let document) = PaceActionTagParser.parseActions(from: fixture).actions.first
                else { return }
                self?.companionManager.diagramOverlayController.present(document)
            }
            observe(.paceSmokeFocusFigure) { [weak self] in
                self?.companionManager.diagramOverlayController.focusFigureForSmokeTest()
            }
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

#if DEBUG
    extension PaceRuntimeSmokeTestHooks {
        static func isVisualAcceptanceEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            environment["PACE_ENABLE_SMOKE_HOOKS"] == "1" && environment["PACE_VISUAL_ACCEPTANCE_FIXTURE"] == "1"
        }

        static func makeVisualAcceptanceSessionIfEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> PaceChatSession? {
            guard isVisualAcceptanceEnabled(environment: environment) else { return nil }
            // A visual test must never load owner history or dispatch a typed fixture to a planner.
            let fixture = PaceVisualAcceptanceChatFixture()
            let session = PaceChatSession(historySource: fixture, transcriptSubmitter: fixture)
            fixture.session = session
            session.isChatTTSMuted = true
            return session
        }
    }

    @MainActor
    private final class PaceVisualAcceptanceChatFixture: PaceChatHistorySource, PaceChatTranscriptSubmitting {
        weak var session: PaceChatSession?

        func loadPastTurnsOldestFirst() -> [PaceChatHistoryTurn] {
            [
                .init(
                    id: "pace-visual-acceptance", userText: "Explain how an airplane wing produces lift.",
                    paceText:
                        "The wing redirects airflow downward. The pressure difference around its curved surface produces lift. Select a part of the interactive aircraft to explore it.",
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ]
        }

        func submitChatTranscript(_ transcript: String, optimisticMessageIdentifier: String) {
            session?.appendCompletedTurn(
                userTranscript: transcript,
                assistantResponse: "This is a local visual acceptance fixture. No planner or saved history was used.")
        }
    }
#endif
