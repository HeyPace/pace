import CoreGraphics
import Foundation
import Testing

@testable import Pace

struct PaceDiagramTests {
    private static func node(id: String = "evaporation", x: Double = 60, y: Double = 220) -> PaceDiagramNode {
        .init(
            id: id, label: "Evaporation", detail: "Heat turns liquid water into water vapor.", x: x, y: y, width: 230,
            height: 140, shape: .rectangle, role: .process, subtitle: "Liquid becomes vapor")
    }

    private static func document(title: String = "The water cycle", nodes: [PaceDiagramNode]? = nil)
        -> PaceDiagramDocument
    {
        .init(
            title: title, summary: "Water changes state as it moves through the environment.",
            nodes: nodes ?? [node(), node(id: "condensation", x: 650)],
            connections: [.init(source: "evaporation", target: "condensation", label: "cools")]
        )
    }

    private static func response(document: PaceDiagramDocument, multipleCalls: Bool = false) throws -> String {
        let documentData = try JSONEncoder().encode(document)
        let arguments = try JSONSerialization.jsonObject(with: documentData)
        let call: [String: Any] = ["name": "show_diagram", "args": arguments]
        let payload: [String: Any] = multipleCalls ? ["calls": [call]] : call
        let data = try JSONSerialization.data(withJSONObject: [
            "spokenText": "Watch water change state as it moves.", "intent": "action", "payload": payload,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func parsesGeneratedDocumentInSingleAndMultipleCallEnvelopes() throws {
        for multipleCalls in [false, true] {
            let parsed = PaceActionTagParser.parseActions(
                from: try Self.response(document: Self.document(), multipleCalls: multipleCalls))
            try #require(parsed.actions.count == 1)
            guard case .showDiagram(let document) = parsed.actions[0] else {
                Issue.record("Expected a generated diagram action")
                return
            }
            #expect(document.title == "The water cycle")
            #expect(document.nodes[0].detail == "Heat turns liquid water into water vapor.")
            #expect(document.connections[0].target == "condensation")
            #expect(parsed.spokenText == "Watch water change state as it moves.")
        }
    }

    @Test func waterCycleFromToEndpointsDecodeWithoutChangingValidation() throws {
        let response = try Self.response(document: Self.document())
            .replacingOccurrences(of: "\"source\":", with: "\"from\":")
            .replacingOccurrences(of: "\"target\":", with: "\"to\":")
        let parsed = PaceActionTagParser.parseActions(from: response)
        try #require(parsed.actions.count == 1)
        guard case .showDiagram(let document) = parsed.actions[0] else {
            Issue.record("Expected water cycle")
            return
        }
        #expect(document.connections[0].source == "evaporation")
        #expect(document.connections[0].target == "condensation")
        #expect(document.nodes[0].role == .process)
        #expect(document.validationIssue == nil)
        let conflicting = response.replacingOccurrences(
            of: "\"from\":\"evaporation\"", with: "\"from\":\"evaporation\",\"source\":\"condensation\"")
        #expect(PaceActionTagParser.parseActions(from: conflicting).actions.isEmpty)
    }

    @Test func parsesDiagramCloseAndLegacyToolCalls() throws {
        let close = PaceActionTagParser.parseActions(
            from: #"{"spokenText":"","intent":"action","payload":{"name":"dismiss_diagram","args":{}}}"#)
        try #require(close.actions.count == 1)
        guard case .dismissDiagram = close.actions[0] else {
            Issue.record("Expected close diagram")
            return
        }
        let data = try JSONEncoder().encode(Self.document())
        var arguments = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        arguments["tool"] = "show_diagram"
        let calls = try JSONSerialization.data(withJSONObject: [[arguments]])
        let legacy = PaceActionTagParser.parseActions(
            from: "<tool_calls>" + String(decoding: calls, as: UTF8.self) + "</tool_calls>")
        #expect(legacy.actions.count == 1)
    }

    @Test func malformedFigureFailsVisiblyInsteadOfClaimingSuccess() throws {
        let missingEndpoint = PaceDiagramDocument(
            title: "Bad graph", summary: "A missing part should not disappear silently.",
            nodes: [Self.node()], connections: [.init(source: "evaporation", target: "missing", label: nil)]
        )
        for multipleCalls in [false, true] {
            let parsed = PaceActionTagParser.parseActions(
                from: try Self.response(document: missingEndpoint, multipleCalls: multipleCalls))
            #expect(parsed.actions.isEmpty)
            #expect(parsed.spokenText.contains("couldn't draw"))
        }
        let mixedCalls =
            #"{"spokenText":"Here is your diagram.","intent":"action","payload":{"calls":[{"name":"show_diagram","args":{"title":"Broken"}},{"name":"type","args":{"text":"must not type"}}]}}"#
        let rejectedPlan = PaceActionTagParser.parseActions(from: mixedCalls)
        #expect(rejectedPlan.actions.isEmpty)
        #expect(rejectedPlan.spokenText.contains("couldn't draw"))
    }

    @Test func validatesDuplicateIDsBoundsOverlapsAndSizeLimits() {
        #expect(Self.document().validationIssue == nil)
        #expect(Self.document(nodes: [Self.node(), Self.node(x: 650)]).validationIssue != nil)
        #expect(Self.document(nodes: [Self.node(x: .nan)]).validationIssue != nil)
        #expect(Self.document(nodes: [Self.node(x: 950)]).validationIssue != nil)
        #expect(Self.document(nodes: [Self.node(), Self.node(id: "condensation", x: 100)]).validationIssue != nil)
        #expect(Self.document(title: String(repeating: "x", count: 101)).validationIssue != nil)
        let excessiveNodes = (0...PaceDiagramDocument.maximumNodeCount).map { Self.node(id: "part\($0)") }
        #expect(Self.document(nodes: excessiveNodes).validationIssue != nil)
    }

    @Test @MainActor func selectionIsLocalAndSurvivesAReplacementWithStableIDs() {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        var submitted: [String] = []
        controller.onAskAboutPart = { submitted.append($0) }
        #expect(controller.present(Self.document()))
        controller.selectNode(id: "evaporation")
        #expect(controller.lastUserInteractionAt != nil)
        #expect(controller.selectedNode?.detail.contains("water vapor") == true)
        #expect(submitted.isEmpty)
        #expect(controller.present(Self.document(title: "A closer view")))
        #expect(controller.selectedNodeID == "evaporation")
        #expect(controller.revision == 2)
        #expect(controller.askAboutSelectedNode())
        #expect(submitted.count == 1)
        #expect(submitted[0].contains("selected diagram part"))
        #expect(!submitted[0].contains("A closer view"))
        #expect(PaceDiagramDocument.requestsDiagram(submitted[0], hasActiveDiagram: true))
        let context = controller.appendingPlannerContext(to: "Why does it cool?")
        #expect(context.contains("Selected part ID: evaporation"))
        #expect(context.contains("water vapor"))
    }

    @Test @MainActor func nextPartNavigationStaysLocalAndExplorationRequiresASelectedPartAndHandler() {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        var submitted: [String] = []
        #expect(!controller.canAskAboutSelectedNode)
        #expect(!controller.askAboutSelectedNode())
        #expect(controller.present(Self.document()))
        controller.selectNextNode()
        #expect(controller.selectedNodeID == "evaporation")
        #expect(!controller.canAskAboutSelectedNode)
        #expect(!controller.askAboutSelectedNode())

        controller.onAskAboutPart = { submitted.append($0) }
        #expect(controller.canAskAboutSelectedNode)
        controller.selectNextNode()
        #expect(controller.selectedNodeID == "condensation")
        controller.selectNextNode()
        #expect(controller.selectedNodeID == "evaporation")
        #expect(submitted.isEmpty)
        #expect(controller.askAboutSelectedNode())
        #expect(submitted == [PaceDiagramDocument.selectedPartQuestion])

        controller.dismiss()
        #expect(!controller.canAskAboutSelectedNode)
        #expect(!controller.askAboutSelectedNode())
        #expect(submitted.count == 1)
    }

    @Test @MainActor func removedPartsClearSelectionAndDismissalRejectsLateResults() throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        var presentationCount = 0
        controller.onDidPresent = { presentationCount += 1 }
        controller.present(Self.document())
        controller.selectNode(id: "evaporation")
        let replacement = PaceDiagramDocument(
            title: "One part", summary: "A different part.", nodes: [Self.node(id: "new")], connections: [])
        controller.present(replacement)
        #expect(controller.selectedNode == nil)
        var generation = controller.dismissalGeneration
        controller.dismiss()
        #expect(controller.lastUserInteractionAt == nil)
        let parsed = PaceActionTagParser.parseActions(from: try Self.response(document: Self.document()))
        let drained = controller.drain(parseResult: parsed, expectedDismissalGeneration: &generation)
        #expect(controller.document == nil)
        #expect(presentationCount == 2)
        #expect(drained.actions.isEmpty)
        #expect(drained.spokenText == "I kept the diagram closed.")
        #expect(controller.appendingPlannerContext(to: "Next") == "Next")
        #expect(!controller.askAboutSelectedNode())
    }

    @Test @MainActor func drainingVisualToolsPreservesOtherActionsAndTheirApprovalPolicy() {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let actions: [PaceParsedAction] = [.showDiagram(Self.document()), .type("User-requested input")]
        let parsed = PaceActionTagParseResult(
            spokenText: "Here is the diagram.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        var generation = controller.dismissalGeneration
        let drained = controller.drain(parseResult: parsed, expectedDismissalGeneration: &generation)
        #expect(controller.document != nil)
        #expect(drained.actions.count == 1)
        #expect(drained.actions.first?.auditOperationName == "type")
        #expect(drained.executionPlan.flattenedActions.count == 1)
        #expect(!PaceActionApprovalPolicy.permitsObservationOnly(drained.executionPlan))
        #expect(PaceActionApprovalPolicy.permitsObservationOnly(.serial(actions: [.showDiagram(Self.document())])))
        #expect(
            !PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
                for: .serial(actions: [.showDiagram(Self.document())])))
    }

    @Test func routesScreenGroundedLearningWithoutUploadingUnrelatedScreens() {
        #expect(PaceDiagramDocument.requestsDiagram("Explain attention with a diagram", hasActiveDiagram: false))
        #expect(!PaceDiagramDocument.requiresScreenContext("Explain attention with a diagram", hasActiveDiagram: false))
        #expect(
            PaceDiagramDocument.requiresScreenContext(
                "Explain what's on my screen with a diagram", hasActiveDiagram: false))
        #expect(PaceDiagramDocument.requiresScreenContext("Explain this diagram", hasActiveDiagram: false))
        #expect(PaceDiagramDocument.requiresScreenContext("Explain this with a diagram", hasActiveDiagram: false))
        #expect(!PaceDiagramDocument.requiresScreenContext("Explain this diagram", hasActiveDiagram: true))
        #expect(PaceDiagramDocument.requiresScreenContext("Turn this code into a diagram", hasActiveDiagram: true))
        #expect(PaceDiagramDocument.requestsDiagram("Expand that", hasActiveDiagram: true))
        #expect(!PaceDiagramDocument.requestsDiagram("Open Safari", hasActiveDiagram: true))
        #expect(PaceDiagramDocument.requestsDismissal("Close the diagram."))
        #expect(!PaceDiagramDocument.requestsDismissal("Explain how to close the diagram"))
    }

    @Test func visualToolsAreAvailableWithoutActionsAndInScreenlessLearning() {
        #expect(
            CompanionSystemPrompt.build(includeAgentMode: false, includeInteractiveDiagrams: true).contains(
                "show_diagram"))
        #expect(CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true).contains("show_diagram"))
        #expect(CompanionSystemPrompt.buildForResearchTurn(includeInteractiveDiagrams: true).contains("show_diagram"))
        #expect(PaceToolRegistry.definition(forToolName: "show_diagram")?.riskLevel == .readOnly)
    }

