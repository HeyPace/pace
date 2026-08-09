//
//  PaceShortcutsAutomationProviderTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceShortcutsAutomationProviderTests {
    @Test func parserRecognizesBoundedExplicitShortcutCommands() {
        #expect(PaceShortcutCommandParser.parse("List my shortcuts") == .list)
        #expect(PaceShortcutCommandParser.parse("what shortcuts do I have?") == .list)
        #expect(PaceShortcutCommandParser.parse("run shortcut Morning Routine") == .run(
            requestedShortcutName: "Morning Routine"
        ))
        #expect(PaceShortcutCommandParser.parse("run my Morning Routine shortcut") == .run(
            requestedShortcutName: "Morning Routine"
        ))
        #expect(PaceShortcutCommandParser.parse("execute the Ship Pace shortcut.") == .run(
            requestedShortcutName: "Ship Pace"
        ))
    }

    @Test func parserLeavesAmbiguousCommandsForExistingRouting() {
        #expect(PaceShortcutCommandParser.parse("run Morning Routine") == nil)
        #expect(PaceShortcutCommandParser.parse("start the timer") == nil)
        #expect(PaceShortcutCommandParser.parse("open Shortcuts") == nil)
        #expect(PaceShortcutCommandParser.parse("what shortcuts can I use in Xcode") == nil)
    }

    @Test func catalogTrimsSortsDeduplicatesAndMatchesExactNormalizedNames() {
        let catalog = PaceShortcutAutomationCatalog.fromListOutput("""

          Ship Pace
        morning brief
        Mórning   Brief
        Open Raycast

        """)

        #expect(catalog.shortcutNames == ["morning brief", "Open Raycast", "Ship Pace"])
        #expect(catalog.exactDisplayName(matching: "  MORNING   BRIEF ") == "morning brief")
        #expect(catalog.exactDisplayName(matching: "Mórning Brief") == "morning brief")
        #expect(catalog.exactDisplayName(matching: "Morning") == nil)
    }

    @Test func blankSuccessfulListProducesAnEmptyCatalog() {
        let catalog = PaceShortcutAutomationCatalog.fromListOutput("\n  \n")

        #expect(catalog.shortcutNames.isEmpty)
        #expect(catalog.exactDisplayName(matching: "Anything") == nil)
    }

    @Test func providerCachesOnlySuccessfulCatalogsForTheConfiguredDuration() async {
        final class LoaderState {
            var loadCount = 0
        }

        let loaderState = LoaderState()
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = PaceShortcutsAutomationProvider(
            successfulCatalogCacheDuration: 300,
            currentDateProvider: { currentDate },
            catalogLoader: {
                loaderState.loadCount += 1
                return .success(PaceShortcutAutomationCatalog(shortcutNames: ["Morning Brief"]))
            }
        )

        _ = await provider.catalog()
        currentDate = currentDate.addingTimeInterval(299)
        _ = await provider.catalog()
        #expect(loaderState.loadCount == 1)

        currentDate = currentDate.addingTimeInterval(2)
        _ = await provider.catalog()
        #expect(loaderState.loadCount == 2)
    }

    @Test func providerDoesNotCacheDiscoveryFailures() async {
        final class LoaderState {
            var loadCount = 0
        }

        let loaderState = LoaderState()
        let provider = PaceShortcutsAutomationProvider(
            catalogLoader: {
                loaderState.loadCount += 1
                return .failure("Shortcuts unavailable")
            }
        )

        #expect(await provider.catalog() == .failure("Shortcuts unavailable"))
        #expect(await provider.catalog() == .failure("Shortcuts unavailable"))
        #expect(loaderState.loadCount == 2)
    }

    @Test func matchedShortcutBuildsTheExistingTypedRunShortcutPlan() {
        let fastActionParseResult = PaceShortcutCommandParser.fastActionParseResult(
            for: "Morning Routine"
        )

        #expect(fastActionParseResult.spokenText == "running Morning Routine.")
        #expect(fastActionParseResult.executionPlan.flattenedActions.count == 1)
        guard case .runShortcut(let shortcutName) = fastActionParseResult.executionPlan.flattenedActions[0] else {
            Issue.record("Expected the deterministic route to reuse .runShortcut")
            return
        }
        #expect(shortcutName == "Morning Routine")
    }
}
