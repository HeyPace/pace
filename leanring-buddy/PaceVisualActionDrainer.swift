import Foundation

@MainActor
enum PaceVisualActionDrainer {
    static func drain(
        parseResult: PaceActionTagParseResult,
        diagramOverlayController: PaceDiagramOverlayController,
        imageOverlayController: PaceImageOverlayController,
        expectedDiagramDismissalGeneration: inout Int,
        expectedImageDismissalGeneration: Int,
        isCurrentTurn: @MainActor () -> Bool = { true },
        runLesson: (@MainActor (PaceDiagramDocument) async -> Bool)? = nil,
        generateImage: (@MainActor (PaceImageGenerationRequest, Int) async -> String)? = nil
    ) async -> PaceActionTagParseResult {
        var teachingDelivery: PaceTeachingDelivery?
        var imageMessages: [String] = []
        var spokenText = parseResult.spokenText
        var remainingSteps: [PaceActionExecutionStep] = []
        for step in parseResult.executionPlan.steps {
            var remainingActions: [PaceParsedAction] = []
            for action in step.actions {
                let permitsVisualOutput = !Task.isCancelled && isCurrentTurn()
                    && expectedDiagramDismissalGeneration == diagramOverlayController.dismissalGeneration
                    && expectedImageDismissalGeneration == imageOverlayController.dismissalGeneration
                switch action {
                case .showDiagram, .dismissDiagram:
                    guard permitsVisualOutput else {
                        spokenText = diagramOverlayController.document == nil
                            ? "I kept the diagram closed." : "I kept the current diagram unchanged."
                        continue
                    }
                    let diagramResult = diagramOverlayController.drain(
                        parseResult: .init(
                            spokenText: spokenText, actions: [action], executionPlan: .serial(actions: [action]),
                            firstClickVisualisationLocation: nil),
                        expectedDismissalGeneration: &expectedDiagramDismissalGeneration)
                    spokenText = diagramResult.spokenText
                    if case .showDiagram(let document) = action, document.lesson != nil,
                       diagramOverlayController.document?.lesson == document.lesson,
                       diagramOverlayController.lessonNeedsInitialPlayback, let runLesson {
                        let handlesSpeech = await runLesson(document)
                        teachingDelivery = .init(handlesSpeech: handlesSpeech)
                        spokenText = [spokenText, document.lesson?.writtenExplanation ?? ""]
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
                    }
                case .generateImage(let request):
                    guard permitsVisualOutput else {
                        imageMessages.append("I kept the image closed.")
                        continue
                    }
                    // Keep the original leases across the await. User dismissal must
                    // revoke later visuals, while owned replacements preserve them.
                    let message: String
                    if let generateImage {
                        message = await generateImage(request, expectedImageDismissalGeneration)
                    } else {
                        message = await imageOverlayController.generate(
                            request, expectedDismissalGeneration: expectedImageDismissalGeneration)
                    }
                    imageMessages.append(message)
                default:
                    remainingActions.append(action)
                }
            }
            if !remainingActions.isEmpty { remainingSteps.append(.init(actions: remainingActions)) }
        }
        let remainingActions = parseResult.actions.filter { action in
            switch action {
            case .showDiagram, .dismissDiagram, .generateImage: return false
            default: return true
            }
        }
        let includesDiagram = parseResult.actions.contains {
            if case .showDiagram = $0 { return true }
            return false
        }
        return .init(
            spokenText: imageMessages.isEmpty
                ? spokenText
                : ((remainingActions.isEmpty && !includesDiagram ? [] : [spokenText]) + imageMessages).joined(separator: " "),
            actions: remainingActions,
            executionPlan: .init(steps: remainingSteps),
            firstClickVisualisationLocation: parseResult.firstClickVisualisationLocation,
            teachingDelivery: teachingDelivery)
    }
}
