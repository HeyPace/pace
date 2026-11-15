//
//  PaceMCPClientIntegrationTests.swift
//  leanring-buddyTests
//
//  End-to-end validation of the stdio MCP bridge against the in-repo
//  fixture server (scripts/mcp-fixture-server.py). These tests prove the
//  full initialize → notifications/initialized → tools/call round trip
//  with a real child process, not a mock.
//

import ApplicationServices
import Foundation
import Testing

@testable import Pace

private enum PaceMCPFixture {
    // Tests run from DerivedData, so #filePath is the only stable anchor
    // back into the repo checkout: …/leanring-buddyTests/<this file>.
    static let fixtureScriptPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts")
        .appendingPathComponent("mcp-fixture-server.py")
        .path

    static let pythonThreeExecutablePath: String? = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isFixtureRunnable: Bool {
        pythonThreeExecutablePath != nil
            && FileManager.default.fileExists(atPath: fixtureScriptPath)
    }

    static func makeFixtureClient(requestTimeoutInSeconds: TimeInterval = 20) -> PaceMCPStdioClient {
        let fixtureServerConfiguration = PaceMCPServerConfiguration(
            command: pythonThreeExecutablePath ?? "python3",
            args: [fixtureScriptPath]
        )
        return PaceMCPStdioClient(
            serverConfigurations: ["fixture": fixtureServerConfiguration],
            requestTimeoutInSeconds: requestTimeoutInSeconds
        )
    }

