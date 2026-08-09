//
//  PaceProgrammableSkill.swift
//  leanring-buddy
//
//  A bounded, declarative program representation for teachable workflows that
//  need simple branching or repetition but never arbitrary source execution.
//

import AppKit
import Foundation

nonisolated struct PaceProgramDefinition: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let identifier: String
    let name: String
    let description: String
    let category: String
    let invocationPhrases: [String]
    let requiredPreferences: [String]
    let nodes: [PaceProgramNode]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case identifier
        case name
        case description
        case category
        case invocationPhrases
        case requiredPreferences
        case nodes
    }

    init(
        schemaVersion: Int,
        identifier: String,
        name: String,
        description: String,
        category: String,
        invocationPhrases: [String],
        requiredPreferences: [String],
        nodes: [PaceProgramNode]
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.name = name
        self.description = description
        self.category = category
        self.invocationPhrases = invocationPhrases
        self.requiredPreferences = requiredPreferences
        self.nodes = nodes
    }

    init(from decoder: Decoder) throws {
        let dynamicContainer = try decoder.container(keyedBy: PaceProgramDynamicCodingKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        let unexpectedKeys = Set(dynamicContainer.allKeys.map(\.stringValue))
            .subtracting(allowedKeys)
        guard unexpectedKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: dynamicContainer.codingPath,
                debugDescription: "unexpected program definition keys: \(unexpectedKeys.sorted())"
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        identifier = try container.decode(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        invocationPhrases = try container.decode([String].self, forKey: .invocationPhrases)
        requiredPreferences = try container.decode([String].self, forKey: .requiredPreferences)
        nodes = try container.decode([PaceProgramNode].self, forKey: .nodes)
    }
}

nonisolated indirect enum PaceProgramNode: Codable, Equatable, Sendable {
    case action(step: PaceAutomationStep)
    case condition(
        predicate: PaceProgramCondition,
        thenNodes: [PaceProgramNode],
        otherwiseNodes: [PaceProgramNode]
    )
    case repeatTimes(count: Int, nodes: [PaceProgramNode])

    private enum NodeType: String, Codable {
        case action
        case condition
        case repeatTimes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case step
        case predicate
        case thenNodes
        case otherwiseNodes
        case count
        case nodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PaceProgramDynamicCodingKey.self)
        let typeKey = PaceProgramDynamicCodingKey(CodingKeys.type.rawValue)
        let nodeType = try container.decode(NodeType.self, forKey: typeKey)

        let allowedKeys: Set<String>
        switch nodeType {
        case .action:
            allowedKeys = [CodingKeys.type.rawValue, CodingKeys.step.rawValue]
            try Self.rejectUnexpectedKeys(in: container, allowedKeys: allowedKeys)
            self = .action(
                step: try container.decode(
                    PaceAutomationStep.self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.step.rawValue)
                )
            )
        case .condition:
            allowedKeys = [
                CodingKeys.type.rawValue,
                CodingKeys.predicate.rawValue,
                CodingKeys.thenNodes.rawValue,
                CodingKeys.otherwiseNodes.rawValue,
            ]
            try Self.rejectUnexpectedKeys(in: container, allowedKeys: allowedKeys)
            self = .condition(
                predicate: try container.decode(
                    PaceProgramCondition.self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.predicate.rawValue)
                ),
                thenNodes: try container.decode(
                    [PaceProgramNode].self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.thenNodes.rawValue)
                ),
                otherwiseNodes: try container.decode(
                    [PaceProgramNode].self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.otherwiseNodes.rawValue)
                )
            )
        case .repeatTimes:
            allowedKeys = [
                CodingKeys.type.rawValue,
                CodingKeys.count.rawValue,
                CodingKeys.nodes.rawValue,
            ]
            try Self.rejectUnexpectedKeys(in: container, allowedKeys: allowedKeys)
            self = .repeatTimes(
                count: try container.decode(
                    Int.self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.count.rawValue)
                ),
                nodes: try container.decode(
                    [PaceProgramNode].self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.nodes.rawValue)
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let step):
            try container.encode(NodeType.action, forKey: .type)
            try container.encode(step, forKey: .step)
        case .condition(let predicate, let thenNodes, let otherwiseNodes):
            try container.encode(NodeType.condition, forKey: .type)
            try container.encode(predicate, forKey: .predicate)
            try container.encode(thenNodes, forKey: .thenNodes)
            try container.encode(otherwiseNodes, forKey: .otherwiseNodes)
        case .repeatTimes(let count, let nodes):
            try container.encode(NodeType.repeatTimes, forKey: .type)
            try container.encode(count, forKey: .count)
            try container.encode(nodes, forKey: .nodes)
        }
    }

    private static func rejectUnexpectedKeys(
        in container: KeyedDecodingContainer<PaceProgramDynamicCodingKey>,
        allowedKeys: Set<String>
    ) throws {
        let unexpectedKeys = Set(container.allKeys.map(\.stringValue)).subtracting(allowedKeys)
        guard unexpectedKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "unexpected keys for program node: \(unexpectedKeys.sorted())"
            ))
        }
    }
}

