//
//  PaceStarterPromptStoreTests.swift
//  leanring-buddyTests
//
//  Pure tests for the first-run "Try these" starter-prompt state. The
//  store reads/writes UserDefaults.standard, so this suite saves+restores
//  the three keys it touches around each test and runs serially so
//  concurrent writes never race. Same pattern as PacePlannerTierStoreTests.
//

import Foundation
import Testing

@testable import Pace

@Suite(.serialized)
struct PaceStarterPromptStoreTests {

    /// The full set of UserDefaults keys the store touches. Must mirror
    /// the private `StarterPromptUserDefaultsKey` enum — if a new key
    /// gets added there, add it here so save/restore stays leak-free.
    private static let allStarterPromptUserDefaultsKeys: [String] = [
        "pace.firstRun.starterPromptsTriedAt",
        "pace.firstRun.starterPromptsFirstSeenAt",
        "pace.firstRun.starterPromptsDismissedAt"
    ]

    /// Saves+clears the keys before the test, restores them after. Keeps
    /// the production UserDefaults free of leaked test state.
    private func withClearedAndRestoredStarterPromptState<R>(
        _ body: () throws -> R
    ) rethrows -> R {
        var savedValuesByKey: [String: Any] = [:]
        for keyName in Self.allStarterPromptUserDefaultsKeys {
            if let savedValue = UserDefaults.standard.object(forKey: keyName) {
                savedValuesByKey[keyName] = savedValue
            }
            UserDefaults.standard.removeObject(forKey: keyName)
        }
        defer {
            for keyName in Self.allStarterPromptUserDefaultsKeys {
                if let savedValue = savedValuesByKey[keyName] {
                    UserDefaults.standard.set(savedValue, forKey: keyName)
                } else {
                    UserDefaults.standard.removeObject(forKey: keyName)
                }
            }
        }
        return try body()
    }

    // MARK: - Catalog shape

    @Test
    func catalogContainsExactlySixPrompts() {
        #expect(PaceStarterPromptCatalog.all.count == 6)
    }

    @Test
    func catalogSlugsAreUnique() {
        let allSlugs = PaceStarterPromptCatalog.all.map { $0.slug }
        let uniqueSlugs = Set(allSlugs)
        #expect(allSlugs.count == uniqueSlugs.count)
    }

    @Test
    func catalogPromptsAllHaveNonEmptyDisplayText() {
        for starterPrompt in PaceStarterPromptCatalog.all {
            #expect(!starterPrompt.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test
    func catalogLookupByExistingSlugReturnsPrompt() {
        #expect(PaceStarterPromptCatalog.prompt(forSlug: "calendar-today") != nil)
    }

    @Test
    func catalogLookupByMissingSlugReturnsNil() {
        #expect(PaceStarterPromptCatalog.prompt(forSlug: "not-a-real-slug") == nil)
    }

    // MARK: - First-seen bookkeeping

    @Test
    func firstSeenStartsUnsetOnFreshStore() {
        withClearedAndRestoredStarterPromptState {
            #expect(PaceStarterPromptStore.firstSeenAt() == nil)
        }
    }

    @Test
    func markFirstSeenIsIdempotent() {
        withClearedAndRestoredStarterPromptState {
            let firstCallTime = Date(timeIntervalSince1970: 1_000_000)
            PaceStarterPromptStore.markFirstSeenIfNeeded(now: firstCallTime)
            let secondCallTime = Date(timeIntervalSince1970: 2_000_000)
            PaceStarterPromptStore.markFirstSeenIfNeeded(now: secondCallTime)
            let storedFirstSeen = PaceStarterPromptStore.firstSeenAt()
            #expect(storedFirstSeen?.timeIntervalSince1970 == firstCallTime.timeIntervalSince1970)
        }
    }

    // MARK: - Tried-set bookkeeping

    @Test
    func markTriedPersistsForExistingSlug() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markTried(slug: "calendar-today")
            #expect(PaceStarterPromptStore.hasTried(slug: "calendar-today"))
            #expect(PaceStarterPromptStore.triedCount() == 1)
        }
    }

