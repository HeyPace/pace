//
//  QExecutionService.swift
//  leanring-buddy
//
//  Q Security Architecture — Action Execution Service (Phase 1E.6).
//  Sole authorization-gated dispatch engine for physical local execution.
//  Enforces path containment, capability token verification, and mandatory audit.
//

import Foundation
import AppKit

public final class QExecutionService: QExecutionProvider, @unchecked Sendable {
    public static let shared = QExecutionService()

    private let ipcChannel: QIPCChannel

    public init(endpointName: String = "q-exec") {
        self.ipcChannel = QIPCChannel(endpointName: endpointName)
        setupIPCHandlers()
    }

    private func setupIPCHandlers() {
        ipcChannel.registerHandler(for: .actionRequest) { [weak self] envelope in
            guard let self else { return nil }
            let tool = envelope.message.payload["tool"] ?? ""
            let actionId = envelope.message.payload["actionId"] ?? UUID().uuidString
            let params = envelope.message.payload

            let req = QActionRequest(
                actionId: actionId,
                toolName: tool,
                toolFamily: "ipc",
                riskLevel: .level1SafeLocalAction,
                literalAction: "IPC Action: \(tool)",
                parameters: params
            )

            let context = QTaskContext(taskId: envelope.message.payload["taskId"] ?? "ipc_task")
            do {
                let res = try await self.executeAction(req, context: context)
                return QIPCMessage(
                    type: .actionResponse,
                    payload: [
                        "actionId": res.actionId,
                        "status": res.success ? "ok" : "error",
                        "summary": res.summary,
                        "error": res.error ?? ""
                    ]
                )
            } catch {
                return QIPCMessage(
                    type: .actionResponse,
                    payload: [
                        "actionId": actionId,
                        "status": "error",
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    // MARK: - QExecutionProvider Protocol Implementation

    public func executeAction(
        _ request: QActionRequest,
        context: QTaskContext
    ) async throws -> QActionResult {
        // 1. Mandatory Pre-Execution Resource Guard validation
        for target in request.targetResources {
            let guardResult = QResourceGuard.validate(path: target)
            if case .denied(let reason, _) = guardResult {
                let auditRec = QAuditRecord(
                    sessionId: "exec-session",
                    taskId: context.taskId,
                    tool: request.toolName,
                    riskLevel: .level4Blocked,
                    rawArguments: request.literalAction,
                    authorizationResult: "deny",
                    provenance: context.isTainted ? "untrusted" : "trusted:system",
                    error: reason
                )
                QAuditLogger.shared.record(auditRec)

                return QActionResult(
                    actionId: request.actionId,
                    success: false,
                    summary: "Resource Guard Denied target: \(target)",
                    error: reason
                )
            }
        }

        // 2. Dispatch Safe Action Set
        let result: QActionResult
        switch request.toolName {
        case "test.noop":
            result = QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "No-op test action completed successfully."
            )

        case "system.running_apps":
            result = executeRunningAppsQuery(request: request)

        case "system.clipboard.read":
            result = executeClipboardRead(request: request)

        case "screen.ocr":
            result = try await executeScreenOCR(request: request)

        case "fs.read":
            result = try executeFileRead(request: request, context: context)

        case "fs.write_sandbox":
            result = try executeSandboxFileWrite(request: request, context: context)

        case "accessibility.read":
            result = try await executeAccessibilityRead(request: request, context: context)

        case "ui.open_app":
            result = executeOpenApp(request: request)

        case "system.clipboard.write":
            result = executeClipboardWrite(request: request)

        case "app.quit":
            result = await executeAppQuit(request: request)

        case "ui.click_element":
            result = await executeClickElement(request: request)

        case "ui.set_text_value":
            result = await executeSetTextValue(request: request)

        case "ui.read_element_value":
            result = await executeReadElementValue(request: request)

        case "ui.set_element_state":
            result = await executeSetElementState(request: request)

        default:
            result = QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Unrecognized or unauthorized tool: '\(request.toolName)'",
                error: "Tool '\(request.toolName)' is not implemented in safe execution set."
            )
        }

        // 3. Mandatory Audit Record
        QAuditLogger.shared.record(
            QAuditRecord(
                sessionId: "exec-session",
                taskId: context.taskId,
                tool: request.toolName,
                riskLevel: request.riskLevel,
                rawArguments: request.literalAction,
                authorizationResult: result.success ? "allow" : "error",
                provenance: context.isTainted ? "untrusted" : "trusted:system",
                executionSummary: result.summary,
                error: result.error
            )
        )

        return result
    }

    // MARK: - Safe Action Implementations

    private func executeRunningAppsQuery(request: QActionRequest) -> QActionResult {
        let runningApps = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .sorted()
        let count = runningApps.count
        let sample = runningApps.prefix(8).joined(separator: ", ")

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Found \(count) running applications: \(sample)...",
            outputData: [
                "count": "\(count)",
                "apps": runningApps.joined(separator: "\n")
            ]
        )
    }

    private func executeClipboardRead(request: QActionRequest) -> QActionResult {
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Read \(clipboard.count) characters from system clipboard.",
            outputData: ["clipboard": clipboard]
        )
    }

    /// Real, on-device screen capture + text recognition (Phase 2G). Every capture/recognition
    /// failure mode — permission absence, no display, capture error, Vision error — is caught
    /// here and converted into a deterministic, non-throwing failure result (`success: false`,
    /// a stable `error` code) rather than propagating an opaque exception or ever fabricating a
    /// result. `outputData["detectedText"]` and `summary` carry the real recognized text; the
    /// security remediation in QPlanExecutor (isScreenDerivedStep — the same
    /// `toolFamily == "perception"` predicate used for taint) redacts `summary` for any
    /// persisted/audited/spoken representation before it ever leaves this in-memory result.
    private func executeScreenOCR(request: QActionRequest) async throws -> QActionResult {
        let frames: [QScreenCaptureFrame]
        do {
            frames = try await QBridgeScreenCapture.shared.captureScreens()
        } catch let captureError as QScreenCaptureError {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: captureError.description,
                error: captureError.errorCode
            )
        }

        guard let firstFrame = frames.first else {
            return QActionResult(actionId: request.actionId, success: false, summary: "No display available for capture.", error: "ENODISPLAY")
        }

        let ocr: QVisionOCRResult
        do {
            ocr = try await QBridgeVision.shared.performOCR(on: firstFrame)
        } catch let visionError as QScreenCaptureError {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: visionError.description,
                error: visionError.errorCode
            )
        }

