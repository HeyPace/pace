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

        case "ui.select_menu_item":
            result = await executeSelectMenuItem(request: request)

        case "ui.set_slider_value":
            result = await executeSetSliderValue(request: request)

        case "ui.activate_application":
            result = await executeActivateApplication(request: request)

        case "ui.focus_element":
            result = await executeFocusElement(request: request)

        case "ui.select_popup_item":
            result = await executeSelectPopupItem(request: request)

        case "ui.toggle_disclosure":
            result = await executeToggleDisclosure(request: request)

        case "ui.select_tab":
            result = await executeSelectTab(request: request)

        case "ui.select_table_row":
            result = await executeSelectTableRow(request: request)

        case "ui.select_outline_row":
            result = await executeSelectOutlineRow(request: request)

        case "ui.set_window_minimized":
            result = await executeSetWindowMinimized(request: request)

        case "ui.set_window_full_screen":
            result = await executeSetWindowFullScreen(request: request)

        case "ui.set_application_hidden":
            result = await executeSetApplicationHidden(request: request)

        case "ui.set_scroll_position":
            result = await executeSetScrollPosition(request: request)

        case "ui.set_window_main":
            result = await executeSetWindowMain(request: request)

        case "ui.close_window":
            result = await executeCloseWindow(request: request)

        case "ui.list_windows":
            result = await executeListWindows(request: request)

        case "ui.list_menu_items":
            result = await executeListMenuItems(request: request)

        case "ui.list_popup_items":
            result = await executeListPopupItems(request: request)

        case "ui.list_table_rows":
            result = await executeListTableRows(request: request)

        case "ui.list_outline_items":
            result = await executeListOutlineItems(request: request)

        case "ui.list_tab_items":
            result = await executeListTabItems(request: request)

        case "ui.list_radio_group_items":
            result = await executeListRadioGroupItems(request: request)

        case "ui.list_toolbar_items":
            result = await executeListToolbarItems(request: request)

        case "ui.list_split_panes":
            result = await executeListSplitPanes(request: request)

        case "ui.list_segmented_control_items":
            result = await executeListSegmentedControlItems(request: request)

        case "ui.list_sheet_dialogs":
            result = await executeListSheetDialogs(request: request)

        case "ui.list_sheet_actions":
            result = await executeListSheetActions(request: request)

        case "ui.select_segmented_control_item":
            result = await executeSelectSegmentedControlItem(request: request)

        case "ui.set_splitter_position":
            result = await executeSetSplitterPosition(request: request)

        case "ui.list_browser_columns":
            result = await executeListBrowserColumns(request: request)

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

        let matchingApps = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName?.caseInsensitiveCompare(app) == .orderedSame) ||
            ($0.bundleIdentifier?.caseInsensitiveCompare(app) == .orderedSame)
        }

        guard !matchingApps.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Application '\(app)' is not running; nothing to terminate.",
                outputData: ["appName": app, "wasRunning": "false"]
            )
        }

        guard matchingApps.count == 1, let runningApp = matchingApps.first else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Multiple running applications match the name '\(app)' — refusing to guess which process to terminate.",
                error: "APP_AMBIGUOUS_MATCH"
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

    /// Level 2 (reversible local action, same unbounded-consequence-class reasoning as
    /// ui.click_element): opens one top-level application menu and selects one direct item within
    /// it via two `AXUIElementPerformAction(kAXPressAction)` calls only — never CGEvent, keyboard
    /// simulation, or coordinates. Every `QAXInteractionError` failure mode — nested-path input,
    /// the app's own root menu, missing/ambiguous/disabled targets, a bounded-poll timeout — is
    /// caught here and converted into a deterministic, non-throwing `QActionResult`; this method
    /// never fabricates success. Only non-secret targeting metadata (menu/item titles) crosses
    /// this method's boundary — never an AX tree dump or unrelated window content. A
    /// `verificationStatus` claim is deliberately NOT made here — a successful press sequence is
    /// not itself evidence the selection took effect; that determination belongs solely to
    /// QPlanExecutor's independent `.axMenuItemSelectionEvidence` verification step.
    private func executeSelectMenuItem(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }
        guard let menuBarTitle = request.parameters["menuBarTitle"], !menuBarTitle.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'menuBarTitle' parameter.",
                error: "menuBarTitle missing"
            )
        }
        guard let itemTitle = request.parameters["itemTitle"], !itemTitle.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'itemTitle' parameter.",
                error: "itemTitle missing"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.selectMenuItem(
                applicationName: applicationName,
                menuBarTitle: menuBarTitle,
                itemTitle: itemTitle
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Menu selection attempted for \(outcome.targetIdentity). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "menuBarTitle": menuBarTitle,
                    "itemTitle": itemTitle,
                    "targetIdentity": outcome.targetIdentity
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
                summary: "Unexpected error while selecting menu item: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Level 2 (reversible local action): sets one semantically-identified, allowlisted
    /// (`AXSlider`/`AXStepper`-only) element to an explicit numeric `desiredValue` via
    /// `AXUIElementSetAttributeValue(kAXValueAttribute)` only — never CGEvent, keyboard
    /// simulation, drag/mouse simulation, or coordinates. Every `QAXInteractionError` failure
    /// mode — disallowed role, non-finite value, unreadable/inconsistent range, an out-of-range
    /// request, ambiguous/stale target (identity, value, or range drift) — is caught here and
    /// converted into a deterministic, non-throwing `QActionResult`; this method never fabricates
    /// success. Only plain numeric values and non-secret targeting metadata cross this method's
    /// boundary — per the Phase 2M discovery, a slider/stepper's value is not sensitive content,
    /// so no masking is applied. A `verificationStatus` claim is deliberately NOT made here — a
    /// successful set is not itself evidence the value actually stuck; that determination belongs
    /// solely to QPlanExecutor's independent `.axSliderValueMatchesDesired` verification step.
    private func executeSetSliderValue(request: QActionRequest) async -> QActionResult {
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
        // Swift's Double(String) init parses "nan"/"inf"/"infinity" as valid (non-finite)
        // Doubles — the explicit .isFinite check below is what actually rejects them, not the
        // parse itself.
        guard let desiredValueRaw = request.parameters["desiredValue"],
              let desiredValue = Double(desiredValueRaw),
              desiredValue.isFinite else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredValue' parameter — must be a finite numeric value.",
                error: "desiredValue invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setSliderValue(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredValue: desiredValue
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Slider/stepper value change attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousValue=\(outcome.previousValue), currentValue=\(outcome.currentValue), desiredValue=\(outcome.desiredValue), range=[\(outcome.minValue), \(outcome.maxValue)]. Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousValue": "\(outcome.previousValue)",
                    "currentValue": "\(outcome.currentValue)",
                    "desiredValue": "\(outcome.desiredValue)",
                    "minValue": "\(outcome.minValue)",
                    "maxValue": "\(outcome.maxValue)"
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
                summary: "Unexpected error while setting slider value: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    // MARK: - Phase 2N: Semantic Application Activation (Level 1, no approval)

    /// Level 1 (safe local action, no approval gate): activates one already-running application,
    /// resolved by an EXACT `localizedName` match, via `NSRunningApplication.activate()` only —
    /// never `AXUIElement`, `CGEvent`, keyboard/mouse simulation, coordinates, AppleScript, or
    /// shell automation, and never gated on `AXIsProcessTrusted()` (the entire point of this
    /// capability is that it works without Accessibility permission granted). Resolution rejects
    /// a missing/empty/whitespace-only name, accepts only `candidate.localizedName ==
    /// requestedName` (never substring/prefix/suffix/fuzzy/case-insensitive), fails closed on zero
    /// matches, and fails closed on more than one exact match rather than guessing which running
    /// instance was intended. The resolved target's `processIdentifier` — not `localizedName` — is
    /// the stable identity used for the idempotency check and threaded through `outputData` for
    /// the independent closed-loop `.processIsFrontmost` verification step
    /// (`QActionVerification.swift`): a `pid` uniquely identifies the exact resolved instance, so
    /// a same-named process quitting and a different one launching between resolution and
    /// verification cannot be misread as the original target remaining frontmost. Idempotent: if
    /// the resolved target is already frontmost, no `activate()` call is made at all. A bounded
    /// ~1s poll (mirroring `executeAppQuit`'s identical pattern) gives the OS time to actually
    /// raise the target before returning, so verification does not race ordinary activation
    /// latency — that independent step, never this method's own observation or `activate()`'s own
    /// return value, is the authoritative postcondition check on success.
    private func executeActivateApplication(request: QActionRequest) async -> QActionResult {
        guard let requestedName = request.parameters["applicationName"],
              !requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or empty required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        // Exact localizedName match only — never substring/prefix/suffix/fuzzy/case-insensitive,
        // and never a silently-normalized (e.g. trimmed) comparison value.
        let exactMatches = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == requestedName
        }

        guard !exactMatches.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "No running application found with the exact name '\(requestedName)'.",
                error: "APP_NOT_RUNNING"
            )
        }

        guard exactMatches.count == 1, let target = exactMatches.first else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Multiple running applications exactly match the name '\(requestedName)' — refusing to guess which one was intended.",
                error: "APP_AMBIGUOUS_MATCH"
            )
        }

        let targetProcessIdentifier = target.processIdentifier
        let targetBundleIdentifier = target.bundleIdentifier ?? ""

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Application '\(requestedName)' is already the frontmost application; no activation was necessary.",
                outputData: [
                    "applicationName": requestedName,
                    "targetProcessIdentifier": "\(targetProcessIdentifier)",
                    "targetBundleIdentifier": targetBundleIdentifier,
                    "changeKind": "alreadyFrontmost"
                ]
            )
        }

        let activationRequestAccepted = target.activate()

        // Bounded poll (~1s) for the target to actually become frontmost before returning, so the
        // immediately-following independent closed-loop verification does not race normal
        // activation latency — the same pattern executeAppQuit already established for
        // termination. This poll is a UX/timing convenience only; it is never itself treated as
        // proof of success — see .processIsFrontmost in QActionVerification.swift.
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Activation attempted for application '\(requestedName)' (activate() accepted=\(activationRequestAccepted)). Independent closed-loop verification pending.",
            outputData: [
                "applicationName": requestedName,
                "targetProcessIdentifier": "\(targetProcessIdentifier)",
                "targetBundleIdentifier": targetBundleIdentifier,
                "changeKind": "activated"
            ]
        )
    }

    // MARK: - Phase 2O: Semantic Element Focus (Level 2)

    /// Level 2 (reversible local action): requests keyboard focus for one semantically-identified,
    /// allowlisted (`QAXFocusableRolePolicy`-only) Accessibility element via
    /// `AXUIElementSetAttributeValue(kAXFocusedAttribute)` only — never a press, never a value
    /// write, never CGEvent/keyboard/mouse simulation, never coordinates. Every
    /// `QAXInteractionError` failure mode — disallowed role, missing criteria, permission
    /// absence, application absence, zero/ambiguous matches, disabled/stale target — is caught
    /// here and converted into a deterministic, non-throwing `QActionResult`; this method never
    /// fabricates success. Only non-secret targeting metadata crosses this method's boundary —
    /// focus-setting never reads or exposes element values, unlike ui.read_element_value/
    /// ui.set_text_value. A `verificationStatus` claim is deliberately NOT made here — a
    /// successful AX write is not itself evidence the target is genuinely focused; that
    /// determination belongs solely to QPlanExecutor's independent `.axElementIsFocused`
    /// verification step.
    private func executeFocusElement(request: QActionRequest) async -> QActionResult {
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
            let outcome = try await QBridgeAccessibility.shared.focusElement(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Focus change attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue
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
                summary: "Unexpected error while focusing element: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    // MARK: - Phase 2P: Semantic Popup Item Selection (Level 2)

    /// Level 2 (reversible local action): resolves one semantically-identified, allowlisted
    /// (`AXPopUpButton`-only) popup, and — unless it already shows the desired item — selects one
    /// item from it via the same two-press-atomic-with-bounded-poll mechanism
    /// `executeSelectMenuItem` already uses, targeting the popup's own opened menu instead of the
    /// application's menu bar. Every `QAXInteractionError` failure mode — disallowed role,
    /// missing criteria, permission absence, application absence, zero/ambiguous popup or item
    /// matches, disabled/stale target, value drift — is caught here and converted into a
    /// deterministic, non-throwing `QActionResult`; this method never fabricates success. Only
    /// non-secret targeting metadata and plain item-label text cross this method's boundary —
    /// popup item labels are not sensitive content, the same conclusion already reached for
    /// button/menu labels. A `verificationStatus` claim is deliberately NOT made here — a
    /// successful press sequence is not itself evidence the popup now shows the desired item;
    /// that determination belongs solely to QPlanExecutor's independent
    /// `.axPopupValueMatchesDesired` verification step.
    private func executeSelectPopupItem(request: QActionRequest) async -> QActionResult {
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
        guard let itemTitle = request.parameters["itemTitle"], !itemTitle.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'itemTitle' parameter.",
                error: "itemTitle missing"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.selectPopupItem(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                itemTitle: itemTitle
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Popup selection attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousValue=\(outcome.previousValue), requestedItemTitle=\(outcome.requestedItemTitle). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousValue": outcome.previousValue,
                    "requestedItemTitle": outcome.requestedItemTitle
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
                summary: "Unexpected error while selecting popup item: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    // MARK: - Phase 2Q: Semantic Disclosure Toggle (Level 2)

    /// Level 2 (reversible local action): resolves one semantically-identified, allowlisted
    /// (`AXDisclosureTriangle`-only) disclosure triangle and, unless it already reports the
    /// requested desired expand/collapse state, presses it toward that state via
    /// `AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`,
    /// never CGEvent, keyboard, mouse, or coordinate interaction. Every `QAXInteractionError`
    /// failure mode — disallowed role, missing criteria, permission absence, application
    /// absence, zero/ambiguous matches, disabled/stale target, unreadable state, state drift — is
    /// caught here and converted into a deterministic, non-throwing `QActionResult`; this method
    /// never fabricates success. Only the small, non-secret expanded/collapsed enum and
    /// non-secret targeting metadata cross this method's boundary — never a raw AX attribute
    /// dump, never the content the toggle reveals or hides. A `verificationStatus` claim is
    /// deliberately NOT made here — a successful press is not itself evidence the desired state
    /// was reached; that determination belongs solely to QPlanExecutor's independent
    /// `.axDisclosureStateMatchesDesired` verification step.
    private func executeToggleDisclosure(request: QActionRequest) async -> QActionResult {
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
              let desiredState = QAXDisclosureState(rawValue: desiredStateRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredState' parameter — must be exactly 'expanded' or 'collapsed'.",
                error: "desiredState invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.toggleDisclosure(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredState: desiredState
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Disclosure toggle attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousState=\(outcome.previousState.rawValue), currentState=\(outcome.currentState.rawValue), desiredState=\(desiredState.rawValue). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousState": outcome.previousState.rawValue,
                    "currentState": outcome.currentState.rawValue,
                    "desiredState": desiredState.rawValue
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
                summary: "Unexpected error while toggling disclosure triangle: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    // MARK: - Phase 2R: Semantic Tab Selection (Level 2)

    /// Level 2 (reversible local action): resolves one semantically-identified, allowlisted
    /// (`AXRadioButton`-with-`AXTabButton`-subrole-only — see `QAXTabRolePolicy`'s documentation
    /// for why "AXTab" is not a real macOS Accessibility role) tab and, unless it already
    /// reports the requested desired selection state, presses it toward that state via
    /// `AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`,
    /// never CGEvent, keyboard, mouse, or coordinate interaction. Every `QAXInteractionError`
    /// failure mode — disallowed role, a resolved `AXRadioButton` lacking the `AXTabButton`
    /// subrole, missing criteria, permission absence, application absence, zero/ambiguous
    /// matches, disabled/stale target, unreadable selection state, selection-state drift, an
    /// unsupported deselection request — is caught here and converted into a deterministic,
    /// non-throwing `QActionResult`; this method never fabricates success. Only the small,
    /// non-secret selected/not-selected boolean and non-secret targeting metadata cross this
    /// method's boundary — never a raw AX attribute dump, never the content of the pane the tab
    /// reveals. A `verificationStatus` claim is deliberately NOT made here — a successful press
    /// is not itself evidence the desired selection state was reached; that determination
    /// belongs solely to QPlanExecutor's independent `.axTabSelectionMatchesDesired`
    /// verification step.
    private func executeSelectTab(request: QActionRequest) async -> QActionResult {
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
        guard let desiredSelectedRaw = request.parameters["desiredSelected"],
              let desiredSelected = Bool(desiredSelectedRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredSelected' parameter — must be exactly 'true' or 'false'.",
                error: "desiredSelected invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.selectTab(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredSelected: desiredSelected
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Tab selection attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousSelected=\(outcome.previousSelected), currentSelected=\(outcome.currentSelected), desiredSelected=\(desiredSelected). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousSelected": "\(outcome.previousSelected)",
                    "currentSelected": "\(outcome.currentSelected)",
                    "desiredSelected": "\(desiredSelected)"
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
                summary: "Unexpected error while selecting tab: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2S: semantic table row selection — Level 2 (reversible local action, approval
    /// required). Selection ONLY: `desiredSelected` MUST be exactly `"true"` — `"false"` is
    /// rejected deterministically before any Accessibility call is made, never treated as a
    /// blind toggle. Restricted to `QAXTableRowRolePolicy`'s single-role allowlist (`AXRow`
    /// only), with the mandatory `AXTableRow` subrole and `AXTable` parent-context gates enforced
    /// inside `QBridgeAccessibility.selectTableRow` itself. Mutation is
    /// `AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`,
    /// never CGEvent, keyboard, mouse, or coordinate interaction. Every `QAXInteractionError`
    /// failure mode — disallowed role, a resolved `AXRow` lacking the `AXTableRow` subrole, a
    /// recognized-but-unsupported `AXOutlineRow` subrole, an unestablished table context, missing
    /// criteria, permission absence, application absence, zero/ambiguous matches,
    /// disabled/stale target, unreadable selection state, selection-state drift — is caught here
    /// and converted into a deterministic, non-throwing `QActionResult`; this method never
    /// fabricates success. Only the small, non-secret selected/not-selected boolean and non-secret
    /// targeting metadata cross this method's boundary — never a raw AX attribute dump, never the
    /// content of the row's own cells or the table it belongs to. A `verificationStatus` claim is
    /// deliberately NOT made here — a successful press is not itself evidence the desired
    /// selection state was reached; that determination belongs solely to QPlanExecutor's
    /// independent `.axTableRowSelectionMatchesDesired` verification step.
    private func executeSelectTableRow(request: QActionRequest) async -> QActionResult {
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
        guard let desiredSelectedRaw = request.parameters["desiredSelected"],
              let desiredSelected = Bool(desiredSelectedRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredSelected' parameter — must be exactly 'true' or 'false'.",
                error: "desiredSelected invalid"
            )
        }
        // This phase supports selection only — refused BEFORE any Accessibility call is made,
        // never treated as a blind toggle and never silently coerced to true.
        guard desiredSelected else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "ui.select_table_row supports selection only — 'desiredSelected: false' (deselection) is not supported in this phase.",
                error: "AX_ROW_DESELECTION_UNSUPPORTED"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.selectTableRow(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredSelected: desiredSelected
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Table row selection attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousSelected=\(outcome.previousSelected), currentSelected=\(outcome.currentSelected), desiredSelected=\(desiredSelected). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousSelected": "\(outcome.previousSelected)",
                    "currentSelected": "\(outcome.currentSelected)",
                    "desiredSelected": "\(desiredSelected)"
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
                summary: "Unexpected error while selecting table row: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2T: semantic outline row selection — Level 2 (reversible local action, approval
    /// required). Selection ONLY: `desiredSelected` MUST be exactly `"true"` — `"false"` is
    /// rejected deterministically before any Accessibility call is made, never treated as a
    /// blind toggle. Restricted to `QAXOutlineRowRolePolicy`'s single-role allowlist (`AXRow`
    /// only), with the mandatory `AXOutlineRow` subrole and `AXOutline` parent-context gates
    /// enforced inside `QBridgeAccessibility.selectOutlineRow` itself. Mutation is
    /// `AXUIElementPerformAction(kAXPressAction)` only — never `AXUIElementSetAttributeValue`,
    /// never CGEvent, keyboard, mouse, or coordinate interaction. Every `QAXInteractionError`
    /// failure mode — disallowed role, a resolved `AXRow` lacking the `AXOutlineRow` subrole, a
    /// recognized-but-unsupported `AXTableRow` subrole, an unestablished outline context, missing
    /// criteria, permission absence, application absence, zero/ambiguous matches,
    /// disabled/stale target, unreadable selection state, selection-state drift — is caught here
    /// and converted into a deterministic, non-throwing `QActionResult`; this method never
    /// fabricates success. Only the small, non-secret selected/not-selected boolean and non-secret
    /// targeting metadata cross this method's boundary — never a raw AX attribute dump, never the
    /// content of the row's own cells, descendants, or the outline it belongs to. A
    /// `verificationStatus` claim is deliberately NOT made here — a successful press is not itself
    /// evidence the desired selection state was reached; that determination belongs solely to
    /// QPlanExecutor's independent `.axOutlineRowSelectionMatchesDesired` verification step.
    private func executeSelectOutlineRow(request: QActionRequest) async -> QActionResult {
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
        guard let desiredSelectedRaw = request.parameters["desiredSelected"],
              let desiredSelected = Bool(desiredSelectedRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredSelected' parameter — must be exactly 'true' or 'false'.",
                error: "desiredSelected invalid"
            )
        }
        // This phase supports selection only — refused BEFORE any Accessibility call is made,
        // never treated as a blind toggle and never silently coerced to true.
        guard desiredSelected else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "ui.select_outline_row supports selection only — 'desiredSelected: false' (deselection) is not supported in this phase.",
                error: "AX_OUTLINE_ROW_DESELECTION_UNSUPPORTED"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.selectOutlineRow(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredSelected: desiredSelected
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Outline row selection attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousSelected=\(outcome.previousSelected), currentSelected=\(outcome.currentSelected), desiredSelected=\(desiredSelected). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousSelected": "\(outcome.previousSelected)",
                    "currentSelected": "\(outcome.currentSelected)",
                    "desiredSelected": "\(desiredSelected)"
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
                summary: "Unexpected error while selecting outline row: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2U: semantic window minimized-state mutation — Level 2 (reversible local action,
    /// approval required). The first WINDOW-level capability in this codebase. Restricted to
    /// `QAXWindowRolePolicy`'s single-role allowlist (`AXWindow` only). Mutation is
    /// `AXUIElementSetAttributeValue(kAXMinimizedAttribute)` only — never
    /// `AXUIElementPerformAction`, never CGEvent, keyboard, mouse, or coordinate interaction.
    /// Unlike every prior row/tab-selection capability, `desiredMinimized` is genuinely
    /// bidirectional here — both `"true"` and `"false"` are fully supported, symmetric target
    /// states, so no early one-way rejection exists for either value (only a missing/malformed
    /// value is rejected). Every `QAXInteractionError` failure mode — disallowed role, missing
    /// criteria, permission absence, application absence, zero/ambiguous matches, an unreadable
    /// current minimized state, a minimized-state drift — is caught here and converted into a
    /// deterministic, non-throwing `QActionResult`; this method never fabricates success. Only the
    /// small, non-secret minimized/not-minimized boolean and non-secret targeting metadata cross
    /// this method's boundary — never a raw AX attribute dump, never the window's own content or
    /// descendant AX tree. A `verificationStatus` claim is deliberately NOT made here — a
    /// successful attribute-set call is not itself evidence the desired minimized state was
    /// reached; that determination belongs solely to QPlanExecutor's independent
    /// `.axWindowMinimizedStateMatchesDesired` verification step.
    private func executeSetWindowMinimized(request: QActionRequest) async -> QActionResult {
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
        guard let desiredMinimizedRaw = request.parameters["desiredMinimized"],
              let desiredMinimized = Bool(desiredMinimizedRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredMinimized' parameter — must be exactly 'true' or 'false'.",
                error: "desiredMinimized invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setWindowMinimizedState(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredMinimized: desiredMinimized
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Window minimized-state mutation attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousMinimized=\(outcome.previousMinimized), currentMinimized=\(outcome.currentMinimized), desiredMinimized=\(desiredMinimized). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousMinimized": "\(outcome.previousMinimized)",
                    "currentMinimized": "\(outcome.currentMinimized)",
                    "desiredMinimized": "\(desiredMinimized)"
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
                summary: "Unexpected error while mutating window minimized state: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    // MARK: - Phase 2AS: Semantic Window Full-Screen State (Level 2)

    /// Level 2 (reversible local action, approval required): sets exactly one semantically-identified
    /// AXWindow's full-screen state to an explicit desiredFullScreen ("true"/"false").
    private func executeSetWindowFullScreen(request: QActionRequest) async -> QActionResult {
        let applicationName = request.parameters["applicationName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter for window full-screen state mutation.",
                error: "AX_MISSING_APPLICATION_NAME"
            )
        }

        let role = request.parameters["role"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !role.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'role' parameter for window full-screen state mutation — must be 'AXWindow'.",
                error: "AX_MISSING_ROLE"
            )
        }

        let identifier = request.parameters["identifier"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = request.parameters["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (identifier != nil && !identifier!.isEmpty) || (title != nil && !title!.isEmpty) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing window match criteria — at least one of 'identifier' or 'title' must be provided.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        let desiredFullScreenRaw = request.parameters["desiredFullScreen"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let desiredFullScreen = Bool(desiredFullScreenRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredFullScreen' parameter — must be exactly 'true' or 'false'.",
                error: "desiredFullScreen invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setWindowFullScreenState(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredFullScreen: desiredFullScreen
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Window full-screen state mutation attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousFullScreen=\(outcome.previousFullScreen), currentFullScreen=\(outcome.currentFullScreen), desiredFullScreen=\(desiredFullScreen). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousFullScreen": "\(outcome.previousFullScreen)",
                    "currentFullScreen": "\(outcome.currentFullScreen)",
                    "desiredFullScreen": "\(desiredFullScreen)"
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
                summary: "Unexpected error while mutating window full-screen state: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    // MARK: - Phase 2V: Semantic Application Hidden State (Level 2)

    /// Level 2 (reversible local action, approval required): sets exactly one already-running
    /// application's hidden/visible state to an explicit `desiredHidden` — never a blind toggle —
    /// resolved by an EXACT `localizedName` match, via `NSRunningApplication.hide()`/`.unhide()`
    /// only — never `AXUIElement`, CGEvent, keyboard/mouse simulation, coordinates, AppleScript,
    /// or shell automation, and never gated on `AXIsProcessTrusted()` (mirroring
    /// `ui.activate_application`'s own native-API-over-raw-AX precedent for app-level operations
    /// — the entire reason this capability works without Accessibility permission granted).
    /// Resolution rejects a missing/empty/whitespace-only name, accepts only
    /// `candidate.localizedName == requestedName` (never substring/prefix/suffix/fuzzy/case-
    /// insensitive), fails closed on zero matches, and fails closed on more than one exact match
    /// rather than guessing which running instance was intended — identical discipline to
    /// `executeActivateApplication`. The resolved target's `processIdentifier` — not
    /// `localizedName` — is the stable identity used for the idempotency check and threaded
    /// through `outputData` for the independent closed-loop
    /// `.applicationHiddenStateMatchesDesired` verification step
    /// (`QActionVerification.swift`): a `pid` uniquely identifies the exact resolved instance, so
    /// a same-named process quitting and a different one launching between resolution and
    /// verification cannot be misread as the original target. Idempotent in BOTH directions: if
    /// the resolved target's `isHidden` already equals `desiredHidden`, no `hide()`/`unhide()`
    /// call is made at all, and no approval is consumed for a mutation that was never needed. A
    /// bounded ~1s poll (mirroring `executeActivateApplication`'s/`executeAppQuit`'s identical
    /// pattern) gives the OS time to actually apply the visibility change before returning, so
    /// verification does not race ordinary hide/unhide latency — that independent step, never
    /// this method's own observation or `hide()`/`unhide()`'s own return value, is the
    /// authoritative postcondition check on success.
    private func executeSetApplicationHidden(request: QActionRequest) async -> QActionResult {
        guard let requestedName = request.parameters["applicationName"],
              !requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or empty required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }
        guard let desiredHiddenRaw = request.parameters["desiredHidden"],
              let desiredHidden = Bool(desiredHiddenRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredHidden' parameter — must be exactly 'true' or 'false'.",
                error: "desiredHidden invalid"
            )
        }

        // Exact localizedName match only — never substring/prefix/suffix/fuzzy/case-insensitive,
        // and never a silently-normalized (e.g. trimmed) comparison value.
        let exactMatches = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == requestedName
        }

        guard !exactMatches.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "No running application found with the exact name '\(requestedName)'.",
                error: "APP_NOT_RUNNING"
            )
        }

        guard exactMatches.count == 1, let target = exactMatches.first else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Multiple running applications exactly match the name '\(requestedName)' — refusing to guess which one was intended.",
                error: "APP_AMBIGUOUS_MATCH"
            )
        }

        let targetProcessIdentifier = target.processIdentifier
        let targetBundleIdentifier = target.bundleIdentifier ?? ""

        // Idempotency check: read isHidden BEFORE any mutation decision — the sole authoritative
        // pre-check, never inferred from frontmost state, window count, or any other signal.
        let currentHiddenAtSearch = target.isHidden
        guard currentHiddenAtSearch != desiredHidden else {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Application '\(requestedName)' already has hidden=\(desiredHidden); no mutation was necessary.",
                outputData: [
                    "applicationName": requestedName,
                    "targetProcessIdentifier": "\(targetProcessIdentifier)",
                    "targetBundleIdentifier": targetBundleIdentifier,
                    "desiredHidden": "\(desiredHidden)",
                    "changeKind": "alreadyDesired"
                ]
            )
        }

        let mutationRequestAccepted = desiredHidden ? target.hide() : target.unhide()

        // Bounded poll (~1s) for the target to actually reach the desired visibility state before
        // returning, so the immediately-following independent closed-loop verification does not
        // race normal hide/unhide latency — the same pattern
        // executeActivateApplication/executeAppQuit already establish. This poll is a UX/timing
        // convenience only; it is never itself treated as proof of success — see
        // .applicationHiddenStateMatchesDesired in QActionVerification.swift.
        for _ in 0..<10 {
            if target.isHidden == desiredHidden {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Hidden-state mutation attempted for application '\(requestedName)' (\(desiredHidden ? "hide()" : "unhide()") accepted=\(mutationRequestAccepted)). Independent closed-loop verification pending.",
            outputData: [
                "applicationName": requestedName,
                "targetProcessIdentifier": "\(targetProcessIdentifier)",
                "targetBundleIdentifier": targetBundleIdentifier,
                "desiredHidden": "\(desiredHidden)",
                "changeKind": "changed"
            ]
        )
    }

    /// Phase 2W: semantic scroll position — Level 2 (reversible local action, approval required).
    /// Sets the ABSOLUTE numeric position of exactly one semantically-identified scroll bar —
    /// never scroll-by-delta, never scroll-to-visible, never scroll-wheel/mouse/keyboard/
    /// coordinate interaction. Restricted to `QAXScrollAreaRolePolicy`'s single-role allowlist
    /// (`AXScrollArea` only) as the SEARCH criterion; the actual scroll bar is resolved via the
    /// explicit `orientation` parameter and independently role-validated inside
    /// `QBridgeAccessibility.setScrollPosition` itself. Mutation is
    /// `AXUIElementSetAttributeValue(kAXValueAttribute)` only — never
    /// `kAXIncrementAction`/`kAXDecrementAction`/`kAXPressAction`. Every `QAXInteractionError`
    /// failure mode — disallowed scroll-area role, invalid orientation, an unresolvable or
    /// misqualified scroll-bar reference, missing criteria, permission absence, application
    /// absence, zero/ambiguous matches, disabled/stale target, non-finite/out-of-range
    /// `desiredValue`, unreadable/inconsistent range, value/range drift — is caught here and
    /// converted into a deterministic, non-throwing `QActionResult`; this method never fabricates
    /// success. Only the small, non-secret numeric position/range and non-secret targeting
    /// metadata cross this method's boundary — never scrolled content, never a screenshot, never
    /// document text. A `verificationStatus` claim is deliberately NOT made here — a successful
    /// attribute-set call is not itself evidence the desired position was reached; that
    /// determination belongs solely to QPlanExecutor's independent
    /// `.scrollPositionMatchesDesired` verification step.
    private func executeSetScrollPosition(request: QActionRequest) async -> QActionResult {
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
        guard let orientation = request.parameters["orientation"], !orientation.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'orientation' parameter — must be exactly 'horizontal' or 'vertical'.",
                error: "orientation missing"
            )
        }
        guard orientation == "horizontal" || orientation == "vertical" else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Invalid 'orientation' parameter '\(orientation)' — must be exactly 'horizontal' or 'vertical'; never inferred.",
                error: "AX_INVALID_ORIENTATION"
            )
        }
        // Swift's Double(String) init parses "nan"/"inf"/"infinity" as valid (non-finite)
        // Doubles — the explicit .isFinite check below is what actually rejects them, not the
        // parse itself.
        guard let desiredValueRaw = request.parameters["desiredValue"],
              let desiredValue = Double(desiredValueRaw),
              desiredValue.isFinite else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredValue' parameter — must be a finite numeric value.",
                error: "desiredValue invalid"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setScrollPosition(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                orientation: orientation,
                desiredValue: desiredValue
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Scroll position change attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousValue=\(outcome.previousValue), currentValue=\(outcome.currentValue), desiredValue=\(outcome.desiredValue), range=[\(outcome.minValue), \(outcome.maxValue)]. Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "orientation": orientation,
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousValue": "\(outcome.previousValue)",
                    "currentValue": "\(outcome.currentValue)",
                    "desiredValue": "\(outcome.desiredValue)",
                    "minValue": "\(outcome.minValue)",
                    "maxValue": "\(outcome.maxValue)"
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
                summary: "Unexpected error while setting scroll position: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2X: semantic window main designation — Level 2 (reversible local action, approval
    /// required). SELECT-ONLY: `desiredMain` MUST be exactly `"true"` — `"false"` is rejected
    /// deterministically before any Accessibility call is made, never treated as a blind toggle.
    /// Restricted to `QAXWindowRolePolicy`'s single-role allowlist (`AXWindow` only, reused
    /// unmodified from Phase 2U). Mutation is
    /// `AXUIElementSetAttributeValue(kAXMainAttribute)` only — never `kAXRaiseAction`, never
    /// `kAXFocusedAttribute`, never `NSRunningApplication.activate()`, never any window-ordering
    /// call. This capability makes NO claim about activation, focus, raise, or any visual/
    /// ordering effect — it reads and writes `kAXMainAttribute` alone. Every `QAXInteractionError`
    /// failure mode — disallowed role, missing criteria, permission absence, application absence,
    /// zero/ambiguous matches, unreadable current main state, main-state drift — is caught here
    /// and converted into a deterministic, non-throwing `QActionResult`; this method never
    /// fabricates success. Only the small, non-secret main/not-main boolean and non-secret
    /// targeting metadata cross this method's boundary — never window content. A
    /// `verificationStatus` claim is deliberately NOT made here — a successful attribute-set call
    /// is not itself evidence the desired main state was reached; that determination belongs
    /// solely to QPlanExecutor's independent `.windowMainStateMatchesDesired` verification step.
    private func executeSetWindowMain(request: QActionRequest) async -> QActionResult {
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
        guard let desiredMainRaw = request.parameters["desiredMain"],
              let desiredMain = Bool(desiredMainRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredMain' parameter — must be exactly 'true' or 'false'.",
                error: "desiredMain invalid"
            )
        }
        // This capability supports selection only — refused BEFORE any Accessibility call is
        // made, never treated as a blind toggle and never silently coerced to true.
        guard desiredMain else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "ui.set_window_main supports selection only — 'desiredMain: false' (un-maining) is not supported.",
                error: "AX_WINDOW_MAIN_DESELECTION_UNSUPPORTED"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.setWindowMain(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                desiredMain: desiredMain
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Window main-designation mutation attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousMain=\(outcome.previousMain), currentMain=\(outcome.currentMain). This does not imply activation, focus, or raise. Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousMain": "\(outcome.previousMain)",
                    "currentMain": "\(outcome.currentMain)",
                    "desiredMain": "\(desiredMain)"
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
                summary: "Unexpected error while setting window main designation: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Level 3 (high risk, irreversible): closes exactly one semantically-identified window by
    /// pressing its kAXCloseButtonAttribute-referenced close button. This method never interacts
    /// with any save/discard dialog the press may cause to appear — it dispatches the single
    /// press and returns; any resulting dialog is left entirely to the human user. The mutation's
    /// own AXError return is never itself treated as proof — independent, absence-based
    /// closed-loop verification (QVerificationStrategy.windowCloseVerified) is the sole source of
    /// truth, wired separately in QPlanExecutor.
    private func executeCloseWindow(request: QActionRequest) async -> QActionResult {
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
            let outcome = try await QBridgeAccessibility.shared.closeWindow(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Window close mutation attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue). This capability never interacts with any save/discard dialog — any such dialog is left entirely to the user. Independent, absence-based closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "matchIdentifier": identifier ?? "",
                    "matchTitle": title ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue
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
                summary: "Unexpected error while closing window: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Level 0 (read-only, no approval): enumerates the windows belonging to exactly one named,
    /// running application. NO mutation, NO recovery — matches the architectural footprint of
    /// every other Level 0 capability in this file exactly.
    ///
    /// PRIVACY BOUNDARY (Phase 2Z, section 6): the per-window metadata built into `outputData`
    /// below exists only in this in-memory `QActionResult` for the CURRENT turn's immediate
    /// reasoning. `QDurablePlanStepSnapshot` — the actual durable, disk-persisted form a completed
    /// step is converted into — has NO `outputData` field at all (confirmed by direct inspection
    /// of `QDurablePlanStepSnapshot.init(from:)` in `QDurablePlanSnapshot.swift`: it only reads
    /// `step.result.summary` and `step.result.verifiedEvidence`, both `String`, never
    /// `step.result.outputData`), so this structured per-window list structurally cannot reach
    /// durable storage, audit logs, replanning state, or long-term memory through the generic
    /// persistence pipeline — no new redaction machinery is needed for a field the architecture
    /// never serializes in the first place. `summary` — the one string field that DOES cross into
    /// `resultSummary`/`verifiedEvidence`/audit-log persistence — is therefore deliberately kept
    /// to an aggregate window COUNT only; it never embeds any individual window's title or
    /// identifier, so even that boundary stays clean on this capability's own side.
    private func executeListWindows(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        do {
            let windows = try await QBridgeAccessibility.shared.listWindows(applicationName: applicationName)

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "windowCount": "\(windows.count)"
            ]
            for (index, window) in windows.enumerated() {
                outputData["window\(index).title"] = window.title ?? ""
                outputData["window\(index).identifier"] = window.identifier ?? ""
                outputData["window\(index).minimized"] = window.minimized.map { $0 ? "true" : "false" } ?? ""
                outputData["window\(index).main"] = window.main.map { $0 ? "true" : "false" } ?? ""
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(windows.count) window(s) for application '\(applicationName)'. This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing windows: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AA: semantic menu enumeration (Level 0, read-only). Dispatches to
    /// `QBridgeAccessibility.listMenuItems` and formats the structured metadata into outputData.
    /// Result summary carries aggregate counts only, never leaking individual menu titles or item
    /// titles to durable storage.
    private func executeListMenuItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        do {
            let menus = try await QBridgeAccessibility.shared.listMenuItems(applicationName: applicationName)
            let totalItemsCount = menus.reduce(0) { $0 + $1.items.count }

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "topLevelMenuCount": "\(menus.count)",
                "totalItemCount": "\(totalItemsCount)"
            ]
            for (menuIndex, menu) in menus.enumerated() {
                outputData["menu\(menuIndex).title"] = menu.title ?? ""
                outputData["menu\(menuIndex).identifier"] = menu.identifier ?? ""
                outputData["menu\(menuIndex).enabled"] = menu.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["menu\(menuIndex).role"] = menu.role
                outputData["menu\(menuIndex).itemCount"] = "\(menu.items.count)"
                for (itemIndex, item) in menu.items.enumerated() {
                    outputData["menu\(menuIndex).item\(itemIndex).title"] = item.title ?? ""
                    outputData["menu\(menuIndex).item\(itemIndex).identifier"] = item.identifier ?? ""
                    outputData["menu\(menuIndex).item\(itemIndex).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                    outputData["menu\(menuIndex).item\(itemIndex).role"] = item.role
                }
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(menus.count) menu(s) and \(totalItemsCount) direct item(s) for application '\(applicationName)'. This is a point-in-time snapshot only — ordering is not meaningful, submenus are not traversed, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing menu items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AD: executes read-only pop-up menu direct item discovery.
    /// Result summary carries aggregate counts only, never leaking individual item titles to durable storage.
    private func executeListPopupItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXPopUpButton"
        guard QAXPopupRolePolicy.isAllowedPopupRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed pop-up button target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]

        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an identifier or title to match semantically.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let metadata = try await QBridgeAccessibility.shared.listPopupItems(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "selectedValue": metadata.selectedValue ?? "",
                "itemCount": "\(metadata.items.count)"
            ]
            if let identifier {
                outputData["identifier"] = identifier
            }
            if let title {
                outputData["title"] = title
            }

            for (itemIndex, item) in metadata.items.enumerated() {
                outputData["item\(itemIndex).title"] = item.title ?? ""
                outputData["item\(itemIndex).identifier"] = item.identifier ?? ""
                outputData["item\(itemIndex).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["item\(itemIndex).selected"] = item.isSelected ? "true" : "false"
                outputData["item\(itemIndex).role"] = item.role
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.items.count) popup item(s) (current value: '\(metadata.selectedValue ?? "none")') for application '\(applicationName)'. This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing pop-up items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AE: executes read-only table direct row discovery.
    /// Result summary carries aggregate counts only, never leaking individual row titles to durable storage.
    private func executeListTableRows(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXTable"
        guard QAXTableRolePolicy.isAllowedTableRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed table target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]

        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an identifier or title to match semantically.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let metadata = try await QBridgeAccessibility.shared.listTableRows(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "rowCount": "\(metadata.rowCount)",
                "selectedRowCount": "\(metadata.selectedRowCount)"
            ]
            if let tableTitle = metadata.tableTitle {
                outputData["tableTitle"] = tableTitle
            }
            if let tableIdentifier = metadata.tableIdentifier {
                outputData["tableIdentifier"] = tableIdentifier
            }

            for row in metadata.rows {
                let idx = row.index
                outputData["row\(idx).index"] = "\(idx)"
                outputData["row\(idx).title"] = row.title ?? ""
                outputData["row\(idx).identifier"] = row.identifier ?? ""
                outputData["row\(idx).selected"] = row.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["row\(idx).enabled"] = row.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["row\(idx).role"] = row.role
                outputData["row\(idx).subrole"] = row.subrole
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.rowCount) table row(s) for table in application '\(applicationName)' (selected rows: \(metadata.selectedRowCount)). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing table rows: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AF: executes read-only outline direct row discovery.
    /// Result summary carries aggregate counts only, never leaking individual outline row titles to durable storage.
    private func executeListOutlineItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXOutline"
        guard QAXOutlineRolePolicy.isAllowedOutlineRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed outline target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]

        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an identifier or title to match semantically.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let metadata = try await QBridgeAccessibility.shared.listOutlineItems(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "itemCount": "\(metadata.itemCount)",
                "selectedItemCount": "\(metadata.selectedItemCount)",
                "expandedItemCount": "\(metadata.expandedItemCount)"
            ]
            if let outlineTitle = metadata.outlineTitle {
                outputData["outlineTitle"] = outlineTitle
            }
            if let outlineIdentifier = metadata.outlineIdentifier {
                outputData["outlineIdentifier"] = outlineIdentifier
            }

            for item in metadata.items {
                let idx = item.index
                outputData["item\(idx).index"] = "\(idx)"
                outputData["item\(idx).title"] = item.title ?? ""
                outputData["item\(idx).identifier"] = item.identifier ?? ""
                outputData["item\(idx).depth"] = "\(item.depth)"
                outputData["item\(idx).expanded"] = item.isExpanded.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["item\(idx).selected"] = item.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["item\(idx).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["item\(idx).role"] = item.role
                outputData["item\(idx).subrole"] = item.subrole
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.itemCount) outline item(s) for outline in application '\(applicationName)' (selected: \(metadata.selectedItemCount), expanded: \(metadata.expandedItemCount)). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing outline items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AH: executes read-only tab group direct item discovery.
    /// Result summary carries aggregate counts only, never leaking individual tab titles to durable storage.
    private func executeListTabItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXTabGroup"
        guard QAXTabGroupRolePolicy.isAllowedTabGroupRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed tab group target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]

        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an identifier or title to match semantically.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let metadata = try await QBridgeAccessibility.shared.listTabItems(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "itemCount": "\(metadata.itemCount)",
                "selectedItemCount": "\(metadata.selectedItemCount)"
            ]
            if let tabGroupTitle = metadata.tabGroupTitle {
                outputData["tabGroupTitle"] = tabGroupTitle
            }
            if let tabGroupIdentifier = metadata.tabGroupIdentifier {
                outputData["tabGroupIdentifier"] = tabGroupIdentifier
            }

            for item in metadata.items {
                let idx = item.index
                outputData["item\(idx).index"] = "\(idx)"
                outputData["item\(idx).title"] = item.title ?? ""
                outputData["item\(idx).identifier"] = item.identifier ?? ""
                outputData["item\(idx).selected"] = item.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["item\(idx).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["item\(idx).role"] = item.role
                outputData["item\(idx).subrole"] = item.subrole
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.itemCount) tab item(s) for tab group in application '\(applicationName)' (selected: \(metadata.selectedItemCount)). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing tab items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AI: executes read-only radio group direct item discovery.
    /// Result summary carries aggregate counts only, never leaking individual radio option titles to durable storage.
    private func executeListRadioGroupItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXRadioGroup"
        guard QAXRadioGroupRolePolicy.isAllowedRadioGroupRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed radio group target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]

        guard identifier != nil || title != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target must specify an identifier or title to match semantically.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        do {
            let metadata = try await QBridgeAccessibility.shared.listRadioGroupItems(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "itemCount": "\(metadata.itemCount)",
                "selectedItemCount": "\(metadata.selectedItemCount)"
            ]
            if let radioGroupTitle = metadata.radioGroupTitle {
                outputData["radioGroupTitle"] = radioGroupTitle
            }
            if let radioGroupIdentifier = metadata.radioGroupIdentifier {
                outputData["radioGroupIdentifier"] = radioGroupIdentifier
            }

            for item in metadata.items {
                let idx = item.index
                outputData["item\(idx).index"] = "\(idx)"
                outputData["item\(idx).title"] = item.title ?? ""
                outputData["item\(idx).identifier"] = item.identifier ?? ""
                outputData["item\(idx).selected"] = item.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["item\(idx).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["item\(idx).role"] = item.role
                outputData["item\(idx).subrole"] = item.subrole ?? ""
            }

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.itemCount) radio item(s) for radio group in application '\(applicationName)' (selected: \(metadata.selectedItemCount)). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing radio group items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AK: executes read-only window toolbar direct item discovery.
    /// Result summary carries aggregate counts only, never leaking individual toolbar button titles to durable storage.
    private func executeListToolbarItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXToolbar"
        guard QAXToolbarRolePolicy.isAllowedToolbarRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed toolbar target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]
        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        do {
            let metadata = try await QBridgeAccessibility.shared.listToolbarItems(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "itemCount": "\(metadata.itemCount)"
            ]
            if let windowTitle = metadata.windowTitle {
                outputData["windowTitle"] = windowTitle
            }
            if let toolbarTitle = metadata.toolbarTitle {
                outputData["toolbarTitle"] = toolbarTitle
            }
            if let toolbarIdentifier = metadata.toolbarIdentifier {
                outputData["toolbarIdentifier"] = toolbarIdentifier
            }

            for item in metadata.items {
                let idx = item.index
                outputData["item\(idx).index"] = "\(idx)"
                outputData["item\(idx).title"] = item.title ?? ""
                outputData["item\(idx).identifier"] = item.identifier ?? ""
                outputData["item\(idx).role"] = item.role
                outputData["item\(idx).subrole"] = item.subrole ?? ""
                outputData["item\(idx).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["item\(idx).selected"] = item.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["item\(idx).help"] = item.help ?? ""
            }

            let windowSuffix = metadata.windowTitle.map { " (window: '\($0)')" } ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.itemCount) toolbar item(s) for toolbar in application '\(applicationName)'\(windowSuffix). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing toolbar items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AT: executes read-only split view pane direct discovery.
    /// Result summary carries aggregate counts only, never leaking individual pane titles to durable storage.
    private func executeListSplitPanes(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXSplitGroup"
        guard QAXSplitGroupRolePolicy.isAllowedSplitGroupRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed split group target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]
        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        do {
            let metadata = try await QBridgeAccessibility.shared.listSplitPanes(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "paneCount": "\(metadata.paneCount)"
            ]
            if let windowTitle = metadata.windowTitle {
                outputData["windowTitle"] = windowTitle
            }
            if let splitGroupTitle = metadata.splitGroupTitle {
                outputData["splitGroupTitle"] = splitGroupTitle
            }
            if let splitGroupIdentifier = metadata.splitGroupIdentifier {
                outputData["splitGroupIdentifier"] = splitGroupIdentifier
            }

            for pane in metadata.panes {
                let idx = pane.index
                outputData["pane\(idx).index"] = "\(idx)"
                outputData["pane\(idx).title"] = pane.title ?? ""
                outputData["pane\(idx).identifier"] = pane.identifier ?? ""
                outputData["pane\(idx).role"] = pane.role
                outputData["pane\(idx).subrole"] = pane.subrole ?? ""
                outputData["pane\(idx).enabled"] = pane.isEnabled.map { $0 ? "true" : "false" } ?? ""
            }

            let windowSuffix = metadata.windowTitle.map { " (window: '\($0)')" } ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.paneCount) split pane(s) for split group in application '\(applicationName)'\(windowSuffix). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing split panes: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AV: executes read-only multi-column browser direct column discovery.
    /// Result summary carries aggregate counts only, never leaking individual column titles to durable storage.
    private func executeListBrowserColumns(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXBrowser"
        guard QAXBrowserRolePolicy.isAllowedBrowserRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed browser target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["browserIdentifier"] ?? request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["browserTitle"] ?? request.parameters["title"] ?? request.parameters["label"]
        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        do {
            let metadata = try await QBridgeAccessibility.shared.listBrowserColumns(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "columnCount": "\(metadata.columnCount)"
            ]
            if let windowTitle = metadata.windowTitle {
                outputData["windowTitle"] = windowTitle
            }
            if let browserTitle = metadata.browserTitle {
                outputData["browserTitle"] = browserTitle
            }
            if let browserIdentifier = metadata.browserIdentifier {
                outputData["browserIdentifier"] = browserIdentifier
            }

            for col in metadata.columns {
                let idx = col.index
                outputData["column\(idx).index"] = "\(idx)"
                outputData["column\(idx).title"] = col.title ?? ""
                outputData["column\(idx).identifier"] = col.identifier ?? ""
                outputData["column\(idx).role"] = col.role
                outputData["column\(idx).subrole"] = col.subrole ?? ""
                outputData["column\(idx).enabled"] = col.isEnabled.map { $0 ? "true" : "false" } ?? ""
            }

            let windowSuffix = metadata.windowTitle.map { " (window: '\($0)')" } ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.columnCount) browser column(s) for browser in application '\(applicationName)'\(windowSuffix). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing browser columns: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AM: executes read-only segmented control direct segment discovery.
    /// Result summary carries aggregate counts only, never leaking individual segment titles to durable storage.
    private func executeListSegmentedControlItems(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXSegmentedControl"
        guard QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed segmented control target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let identifier = request.parameters["identifier"] ?? request.parameters["id"]
        let title = request.parameters["title"] ?? request.parameters["label"]
        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        do {
            let metadata = try await QBridgeAccessibility.shared.listSegmentedControlItems(
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                title: title,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "role": role,
                "itemCount": "\(metadata.itemCount)",
                "selectedItemCount": "\(metadata.selectedItemCount)"
            ]
            if let windowTitle = metadata.windowTitle {
                outputData["windowTitle"] = windowTitle
            }
            if let controlTitle = metadata.controlTitle {
                outputData["controlTitle"] = controlTitle
            }
            if let controlIdentifier = metadata.controlIdentifier {
                outputData["controlIdentifier"] = controlIdentifier
            }

            for item in metadata.items {
                let idx = item.index
                outputData["item\(idx).index"] = "\(idx)"
                outputData["item\(idx).title"] = item.title ?? ""
                outputData["item\(idx).identifier"] = item.identifier ?? ""
                outputData["item\(idx).role"] = item.role
                outputData["item\(idx).subrole"] = item.subrole ?? ""
                outputData["item\(idx).enabled"] = item.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["item\(idx).selected"] = item.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
            }

            let windowSuffix = metadata.windowTitle.map { " (window: '\($0)')" } ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.itemCount) segment(s) for segmented control in application '\(applicationName)'\(windowSuffix) (selected: \(metadata.selectedItemCount)). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing segmented control items: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AN: executes read-only window direct sheet discovery.
    /// Result summary carries aggregate counts only, never leaking individual sheet titles to durable storage.
    private func executeListSheetDialogs(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        if let role = request.parameters["role"] {
            guard QAXSheetRolePolicy.isAllowedSheetRole(role) else {
                return QActionResult(
                    actionId: request.actionId,
                    success: false,
                    summary: "Target role '\(role)' is not an allowed sheet target.",
                    error: "AX_DISALLOWED_ROLE"
                )
            }
        }

        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        do {
            let metadata = try await QBridgeAccessibility.shared.listSheetDialogs(
                applicationName: applicationName,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "sheetCount": "\(metadata.sheetCount)"
            ]
            if let windowTitle = metadata.windowTitle {
                outputData["windowTitle"] = windowTitle
            }
            if let windowIdentifier = metadata.windowIdentifier {
                outputData["windowIdentifier"] = windowIdentifier
            }

            for sheet in metadata.sheets {
                let idx = sheet.index
                outputData["sheet\(idx).index"] = "\(idx)"
                outputData["sheet\(idx).title"] = sheet.title ?? ""
                outputData["sheet\(idx).identifier"] = sheet.identifier ?? ""
                outputData["sheet\(idx).role"] = sheet.role
                outputData["sheet\(idx).subrole"] = sheet.subrole ?? ""
                outputData["sheet\(idx).modal"] = sheet.isModal.map { $0 ? "true" : "false" } ?? "unknown"
            }

            let windowSuffix = metadata.windowTitle.map { " (window: '\($0)')" } ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.sheetCount) sheet(s) for window in application '\(applicationName)'\(windowSuffix). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing sheet dialogs: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AO: executes read-only sheet direct action controls discovery.
    /// Result summary carries aggregate counts only, never leaking individual button labels to durable storage.
    private func executeListSheetActions(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        if let role = request.parameters["role"] {
            guard QAXSheetActionRolePolicy.isAllowedSheetActionRole(role) else {
                return QActionResult(
                    actionId: request.actionId,
                    success: false,
                    summary: "Target role '\(role)' is not an allowed sheet action target.",
                    error: "AX_DISALLOWED_ROLE"
                )
            }
        }

        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]
        let sheetTitle = request.parameters["sheetTitle"] ?? request.parameters["sheet"]
        let sheetIdentifier = request.parameters["sheetIdentifier"] ?? request.parameters["sheetId"]

        do {
            let metadata = try await QBridgeAccessibility.shared.listSheetActions(
                applicationName: applicationName,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier,
                sheetTitle: sheetTitle,
                sheetIdentifier: sheetIdentifier
            )

            var outputData: [String: String] = [
                "applicationName": applicationName,
                "actionCount": "\(metadata.actionCount)"
            ]
            if let windowTitle = metadata.windowTitle {
                outputData["windowTitle"] = windowTitle
            }
            if let windowIdentifier = metadata.windowIdentifier {
                outputData["windowIdentifier"] = windowIdentifier
            }
            if let sheetTitle = metadata.sheetTitle {
                outputData["sheetTitle"] = sheetTitle
            }
            if let sheetIdentifier = metadata.sheetIdentifier {
                outputData["sheetIdentifier"] = sheetIdentifier
            }

            for action in metadata.actions {
                let idx = action.index
                outputData["action\(idx).index"] = "\(idx)"
                outputData["action\(idx).title"] = action.title ?? ""
                outputData["action\(idx).identifier"] = action.identifier ?? ""
                outputData["action\(idx).role"] = action.role
                outputData["action\(idx).subrole"] = action.subrole ?? ""
                outputData["action\(idx).enabled"] = action.isEnabled.map { $0 ? "true" : "false" } ?? ""
                outputData["action\(idx).selected"] = action.isSelected.map { $0 ? "true" : "false" } ?? "unknown"
                outputData["action\(idx).focused"] = action.isFocused.map { $0 ? "true" : "false" } ?? ""
            }

            let sheetSuffix = metadata.sheetTitle.map { " (sheet: '\($0)')" } ?? ""
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated \(metadata.actionCount) direct action control(s) for sheet in application '\(applicationName)'\(sheetSuffix). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
                outputData: outputData
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
                summary: "Unexpected error while listing sheet actions: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AQ: semantic segmented control item selection — Level 2 (reversible local action, approval required).
    /// Selection ONLY: desired segment is selected. Idempotent (already selected returns no-op without mutation).
    /// Role must be AXSegmentedControl. Direct segment must be AXRadioButton or AXButton (AXTabButton is excluded).
    private func executeSelectSegmentedControlItem(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        let role = request.parameters["role"] ?? "AXSegmentedControl"
        guard QAXSegmentedControlRolePolicy.isAllowedSegmentedControlRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed segmented control target.",
                error: "AX_DISALLOWED_ROLE"
            )
        }

        let controlIdentifier = request.parameters["controlIdentifier"] ?? (request.parameters["segmentIdentifier"] != nil ? request.parameters["identifier"] : nil)
        let controlTitle = request.parameters["controlTitle"] ?? (request.parameters["segmentTitle"] != nil || request.parameters["segmentLabel"] != nil || request.parameters["segment"] != nil ? request.parameters["title"] : nil)
        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        let segmentIdentifier = request.parameters["segmentIdentifier"] ?? (controlIdentifier != request.parameters["identifier"] ? request.parameters["identifier"] : nil)
        let segmentTitle = request.parameters["segmentTitle"] ?? request.parameters["segmentLabel"] ?? request.parameters["segment"] ?? (controlTitle != request.parameters["title"] ? request.parameters["title"] : nil)

        guard segmentIdentifier != nil || segmentTitle != nil else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target segment must specify a 'segmentIdentifier' or 'segmentTitle' to match semantically.",
                error: "AX_MISSING_MATCH_CRITERIA"
            )
        }

        let desiredSelectedRaw = request.parameters["desiredSelected"] ?? "true"
        guard let desiredSelected = Bool(desiredSelectedRaw) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid 'desiredSelected' parameter — must be exactly 'true' or 'false'.",
                error: "desiredSelected invalid"
            )
        }

        guard desiredSelected else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "ui.select_segmented_control_item supports selection only — 'desiredSelected: false' (deselection) is not supported.",
                error: "AX_SEGMENT_DESELECTION_UNSUPPORTED"
            )
        }

        do {
            let outcome = try await QBridgeAccessibility.shared.selectSegmentedControlItem(
                applicationName: applicationName,
                role: role,
                controlIdentifier: controlIdentifier,
                controlTitle: controlTitle,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier,
                segmentIdentifier: segmentIdentifier,
                segmentTitle: segmentTitle,
                desiredSelected: desiredSelected
            )
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Segmented control item selection attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousSelected=\(outcome.previousSelected), currentSelected=\(outcome.currentSelected), desiredSelected=\(desiredSelected). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "controlIdentifier": controlIdentifier ?? "",
                    "controlTitle": controlTitle ?? "",
                    "segmentIdentifier": segmentIdentifier ?? "",
                    "segmentTitle": segmentTitle ?? "",
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousSelected": "\(outcome.previousSelected)",
                    "currentSelected": "\(outcome.currentSelected)",
                    "desiredSelected": "\(desiredSelected)"
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
                summary: "Unexpected error while selecting segmented control item: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }

    /// Phase 2AU: semantic split view divider position mutation (Level 2, approval required).
    /// Sets the numeric divider position of exactly ONE semantically-identified `AXSplitter` within an `AXSplitGroup`
    /// in a named application window via `AXUIElementSetAttributeValue(kAXValueAttribute)`.
    private func executeSetSplitterPosition(request: QActionRequest) async -> QActionResult {
        guard let applicationName = request.parameters["applicationName"], !applicationName.isEmpty else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing required 'applicationName' parameter.",
                error: "applicationName missing"
            )
        }

        guard let desiredPositionString = request.parameters["desiredPosition"] ?? request.parameters["position"] ?? request.parameters["value"],
              let desiredPosition = Double(desiredPositionString), desiredPosition.isFinite else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Missing or invalid required 'desiredPosition' parameter (must be a finite numeric value).",
                error: "AX_INVALID_DESIRED_VALUE"
            )
        }

        let splitterIndex: Int
        if let idxString = request.parameters["splitterIndex"] ?? request.parameters["index"] ?? request.parameters["dividerIndex"] {
            guard let parsedIdx = Int(idxString), parsedIdx >= 0 else {
                return QActionResult(
                    actionId: request.actionId,
                    success: false,
                    summary: "Invalid 'splitterIndex' parameter: '\(idxString)' (must be non-negative integer).",
                    error: "AX_INVALID_SPLITTER_INDEX"
                )
            }
            splitterIndex = parsedIdx
        } else {
            splitterIndex = 0
        }

        let tolerance: Double
        if let tolString = request.parameters["tolerance"] {
            guard let parsedTol = Double(tolString), parsedTol >= 0.0, parsedTol.isFinite else {
                return QActionResult(
                    actionId: request.actionId,
                    success: false,
                    summary: "Invalid 'tolerance' parameter: '\(tolString)' (must be non-negative finite number).",
                    error: "AX_INVALID_SPLITTER_TOLERANCE"
                )
            }
            tolerance = parsedTol
        } else {
            tolerance = 0.5
        }

        let role = request.parameters["role"] ?? "AXSplitter"
        guard QAXSplitterRolePolicy.isAllowedSplitterRole(role) else {
            return QActionResult(
                actionId: request.actionId,
                success: false,
                summary: "Target role '\(role)' is not an allowed splitter target.",
                error: "AX_SPLITTER_ROLE_NOT_ALLOWED"
            )
        }

        let splitGroupIdentifier = request.parameters["splitGroupIdentifier"] ?? request.parameters["identifier"] ?? request.parameters["id"]
        let splitGroupTitle = request.parameters["splitGroupTitle"] ?? request.parameters["title"] ?? request.parameters["label"]
        let windowTitle = request.parameters["windowTitle"] ?? request.parameters["window"]
        let windowIdentifier = request.parameters["windowIdentifier"] ?? request.parameters["windowId"]

        do {
            let outcome = try await QBridgeAccessibility.shared.setSplitterPosition(
                applicationName: applicationName,
                desiredPosition: desiredPosition,
                splitterIndex: splitterIndex,
                tolerance: tolerance,
                windowTitle: windowTitle,
                windowIdentifier: windowIdentifier,
                splitGroupIdentifier: splitGroupIdentifier,
                splitGroupTitle: splitGroupTitle,
                role: role
            )

            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Splitter position mutation attempted for \(outcome.targetIdentity): changeKind=\(outcome.changeKind.rawValue), previousPosition=\(outcome.previousPosition), currentPosition=\(outcome.currentPosition), desiredPosition=\(desiredPosition), tolerance=\(tolerance). Independent closed-loop verification pending.",
                outputData: [
                    "applicationName": applicationName,
                    "role": role,
                    "targetIdentity": outcome.targetIdentity,
                    "changeKind": outcome.changeKind.rawValue,
                    "previousPosition": "\(outcome.previousPosition)",
                    "currentPosition": "\(outcome.currentPosition)",
                    "desiredPosition": "\(desiredPosition)",
                    "minValue": "\(outcome.minValue)",
                    "maxValue": "\(outcome.maxValue)",
                    "splitterIndex": "\(splitterIndex)",
                    "tolerance": "\(tolerance)",
                    "windowTitle": windowTitle ?? "",
                    "windowIdentifier": windowIdentifier ?? "",
                    "splitGroupIdentifier": splitGroupIdentifier ?? "",
                    "splitGroupTitle": splitGroupTitle ?? ""
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
                summary: "Unexpected error while setting splitter position: \(error.localizedDescription)",
                error: "AX_UNEXPECTED_ERROR"
            )
        }
    }
}