    static func makeAmbiguityClient(signalDirectory: URL? = nil) -> PaceMCPStdioClient {
        let program = #"""
            import json, pathlib, sys, time
            calls = []
            signal_root = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                if request["method"] == "initialize":
                    result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "ambiguity-fixture", "version": "1"}}
                else:
                    params = request["params"]
                    name = params["name"]
                    args = params.get("arguments", {})
                    target = args.get("app", args.get("app_target", ""))
                    if name == "receipt":
                        result = {"content": [{"type": "text", "text": "\n".join(calls)}]}
                    else:
                        calls.append(name + ":" + target)
                        if name in ["window", "see"] and target == "Google Chrome":
                            result = {"isError": True, "content": [{"type": "text", "text": "Multiple apps match 'Google Chrome'. Did you mean: Google Chrome (PID:111), Google Chrome (PID:222)?"}]}
                        else:
                            if signal_root and target == "PID:111":
                                (signal_root / "started").write_text("ready")
                                deadline = time.monotonic() + 3
                                while not (signal_root / "release").exists() and time.monotonic() < deadline:
                                    time.sleep(0.001)
                            text = "Current application inventory" if name == "app" else "Window title Preview " + target
                            result = {"content": [{"type": "text", "text": text}]}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            """#
        return PaceMCPStdioClient(serverConfigurations: [
            "peekaboo": .init(
                command: pythonThreeExecutablePath ?? "python3",
                args: ["-u", "-c", program, signalDirectory?.path ?? "", UUID().uuidString])
        ])
    }
}

@Suite(.serialized)
struct PaceMCPClientIntegrationTests {
    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func rapidConfigurationSwitchesKeepSDKResponsesWithTheirOwnProducer() async throws {
        let program = #"""
            import json, sys
            nonce = sys.argv[1]
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                if request["method"] == "initialize":
                    result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": nonce, "version": "1"}}
                elif request["method"] == "tools/list":
                    result = {"tools": []}
                else:
                    result = {"content": [{"type": "text", "text": nonce}]}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            """#
        for index in 0..<12 {
            let nonce = "producer-\(index)-\(UUID().uuidString)"
            let client = PaceMCPStdioClient(
                serverConfigurations: [
                    "fixture-rapid-config-switch": .init(
                        command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3",
                        args: ["-u", "-c", program, nonce])
                ],
                requestTimeoutInSeconds: 4)
            _ = try await client.toolCatalog(serverName: "fixture-rapid-config-switch")
            for _ in 0..<2 {
                let response = try await client.callTool(
                    .init(serverName: "fixture-rapid-config-switch", toolName: "echo", arguments: [:]))
                #expect(response == nonce)
            }
        }
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func timedOutReadOnlyInspectionsStopQueuedClicksWithoutAnAmbiguityGuess() async throws {
        let program = #"""
            import json, pathlib, sys, time
            receipt = pathlib.Path(sys.argv[1])
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                if request["method"] == "initialize":
                    result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "timeout-inspection", "version": "1"}}
                elif request["method"] == "tools/list":
                    result = {"tools": []}
                else:
                    name = request["params"]["name"]
                    with receipt.open("a") as file:
                        file.write(name + "\n")
                    if name in ["window", "see", "app"]:
                        time.sleep(1)
                    result = {"content": [{"type": "text", "text": "completed " + name}]}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            """#
        for toolName in ["window", "see", "app"] {
            let receipt = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pace-inspection-timeout-\(UUID()).txt")
            defer { try? FileManager.default.removeItem(at: receipt) }
            let client = PaceMCPStdioClient(
                serverConfigurations: [
                    "peekaboo": .init(
                        command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3",
                        args: ["-u", "-c", program, receipt.path])
                ],
                requestTimeoutInSeconds: 0.5)
            _ = try await client.toolCatalog(serverName: "peekaboo")
            let executor = PaceActionExecutor(
                actionsAreEnabledOverride: true, mcpClient: client,
                readMyScreenIsEnabled: { true }, runningApplicationBundleURL: { _ in nil },
                preferredInspectionProcessIdentifiers: { [] })
            let inspection = PaceMCPToolCall(
                serverName: "peekaboo", toolName: toolName,
                arguments: toolName == "see"
                    ? ["app_target": .string("Google Chrome")]
                    : ["action": .string("list"), "app": .string("Google Chrome")])
            let observations = await executor.executeActionPlan(
                .serial(actions: [
                    .mcp(inspection), .mcp(.init(serverName: "peekaboo", toolName: "click", arguments: [:])),
                ]), screenCaptures: [])
            #expect(observations.count == 1)
            #expect(observations.first?.terminalReason == .inspectionInterrupted)
            #expect(observations.first?.stopsAgentLoop == true)
            #expect(observations.first?.summary.contains("SDK request") == true)
            #expect(
                PaceActionExecutionObservation.formatForUserFeedback(observations)
                    == "The Peekaboo connection took too long. Please try again.")
            #expect(!PaceActionRunRecord.completed(observations: observations).showsInConversation)
            #expect(try String(contentsOf: receipt, encoding: .utf8) == toolName + "\n")
        }
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func genericMCPFailuresShowHumanFeedbackAndKeepTechnicalReceiptsSeparate() async throws {
        let client = PaceMCPFixture.makeFixtureClient()
        let executor = PaceActionExecutor(actionsAreEnabledOverride: true, mcpClient: client)
        let result = await executor.callMCPTool(.init(serverName: "fixture", toolName: "fail", arguments: [:]))
        #expect(result.terminalReason == nil)
        #expect(result.summary.contains("intentional fixture failure"))
        #expect(
            PaceActionExecutionObservation.formatForUserFeedback([result])
                == "I couldn’t finish that step through Fixture.")
        let record = PaceActionRunRecord.completed(observations: [result])
        #expect(record.showsInConversation)
        #expect(record.status == .failed)
        #expect(!record.detail.contains("MCP"))
        #expect(!record.detail.contains("intentional fixture failure"))
        #expect(record.diagnosticDetail?.contains("intentional fixture failure") == true)
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        manager.actionExecutor.mutationLog.append(
            .axValue(
                element: AXUIElementCreateApplication(1), oldValue: "old", summary: "An older edit"))
        let mutationCountBeforeFailure = manager.actionExecutor.mutationLog.count
        manager.appendActionResult(record)
        manager.noteReversibleActionExecuted(sinceMutationCount: mutationCountBeforeFailure)
        #expect(manager.mostRecentReversibleActionAt == nil)
        let missing = await executor.callMCPTool(.init(serverName: "missing", toolName: "read", arguments: [:]))
        #expect(missing.userFacingSummary == "Connect Missing in Pace settings before trying again.")
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func recoverableInspectionRPCFailuresPermitOnlyOneFreshPlanAndKeepWritesStopped() async throws {
        let program = #"""
            import json, sys
            calls = []
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                if request["method"] == "initialize":
                    result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "rpc-repair", "version": "1"}}
                else:
                    params = request["params"]
                    name = params["name"]
                    if name == "receipt":
                        result = {"content": [{"type": "text", "text": "\n".join(calls)}]}
                    else:
                        calls.append(name)
                        diagnostic = params.get("arguments", {}).get("failure", "invalid parameter: app")
                        result = {"isError": True, "content": [{"type": "text", "text": diagnostic}]}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            """#
        let client = PaceMCPStdioClient(serverConfigurations: [
            "peekaboo": .init(
                command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3",
                args: ["-u", "-c", program, UUID().uuidString])
        ])
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { true })
        let futureWrite = PaceParsedAction.mcp(.init(serverName: "peekaboo", toolName: "click", arguments: [:]))
        for diagnostic in ["invalid parameter: app", "Application not running"] {
            executor.beginUserTurn()
            let inspection = PaceParsedAction.mcp(
                .init(
                    serverName: "peekaboo", toolName: "window",
                    arguments: ["action": .string("list"), "failure": .string(diagnostic)]))
            let plan = PaceActionExecutionPlan.serial(actions: [inspection, futureWrite])
            let first = await executor.executeActionPlanWithReceipt(plan, screenCaptures: [])
            #expect(first.observations.count == 1)
            #expect(first.observations.first?.terminalReason == .recoverableInspectionFailure)
            #expect(first.observations.first?.stopsAgentLoop == false)
            #expect(first.executedPlan.flattenedActions.isEmpty)
            #expect(PaceActionApprovalPolicy.needsAnswerAfterInspection(plan, observations: first.observations))
            #expect(first.observations.first?.summary.contains(diagnostic) == true)
            let repeated = await executor.executeActionPlanWithReceipt(plan, screenCaptures: [])
            #expect(repeated.observations.count == 1)
            #expect(repeated.observations.first?.terminalReason == .inspectionInterrupted)
            #expect(repeated.observations.first?.stopsAgentLoop == true)
            if diagnostic == "Application not running" {
                #expect(
                    repeated.observations.first?.userFacingSummary == "Open the app you want me to use, then try again."
                )
            }
        }
        for (diagnostic, expectedFeedback) in [
            (
                "Screen Recording permission denied",
                "Enable Screen Recording for Peekaboo in System Settings, then try again."
            ),
            ("Accessibility access denied", "Enable Accessibility for Peekaboo in System Settings, then try again."),
            ("Unauthorized: expired token", "Sign in again to Peekaboo through Pace settings, then try again."),
        ] {
            executor.beginUserTurn()
            let observation = await executor.callMCPTool(
                .init(
                    serverName: "peekaboo", toolName: "app",
                    arguments: ["action": .string("list"), "failure": .string(diagnostic)]))
            #expect(observation.terminalReason == .inspectionInterrupted)
            #expect(observation.userFacingSummary == expectedFeedback)
            #expect(observation.summary.contains(diagnostic))
            #expect(!expectedFeedback.contains("MCP"))
        }
        let calls = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(!calls.contains("click"))
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func disabledScreenReadingStopsTheQueuedPlanBeforeAnyProviderDispatch() async throws {
        let client = PaceMCPFixture.makeAmbiguityClient()
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { false })
        let receipt = await executor.executeActionPlanWithReceipt(
            .serial(actions: [
                .mcp(.init(serverName: "peekaboo", toolName: "window", arguments: ["action": .string("list")])),
                .mcp(.init(serverName: "peekaboo", toolName: "click", arguments: [:])),
            ]), screenCaptures: [])
        #expect(receipt.observations.count == 1)
        #expect(receipt.observations.first?.terminalReason == .inspectionInterrupted)
        #expect(receipt.observations.first?.userFacingSummary?.contains("Turn on Read My Screen") == true)
        #expect(receipt.executedPlan.flattenedActions.isEmpty)
        let calls = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(calls.isEmpty)
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func executionReceiptsPreserveEarlierMutationsAndExcludeQueuedFutureWrites() async throws {
        let client = PaceMCPFixture.makeAmbiguityClient()
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { true },
            runningApplicationBundleURL: { _ in URL(fileURLWithPath: "/Applications/Google Chrome.app") },
            preferredInspectionProcessIdentifiers: { [] })
        let inspection = PaceParsedAction.mcp(
            .init(
                serverName: "peekaboo", toolName: "window",
                arguments: [
                    "action": .string("list"), "app": .string("Google Chrome"),
                ]))
        let earlierWrite = PaceParsedAction.mcp(
            .init(serverName: "peekaboo", toolName: "earlier_write", arguments: [:]))
        let futureWrite = PaceParsedAction.mcp(.init(serverName: "peekaboo", toolName: "future_write", arguments: [:]))
        let receipt = await executor.executeActionPlanWithReceipt(
            .serial(actions: [earlierWrite, inspection, futureWrite]), screenCaptures: [])
        #expect(receipt.observations.count == 2)
        #expect(receipt.executedPlan.flattenedActions.count == 1)
        guard case .mcp(let executedCall) = try #require(receipt.executedPlan.flattenedActions.first) else {
            Issue.record("Expected an exact dispatched write receipt")
            return
        }
        #expect(executedCall.toolName == "earlier_write")
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        manager.actionExecutor.mutationLog.append(
            .axValue(
                element: AXUIElementCreateApplication(1), oldValue: "old", summary: "An older edit"))
        let oldMutationCount = manager.actionExecutor.mutationLog.count
        manager.noteReversibleActionExecuted(sinceMutationCount: oldMutationCount)
        #expect(manager.mostRecentReversibleActionAt == nil)
        manager.actionExecutor.mutationLog.append(
            .axValue(
                element: AXUIElementCreateApplication(1), oldValue: "before", summary: "Actual earlier edit"))
        manager.noteReversibleActionExecuted(sinceMutationCount: oldMutationCount)
        #expect(manager.mostRecentReversibleActionSummary == "Actual earlier edit")
        #expect(manager.mostRecentReversibleActionAt != nil)
        let callReceipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(callReceipt.contains("earlier_write:"))
        #expect(!callReceipt.contains("future_write:"))

        manager.clearReversibleActionUndoState()
        executor.beginUserTurn()
        let blockedReceipt = await executor.executeActionPlanWithReceipt(
            .serial(actions: [inspection, futureWrite]), screenCaptures: [])
        #expect(blockedReceipt.executedPlan.flattenedActions.isEmpty)
        manager.noteReversibleActionExecuted(sinceMutationCount: manager.actionExecutor.mutationLog.count)
        #expect(manager.mostRecentReversibleActionAt == nil)
        #expect(!PaceActionApprovalPolicy.actionIsReversibleMutation(inspection))
        #expect(
            !PaceActionApprovalPolicy.actionIsReversibleMutation(
                .mcp(.init(serverName: "peekaboo", toolName: "see", arguments: [:]))))
        #expect(PaceActionApprovalPolicy.actionIsReversibleMutation(earlierWrite))
    }

    @MainActor
    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func executorUsesLaunchedPIDAndStopsTheOriginalPlanAfterAmbiguousInspection() async throws {
        let fixtureProgram = #"""
        import json, sys
        calls = 0
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            if request["method"] == "initialize":
                result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "dispatch-fixture", "version": "1"}}
            else:
                calls += 1
                params = request["params"]
                target = params.get("arguments", {}).get("app", "")
                if params["name"] == "window" and target != "PID:4123":
                    result = {"isError": True, "content": [{"type": "text", "text": "Multiple apps match 'Google Chrome'. Did you mean: PID:111 or PID:222?"}]}
                else:
                    result = {"content": [{"type": "text", "text": "calls=" + str(calls) + ";target=" + target}]}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#
        let configuration = PaceMCPServerConfiguration(
            command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3", args: ["-u", "-c", fixtureProgram])
        let client = PaceMCPStdioClient(serverConfigurations: ["peekaboo": configuration])
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { true }, runningApplicationBundleURL: { _ in chromeURL },
            preferredInspectionProcessIdentifiers: { [] })
        executor.rememberLaunchedApplication(named: "Chrome", processIdentifier: 4123, bundleURL: chromeURL, generation: executor.applicationTargetGeneration)
        let inspection = PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["action": .string("list"), "app": .string("Google Chrome")])
        let boundResult = await executor.callMCPTool(inspection)
        #expect(boundResult.summary.contains("target=PID:4123"))
        #expect(!boundResult.stopsAgentLoop)

        executor.beginUserTurn()
        let blockedResults = await executor.executeActionPlan(.serial(actions: [
            .mcp(inspection),
            .mcp(.init(serverName: "peekaboo", toolName: "click", arguments: ["query": .string("should not click")])),
            .mcp(.init(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("should not inspect")])),
        ]), screenCaptures: [])
        #expect(blockedResults.count == 1)
        #expect(blockedResults.first?.terminalReason == .ambiguousInspectionTarget)
        #expect(blockedResults.first?.stopsActionPlan == true)
        #expect(blockedResults.first?.stopsAgentLoop == false)
        #expect(PaceActionExecutionObservation.formatForUserFeedback(blockedResults) == nil)
        let receipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(receipt.contains("calls=5;"))
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func ambiguousReadOnlyInventoryReturnsAllValidatedCandidatesWithoutBindingOrLaterWrites() async throws {
        let client = PaceMCPFixture.makeAmbiguityClient()
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { true }, runningApplicationBundleURL: { _ in chromeURL },
            preferredInspectionProcessIdentifiers: { [222] })
        let inspection = PaceMCPToolCall(
            serverName: "peekaboo", toolName: "window",
            arguments: [
                "action": .string("list"), "app": .string("Google Chrome"),
            ])
        let plan = PaceActionExecutionPlan.serial(actions: [
            .mcp(inspection), .mcp(.init(serverName: "peekaboo", toolName: "click", arguments: [:])),
            .type("never type"),
        ])
        let observations = await executor.executeActionPlan(plan, screenCaptures: [])
        #expect(observations.count == 1)
        let observation = try #require(observations.first)
        #expect(observation.requiresFreshInspectionPlan)
        #expect(!observation.stopsAgentLoop)
        #expect(observation.summary.contains("Preview PID:111"))
        #expect(observation.summary.contains("Preview PID:222"))
        #expect(observation.summary.contains("inventory may be incomplete"))
        #expect(try executor.boundPeekabooToolCall(inspection) == inspection)
        #expect(PaceActionApprovalPolicy.needsAnswerAfterInspection(plan, observations: observations))
        let receipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(receipt.components(separatedBy: "\n") == ["window:Google Chrome", "window:PID:222", "window:PID:111"])

        let repeated = await executor.callMCPTool(inspection)
        #expect(repeated.terminalReason == .ambiguousApplicationTarget)
        #expect(repeated.userFacingSummary == "Which Google Chrome window do you mean?")
        let repeatedReceipt = try await client.callTool(
            .init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(repeatedReceipt.components(separatedBy: "\n").count == 4)
        executor.beginUserTurn()
        #expect(await executor.callMCPTool(inspection).requiresFreshInspectionPlan)
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func ambiguityDoesNotRecoverMutationsScreenshotsOrExactSelectors() async throws {
        let requests = [
            PaceMCPToolCall(
                serverName: "peekaboo", toolName: "window",
                arguments: ["action": .string("focus"), "app": .string("Google Chrome")]),
            PaceMCPToolCall(
                serverName: "peekaboo", toolName: "see", arguments: ["app_target": .string("Google Chrome")]),
            PaceMCPToolCall(
                serverName: "peekaboo", toolName: "window",
                arguments: ["action": .string("list"), "app": .string("Google Chrome"), "window_id": .number(123)]),
        ]
        for request in requests {
            let client = PaceMCPFixture.makeAmbiguityClient()
            let executor = PaceActionExecutor(
                actionsAreEnabledOverride: true, mcpClient: client,
                readMyScreenIsEnabled: { true },
                runningApplicationBundleURL: { _ in URL(fileURLWithPath: "/Applications/Google Chrome.app") },
                preferredInspectionProcessIdentifiers: { [] })
            let observations = await executor.executeActionPlan(
                .serial(actions: [
                    .mcp(request), .mcp(.init(serverName: "peekaboo", toolName: "click", arguments: [:])),
                ]), screenCaptures: [])
            #expect(observations.count == 1)
            #expect(observations.first?.terminalReason == .ambiguousApplicationTarget)
            #expect(observations.first?.stopsAgentLoop == true)
            let receipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
            #expect(receipt.components(separatedBy: "\n").count == 1)
        }
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func deadOrWrongApplicationCandidatesUseOnlyOneReadOnlyAppInventory() async throws {
        let client = PaceMCPFixture.makeAmbiguityClient()
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { true },
            runningApplicationBundleURL: { identifier in
                identifier == 111 ? nil : URL(fileURLWithPath: "/Applications/Safari.app")
            }, preferredInspectionProcessIdentifiers: { [] })
        let result = await executor.callMCPTool(
            .init(
                serverName: "peekaboo", toolName: "window",
                arguments: [
                    "action": .string("list"), "app": .string("Google Chrome"),
                ]))
        #expect(result.requiresFreshInspectionPlan)
        #expect(result.summary.contains("Current application inventory"))
        let receipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(receipt.components(separatedBy: "\n") == ["window:Google Chrome", "app:"])
    }

    @MainActor @Test func candidateParsingIsBoundedAndPrioritizesOnlyValidatedVisibleProcesses() {
        let diagnostic = "PID:-1 PID:0 PID:9999999999 PID:111 PID:111 PID:222 PID:333 PID:444 PID:555 PID:666"
        #expect(PaceActionExecutor.peekabooAmbiguousProcessIdentifiers(in: diagnostic) == [111, 222, 333, 444])
        #expect(
            PaceActionExecutor.peekabooAmbiguousProcessIdentifiers(
                in: diagnostic, preferring: [666, 999], matchesApplication: { $0 != 111 }) == [666, 222, 333, 444])
        #expect(
            PaceActionExecutor.peekabooAmbiguousProcessIdentifiers(
                in: String(repeating: "x", count: 8_000) + " PID:777"
            ).isEmpty)
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func revocationCancellationAndNewTurnsStopRecoveryAfterAnAwait() async throws {
        for interruption in ["revoke", "cancel", "newTurn"] {
            let signalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pace-inspection-\(UUID())")
            try FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: signalDirectory) }
            let client = PaceMCPFixture.makeAmbiguityClient(signalDirectory: signalDirectory)
            var canReadScreen = true
            let executor = PaceActionExecutor(
                actionsAreEnabledOverride: true, mcpClient: client,
                readMyScreenIsEnabled: { canReadScreen },
                runningApplicationBundleURL: { _ in URL(fileURLWithPath: "/Applications/Google Chrome.app") },
                preferredInspectionProcessIdentifiers: { [] })
            let task = Task { @MainActor in
                await executor.callMCPTool(
                    .init(
                        serverName: "peekaboo", toolName: "window",
                        arguments: [
                            "action": .string("list"), "app": .string("Google Chrome"),
                        ]))
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !FileManager.default.fileExists(atPath: signalDirectory.appendingPathComponent("started").path),
                ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(FileManager.default.fileExists(atPath: signalDirectory.appendingPathComponent("started").path))
            switch interruption {
            case "revoke": canReadScreen = false
            case "cancel": task.cancel()
            default: executor.beginUserTurn()
            }
            try Data().write(to: signalDirectory.appendingPathComponent("release"))
            let result = await task.value
            #expect(result.terminalReason == .inspectionInterrupted)
            #expect(result.stopsAgentLoop)
            let receipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
            #expect(receipt.components(separatedBy: "\n") == ["window:Google Chrome", "window:PID:111"])
        }
    }

    @MainActor @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func anInventoryFromAReusedProcessIsDiscardedAfterItsAwait() async throws {
        let signalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pace-inspection-\(UUID())")
        try FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: signalDirectory) }
        let client = PaceMCPFixture.makeAmbiguityClient(signalDirectory: signalDirectory)
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        var firstProcessBundleURL = chromeURL
        let executor = PaceActionExecutor(
            actionsAreEnabledOverride: true, mcpClient: client,
            readMyScreenIsEnabled: { true },
            runningApplicationBundleURL: { identifier in
                identifier == 111 ? firstProcessBundleURL : chromeURL
            }, preferredInspectionProcessIdentifiers: { [] })
        let task = Task { @MainActor in
            await executor.callMCPTool(
                .init(
                    serverName: "peekaboo", toolName: "window",
                    arguments: [
                        "action": .string("list"), "app": .string("Google Chrome"),
                    ]))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: signalDirectory.appendingPathComponent("started").path),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(FileManager.default.fileExists(atPath: signalDirectory.appendingPathComponent("started").path))
        firstProcessBundleURL = URL(fileURLWithPath: "/Applications/Safari.app")
        try Data().write(to: signalDirectory.appendingPathComponent("release"))
        let result = await task.value
        #expect(result.requiresFreshInspectionPlan)
        #expect(!result.summary.contains("Preview PID:111"))
        #expect(result.summary.contains("PID:111 changed during inspection"))
        #expect(result.summary.contains("Preview PID:222"))
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func ambiguousPeekabooResolutionIsTypedButUncertainDispatchRemainsRecoverable() async throws {
        let fixtureProgram = #"""
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            if request["method"] == "initialize":
                result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "target-fixture", "version": "1"}}
            else:
                result = {"isError": True, "content": [{"type": "text", "text": request["params"]["arguments"]["failure"]}]}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#
        let configuration = PaceMCPServerConfiguration(
            command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3", args: ["-u", "-c", fixtureProgram])
        let client = PaceMCPStdioClient(serverConfigurations: ["peekaboo": configuration, "other": configuration])
        let ambiguousMessage = "Failed to list windows: Multiple apps match 'Google Chrome'. Did you mean: Google Chrome (PID:111), Google Chrome (PID:222)"
        do {
            _ = try await client.callTool(.init(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Google Chrome"), "failure": .string(ambiguousMessage)]))
            Issue.record("Ambiguous app resolution must fail")
        } catch PaceMCPClientError.ambiguousApplicationTarget(let message) {
            #expect(message.contains("PID:111"))
            #expect(message.contains("PID:222"))
        }
        for (serverName, message) in [
            ("other", ambiguousMessage),
            ("peekaboo", "Dispatch outcome uncertain. Capture a fresh snapshot before retrying."),
        ] {
            do {
                _ = try await client.callTool(.init(serverName: serverName, toolName: "window", arguments: ["app": .string("Google Chrome"), "failure": .string(message)]))
                Issue.record("Expected fixture failure")
            } catch PaceMCPClientError.rpcError(let result) {
                #expect(result.contains(message))
            }
        }
        let independentClient = PaceMCPFixture.makeFixtureClient()
        let result = try await independentClient.callTool(.init(serverName: "fixture", toolName: "echo", arguments: ["text": .string("unrelated request preserved")]))
        #expect(result.contains("unrelated request preserved"))
    }

    @Test func quotedAppAmbiguityOutsidePeekabooTargetResolutionIsNotTerminal() {
        let diagnostic = "Multiple apps match 'Google Chrome'. Did you mean: Google Chrome (PID:111)"
        for request in [
            PaceMCPToolCall(serverName: "research", toolName: "window", arguments: ["app": .string("Google Chrome")]),
            PaceMCPToolCall(serverName: "peekaboo", toolName: "echo", arguments: ["app": .string("Google Chrome")]),
            PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: [:]),
            PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Safari")]),
        ] {
            let error = PaceMCPClientError.classifyToolError(PaceMCPClientError.rpcError(diagnostic), toolCall: request)
            guard let clientError = error as? PaceMCPClientError, case .rpcError = clientError else {
                Issue.record("Unrelated error must remain recoverable")
                continue
            }
        }
        let request = PaceMCPToolCall(serverName: "peekaboo", toolName: "window", arguments: ["app": .string("Google Chrome")])
        let quotedError = PaceMCPClientError.classifyToolError(PaceMCPClientError.rpcError("Documentation quotes: " + diagnostic), toolCall: request)
        guard let clientError = quotedError as? PaceMCPClientError, case .rpcError = clientError else {
            Issue.record("Quoted diagnostic is not a provider resolution failure")
            return
        }
    }

    @Test
    func missingExecutableReportsActionableLocalizedFailure() async {
        let missingCommand = "/tmp/pace-missing-server-\(UUID())"
        let client = PaceMCPStdioClient(serverConfigurations: [
            "missing-fixture": .init(command: missingCommand)
        ])
        do {
            _ = try await client.toolCatalog(serverName: "missing-fixture")
            Issue.record("Missing executable must fail")
        } catch {
            #expect(error.localizedDescription.contains("not executable"))
            #expect(error.localizedDescription.contains(missingCommand))
        }
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func slowServerDoesNotBlockUnrelatedServer() async throws {
        let configuration = PaceMCPServerConfiguration(
            command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3",
            args: [PaceMCPFixture.fixtureScriptPath])
        let client = PaceMCPStdioClient(serverConfigurations: [
            "slow-fixture": configuration, "fast-fixture": configuration,
        ])
        // Warm both producers before testing independent request serialization.
        _ = try await client.toolCatalog(serverName: "slow-fixture")
        _ = try await client.toolCatalog(serverName: "fast-fixture")
        let slow = Task {
            try await client.callTool(
                .init(serverName: "slow-fixture", toolName: "sleep", arguments: ["seconds": .number(2)]))
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        let result = try await client.callTool(
            .init(serverName: "fast-fixture", toolName: "echo", arguments: ["text": .string("independent")]))
        #expect(result.contains("independent"))
        #expect(started.duration(to: .now) < .seconds(1))
        _ = try await slow.value
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func echoToolCallRoundTripsTextThroughFixtureServer() async throws {
        let fixtureClient = PaceMCPFixture.makeFixtureClient()
        let observationText = try await fixtureClient.callTool(
            PaceMCPToolCall(
                serverName: "fixture",
                toolName: "echo",
                arguments: ["text": .string("hello pace")]
            )
        )
        #expect(observationText.contains("hello pace"))
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func toolResultWithIsErrorCannotBeReportedAsSuccessfulAction() async throws {
        let configuration = PaceMCPServerConfiguration(
            command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3", args: [PaceMCPFixture.fixtureScriptPath]
        )
        for serverName in ["fixture", "peekaboo"] {
            let client = PaceMCPStdioClient(serverConfigurations: [serverName: configuration])
            do {
                _ = try await client.callTool(.init(serverName: serverName, toolName: "fail", arguments: [:]))
                Issue.record("Expected the \(serverName) transport to reject isError=true")
            } catch PaceMCPClientError.rpcError(let message) {
                #expect(message.contains("intentional fixture failure"))
            }
        }
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func unknownToolNameSurfacesJSONRPCErrorAsRpcError() async {
        let fixtureClient = PaceMCPFixture.makeFixtureClient()
        do {
            _ = try await fixtureClient.callTool(
                PaceMCPToolCall(serverName: "fixture", toolName: "does_not_exist", arguments: [:])
            )
            Issue.record("Expected rpcError for an unknown tool name")
        } catch let mcpError as PaceMCPClientError {
            guard case .rpcError(let errorMessage) = mcpError else {
                Issue.record("Expected rpcError, got \(mcpError)")
                return
            }
            #expect(errorMessage.contains("unknown tool"))
        } catch {
            Issue.record("Expected PaceMCPClientError, got \(error)")
        }
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func peekabooDiscoveryAndActionsKeepTheSameProducerProcess() async throws {
        let configuration = PaceMCPServerConfiguration(
            command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3",
            args: [PaceMCPFixture.fixtureScriptPath]
        )
        let client = PaceMCPStdioClient(serverConfigurations: ["peekaboo": configuration])
        let catalog = try await client.peekabooToolCatalog()
        #expect(catalog.contains("inputSchema"))
        #expect(catalog.contains("app"))
        #expect(!catalog.contains("analyze"))
        let identityRequest = PaceMCPToolCall(serverName: "peekaboo", toolName: "session_identity", arguments: [:])
        let firstProducer = try await client.callTool(identityRequest)
        let secondProducer = try await client.callTool(identityRequest)
        #expect(firstProducer == secondProducer)
        #expect(Int(firstProducer) != nil)
        let evidence = try await client.callTool(
            .init(
                serverName: "peekaboo", toolName: "echo", arguments: ["text": .string("tool summary")]
            ))
        #expect(evidence.contains("structured evidence"))
        #expect(evidence.contains("producer-bound-fixture"))
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func arbitraryConfiguredServerDiscoversSchemasAndKeepsItsProducer() async throws {
        let client = PaceMCPFixture.makeFixtureClient()
        let catalog = try await client.toolCatalog(serverName: "fixture")
        #expect(catalog.contains("inputSchema"))
        #expect(catalog.contains("Fixture app inventory"))
        let request = PaceMCPToolCall(serverName: "fixture", toolName: "session_identity", arguments: [:])
        let first = try await client.callTool(request)
        let second = try await client.callTool(request)
        #expect(first == second)
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func genericServerPreservesStructuredOnlyToolResults() async throws {
        let client = PaceMCPFixture.makeFixtureClient()
        let result = try await client.callTool(
            .init(serverName: "fixture", toolName: "structured_only", arguments: [:]))
        #expect(result.contains("assigned_issue"))
        #expect(result.contains("PACE-42"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_PEEKABOO_INTEGRATION"] == "1"))
    func installedPeekabooPublishesItsRealComputerUseSchemas() async throws {
        let entry = try #require(PaceMCPServerCatalog.entry(forSlug: "peekaboo"))
        let configuration = PaceMCPServerConfiguration(
            command: "/opt/homebrew/bin/npx",
            args: entry.arguments
        )
        let client = PaceMCPStdioClient(
            serverConfigurations: ["peekaboo": configuration], requestTimeoutInSeconds: 60
        )
        let catalog = try await client.peekabooToolCatalog()
        for toolName in ["see", "click", "type", "press", "app", "window"] {
            #expect(catalog.contains("\"name\":\"" + toolName + "\""))
        }
        #expect(catalog.contains("inputSchema"))
        #expect(!catalog.contains("\"name\":\"analyze\""))
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func sdkTimeoutClosesTheProducerWithoutReplayingTheCall() async throws {
        let configuration = PaceMCPServerConfiguration(
            command: PaceMCPFixture.pythonThreeExecutablePath ?? "python3", args: [PaceMCPFixture.fixtureScriptPath]
        )
        let client = PaceMCPStdioClient(
            serverConfigurations: ["playwright": configuration], requestTimeoutInSeconds: 0.5)
        let identity = PaceMCPToolCall(serverName: "playwright", toolName: "session_identity", arguments: [:])
        let firstProducer = try await client.callTool(identity)
        do {
            _ = try await client.callTool(
                .init(serverName: "playwright", toolName: "sleep", arguments: ["seconds": .number(5)]))
            Issue.record("Expected the slow SDK request to time out")
        } catch PaceMCPClientError.requestTimedOut {}
        let newProducer = try await client.callTool(identity)
        #expect(firstProducer != newProducer)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_OSS_BROWSER_INTEGRATION"] == "1"))
    func installedPlaywrightPublishesRealBrowserSchemas() async throws {
        let configuration = PaceMCPServerConfiguration(
            command: "/opt/homebrew/bin/npx",
            args: ["-y", "@playwright/mcp@0.0.85", "--browser", "chrome", "--isolated"]
        )
        let client = PaceMCPStdioClient(
            serverConfigurations: ["playwright": configuration], requestTimeoutInSeconds: 60)
        let catalog = try await client.playwrightToolCatalog()
        for name in ["browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_fill_form"] {
            #expect(catalog.contains("\"name\":\"" + name + "\""))
        }
        #expect(!catalog.contains("browser_run_code"))
    }

    @Test func starterConfigurationSeedsAppleMCPServer() throws {
        let starterData = try #require(PaceMCPServerRegistry.starterConfigurationJSON.data(using: .utf8))
        let decodedRoot = try JSONDecoder().decode(
            [String: [String: PaceMCPServerConfiguration]].self,
            from: starterData
        )
        let appleServerConfiguration = try #require(decodedRoot["mcpServers"]?["apple"])
        #expect(appleServerConfiguration.command == "npx")
        #expect(appleServerConfiguration.args == ["-y", "apple-mcp"])
    }

    @Test func unconfiguredServerNameThrowsServerNotConfigured() async {
        let clientWithNoServers = PaceMCPStdioClient(serverConfigurations: [:])
        do {
            _ = try await clientWithNoServers.callTool(
                PaceMCPToolCall(serverName: "missing", toolName: "echo", arguments: [:])
            )
            Issue.record("Expected serverNotConfigured")
        } catch let mcpError as PaceMCPClientError {
            guard case .serverNotConfigured(let serverName) = mcpError else {
                Issue.record("Expected serverNotConfigured, got \(mcpError)")
                return
            }
            #expect(serverName == "missing")
        } catch {
            Issue.record("Expected PaceMCPClientError, got \(error)")
        }
    }

    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func slowToolCallTimesOutWithShortTimeout() async {
        let fixtureClient = PaceMCPFixture.makeFixtureClient(requestTimeoutInSeconds: 2)
        do {
            _ = try await fixtureClient.callTool(
                PaceMCPToolCall(
                    serverName: "fixture",
                    toolName: "sleep",
                    arguments: ["seconds": .number(10)]
                )
            )
            Issue.record("Expected requestTimedOut")
        } catch let mcpError as PaceMCPClientError {
            guard case .requestTimedOut = mcpError else {
                Issue.record("Expected requestTimedOut, got \(mcpError)")
                return
            }
        } catch {
            Issue.record("Expected PaceMCPClientError, got \(error)")
        }
    }
}
