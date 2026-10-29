import Foundation
import RealityKit
import Testing
import simd

@testable import Pace

@Suite(.serialized)
struct PaceFigureSceneTests {
    @Test func registryAircraftDecodesWithoutFlowchartCoordinates() throws {
        let document = try aircraftDocument()
        #expect(document.validationIssue == nil)
        #expect(document.figure?.template == .airplane)
        #expect(Set(document.nodes.map(\.id)) == PaceFigureScene.airplaneNodeIDs)
        #expect(document.connections.isEmpty)
    }

    @Test func customSolidsRequireEveryVisibleAssemblyToHaveAnExplanation() {
        let scene = PaceFigureScene(parts: [part()])
        #expect(scene.validationIssue(nodeIDs: ["body"]) == nil)
        #expect(scene.validationIssue(nodeIDs: ["body", "unrepresented"]) != nil)
        #expect(scene.validationIssue(nodeIDs: ["another"]) != nil)
    }

    @Test func invalidTransformsAndDuplicateSolidIDsAreRejected() {
        for position in [[0.0, 0], [Double.nan, 0, 0], [Double.infinity, 0, 0], [13, 0, 0]] {
            #expect(PaceFigureScene(parts: [part(position: position)]).validationIssue(nodeIDs: ["body"]) != nil)
        }
        for size in [[0.0, 1, 1], [-1, 1, 1], [1, 1, 13]] {
            #expect(PaceFigureScene(parts: [part(size: size)]).validationIssue(nodeIDs: ["body"]) != nil)
        }
        #expect(PaceFigureScene(parts: [part(), part()]).validationIssue(nodeIDs: ["body"]) != nil)
        #expect(PaceFigureScene(parts: []).validationIssue(nodeIDs: ["body"]) != nil)
    }

    @Test func meshIndicesDegeneracyAndGeometryBudgetsAreEnforced() {
        let vertices = [[0.0, 0, 0], [1, 0, 0], [0, 1, 0]]
        let valid = part(geometry: .mesh, vertices: vertices, triangles: [0, 1, 2])
        #expect(PaceFigureScene(parts: [valid]).validationIssue(nodeIDs: ["body"]) == nil)
        for triangles in [[0, 1, 3], [-1, 1, 2], [0, 0, 2], [0, 1]] {
            let invalid = part(geometry: .mesh, vertices: vertices, triangles: triangles)
            #expect(PaceFigureScene(parts: [invalid]).validationIssue(nodeIDs: ["body"]) != nil)
        }
        let collinear = part(geometry: .mesh, vertices: [[0, 0, 0], [0.5, 0, 0], [1, 0, 0]], triangles: [0, 1, 2])
        #expect(PaceFigureScene(parts: [collinear]).validationIssue(nodeIDs: ["body"]) != nil)
        let oversized = part(geometry: .mesh, vertices: Array(repeating: [0, 0, 0], count: 257), triangles: [0, 1, 2])
        #expect(PaceFigureScene(parts: [oversized]).validationIssue(nodeIDs: ["body"]) != nil)
        let excessSolids = (0...96).map { part(id: "solid-\($0)") }
        #expect(PaceFigureScene(parts: excessSolids).validationIssue(nodeIDs: ["body"]) != nil)
    }

