//
//  PaceToolRegistry.swift
//  leanring-buddy
//
//  Typed catalog for local Pace tools. This is intentionally metadata
//  only today: parser, prompt, approval, and executor code can all
//  depend on one shared tool contract without introducing an MCP
//  transport boundary yet.
//

import Foundation

nonisolated enum PaceToolRiskLevel: String {
    case readOnly
    case appOrSystemMutation
    case inputInjection
    case destructive
    case externalIntegration

    var displayName: String {
        switch self {
        case .readOnly:
            return "read-only"
        case .appOrSystemMutation:
            return "app/system change"
        case .inputInjection:
            return "input injection"
        case .destructive:
            return "destructive"
        case .externalIntegration:
            return "external tool"
        }
    }
}

nonisolated enum PaceLocalToolKind: String, CaseIterable {
    case click
    case doubleClick
    case type
    case setValue
    case undo
    case key
    case clipboard
    case window
    case scroll
    case openApp
    case openURL
    case screenCapture
    case codexSession
    case meeting
    case music
    case volume
    case brightness
    case calendar
    case calendarCreate
    case reminder
    case finder
    case notes
    case mail
    case things
    case shortcuts
    case messages
    case downloadFile
    case startTimer
    case recordFlow
    case runFlow
    case generateImage
    case showDiagram
    case dismissDiagram
    case drawAnnotation
    case clearAnnotations
}

nonisolated struct PaceLocalToolDefinition {
    let kind: PaceLocalToolKind
    let canonicalName: String
    let aliases: [String]
    let schemaExample: String
    let description: String
    let riskLevel: PaceToolRiskLevel
    let executionSummary: String
    let observationSummary: String
    /// Short user-facing voice/chat phrase that would trigger this tool.
    /// Rendered in the Skills tab of `PaceMainWindow` so the user can
    /// see at a glance how to ask for each capability. Drift-checked at
    /// startup — every tool must have a non-empty utterance.
    let exampleUtterance: String

    var promptLine: String {
        "- \(schemaExample) \(description)"
    }

    var allNames: [String] {
        [canonicalName] + aliases
    }
}

nonisolated struct PaceToolRegistryValidationIssue: Equatable, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