nonisolated enum PaceProgramCondition: Codable, Equatable, Sendable {
    case weekdayIn([Int])
    case localHourIn(startInclusive: Int, endExclusive: Int)
    case frontmostApplicationIn(bundleIdentifiers: [String])

    private enum ConditionType: String, Codable {
        case weekdayIn
        case localHourIn
        case frontmostApplicationIn
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case weekdays
        case startInclusive
        case endExclusive
        case bundleIdentifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PaceProgramDynamicCodingKey.self)
        let conditionType = try container.decode(
            ConditionType.self,
            forKey: PaceProgramDynamicCodingKey(CodingKeys.type.rawValue)
        )

        let allowedKeys: Set<String>
        switch conditionType {
        case .weekdayIn:
            allowedKeys = [CodingKeys.type.rawValue, CodingKeys.weekdays.rawValue]
            try Self.rejectUnexpectedKeys(in: container, allowedKeys: allowedKeys)
            self = .weekdayIn(try container.decode(
                [Int].self,
                forKey: PaceProgramDynamicCodingKey(CodingKeys.weekdays.rawValue)
            ))
        case .localHourIn:
            allowedKeys = [
                CodingKeys.type.rawValue,
                CodingKeys.startInclusive.rawValue,
                CodingKeys.endExclusive.rawValue,
            ]
            try Self.rejectUnexpectedKeys(in: container, allowedKeys: allowedKeys)
            self = .localHourIn(
                startInclusive: try container.decode(
                    Int.self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.startInclusive.rawValue)
                ),
                endExclusive: try container.decode(
                    Int.self,
                    forKey: PaceProgramDynamicCodingKey(CodingKeys.endExclusive.rawValue)
                )
            )
        case .frontmostApplicationIn:
            allowedKeys = [
                CodingKeys.type.rawValue,
                CodingKeys.bundleIdentifiers.rawValue,
            ]
            try Self.rejectUnexpectedKeys(in: container, allowedKeys: allowedKeys)
            self = .frontmostApplicationIn(bundleIdentifiers: try container.decode(
                [String].self,
                forKey: PaceProgramDynamicCodingKey(CodingKeys.bundleIdentifiers.rawValue)
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .weekdayIn(let weekdays):
            try container.encode(ConditionType.weekdayIn, forKey: .type)
            try container.encode(weekdays, forKey: .weekdays)
        case .localHourIn(let startInclusive, let endExclusive):
            try container.encode(ConditionType.localHourIn, forKey: .type)
            try container.encode(startInclusive, forKey: .startInclusive)
            try container.encode(endExclusive, forKey: .endExclusive)
        case .frontmostApplicationIn(let bundleIdentifiers):
            try container.encode(ConditionType.frontmostApplicationIn, forKey: .type)
            try container.encode(bundleIdentifiers, forKey: .bundleIdentifiers)
        }
    }

    func matches(_ context: PaceProgramContext) -> Bool {
        switch self {
        case .weekdayIn(let weekdays):
            return weekdays.contains(context.weekday)
        case .localHourIn(let startInclusive, let endExclusive):
            return context.localHour >= startInclusive && context.localHour < endExclusive
        case .frontmostApplicationIn(let bundleIdentifiers):
            guard let frontmostApplicationBundleIdentifier = context
                .frontmostApplicationBundleIdentifier else {
                return false
            }
            return bundleIdentifiers.contains(frontmostApplicationBundleIdentifier)
        }
    }

    private static func rejectUnexpectedKeys(
        in container: KeyedDecodingContainer<PaceProgramDynamicCodingKey>,
        allowedKeys: Set<String>
    ) throws {
        let unexpectedKeys = Set(container.allKeys.map(\.stringValue)).subtracting(allowedKeys)
        guard unexpectedKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "unexpected keys for program predicate: \(unexpectedKeys.sorted())"
            ))
        }
    }
}

