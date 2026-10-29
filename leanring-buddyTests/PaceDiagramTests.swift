import CoreGraphics
import Foundation
import Testing
@testable import Pace

struct PaceDiagramTests {
    private static func node(id: String = "evaporation", x: Double = 60, y: Double = 220) -> PaceDiagramNode {
        .init(id: id, label: "Evaporation", detail: "Heat turns liquid water into water vapor.", x: x, y: y, width: 230, height: 140, shape: .rectangle, role: .process, subtitle: "Liquid becomes vapor")
    }

    private static func document(title: String = "The water cycle", nodes: [PaceDiagramNode]? = nil) -> PaceDiagramDocument {
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
            "spokenText": "Watch water change state as it moves.", "intent": "action", "payload": payload
        ])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func parsesGeneratedDocumentInSingleAndMultipleCallEnvelopes() throws {
        for multipleCalls in [false, true] {
            let parsed = PaceActionTagParser.parseActions(from: try Self.response(document: Self.document(), multipleCalls: multipleCalls))
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

    @Test func parsesDiagramCloseAndLegacyToolCalls() throws {
        let close = PaceActionTagParser.parseActions(from: #"{"spokenText":"","intent":"action","payload":{"name":"dismiss_diagram","args":{}}}"#)
        try #require(close.actions.count == 1)
        guard case .dismissDiagram = close.actions[0] else {
            Issue.record("Expected close diagram")
            return
        }
        let data = try JSONEncoder().encode(Self.document())
        var arguments = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        arguments["tool"] = "show_diagram"
        let calls = try JSONSerialization.data(withJSONObject: [[arguments]])
        let legacy = PaceActionTagParser.parseActions(from: "<tool_calls>" + String(decoding: calls, as: UTF8.self) + "</tool_calls>")
        #expect(legacy.actions.count == 1)
    }

    @Test func malformedFigureFailsVisiblyInsteadOfClaimingSuccess() throws {
        let missingEndpoint = PaceDiagramDocument(
            title: "Bad graph", summary: "A missing part should not disappear silently.",
            nodes: [Self.node()], connections: [.init(source: "evaporation", target: "missing", label: nil)]
        )
        for multipleCalls in [false, true] {
            let parsed = PaceActionTagParser.parseActions(from: try Self.response(document: missingEndpoint, multipleCalls: multipleCalls))
            #expect(parsed.actions.isEmpty)
            #expect(parsed.spokenText.contains("couldn't draw"))
        }
        let mixedCalls = #"{"spokenText":"Here is your diagram.","intent":"action","payload":{"calls":[{"name":"show_diagram","args":{"title":"Broken"}},{"name":"type","args":{"text":"must not type"}}]}}"#
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

    @Test @MainActor func removedPartsClearSelectionAndDismissalRejectsLateResults() throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        var presentationCount = 0
        controller.onDidPresent = { presentationCount += 1 }
        controller.present(Self.document())
        controller.selectNode(id: "evaporation")
        let replacement = PaceDiagramDocument(title: "One part", summary: "A different part.", nodes: [Self.node(id: "new")], connections: [])
        controller.present(replacement)
        #expect(controller.selectedNode == nil)
        let generation = controller.dismissalGeneration
        controller.dismiss()
        let parsed = PaceActionTagParser.parseActions(from: try Self.response(document: Self.document()))
        let drained = controller.drain(parseResult: parsed, expectedDismissalGeneration: generation)
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
        let parsed = PaceActionTagParseResult(spokenText: "Here is the diagram.", actions: actions, executionPlan: .serial(actions: actions), firstClickVisualisationLocation: nil)
        let drained = controller.drain(parseResult: parsed, expectedDismissalGeneration: controller.dismissalGeneration)
        #expect(controller.document != nil)
        #expect(drained.actions.count == 1)
        #expect(drained.actions.first?.auditOperationName == "type")
        #expect(drained.executionPlan.flattenedActions.count == 1)
        #expect(!PaceActionApprovalPolicy.permitsObservationOnly(drained.executionPlan))
        #expect(PaceActionApprovalPolicy.permitsObservationOnly(.serial(actions: [.showDiagram(Self.document())])))
        #expect(!PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: .serial(actions: [.showDiagram(Self.document())])))
    }

    @Test func routesScreenGroundedLearningWithoutUploadingUnrelatedScreens() {
        #expect(PaceDiagramDocument.requestsDiagram("Explain attention with a diagram", hasActiveDiagram: false))
        #expect(!PaceDiagramDocument.requiresScreenContext("Explain attention with a diagram", hasActiveDiagram: false))
        #expect(PaceDiagramDocument.requiresScreenContext("Explain what's on my screen with a diagram", hasActiveDiagram: false))
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
        #expect(CompanionSystemPrompt.build(includeAgentMode: false, includeInteractiveDiagrams: true).contains("show_diagram"))
        #expect(CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true).contains("show_diagram"))
        #expect(CompanionSystemPrompt.buildForResearchTurn(includeInteractiveDiagrams: true).contains("show_diagram"))
        #expect(PaceToolRegistry.definition(forToolName: "show_diagram")?.riskLevel == .readOnly)
    }

    @Test func diagramRoutingLeavesUnrelatedActionsAndAnnotationsAlone() {
        for transcript in [
            "open Sketch", "draw me a circle around the Save button", "email the diagram to Sam",
            "open the diagram in Preview", "walk me through setting up wifi", "change that to 50% volume",
            "draw a diagram then email Sam", "expand that node and type hello"
        ] {
            #expect(!PaceDiagramDocument.requestsDiagram(transcript, hasActiveDiagram: true), "Unexpected diagram fast path: \(transcript)")
        }
        #expect(PaceDiagramDocument.requestsDiagram("Create a figure showing the water cycle", hasActiveDiagram: false))
        #expect(PaceDiagramDocument.requestsDiagram("Walk me through this diagram", hasActiveDiagram: true))
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
        #expect(!PaceDiagramOverlayManager.shouldDismissForEscape(pointerLocation: CGPoint(x: 50, y: 50), diagramFrames: frames))
        #expect(PaceDiagramOverlayManager.shouldDismissForEscape(pointerLocation: CGPoint(x: 400, y: 250), diagramFrames: frames))
    }

    @Test func deterministicAutomationsRejectInteractiveDiagramTools() {
        for tool in ["show_diagram", "dismiss_diagram", "diagram", "close_diagram"] {
            let definition = PaceAutomationDefinition(
                schemaVersion: 1, identifier: "diagram-test", name: "Diagram", description: "Visual", category: "test",
                source: .user, executionMode: .deterministicLocal, requiredPreferences: [],
                steps: [.init(toolCalls: [.init(tool: tool, arguments: [:])])]
            )
            #expect(PaceAutomationDefinitionValidator.validationIssues(for: definition).contains { $0.message.contains("forbidden tool") })
            do {
                _ = try PaceAutomationCompiler.compile(definition)
                Issue.record("Interactive figures must not compile into unattended automations")
            } catch {
                #expect(String(describing: error).contains("forbidden tool"))
            }
        }
    }


    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_RUN_CODEX_DIAGRAM_INTEGRATION"] == "1"), .timeLimit(.minutes(2)))
    @MainActor func authenticatedCodexCreatesAndRevisesAnInteractiveDiagram() async throws {
        let client = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        let prompt = CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true)
        let question = "Create an interactive diagram explaining the water cycle. Include evaporation, condensation, precipitation and collection, with a useful explanation for every clickable part. Use show_diagram."
        let initialResponse = try await client.generateResponseStreaming(
            images: [], systemPrompt: prompt, conversationHistory: [], userPrompt: question, onTextChunk: { _ in }
        )
        let initialPlan = PaceActionTagParser.parseActions(from: initialResponse.text)
        let controller = PaceDiagramOverlayController(showsWindows: false)
        _ = controller.drain(parseResult: initialPlan, expectedDismissalGeneration: controller.dismissalGeneration)
        let document = try #require(controller.document, "The authenticated Codex response must produce a valid interactive diagram")
        #expect(document.nodes.count >= 3)
        #expect(!initialPlan.spokenText.isEmpty)
        let part = try #require(document.nodes.first)
        controller.selectNode(id: part.id)
        let followUp = controller.appendingPlannerContext(to: "Simplify this diagram to three main parts. Keep the selected part ID and explain it more clearly. Return the updated show_diagram document.")
        client.resetForNewTurn()
        let revisedResponse = try await client.generateResponseStreaming(
            images: [], systemPrompt: prompt,
            conversationHistory: [(userPlaceholder: question, assistantResponse: initialPlan.spokenText)],
            userPrompt: followUp, onTextChunk: { _ in }
        )
        let revisedPlan = PaceActionTagParser.parseActions(from: revisedResponse.text)
        _ = controller.drain(parseResult: revisedPlan, expectedDismissalGeneration: controller.dismissalGeneration)
        #expect(controller.revision == 2)
        #expect(controller.document?.nodes.count == 3)
        #expect(controller.selectedNodeID == part.id)
        #expect(controller.selectedNode?.detail.isEmpty == false)
        controller.dismiss()
        #expect(controller.document == nil)
    }

}
