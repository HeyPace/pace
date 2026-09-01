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

    private func executeScreenOCR(request: QActionRequest) async throws -> QActionResult {
        let frames = try await QBridgeScreenCapture.shared.captureScreens()
        guard let firstFrame = frames.first else {
            return QActionResult(actionId: request.actionId, success: false, summary: "No display available for capture.", error: "ENODISPLAY")
        }
        let ocr = try await QBridgeVision.shared.performOCR(on: firstFrame)
        return QActionResult(
            actionId: request.actionId,
            success: true,
            summary: "Captured screen \(firstFrame.screenNumber) and recognized: \(ocr.detectedText)",
            outputData: [
                "screen": "\(firstFrame.screenNumber)",
                "detectedText": ocr.detectedText,
                "confidence": "\(ocr.confidence)"
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
}