private struct PaceProgramDynamicCodingKey: CodingKey {
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

nonisolated struct PaceProgramContext: Equatable, Sendable {
    let weekday: Int
    let localHour: Int
    let frontmostApplicationBundleIdentifier: String?

    @MainActor
    static func current(
        date: Date = Date(),
        calendar: Calendar = .current,
        workspace: NSWorkspace = .shared
    ) -> PaceProgramContext {
        PaceProgramContext(
            weekday: calendar.component(.weekday, from: date),
            localHour: calendar.component(.hour, from: date),
            frontmostApplicationBundleIdentifier: workspace
                .frontmostApplication?
                .bundleIdentifier
        )
    }
}

nonisolated enum PaceProgramCompilationOutcome {
    case executionPlan(PaceActionExecutionPlan)
    case noActionsMatched
}

nonisolated enum PaceProgramCompilationError: Error, Equatable, CustomStringConvertible {
    case invalidProgram([String])
    case typedCompilationFailed(String)

    var description: String {
        switch self {
        case .invalidProgram(let issues):
            return issues.joined(separator: "; ")
        case .typedCompilationFailed(let failureDescription):
            return failureDescription
        }
    }
}

nonisolated enum PaceProgramValidator {
    static let supportedSchemaVersion = 1
    static let maximumNestingDepth = 4
    static let maximumSourceNodeCount = 50
    static let maximumRepeatCount = 10
    static let maximumExpandedActionStepCount = 50

    static func validationIssues(
        for program: PaceProgramDefinition
    ) -> [PaceAutomationValidationIssue] {
        var validationIssues: [PaceAutomationValidationIssue] = []

        if program.schemaVersion != supportedSchemaVersion {
            validationIssues.append(.init(
                message: "unsupported schemaVersion \(program.schemaVersion); expected \(supportedSchemaVersion)"
            ))
        }
        for (fieldName, fieldValue) in [
            ("identifier", program.identifier),
            ("name", program.name),
            ("description", program.description),
            ("category", program.category),
        ] where fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append(.init(message: "\(fieldName) must not be empty"))
        }
        if program.identifier != PaceFlowStore.slug(for: program.identifier) {
            validationIssues.append(.init(
                message: "identifier must contain only canonical lowercase slug characters"
            ))
        }
        for requiredPreferenceKey in program.requiredPreferences {
            if PaceLocalMemoryKey(rawValue: requiredPreferenceKey) == nil {
                validationIssues.append(.init(
                    message: "requires unknown preference key \(requiredPreferenceKey)"
                ))
            }
        }
        if program.nodes.isEmpty {
            validationIssues.append(.init(message: "must declare at least one program node"))
        }

        var sourceNodeCount = 0
        var allActionSteps: [PaceAutomationStep] = []
        let worstCaseExpandedActionStepCount = inspectNodes(
            program.nodes,
            depth: 1,
            sourceNodeCount: &sourceNodeCount,
            allActionSteps: &allActionSteps,
            validationIssues: &validationIssues
        )

        if sourceNodeCount > maximumSourceNodeCount {
            validationIssues.append(.init(
                message: "program has \(sourceNodeCount) source nodes; maximum is \(maximumSourceNodeCount)"
            ))
        }
        if worstCaseExpandedActionStepCount > maximumExpandedActionStepCount {
            validationIssues.append(.init(
                message: "program expands to at most \(worstCaseExpandedActionStepCount) action steps; maximum is \(maximumExpandedActionStepCount)"
            ))
        }
        if allActionSteps.isEmpty {
            validationIssues.append(.init(message: "program must contain at least one action"))
        } else if !containsProgrammableLogic(program.nodes) {
            validationIssues.append(.init(
                message: "program must contain a condition or bounded repetition"
            ))
        } else {
            let syntheticDefinition = PaceAutomationDefinition(
                schemaVersion: PaceAutomationDefinitionValidator.supportedSchemaVersion,
                identifier: program.identifier,
                name: program.name,
                description: program.description,
                category: program.category,
                invocationPhrases: program.invocationPhrases,
                source: .user,
                executionMode: .deterministicLocal,
                requiredPreferences: program.requiredPreferences,
                steps: allActionSteps
            )
            validationIssues.append(contentsOf: PaceAutomationDefinitionValidator
                .validationIssues(for: syntheticDefinition))
            if PaceAutomationDefinitionValidator.validationIssues(for: syntheticDefinition).isEmpty {
                do {
                    _ = try PaceAutomationCompiler.compile(syntheticDefinition)
                } catch {
                    validationIssues.append(.init(
                        message: "program actions do not compile completely: \(error)"
                    ))
                }
            }
        }

        return validationIssues
    }

