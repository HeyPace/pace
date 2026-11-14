import Foundation

nonisolated enum PacePowerPermission: String {
    case microphone, speechRecognition, screenRecording, accessibility
    case calendar, reminders, contacts, offDevicePlanning, externalTools
}

nonisolated enum PacePowerTurnKind {
    case screen, textOnly, research
}

nonisolated struct PacePowerPromptContext {
    let turnKind: PacePowerTurnKind
    var includeAgentMode = false
    var isTuitionModeEnabled = false
    var includeInteractiveDiagrams = false
}

nonisolated struct PacePowerPromptContribution {
    let order: Int
    let applies: @Sendable (PacePowerPromptContext) -> Bool
    let render: @MainActor @Sendable (PacePowerCatalog) -> String
}

nonisolated struct PacePowerDefinition: Identifiable {
    let identifier: String
    let title: String
    let summary: String
    /// Disclosure metadata only. The existing per-operation permission and consent gates remain authoritative.
    let permissionsUsed: [PacePowerPermission]
    let tools: [PaceLocalToolDefinition]
    let promptContributions: [PacePowerPromptContribution]

    var id: String { identifier }
}

nonisolated struct PacePowerCatalog {
    static let preinstalled = PacePowerCatalog(powers: [
        PaceTextPower.definition,
        PaceVoicePower.definition,
        PaceScreenPower.definition,
        PaceComputerUsePower.definition,
        PaceTeachingPower.definition,
        PaceImagesPower.definition,
        PaceResearchPower.definition,
        PaceProductivityPower.definition,
        PaceAutomationPower.definition,
        PaceIntegrationPower.definition,
        PaceCodingPower.definition,
    ])

    let powers: [PacePowerDefinition]

    var tools: [PaceLocalToolDefinition] {
        let kindOrder = Dictionary(uniqueKeysWithValues: PaceLocalToolKind.allCases.enumerated().map {
            ($0.element, $0.offset)
        })
        // Keep the established planner order independent of how powers are grouped on disk.
        return powers.flatMap(\.tools).sorted {
            kindOrder[$0.kind, default: 0] < kindOrder[$1.kind, default: 0]
        }
    }

    func owner(of toolKind: PaceLocalToolKind) -> PacePowerDefinition? {
        powers.first { $0.tools.contains { $0.kind == toolKind } }
    }

    @MainActor
    func prompt(for context: PacePowerPromptContext) -> String {
        powers.flatMap(\.promptContributions).enumerated()
            .filter { $0.element.applies(context) }
            .sorted {
                $0.element.order == $1.element.order
                    ? $0.offset < $1.offset
                    : $0.element.order < $1.element.order
            }
            .map { $0.element.render(self) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func validationIssues() -> [String] {
        var issues: [String] = []
        var identifiers: Set<String> = []
        var owners: [PaceLocalToolKind: String] = [:]
        for power in powers {
            if power.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("empty power identifier")
            }
            if !identifiers.insert(power.identifier).inserted {
                issues.append("duplicate power identifier \(power.identifier)")
            }
            if power.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || power.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(power.identifier) needs a title and summary")
            }
            for tool in power.tools {
                if let previousOwner = owners.updateValue(power.identifier, forKey: tool.kind) {
                    issues.append("\(tool.canonicalName) is owned by both \(previousOwner) and \(power.identifier)")
                }
            }
        }
        return issues
    }
}