nonisolated enum PaceToolRegistry {
    static let localTools = PacePowerCatalog.preinstalled.tools

    static func definition(forToolName rawToolName: String) -> PaceLocalToolDefinition? {
        let normalizedToolName = normalizeToolName(rawToolName)
        return localTools.first { definition in
            definition.allNames.contains(normalizedToolName)
        }
    }

    static func kind(forToolName rawToolName: String) -> PaceLocalToolKind? {
        definition(forToolName: rawToolName)?.kind
    }

    static var plannerToolListText: String {
        localTools
            .map(\.promptLine)
            .joined(separator: "\n")
    }

    static func validateForAppStartup() {
        let validationIssues = validateLocalRegistry()
            + validateBundledRegistryArtifact(
                bundle: .main,
                allowSourceTreeFallback: false
            )
            + validateBundledPlannerResponseSchemaArtifact(
                bundle: .main,
                allowSourceTreeFallback: false
            )
        // Typed automation validation runs alongside the tool registry so a
        // malformed, forbidden, or partially parsed manifest fails at launch.
        let automationValidationIssues = PaceAutomationDefinitionLibrary
            .validateBundledDefinitions(bundle: .main, allowSourceTreeFallback: false)
            .map { PaceToolRegistryValidationIssue(message: "bundled automation: \($0.message)") }
        // Meeting note profiles validate alongside automations — same
        // fail-fast contract so malformed bundled profile JSON is caught
        // at launch, not at first meeting synthesis.
        let profileValidationIssues = PaceMeetingNoteProfileLibrary
            .validateBundledProfiles(bundle: .main, allowSourceTreeFallback: false)
            .map { PaceToolRegistryValidationIssue(message: "bundled meeting note profile: \($0.message)") }
        let powerValidationIssues = PacePowerCatalog.preinstalled.validationIssues().map {
            PaceToolRegistryValidationIssue(message: "preinstalled power: \($0)")
        }
        let allValidationIssues = validationIssues + automationValidationIssues + profileValidationIssues + powerValidationIssues
        guard allValidationIssues.isEmpty else {
            let formattedIssues = allValidationIssues
                .map { "- \($0.description)" }
                .joined(separator: "\n")
            fatalError("Pace local tool registry is invalid:\n\(formattedIssues)")
        }
    }

    static func validateSourceRegistryArtifact() -> [PaceToolRegistryValidationIssue] {
        validateBundledRegistryArtifact(
            bundle: .main,
            allowSourceTreeFallback: true
        )
        + validateBundledPlannerResponseSchemaArtifact(
            bundle: .main,
            allowSourceTreeFallback: true
        )
    }

    static func validateLocalRegistry() -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        if localTools.isEmpty {
            validationIssues.append(.init(message: "registry must contain at least one local tool"))
        }

        // Hard product invariant: Pace ships NO destructive tools. Every
        // mutation must be undoable, collision-safe, or draft-only. Startup
        // fails if a destructive-risk definition is ever added, so the
        // planner can never gain access to one silently.
        for destructiveDefinition in localTools.filter({ $0.riskLevel == .destructive }) {
            validationIssues.append(.init(
                message: "\(destructiveDefinition.canonicalName) is destructive — Pace does not permit destructive tools"
            ))
        }

        let registeredKinds = Set(localTools.map(\.kind))
        let expectedKinds = Set(PaceLocalToolKind.allCases)
        for missingKind in expectedKinds.subtracting(registeredKinds).sorted(by: { $0.rawValue < $1.rawValue }) {
            validationIssues.append(.init(message: "missing local tool definition for kind \(missingKind.rawValue)"))
        }
        for duplicateKind in duplicateValues(localTools.map(\.kind)) {
            validationIssues.append(.init(message: "duplicate local tool definition for kind \(duplicateKind.rawValue)"))
        }

        var seenToolNames: [String: String] = [:]
        for definition in localTools {
            let trimmedCanonicalName = definition.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCanonicalName.isEmpty {
                validationIssues.append(.init(message: "\(definition.kind.rawValue) has an empty canonical name"))
            }

            if definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty description"))
            }
            if definition.executionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty execution summary"))
            }
            if definition.observationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty observation summary"))
            }
            if definition.exampleUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                validationIssues.append(.init(message: "\(definition.canonicalName) has an empty example utterance"))
            }

            for toolName in definition.allNames {
                let normalizedToolName = normalizeToolName(toolName)
                if normalizedToolName.isEmpty {
                    validationIssues.append(.init(message: "\(definition.canonicalName) has an empty name or alias"))
                    continue
                }
                if let existingCanonicalName = seenToolNames[normalizedToolName] {
                    validationIssues.append(.init(
                        message: "\(definition.canonicalName) reuses tool name or alias \(normalizedToolName) from \(existingCanonicalName)"
                    ))
                } else {
                    seenToolNames[normalizedToolName] = definition.canonicalName
                }
            }

            validationIssues.append(contentsOf: validateSchemaExample(definition))
        }

        return validationIssues
    }

    static func riskDisplayName(for action: PaceParsedAction) -> String {
        if case .mcp = action {
            return PaceToolRiskLevel.externalIntegration.displayName
        }
        return definition(for: action)?.riskLevel.displayName ?? "unknown"
    }

    static func definition(for action: PaceParsedAction) -> PaceLocalToolDefinition? {
        switch action {
        case .click, .clickCandidates:
            return definition(forToolName: "click")
        case .doubleClick:
            return definition(forToolName: "double_click")
        case .type:
            return definition(forToolName: "type")
        case .setTextValue, .editSelectedText:
            return definition(forToolName: "set_value")
        case .undoLastMutation:
            return definition(forToolName: "undo_last")
        case .pressKey:
            return definition(forToolName: "key")
        case .readClipboard:
            return definition(forToolName: "clipboard_read")
        case .snapWindow:
            return definition(forToolName: "window_snap")
        case .scroll:
            return definition(forToolName: "scroll")
        case .openApplication:
            return definition(forToolName: "open_app")
        case .openURL, .openBrowser:
            return definition(forToolName: "open_url")
        case .screenCapture:
            return definition(forToolName: "screen_capture")
        case .meeting:
            return definition(forToolName: "meeting")
        case .codexSession:
            return definition(forToolName: "codex_session")
        case .controlMusic:
            return definition(forToolName: "music")
        case .adjustVolume:
            return definition(forToolName: "volume")
        case .adjustBrightness:
            return definition(forToolName: "brightness")
        case .listCalendarEvents:
            return definition(forToolName: "calendar")
        case .createCalendarEvent:
            return definition(forToolName: "calendar_create")
        case .createReminder:
            return definition(forToolName: "reminder")
        case .finder:
            return definition(forToolName: "finder")
        case .createNote, .appendNote, .searchNotes:
            return definition(forToolName: "notes")
        case .composeMail:
            return definition(forToolName: "mail")
        case .createThingsToDo:
            return definition(forToolName: "things")
        case .runShortcut:
            return definition(forToolName: "shortcuts")
        case .openMessages:
            return definition(forToolName: "messages")
        case .downloadFile:
            return definition(forToolName: "download_file")
        case .startTimer:
            return definition(forToolName: "start_timer")
        case .recordFlow:
            return definition(forToolName: "record_flow")
        case .runFlow:
            return definition(forToolName: "run_flow")
        case .mcp:
            return nil
        case .generateImage:
            return definition(forToolName: "generate_image")
        case .showDiagram:
            return definition(forToolName: "show_diagram")
        case .dismissDiagram:
            return definition(forToolName: "dismiss_diagram")
        case .drawAnnotation:
            return definition(forToolName: "draw_annotation")
        case .clearAnnotations:
            return definition(forToolName: "clear_annotations")
        }
    }

    nonisolated private static func normalizeToolName(_ rawToolName: String) -> String {
        rawToolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func validateSchemaExample(
        _ definition: PaceLocalToolDefinition
    ) -> [PaceToolRegistryValidationIssue] {
        guard let schemaData = definition.schemaExample.data(using: .utf8) else {
            return [.init(message: "\(definition.canonicalName) schema example is not UTF-8")]
        }

        do {
            let decodedExample = try JSONSerialization.jsonObject(with: schemaData)
            guard let exampleObject = decodedExample as? [String: Any] else {
                return [.init(message: "\(definition.canonicalName) schema example must be a JSON object")]
            }
            guard let exampleToolName = exampleObject["tool"] as? String else {
                return [.init(message: "\(definition.canonicalName) schema example must include a string tool field")]
            }
            guard normalizeToolName(exampleToolName) == normalizeToolName(definition.canonicalName) else {
                return [.init(
                    message: "\(definition.canonicalName) schema example tool field is \(exampleToolName)"
                )]
            }
            return []
        } catch {
            return [.init(message: "\(definition.canonicalName) schema example is invalid JSON: \(error.localizedDescription)")]
        }
    }

    private static func validateBundledRegistryArtifact(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> [PaceToolRegistryValidationIssue] {
        guard let registryURL = registryArtifactURL(
            bundle: bundle,
            allowSourceTreeFallback: allowSourceTreeFallback
        ) else {
            return [.init(message: "missing v10 action registry artifact at Resources/v10-actions/registry.json")]
        }

        do {
            let registryData = try Data(contentsOf: registryURL)
            let decodedObject = try JSONSerialization.jsonObject(with: registryData)
            guard let registryObject = decodedObject as? [String: Any] else {
                return [.init(message: "v10 action registry artifact must be a JSON object")]
            }
            return validateRegistryArtifactObject(registryObject)
        } catch {
            return [.init(message: "could not read v10 action registry artifact: \(error.localizedDescription)")]
        }
    }

    private static func registryArtifactURL(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> URL? {
        let bundleCandidates = [
            bundle.url(
                forResource: "registry",
                withExtension: "json",
                subdirectory: "Resources/v10-actions"
            ),
            bundle.url(
                forResource: "registry",
                withExtension: "json",
                subdirectory: "v10-actions"
            ),
            bundle.url(
                forResource: "registry",
                withExtension: "json"
            )
        ]
        if let bundledURL = bundleCandidates.compactMap({ $0 }).first {
            return bundledURL
        }

        guard allowSourceTreeFallback else { return nil }
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceTreeURL = currentDirectoryURL
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("Resources")
            .appendingPathComponent("v10-actions")
            .appendingPathComponent("registry.json")
        return FileManager.default.fileExists(atPath: sourceTreeURL.path) ? sourceTreeURL : nil
    }

    private static func validateBundledPlannerResponseSchemaArtifact(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> [PaceToolRegistryValidationIssue] {
        guard let schemaURL = plannerResponseSchemaArtifactURL(
            bundle: bundle,
            allowSourceTreeFallback: allowSourceTreeFallback
        ) else {
            return [.init(message: "missing v10 planner response schema artifact at Resources/v10-actions/pace-fm-response-v10.schema.json")]
        }

        do {
            let schemaData = try Data(contentsOf: schemaURL)
            let decodedObject = try JSONSerialization.jsonObject(with: schemaData)
            guard let schemaObject = decodedObject as? [String: Any] else {
                return [.init(message: "v10 planner response schema artifact must be a JSON object")]
            }
            return validatePlannerResponseSchemaArtifactObject(schemaObject)
        } catch {
            return [.init(message: "could not read v10 planner response schema artifact: \(error.localizedDescription)")]
        }
    }

    private static func plannerResponseSchemaArtifactURL(
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> URL? {
        let bundleCandidates = [
            bundle.url(
                forResource: "pace-fm-response-v10.schema",
                withExtension: "json",
                subdirectory: "Resources/v10-actions"
            ),
            bundle.url(
                forResource: "pace-fm-response-v10.schema",
                withExtension: "json",
                subdirectory: "v10-actions"
            ),
            bundle.url(
                forResource: "pace-fm-response-v10.schema",
                withExtension: "json"
            )
        ]
        if let bundledURL = bundleCandidates.compactMap({ $0 }).first {
            return bundledURL
        }

        guard allowSourceTreeFallback else { return nil }
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceTreeURL = currentDirectoryURL
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("Resources")
            .appendingPathComponent("v10-actions")
            .appendingPathComponent("pace-fm-response-v10.schema.json")
        return FileManager.default.fileExists(atPath: sourceTreeURL.path) ? sourceTreeURL : nil
    }

    private static func validatePlannerResponseSchemaArtifactObject(
        _ schemaObject: [String: Any]
    ) -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        if schemaObject["title"] as? String != "Pace planner response v10" {
            validationIssues.append(.init(message: "v10 planner response schema title drift"))
        }
        if schemaObject["type"] as? String != "object" {
            validationIssues.append(.init(message: "v10 planner response schema root type must be object"))
        }
        guard let properties = schemaObject["properties"] as? [String: Any] else {
            validationIssues.append(.init(message: "v10 planner response schema must define properties"))
            return validationIssues
        }
        for requiredProperty in ["spokenText", "intent", "payload"] where properties[requiredProperty] == nil {
            validationIssues.append(.init(message: "v10 planner response schema missing property \(requiredProperty)"))
        }

        return validationIssues
    }

    private static func validateRegistryArtifactObject(
        _ registryObject: [String: Any]
    ) -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        guard let version = registryObject["version"] as? Int, version == 1 else {
            validationIssues.append(.init(message: "v10 action registry artifact version must be 1"))
            return validationIssues
        }

        guard let actionObjects = registryObject["actions"] as? [[String: Any]] else {
            validationIssues.append(.init(message: "v10 action registry artifact must contain an actions array"))
            return validationIssues
        }

        let definitionsByKind = Dictionary(uniqueKeysWithValues: localTools.map { ($0.kind.rawValue, $0) })
        let artifactKinds = actionObjects.compactMap { $0["kind"] as? String }
        let expectedKinds = Set(PaceLocalToolKind.allCases.map(\.rawValue))
        let actualKinds = Set(artifactKinds)

        for missingKind in expectedKinds.subtracting(actualKinds).sorted() {
            validationIssues.append(.init(message: "v10 action registry artifact missing kind \(missingKind)"))
        }
        for extraKind in actualKinds.subtracting(expectedKinds).sorted() {
            validationIssues.append(.init(message: "v10 action registry artifact has unknown kind \(extraKind)"))
        }
        for duplicateKind in duplicateValues(artifactKinds) {
            validationIssues.append(.init(message: "v10 action registry artifact duplicates kind \(duplicateKind)"))
        }

        for actionObject in actionObjects {
            guard let kindName = actionObject["kind"] as? String,
                  let definition = definitionsByKind[kindName] else {
                continue
            }
            validationIssues.append(contentsOf: validateRegistryArtifactAction(
                actionObject,
                definition: definition
            ))
        }

        return validationIssues
    }

    private static func validateRegistryArtifactAction(
        _ actionObject: [String: Any],
        definition: PaceLocalToolDefinition
    ) -> [PaceToolRegistryValidationIssue] {
        var validationIssues: [PaceToolRegistryValidationIssue] = []

        let artifactToolName = actionObject["tool"] as? String
        if normalizeToolName(artifactToolName ?? "") != normalizeToolName(definition.canonicalName) {
            validationIssues.append(.init(
                message: "v10 artifact kind \(definition.kind.rawValue) has tool \(artifactToolName ?? "<missing>"), expected \(definition.canonicalName)"
            ))
        }

        let artifactAliases = (actionObject["aliases"] as? [String]) ?? []
        if artifactAliases.map(normalizeToolName) != definition.aliases.map(normalizeToolName) {
            validationIssues.append(.init(message: "v10 artifact aliases drift for \(definition.canonicalName)"))
        }

        let artifactRisk = actionObject["risk"] as? String
        if artifactRisk != definition.riskLevel.rawValue {
            validationIssues.append(.init(message: "v10 artifact risk drift for \(definition.canonicalName)"))
        }

        guard let schemaExample = actionObject["schemaExample"] as? [String: Any] else {
            validationIssues.append(.init(message: "v10 artifact schemaExample missing for \(definition.canonicalName)"))
            return validationIssues
        }

        let artifactExampleToolName = schemaExample["tool"] as? String
        if normalizeToolName(artifactExampleToolName ?? "") != normalizeToolName(definition.canonicalName) {
            validationIssues.append(.init(message: "v10 artifact schemaExample tool drift for \(definition.canonicalName)"))
        }

        let artifactExampleUtterance = (actionObject["exampleUtterance"] as? String) ?? ""
        if artifactExampleUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationIssues.append(.init(message: "v10 artifact exampleUtterance missing for \(definition.canonicalName)"))
        } else if artifactExampleUtterance != definition.exampleUtterance {
            validationIssues.append(.init(message: "v10 artifact exampleUtterance drift for \(definition.canonicalName)"))
        }

        return validationIssues
    }

    private static func duplicateValues<T: Hashable>(_ values: [T]) -> [T] {
        var seenValues = Set<T>()
        var duplicateValues = Set<T>()
        for value in values {
            if !seenValues.insert(value).inserted {
                duplicateValues.insert(value)
            }
        }
        return Array(duplicateValues)
    }
}