    static func worstCaseExpandedActionSteps(
        for program: PaceProgramDefinition
    ) -> Int {
        var sourceNodeCount = 0
        var allActionSteps: [PaceAutomationStep] = []
        var validationIssues: [PaceAutomationValidationIssue] = []
        return inspectNodes(
            program.nodes,
            depth: 1,
            sourceNodeCount: &sourceNodeCount,
            allActionSteps: &allActionSteps,
            validationIssues: &validationIssues
        )
    }

    private static func inspectNodes(
        _ nodes: [PaceProgramNode],
        depth: Int,
        sourceNodeCount: inout Int,
        allActionSteps: inout [PaceAutomationStep],
        validationIssues: inout [PaceAutomationValidationIssue]
    ) -> Int {
        var expandedActionStepCount = 0
        for node in nodes {
            sourceNodeCount += 1
            if depth > maximumNestingDepth {
                validationIssues.append(.init(
                    message: "program nesting depth \(depth) exceeds maximum \(maximumNestingDepth)"
                ))
            }

            switch node {
            case .action(let step):
                allActionSteps.append(step)
                expandedActionStepCount = cappedAdd(expandedActionStepCount, 1)

            case .condition(let predicate, let thenNodes, let otherwiseNodes):
                validate(predicate, validationIssues: &validationIssues)
                let thenActionCount = inspectNodes(
                    thenNodes,
                    depth: depth + 1,
                    sourceNodeCount: &sourceNodeCount,
                    allActionSteps: &allActionSteps,
                    validationIssues: &validationIssues
                )
                let otherwiseActionCount = inspectNodes(
                    otherwiseNodes,
                    depth: depth + 1,
                    sourceNodeCount: &sourceNodeCount,
                    allActionSteps: &allActionSteps,
                    validationIssues: &validationIssues
                )
                expandedActionStepCount = cappedAdd(
                    expandedActionStepCount,
                    max(thenActionCount, otherwiseActionCount)
                )

            case .repeatTimes(let count, let repeatedNodes):
                if !(1...maximumRepeatCount).contains(count) {
                    validationIssues.append(.init(
                        message: "repeat count \(count) is outside 1...\(maximumRepeatCount)"
                    ))
                }
                let repeatedActionCount = inspectNodes(
                    repeatedNodes,
                    depth: depth + 1,
                    sourceNodeCount: &sourceNodeCount,
                    allActionSteps: &allActionSteps,
                    validationIssues: &validationIssues
                )
                expandedActionStepCount = cappedAdd(
                    expandedActionStepCount,
                    cappedMultiply(repeatedActionCount, max(count, 0))
                )
            }
        }
        return expandedActionStepCount
    }

    private static func validate(
        _ predicate: PaceProgramCondition,
        validationIssues: inout [PaceAutomationValidationIssue]
    ) {
        switch predicate {
        case .weekdayIn(let weekdays):
            if weekdays.isEmpty || weekdays.contains(where: { !(1...7).contains($0) }) {
                validationIssues.append(.init(
                    message: "weekdayIn requires one or more weekday values in 1...7"
                ))
            }
        case .localHourIn(let startInclusive, let endExclusive):
            if !(0...23).contains(startInclusive)
                || !(1...24).contains(endExclusive)
                || startInclusive >= endExclusive {
                validationIssues.append(.init(
                    message: "localHourIn requires 0 <= startInclusive < endExclusive <= 24"
                ))
            }
        case .frontmostApplicationIn(let bundleIdentifiers):
            if bundleIdentifiers.isEmpty || bundleIdentifiers.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                validationIssues.append(.init(
                    message: "frontmostApplicationIn requires non-empty bundle identifiers"
                ))
            }
        }
    }

    private static func containsProgrammableLogic(_ nodes: [PaceProgramNode]) -> Bool {
        for node in nodes {
            switch node {
            case .action:
                continue
            case .condition:
                return true
            case .repeatTimes:
                return true
            }
        }
        return false
    }

    private static func cappedAdd(_ leftValue: Int, _ rightValue: Int) -> Int {
        let cap = maximumExpandedActionStepCount + 1
        guard leftValue < cap, rightValue < cap else { return cap }
        return min(cap, leftValue + rightValue)
    }

    private static func cappedMultiply(_ leftValue: Int, _ rightValue: Int) -> Int {
        let cap = maximumExpandedActionStepCount + 1
        guard leftValue > 0, rightValue > 0 else { return 0 }
        guard leftValue <= cap / rightValue else { return cap }
        return min(cap, leftValue * rightValue)
    }
}

