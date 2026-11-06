import Foundation
import Testing

@testable import Pace

struct PacePowerCatalogTests {
    @Test func preinstalledPowersHaveUniqueOwnersForEveryExistingTool() {
        let catalog = PacePowerCatalog.preinstalled
        #expect(catalog.validationIssues().isEmpty)
        #expect(Set(catalog.tools.map(\.kind)) == Set(PaceLocalToolKind.allCases))
        for kind in PaceLocalToolKind.allCases {
            #expect(catalog.powers.filter { $0.tools.contains { $0.kind == kind } }.count == 1)
            #expect(catalog.owner(of: kind) != nil)
        }
        #expect(catalog.powers.contains { $0.id == "pace.text" })
        #expect(catalog.powers.contains { $0.id == "pace.voice" })
    }

    @Test func teachingOwnsOnlyOverlayToolsAndImagesHaveTheirOwnOwner() {
        let teaching = PaceTeachingPower.definition
        #expect(Set(teaching.tools.map(\.kind)) == [.showDiagram, .dismissDiagram, .drawAnnotation, .clearAnnotations])
        #expect(teaching.tools.allSatisfy { $0.riskLevel == .readOnly })
        #expect(PacePowerCatalog.preinstalled.owner(of: .generateImage)?.id == "pace.images")
        #expect(PacePowerCatalog.preinstalled.owner(of: .click)?.id == "pace.computer")
    }

    @MainActor @Test func providerContributionIsReachableWithoutChangingThePromptAssembler() {
        let additionalPower = PacePowerDefinition(
            identifier: "example.walkthrough", title: "Walkthrough", summary: "A bounded test power.",
            permissionsUsed: [], tools: [],
            promptContributions: [
                .init(order: 50, applies: { $0.isTuitionModeEnabled }, render: { _ in "Explain the current step." })
            ]
        )
        let catalog = PacePowerCatalog(powers: [additionalPower])
        #expect(catalog.prompt(for: .init(turnKind: .screen)).isEmpty)
        #expect(catalog.prompt(for: .init(turnKind: .screen, isTuitionModeEnabled: true)) == "Explain the current step.")
        #expect(catalog.tools.isEmpty)
    }

    @MainActor @Test func screenlessAnswersDoNotLoadScreenOrComputerInstructions() {
        let prompt = CompanionSystemPrompt.buildTextOnly()
        #expect(prompt.contains(PaceTextPower.conversationRules))
        #expect(prompt.contains(PaceVoicePower.responseRules))
        #expect(!prompt.contains(PaceTeachingPower.pointingRules))
        #expect(!prompt.contains("available tools:"))
        #expect(!prompt.contains("show_diagram"))
    }

    @MainActor @Test func teachingContextComposesWithExistingActionGates() {
        let prompt = CompanionSystemPrompt.build(
            includeAgentMode: true, isTuitionModeEnabled: true, includeInteractiveDiagrams: true)
        #expect(prompt.contains(PaceTeachingPower.tuitionModeRules))
        #expect(prompt.contains(PaceTeachingPower.diagramRules))
        #expect(prompt.contains("do NOT emit click"))
        let readOnlyPrompt = CompanionSystemPrompt.build(includeAgentMode: false, includeInteractiveDiagrams: true)
        #expect(readOnlyPrompt.contains("show_diagram"))
        #expect(!readOnlyPrompt.contains("available tools:"))
        #expect(!readOnlyPrompt.contains("- {\"tool\":\"click\""))
    }

    @MainActor @Test func omittingAnImageProviderOmitsItsToolAndInstructions() {
        let catalog = PacePowerCatalog(powers: [PaceComputerUsePower.definition, PaceTeachingPower.definition])
        let prompt = catalog.prompt(for: .init(
            turnKind: .screen, includeAgentMode: true, includeInteractiveDiagrams: true))
        #expect(prompt.contains("show_diagram"))
        #expect(prompt.contains("- {\"tool\":\"click\""))
        #expect(!prompt.contains("generate_image"))
        #expect(!prompt.contains("Image generation uses the selected"))
    }

    @MainActor @Test func physicalTeachingGuidanceDoesNotDependOnTheImagesPower() {
        let catalog = PacePowerCatalog(powers: [PaceTeachingPower.definition])
        for turnKind in [PacePowerTurnKind.screen, .textOnly, .research] {
            let prompt = catalog.prompt(for: .init(turnKind: turnKind, includeInteractiveDiagrams: true))
            #expect(prompt.contains("For a physical object, prefer a detailed rotatable 3D figure"))
            #expect(prompt.contains("do not substitute a flowchart of labels for a requested airplane"))
            #expect(!prompt.contains("generate_image"))
        }
        #expect(!PaceImagesPower.imageRules.contains("For a physical object"))
        #expect(!PaceImagesPower.imageRules.contains("Never speak JSON"))
        let readOnlyPrompt = CompanionSystemPrompt.build(includeAgentMode: false, includeInteractiveDiagrams: true)
        #expect(readOnlyPrompt.contains("generate_image remains available when desktop actions and screen reading are off"))
        #expect(readOnlyPrompt.contains("the existing Codex consent requirement still applies"))
        let combinedPrompt = CompanionSystemPrompt.build(includeAgentMode: true, includeInteractiveDiagrams: true)
        #expect(combinedPrompt.components(separatedBy: "Never speak JSON or claim a figure is visible").count == 2)
    }

    @Test func duplicatePowerAndToolOwnershipAreRejectedAtStartup() {
        let catalog = PacePowerCatalog(powers: [PaceTeachingPower.definition, PaceTeachingPower.definition])
        let issues = catalog.validationIssues()
        #expect(issues.contains { $0.contains("duplicate power identifier") })
        #expect(issues.contains { $0.contains("owned by both") })
    }
}
