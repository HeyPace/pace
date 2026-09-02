//
//  QSensitiveArgumentPolicy.swift
//  leanring-buddy
//
//  Q Security Architecture — Sensitive Argument Policy (Phase 2I remediation).
//  A single, canonical table of which model-supplied step arguments carry values that must
//  never be persisted, displayed, or logged verbatim, keyed by tool name.
//
//  `ui.set_text_value` is NOT a registered/executable Q capability today — it does not appear
//  in `QModelPlanParser.registeredCapabilities`, so `QModelPlanParser.parse` rejects it with
//  `.unknownCapability` and it can never actually be planned or executed. This table
//  pre-declares the redaction contract that capability's future implementation MUST honor
//  (its `value` parameter), so the durable-persistence and approval-description boundaries
//  that consult this table are already correct on day one of that implementation, rather than
//  requiring a second, separate remediation once the capability itself lands. See
//  docs/PHASE_2I_TEXT_ENTRY_SECURITY_REMEDIATION.md for the full analysis this closes.
//

import Foundation

public enum QSensitiveArgumentPolicy {
    /// Per-tool-name argument keys whose values are sensitive free text (as opposed to
    /// identifiers, roles, titles, or other non-secret targeting metadata) and must never be
    /// persisted, displayed, or logged verbatim.
    public static let sensitiveArgumentKeysByToolName: [String: Set<String>] = [
        "ui.set_text_value": ["value"]
    ]

    /// Whether `key` is a declared-sensitive argument for `toolName`.
    public static func isSensitiveArgument(toolName: String, key: String) -> Bool {
        sensitiveArgumentKeysByToolName[toolName]?.contains(key) ?? false
    }

    /// Whether `toolName` has ANY declared-sensitive arguments at all — used by callers that
    /// need to decide whether to trust a generic, model-authored description string (e.g. an
    /// approval prompt) or fall back to a safe, template-built description instead.
    public static func hasSensitiveArguments(toolName: String) -> Bool {
        !(sensitiveArgumentKeysByToolName[toolName]?.isEmpty ?? true)
    }

    /// Replaces a sensitive argument's raw value with a length-preserving placeholder — the
    /// value's character count is useful audit/debugging metadata and is not itself sensitive
    /// (it does not identify content), so it is kept; the literal text is not.
    public static func redactedPlaceholder(forRawValue rawValue: String) -> String {
        "[REDACTED_SENSITIVE_ARGUMENT:length=\(rawValue.count)]"
    }

    /// Applies the sensitive-argument policy to a full arguments dictionary for `toolName`,
    /// masking only the declared-sensitive keys and leaving every other key (and every other
    /// tool's arguments entirely) byte-for-byte unchanged. Deterministic and side-effect-free.
    public static func redactedArguments(toolName: String, arguments: [String: String]) -> [String: String] {
        guard let sensitiveKeys = sensitiveArgumentKeysByToolName[toolName], !sensitiveKeys.isEmpty else {
            return arguments
        }
        var redacted = arguments
        for key in sensitiveKeys {
            if let rawValue = redacted[key] {
                redacted[key] = redactedPlaceholder(forRawValue: rawValue)
            }
        }
        return redacted
    }

    /// Builds the pre-approval HUD/description text for a step whose tool has declared-sensitive
    /// arguments, from non-sensitive targeting metadata only (application name, then identifier
    /// or title or role) — never from a sensitive argument's raw value, and never from the
    /// model's free-text `literalAction`/description, which the generic approval path otherwise
    /// trusts verbatim (`QPermissionGate`'s `expectedEffect: request.literalAction`). Every tool
    /// with no declared-sensitive arguments — i.e. every capability actually registered/
    /// executable today — passes through `fallbackLiteralAction` unchanged, so this has zero
    /// effect on existing approval UX for `ui.click_element`, `app.quit`,
    /// `system.clipboard.write`, etc. The phrasing below assumes a text-entry-shaped sensitive
    /// argument, matching the one entry `QSensitiveArgumentPolicy` declares today
    /// (`ui.set_text_value`'s `value`); a future non-text sensitive argument would need its own
    /// phrasing, not a change to this function's gating.
    public static func approvalSafeLiteralAction(
        toolName: String,
        arguments: [String: String],
        fallbackLiteralAction: String
    ) -> String {
        guard hasSensitiveArguments(toolName: toolName) else {
            return fallbackLiteralAction
        }
        let applicationName = arguments["applicationName"] ?? "the active application"
        let targetDescriptor = arguments["identifier"] ?? arguments["title"] ?? arguments["role"] ?? "the target field"
        return "Allow Q to enter text into \u{201C}\(applicationName) \u{2192} \(targetDescriptor)\u{201D}?"
    }
}