nonisolated enum PaceProgramCompiler {
    static func compile(
        _ program: PaceProgramDefinition,
        context: PaceProgramContext
    ) throws -> PaceProgramCompilationOutcome {
        let validationMessages = PaceProgramValidator
            .validationIssues(for: program)
            .map(\.message)
        guard validationMessages.isEmpty else {
            throw PaceProgramCompilationError.invalidProgram(validationMessages)
        }

        var expandedSteps: [PaceAutomationStep] = []
        expand(program.nodes, context: context, into: &expandedSteps)
        guard !expandedSteps.isEmpty else {
            return .noActionsMatched
        }

        let transientDefinition = PaceAutomationDefinition(
            schemaVersion: PaceAutomationDefinitionValidator.supportedSchemaVersion,
            identifier: program.identifier,
            name: program.name,
            description: program.description,
            category: program.category,
            invocationPhrases: program.invocationPhrases,
            source: .user,
            executionMode: .deterministicLocal,
            requiredPreferences: program.requiredPreferences,
            steps: expandedSteps
        )
        do {
            return .executionPlan(try PaceAutomationCompiler.compile(transientDefinition))
        } catch {
            throw PaceProgramCompilationError.typedCompilationFailed(String(describing: error))
        }
    }

    private static func expand(
        _ nodes: [PaceProgramNode],
        context: PaceProgramContext,
        into expandedSteps: inout [PaceAutomationStep]
    ) {
        for node in nodes {
            switch node {
            case .action(let step):
                expandedSteps.append(step)
            case .condition(let predicate, let thenNodes, let otherwiseNodes):
                expand(
                    predicate.matches(context) ? thenNodes : otherwiseNodes,
                    context: context,
                    into: &expandedSteps
                )
            case .repeatTimes(let count, let repeatedNodes):
                for _ in 0..<count {
                    expand(repeatedNodes, context: context, into: &expandedSteps)
                }
            }
        }
    }
}

nonisolated enum PaceProgramLibrary {
    static func resolve(
        identifier: String,
        in programs: [PaceProgramDefinition]
    ) -> PaceProgramDefinition? {
        programs.first(where: { $0.identifier == identifier })
    }

    static func missingRequiredPreference(
        for program: PaceProgramDefinition,
        memoryStore: PaceLocalMemoryStoreReadable.Type = PaceLocalMemoryStore.self
    ) -> String? {
        for requiredPreferenceKey in program.requiredPreferences {
            guard let resolvedPreferenceKey = PaceLocalMemoryKey(rawValue: requiredPreferenceKey),
                  memoryStore.string(for: resolvedPreferenceKey) != nil else {
                return requiredPreferenceKey
            }
        }
        return nil
    }
}

nonisolated enum PaceUserProgramStoreError: Error, Equatable {
    case invalidProgram([String])
    case nameCollision(String)
    case identifierCollision(String)
}

