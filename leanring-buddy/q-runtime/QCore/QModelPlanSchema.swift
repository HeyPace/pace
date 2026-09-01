//
//  QModelPlanSchema.swift
//  leanring-buddy
//
//  Q Security Architecture — Structured Local Model Plan Schema & Parser (Phase 2B).
//  Defines the Codable contract for model-generated multi-step plans, enforces schema
//  validation, capability allowlisting, and translates raw model output into authoritative QPlan models.
//

import Foundation

// MARK: - Model Output Schema (Data only, zero authority)

public struct QModelActionSchema: Codable, Sendable, Equatable {
    public let actionName: String
    public let toolFamily: String
    public let riskLevel: String?
    public let description: String
    public let targetResources: [String]?
    public let parameters: [String: String]?

    public init(
        actionName: String,
        toolFamily: String,
        riskLevel: String? = nil,
        description: String,
        targetResources: [String]? = nil,
        parameters: [String: String]? = nil
    ) {
        self.actionName = actionName
        self.toolFamily = toolFamily
        self.riskLevel = riskLevel
        self.description = description
        self.targetResources = targetResources
        self.parameters = parameters
    }
}

public struct QModelPlanSchema: Codable, Sendable, Equatable {
    public let taskPrompt: String?
    public let summary: String?
    public let steps: [QModelActionSchema]

    public init(
        taskPrompt: String? = nil,
        summary: String? = nil,
        steps: [QModelActionSchema]
    ) {
        self.taskPrompt = taskPrompt
        self.summary = summary
        self.steps = steps
    }
}

// MARK: - Parse Errors

public enum QModelPlanParseError: Error, Equatable, Sendable {
    case emptyOutput
    case malformedJSON(String)
    case emptySteps
    case unknownCapability(toolName: String)
    case unauthorizedRiskLevel(toolName: String, risk: String)
    case stepLimitExceeded(count: Int, maxAllowed: Int)
    case missingRequiredField(String)
}

// MARK: - Schema Validator & Parser

public struct QModelPlanParser: Sendable {
    public static let maxAllowedSteps = 10

    /// Allowed tool families and their corresponding registered action names
    public static let registeredCapabilities: [String: (toolFamily: String, defaultRisk: QCapabilityLevel)] = [
        "system.running_apps": ("system", .level0ReadOnly),
        "system.clipboard.read": ("system", .level0ReadOnly),
        "screen.ocr": ("perception", .level0ReadOnly),
        "ui.open_app": ("app", .level1SafeLocalAction),
        "fs.read": ("fs", .level0ReadOnly),
        "fs.write_sandbox": ("fs", .level1SafeLocalAction),
        "test.noop": ("test", .level0ReadOnly),
        "accessibility.read": ("accessibility", .level0ReadOnly)
    ]

    /// Parses raw model text into a validated QPlan data model.
    public static func parse(
        rawText: String,
        taskId: String,
        taskPrompt: String,
        sessionId: String = "default"
    ) throws -> QPlan {
        let cleanedJSON = extractJSON(from: rawText)
        guard !cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QModelPlanParseError.emptyOutput
        }

        guard let data = cleanedJSON.data(using: .utf8) else {
            throw QModelPlanParseError.malformedJSON("Failed to encode cleaned string to UTF-8")
        }

        let schema: QModelPlanSchema
        do {
            schema = try JSONDecoder().decode(QModelPlanSchema.self, from: data)
        } catch {
            throw QModelPlanParseError.malformedJSON("JSON decoding error: \(error.localizedDescription)")
        }

        guard !schema.steps.isEmpty else {
            throw QModelPlanParseError.emptySteps
        }

        guard schema.steps.count <= maxAllowedSteps else {
            throw QModelPlanParseError.stepLimitExceeded(count: schema.steps.count, maxAllowed: maxAllowedSteps)
        }

        var validatedSteps: [QPlanStep] = []

        for (index, actionSchema) in schema.steps.enumerated() {
            guard !actionSchema.actionName.isEmpty else {
                throw QModelPlanParseError.missingRequiredField("step[\(index)].actionName")
            }

            guard let regCap = registeredCapabilities[actionSchema.actionName] else {
                throw QModelPlanParseError.unknownCapability(toolName: actionSchema.actionName)
            }

            // Derive or validate risk level
            let riskLevel: QCapabilityLevel
            if let declaredRisk = actionSchema.riskLevel {
                switch declaredRisk.lowercased() {
                case "level0", "level0readonly", "0":
                    riskLevel = .level0ReadOnly
                case "level1", "level1safelocalaction", "1":
                    riskLevel = .level1SafeLocalAction
                case "level2", "level2userapproval", "2":
                    riskLevel = .level2UserApproval
                case "level3", "level3highrisk", "3":
                    riskLevel = .level3HighRisk
                case "level4", "level4blocked", "4":
                    throw QModelPlanParseError.unauthorizedRiskLevel(toolName: actionSchema.actionName, risk: "Level 4 (Blocked)")
                default:
                    riskLevel = regCap.defaultRisk
                }
            } else {
                riskLevel = regCap.defaultRisk
            }

            let plannedAction = QPlannedAction(
                actionName: actionSchema.actionName,
                toolFamily: regCap.toolFamily,
                riskLevel: riskLevel,
                literalAction: actionSchema.description,
                targetResources: actionSchema.targetResources ?? [],
                arguments: actionSchema.parameters ?? [:]
            )

            let step = QPlanStep(
                index: index,
                action: plannedAction,
                description: actionSchema.description.isEmpty ? "\(actionSchema.actionName)" : actionSchema.description
            )
            validatedSteps.append(step)
        }

        return QPlan(
            taskId: taskId,
            sessionId: sessionId,
            taskPrompt: taskPrompt,
            steps: validatedSteps
        )
    }

    /// Strips markdown code block wrappers (e.g. ```json ... ```) and extracts raw JSON object
    public static func extractJSON(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("```json") {
            if let startRange = trimmed.range(of: "```json") {
                let afterStart = trimmed[startRange.upperBound...]
                if let endRange = afterStart.range(of: "```") {
                    return String(afterStart[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } else if trimmed.contains("```") {
            if let startRange = trimmed.range(of: "```") {
                let afterStart = trimmed[startRange.upperBound...]
                if let endRange = afterStart.range(of: "```") {
                    return String(afterStart[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Extract between first { and last }
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            return String(trimmed[firstBrace...lastBrace])
        }

        return trimmed
    }
}
