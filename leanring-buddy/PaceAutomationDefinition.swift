//
//  PaceAutomationDefinition.swift
//  leanring-buddy
//
//  Versioned, deterministic local automations built from Pace's canonical
//  typed tools. Definitions compile through PaceActionTagParser so automation
//  execution shares the same validation, approval, executor, and audit path as
//  planner-produced actions without involving a model.
//

import Foundation

nonisolated enum PaceAutomationSource: String, Codable, Equatable, Hashable, Sendable {
    case bundled
    case user
    case program
    case recordedFlow
    case skill
    case shortcuts
}

nonisolated enum PaceAutomationExecutionMode: String, Codable, Equatable, Hashable, Sendable {
    case deterministicLocal
    case deterministicProgram
    case deterministicReplay
    case plannerGrounded
    case externalOpaque

    var displayName: String {
        switch self {
        case .deterministicLocal:
            return "deterministic local"
        case .deterministicProgram:
            return "deterministic program"
        case .deterministicReplay:
            return "deterministic replay"
        case .plannerGrounded:
            return "uses the local planner"
        case .externalOpaque:
            return "runs in Shortcuts"
        }
    }
}

nonisolated struct PaceAutomationToolCall: Codable, Equatable, Sendable {
    let tool: String
    let arguments: [String: PaceMCPJSONValue]
}

nonisolated struct PaceAutomationStep: Codable, Equatable, Sendable {
    let toolCalls: [PaceAutomationToolCall]
}

nonisolated struct PaceAutomationDefinition: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let identifier: String
    let name: String
    let description: String
    let category: String
    /// Natural phrases that should select this automation. Optional so
    /// schema-v1 manifests written before semantic routing remain valid.
    let invocationPhrases: [String]?
    let source: PaceAutomationSource
    let executionMode: PaceAutomationExecutionMode
    let requiredPreferences: [String]
    let steps: [PaceAutomationStep]

    init(
        schemaVersion: Int,
        identifier: String,
        name: String,
        description: String,
        category: String,
        invocationPhrases: [String]? = nil,
        source: PaceAutomationSource,
        executionMode: PaceAutomationExecutionMode,
        requiredPreferences: [String],
        steps: [PaceAutomationStep]
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.name = name
        self.description = description
        self.category = category
        self.invocationPhrases = invocationPhrases
        self.source = source
        self.executionMode = executionMode
        self.requiredPreferences = requiredPreferences
        self.steps = steps
    }
}

nonisolated struct PaceAutomationValidationIssue: Equatable, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

nonisolated enum PaceAutomationCompilationError: Error, Equatable, CustomStringConvertible {
    case invalidDefinition([String])
    case couldNotEncodeToolCalls
    case partiallyParsed(expectedStepActionCounts: [Int], actualStepActionCounts: [Int])

    var description: String {
        switch self {
        case .invalidDefinition(let issues):
            return issues.joined(separator: "; ")
        case .couldNotEncodeToolCalls:
            return "could not encode tool calls"
        case .partiallyParsed(let expectedStepActionCounts, let actualStepActionCounts):
            return "expected step action counts \(expectedStepActionCounts), parsed \(actualStepActionCounts)"
        }
    }
}

