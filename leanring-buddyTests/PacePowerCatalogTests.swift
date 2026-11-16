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

    @MainActor @Test func windowInventoryPromptSharesOnlyItsRequiredPowerInstructions() throws {
        let prompt = CompanionSystemPrompt.buildForWindowInventory()
        #expect(prompt.contains(PaceTextPower.conversationRules))
        #expect(prompt.contains(PaceVoicePower.responseRules))
        #expect(prompt.contains(PaceComputerUsePower.mcpActionProtocolRules))
        #expect(prompt.contains(PaceComputerUsePower.windowInventoryRules))
        for unrelatedInstruction in [
            "available tools:", "Draw.annotation", "show_diagram", "generate_image",
            "coding_session", "Mail.draft", "App.launch", "<conversation_so_far>",
            PaceComputerUsePower.desktopToolRecoveryGuidance,
        ] {
            #expect(!prompt.contains(unrelatedInstruction), "\(unrelatedInstruction)")
        }

        let normalPrompt = CompanionSystemPrompt.build(
            includeAgentMode: true, isTuitionModeEnabled: true, includeInteractiveDiagrams: true)
        #expect(!normalPrompt.contains(PaceComputerUsePower.mcpActionProtocolRules))
        #expect(normalPrompt.contains(PaceTeachingPower.tuitionModeRules))
        #expect(normalPrompt.contains("show_diagram"))
        #expect(normalPrompt.contains("coding_session"))
        #expect(normalPrompt.contains("Codex.session"))

        let examples = PaceComputerUsePower.mcpActionProtocolRules.split(separator: "\n")
            .filter { $0.hasPrefix("{\"spokenText\"") }
        #expect(examples.count == 2)
        var actionCounts: [Int] = []
        for example in examples {
            let parsed = PaceActionTagParser.parseActions(from: String(example))
            #expect(parsed.spokenText.isEmpty)
            actionCounts.append(parsed.executionPlan.flattenedActions.count)
            for action in parsed.executionPlan.flattenedActions {
                guard case .mcp(let call) = action else {
                    Issue.record("Shared MCP envelope did not parse as an MCP call")
                    continue
                }
                #expect(call.serverName == "peekaboo")
                #expect(call.toolName == "window")
                #expect(call.arguments["action"] == .string("list"))
            }
        }
        #expect(actionCounts == [1, 2])
    }

    @MainActor @Test func passiveScreenPromptKeepsGroundingAndMemoryWithoutActionOrVisualSchemas() throws {
        let threadSummary = "<conversation_so_far>We were reviewing the Pace project.</conversation_so_far>"
        let ambientContext = "Frontmost app: Xcode"
        let prompt = CompanionSystemPrompt.build(
            includeAgentMode: false,
            isTuitionModeEnabled: true,
            threadSummaryInjection: threadSummary,
            ambientContextInjection: ambientContext,
            usesIterativeComputerUse: false,
            includeInteractiveDiagrams: false)
        #expect(prompt.hasPrefix(threadSummary))
        #expect(prompt.contains(ambientContext))
        #expect(prompt.contains(PaceTextPower.conversationRules))
        #expect(prompt.contains(PaceVoicePower.responseRules))
        #expect(prompt.contains(PaceTeachingPower.pointingRules))
        #expect(!prompt.contains("available tools:"))
        #expect(!prompt.contains("Pace WILL call you again"))
        #expect(!prompt.contains(PaceTeachingPower.tuitionModeRules))
        #expect(!prompt.contains("show_diagram"))
        #expect(!prompt.contains("generate_image"))

        let fullPrompt = CompanionSystemPrompt.build(
            includeAgentMode: true,
            isTuitionModeEnabled: true,
            threadSummaryInjection: threadSummary,
            ambientContextInjection: ambientContext,
            usesIterativeComputerUse: true,
            includeInteractiveDiagrams: true)
        #expect(fullPrompt.contains("available tools:"))
        #expect(fullPrompt.contains("Pace WILL call you again"))
        #expect(fullPrompt.contains("show_diagram"))
        #expect(fullPrompt.contains("generate_image"))
        print("Screen prompt UTF-8 bytes: full=\(fullPrompt.utf8.count), passive=\(prompt.utf8.count)")
        if let exportPath = ProcessInfo.processInfo.environment["PACE_SCREEN_PROMPT_EXPORT_PATH"] {
            let data = try JSONSerialization.data(withJSONObject: ["full": fullPrompt, "passive": prompt])
            try data.write(to: URL(fileURLWithPath: exportPath), options: .atomic)
        }
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
