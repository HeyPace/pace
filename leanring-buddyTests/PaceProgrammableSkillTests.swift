//
//  PaceProgrammableSkillTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceProgramModelTests {
    @Test func programRoundTripsThroughTaggedJSON() throws {
        let program = makeProgram(nodes: [
            .condition(
                predicate: .weekdayIn([2, 3, 4, 5, 6]),
                thenNodes: [openApplicationNode("Notes")],
                otherwiseNodes: [
                    .repeatTimes(count: 2, nodes: [volumeNode("down")]),
                ]
            ),
        ])

        let encodedProgram = try JSONEncoder().encode(program)
        let decodedProgram = try JSONDecoder().decode(
            PaceProgramDefinition.self,
            from: encodedProgram
        )
        #expect(decodedProgram == program)
    }

    @Test func decoderRejectsFieldsThatDoNotBelongToNodeType() {
        let rawProgram = #"""
        {
          "schemaVersion": 1,
          "identifier": "invalid-extra-field",
          "name": "Invalid extra field",
          "description": "Invalid fixture.",
          "category": "test",
          "invocationPhrases": [],
          "requiredPreferences": [],
          "nodes": [{
            "type": "action",
            "step": {"toolCalls": [{"tool": "open_app", "arguments": {"app": "Notes"}}]},
            "count": 2
          }]
        }
        """#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                PaceProgramDefinition.self,
                from: Data(rawProgram.utf8)
            )
        }
    }

    @Test func validatorChecksActionsInInactiveBranches() {
        let invalidNode = PaceProgramNode.action(step: PaceAutomationStep(toolCalls: [
            PaceAutomationToolCall(tool: "shell_script", arguments: [:]),
        ]))
        let program = makeProgram(nodes: [
            .condition(
                predicate: .weekdayIn([2]),
                thenNodes: [openApplicationNode("Notes")],
                otherwiseNodes: [invalidNode]
            ),
        ])

        let validationMessages = PaceProgramValidator
            .validationIssues(for: program)
            .map(\.message)
        #expect(validationMessages.contains(where: { $0.contains("unknown tool shell_script") }))
    }

    @Test func validatorEnforcesRepeatAndExpansionBudgets() {
        let invalidRepeatProgram = makeProgram(nodes: [
            .repeatTimes(count: 11, nodes: [volumeNode("down")]),
        ])
        let repeatValidationMessages = PaceProgramValidator
            .validationIssues(for: invalidRepeatProgram)
            .map(\.message)
        #expect(repeatValidationMessages.contains(where: { $0.contains("outside 1...10") }))

        let expansionProgram = makeProgram(nodes: [
            .repeatTimes(
                count: 10,
                nodes: (0..<6).map { _ in volumeNode("down") }
            ),
        ])
        let expansionValidationMessages = PaceProgramValidator
            .validationIssues(for: expansionProgram)
            .map(\.message)
        #expect(expansionValidationMessages.contains(where: {
            $0.contains("maximum is 50")
        }))
    }

    @Test func validatorEnforcesNestingAndSourceNodeBudgets() {
        var nestedNode = openApplicationNode("Notes")
        for _ in 0..<4 {
            nestedNode = .repeatTimes(count: 1, nodes: [nestedNode])
        }
        let nestingMessages = PaceProgramValidator
            .validationIssues(for: makeProgram(nodes: [nestedNode]))
            .map(\.message)
        #expect(nestingMessages.contains(where: { $0.contains("nesting depth 5") }))

        let sourceNodeProgram = makeProgram(
            nodes: (0..<51).map { _ in volumeNode("down") }
        )
        let sourceNodeMessages = PaceProgramValidator
            .validationIssues(for: sourceNodeProgram)
            .map(\.message)
        #expect(sourceNodeMessages.contains(where: { $0.contains("51 source nodes") }))
    }

    @Test func validatorRejectsInvalidPredicatesAndEmptyPrograms() {
        let invalidPredicatesProgram = makeProgram(nodes: [
            .condition(
                predicate: .weekdayIn([0, 8]),
                thenNodes: [],
                otherwiseNodes: []
            ),
            .condition(
                predicate: .localHourIn(startInclusive: 18, endExclusive: 9),
                thenNodes: [],
                otherwiseNodes: []
            ),
            .condition(
                predicate: .frontmostApplicationIn(bundleIdentifiers: [""]),
                thenNodes: [],
                otherwiseNodes: []
            ),
        ])
        let validationMessages = PaceProgramValidator
            .validationIssues(for: invalidPredicatesProgram)
            .map(\.message)
        #expect(validationMessages.contains(where: { $0.contains("weekdayIn") }))
        #expect(validationMessages.contains(where: { $0.contains("localHourIn") }))
        #expect(validationMessages.contains(where: { $0.contains("frontmostApplicationIn") }))
        #expect(validationMessages.contains(where: { $0.contains("at least one action") }))
    }

    @Test func validatorKeepsFixedSequencesInTheTypedAutomationTier() {
        let fixedSequenceProgram = makeProgram(nodes: [
            openApplicationNode("Notes"),
            openApplicationNode("Calendar"),
        ])

        let validationMessages = PaceProgramValidator
            .validationIssues(for: fixedSequenceProgram)
            .map(\.message)
        #expect(validationMessages.contains(where: {
            $0.contains("condition or bounded repetition")
        }))
    }

    @Test func compilerSelectsWeekdayHourAndFrontmostApplicationBranches() throws {
        let program = makeProgram(nodes: [
            .condition(
                predicate: .weekdayIn([2]),
                thenNodes: [openApplicationNode("Notes")],
                otherwiseNodes: [openApplicationNode("Music")]
            ),
            .condition(
                predicate: .localHourIn(startInclusive: 9, endExclusive: 17),
                thenNodes: [openApplicationNode("Calendar")],
                otherwiseNodes: []
            ),
            .condition(
                predicate: .frontmostApplicationIn(bundleIdentifiers: ["com.apple.Notes"]),
                thenNodes: [openApplicationNode("Finder")],
                otherwiseNodes: []
            ),
        ])

        let executionPlan = try requireExecutionPlan(
            PaceProgramCompiler.compile(
                program,
                context: PaceProgramContext(
                    weekday: 2,
                    localHour: 10,
                    frontmostApplicationBundleIdentifier: "com.apple.Notes"
                )
            )
        )
        let openedApplications = executionPlan.flattenedActions.compactMap { action -> String? in
            guard case .openApplication(let applicationName) = action else { return nil }
            return applicationName
        }
        #expect(openedApplications == ["Notes", "Calendar", "Finder"])
    }

    @Test func compilerExpandsRepeatsAndPreservesOrder() throws {
        let program = makeProgram(nodes: [
            openApplicationNode("Music"),
            .repeatTimes(count: 3, nodes: [volumeNode("down")]),
            openApplicationNode("Notes"),
        ])

        let executionPlan = try requireExecutionPlan(
            PaceProgramCompiler.compile(program, context: fixtureContext)
        )
        #expect(executionPlan.flattenedActions.count == 5)
        guard case .openApplication("Music") = executionPlan.flattenedActions[0],
              case .adjustVolume = executionPlan.flattenedActions[1],
              case .adjustVolume = executionPlan.flattenedActions[2],
              case .adjustVolume = executionPlan.flattenedActions[3],
              case .openApplication("Notes") = executionPlan.flattenedActions[4] else {
            Issue.record("program did not preserve action order")
            return
        }
    }

    @Test func compilerReturnsNoActionsWhenSelectedBranchIsEmpty() throws {
        let program = makeProgram(nodes: [
            .condition(
                predicate: .weekdayIn([1]),
                thenNodes: [openApplicationNode("Notes")],
                otherwiseNodes: []
            ),
        ])

        let outcome = try PaceProgramCompiler.compile(program, context: fixtureContext)
        guard case .noActionsMatched = outcome else {
            Issue.record("expected noActionsMatched")
            return
        }
    }

    @Test func naturalLanguageStructurerAcceptsOnlyFullyValidPrograms() throws {
        let validProgram = makeProgram(nodes: [
            .repeatTimes(count: 2, nodes: [volumeNode("down")]),
        ])
        let validJSON = String(
            data: try JSONEncoder().encode(validProgram),
            encoding: .utf8
        ) ?? ""
        #expect(PaceNaturalLanguageProgramStructurer.program(fromStructuredJSON: validJSON) == validProgram)

        let sourceCode = "```lua\nfor index = 1, 2 do hs.audiodevice.defaultOutputDevice():setVolume(20) end\n```"
        #expect(PaceNaturalLanguageProgramStructurer.program(fromStructuredJSON: sourceCode) == nil)

        let inventedNodeJSON = validJSON.replacingOccurrences(
            of: "\"repeatTimes\"",
            with: "\"runShell\""
        )
        #expect(PaceNaturalLanguageProgramStructurer.program(fromStructuredJSON: inventedNodeJSON) == nil)
    }

    private let fixtureContext = PaceProgramContext(
        weekday: 2,
        localHour: 10,
        frontmostApplicationBundleIdentifier: "com.apple.Notes"
    )

    private func makeProgram(nodes: [PaceProgramNode]) -> PaceProgramDefinition {
        PaceProgramDefinition(
            schemaVersion: 1,
            identifier: "fixture-program",
            name: "Fixture Program",
            description: "A bounded program fixture.",
            category: "test",
            invocationPhrases: ["run fixture program"],
            requiredPreferences: [],
            nodes: nodes
        )
    }

    private func openApplicationNode(_ applicationName: String) -> PaceProgramNode {
        .action(step: PaceAutomationStep(toolCalls: [
            PaceAutomationToolCall(
                tool: "open_app",
                arguments: ["app": .string(applicationName)]
            ),
        ]))
    }

    private func volumeNode(_ direction: String) -> PaceProgramNode {
        .action(step: PaceAutomationStep(toolCalls: [
            PaceAutomationToolCall(
                tool: "volume",
                arguments: ["direction": .string(direction)]
            ),
        ]))
    }

    private func requireExecutionPlan(
        _ outcome: PaceProgramCompilationOutcome
    ) throws -> PaceActionExecutionPlan {
        guard case .executionPlan(let executionPlan) = outcome else {
            Issue.record("expected execution plan")
            throw PaceProgramCompilationError.typedCompilationFailed("missing execution plan")
        }
        return executionPlan
    }
}

struct PaceUserProgramStoreTests {
    @Test func storePersistsValidProgramsAndIsolatesMalformedFiles() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PaceUserProgramStore(directoryURL: directoryURL)
        let program = makeProgram(identifier: "morning-program", name: "Morning Program")

        try store.save(program)
        try Data("not json".utf8).write(
            to: directoryURL.appendingPathComponent("invalid.json")
        )

        #expect(store.listValidPrograms() == [program])
        try store.delete(identifier: program.identifier)
        #expect(store.listValidPrograms().isEmpty)
    }

    @Test func storeRefusesStoredAndCrossCatalogCollisions() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PaceUserProgramStore(directoryURL: directoryURL)
        let program = makeProgram(identifier: "morning-program", name: "Morning Program")
        try store.save(program)

        #expect(throws: PaceUserProgramStoreError.nameCollision("Morning Program")) {
            try store.save(makeProgram(identifier: "another", name: "Morning Program"))
        }
        #expect(throws: PaceUserProgramStoreError.identifierCollision("collision")) {
            try store.save(
                makeProgram(identifier: "collision", name: "Different Name"),
                existingIdentifiers: ["collision"]
            )
        }
        #expect(throws: PaceUserProgramStoreError.nameCollision("Existing Catalog Name")) {
            try store.save(
                makeProgram(identifier: "catalog-name", name: "Existing Catalog Name"),
                existingNormalizedNames: ["existing catalog name"]
            )
        }
    }

    @Test func programRequiredPreferencesUseTheSharedMemorySeam() {
        var program = makeProgram(identifier: "preference-program", name: "Preference Program")
        program = PaceProgramDefinition(
            schemaVersion: program.schemaVersion,
            identifier: program.identifier,
            name: program.name,
            description: program.description,
            category: program.category,
            invocationPhrases: program.invocationPhrases,
            requiredPreferences: ["preferredNotesApp"],
            nodes: program.nodes
        )

        #expect(PaceProgramLibrary.missingRequiredPreference(
            for: program,
            memoryStore: EmptyProgramMemoryStore.self
        ) == "preferredNotesApp")
        #expect(PaceProgramLibrary.missingRequiredPreference(
            for: program,
            memoryStore: PopulatedProgramMemoryStore.self
        ) == nil)
    }

    @Test func programResolutionFailsClosedForAStaleCatalogReference() {
        let program = makeProgram(identifier: "available", name: "Available")

        #expect(PaceProgramLibrary.resolve(identifier: "missing", in: [program]) == nil)
        #expect(PaceProgramLibrary.resolve(identifier: "available", in: [program]) == program)
    }

    private func makeProgram(identifier: String, name: String) -> PaceProgramDefinition {
        PaceProgramDefinition(
            schemaVersion: 1,
            identifier: identifier,
            name: name,
            description: "Program store fixture.",
            category: "test",
            invocationPhrases: [name],
            requiredPreferences: [],
            nodes: [
                .repeatTimes(count: 2, nodes: [
                    .action(step: PaceAutomationStep(toolCalls: [
                        PaceAutomationToolCall(
                            tool: "volume",
                            arguments: ["direction": .string("down")]
                        ),
                    ])),
                ]),
            ]
        )
    }
}

private enum EmptyProgramMemoryStore: PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String? {
        nil
    }
}

private enum PopulatedProgramMemoryStore: PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String? {
        "value"
    }
}
