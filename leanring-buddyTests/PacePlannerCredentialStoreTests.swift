import AppKit
import Foundation
import Testing

@testable import Pace

@MainActor
private final class CredentialLoaderFixture {
    var calls = 0
    var shouldFail = false
    var pause = false
    var cancellationCount = 0
    var receivedConfigurations: [PaceInfisicalCredentialConfiguration] = []
    var value = "sk-synthetic-credential-for-automated-tests-only"

    func load(_ configuration: PaceInfisicalCredentialConfiguration) async throws -> String {
        calls += 1
        receivedConfigurations.append(configuration)
        do {
            while pause {
                try await Task.sleep(for: .milliseconds(1))
            }
            if shouldFail {
                throw PacePlannerCredentialError.unavailable
            }
            return value
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

@MainActor
private final class LateCredentialFailureFixture {
    var calls = 0
    var completeFirstFetch: CheckedContinuation<Void, Never>?

    func load() async throws -> String {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { completeFirstFetch = $0 }
            throw PacePlannerCredentialError.unavailable
        }
        return "sk-synthetic-credential-for-automated-tests-only"
    }
}

@MainActor
struct PacePlannerCredentialStoreTests {
    private let configuration = PaceInfisicalCredentialConfiguration(
        projectID: "11111111-1111-4111-8111-111111111111",
        organizationID: "22222222-2222-4222-8222-222222222222",
        environment: "dev", secretPath: "/pace", secretName: "OPENAI_API_KEY"
    )

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    private func makeReadinessManager(store: PacePlannerCredentialStore) -> CompanionManager {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        manager.fastEverydayAnswersEnabled = true
        manager.activePlannerTier = .cliDirect
        manager.activePlannerTierCLIDirectUpstream = .codex
        manager.plannerClient = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        manager.fastAnswerCredentialSourceIsReady = { true }
        manager.fastAnswerCredentialStore = store
        return manager
    }

    @Test func queuedReadinessRechecksAuthorizationBeforeLoading() async throws {
        let fixture = CredentialLoaderFixture()
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) })
        let manager = makeReadinessManager(store: store)
        var sourceIsReady = true
        manager.fastAnswerCredentialSourceIsReady = { sourceIsReady }
        manager.prewarmFastAnswerCredentialsIfNeeded()
        let queuedPrewarm = try #require(manager.fastAnswerCredentialPrewarmTask)
        sourceIsReady = false
        await queuedPrewarm.value
        #expect(fixture.calls == 0)
        #expect(manager.fastAnswerCredentialPrewarmTask == nil)
    }

    @Test func queuedReadinessRechecksSelectedBrainAndFastAnswerOptIn() async throws {
        for revokedSetting in ["fastAnswers", "tier", "upstream", "automaticPlanner"] {
            let fixture = CredentialLoaderFixture()
            let store = PacePlannerCredentialStore(
                loadConfiguration: { configuration },
                loadInfisicalKey: { try await fixture.load($0) })
            let manager = makeReadinessManager(store: store)
            manager.prewarmFastAnswerCredentialsIfNeeded()
            let queuedPrewarm = try #require(manager.fastAnswerCredentialPrewarmTask)
            switch revokedSetting {
            case "fastAnswers": manager.fastEverydayAnswersEnabled = false
            case "tier": manager.activePlannerTier = .local
            case "upstream": manager.activePlannerTierCLIDirectUpstream = .claude
            default:
                manager.plannerClient = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: "explicit-model")
            }
            await queuedPrewarm.value
            #expect(fixture.calls == 0)
            #expect(manager.fastAnswerCredentialPrewarmTask == nil)
        }
    }

    @Test func repeatedReadinessSharesOneOwnedPrewarmAndInvalidationRejectsOldCleanup() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.pause = true
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) })
        let manager = makeReadinessManager(store: store)
        defer { manager.invalidateFastAnswerCredentialPrewarm() }
        for _ in 0..<10 { manager.prewarmFastAnswerCredentialsIfNeeded() }
        let oldPrewarm = try #require(manager.fastAnswerCredentialPrewarmTask)
        try await waitUntil { fixture.calls == 1 }
        for _ in 0..<10 { manager.prewarmFastAnswerCredentialsIfNeeded() }
        #expect(fixture.calls == 1)

        manager.invalidateFastAnswerCredentialPrewarm()
        manager.prewarmFastAnswerCredentialsIfNeeded()
        let replacementPrewarm = try #require(manager.fastAnswerCredentialPrewarmTask)
        await oldPrewarm.value
        try await waitUntil { fixture.calls == 2 }
        #expect(manager.fastAnswerCredentialPrewarmTask != nil)
        fixture.pause = false
        await replacementPrewarm.value
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
        #expect(manager.fastAnswerCredentialPrewarmTask == nil)
    }

    @Test func invalidatedQueuedReadinessNeverStartsTheLoader() async throws {
        let fixture = CredentialLoaderFixture()
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) })
        let manager = makeReadinessManager(store: store)
        manager.prewarmFastAnswerCredentialsIfNeeded()
        let queuedPrewarm = try #require(manager.fastAnswerCredentialPrewarmTask)
        manager.invalidateFastAnswerCredentialPrewarm()
        await queuedPrewarm.value
        #expect(fixture.calls == 0)
        #expect(manager.fastAnswerCredentialPrewarmTask == nil)
    }

    @Test func wakeReadinessRefreshesExpiredKeyAndDemandJoinsWithoutIdleRefresh() async throws {
        let fixture = CredentialLoaderFixture()
        var elapsed: TimeInterval = 100
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) }, now: { elapsed })
        #expect(try await store.loadOpenAIKey() == fixture.value)
        let manager = makeReadinessManager(store: store)
        let workspaceNotifications = NotificationCenter()
        let panelManager = MenuBarPanelManager(
            companionManager: manager, workspaceNotificationCenter: workspaceNotifications)
        defer {
            manager.invalidateFastAnswerCredentialPrewarm()
            withExtendedLifetime(panelManager) {}
        }
        elapsed += 30 * 60
        fixture.value = "sk-refreshed-synthetic-credential-for-tests-only"
        fixture.pause = true
        workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { fixture.calls == 2 }
        let wakePrewarm = try #require(manager.fastAnswerCredentialPrewarmTask)
        var demandStarted = false
        let demand = Task {
            demandStarted = true
            return try await store.loadOpenAIKey()
        }
        try await waitUntil { demandStarted }
        #expect(fixture.calls == 2)
        fixture.pause = false
        #expect(try await demand.value == fixture.value)
        await wakePrewarm.value
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)

        elapsed += 30 * 60
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.calls == 2)
        #expect(manager.fastAnswerCredentialPrewarmTask == nil)
        fixture.value = "sk-next-synthetic-credential-for-tests-only"
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 3)
    }

    @Test func configuredInfisicalBypassesKeychainAndCachesOnlyInMemory() async throws {
        let fixture = CredentialLoaderFixture()
        var keychainCalls = 0
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadKeychain: {
                keychainCalls += 1
                return "wrong-source"
            }, loadInfisicalKey: { try await fixture.load($0) }
        )
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 1)
        #expect(keychainCalls == 0)
    }

    @Test func absentConfigurationPreservesExistingKeychainBehavior() async throws {
        let fixture = CredentialLoaderFixture()
        let store = PacePlannerCredentialStore(
            loadConfiguration: { nil },
            loadKeychain: { "existing-keychain-key" },
            loadInfisicalKey: { try await fixture.load($0) }
        )
        #expect(try await store.loadOpenAIKey() == "existing-keychain-key")
        #expect(fixture.calls == 0)
    }

    @Test func configuredFailureDoesNotFallbackOrRepeatFetchUntilBackoffExpires() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.shouldFail = true
        var keychainCalls = 0
        var elapsed: TimeInterval = 100
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadKeychain: {
                keychainCalls += 1
                return "wrong-source"
            }, loadInfisicalKey: { try await fixture.load($0) }, now: { elapsed }
        )
        await #expect(throws: PacePlannerCredentialError.self) { try await store.loadOpenAIKey() }
        fixture.shouldFail = false
        await #expect(throws: PacePlannerCredentialError.self) { try await store.loadOpenAIKey() }
        elapsed += 29
        await #expect(throws: PacePlannerCredentialError.self) { try await store.loadOpenAIKey() }
        #expect(fixture.calls == 1)
        elapsed += 1
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
        #expect(keychainCalls == 0)
    }

    @Test func explicitClearRetriesAfterFailedFetchWithoutWaitingForBackoff() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.shouldFail = true
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) })
        await #expect(throws: PacePlannerCredentialError.self) { try await store.loadOpenAIKey() }
        fixture.shouldFail = false
        store.clearCachedKey()
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
    }

    @Test func configurationChangeDoesNotInheritPreviousSourceFailureBackoff() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.shouldFail = true
        var selectedConfiguration = configuration
        let store = PacePlannerCredentialStore(
            loadConfiguration: { selectedConfiguration },
            loadInfisicalKey: { try await fixture.load($0) })
        await #expect(throws: PacePlannerCredentialError.self) { try await store.loadOpenAIKey() }
        selectedConfiguration = .init(
            projectID: configuration.projectID, organizationID: configuration.organizationID,
            environment: "production", secretPath: "/other", secretName: "OPENAI_API_KEY")
        fixture.shouldFail = false
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
    }

    @Test func lateFailureFromOldConfigurationCannotSetNewSourceBackoff() async throws {
        let fixture = LateCredentialFailureFixture()
        var selectedConfiguration = configuration
        var elapsed: TimeInterval = 100
        let store = PacePlannerCredentialStore(
            loadConfiguration: { selectedConfiguration },
            loadInfisicalKey: { _ in try await fixture.load() }, now: { elapsed }, cacheLifetime: 1)
        let oldRequest = Task { try await store.loadOpenAIKey() }
        try await waitUntil { fixture.completeFirstFetch != nil }
        selectedConfiguration = .init(
            projectID: configuration.projectID, organizationID: configuration.organizationID,
            environment: "production", secretPath: "/other", secretName: "OPENAI_API_KEY")
        _ = try await store.loadOpenAIKey()
        fixture.completeFirstFetch?.resume()
        await #expect(throws: PacePlannerCredentialError.self) { try await oldRequest.value }
        elapsed += 1
        #expect(try await store.loadOpenAIKey() != nil)
        #expect(fixture.calls == 3)
    }

    @Test func expiredCacheAndExplicitClearFetchAgain() async throws {
        let fixture = CredentialLoaderFixture()
        var uptime: TimeInterval = 100
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) },
            now: { uptime },
            cacheLifetime: 30
        )
        _ = try await store.loadOpenAIKey()
        uptime += 29
        _ = try await store.loadOpenAIKey()
        #expect(fixture.calls == 1)
        uptime += 1
        _ = try await store.loadOpenAIKey()
        #expect(fixture.calls == 2)
        store.clearCachedKey()
        _ = try await store.loadOpenAIKey()
        #expect(fixture.calls == 3)
    }

    @Test func configurationChangeCannotReusePreviousCredential() async throws {
        let fixture = CredentialLoaderFixture()
        var selectedConfiguration = configuration
        let store = PacePlannerCredentialStore(
            loadConfiguration: { selectedConfiguration },
            loadInfisicalKey: { try await fixture.load($0) }
        )
        _ = try await store.loadOpenAIKey()
        selectedConfiguration = .init(
            projectID: configuration.projectID,
            organizationID: configuration.organizationID,
            environment: "production",
            secretPath: "/other",
            secretName: "OPENAI_API_KEY"
        )
        fixture.value = "sk-different-synthetic-credential-for-tests-only"
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
        #expect(fixture.receivedConfigurations.last == selectedConfiguration)
    }

    @Test func simultaneousCallersShareFetchAndOneCancellationDoesNotCancelTheOther() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.pause = true
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) }
        )
        let first = Task { try await store.loadOpenAIKey() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await store.loadOpenAIKey()
        }
        try await waitUntil { fixture.calls == 1 && secondStarted }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(fixture.pause)
        fixture.pause = false
        #expect(try await second.value == fixture.value)
        #expect(fixture.calls == 1)
        #expect(fixture.cancellationCount == 0)
        _ = try await store.loadOpenAIKey()
        #expect(fixture.calls == 1)
    }

    @Test func lastCancelledCallerStopsFetchAndNeverCachesItsResult() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.pause = true
        let store = PacePlannerCredentialStore(
            loadConfiguration: { configuration },
            loadInfisicalKey: { try await fixture.load($0) }
        )
        let request = Task { try await store.loadOpenAIKey() }
        try await waitUntil { fixture.calls == 1 }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        try await waitUntil { fixture.cancellationCount == 1 }
        #expect(fixture.cancellationCount == 1)
        fixture.pause = false
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
    }

    @Test func configurationChangeDuringFetchRejectsTheOldResult() async throws {
        let fixture = CredentialLoaderFixture()
        fixture.pause = true
        var selectedConfiguration = configuration
        let store = PacePlannerCredentialStore(
            loadConfiguration: { selectedConfiguration },
            loadInfisicalKey: { try await fixture.load($0) }
        )
        let first = Task { try await store.loadOpenAIKey() }
        try await waitUntil { fixture.calls == 1 }
        selectedConfiguration = .init(
            projectID: configuration.projectID,
            organizationID: configuration.organizationID,
            environment: "production",
            secretPath: "/other",
            secretName: "OPENAI_API_KEY"
        )
        fixture.pause = false
        await #expect(throws: PacePlannerCredentialError.self) { try await first.value }
        #expect(try await store.loadOpenAIKey() == fixture.value)
        #expect(fixture.calls == 2)
    }

    @Test func malformedExplicitConfigurationNeverTouchesKeychain() async throws {
        var keychainCalls = 0
        let store = PacePlannerCredentialStore(
            loadConfiguration: { throw PacePlannerCredentialError.invalidConfiguration },
            loadKeychain: {
                keychainCalls += 1
                return "wrong-source"
            }
        )
        await #expect(throws: PacePlannerCredentialError.self) { try await store.loadOpenAIKey() }
        #expect(keychainCalls == 0)
    }

    @Test func defaultsContainOnlyValidatedMetadataAndUnknownValuesFailClosed() throws {
        let suiteName = "PaceCredentialTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(try PaceInfisicalCredentialConfiguration.load(defaults: defaults) == nil)
        let valid: [String: Any] = [
            "projectID": configuration.projectID, "organizationID": configuration.organizationID,
            "environment": "dev", "secretPath": "/pace",
        ]
        defaults.set(valid, forKey: PaceInfisicalCredentialConfiguration.defaultsKey)
        #expect(try PaceInfisicalCredentialConfiguration.load(defaults: defaults) == configuration)
        for invalid in [
            valid.merging(["environment": 1]) { _, new in new },
            valid.merging(["secretPath": "/pace;echo nope"]) { _, new in new },
            valid.merging(["projectID": "--help"]) { _, new in new },
            valid.merging(["apiKey": "synthetic-value"]) { _, new in new },
        ] {
            defaults.set(invalid, forKey: PaceInfisicalCredentialConfiguration.defaultsKey)
            #expect(throws: PacePlannerCredentialError.self) {
                try PaceInfisicalCredentialConfiguration.load(defaults: defaults)
            }
        }
    }

    @Test func realProcessReturnsSyntheticKeyWithoutFilesOrStderrExposure() async throws {
        let key = "sk-synthetic-credential-for-automated-tests-only"
        let value = try await PaceInfisicalCredentialProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import sys; sys.stderr.write('never return this private diagnostic'); print('\(key)')",
            ]
        )
        #expect(value == key)
        do {
            _ = try await PaceInfisicalCredentialProcess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [
                    "-c",
                    "import sys; sys.stderr.write('never return this private diagnostic'); sys.exit(2)",
                ]
            )
            Issue.record("Expected sanitized failure")
        } catch {
            #expect(error is PacePlannerCredentialError)
            #expect(!error.localizedDescription.contains("private diagnostic"))
        }
    }

    @Test func oversizedOrInvalidStdoutIsRejectedBeforeAcceptance() async throws {
        for script in ["print('sk-' + 'a' * 20000)", "print('not-an-api-key')"] {
            await #expect(throws: PacePlannerCredentialError.self) {
                try await PaceInfisicalCredentialProcess.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-c", script]
                )
            }
        }
    }

    @Test func realStalledProcessTimesOutAndCancellationReturnsControl() async throws {
        let startedAt = ContinuousClock.now
        await #expect(throws: PacePlannerCredentialError.self) {
            try await PaceInfisicalCredentialProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 0.1
            )
        }
        #expect(startedAt.duration(to: .now) < .seconds(3))
        let request = Task {
            try await PaceInfisicalCredentialProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 30
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
    }
}
