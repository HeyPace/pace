import Foundation
import Testing

@testable import Pace

struct PaceInitialInspectionPlanResolverTests {
    private var eligibleContext: PaceInitialInspectionPlanResolver.Context {
        .init(
            usesDirectCodex: true, usesDefaultCodexPlanner: true,
            hasAcceptedDirectSpawnConsent: true, canRunDirectSpawnTurn: true,
            isReadMyScreenEnabled: true, areActionsEnabled: true,
            isLocalForegroundTurn: true, isResearchOrEscalationTurn: false,
            hasActiveSkill: false, hasScreenSuggestion: false,
            hasVisualContext: false, requestsTeaching: false)
    }

    @MainActor
    @Test func changedSettingsEndTheInspectionOnceWithoutStaleTurnOutput() throws {
        let (manager, persister, client) = PaceConversationRecorderTests().makeDismissalFixture()
        let turnLease = manager.turnLeaseRegistry.beginTurn()
        manager.beginConversationRequest("List Google Chrome windows.")
        manager.currentTurnHUDState = .acting("Checking windows")
        #expect(!manager.finishInitialInspectionIfSettingsChanged(context: eligibleContext, turnLease: turnLease))
        #expect(persister.events.values.filter { $0.role == .pace }.isEmpty)

        var revokedContext = eligibleContext
        revokedContext.isReadMyScreenEnabled = false
        #expect(manager.finishInitialInspectionIfSettingsChanged(context: revokedContext, turnLease: turnLease))
        #expect(manager.currentTurnHUDState.status == .failed)
        let message = try #require(manager.currentTurnHUDState.detail)
        #expect(manager.chatSession.userFacingMessages.filter { $0.body == message }.count == 1)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
        #expect(client.spokenTexts.isEmpty)

        let newerTurnLease = manager.turnLeaseRegistry.beginTurn()
        manager.currentTurnHUDState = .understanding("New request")
        #expect(!manager.finishInitialInspectionIfSettingsChanged(context: revokedContext, turnLease: turnLease))
        #expect(manager.isActiveTurn(newerTurnLease))
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
        #expect(manager.currentTurnHUDState == .understanding("New request"))
    }