nonisolated enum PaceAutomationDefinitionValidator {
    static let supportedSchemaVersion = 1

    private static let deterministicToolKinds: Set<PaceLocalToolKind> = [
        .brightness,
        .calendar,
        .calendarCreate,
        .clearAnnotations,
        .clipboard,
        .finder,
        .music,
        .notes,
        .openApp,
        .reminder,
        .startTimer,
        .things,
        .volume,
        .window,
    ]

    static var allowedToolDefinitionsForAuthoring: [PaceLocalToolDefinition] {
        PaceToolRegistry.localTools.filter { deterministicToolKinds.contains($0.kind) }
    }

    static func validationIssues(
        for definition: PaceAutomationDefinition
    ) -> [PaceAutomationValidationIssue] {
        var validationIssues: [PaceAutomationValidationIssue] = []

        if definition.schemaVersion != supportedSchemaVersion {
            validationIssues.append(.init(
                message: "unsupported schemaVersion \(definition.schemaVersion); expected \(supportedSchemaVersion)"
            ))
        }

        for (fieldName, fieldValue) in [
            ("identifier", definition.identifier),
            ("name", definition.name),
            ("description", definition.description),
            ("category", definition.category),
        ] where fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append(.init(message: "\(fieldName) must not be empty"))
        }

        if definition.source != .bundled && definition.source != .user {
            validationIssues.append(.init(
                message: "typed definition source must be bundled or user"
            ))
        }
        if definition.executionMode != .deterministicLocal {
            validationIssues.append(.init(
                message: "typed definition executionMode must be deterministicLocal"
            ))
        }
        if definition.steps.isEmpty {
            validationIssues.append(.init(message: "must declare at least one step"))
        }

        for requiredPreferenceKey in definition.requiredPreferences {
            if PaceLocalMemoryKey(rawValue: requiredPreferenceKey) == nil {
                validationIssues.append(.init(
                    message: "requires unknown preference key \(requiredPreferenceKey)"
                ))
            }
        }

        for (stepIndex, automationStep) in definition.steps.enumerated() {
            if automationStep.toolCalls.isEmpty {
                validationIssues.append(.init(
                    message: "step \(stepIndex + 1) must declare at least one tool call"
                ))
            }

            for (toolCallIndex, toolCall) in automationStep.toolCalls.enumerated() {
                let location = "step \(stepIndex + 1), call \(toolCallIndex + 1)"
                guard let toolDefinition = PaceToolRegistry.definition(forToolName: toolCall.tool) else {
                    validationIssues.append(.init(
                        message: "\(location) uses unknown tool \(toolCall.tool)"
                    ))
                    continue
                }
                if !deterministicToolKinds.contains(toolDefinition.kind)
                    || toolDefinition.riskLevel == .destructive {
                    validationIssues.append(.init(
                        message: "\(location) uses forbidden tool \(toolDefinition.canonicalName)"
                    ))
                }
                if toolCall.arguments["tool"] != nil {
                    validationIssues.append(.init(
                        message: "\(location) arguments must not override the tool name"
                    ))
                }
            }
        }

        return validationIssues
    }
}

nonisolated enum PaceUserAutomationStoreError: Error, Equatable {
    case invalidDefinition([String])
    case nameCollision(String)
    case identifierCollision(String)
}

