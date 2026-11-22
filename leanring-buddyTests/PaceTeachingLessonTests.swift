import Foundation
import Testing

@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceTeachingLessonTests {
    private final class SpeechGate {
        var narratedIDs: [String] = []
        var waiter: CheckedContinuation<Void, Error>?
        func narrate(_ step: PaceTeachingLesson.Step) async throws {
            narratedIDs.append(step.id)
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        func finish() { let previous = waiter; waiter = nil; previous?.resume() }
        func stop() { let previous = waiter; waiter = nil; previous?.resume(throwing: CancellationError()) }
    }

    private func fixture() throws -> PaceDiagramDocument {
        try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .piCamera))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 { if condition() { return }; await Task.yield() }
        #expect(condition())
        throw CancellationError()
    }

    @Test func templatesValidateAndKeepPlannerGeometryBudgetSeparate() throws {
        for definition in PaceTeachingTemplateCatalog.definitions {
            let document = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: definition.template))
            #expect(document.validationIssue == nil)
            #expect(definition.parts.count >= 90)
            #expect(Set(definition.parts.map(\.nodeID)) == definition.nodeIDs)
            #expect(Set(definition.anchors.keys) == definition.nodeIDs)
            #expect(definition.controlNodeIDs.isSubset(of: definition.nodeIDs))
            #expect(Set(definition.parts.map(\.id)).count == definition.parts.count)
            let custom = PaceFigureScene(parts: definition.parts)
            #expect(custom.validationIssue(nodeIDs: definition.nodeIDs) != nil)
            let roundTrip = try JSONDecoder().decode(PaceDiagramDocument.self, from: JSONEncoder().encode(document))
            #expect(roundTrip == document)
        }
    }

    @Test func invalidLessonReferencesAreRejectedBeforeReplacingVisibleDocument() throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let original = try fixture()
        #expect(controller.present(original))
        let invalidSteps: [PaceTeachingLesson.Step] = [
            .init(id: "unknown", title: "Unknown", narration: "Not visible.", revealedNodeIDs: ["missing"]),
            .init(id: "hidden-focus", title: "Hidden", narration: "Not visible.", revealedNodeIDs: ["board"], focusNodeID: "latch"),
            .init(id: "invalid-motion", title: "Motion", narration: "Invalid range.", revealedNodeIDs: ["latch"], focusNodeID: "latch", controlValue: 2),
            .init(id: "unsupported-motion", title: "Motion", narration: "Invalid assembly.", revealedNodeIDs: ["board"], focusNodeID: "board", controlValue: 0.5)
        ]
        for step in invalidSteps {
            var invalid = original
            invalid.lesson = .init(steps: [step])
            #expect(invalid.validationIssue != nil)
            #expect(!controller.present(invalid))
            #expect(controller.document?.title == original.title)
            #expect(controller.currentLessonStep?.id == original.lesson?.steps.first?.id)
        }
        var duplicate = original
        let step = try #require(original.lesson?.steps.first)
        duplicate.lesson = .init(steps: [step, step])
        #expect(duplicate.validationIssue != nil)
    }

    @Test func progressionWaitsForUtteranceCompletionAndPauseRestartsHonestly() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let document = try fixture()
        #expect(controller.present(document))
        let gate = SpeechGate()
        let run = Task { await controller.runLesson(muted: false, stopSpeech: gate.stop, narrate: gate.narrate) }
        try await waitUntil { gate.waiter != nil }
        #expect(controller.lessonStepIndex == 0)
        #expect(controller.lessonPlaybackState == .playing)
        gate.finish()
        try await waitUntil { gate.narratedIDs.count == 2 }
        #expect(controller.lessonStepIndex == 1)
        controller.pauseLesson()
        await run.value
        #expect(controller.lessonPlaybackState == .paused)
        #expect(controller.lessonStepIndex == 1)
        let restarted = Task { await controller.runLesson(muted: false, stopSpeech: gate.stop, narrate: gate.narrate) }
        try await waitUntil { gate.narratedIDs.count == 3 }
        #expect(gate.narratedIDs[1] == gate.narratedIDs[2])
        controller.dismiss()
        await restarted.value
        #expect(controller.document == nil)
        #expect(controller.lessonPlaybackState == .idle)
    }

    @Test func navigationHasDeterministicSnapshotsAndPlayingNavigationKeepsTheAwaitedOwner() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        #expect(controller.present(try fixture()))
        var replayRequests = 0
        controller.onPlayLessonRequested = { replayRequests += 1 }
        controller.moveLesson(by: 3)
        #expect(controller.currentLessonStep?.focusNodeID == "latch")
        #expect(controller.controlDeflection == 0.8)
        controller.moveLesson(by: -1)
        #expect(controller.currentLessonStep?.focusNodeID == "display-port")
        #expect(controller.controlDeflection == 0)
        #expect(replayRequests == 0)
        let gate = SpeechGate()
        let run = Task { await controller.runLesson(muted: false, stopSpeech: gate.stop, narrate: gate.narrate) }
        try await waitUntil { gate.waiter != nil }
        controller.moveLesson(by: 1)
        try await waitUntil { gate.narratedIDs.count == 2 }
        #expect(replayRequests == 0)
        #expect(controller.currentLessonStep?.focusNodeID == "latch")
        #expect(controller.lessonPlaybackState == .playing)
        controller.pauseLesson()
        await run.value
    }

    @Test func manualSelectionAndReplacementFenceLateCompletion() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        #expect(controller.present(try fixture()))
        let gate = SpeechGate()
        let run = Task { await controller.runLesson(muted: false, stopSpeech: gate.stop, narrate: gate.narrate) }
        try await waitUntil { gate.waiter != nil }
        controller.selectNode(id: "camera")
        await run.value
        #expect(controller.selectedNodeID == "camera")
        #expect(controller.lessonPlaybackState == .paused)
        #expect(controller.lessonStepIndex == 0)
        let replacement = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .liftSystem))
        #expect(controller.present(replacement))
        gate.finish()
        #expect(controller.currentLessonStep?.focusNodeID == "airframe")
        #expect(controller.lessonStepIndex == 0)
    }

    @Test func mutedLessonStaysManualAndNeverCallsVoice() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        #expect(controller.present(try fixture()))
        var voiceCalls = 0
        await controller.runLesson(muted: true, stopSpeech: {}, narrate: { _ in voiceCalls += 1 })
        #expect(voiceCalls == 0)
        #expect(controller.lessonPlaybackState == .paused)
        controller.moveLesson(by: 1)
        #expect(controller.lessonStepIndex == 1)
        #expect(voiceCalls == 0)
    }

    @Test func sharedVisualDrainerAwaitsLessonAndRetainsWrittenAnswerWithHandledSpeech() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let imageController = PaceImageOverlayController(showsWindows: false)
        let document = try fixture()
        let actions: [PaceParsedAction] = [.showDiagram(document)]
        let parsed = PaceActionTagParseResult(spokenText: "Do not duplicate this overview.", actions: actions,
            executionPlan: .serial(actions: actions), firstClickVisualisationLocation: nil)
        let gate = SpeechGate()
        var hasReturned = false
        let drain = Task {
            var generation = controller.dismissalGeneration
            let result = await PaceVisualActionDrainer.drain(parseResult: parsed,
                diagramOverlayController: controller, imageOverlayController: imageController,
                expectedDiagramDismissalGeneration: &generation,
                expectedImageDismissalGeneration: imageController.dismissalGeneration,
                runLesson: { _ in await controller.runLesson(muted: false, stopSpeech: gate.stop, narrate: gate.narrate); return true })
            hasReturned = true
            return result
        }
        try await waitUntil { gate.waiter != nil }
        #expect(controller.document != nil)
        #expect(!hasReturned)
        controller.pauseLesson()
        let result = await drain.value
        #expect(result.spokenText.contains(document.lesson?.steps.first?.narration ?? "missing"))
        #expect(result.teachingDelivery?.handlesSpeech == true)
        #expect(result.actions.isEmpty)
        #expect(result.executionPlan.steps.isEmpty)
    }
    @Test func dataDrivenArraysValidateAndTargetsAreShifted() throws {
        let example = PaceTeachingArrayIllustration.nextTokenExample
        #expect(example.validationIssue == nil)
        let rows = try #require(example.illustration?.rows)
        let sequence = try #require(rows.first { $0.nodeID == "sequence" }).values
        let context = try #require(rows.first { $0.nodeID == "context" }).values
        let target = try #require(rows.first { $0.nodeID == "target" }).values
        #expect(context == Array(sequence.prefix(4)))
        #expect(target == Array(sequence.dropFirst().prefix(4)))
        #expect(target.count == context.count)
        for invalidRow in [
            PaceTeachingArrayIllustration.Row(nodeID: "sequence", kind: .tokens, values: ["a"], offset: -1),
            .init(nodeID: "sequence", kind: .tokens, values: [String(repeating: "x", count: 25)]),
            .init(nodeID: "sequence", kind: .matrix, values: ["1"], columns: 0),
            .init(nodeID: "sequence", kind: .tokens, values: Array(repeating: "x", count: 13)),
            .init(nodeID: "sequence", kind: .tokens, values: ["a"], columns: 3)
        ] {
            #expect(PaceTeachingArrayIllustration(rows: [invalidRow]).validationIssue(nodeIDs: ["sequence"]) != nil)
        }
        var mixed = example
        mixed.figure = .init(template: .piCamera)
        #expect(mixed.validationIssue != nil)
    }

    @Test func mutedAndManualCaptionsUseOneSharedHistoryIdentity() async throws {
        let (manager, persister, client) = PaceConversationRecorderTests().makeDismissalFixture()
        let user = manager.acceptConversationRequest("Teach camera wiring", origin: .typed)
        manager.diagramOverlayController.lessonConversationTurnIdentifier = user.eventID
        let step = try #require(try fixture().lesson?.steps.first)
        manager.diagramOverlayController.onWrittenLessonStep?(step)
        manager.diagramOverlayController.onWrittenLessonStep?(step)
        let identifier = manager.diagramOverlayController.historyEventIdentifier(for: step)
        manager.recordAssistantNarration(step.narration, eventIdentifier: identifier, turnIdentifier: user.eventID)
        let assistantEvents = persister.events.values.filter { $0.role == .pace }
        #expect(assistantEvents.count == 1)
        #expect(assistantEvents.first?.text == step.narration)
        #expect(assistantEvents.first?.turnID == user.eventID)
        #expect(client.spokenTexts.isEmpty)
        #expect(manager.chatSession.messages.filter { $0.role == .pace && $0.body == step.narration }.count == 1)
    }

    @Test func followingUpKeepsGeometryAndNeverReplaysCopiedLesson() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let original = try fixture()
        #expect(controller.present(original))
        await controller.runLesson(muted: true, stopSpeech: {}, narrate: { _ in Issue.record("Muted lesson spoke.") })
        controller.moveLesson(by: 3)
        let historyID = controller.historyEventIdentifier(for: try #require(controller.currentLessonStep))
        var followup = original
        followup.figure?.focusNodeID = "camera"
        followup.figure?.viewpoint = .top
        #expect(controller.present(followup))
        #expect(controller.lessonStepIndex == 3)
        #expect(!controller.lessonNeedsInitialPlayback)
        #expect(controller.selectedNodeID == "camera")
        #expect(controller.document?.figure?.hasSameGeometry(as: try #require(original.figure)) == true)
        #expect(controller.historyEventIdentifier(for: try #require(controller.currentLessonStep)) == historyID)
        let context = controller.appendingPlannerContext(to: "Question")
        #expect(!context.contains("revealedNodeIDs"))
        #expect(context.contains("do not recreate or replay"))
    }

    @Test func uncooperativeOldNarrationCompletionCannotAdvanceReplacementLesson() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        #expect(controller.present(try fixture()))
        let gate = SpeechGate()
        let oldRun = Task { await controller.runLesson(muted: false, stopSpeech: {}, narrate: gate.narrate) }
        try await waitUntil { gate.waiter != nil }
        let replacement = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .liftSystem))
        #expect(controller.present(replacement))
        gate.finish()
        await oldRun.value
        #expect(controller.document?.title == replacement.title)
        #expect(controller.lessonStepIndex == 0)
        #expect(controller.currentLessonStep?.focusNodeID == "airframe")
        #expect(controller.lessonPlaybackState == .paused)
    }

    @Test func revokedCallerLeaseCannotPresentOrAdoptNewTurn() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let imageController = PaceImageOverlayController(showsWindows: false)
        let actions: [PaceParsedAction] = [.showDiagram(try fixture())]
        var generation = controller.dismissalGeneration
        var playbackCalls = 0
        _ = await PaceVisualActionDrainer.drain(
            parseResult: .init(spokenText: "Old response", actions: actions, executionPlan: .serial(actions: actions),
                               firstClickVisualisationLocation: nil),
            diagramOverlayController: controller, imageOverlayController: imageController,
            expectedDiagramDismissalGeneration: &generation,
            expectedImageDismissalGeneration: imageController.dismissalGeneration,
            isCurrentTurn: { false }, runLesson: { _ in playbackCalls += 1; return true })
        #expect(controller.document == nil)
        #expect(playbackCalls == 0)
    }

    @Test func leaseRevocationWhileAwaitingLessonRejectsLaterVisualInSamePlan() async throws {
        let controller = PaceDiagramOverlayController(showsWindows: false)
        let imageController = PaceImageOverlayController(showsWindows: false)
        let first = try fixture()
        let replacement = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: .liftSystem))
        let actions: [PaceParsedAction] = [.showDiagram(first), .showDiagram(replacement)]
        var callerIsCurrent = true
        let gate = SpeechGate()
        let drain = Task {
            var generation = controller.dismissalGeneration
            return await PaceVisualActionDrainer.drain(
                parseResult: .init(spokenText: "", actions: actions, executionPlan: .serial(actions: actions),
                                   firstClickVisualisationLocation: nil),
                diagramOverlayController: controller, imageOverlayController: imageController,
                expectedDiagramDismissalGeneration: &generation,
                expectedImageDismissalGeneration: imageController.dismissalGeneration,
                isCurrentTurn: { callerIsCurrent },
                runLesson: { _ in await controller.runLesson(muted: false, stopSpeech: gate.stop, narrate: gate.narrate); return true })
        }
        try await waitUntil { gate.waiter != nil }
        callerIsCurrent = false
        controller.pauseLesson()
        _ = await drain.value
        #expect(controller.document?.title == first.title)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_SPEED_EXPORT_PROMPT"] != nil))
    func exportTeachingSpeedBaselinePromptWhenRequested() throws {
        let outputPath = try #require(ProcessInfo.processInfo.environment["PACE_SPEED_EXPORT_PROMPT"])
        let prompt = CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true)
        try prompt.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    private func compactArguments(for template: PaceFigureScene.Template) -> [String: PaceMCPJSONValue] {
        ["title": .string("An authored title"), "summary": .string("An authored summary"),
         "figure": .object(["template": .string(template.rawValue)])]
    }

    private func encodedArguments(_ document: PaceDiagramDocument) throws -> [String: PaceMCPJSONValue] {
        try JSONDecoder().decode([String: PaceMCPJSONValue].self, from: JSONEncoder().encode(document))
    }

    private func plannerEnvelope(arguments: [String: PaceMCPJSONValue], multipleCalls: Bool = false) throws -> String {
        let call: PaceMCPJSONValue = .object(["name": .string("show_diagram"), "args": .object(arguments)])
        let envelope: [String: PaceMCPJSONValue] = [
            "spokenText": .string(""), "intent": .string("action"),
            "payload": multipleCalls ? .object(["calls": .array([call])]) : call]
        return String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    }

    @Test func compactTrustedTemplatesRetainDetailedPartsAndAuthoredLessonsThroughTheActionParser() throws {
        for definition in PaceTeachingTemplateCatalog.definitions {
            let authored = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: definition.template))
            var arguments = compactArguments(for: definition.template)
            arguments["lesson"] = try encodedArguments(authored)["lesson"]
            for wrapped in [false, true] {
                let suppliedArguments = wrapped ? ["document": PaceMCPJSONValue.object(arguments)] : arguments
                let document = try #require(PaceDiagramDocument.parse(arguments: suppliedArguments))
                #expect(document.nodes == authored.nodes)
                #expect(document.connections.isEmpty)
                #expect(document.title == "An authored title")
                #expect(document.summary == "An authored summary")
                #expect(document.lesson == authored.lesson)
                for multipleCalls in [false, true] {
                    let parsed = PaceActionTagParser.parseActions(
                        from: try plannerEnvelope(arguments: suppliedArguments, multipleCalls: multipleCalls))
                    try #require(parsed.actions.count == 1)
                    guard case .showDiagram(let parsedDocument) = parsed.actions[0] else {
                        Issue.record("Expected a compact native teaching figure")
                        continue
                    }
                    #expect(parsedDocument == document)
                    let controller = PaceDiagramOverlayController(showsWindows: false)
                    #expect(controller.present(parsedDocument))
                    #expect(controller.currentLessonStep == authored.lesson?.steps.first)
                    #expect(controller.selectedNodeID == authored.lesson?.steps.first?.focusNodeID)
                }
            }
            #expect(PaceDiagramDocument.parse(arguments: compactArguments(for: definition.template))?.lesson == nil)
        }
    }

    @Test func compactDefaultsNeverReplaceExplicitPartTextOrMalformedFields() throws {
        for definition in PaceTeachingTemplateCatalog.definitions {
            let authored = try #require(PaceTeachingTemplateCatalog.lessonDocument(for: definition.template))
            var fullArguments = try encodedArguments(authored)
            #expect(PaceDiagramDocument.parse(arguments: fullArguments) == authored)
            guard case .array(var nodes) = fullArguments["nodes"],
                  case .object(var firstNode) = nodes.first else {
                Issue.record("Expected authored template nodes")
                continue
            }
            firstNode["label"] = .string("My assembly label")
            firstNode["detail"] = .string("My intentional assembly explanation.")
            firstNode["subtitle"] = .string("My subtitle")
            nodes[0] = .object(firstNode)
            fullArguments["nodes"] = .array(nodes)
            let explicitDocument = try #require(PaceDiagramDocument.parse(arguments: fullArguments))
            #expect(explicitDocument.nodes.first?.label == "My assembly label")
            #expect(explicitDocument.nodes.first?.detail == "My intentional assembly explanation.")
            #expect(explicitDocument.nodes.first?.subtitle == "My subtitle")
            #expect(explicitDocument.lesson == authored.lesson)
            fullArguments.removeValue(forKey: "connections")
            #expect(PaceDiagramDocument.parse(arguments: fullArguments) == explicitDocument)
            for invalidNodes: PaceMCPJSONValue in [.null, .array([]), .object([:]), .string("catalog"), .array([.null]), .array(Array(nodes.dropLast()))] {
                var arguments = compactArguments(for: definition.template)
                arguments["nodes"] = invalidNodes
                #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
            }
            for invalidConnections: PaceMCPJSONValue in [.null, .object([:]), .string("none"), .array([.null]),
                .array([.object(["source": .string("unknown"), "target": .string("missing")])])] {
                var arguments = compactArguments(for: definition.template)
                arguments["connections"] = invalidConnections
                #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
            }
            for field in ["title", "summary"] {
                for invalidText: PaceMCPJSONValue in [.null, .string(""), .string(String(repeating: "x", count: 501)), .number(1)] {
                    var arguments = compactArguments(for: definition.template)
                    arguments[field] = invalidText
                    #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
                }
            }
        }
    }

    @Test func compactTemplatesRejectUnknownReferencesMixedGeometryAndOversizedPayloads() throws {
        let template = PaceFigureScene.Template.liftSystem
        let invalidFigures: [PaceMCPJSONValue] = [
            .object(["template": .string("unknown")]), .object(["template": .string("airplane")]),
            .object(["parts": .array([])]),
            .object(["template": .string(template.rawValue), "focusNodeID": .string("unknown")]),
            .object(["template": .string(template.rawValue), "parts": .array([.object([
                "id": .string("custom"), "nodeID": .string("engine"), "geometry": .string("box"),
                "position": .array([.number(0), .number(0), .number(0)]),
                "size": .array([.number(1), .number(1), .number(1)])])])])]
        for figure in invalidFigures {
            var arguments = compactArguments(for: template)
            arguments["figure"] = figure
            #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
        }
        var arguments = compactArguments(for: template)
        arguments["illustration"] = .object(["rows": .array([])])
        #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
        arguments = compactArguments(for: template)
        arguments.removeValue(forKey: "figure")
        #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
        arguments = compactArguments(for: template)
        arguments["lesson"] = .object(["steps": .array([.object([
            "id": .string("unknown"), "title": .string("Unknown"), "narration": .string("An authored narration."),
            "revealedNodeIDs": .array([.string("unknown")]), "focusNodeID": .string("unknown")])])])
        #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
        arguments = compactArguments(for: template)
        arguments["padding"] = .string(String(repeating: "x", count: 64_000))
        #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
        arguments["padding"] = .string(String(repeating: "x", count: 63_000))
        #expect(try JSONEncoder().encode(arguments).count < 64_000)
        #expect(PaceDiagramDocument.parse(arguments: arguments) == nil)
        let example = try #require(PaceToolRegistry.definition(forToolName: "show_diagram")?.schemaExample)
        let parsed = PaceActionTagParser.parseActions(from: example)
        try #require(parsed.actions.count == 1)
        guard case .showDiagram(let document) = parsed.actions[0] else {
            Issue.record("The compact registry example must present its teaching figure")
            return
        }
        #expect(document.figure?.template == template)
        #expect(document.nodes == PaceTeachingTemplateCatalog.liftSystem.nodes)
        #expect(document.lesson?.steps.count == 2)
    }

    @Test func fullGenericAndCompactCatalogPromptExamplesBothParse() throws {
        let examples = [PaceTeachingPower.genericDiagramExample,
                        try #require(PaceToolRegistry.definition(forToolName: "show_diagram")?.schemaExample)]
        for (index, example) in examples.enumerated() {
            let parsed = PaceActionTagParser.parseActions(from: example)
            try #require(parsed.actions.count == 1)
            guard case .showDiagram(let document) = parsed.actions[0] else {
                Issue.record("Prompt example must produce a valid diagram")
                continue
            }
            #expect(document.validationIssue == nil)
            #expect(PaceTeachingPower.diagramRules.contains(example))
            if index == 0 {
                #expect(document.figure == nil && document.illustration == nil)
                #expect(Set(document.nodes.map(\.id)) == ["vapor", "droplets"])
                #expect(document.connections.count == 1)
            } else {
                #expect(document.figure?.template == .liftSystem)
                #expect(document.nodes == PaceTeachingTemplateCatalog.liftSystem.nodes)
            }
        }
        #expect(PaceToolRegistry.definition(forToolName: "show_diagram")?.exampleUtterance == "explain how the F-35B hovers")
    }

    private func generalTeachingValidityReasons(_ text: String, expectsAirplane: Bool) -> [String] {
        let parsed = PaceActionTagParser.parseActions(from: text)
        guard parsed.actions.count == 1, parsed.executionPlan.flattenedActions.count == 1,
              case .showDiagram(let document) = parsed.actions[0] else {
            return ["Expected exactly one valid show_diagram action"]
        }
        var reasons: [String] = []
        if let issue = document.validationIssue { reasons.append(issue) }
        if document.nodes.contains(where: { $0.detail.count < 20 }) { reasons.append("Every stage or part needs a useful explanation") }
        if expectsAirplane {
            if document.figure?.template != .airplane { reasons.append("Expected generic airplane template") }
            if Set(document.nodes.map(\.id)) != ["fuselage", "cockpit", "wings", "engines", "ailerons", "elevators", "rudder", "flaps"] {
                reasons.append("Expected all eight airplane explanation nodes")
            }
        } else {
            if document.figure != nil || document.illustration != nil { reasons.append("Expected a 2D flowchart") }
            let labels = document.nodes.map { $0.label.lowercased() }
            if labels.count != 4 || ["evaporation", "condensation", "precipitation", "collection"].contains(where: { stage in !labels.contains(where: { $0.contains(stage) }) }) {
                reasons.append("Expected four named water-cycle stages")
            }
            if document.connections.count < 3 { reasons.append("Expected connected process stages") }
        }
        return reasons
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_SPEED_GENERAL_RESULT_PATH"] != nil))
    func probeNoncatalogTeachingWhenRequested() async throws {
        let resultPath = try #require(ProcessInfo.processInfo.environment["PACE_SPEED_GENERAL_RESULT_PATH"])
        let systemPrompt = CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true)
        let requests = ["Show a generic rotatable passenger airplane and explain its eight physical parts using the airplane template.",
                        "Show an explicit 2D water-cycle flowchart with four named useful stages: evaporation, condensation, precipitation and collection."]
        var samples: [[String: Any]] = []
        func save() throws {
            let report: [String: Any] = ["systemPrompt": systemPrompt, "model": "cli_default",
                "requestTimeoutSeconds": 45, "samples": samples]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        }
        try save()
        for (index, request) in requests.enumerated() {
            var sample: [String: Any] = ["userRequest": request]
            var rawResponse = ""
            do {
                let planner = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil, requestTimeout: 45)
                let response = try await planner.generateResponseStreaming(images: [], systemPrompt: systemPrompt,
                    conversationHistory: [], userPrompt: request, onTextChunk: { rawResponse = $0 })
                rawResponse = response.text
            } catch is CancellationError { throw CancellationError() }
            catch { sample["error"] = String(describing: error) }
            let reasons = generalTeachingValidityReasons(rawResponse, expectsAirplane: index == 0)
            sample["rawResponse"] = rawResponse
            sample["validityReasons"] = reasons
            samples.append(sample)
            try save()
            #expect(sample["error"] == nil && reasons.isEmpty, "General teaching results are recorded in the private probe report")
        }
    }

    private struct TeachingSpeedCondition {
        let name: String
        let prompt: String
        var modelIdentifier: String? = nil
        var reasoningEffort: PaceCodexReasoningEffort? = nil
        var completionPolicy: PaceCodexCompletionPolicy = .processExit
        var requiresExplicitNodesAndConnections: Bool = false
    }

    private struct TeachingSpeedSample: Encodable {
        let round: Int
        let order: Int
        let condition: String
        let model: String
        let effort: String
        let completionPolicy: String
        let systemPromptBytes: Int
        let startedAt: Date
        var firstCompletedMessageMilliseconds: Double?
        var firstValidCompletedMessageMilliseconds: Double?
        var fullReturnMilliseconds: Double = 0
        var outputBytes: Int = 0
        var rawResponse: String = ""
        var completedMessages: [String] = []
        var validityReasons: [String] = []
        var error: String?
    }

    private struct TeachingSpeedReport: Encodable {
        let userRequest: String
        let baselinePrompt: String
        let compactPrompt: String
        let requestTimeoutSeconds: Double
        var samples: [TeachingSpeedSample] = []
        var invalidOutputCount: Int { samples.filter { !$0.validityReasons.isEmpty }.count }
        var errorCount: Int { samples.filter { $0.error != nil }.count }

        private enum CodingKeys: String, CodingKey {
            case userRequest, baselinePrompt, compactPrompt, requestTimeoutSeconds, samples, invalidOutputCount, errorCount
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userRequest, forKey: .userRequest)
            try values.encode(baselinePrompt, forKey: .baselinePrompt)
            try values.encode(compactPrompt, forKey: .compactPrompt)
            try values.encode(requestTimeoutSeconds, forKey: .requestTimeoutSeconds)
            try values.encode(samples, forKey: .samples)
            try values.encode(invalidOutputCount, forKey: .invalidOutputCount)
            try values.encode(errorCount, forKey: .errorCount)
        }
    }

    private func teachingSpeedValidityReasons(
        _ text: String, requiresExplicitNodesAndConnections: Bool
    ) -> [String] {
        guard let envelope = try? JSONDecoder().decode([String: PaceMCPJSONValue].self, from: Data(text.utf8)),
              envelope["intent"] == .string("action") else {
            return ["Expected one action JSON envelope"]
        }
        if requiresExplicitNodesAndConnections {
            guard case .object(let payload) = envelope["payload"] else {
                return ["Baseline requires explicit diagram arguments"]
            }
            let calls: [PaceMCPJSONValue]
            if case .array(let payloadCalls) = payload["calls"] { calls = payloadCalls }
            else { calls = [.object(payload)] }
            guard calls.count == 1, case .object(let call) = calls[0],
                  case .object(var arguments) = call["args"] else {
                return ["Baseline requires one explicit diagram argument object"]
            }
            if case .object(let documentArguments) = arguments["document"] { arguments = documentArguments }
            guard arguments["nodes"] != nil, arguments["connections"] != nil else {
                return ["Baseline contract requires explicit nodes and connections"]
            }
        }
        let parsed = PaceActionTagParser.parseActions(from: text)
        guard parsed.actions.count == 1, parsed.executionPlan.flattenedActions.count == 1,
              case .showDiagram(let document) = parsed.actions[0] else {
            return ["Expected exactly one valid show_diagram action"]
        }
        var reasons: [String] = []
        if !parsed.spokenText.isEmpty { reasons.append("Outer speech duplicates guided narration") }
        if let issue = document.validationIssue { reasons.append(issue) }
        if document.figure?.template != .liftSystem { reasons.append("Expected lift_system template") }
        let definition = PaceTeachingTemplateCatalog.liftSystem
        if Set(document.nodes.map(\.id)) != definition.nodeIDs { reasons.append("Missing canonical teaching parts") }
        if definition.parts.count < 90 { reasons.append("Detailed native geometry is missing") }
        guard let steps = document.lesson?.steps, steps.count == 2 else {
            return reasons + ["Expected two authored lesson steps"]
        }
        for step in steps {
            if step.focusNodeID == nil { reasons.append("Each lesson step must highlight its explained part") }
            if step.narration.count > 200 || step.narration.contains("\n") {
                reasons.append("Narration must be one brief sentence")
            }
            let sentenceEndings = (try? NSRegularExpression(pattern: #"[.!?](?:\s|$)"#))?
                .numberOfMatches(in: step.narration, range: NSRange(step.narration.startIndex..., in: step.narration)) ?? 0
            if sentenceEndings > 1 { reasons.append("Narration contains more than one sentence") }
        }
        let controller = PaceDiagramOverlayController(showsWindows: false)
        if !controller.present(document) { reasons.append("Controller rejected the teaching document") }
        if controller.currentLessonStep != steps.first || controller.selectedNodeID != steps.first?.focusNodeID {
            reasons.append("First lesson snapshot did not highlight its authored part")
        }
        controller.moveLesson(by: 1)
        if controller.currentLessonStep != steps.last || controller.selectedNodeID != steps.last?.focusNodeID {
            reasons.append("Second lesson snapshot did not highlight its authored part")
        }
        controller.dismiss()
        return reasons
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_SPEED_BASELINE_PROMPT"] != nil))
    func benchmarkTeachingPlannerWhenRequested() async throws {
        let baselinePath = try #require(ProcessInfo.processInfo.environment["PACE_SPEED_BASELINE_PROMPT"])
        let resultPath = try #require(ProcessInfo.processInfo.environment["PACE_SPEED_RESULT_PATH"])
        try #require(baselinePath != resultPath)
        let baselinePrompt = try String(contentsOfFile: baselinePath, encoding: .utf8)
        let compactPrompt = CompanionSystemPrompt.buildTextOnly(includeInteractiveDiagrams: true)
        let userRequest = "Explain how the F-35B hovers using the lift_system template and a two-step guided lesson. Keep each narration to one brief sentence. Show the diagram first and highlight the part being explained."
        let availableConditions = [
            TeachingSpeedCondition(name: "baseline-default", prompt: baselinePrompt,
                                   requiresExplicitNodesAndConnections: true),
            TeachingSpeedCondition(name: "compact-default", prompt: compactPrompt),
            TeachingSpeedCondition(name: "compact-sealed", prompt: compactPrompt,
                                   completionPolicy: .completedTurn),
            TeachingSpeedCondition(name: "compact-luna-sealed", prompt: compactPrompt,
                                   modelIdentifier: "gpt-6-luna", reasoningEffort: .low,
                                   completionPolicy: .completedTurn)]
        let conditions = ProcessInfo.processInfo.environment["PACE_SPEED_PAIR_ONLY"] == "1"
            ? availableConditions.filter { ["baseline-default", "compact-sealed"].contains($0.name) }
            : availableConditions
        var report = TeachingSpeedReport(userRequest: userRequest, baselinePrompt: baselinePrompt,
                                        compactPrompt: compactPrompt, requestTimeoutSeconds: 45)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let resultURL = URL(fileURLWithPath: resultPath)
        try encoder.encode(report).write(to: resultURL, options: .atomic)
        for round in 0..<5 {
            for order in conditions.indices {
                let condition = conditions[(round + order) % conditions.count]
                var sample = TeachingSpeedSample(round: round + 1, order: order + 1,
                    condition: condition.name, model: condition.modelIdentifier ?? "cli_default",
                    effort: condition.reasoningEffort?.rawValue ?? "cli_default",
                    completionPolicy: condition.completionPolicy == .completedTurn ? "completed_turn" : "process_exit",
                    systemPromptBytes: condition.prompt.utf8.count, startedAt: Date())
                let planner = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: condition.modelIdentifier,
                    codexReasoningEffort: condition.reasoningEffort, requestTimeout: report.requestTimeoutSeconds,
                    codexCompletionPolicy: condition.completionPolicy)
                let startedAt = ProcessInfo.processInfo.systemUptime
                do {
                    let response = try await planner.generateResponseStreaming(images: [],
                        systemPrompt: condition.prompt, conversationHistory: [], userPrompt: userRequest,
                        onTextChunk: { text in
                            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                            sample.completedMessages.append(text)
                            if sample.firstCompletedMessageMilliseconds == nil {
                                sample.firstCompletedMessageMilliseconds = elapsed
                            }
                            if sample.firstValidCompletedMessageMilliseconds == nil,
                               teachingSpeedValidityReasons(text,
                                requiresExplicitNodesAndConnections: condition.requiresExplicitNodesAndConnections).isEmpty {
                                sample.firstValidCompletedMessageMilliseconds = elapsed
                            }
                        })
                    sample.fullReturnMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    sample.rawResponse = response.text
                    sample.outputBytes = response.text.utf8.count
                    sample.validityReasons = teachingSpeedValidityReasons(response.text,
                        requiresExplicitNodesAndConnections: condition.requiresExplicitNodesAndConnections)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    sample.fullReturnMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    sample.rawResponse = sample.completedMessages.joined()
                    sample.outputBytes = sample.rawResponse.utf8.count
                    sample.error = String(describing: error)
                    sample.validityReasons = teachingSpeedValidityReasons(sample.rawResponse,
                        requiresExplicitNodesAndConnections: condition.requiresExplicitNodesAndConnections)
                }
                report.samples.append(sample)
                try encoder.encode(report).write(to: resultURL, options: .atomic)
            }
        }
        #expect(report.errorCount == 0, "Planner errors are recorded in the private benchmark result")
        #expect(report.invalidOutputCount == 0, "Invalid teaching outputs are recorded in the private benchmark result")
    }

}