    @Test func exactWindowCommandsProduceOneReadOnlyActionWithoutNarration() throws {
        let requests = [
            ("List Google Chrome windows", "Google Chrome"),
            ("List windows for Safari", "Safari"),
            ("  LIST   chrome WINDOWS.  ", "Google Chrome"),
            ("List Firefox windows!", "Firefox"),
            ("List windows for Arc.", "Arc"),
            ("List TextEdit windows.", "TextEdit"),
            ("Use Peekaboo window list with app Safari.", "Safari"),
            ("Read only: use Peekaboo window list with app Chrome.", "Google Chrome"),
        ]
        for (transcript, expectedApplicationName) in requests {
            let plan = try #require(
                PaceInitialInspectionPlanResolver.resolve(
                    transcript: transcript, context: eligibleContext))
            #expect(
                plan.toolCall
                    == PaceMCPToolCall(
                        serverName: "peekaboo", toolName: "window",
                        arguments: ["action": .string("list"), "app": .string(expectedApplicationName)]))
            let parsed = PaceActionTagParser.parseActions(from: plan.canonicalEnvelope)
            #expect(parsed.spokenText.isEmpty)
            #expect(parsed.actions.count == 1)
            #expect(parsed.executionPlan.flattenedActions.count == 1)
            guard case .mcp(let parsedCall) = try #require(parsed.actions.first) else {
                Issue.record("Expected one MCP window inventory action")
                continue
            }
            #expect(parsedCall == plan.toolCall)
            #expect(PaceActionApprovalPolicy.permitsObservationOnly(parsed.executionPlan))
            #expect(PaceActionApprovalPolicy.needsAnswerAfterInspection(parsed.executionPlan))

            let encoded = try JSONDecoder().decode(
                [String: PaceMCPJSONValue].self, from: Data(plan.canonicalEnvelope.utf8))
            #expect(encoded["spokenText"] == .string(""))
            #expect(encoded["intent"] == .string("action"))
        }
    }

    @Test func compoundsUnknownTargetsAndUnmatchedTextRetainOrdinaryPlanning() {
        for transcript in [
            "", "List windows", "List my windows", "List its windows", "List those windows again",
            "List windows for the previous app", "List windows for Unknown App",
            "List Google Chrome Beta windows", "List Chrome and Safari windows",
            "List Chrome windows and close them", "List Chrome windows then click Save",
            "List Chrome windows, please", "List Chrome windows. Open Safari.",
            "List Chrome windows\nType hello", "List Chrome windows..",
            "Don't list Chrome windows", "Do not list windows for Safari",
            "Explain how to list Chrome windows", "Teach me to list Chrome windows",
            "Research how to list Chrome windows", "Write code to list Chrome windows",
            "Run a skill to list Chrome windows", "List Chrome windows in the background",
            "List Chrome windows for PID 123", "List windows for Safari window 84",
            "List windows for Safari\"}", "List windows for $(open Safari)",
            "Use Playwright window list with app Safari",
            "Use Peekaboo app list with app Safari",
            "Use Peekaboo window close with app Safari",
            "Use Peekaboo window list with app Safari pid 123",
            "Use Peekaboo window list with app Safari window_id 84",
            "Use Peekaboo window list with app Safari and activate it",
            "Read only: use Peekaboo window list with app Chrome. Then click Save.",
            "Read only: use Peekaboo window list with app Google Chrome to check my current windows. Confirm briefly whether you could inspect them. Do not activate apps, click, type, open, close, or change anything. Also close Safari.",
        ] {
            #expect(
                PaceInitialInspectionPlanResolver.resolve(
                    transcript: transcript, context: eligibleContext) == nil, "\(transcript)")
        }
    }

    @Test func everyAuthorizationAndTurnContextGateIsRequired() {
        let requiredGates: [WritableKeyPath<PaceInitialInspectionPlanResolver.Context, Bool>] = [
            \.usesDirectCodex, \.usesDefaultCodexPlanner,
            \.hasAcceptedDirectSpawnConsent, \.canRunDirectSpawnTurn,
            \.isReadMyScreenEnabled, \.areActionsEnabled, \.isLocalForegroundTurn,
        ]
        let excludedContexts: [WritableKeyPath<PaceInitialInspectionPlanResolver.Context, Bool>] = [
            \.isResearchOrEscalationTurn, \.hasActiveSkill, \.hasScreenSuggestion,
            \.hasVisualContext, \.requestsTeaching,
        ]
        for gate in requiredGates + excludedContexts {
            var context = eligibleContext
            context[keyPath: gate].toggle()
            #expect(
                PaceInitialInspectionPlanResolver.resolve(
                    transcript: "List Google Chrome windows.", context: context) == nil)
        }
    }

    @Test func inspectionReceiptRequiresAContinuationWithItsExactEvidence() throws {
        let plan = try #require(
            PaceInitialInspectionPlanResolver.resolve(
                transcript: "List windows for Safari.", context: eligibleContext))
        let parsed = PaceActionTagParser.parseActions(from: plan.canonicalEnvelope)
        let observations = [
            PaceActionExecutionObservation(
                toolName: "mcp.peekaboo.window", summary: "Safari window 84: Launch checklist")
        ]
        #expect(
            PaceActionApprovalPolicy.needsAnswerAfterInspection(
                parsed.executionPlan, observations: observations))
        var history = PaceAgentInspectionHistory()
        history.append(plannerRequest: plan.canonicalEnvelope, observations: observations)
        #expect(history.formattedForPlanner.contains(plan.canonicalEnvelope))
        #expect(history.formattedForPlanner.contains("Safari window 84: Launch checklist"))
    }

    @Test func continuationScopeAllowsOnlyWindowListsOrAnAnswer() throws {
        let plan = try #require(PaceInitialInspectionPlanResolver.resolve(
            transcript: "List Safari windows.", context: eligibleContext))
        let observedProcessList = PaceParsedAction.mcp(.init(
            serverName: "peekaboo", toolName: "window",
            arguments: ["action": .string("list"), "app": .string("PID:111")]))
        #expect(plan.permitsContinuation(.serial(actions: [observedProcessList])))
        #expect(plan.permitsContinuation(PaceActionTagParser.parseActions(from: "safari has two windows.").executionPlan))
        #expect(plan.permitsContinuation(PaceActionExecutionPlan(steps: [
            .init(actions: [observedProcessList, observedProcessList])
        ])))

        let outOfScopeActions: [PaceParsedAction] = [
            .readClipboard,
            .openApplication("Safari"),
            .mcp(.init(serverName: "peekaboo", toolName: "window",
                arguments: ["action": .string("close"), "app": .string("PID:111")])),
            .mcp(.init(serverName: "peekaboo", toolName: "see", arguments: ["app": .string("PID:111")])),
            .mcp(.init(serverName: "peekaboo", toolName: "app", arguments: ["action": .string("list")])),
            .mcp(.init(serverName: "playwright", toolName: "window", arguments: ["action": .string("list")])),
            .mcp(.init(serverName: "peekaboo", toolName: "window", arguments: [:])),
        ]
        for action in outOfScopeActions {
            #expect(!plan.permitsContinuation(.serial(actions: [action])))
            #expect(!plan.permitsContinuation(PaceActionExecutionPlan(steps: [
                .init(actions: [observedProcessList, action])
            ])))
            #expect(!plan.permitsContinuation(.serial(actions: [observedProcessList, action])))
        }
    }

    @MainActor @Test func outOfScopeContinuationUsesOneCanonicalFailureWithoutDispatch() throws {
        let (manager, persister, client) = PaceConversationRecorderTests().makeDismissalFixture()
        let turnLease = manager.turnLeaseRegistry.beginTurn()
        manager.beginConversationRequest("List Safari windows.")
        let plan = try #require(PaceInitialInspectionPlanResolver.resolve(
            transcript: "List Safari windows.", context: eligibleContext))
        let unexpectedPlan = PaceActionExecutionPlan.serial(actions: [.readClipboard])
        #expect(!manager.finishInitialInspectionIfOutOfScope(
            initialInspectionPlan: nil, executionPlan: unexpectedPlan, turnLease: turnLease))
        #expect(manager.finishInitialInspectionIfOutOfScope(
            initialInspectionPlan: plan, executionPlan: unexpectedPlan, turnLease: turnLease))
        #expect(manager.currentTurnHUDState.status == .failed)
        let message = try #require(manager.currentTurnHUDState.detail)
        #expect(message.contains("No actions from that plan were executed"))
        #expect(manager.chatSession.userFacingMessages.filter { $0.body == message }.count == 1)
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
        #expect(client.spokenTexts.isEmpty)
        #expect(manager.actionExecutor.mutationLog.isEmpty)

        let newerTurnLease = manager.turnLeaseRegistry.beginTurn()
        manager.currentTurnHUDState = .understanding("New request")
        #expect(!manager.finishInitialInspectionIfOutOfScope(
            initialInspectionPlan: plan, executionPlan: unexpectedPlan, turnLease: turnLease))
        #expect(manager.isActiveTurn(newerTurnLease))
        #expect(persister.events.values.filter { $0.role == .pace }.count == 1)
        #expect(manager.currentTurnHUDState == .understanding("New request"))
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_RUN_INSPECTION_LATENCY_BENCHMARK"] == "1"))
    func nativeInitialPlanLatencyComparison() async throws {
        let transcript = "List Google Chrome windows."
        let systemPrompt = """
            You are Pace's planner. Author a plan, but do not execute tools or inspect anything yourself.
            For the user's exact named-app window-inventory command, return only one JSON action envelope.
            The envelope has spokenText="", intent="action", and payload containing name="MCP.call".
            Its args are server="peekaboo", tool="window", arguments={"action":"list","app":"Google Chrome"}.
            Return no narration, markdown, additional fields or additional actions.
            """
        let legacyPlanner = PaceLocalCLIPlannerClient(
            upstream: .codex, modelIdentifier: nil, requestTimeout: 30)
        var legacyMilliseconds: [Double] = []
        var localMilliseconds: [Double] = []
        var remoteRequests = 0
        let clock = ContinuousClock()

        func milliseconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }

        func validate(_ response: String) throws {
            let parsed = PaceActionTagParser.parseActions(from: response)
            #expect(parsed.spokenText.isEmpty)
            #expect(parsed.actions.count == 1)
            guard case .mcp(let call) = try #require(parsed.actions.first) else {
                Issue.record("The measured plan did not contain the requested inventory action")
                return
            }
            #expect(call.serverName == "peekaboo")
            #expect(call.toolName == "window")
            #expect(call.arguments == ["action": .string("list"), "app": .string("Google Chrome")])
            #expect(PaceActionApprovalPolicy.permitsObservationOnly(parsed.executionPlan))
        }

        func measureLegacy() async throws {
            let started = clock.now
            remoteRequests += 1
            let response = try await legacyPlanner.generateResponseStreaming(
                images: [], systemPrompt: systemPrompt, conversationHistory: [], userPrompt: transcript,
                onTextChunk: { _ in })
            legacyMilliseconds.append(milliseconds(started.duration(to: clock.now)))
            try validate(response.text)
        }

        func measureLocal() throws {
            let started = clock.now
            let plan = try #require(
                PaceInitialInspectionPlanResolver.resolve(
                    transcript: transcript, context: eligibleContext))
            localMilliseconds.append(milliseconds(started.duration(to: clock.now)))
            try validate(plan.canonicalEnvelope)
        }

        for index in 0..<5 {
            if index.isMultiple(of: 2) {
                try await measureLegacy()
                try measureLocal()
            } else {
                try measureLocal()
                try await measureLegacy()
            }
        }
        #expect(remoteRequests == 5)
        #expect(legacyMilliseconds.count == 5)
        #expect(localMilliseconds.count == 5)
        let report: [String: Any] = [
            "workload": transcript,
            "legacy_model": "selected Codex CLI default",
            "legacy_ms": legacyMilliseconds,
            "local_ms": localMilliseconds,
            "legacy_remote_requests": remoteRequests,
            "local_remote_requests": 0,
            "executor_calls": 0,
            "scope": "Initial-plan authoring only; excludes capture, tools, final answer and audio",
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PACE_INSPECTION_BENCHMARK \(try #require(String(data: reportData, encoding: .utf8)))")
    }
}
