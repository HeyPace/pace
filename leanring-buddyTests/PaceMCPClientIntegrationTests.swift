//
//  PaceMCPClientIntegrationTests.swift
//  leanring-buddyTests
//
//  End-to-end validation of the stdio MCP bridge against the in-repo
//  fixture server (scripts/mcp-fixture-server.py). These tests prove the
//  full initialize → notifications/initialized → tools/call round trip
//  with a real child process, not a mock.
//

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
}

@Suite(.serialized)
struct PaceMCPClientIntegrationTests {
    @MainActor
    @Test(.enabled(if: PaceMCPFixture.isFixtureRunnable))
    func executorUsesLaunchedPIDAndStopsAllLaterDispatchAfterAmbiguousInspection() async throws {
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
            readMyScreenIsEnabled: { true }, runningApplicationBundleURL: { _ in chromeURL })
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
        #expect(blockedResults.first?.terminalReason == .ambiguousApplicationTarget)
        #expect(PaceActionExecutionObservation.formatForUserFeedback(blockedResults)?.contains("remaining actions were not run") == true)
        let receipt = try await client.callTool(.init(serverName: "peekaboo", toolName: "receipt", arguments: [:]))
        #expect(receipt.contains("calls=3;"))
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