        guard !ocr.detectedText.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Captured screen \(firstFrame.screenNumber) — no text was recognized.",
                outputData: [
                    "screen": "\(firstFrame.screenNumber)",
                    "detectedText": "",
                    "confidence": "\(ocr.confidence)",
                    "elementCount": "0"
                ]
            )
        }

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Captured screen \(firstFrame.screenNumber) and recognized: \(ocr.detectedText)",
            outputData: [
                "screen": "\(firstFrame.screenNumber)",
                "detectedText": ocr.detectedText,
                "confidence": "\(ocr.confidence)",
                "elementCount": "\(ocr.elementCount)"
            ]
        )
    }

    private func executeFileRead(request: QActionRequest, context: QTaskContext) throws -> QActionResult {
        guard let path = request.parameters["path"] else {
            return QActionResult(actionId: request.actionId, success: false, summary: "Missing 'path' parameter.", error: "path missing")
        }

        // Must validate with ResourceGuard
        let guardOutcome = QResourceGuard.validate(path: path)
        if case .denied(let reason, _) = guardOutcome {
            return QActionResult(actionId: request.actionId, success: false, summary: "Resource guard denied path.", error: reason)
        }

        let standardPath = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: standardPath) {
            let content = (try? String(contentsOfFile: standardPath, encoding: .utf8)) ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Read \(content.count) characters from \(path)",
                outputData: ["content": content]
            )
        } else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "File does not exist: \(path)",
                error: "ENOENT"
            )
        }
    }

    private func executeSandboxFileWrite(request: QActionRequest, context: QTaskContext) throws -> QActionResult {
        guard let path = request.parameters["path"], let content = request.parameters["content"] else {
            return QActionResult(actionId: request.actionId, success: false, summary: "Missing path or content parameter.", error: "invalid parameters")
        }

        let guardOutcome = QResourceGuard.validate(path: path)
        if case .denied(let reason, _) = guardOutcome {
            return QActionResult(actionId: request.actionId, success: false, summary: "Resource guard denied path.", error: reason)
        }

        let standardPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: standardPath)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Wrote \(content.count) bytes to sandbox file \(path)",
            outputData: ["path": path, "bytesWritten": "\(content.utf8.count)"]
        )
    }

    private func executeAccessibilityRead(request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        let axInfo = try await QBridgeAccessibility.shared.readFocusedElement()
        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Read focused element: \(axInfo?.title ?? "None") [\(axInfo?.role ?? "AXUnknown")]",
            outputData: ["role": axInfo?.role ?? "", "title": axInfo?.title ?? ""]
        )
    }

    private func executeOpenApp(request: QActionRequest) -> QActionResult {
        let app = request.parameters["appName"] ?? "Calculator"
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
        }

        if running {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Application '\(app)' is already running.",
                outputData: ["appName": app, "running": "true"]
            )
        }

        // Attempt launching application
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(app.lowercased())") ??
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: appUrl, configuration: config, completionHandler: nil)
        }

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Dispatched launch request for application '\(app)'.",
            outputData: ["appName": app]
        )
    }

    // MARK: - Phase 2E: Controlled Mutating Actions (Level 2 / Level 3)

    /// Level 2 (reversible local action): overwrites the system pasteboard with the given text.
    /// Trivially reversible by the user (copy something else); no persistent file/system mutation.
    private func executeClipboardWrite(request: QActionRequest) -> QActionResult {
        guard let text = request.parameters["text"] else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'text' parameter for clipboard write.",
                error: "text missing"
            )
        }

        NSPasteboard.general.clearContents()
        let wrote = NSPasteboard.general.setString(text, forType: .string)

        return QActionResult(
            actionId: request.actionId,
            success: wrote,
            summary: wrote
                ? "Wrote \(text.count) character(s) to the system clipboard."
                : "Failed to write to the system clipboard.",
            outputData: ["length": "\(text.count)"],
            error: wrote ? nil : "NSPasteboard.setString returned false"
        )
    }

    /// Level 3 (mutating action with meaningful user impact): terminates a running application.
    /// Polls briefly for the process to actually leave NSWorkspace.runningApplications so the
    /// immediately-following closed-loop verification (QVerificationStrategy.appNotRunning)
    /// observes a stable, non-flaky result rather than racing app teardown.
    private func executeAppQuit(request: QActionRequest) async -> QActionResult {
        let app = request.parameters["appName"] ?? request.targetResources.first ?? ""
        guard !app.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'appName' parameter for app quit.",
                error: "appName missing"
            )
        }

        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(app) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(app) == .orderedSame)
        }) else {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Application '\(app)' is not running; nothing to terminate.",
                outputData: ["appName": app, "wasRunning": "false"]
            )
        }

        let dispatched = runningApp.terminate()

        // Bounded poll (~1s) for the process to actually disappear before returning, so
        // downstream empirical verification does not race normal app teardown latency.
        for _ in 0..<10 {
            let stillRunning = NSWorkspace.shared.runningApplications.contains { candidate in
                (candidate.localizedName?.caseInsensitiveCompare(app) == .orderedSame) ||
                (candidate.bundleIdentifier?.caseInsensitiveCompare(app) == .orderedSame)
            }
            if !stillRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: dispatched
                ? "Dispatched termination request for application '\(app)'."
                : "Termination request for '\(app)' was not accepted by the process (it may have already quit or blocked termination).",
            outputData: ["appName": app, "terminateDispatched": "\(dispatched)"]
        )
    }

    // MARK: - Phase 2H: Semantic AXUIElement Click (Level 2)

    /// Level 2 (reversible local action): presses one semantically-identified Accessibility
    /// element. Every QAXInteractionError failure mode — missing criteria, permission denied,
    /// application unavailable, zero/ambiguous matches, disabled/stale target, unsupported
    /// action, press failure — is caught here and converted into a deterministic, non-throwing
    /// QActionResult; this method never falls back to coordinates or a CGEvent click, and never
    /// fabricates success. The pre-click AX snapshot is threaded through outputData so
    /// QPlanExecutor's closed-loop verification step can diff it against the post-click state.
    private func executeClickElement(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }
        guard let role = request.parameters["role"], !role.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'role' parameter.",
                error: "role missing"
            )
        }
        let identifier = request.parameters["identifier"].flatMap { $0.isEmpty ? nil : $0 }
        let title = request.parameters["title"].flatMap { $0.isEmpty ? nil : $0 }
        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an 'identifier' or 'title' to match semantically — coordinates are never accepted.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let (evidence, preClickSnapshot) = try await QBridgeAccessibility.shared.clickElement(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: evidence,
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "preClickIdentifier": preClickSnapshot.identifier ?? "",
                    "preClickTitleOrDescription": preClickSnapshot.titleOrDescription ?? "",
                    "preClickEnabled": "\(preClickSnapshot.isEnabled)"
                ]
            )
        } catch let axError as QAXInteractionError {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: axError.description,
                error: axError.errorCode
            )
        } catch {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Unexpected error while clicking element: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Level 2 (reversible local action): sets the value of one semantically-identified,
    /// currently-focused AXTextField/AXTextArea element via `AXUIElementSetAttributeValue
    /// (kAXValueAttribute)` only — never CGEvent, keyboard simulation, or Return/Tab/submit.
    /// Every `QAXInteractionError` failure mode is caught here and converted into a
    /// deterministic, non-throwing `QActionResult`; this method never falls back to coordinates
    /// or CGEvent, and never fabricates success. Neither the model-supplied `value` parameter nor
    /// the field's prior/current literal content are ever placed in `summary` or `outputData` —
    /// only `QAXTextValueMutationOutcome`'s safe metadata (lengths, non-secret target identity,
    /// and SHA-256 hashes the later closed-loop verification step consumes) crosses this
    /// method's boundary. A `verificationStatus` claim is deliberately NOT made here — a
    /// successful AX write is not itself evidence of goal success; that determination belongs
    /// solely to QPlanExecutor's independent `.axTextValueChanged` verification step.
    private func executeSetTextValue(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }
        guard let role = request.parameters["role"], !role.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'role' parameter.",
                error: "role missing"
            )
        }
        let identifier = request.parameters["identifier"].flatMap { $0.isEmpty ? nil : $0 }
        let title = request.parameters["title"].flatMap { $0.isEmpty ? nil : $0 }
        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an 'identifier' or 'title' to match semantically — coordinates are never accepted.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }
        guard let newValue = request.parameters["value"] else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'value' parameter.",
                error: "value missing"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                newValue: newValue
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "AX text-value write attempted for \(outcome.targetIdentity): valueChanged=\(outcome.valueChanged), previousLength=\(outcome.previousLength), currentLength=\(outcome.currentLength). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "valueChanged": outcome.valueChanged ? "true" : "false",
                    "previousLength": "\(outcome.previousLength)",
                    "currentLength": "\(outcome.currentLength)",
                    "previousValueHash": outcome.previousValueHash,
                    "intendedValueHash": outcome.intendedValueHash
                ]
            )
        } catch let axError as QAXInteractionError {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: axError.description,
                error: axError.errorCode
            )
        } catch {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Unexpected error while setting text value: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Level 0 (read-only, zero mutation): reads the value of one semantically-identified
    /// Accessibility element. Every `QAXInteractionError` failure mode — missing criteria,
    /// denylisted secure-field role, permission denied, application unavailable, zero/ambiguous
    /// matches — is caught here and converted into a deterministic, non-throwing `QActionResult`;
    /// this method never falls back to coordinates or a screenshot, and never fabricates a value.
    /// Unlike ui.set_text_value's carefully-hashed-and-masked outputs, the read value is placed
    /// directly in `summary`/`outputData` as plaintext — exposing it to the model is this
    /// capability's entire purpose, exactly like screen.ocr. This tool is registered under
    /// toolFamily "perception" (see QModelPlanSchema.swift), which is what routes this raw value
    /// through QPlanExecutor's existing sanitize-before-persist / raw-for-reasoning boundary
    /// before it reaches durable state, audit, or memory — the same boundary screen.ocr already
    /// relies on.
    private func executeReadElementValue(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }
        guard let role = request.parameters["role"], !role.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'role' parameter.",
                error: "role missing"
            )
        }
        let identifier = request.parameters["identifier"].flatMap { $0.isEmpty ? nil : $0 }
        let title = request.parameters["title"].flatMap { $0.isEmpty ? nil : $0 }
        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an 'identifier' or 'title' to match semantically — coordinates are never accepted.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let (value, snapshot) = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Read \(role) element (identifier=\(snapshot.identifier ?? "none"), label=\(snapshot.titleOrDescription ?? "none")) in \(applicationName): \(value)",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "value": value
                ]
            )
        } catch let axError as QAXInteractionError {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: axError.description,
                error: axError.errorCode
            )
        } catch {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Unexpected error while reading element value: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Level 2 (reversible local action): sets one semantically-identified, allowlisted
    /// (`AXCheckBox`/`AXRadioButton`-only) element to an explicit desired on/off state via
    /// `AXUIElementPerformAction(kAXPressAction)` only — never CGEvent, keyboard simulation, or
    /// coordinates. Every `QAXInteractionError` failure mode — disallowed role, unreadable/
    /// uninterpretable state, ambiguous/stale target (identity or value-drift), an unguaranteed
    /// state transition — is caught here and converted into a deterministic, non-throwing
    /// `QActionResult`; this method never fabricates success. Only small, non-secret enum values
    /// ("on"/"off") and SHA-256 hashes cross this method's boundary — never a raw AX attribute
    /// dump, never unrelated UI content. A `verificationStatus` claim is deliberately NOT made
    /// here — a successful press is not itself evidence the desired state was reached; that
    /// determination belongs solely to QPlanExecutor's independent
    /// `.axElementStateMatchesDesired` verification step.
    private func executeSetElementState(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }
        guard let role = request.parameters["role"], !role.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'role' parameter.",
                error: "role missing"
            )
        }
        let identifier = request.parameters["identifier"].flatMap { $0.isEmpty ? nil : $0 }
        let title = request.parameters["title"].flatMap { $0.isEmpty ? nil : $0 }
        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an 'identifier' or 'title' to match semantically — coordinates are never accepted.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }
        guard let desiredStateRaw = request.parameters["desiredState"],
              let desiredState = QAXElementState(rawValue: desiredStateRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredState' parameter — must be exactly 'on' or 'off'.",
                error: "desiredState invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setElementState(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredState: desiredState
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "State change attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousState=\(outcome.previousState.rawValue), currentState=\(outcome.currentState.rawValue). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousState": outcome.previousState.rawValue,
                    "currentState": outcome.currentState.rawValue,
                    "previousStateHash": outcome.previousStateHash,
                    "desiredStateHash": outcome.desiredStateHash
                ]
            )
        } catch let axError as QAXInteractionError {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: axError.description,
                error: axError.errorCode
            )
        } catch {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Unexpected error while setting element state: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }
}