    @Test func airplaneTemplateRejectsIncompleteExplanationsAndExtraGeometry() {
        #expect(PaceFigureScene(template: .airplane).validationIssue(nodeIDs: ["wings"]) != nil)
        #expect(
            PaceFigureScene(template: .airplane, parts: [part()]).validationIssue(
                nodeIDs: PaceFigureScene.airplaneNodeIDs) != nil)
        #expect(
            PaceFigureScene(template: .airplane, focusNodeID: "missing").validationIssue(
                nodeIDs: PaceFigureScene.airplaneNodeIDs) != nil)
    }

    @Test @MainActor func figureUpdatesPreserveExplorationAndHonorANewRequestedFocus() throws {
        var document = try aircraftDocument()
        let controller = PaceDiagramOverlayController(showsWindows: false)
        controller.present(document)
        #expect(controller.selectedNodeID == "wings")
        controller.selectNode(id: "ailerons")
        controller.present(document)
        #expect(controller.selectedNodeID == "ailerons")
        document.figure?.focusNodeID = "engines"
        controller.present(document)
        #expect(controller.selectedNodeID == "engines")
        #expect(controller.appendingPlannerContext(to: "Explain this").contains("airplane"))
        controller.dismiss()
        #expect(controller.document == nil)
    }

    @Test @MainActor func nativeAircraftContainsShapedSelectableGeometryAndRealHingeAssemblies() throws {
        let assembly = try PaceAircraftFigureBuilder.makeAssembly()
        #expect(Set(assembly.selectableEntities.map(\.name)) == PaceFigureScene.airplaneNodeIDs)
        #expect(assembly.movingSurfaces.count == 9)
        let bounds = assembly.root.visualBounds(relativeTo: nil)
        #expect(bounds.extents.x > 9)
        #expect(bounds.extents.z > 9)
        #expect(bounds.extents.y > 1)
        for surface in assembly.movingSurfaces {
            #expect(surface.entity.parent != nil)
            #expect(surface.maximumAngle.isFinite && surface.maximumAngle > 0)
            #expect(abs(length(surface.axis) - 1) < 0.0001)
            #expect(PaceFigureScene.airplaneNodeIDs.contains(surface.nodeID))
        }
        var entities = [assembly.root]
        var meshCount = 0
        while let entity = entities.popLast() {
            if entity is ModelEntity { meshCount += 1 }
            entities.append(contentsOf: entity.children)
        }
        #expect(meshCount >= 100)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PACE_RUN_CODEX_DIAGRAM_INTEGRATION"] == "1"),
        .timeLimit(.minutes(2)))
    @MainActor func authenticatedCodexAuthorsTheAircraftAndFocusesItsEngine() async throws {
        let client = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        let prompt = CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true)
        let question = "Show a detailed rotatable 3D airplane and explain how it flies. Use the native aircraft figure."
        let response = try await client.generateResponseStreaming(
            images: [], systemPrompt: prompt, conversationHistory: [], userPrompt: question, onTextChunk: { _ in })
        let parsed = PaceActionTagParser.parseActions(from: response.text)
        let controller = PaceDiagramOverlayController(showsWindows: false)
        var generation = controller.dismissalGeneration
        _ = controller.drain(parseResult: parsed, expectedDismissalGeneration: &generation)
        let document = try #require(
            controller.document,
            "Codex must emit a valid native aircraft scene: \(String(response.text.prefix(8000)))")
        #expect(document.figure?.template == .airplane)
        #expect(Set(document.nodes.map(\.id)) == PaceFigureScene.airplaneNodeIDs)
        controller.selectNode(id: "ailerons")
        client.resetForNewTurn()
        let followUp = try await client.generateResponseStreaming(
            images: [], systemPrompt: prompt,
            conversationHistory: [(userPlaceholder: question, assistantResponse: parsed.spokenText)],
            userPrompt: controller.appendingPlannerContext(
                to:
                    "Focus the figure on engines instead. Return the complete updated aircraft figure with focusNodeID engines."
            ),
            onTextChunk: { _ in })
        _ = controller.drain(
            parseResult: PaceActionTagParser.parseActions(from: followUp.text),
            expectedDismissalGeneration: &generation)
        #expect(controller.revision == 2)
        #expect(controller.document?.figure?.template == .airplane)
        #expect(controller.selectedNodeID == "engines")
        #expect(controller.selectedNode?.detail.isEmpty == false)
    }

    private func aircraftDocument() throws -> PaceDiagramDocument {
        let example = try #require(PaceToolRegistry.definition(forToolName: "show_diagram")?.schemaExample)
        let data = try #require(example.data(using: .utf8))
        var arguments = try JSONDecoder().decode([String: PaceMCPJSONValue].self, from: data)
        arguments.removeValue(forKey: "tool")
        return try #require(PaceDiagramDocument.parse(arguments: arguments))
    }

    private func part(
        id: String = "shell", geometry: PaceFigureScene.Geometry = .box,
        position: [Double] = [0, 0, 0], size: [Double] = [1, 1, 1],
        vertices: [[Double]]? = nil, triangles: [Int]? = nil
    ) -> PaceFigureScene.Part {
        PaceFigureScene.Part(
            id: id, nodeID: "body", geometry: geometry, position: position, size: size,
            vertices: vertices, triangles: triangles)
    }
}