/// Isolated JSON persistence for deterministic automations authored by the
/// user. Invalid files are skipped independently so one stale definition can
/// never hide the rest of the catalog.
nonisolated struct PaceUserAutomationStore {
    static var defaultDirectoryURL: URL {
        let applicationSupportRootURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportRootURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("automations", isDirectory: true)
    }

    let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    func save(
        _ definition: PaceAutomationDefinition,
        existingNormalizedNames: Set<String> = [],
        existingIdentifiers: Set<String> = []
    ) throws {
        let validationMessages = PaceAutomationDefinitionValidator
            .validationIssues(for: definition)
            .map(\.message)
        guard definition.source == .user, validationMessages.isEmpty else {
            throw PaceUserAutomationStoreError.invalidDefinition(validationMessages)
        }
        do {
            _ = try PaceAutomationCompiler.compile(definition)
        } catch {
            throw PaceUserAutomationStoreError.invalidDefinition([String(describing: error)])
        }

        let normalizedDefinitionName = PaceAutomationCatalog.normalizedName(definition.name)
        let storedNames = Set(listValidDefinitions().map {
            PaceAutomationCatalog.normalizedName($0.name)
        })
        guard !existingNormalizedNames.contains(normalizedDefinitionName),
              !storedNames.contains(normalizedDefinitionName) else {
            throw PaceUserAutomationStoreError.nameCollision(definition.name)
        }
        let storedIdentifiers = Set(listValidDefinitions().map(\.identifier))
        guard !existingIdentifiers.contains(definition.identifier),
              !storedIdentifiers.contains(definition.identifier) else {
            throw PaceUserAutomationStoreError.identifierCollision(definition.identifier)
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destinationFileURL = directoryURL
            .appendingPathComponent("\(definition.identifier).json")
        guard !FileManager.default.fileExists(atPath: destinationFileURL.path) else {
            throw PaceUserAutomationStoreError.identifierCollision(definition.identifier)
        }
        let encodedDefinition = try Self.jsonEncoder.encode(definition)
        try encodedDefinition.write(to: destinationFileURL, options: .atomic)
    }

    func listValidDefinitions() -> [PaceAutomationDefinition] {
        guard let definitionURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return definitionURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { definitionURL -> PaceAutomationDefinition? in
                guard let definitionData = try? Data(contentsOf: definitionURL),
                      let definition = try? Self.jsonDecoder.decode(
                        PaceAutomationDefinition.self,
                        from: definitionData
                      ),
                      definition.source == .user,
                      PaceAutomationDefinitionValidator.validationIssues(for: definition).isEmpty,
                      (try? PaceAutomationCompiler.compile(definition)) != nil else {
                    return nil
                }
                return definition
            }
            .sorted { firstDefinition, secondDefinition in
                firstDefinition.name.localizedCaseInsensitiveCompare(
                    secondDefinition.name
                ) == .orderedAscending
            }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let jsonDecoder = JSONDecoder()
}

/// Untrusted local-planner output decoder. The returned definition still has
/// to pass the validator and complete compiler before the store accepts it.
nonisolated enum PaceNaturalLanguageAutomationStructurer {
    private struct StructuredAutomationResponse: Decodable {
        let name: String?
        let description: String?
        let category: String?
        let invocationPhrases: [String]?
        let steps: [PaceAutomationStep]?
    }

    static var systemPrompt: String {
        let allowedTools = PaceAutomationDefinitionValidator
            .allowedToolDefinitionsForAuthoring
            .map(\.promptLine)
            .joined(separator: "\n")
        return """
        Convert the user's repeatable task into one deterministic local Pace automation.
        Return ONLY one JSON object with this exact shape:
        {"name":"short title","description":"literal complete outcome","category":"custom","invocationPhrases":["natural phrase"],"steps":[{"toolCalls":[{"tool":"canonical_name","arguments":{}}]}]}

        Use only the tools listed below and copy their canonical tool names and argument keys exactly:
        \(allowedTools)

        Rules:
        - Include only concrete actions and values stated by the user.
        - If the user says "when I say X", put X in invocationPhrases and do not treat that clause as an action.
        - Do not invent recipients, content, dates, paths, applications, or parameters.
        - Do not emit click, typing, key, URL, mail, message, Shortcut, flow, download, script, or MCP calls.
        - If the task cannot be represented completely with the listed tools, return {"name":"","description":"","category":"custom","invocationPhrases":[],"steps":[]}.
        """
    }

    static func definition(fromStructuredJSON rawText: String) -> PaceAutomationDefinition? {
        guard let jsonObject = extractJSONObject(from: rawText),
              let jsonData = jsonObject.data(using: .utf8),
              let response = try? JSONDecoder().decode(
                StructuredAutomationResponse.self,
                from: jsonData
              ) else {
            return nil
        }

        let name = response.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = response.description?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let steps = response.steps ?? []
        guard !name.isEmpty, !description.isEmpty, !steps.isEmpty else {
            return nil
        }

        let definition = PaceAutomationDefinition(
            schemaVersion: PaceAutomationDefinitionValidator.supportedSchemaVersion,
            identifier: PaceFlowStore.slug(for: name),
            name: name,
            description: description,
            category: response.category?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmptyValue ?? "custom",
            invocationPhrases: response.invocationPhrases,
            source: .user,
            executionMode: .deterministicLocal,
            requiredPreferences: [],
            steps: steps
        )
        guard PaceAutomationDefinitionValidator.validationIssues(for: definition).isEmpty,
              (try? PaceAutomationCompiler.compile(definition)) != nil else {
            return nil
        }
        return definition
    }

    private static func extractJSONObject(from rawText: String) -> String? {
        guard let openingBraceIndex = rawText.firstIndex(of: "{"),
              let closingBraceIndex = rawText.lastIndex(of: "}"),
              openingBraceIndex <= closingBraceIndex else {
            return nil
        }
        return String(rawText[openingBraceIndex...closingBraceIndex])
    }
}

private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}

nonisolated enum PaceAutomationCompiler {
    static func compile(
        _ definition: PaceAutomationDefinition
    ) throws -> PaceActionExecutionPlan {
        let definitionValidationMessages = PaceAutomationDefinitionValidator
            .validationIssues(for: definition)
            .map(\.message)
        guard definitionValidationMessages.isEmpty else {
            throw PaceAutomationCompilationError.invalidDefinition(definitionValidationMessages)
        }

        let encodedSteps = definition.steps.map { automationStep in
            automationStep.toolCalls.map(PaceAutomationParserToolCall.init)
        }
        guard let encodedToolCallData = try? JSONEncoder().encode(encodedSteps),
              let encodedToolCallJSON = String(data: encodedToolCallData, encoding: .utf8) else {
            throw PaceAutomationCompilationError.couldNotEncodeToolCalls
        }

        let parserInput = "<tool_calls>\n\(encodedToolCallJSON)\n</tool_calls>"
        let parseResult = PaceActionTagParser.parseActions(from: parserInput)
        let expectedStepActionCounts = definition.steps.map { $0.toolCalls.count }
        let actualStepActionCounts = parseResult.executionPlan.steps.map { $0.actions.count }

        guard parseResult.spokenText.isEmpty,
              expectedStepActionCounts == actualStepActionCounts else {
            throw PaceAutomationCompilationError.partiallyParsed(
                expectedStepActionCounts: expectedStepActionCounts,
                actualStepActionCounts: actualStepActionCounts
            )
        }

        return parseResult.executionPlan
    }

    private struct PaceAutomationParserToolCall: Encodable {
        let tool: String
        let arguments: [String: PaceMCPJSONValue]

        init(_ toolCall: PaceAutomationToolCall) {
            self.tool = toolCall.tool
            self.arguments = toolCall.arguments
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            try container.encode(tool, forKey: DynamicCodingKey("tool"))
            for (argumentName, argumentValue) in arguments {
                try container.encode(argumentValue, forKey: DynamicCodingKey(argumentName))
            }
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }
}

nonisolated enum PaceAutomationDefinitionLibrary {
    static let bundleResourceDirectory = "automations"
    static let resourceIndexName = "automation-index"

    private struct PaceAutomationResourceIndex: Decodable {
        let schemaVersion: Int
        let identifiers: [String]
    }

    static func loadBundledDefinitions(
        bundle: Bundle = .main,
        allowSourceTreeFallback: Bool = false
    ) -> [PaceAutomationDefinition] {
        automationResourceURLs(
            bundle: bundle,
            allowSourceTreeFallback: allowSourceTreeFallback
        )
        .compactMap { automationURL in
            guard let automationData = try? Data(contentsOf: automationURL) else {
                return nil
            }
            return try? JSONDecoder().decode(PaceAutomationDefinition.self, from: automationData)
        }
        .sorted { firstDefinition, secondDefinition in
            firstDefinition.name.localizedCaseInsensitiveCompare(secondDefinition.name) == .orderedAscending
        }
    }

    static func validateBundledDefinitions(
        bundle: Bundle = .main,
        allowSourceTreeFallback: Bool = true
    ) -> [PaceAutomationValidationIssue] {
        validateBundledDefinitions(
            resourceURLs: automationResourceURLs(
                bundle: bundle,
                allowSourceTreeFallback: allowSourceTreeFallback
            )
        )
    }

    static func validateBundledDefinitions(
        resourceURLs: [URL]
    ) -> [PaceAutomationValidationIssue] {
        guard !resourceURLs.isEmpty else {
            return [.init(message: "no bundled automation manifests found")]
        }

        var validationIssues: [PaceAutomationValidationIssue] = []
        var seenIdentifiers: Set<String> = []
        var seenNames: Set<String> = []

        for automationURL in resourceURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let filename = automationURL.lastPathComponent
            guard let automationData = try? Data(contentsOf: automationURL) else {
                validationIssues.append(.init(message: "could not read \(filename)"))
                continue
            }

            let definition: PaceAutomationDefinition
            do {
                definition = try JSONDecoder().decode(PaceAutomationDefinition.self, from: automationData)
            } catch {
                validationIssues.append(.init(
                    message: "\(filename) failed to decode: \(error.localizedDescription)"
                ))
                continue
            }

            if definition.source != .bundled {
                validationIssues.append(.init(
                    message: "\(filename) source must be bundled"
                ))
            }

            let expectedFilename = "\(definition.identifier).json"
            if filename != expectedFilename {
                validationIssues.append(.init(
                    message: "\(filename) declares identifier \(definition.identifier); filename must be \(expectedFilename)"
                ))
            }

            if !seenIdentifiers.insert(definition.identifier).inserted {
                validationIssues.append(.init(
                    message: "duplicate automation identifier \(definition.identifier)"
                ))
            }

            let normalizedName = PaceAutomationCatalog.normalizedName(definition.name)
            if !seenNames.insert(normalizedName).inserted {
                validationIssues.append(.init(
                    message: "duplicate automation name \(definition.name)"
                ))
            }

            do {
                _ = try PaceAutomationCompiler.compile(definition)
            } catch {
                validationIssues.append(.init(
                    message: "\(definition.identifier): \(error)"
                ))
            }
        }

        return validationIssues
    }

    static func missingRequiredPreference(
        for definition: PaceAutomationDefinition,
        memoryStore: PaceLocalMemoryStoreReadable.Type = PaceLocalMemoryStore.self
    ) -> String? {
        for requiredPreferenceKey in definition.requiredPreferences {
            guard let resolvedPreferenceKey = PaceLocalMemoryKey(rawValue: requiredPreferenceKey),
                  memoryStore.string(for: resolvedPreferenceKey) != nil else {
                return requiredPreferenceKey
            }
        }
        return nil
    }

    private static func automationResourceURLs(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> [URL] {
        let sourceTreeDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )
        .appendingPathComponent("leanring-buddy")
        .appendingPathComponent("Resources")
        .appendingPathComponent(bundleResourceDirectory)

        let indexURLCandidates = [
            bundle.url(
                forResource: resourceIndexName,
                withExtension: "json",
                subdirectory: "Resources/\(bundleResourceDirectory)"
            ),
            bundle.url(
                forResource: resourceIndexName,
                withExtension: "json",
                subdirectory: bundleResourceDirectory
            ),
            bundle.url(forResource: resourceIndexName, withExtension: "json"),
            allowSourceTreeFallback
                ? sourceTreeDirectoryURL.appendingPathComponent("\(resourceIndexName).json")
                : nil,
        ]
        guard let indexURL = indexURLCandidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }),
        let indexData = try? Data(contentsOf: indexURL),
        let resourceIndex = try? JSONDecoder().decode(PaceAutomationResourceIndex.self, from: indexData),
        resourceIndex.schemaVersion == 1 else {
            return []
        }

        return resourceIndex.identifiers.compactMap { identifier in
            let bundledManifestURLCandidates = [
                bundle.url(
                    forResource: identifier,
                    withExtension: "json",
                    subdirectory: "Resources/\(bundleResourceDirectory)"
                ),
                bundle.url(
                    forResource: identifier,
                    withExtension: "json",
                    subdirectory: bundleResourceDirectory
                ),
                bundle.url(forResource: identifier, withExtension: "json"),
            ]
            if let bundledManifestURL = bundledManifestURLCandidates
                .compactMap({ $0 })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return bundledManifestURL
            }
            if allowSourceTreeFallback {
                return sourceTreeDirectoryURL.appendingPathComponent("\(identifier).json")
            }
            return bundle.resourceURL?.appendingPathComponent("\(identifier).json")
        }
    }
}

/// Shared read seam for typed-automation and skill preference preflight.
nonisolated protocol PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String?
}

extension PaceLocalMemoryStore: PaceLocalMemoryStoreReadable {}
