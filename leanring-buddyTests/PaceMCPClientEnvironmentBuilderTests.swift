//
//  PaceMCPClientEnvironmentBuilderTests.swift
//  leanring-buddyTests
//
//  Pins the spawn-time env-substitution logic that backs Composio's
//  Keychain-managed API key. The injected `secretLookup` closure lets
//  these tests run without touching the real Keychain or spawning a
//  subprocess — which would have failed under `xcodebuild test`'s
//  unsigned harness anyway.
//

import Foundation
import Testing
@testable import Pace

struct PaceMCPClientEnvironmentBuilderTests {

    @Test func emptySentinelTriggersSecretLookupForMatchingServerAndKey() async throws {
        let resolved = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: ["PATH": "/usr/bin"],
            serverConfigurationEnvironment: ["COMPOSIO_API_KEY": ""],
            serverSlug: "composio",
            secretLookup: { server, key in
                if server == "composio" && key == "COMPOSIO_API_KEY" {
                    return "secret-from-keychain"
                }
                return nil
            }
        )
        #expect(resolved["COMPOSIO_API_KEY"] == "secret-from-keychain")
    }

    @Test func nonEmptyValueIsForwardedVerbatimAndSkipsLookup() async throws {
        var lookupCallCount = 0
        let resolved = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: [:],
            serverConfigurationEnvironment: ["GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_in_config"],
            serverSlug: "github",
            secretLookup: { _, _ in
                lookupCallCount += 1
                return "this-should-never-be-used"
            }
        )
        #expect(resolved["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_in_config")
        #expect(lookupCallCount == 0)
    }

    @Test func emptySentinelWithMissingSecretLeavesSentinelInPlace() async throws {
        // When the user hasn't stored a secret yet, we must NOT
        // silently inherit some unrelated value from the parent
        // shell's env. The empty sentinel survives so the spawned
        // subprocess fails loudly with "missing API key".
        let resolved = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: ["COMPOSIO_API_KEY": "leaked-from-parent-shell"],
            serverConfigurationEnvironment: ["COMPOSIO_API_KEY": ""],
            serverSlug: "composio",
            secretLookup: { _, _ in nil }
        )
        #expect(resolved["COMPOSIO_API_KEY"] == "")
    }

    @Test func unrelatedBaseEnvVarsPassThrough() async throws {
        let resolved = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: [
                "PATH": "/usr/bin:/usr/local/bin",
                "HOME": "/Users/test",
                "LANG": "en_US.UTF-8"
            ],
            serverConfigurationEnvironment: ["COMPOSIO_API_KEY": ""],
            serverSlug: "composio",
            secretLookup: { _, _ in "k" }
        )
        #expect(resolved["PATH"] == "/usr/bin:/usr/local/bin")
        #expect(resolved["HOME"] == "/Users/test")
        #expect(resolved["LANG"] == "en_US.UTF-8")
        #expect(resolved["COMPOSIO_API_KEY"] == "k")
    }

    @Test func secretLookupReceivesExactServerSlugAndKey() async throws {
        var observedServerArg: String?
        var observedKeyArg: String?
        _ = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: [:],
            serverConfigurationEnvironment: ["SLACK_BOT_TOKEN": ""],
            serverSlug: "slack",
            secretLookup: { server, key in
                observedServerArg = server
                observedKeyArg = key
                return "xoxb-foo"
            }
        )
        #expect(observedServerArg == "slack")
        #expect(observedKeyArg == "SLACK_BOT_TOKEN")
    }

    @Test func multipleEnvKeysHandledIndependently() async throws {
        // A future server with both a sentinel + a configured value
        // (e.g. Slack: bot token from Keychain, team ID in plain
        // config because it's not a secret) should resolve each
        // independently.
        let resolved = PaceMCPClientEnvironmentBuilder.buildSpawnEnvironment(
            baseEnvironment: [:],
            serverConfigurationEnvironment: [
                "SLACK_BOT_TOKEN": "",
                "SLACK_TEAM_ID": "T01ABCDEF"
            ],
            serverSlug: "slack",
            secretLookup: { _, key in
                key == "SLACK_BOT_TOKEN" ? "xoxb-from-keychain" : nil
            }
        )
        #expect(resolved["SLACK_BOT_TOKEN"] == "xoxb-from-keychain")
        #expect(resolved["SLACK_TEAM_ID"] == "T01ABCDEF")
    }
}
