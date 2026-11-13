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

}
