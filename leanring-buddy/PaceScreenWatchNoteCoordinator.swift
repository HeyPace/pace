import Foundation

@MainActor
final class PaceScreenWatchNoteCoordinator {
    private struct PendingObservation {
        let observation: PaceScreenWatchObservation
        let sourceRevision: UInt64
    }

    private let now: () -> Date
    private let isEligible: (PaceScreenWatchObservation) -> Bool
    private let sourceRevision: () -> UInt64
    private let recognizeText: (PaceScreenWatchObservation) async throws -> [RecognizedTextBox]
    private let persist: (PaceScreenWatchObservation, String) -> Void
    private var pendingObservation: PendingObservation?
    private var currentScene: PaceScreenSceneIdentity?
    private var epoch: UInt64 = 0
    private var lastAttemptAt: Date?
    private var recognitionTask: Task<Void, Never>?
    private var hasReportedDelayedRecognition = false
    private let onDelayedRecognition: () -> Void

    init(now: @escaping () -> Date = Date.init,
         isEligible: @escaping (PaceScreenWatchObservation) -> Bool,
         sourceRevision: @escaping () -> UInt64,
         recognizeText: @escaping (PaceScreenWatchObservation) async throws -> [RecognizedTextBox],
         persist: @escaping (PaceScreenWatchObservation, String) -> Void,
         onDelayedRecognition: @escaping () -> Void = {}) {
        self.now = now
        self.isEligible = isEligible
        self.sourceRevision = sourceRevision
        self.recognizeText = recognizeText
        self.persist = persist
        self.onDelayedRecognition = onDelayedRecognition
    }

    func observe(_ observation: PaceScreenWatchObservation) {
        if recognitionTask != nil, !hasReportedDelayedRecognition,
           let lastAttemptAt, now().timeIntervalSince(lastAttemptAt) > 12 {
            hasReportedDelayedRecognition = true
            onDelayedRecognition()
        }
        guard isEligible(observation) else { return }
        if currentScene != observation.sceneIdentity {
            invalidate()
            currentScene = observation.sceneIdentity
        }
        pendingObservation = PendingObservation(observation: observation, sourceRevision: sourceRevision())
        startPendingObservationIfDue()
    }

    func invalidate() {
        epoch &+= 1
        pendingObservation = nil
        currentScene = nil
        recognitionTask?.cancel()
        // Cancellation revokes the result. Vision may still be working, so only
        // its actual completion can release this slot or advance the queue.
    }

    private func startPendingObservationIfDue() {
        guard recognitionTask == nil, let pendingObservation,
              pendingObservation.sourceRevision == sourceRevision(),
              isFresh(pendingObservation.observation), isEligible(pendingObservation.observation),
              lastAttemptAt.map({ now().timeIntervalSince($0) >= 30 }) ?? true else { return }
        self.pendingObservation = nil
        lastAttemptAt = now()
        hasReportedDelayedRecognition = false
        let attemptEpoch = epoch
        let observation = pendingObservation.observation
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                recognitionTask = nil
                startPendingObservationIfDue()
            }
            do {
                let boxes = try await recognizeText(observation)
                let excerpt = PaceScreenWatchNoteText.excerpt(from: boxes,
                    screenshotHeightInPixels: observation.capture.screenshotHeightInPixels)
                guard let excerpt, !Task.isCancelled,
                      pendingObservation.sourceRevision == sourceRevision(),
                      isFresh(observation), isEligible(observation), epoch == attemptEpoch else { return }
                persist(observation, excerpt)
            } catch {
                // A failure consumes the same global attempt budget as a success.
            }
        }
    }

    private func isFresh(_ observation: PaceScreenWatchObservation) -> Bool {
        (0...12).contains(now().timeIntervalSince(observation.observedAt))
    }
}

nonisolated enum PaceScreenWatchNoteText {
    static func excerpt(from boxes: [RecognizedTextBox], screenshotHeightInPixels: Int) -> String? {
        let hasSensitiveLabel = boxes.contains { PaceScreenSuggestionBoundary.containsSensitiveOCRLabel($0.text) }
        guard !hasSensitiveLabel else { return nil }
        let positionedBoxes = boxes.filter { $0.pixelBoundingBox.count == 4 && !$0.text.isEmpty }
        // Exclude the menu/tab/address strip only when a useful body exists.
        // Geometry is deliberately conservative and makes no claim about tasks.
        let contentBoxes = positionedBoxes.filter {
            $0.pixelBoundingBox[1] >= max(80, Int(Double(screenshotHeightInPixels) * 0.12))
        }
        let selectedBoxes = contentBoxes.contains(where: { $0.text.count >= 20 }) ? contentBoxes : positionedBoxes
        let orderedBoxes = selectedBoxes.sorted {
            if $0.pixelBoundingBox[1] != $1.pixelBoundingBox[1] {
                return $0.pixelBoundingBox[1] < $1.pixelBoundingBox[1]
            }
            if $0.pixelBoundingBox[0] != $1.pixelBoundingBox[0] {
                return $0.pixelBoundingBox[0] < $1.pixelBoundingBox[0]
            }
            return $0.text < $1.text
        }
        let redactedText = PaceScreenSuggestionBoundary.redactedOCR(orderedBoxes.map(\.text).joined(separator: "\n"))
        let meaningfulLines = redactedText.components(separatedBy: .newlines).filter {
            let visibleText = $0.replacingOccurrences(of: "[redacted]", with: "")
            return visibleText.contains(where: { $0.isLetter || $0.isNumber })
        }
        let collapsedText = meaningfulLines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsedText.count >= 12 else { return nil }
        return String(collapsedText.prefix(PaceScreenWatchJournal.maximumScreenDescriptionCharacterCount))
    }
}