    @Test
    func markTriedIgnoresUnknownSlug() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markTried(slug: "totally-fake")
            #expect(PaceStarterPromptStore.triedCount() == 0)
        }
    }

    @Test
    func triedCountReflectsDistinctSlugsTried() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markTried(slug: "calendar-today")
            PaceStarterPromptStore.markTried(slug: "set-five-minute-timer")
            // Repeat tap on the same slug must not double-count.
            PaceStarterPromptStore.markTried(slug: "calendar-today")
            #expect(PaceStarterPromptStore.triedCount() == 2)
        }
    }

    @Test
    func triedAtTimestampsFilterOutUnknownSlugsFromPersistedDictionary() {
        withClearedAndRestoredStarterPromptState {
            // Simulate a stale persisted dictionary that has a slug no
            // longer in the catalog (e.g. removed in a release). The
            // store must silently drop it.
            UserDefaults.standard.set(
                ["calendar-today": Date().timeIntervalSince1970,
                 "obsolete-slug": Date().timeIntervalSince1970],
                forKey: "pace.firstRun.starterPromptsTriedAt"
            )
            let resolvedTimestamps = PaceStarterPromptStore.triedAtTimestampsBySlug()
            #expect(resolvedTimestamps.keys.contains("calendar-today"))
            #expect(!resolvedTimestamps.keys.contains("obsolete-slug"))
        }
    }

    // MARK: - Visibility decision

    @Test
    func isVisibleReturnsTrueOnAbsolutelyFreshState() {
        withClearedAndRestoredStarterPromptState {
            #expect(PaceStarterPromptStore.isVisible(now: Date()))
        }
    }

    @Test
    func isVisibleReturnsFalseAfterDismissal() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markDismissed()
            #expect(!PaceStarterPromptStore.isVisible(now: Date()))
        }
    }

    @Test
    func isVisibleReturnsFalseAfterFourPromptsTried() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markTried(slug: "calendar-today")
            PaceStarterPromptStore.markTried(slug: "set-five-minute-timer")
            PaceStarterPromptStore.markTried(slug: "open-safari-anthropic")
            PaceStarterPromptStore.markTried(slug: "what-is-on-screen")
            #expect(!PaceStarterPromptStore.isVisible(now: Date()))
        }
    }

    @Test
    func isVisibleStaysTrueAfterThreePromptsTried() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markTried(slug: "calendar-today")
            PaceStarterPromptStore.markTried(slug: "set-five-minute-timer")
            PaceStarterPromptStore.markTried(slug: "open-safari-anthropic")
            #expect(PaceStarterPromptStore.isVisible(now: Date()))
        }
    }

    @Test
    func isVisibleReturnsFalseAfterTwentyFourHourWindowExpires() {
        withClearedAndRestoredStarterPromptState {
            let firstSeenTime = Date(timeIntervalSince1970: 1_700_000_000)
            PaceStarterPromptStore.markFirstSeenIfNeeded(now: firstSeenTime)
            let oneSecondPastTheWindow = firstSeenTime.addingTimeInterval(24 * 60 * 60 + 1)
            #expect(!PaceStarterPromptStore.isVisible(now: oneSecondPastTheWindow))
        }
    }

    @Test
    func isVisibleStaysTrueWithinTwentyFourHourWindow() {
        withClearedAndRestoredStarterPromptState {
            let firstSeenTime = Date(timeIntervalSince1970: 1_700_000_000)
            PaceStarterPromptStore.markFirstSeenIfNeeded(now: firstSeenTime)
            let oneMinuteIntoTheWindow = firstSeenTime.addingTimeInterval(60)
            #expect(PaceStarterPromptStore.isVisible(now: oneMinuteIntoTheWindow))
        }
    }

    @Test
    func resetVisibilityClearsFirstSeenAndDismissedButKeepsTriedSet() {
        withClearedAndRestoredStarterPromptState {
            PaceStarterPromptStore.markTried(slug: "calendar-today")
            PaceStarterPromptStore.markFirstSeenIfNeeded()
            PaceStarterPromptStore.markDismissed()
            PaceStarterPromptStore.resetVisibility()
            #expect(PaceStarterPromptStore.firstSeenAt() == nil)
            #expect(PaceStarterPromptStore.dismissedAt() == nil)
            #expect(PaceStarterPromptStore.hasTried(slug: "calendar-today"))
            #expect(PaceStarterPromptStore.isVisible(now: Date()))
        }
    }
}