    @Test func explicitActiveFigureViewsUseTheDiagramPathWithoutWideningUnrelatedRequests() {
        for transcript in ["Rotate this plane to top view", "Please turn the figure from the rear."] {
            #expect(PaceDiagramDocument.requestsDiagram(transcript, hasActiveDiagram: true))
            #expect(PaceDiagramDocument.canUseDiagramOnlyFastPath(transcript, hasActiveDiagram: true))
            #expect(!PaceDiagramDocument.requiresScreenContext(transcript, hasActiveDiagram: true))
            #expect(!PaceDiagramDocument.requestsDiagram(transcript, hasActiveDiagram: false))
        }
        for transcript in [
            "rotate it to top view", "rotate the window to top view", "rotate this plane to top view and open Safari",
        ] {
            #expect(!PaceDiagramDocument.canUseDiagramOnlyFastPath(transcript, hasActiveDiagram: true))
        }
        #expect(
            PaceDiagramDocument.canUseDiagramOnlyFastPath(
                PaceDiagramDocument.selectedPartQuestion, hasActiveDiagram: true))
    }

    @Test func diagramRoutingLeavesUnrelatedActionsAndAnnotationsAlone() {
        for transcript in [
            "open Sketch", "draw me a circle around the Save button", "email the diagram to Sam",
            "open the diagram in Preview", "walk me through setting up wifi", "change that to 50% volume",
            "draw a diagram then email Sam", "expand that node and type hello",
            "draw a diagram of my week then add it to Notes", "draw a diagram of my week and put it in Keynote",
            "show a diagram of the plan plus print it",
            "help me figure out a time and create a reminder", "can you figure out how to make a pivot table",
            "show me the sales figures", "create a flowchart in Figma", "change my wifi connection to Home",
            "add a reminder to order the replacement part", "change the node version in my project",
        ] {
            #expect(
                !PaceDiagramDocument.canUseDiagramOnlyFastPath(transcript, hasActiveDiagram: true),
                "Unexpected diagram fast path: \(transcript)")
        }
        #expect(PaceDiagramDocument.requestsDiagram("Show a diagram of the water cycle", hasActiveDiagram: false))
        #expect(PaceDiagramDocument.requestsDiagram("Walk me through this diagram", hasActiveDiagram: true))
        for transcript in [
            "Explain supply and demand with a diagram", "Draw a diagram of TCP and UDP",
            "draw a diagram of my week then add it to Notes",
        ] {
            #expect(PaceDiagramDocument.requestsDiagram(transcript, hasActiveDiagram: false))
            #expect(!PaceDiagramDocument.canUseDiagramOnlyFastPath(transcript, hasActiveDiagram: false))
        }
    }

    @Test func headlessPromptsDoNotAdvertiseInteractiveFigures() {
        #expect(!CompanionSystemPrompt.build(includeAgentMode: false).contains("show_diagram"))
        #expect(!CompanionSystemPrompt.buildTextOnly().contains("show_diagram"))
        #expect(!CompanionSystemPrompt.buildForResearchTurn().contains("show_diagram"))
    }

    @Test @MainActor func partQuestionsKeepGeneratedLabelsOutOfRoutingIntent() {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let document = Self.document(title: "How this code works")
        controller.present(document)
        controller.selectNode(id: "evaporation")
        var question = ""
        controller.onAskAboutPart = { question = $0 }
        #expect(controller.askAboutSelectedNode())
        #expect(!question.contains(document.title))
        #expect(!PaceDiagramDocument.requiresScreenContext(question, hasActiveDiagram: true))
        #expect(controller.appendingPlannerContext(to: question).contains(document.title))
    }

    @Test @MainActor func escapeOutsideTheDiagramPreservesTheLearningSession() {
        let frames = [CGRect(x: 200, y: 100, width: 500, height: 300)]
        #expect(
            !PaceDiagramOverlayManager.shouldDismissForEscape(
                pointerLocation: CGPoint(x: 50, y: 50), diagramFrames: frames))
        #expect(
            PaceDiagramOverlayManager.shouldDismissForEscape(
                pointerLocation: CGPoint(x: 400, y: 250), diagramFrames: frames))
    }

    @Test func deterministicAutomationsRejectInteractiveDiagramTools() {
        for tool in ["show_diagram", "dismiss_diagram", "diagram", "close_diagram"] {
            let definition = PaceAutomationDefinition(
                schemaVersion: 1, identifier: "diagram-test", name: "Diagram", description: "Visual", category: "test",
                source: .user, executionMode: .deterministicLocal, requiredPreferences: [],
                steps: [.init(toolCalls: [.init(tool: tool, arguments: [:])])]
            )
            #expect(
                PaceAutomationDefinitionValidator.validationIssues(for: definition).contains {
                    $0.message.contains("forbidden tool")
                })
            do {
                _ = try PaceAutomationCompiler.compile(definition)
                Issue.record("Interactive figures must not compile into unattended automations")
            } catch {
                #expect(String(describing: error).contains("forbidden tool"))
            }
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PACE_RUN_CODEX_DIAGRAM_INTEGRATION"] == "1"),
        .timeLimit(.minutes(2)))
    @MainActor func authenticatedCodexCreatesAndRevisesAnInteractiveDiagram() async throws {
        let client = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        let prompt = CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true)
        let question =
            "Create an interactive 2D flowchart explaining the water cycle. Include evaporation, condensation, precipitation and collection, with a useful explanation for every clickable part. Use show_diagram without figure geometry."
        let initialResponse = try await client.generateResponseStreaming(
            images: [], systemPrompt: prompt, conversationHistory: [], userPrompt: question, onTextChunk: { _ in }
        )
        let initialPlan = PaceActionTagParser.parseActions(from: initialResponse.text)
        let controller = PaceDiagramOverlayController(showsWindows: false)
        var generation = controller.dismissalGeneration
        _ = controller.drain(parseResult: initialPlan, expectedDismissalGeneration: &generation)
        let document = try #require(
            controller.document,
            "The authenticated Codex response must produce a valid interactive diagram: \(String(initialResponse.text.prefix(8000)))"
        )
        #expect(document.nodes.count >= 3)
        #expect(!initialPlan.spokenText.isEmpty)
        let part = try #require(document.nodes.first)
        controller.selectNode(id: part.id)
        let followUp = controller.appendingPlannerContext(
            to:
                "Simplify this diagram to three main parts. Keep the selected part ID and explain it more clearly. Return the updated show_diagram document."
        )
        client.resetForNewTurn()
        let revisedResponse = try await client.generateResponseStreaming(
            images: [], systemPrompt: prompt,
            conversationHistory: [(userPlaceholder: question, assistantResponse: initialPlan.spokenText)],
            userPrompt: followUp, onTextChunk: { _ in }
        )
        let revisedPlan = PaceActionTagParser.parseActions(from: revisedResponse.text)
        _ = controller.drain(parseResult: revisedPlan, expectedDismissalGeneration: &generation)
        #expect(controller.revision == 2)
        #expect(controller.document?.nodes.count == 3)
        #expect(controller.selectedNodeID == part.id)
        #expect(controller.selectedNode?.detail.isEmpty == false)
        controller.dismiss()
        #expect(controller.document == nil)
    }

    @Test @MainActor func aPlanCanReplaceItsOwnDismissedFigureWithoutDefeatingExternalDismissal() {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        controller.present(Self.document())
        let actions: [PaceParsedAction] = [.dismissDiagram, .showDiagram(Self.document(title: "Replacement"))]
        let plan = PaceActionTagParseResult(
            spokenText: "Updated.", actions: actions, executionPlan: .serial(actions: actions),
            firstClickVisualisationLocation: nil)
        var generation = controller.dismissalGeneration
        let result = controller.drain(parseResult: plan, expectedDismissalGeneration: &generation)
        #expect(controller.document?.title == "Replacement")
        #expect(result.spokenText == "Updated.")
        var oldGeneration = controller.dismissalGeneration
        controller.dismiss()
        controller.present(Self.document(title: "Newer user request"))
        _ = controller.drain(parseResult: plan, expectedDismissalGeneration: &oldGeneration)
        #expect(controller.document?.title == "Newer user request")
    }

    @Test func nonDiagramActionArgumentsNamedDiagramDoNotTriggerFigureValidation() {
        for payload in [
            #"{"name":"shortcut.run","args":{"name":"Diagram"}}"#,
            #"{"calls":[{"name":"shortcut.run","args":{"name":"Diagram"}}]}"#,
        ] {
            let response =
                "{\"spokenText\":\"Running the shortcut.\",\"intent\":\"action\",\"payload\":" + payload + "}"
            let result = PaceActionTagParser.parseActions(from: response)
            #expect(result.actions.count == 1)
            #expect(result.spokenText == "Running the shortcut.")
        }
    }

    @Test @MainActor func aTurnCarriesItsOwnDismissalGenerationAcrossPlannerSteps() {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        controller.present(Self.document())
        var generation = controller.dismissalGeneration
        let closeActions: [PaceParsedAction] = [.dismissDiagram]
        let closePlan = PaceActionTagParseResult(
            spokenText: "", actions: closeActions, executionPlan: .serial(actions: closeActions),
            firstClickVisualisationLocation: nil)
        _ = controller.drain(parseResult: closePlan, expectedDismissalGeneration: &generation)
        #expect(generation == controller.dismissalGeneration)
        let showActions: [PaceParsedAction] = [.showDiagram(Self.document(title: "Next step"))]
        let showPlan = PaceActionTagParseResult(
            spokenText: "Updated.", actions: showActions, executionPlan: .serial(actions: showActions),
            firstClickVisualisationLocation: nil)
        _ = controller.drain(parseResult: showPlan, expectedDismissalGeneration: &generation)
        #expect(controller.document?.title == "Next step")
        controller.dismiss()
        _ = controller.drain(parseResult: showPlan, expectedDismissalGeneration: &generation)
        #expect(controller.document == nil)
    }

}
