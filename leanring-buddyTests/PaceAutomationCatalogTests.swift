//
//  PaceAutomationCatalogTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceAutomationDefinitionTests {
    @Test func bundledDefinitionsValidateAndCompileFromSourceTree() throws {
        let validationIssues = PaceAutomationDefinitionLibrary.validateBundledDefinitions(
            bundle: .main,
            allowSourceTreeFallback: true
        )
        #expect(validationIssues.isEmpty, "\(validationIssues)")

        let definitions = PaceAutomationDefinitionLibrary.loadBundledDefinitions(
            bundle: .main,
            allowSourceTreeFallback: true
        )
        #expect(!definitions.isEmpty)
        #expect((10...20).contains(definitions.count))
        #expect(Set(definitions.map(\.identifier)).count == definitions.count)
        let starterLibraryCategories = Set(definitions.map(\.category))
        #expect(
            starterLibraryCategories.isSuperset(of: [
                "calendar",
                "capture",
                "files",
                "focus",
                "media",
                "planning",
                "shutdown",
                "window",
                "work",
            ]))
        for definition in definitions {
            let executionPlan = try PaceAutomationCompiler.compile(definition)
            #expect(executionPlan.steps.count == definition.steps.count)
            #expect(executionPlan.flattenedActions.count == definition.steps.flatMap(\.toolCalls).count)
        }
    }

    @Test func compilerProducesCanonicalTypedActions() throws {
        let definition = makeDefinition(
            steps: [
                PaceAutomationStep(toolCalls: [
                    PaceAutomationToolCall(
                        tool: "open_app",
                        arguments: ["app": .string("Calendar")]
                    ),
                    PaceAutomationToolCall(
                        tool: "reminder",
                        arguments: ["title": .string("Review tomorrow")]
                    ),
                ])
            ]
        )

        let executionPlan = try PaceAutomationCompiler.compile(definition)
        #expect(executionPlan.steps.count == 1)
        #expect(executionPlan.flattenedActions.count == 2)
        guard case .openApplication(let applicationName) = executionPlan.flattenedActions[0] else {
            Issue.record("expected openApplication")
            return
        }
        #expect(applicationName == "Calendar")
        guard case .createReminder(let reminderRequest) = executionPlan.flattenedActions[1] else {
            Issue.record("expected createReminder")
            return
        }
        #expect(reminderRequest.title == "Review tomorrow")
    }

    @Test func validatorRejectsForbiddenAndUnknownTools() {
        let definition = makeDefinition(
            steps: [
                PaceAutomationStep(toolCalls: [
                    PaceAutomationToolCall(
                        tool: "shortcuts",
                        arguments: ["name": .string("Opaque workflow")]
                    ),
                    PaceAutomationToolCall(tool: "shell_script", arguments: [:]),
                ])
            ]
        )

        let validationMessages =
            PaceAutomationDefinitionValidator
            .validationIssues(for: definition)
            .map(\.message)
        #expect(validationMessages.contains(where: { $0.contains("forbidden tool shortcuts") }))
        #expect(validationMessages.contains(where: { $0.contains("unknown tool shell_script") }))
    }

    @Test func compilerRejectsARegisteredCallThatOnlyPartiallyParses() {
        let definition = makeDefinition(
            steps: [
                PaceAutomationStep(toolCalls: [
                    PaceAutomationToolCall(tool: "open_app", arguments: [:])
                ])
            ]
        )

        #expect(
            throws: PaceAutomationCompilationError.partiallyParsed(
                expectedStepActionCounts: [1],
                actualStepActionCounts: []
            )
        ) {
            _ = try PaceAutomationCompiler.compile(definition)
        }
    }

    @Test func validatorRejectsSchemaDrift() {
        let definition = PaceAutomationDefinition(
            schemaVersion: 2,
            identifier: "future-schema",
            name: "future schema",
            description: "Fixture",
            category: "test",
            source: .bundled,
            executionMode: .deterministicLocal,
            requiredPreferences: [],
            steps: [
                PaceAutomationStep(toolCalls: [
                    PaceAutomationToolCall(
                        tool: "open_app",
                        arguments: ["app": .string("Calendar")]
                    )
                ])
            ]
        )

        let validationMessages =
            PaceAutomationDefinitionValidator
            .validationIssues(for: definition)
            .map(\.message)
        #expect(validationMessages.contains(where: { $0.contains("unsupported schemaVersion 2") }))
    }

    @Test func naturalLanguageStructurerAcceptsOnlyFullyCompiledTypedCalls() throws {
        let rawResponse = #"""
            {"name":"Open Calendar","description":"Opens Calendar.","category":"custom","invocationPhrases":["show me my calendar"],"steps":[{"toolCalls":[{"tool":"open_app","arguments":{"app":"Calendar"}}]}]}
            """#

        let definition = try #require(
            PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: rawResponse)
        )
        #expect(definition.source == .user)
        #expect(definition.name == "Open Calendar")
        #expect(definition.invocationPhrases == ["show me my calendar"])
        let executionPlan = try PaceAutomationCompiler.compile(definition)
        #expect(executionPlan.flattenedActions.count == 1)
    }

    @Test func naturalLanguageStructurerRejectsInputInjectionCalls() {
        let rawResponse = #"""
            {"name":"Type Secret","description":"Types text.","category":"custom","invocationPhrases":["type it"],"steps":[{"toolCalls":[{"tool":"type","arguments":{"text":"secret"}}]}]}
            """#

        #expect(
            PaceNaturalLanguageAutomationStructurer.definition(fromStructuredJSON: rawResponse) == nil
        )
    }

    @Test func userAutomationStoreIsolatesInvalidFilesAndRefusesNameCollisions() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PaceUserAutomationStore(directoryURL: directoryURL)
        let definition = PaceAutomationDefinition(
            schemaVersion: 1,
            identifier: "open-calendar",
            name: "Open Calendar",
            description: "Opens Calendar.",
            category: "custom",
            invocationPhrases: ["show my calendar"],
            source: .user,
            executionMode: .deterministicLocal,
            requiredPreferences: [],
            steps: [
                PaceAutomationStep(toolCalls: [
                    PaceAutomationToolCall(
                        tool: "open_app",
                        arguments: ["app": .string("Calendar")]
                    )
                ])
            ]
        )

        try store.save(definition)
        try Data("not json".utf8).write(
            to: directoryURL.appendingPathComponent("invalid.json")
        )
        #expect(store.listValidDefinitions() == [definition])

        #expect(throws: PaceUserAutomationStoreError.nameCollision("Open Calendar")) {
            try store.save(definition)
        }
    }

    private func makeDefinition(
        steps: [PaceAutomationStep]
    ) -> PaceAutomationDefinition {
        PaceAutomationDefinition(
            schemaVersion: 1,
            identifier: "fixture",
            name: "fixture automation",
            description: "Fixture automation.",
            category: "test",
            source: .bundled,
            executionMode: .deterministicLocal,
            requiredPreferences: [],
            steps: steps
        )
    }
}

struct PaceAutomationCatalogTests {
    @Test func everyBundledInvocationPhraseSelectsItsOwnAutomation() async throws {
        let definitions = PaceAutomationDefinitionLibrary.loadBundledDefinitions(
            bundle: .main,
            allowSourceTreeFallback: true
        )
        let catalog = PaceAutomationCatalog(
            typedDefinitions: definitions,
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )

        for definition in definitions {
            let invocationPhrases = try #require(definition.invocationPhrases)
            #expect(invocationPhrases.count >= 3)
            for invocationPhrase in invocationPhrases {
                let result = await PaceAutomationNaturalLanguageMatcher.match(
                    transcript: invocationPhrase,
                    catalog: catalog,
                    embedder: nil
                )
                guard case .unique(let entry, .exactInvocationPhrase, _) = result else {
                    Issue.record("expected exact route for \(invocationPhrase): \(result)")
                    continue
                }
                #expect(entry.reference == .typedDefinition(identifier: definition.identifier))
            }
        }
    }

    @Test func catalogLabelsEveryReusableWorkSource() {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [makeTypedDefinition(name: "Built in")],
            recordedFlows: [
                PaceRecordedFlow(
                    name: "Recorded",
                    createdAt: Date(timeIntervalSince1970: 1),
                    steps: [.keyShortcut(key: "cmd+k")]
                )
            ],
            skills: [
                PaceSkillFile(
                    name: "Grounded",
                    slug: "grounded",
                    description: "Planner-grounded fixture.",
                    category: "test",
                    requiredPreferences: [],
                    trigger: nil,
                    steps: [PaceSkillStep(instruction: "Open Notes", toolCall: nil)],
                    notes: nil
                )
            ],
            shortcutNames: ["Opaque"],
            programs: [makeProgram(name: "Programmed")]
        )

        #expect(
            Set(catalog.entries.map(\.executionMode)) == [
                .deterministicLocal,
                .deterministicProgram,
                .deterministicReplay,
                .plannerGrounded,
                .externalOpaque,
            ])
        #expect(catalog.spokenListResponse().contains("deterministic local: Built in"))
        #expect(catalog.spokenListResponse().contains("deterministic program: Programmed"))
        #expect(catalog.spokenListResponse().contains("uses the local planner: Grounded"))
        #expect(catalog.spokenListResponse().contains("runs in Shortcuts: Opaque"))
    }

    @Test func exactNormalizedMatchIsUniqueAndFuzzyMatchFallsThrough() {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [makeTypedDefinition(name: "Wéekly   Review")],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )

        guard case .unique(let matchingEntry) = catalog.exactMatch(for: " weekly review ") else {
            Issue.record("expected exact normalized match")
            return
        }
        #expect(matchingEntry.name == "Wéekly   Review")
        #expect(catalog.exactMatch(for: "weekly") == .notFound)
    }

    @Test func programmedAutomationInvocationPhraseUsesTheSharedLocalMatcher() async {
        let program = makeProgram(name: "Programmed")
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [],
            recordedFlows: [],
            skills: [],
            shortcutNames: [],
            programs: [program]
        )

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "run Programmed",
            catalog: catalog,
            embedder: nil
        )
        guard case .unique(let entry, .exactInvocationPhrase, _) = result else {
            Issue.record("expected exact programmed-automation route")
            return
        }
        #expect(entry.reference == .program(identifier: program.identifier))
        #expect(entry.executionMode == .deterministicProgram)
    }

    @Test func crossSourceNameCollisionNeverSelectsOneEntry() {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [makeTypedDefinition(name: "Daily reset")],
            recordedFlows: [
                PaceRecordedFlow(
                    name: "daily reset",
                    createdAt: Date(timeIntervalSince1970: 1),
                    steps: [.keyShortcut(key: "escape")]
                )
            ],
            skills: [],
            shortcutNames: []
        )

        guard case .collision(let matchingEntries) = catalog.exactMatch(for: "DAILY RESET") else {
            Issue.record("expected collision")
            return
        }
        #expect(matchingEntries.count == 2)
        #expect(Set(matchingEntries.map(\.source)) == [.bundled, .recordedFlow])
    }

    @Test func parserRecognizesOnlyExplicitCatalogCommands() {
        #expect(PaceAutomationCatalogCommandParser.parse("list my automations") == .list)
        #expect(PaceAutomationCatalogCommandParser.parse("What automations do I have?") == .list)
        #expect(
            PaceAutomationCatalogCommandParser.parse("run automation Weekly Review")
                == .run(
                    requestedName: "Weekly Review"
                ))
        #expect(
            PaceAutomationCatalogCommandParser.parse("execute the automation named Daily Reset.")
                == .run(
                    requestedName: "Daily Reset"
                ))
        #expect(PaceAutomationCatalogCommandParser.parse("run Weekly Review") == nil)
        #expect(PaceAutomationCatalogCommandParser.parse("automate this") == nil)
    }

    @Test func creationParserExtractsNaturalLanguageDescription() {
        #expect(
            PaceAutomationCreationCommandParser.parse(
                "Create an automation that opens Calendar and starts a focus timer"
            )
                == PaceAutomationCreationCommand(
                    rawDescription: "opens Calendar and starts a focus timer"
                ))
        #expect(PaceAutomationCreationCommandParser.parse("create an automation") == nil)
        #expect(PaceAutomationCreationCommandParser.parse("automate this") == nil)
    }

    @Test func deterministicSkillFallbackPreservesWordsWhenTypedStructuringFails() throws {
        #expect(
            PaceNaturalLanguageAutomationStructurer.definition(
                fromStructuredJSON: "planner unavailable"
            ) == nil)
        let fallbackSkill = try #require(
            PaceSkillLoader.structureSkillDeterministically(
                from: "when I say start my day, open Notes then open Slack"
            ))
        #expect(fallbackSkill.trigger == "start my day")
        #expect(fallbackSkill.steps.map(\.instruction) == ["Open Notes", "Open Slack"])
    }

    @Test func naturalMatcherSelectsAnExactAuthoredPhraseWithoutEmbeddings() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(
                    name: "Daily plan note",
                    invocationPhrases: ["help me plan my day"]
                )
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "Help me plan my day!",
            catalog: catalog,
            embedder: nil
        )

        guard case .unique(let entry, let evidence, let score) = result else {
            Issue.record("expected one exact natural-language match")
            return
        }
        #expect(entry.name == "Daily plan note")
        #expect(evidence == .exactInvocationPhrase)
        #expect(score == 1)
    }

    @Test func naturalMatcherKeepsExactAliasCollisionsOutOfModelResolution() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(
                    name: "Daily plan note",
                    invocationPhrases: ["start my day"]
                ),
                makeTypedDefinition(
                    name: "Today schedule",
                    invocationPhrases: ["start my day"]
                ),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "Start my day",
            catalog: catalog,
            embedder: nil
        )

        guard case .ambiguous(let entries, .exactInvocationPhrase) = result else {
            Issue.record("expected an exact-alias collision")
            return
        }
        #expect(Set(entries.map(\.name)) == ["Daily plan note", "Today schedule"])
    }

    @Test func naturalMatcherUsesSemanticWinnerForDifferentWords() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(name: "Daily plan note"),
                makeTypedDefinition(name: "Tomorrow schedule"),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )
        let embedder = FixedAutomationEmbedder(vectors: [
            [1, 0],
            [0.99, 0.01],
            [0, 1],
        ])

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "organize the things I need to accomplish",
            catalog: catalog,
            embedder: embedder
        )

        guard case .unique(let entry, let evidence, _) = result else {
            Issue.record("expected one semantic natural-language match")
            return
        }
        #expect(entry.name == "Daily plan note")
        #expect(evidence == .semantic)
    }

    @Test func naturalMatcherUsesCalibratedCompactEmbeddingRange() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(name: "Daily plan note"),
                makeTypedDefinition(name: "Tomorrow schedule"),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )
        let embedder = FixedAutomationEmbedder(vectors: [
            [1, 0],
            [0.6, 0.8],
            [0.4, 0.916515],
        ])

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "organize the things I need to accomplish",
            catalog: catalog,
            embedder: embedder
        )

        guard case .unique(let entry, .semantic, _) = result else {
            Issue.record("expected the calibrated compact-vector winner")
            return
        }
        #expect(entry.name == "Daily plan note")
    }

    @Test func naturalMatcherOffersNearThresholdCandidatesToLocalResolver() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(name: "Focus timer"),
                makeTypedDefinition(name: "End of day reset"),
                makeTypedDefinition(name: "Daily plan note"),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )
        let embedder = FixedAutomationEmbedder(vectors: [
            [1, 0],
            [0.31, 0.95073],
            [0.33, 0.94398],
            [0.35, 0.93675],
        ])

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "I need uninterrupted work time",
            catalog: catalog,
            embedder: embedder
        )

        guard case .ambiguous(let candidates, .semantic) = result else {
            Issue.record("expected a bounded local-model shortlist")
            return
        }
        #expect(
            candidates.map(\.name) == [
                "Focus timer",
                "End of day reset",
                "Daily plan note",
            ])
    }

    @Test func naturalMatcherRejectsCloseSemanticCandidatesAsAmbiguous() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(name: "Today schedule"),
                makeTypedDefinition(name: "Tomorrow schedule"),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )
        let embedder = FixedAutomationEmbedder(vectors: [
            [1, 0],
            [0.99, 0.01],
            [0.98, 0.02],
        ])

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "show me my schedule",
            catalog: catalog,
            embedder: embedder
        )

        guard case .ambiguous(let entries, .semantic) = result else {
            Issue.record("expected an ambiguous natural-language match")
            return
        }
        #expect(Set(entries.map(\.name)) == ["Today schedule", "Tomorrow schedule"])
    }

    @Test func naturalMatcherFallsThroughForWeakWords() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(name: "Daily plan note"),
                makeTypedDefinition(name: "Tomorrow schedule"),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )
        let embedder = FixedAutomationEmbedder(vectors: [
            [1, 0],
            [0, 1],
            [0, -1],
        ])

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "tell me a joke",
            catalog: catalog,
            embedder: embedder
        )

        #expect(result == .noMatch)
    }

    @Test func naturalMatcherNeverSemanticallyHijacksAFactualQuestion() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(name: "Today schedule"),
                makeTypedDefinition(name: "Daily plan note"),
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )
        // These vectors would otherwise produce a confident automation match.
        let embedder = FixedAutomationEmbedder(vectors: [
            [1, 0],
            [0.99, 0.01],
            [0, 1],
        ])

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "What is the largest planet in our solar system?",
            catalog: catalog,
            embedder: embedder
        )

        #expect(result == .noMatch)
    }

    @Test func implicitCatalogPolicySkipsQuestionsBeforeDiscovery() {
        #expect(
            !PaceAutomationNaturalLanguageMatcher.shouldAttemptImplicitCatalogMatch(
                transcript: "Which element has the chemical symbol O?"
            ))
        #expect(
            PaceAutomationNaturalLanguageMatcher.shouldAttemptImplicitCatalogMatch(
                transcript: "start my focus session"
            ))
    }

    @Test func naturalMatcherFallsThroughWhenEmbeddingFails() async {
        let catalog = PaceAutomationCatalog(
            typedDefinitions: [
                makeTypedDefinition(
                    name: "Focus timer",
                    invocationPhrases: ["start a focus session"]
                )
            ],
            recordedFlows: [],
            skills: [],
            shortcutNames: []
        )

        let result = await PaceAutomationNaturalLanguageMatcher.match(
            transcript: "please start a focus session",
            catalog: catalog,
            embedder: FailingAutomationEmbedder()
        )

        #expect(result == .noMatch)
    }

    private func makeTypedDefinition(
        name: String,
        invocationPhrases: [String]? = nil
    ) -> PaceAutomationDefinition {
        PaceAutomationDefinition(
            schemaVersion: 1,
            identifier: PaceFlowStore.slug(for: name),
            name: name,
            description: "Fixture automation.",
            category: "test",
            invocationPhrases: invocationPhrases,
            source: .bundled,
            executionMode: .deterministicLocal,
            requiredPreferences: [],
            steps: [
                PaceAutomationStep(toolCalls: [
                    PaceAutomationToolCall(
                        tool: "open_app",
                        arguments: ["app": .string("Calendar")]
                    )
                ])
            ]
        )
    }

    private func makeProgram(name: String) -> PaceProgramDefinition {
        PaceProgramDefinition(
            schemaVersion: 1,
            identifier: PaceFlowStore.slug(for: name),
            name: name,
            description: "Program fixture.",
            category: "test",
            invocationPhrases: ["run \(name)"],
            requiredPreferences: [],
            nodes: [
                .repeatTimes(
                    count: 2,
                    nodes: [
                        .action(
                            step: PaceAutomationStep(toolCalls: [
                                PaceAutomationToolCall(
                                    tool: "volume",
                                    arguments: ["direction": .string("down")]
                                )
                            ]))
                    ])
            ]
        )
    }
}

private final class FixedAutomationEmbedder: PaceTextEmbedding {
    private let vectors: [[Float]]

    init(vectors: [[Float]]) {
        self.vectors = vectors
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        #expect(texts.count == vectors.count)
        return vectors
    }
}

private final class FailingAutomationEmbedder: PaceTextEmbedding {
    func embed(_ texts: [String]) async throws -> [[Float]] {
        throw PaceEmbeddingClientError(message: "fixture failure")
    }
}
