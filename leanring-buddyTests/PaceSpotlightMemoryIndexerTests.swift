//
//  PaceSpotlightMemoryIndexerTests.swift
//  leanring-buddyTests
//
//  Pure mapping and fake-operation tests for the Spotlight memory mirror.
//  No test mutates the system search index.
//

import CoreSpotlight
import Foundation
import Testing
@testable import Pace

struct PaceSpotlightMemoryIndexerTests {

    @Test func builtItemHasEntryIDAsUniqueIdentifier() async throws {
        let entry = makeEntry(id: "mem-001", text: "remembered something")
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        #expect(item.uniqueIdentifier == "mem-001")
        #expect(item.domainIdentifier == "com.pace.app.memory")
    }

    @Test func builtItemTitleIsBoundedPrefixOfText() async throws {
        // Long text would otherwise push every other column off the
        // Spotlight result row. Verify the bound holds.
        let veryLongText = String(repeating: "a", count: 200)
        let entry = makeEntry(id: "mem-002", text: veryLongText)
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        #expect(item.attributeSet.title?.count == 60)
    }

    @Test func builtItemContentDescriptionIsFullText() async throws {
        let entry = makeEntry(
            id: "mem-003",
            text: "user prefers Firefox as their default browser"
        )
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        #expect(item.attributeSet.contentDescription == entry.text)
    }

    @Test func builtItemKeywordsIncludePaceTokenAndKindAndTopicTags() async throws {
        let entry = makeEntry(
            id: "mem-004",
            text: "the team finalised the spec on march 5th",
            kind: .fact,
            topicTags: ["product", "spec"]
        )
        guard let item = PaceSpotlightMemoryIndexer.buildSearchableItem(
            forEntry: entry,
            domainIdentifier: "com.pace.app.memory"
        ) else {
            Issue.record("Expected mapping to produce an item")
            return
        }
        let keywords = item.attributeSet.keywords ?? []
        #expect(keywords.contains("pace"))
        #expect(keywords.contains("fact"))
        #expect(keywords.contains("product"))
        #expect(keywords.contains("spec"))
    }