nonisolated struct PaceUserProgramStore {
    static var defaultDirectoryURL: URL {
        let applicationSupportRootURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportRootURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("programs", isDirectory: true)
    }

    let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    func save(
        _ program: PaceProgramDefinition,
        existingNormalizedNames: Set<String> = [],
        existingIdentifiers: Set<String> = []
    ) throws {
        let validationMessages = PaceProgramValidator.validationIssues(for: program).map(\.message)
        guard validationMessages.isEmpty else {
            throw PaceUserProgramStoreError.invalidProgram(validationMessages)
        }

        let storedPrograms = listValidPrograms()
        let normalizedProgramName = PaceAutomationCatalog.normalizedName(program.name)
        let storedNames = Set(storedPrograms.map {
            PaceAutomationCatalog.normalizedName($0.name)
        })
        guard !existingNormalizedNames.contains(normalizedProgramName),
              !storedNames.contains(normalizedProgramName) else {
            throw PaceUserProgramStoreError.nameCollision(program.name)
        }
        let storedIdentifiers = Set(storedPrograms.map(\.identifier))
        guard !existingIdentifiers.contains(program.identifier),
              !storedIdentifiers.contains(program.identifier) else {
            throw PaceUserProgramStoreError.identifierCollision(program.identifier)
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let destinationFileURL = directoryURL
            .appendingPathComponent("\(program.identifier).json")
        guard !FileManager.default.fileExists(atPath: destinationFileURL.path) else {
            throw PaceUserProgramStoreError.identifierCollision(program.identifier)
        }
        try Self.jsonEncoder.encode(program).write(to: destinationFileURL, options: .atomic)
    }

    func listValidPrograms() -> [PaceProgramDefinition] {
        guard let programURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return programURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { programURL in
                guard let programData = try? Data(contentsOf: programURL),
                      let program = try? Self.jsonDecoder.decode(
                        PaceProgramDefinition.self,
                        from: programData
                      ),
                      programURL.deletingPathExtension().lastPathComponent == program.identifier,
                      PaceProgramValidator.validationIssues(for: program).isEmpty else {
                    return nil
                }
                return program
            }
            .sorted { firstProgram, secondProgram in
                firstProgram.name.localizedCaseInsensitiveCompare(secondProgram.name)
                    == .orderedAscending
            }
    }

    func delete(identifier: String) throws {
        let targetFileURL = directoryURL.appendingPathComponent("\(identifier).json")
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            try FileManager.default.removeItem(at: targetFileURL)
        }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let jsonDecoder = JSONDecoder()
}

nonisolated enum PaceNaturalLanguageProgramStructurer {
    static var systemPrompt: String {
        let allowedTools = PaceAutomationDefinitionValidator
            .allowedToolDefinitionsForAuthoring
            .map(\.promptLine)
            .joined(separator: "\n")
        return """
        Convert the user's repeatable task into one bounded deterministic Pace Program.
        Return ONLY one JSON object matching this schema, or {} when the task needs live judgment or unsupported authority:
        {"schemaVersion":1,"identifier":"kebab-case-name","name":"short title","description":"literal complete outcome","category":"custom","invocationPhrases":["natural phrase"],"requiredPreferences":[],"nodes":[PROGRAM_NODE]}

        PROGRAM_NODE is exactly one of:
        {"type":"action","step":{"toolCalls":[{"tool":"canonical_name","arguments":{}}]}}
        {"type":"condition","predicate":PREDICATE,"thenNodes":[PROGRAM_NODE],"otherwiseNodes":[PROGRAM_NODE]}
        {"type":"repeatTimes","count":1,"nodes":[PROGRAM_NODE]}

        PREDICATE is exactly one of:
        {"type":"weekdayIn","weekdays":[1,2,3,4,5,6,7]}
        {"type":"localHourIn","startInclusive":9,"endExclusive":17}
        {"type":"frontmostApplicationIn","bundleIdentifiers":["com.apple.Notes"]}

        Calendar weekday integers are 1=Sunday through 7=Saturday. Repeat count must be 1 through 10.
        Use only the tools listed below and copy their canonical tool names and argument keys exactly:
        \(allowedTools)

        Rules:
        - Return {} unless branching or literal repetition is necessary. Fixed sequences belong to the simpler typed automation tier.
        - Preserve only actions, conditions, counts, and values explicitly requested by the user.
        - If the user says "when I say X", put X in invocationPhrases and do not treat it as an action.
        - Do not emit source code, shell, network, file, import, Accessibility, click, typing, key, URL, Shortcut, flow, download, script, or MCP calls.
        - Do not branch on screen contents or the result of an earlier action.
        - Stay within 4 nesting levels, 50 source nodes, and 50 worst-case expanded action steps.
        """
    }

    static func program(fromStructuredJSON rawText: String) -> PaceProgramDefinition? {
        guard let jsonObject = extractJSONObject(from: rawText),
              jsonObject != "{}",
              let jsonData = jsonObject.data(using: .utf8),
              let program = try? JSONDecoder().decode(PaceProgramDefinition.self, from: jsonData),
              PaceProgramValidator.validationIssues(for: program).isEmpty else {
            return nil
        }
        return program
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
