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

    /// Allowed tool families and their corresponding registered action names.
    ///
    /// Phase 2E adds the first two controlled mutating capabilities above Level 1:
    /// `system.clipboard.write` (Level 2 — reversible local action; overwrites the pasteboard,
    /// trivially undone by copying something else) and `app.quit` (Level 3 — mutating action
    /// with meaningful user impact; terminates a running application). Both flow through the
    /// same QResourceGuard -> QPermissionGate -> approval -> QPlanExecutor -> QExecutionService
    /// pipeline as every other capability; the model never gains direct execution authority.
    public static let registeredCapabilities: [String: (toolFamily: String, defaultRisk: QCapabilityLevel)] = [
        "system.running_apps": ("system", .level0ReadOnly),
        "system.clipboard.read": ("system", .level0ReadOnly),
        "screen.ocr": ("perception", .level0ReadOnly),
        "ui.open_app": ("app", .level1SafeLocalAction),
        "fs.read": ("fs", .level0ReadOnly),
        "fs.write_sandbox": ("fs", .level1SafeLocalAction),
        "test.noop": ("test", .level0ReadOnly),
        "accessibility.read": ("accessibility", .level0ReadOnly),
        "system.clipboard.write": ("system", .level2UserApproval),
        "app.quit": ("app", .level3HighRisk),
        // Phase 2H: semantic AXUIElement click — Level 2 (reversible local action). The target
        // MUST identify an Accessibility element semantically (role + identifier or title/
        // description); raw screen coordinates are never an accepted parameter for this tool. See
        // QBridgeAccessibility.clickElement and docs/PHASE_2H_SEMANTIC_CLICK.md for the full
        // resolution / observation-binding / verification contract.
        "ui.click_element": ("ui", .level2UserApproval),
        // Phase 2I: semantic AX text-entry write — Level 2 (reversible local action). The target
        // MUST identify an Accessibility element semantically (role + identifier or title) AND
        // the role MUST be on QAXTextEntryRolePolicy's allowlist (AXTextField/AXTextArea only —
        // never AXSecureTextField, never an unrecognized role). The target must already be the
        // system's genuinely focused element; this tool never clicks/focuses a field itself.
        // Mutation is AXUIElementSetAttributeValue(kAXValueAttribute) only — never CGEvent,
        // keyboard simulation, or Return/Tab/submit. Its `value` parameter is declared sensitive
        // in QSensitiveArgumentPolicy — masked before durable persistence and never used to
        // build approval/HUD display text. See QBridgeAccessibility.setTextValue and
        // docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md for the full contract.
        "ui.set_text_value": ("ui", .level2UserApproval)
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

            // Risk classification is strictly authoritative from the registered capability
            // allowlist — model-declared risk text is untrusted data and is NEVER used to set
            // or downgrade the enforced risk level. A declared value is optional (the common
            // case: trust the registry outright), but if the model DOES declare one, it must
            // exactly match this tool's registered risk level; any mismatch — an unrecognized
            // string, an attempt to claim Level 4, or simply the wrong level for this tool
            // (e.g. claiming Level 0 for a Level 3 tool to try to dodge the approval gate) —
            // is rejected outright rather than silently coerced to the registered value.
            if let declaredRisk = actionSchema.riskLevel {
                guard let parsedDeclaredRisk = QCapabilityLevel.parse(declaredRisk) else {
                    throw QModelPlanParseError.unauthorizedRiskLevel(toolName: actionSchema.actionName, risk: declaredRisk)
                }
                guard parsedDeclaredRisk == regCap.defaultRisk else {
                    throw QModelPlanParseError.unauthorizedRiskLevel(toolName: actionSchema.actionName, risk: declaredRisk)
                }
            }
            let riskLevel = regCap.defaultRisk

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