    @Test func mappingDropsEntriesWithEmptyText() async throws {
        // Spotlight would otherwise render a blank result row.
        let blankEntry = makeEntry(id: "mem-005", text: "")
        let whitespaceEntry = makeEntry(id: "mem-006", text: "   \n\t  ")
        #expect(
            PaceSpotlightMemoryIndexer.buildSearchableItem(
                forEntry: blankEntry,
                domainIdentifier: "com.pace.app.memory"
            ) == nil
        )
        #expect(
            PaceSpotlightMemoryIndexer.buildSearchableItem(
                forEntry: whitespaceEntry,
                domainIdentifier: "com.pace.app.memory"
            ) == nil
        )
    }

    @Test func bulkBuildSkipsTombstonedEntries() async throws {
        // Tombstoned entries are still in the persistence file (so we
        // honour the 30-day retention window for recovery), but they
        // must NOT show up in Spotlight.
        let active = makeEntry(id: "mem-007", text: "still around")
        var tombstoned = makeEntry(id: "mem-008", text: "deleted ages ago")
        tombstoned.tombstonedAt = Date()

        let items = PaceSpotlightMemoryIndexer.buildSearchableItems(
            fromActiveEntries: [active, tombstoned],
            domainIdentifier: "com.pace.app.memory"
        )
        #expect(items.count == 1)
        #expect(items.first?.uniqueIdentifier == "mem-007")
    }

    @Test func humanKindLabelIsStableAcrossKinds() async throws {
        // Pin the labels so a future kind rename doesn't silently
        // change what users see in the Spotlight result subject line.
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .conversationTurn) == "conversation")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .fact) == "fact")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .preference) == "preference")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .journalEvent) == "journal event")
        #expect(PaceSpotlightMemoryIndexer.humanReadableKindLabel(forKind: .summary) == "summary")
    }

    @MainActor private final class FakeIndex {
        var operations: [String] = []
        var indexCompletion: PaceSpotlightMemoryIndexer.Completion?
        var deleteCompletion: PaceSpotlightMemoryIndexer.Completion?

        func index(_ items: [CSSearchableItem], completion: @escaping PaceSpotlightMemoryIndexer.Completion) {
            operations.append("index:" + items.map(\.uniqueIdentifier).joined(separator: ","))
            indexCompletion = completion
        }

        func deleteDomains(_ identifiers: [String], completion: @escaping PaceSpotlightMemoryIndexer.Completion) {
            operations.append("delete:" + identifiers.joined(separator: ","))
            deleteCompletion = completion
        }

        func finishIndex(error: Error? = nil) {
            let completion = indexCompletion
            indexCompletion = nil
            completion?(error)
        }

        func finishDelete(error: Error? = nil) {
            let completion = deleteCompletion
            deleteCompletion = nil
            completion?(error)
        }
    }

    @MainActor @Test func startupCleanupPurgesOnlyPaceDomainBeforeMirroringLatestAllowedSnapshot() {
        let fakeIndex = FakeIndex()
        var completedMigrations = 0
        let indexer = PaceSpotlightMemoryIndexer(indexOperation: fakeIndex.index,
            deleteDomainOperation: fakeIndex.deleteDomains, hasCompletedLegacyCleanup: { false },
            markLegacyCleanupComplete: { completedMigrations += 1 })
        var screenEntry = makeEntry(id: "private-screen", text: "Observed article text")
        screenEntry.source = .screenWatchHistory
        indexer.prepareMirrorAfterUpgrade(toMatch: [screenEntry, makeEntry(id: "initial", text: "Allowed initial memory")])
        #expect(fakeIndex.operations == ["delete:com.pace.app.memory"])
        #expect(completedMigrations == 0)
        indexer.syncMirror(toMatch: [screenEntry, makeEntry(id: "latest", text: "Allowed latest memory")])
        #expect(fakeIndex.operations.count == 1)
        fakeIndex.finishDelete()
        #expect(completedMigrations == 1)
        #expect(fakeIndex.operations == ["delete:com.pace.app.memory", "index:latest"])
        fakeIndex.finishIndex()
    }

    @MainActor @Test func cleanupWaitsForPendingIndexCompletionSoLateWritesCannotRacePurge() {
        let fakeIndex = FakeIndex()
        let indexer = PaceSpotlightMemoryIndexer(indexOperation: fakeIndex.index,
            deleteDomainOperation: fakeIndex.deleteDomains, hasCompletedLegacyCleanup: { false },
            markLegacyCleanupComplete: {})
        indexer.syncMirror(toMatch: [makeEntry(id: "already-running", text: "Earlier allowed memory")])
        indexer.prepareMirrorAfterUpgrade(toMatch: [makeEntry(id: "startup", text: "Startup allowed memory")])
        indexer.syncMirror(toMatch: [makeEntry(id: "latest", text: "Latest allowed memory")])
        #expect(fakeIndex.operations == ["index:already-running"])
        fakeIndex.finishIndex()
        #expect(fakeIndex.operations == ["index:already-running", "delete:com.pace.app.memory"])
        fakeIndex.finishDelete()
        #expect(fakeIndex.operations == ["index:already-running", "delete:com.pace.app.memory", "index:latest"])
        fakeIndex.finishIndex()
    }

    @MainActor @Test func failedCleanupDoesNotMarkMigrationOrMirrorAheadOfRetry() {
        let fakeIndex = FakeIndex()
        var completedMigrations = 0
        let indexer = PaceSpotlightMemoryIndexer(indexOperation: fakeIndex.index,
            deleteDomainOperation: fakeIndex.deleteDomains, hasCompletedLegacyCleanup: { false },
            markLegacyCleanupComplete: { completedMigrations += 1 })
        indexer.prepareMirrorAfterUpgrade(toMatch: [makeEntry(id: "initial", text: "Allowed initial memory")])
        fakeIndex.finishDelete(error: URLError(.cannotWriteToFile))
        #expect(completedMigrations == 0)
        #expect(fakeIndex.operations == ["delete:com.pace.app.memory"])
        indexer.syncMirror(toMatch: [makeEntry(id: "retry", text: "Allowed retry memory")])
        #expect(fakeIndex.operations == ["delete:com.pace.app.memory", "delete:com.pace.app.memory"])
        fakeIndex.finishDelete()
        #expect(completedMigrations == 1)
        #expect(fakeIndex.operations.last == "index:retry")
        fakeIndex.finishIndex()
    }

    @MainActor @Test func completedMigrationIsNotRepeatedAndIndexFailureDoesNotBlockLaterSync() {
        let fakeIndex = FakeIndex()
        var completedMigrations = 0
        let indexer = PaceSpotlightMemoryIndexer(indexOperation: fakeIndex.index,
            deleteDomainOperation: fakeIndex.deleteDomains, hasCompletedLegacyCleanup: { true },
            markLegacyCleanupComplete: { completedMigrations += 1 })
        indexer.prepareMirrorAfterUpgrade(toMatch: [makeEntry(id: "initial", text: "Allowed initial memory")])
        fakeIndex.finishIndex(error: URLError(.cannotWriteToFile))
        indexer.syncMirror(toMatch: [makeEntry(id: "later", text: "Allowed later memory")])
        #expect(fakeIndex.operations == ["index:initial", "index:later"])
        #expect(completedMigrations == 0)
        fakeIndex.finishIndex()
    }

    // MARK: - Builders

    private func makeEntry(
        id: String,
        text: String,
        kind: PaceMemoryEntryKind = .conversationTurn,
        topicTags: [String] = []
    ) -> PaceMemoryEntry {
        PaceMemoryEntry(
            id: id,
            kind: kind,
            text: text,
            structured: nil,
            source: .paceHistory,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedding: nil,
            confidence: nil,
            topicTags: topicTags,
            tombstonedAt: nil
        )
    }
}
