//
//  PaceSpotlightMemoryIndexer.swift
//  leanring-buddy
//
//  Mirrors active `PaceMemoryEntry` values into the system's
//  CoreSpotlight index so users can find their Pace memories from
//  Spotlight (Cmd+Space) and from any other Spotlight-backed
//  surface — Mail's smart suggestions, Notes' search, etc.
//
//  Strictly a one-way MIRROR. PaceMemoryStore stays the source of
//  truth; this indexer never reads from Spotlight and never round-
//  trips data through it. Spotlight gets the same content the user
//  has already stored on this Mac, with the same on-device posture
//  as the rest of the app. Passive screen history is excluded. A
//  one-time upgrade purge removes legacy replicas from Pace's own
//  domain before allowed memories are mirrored again.
//
//  Failure posture: best-effort. CoreSpotlight is unavailable in
//  unsigned dev bundles, sandboxed CI, and a handful of corner
//  cases; any failure logs once and skips. A missing Spotlight
//  mirror never blocks a real user turn.
//

import CoreSpotlight
import Foundation

@MainActor
final class PaceSpotlightMemoryIndexer {

    typealias Completion = @MainActor (Error?) -> Void
    typealias IndexOperation = ([CSSearchableItem], @escaping Completion) -> Void
    typealias DeleteDomainOperation = ([String], @escaping Completion) -> Void

    private let spotlightDomainIdentifier = "com.pace.app.memory"
    private let indexOperation: IndexOperation
    private let deleteDomainOperation: DeleteDomainOperation
    private let markLegacyCleanupComplete: () -> Void
    private var legacyCleanupIsComplete: Bool
    private var cleanupIsRequired = false
    private var isOperationInFlight = false
    private var pendingMirrorEntries: [PaceMemoryEntry]?
    private var hasReportedCleanupFailure = false

    init(spotlightIndex: CSSearchableIndex = .default(),
         indexOperation: IndexOperation? = nil,
         deleteDomainOperation: DeleteDomainOperation? = nil,
         hasCompletedLegacyCleanup: () -> Bool = {
             UserDefaults.standard.bool(forKey: "PaceSpotlightScreenHistoryCleanupV1")
         },
         markLegacyCleanupComplete: @escaping () -> Void = {
             UserDefaults.standard.set(true, forKey: "PaceSpotlightScreenHistoryCleanupV1")
         }) {
        self.indexOperation = indexOperation ?? { items, completion in
            spotlightIndex.indexSearchableItems(items) { error in
                Task { @MainActor in completion(error) }
            }
        }
        self.deleteDomainOperation = deleteDomainOperation ?? { identifiers, completion in
            spotlightIndex.deleteSearchableItems(withDomainIdentifiers: identifiers) { error in
                Task { @MainActor in completion(error) }
            }
        }
        self.legacyCleanupIsComplete = hasCompletedLegacyCleanup()
        self.markLegacyCleanupComplete = markLegacyCleanupComplete
    }

    func prepareMirrorAfterUpgrade(toMatch activeEntries: [PaceMemoryEntry]) {
        if !legacyCleanupIsComplete { cleanupIsRequired = true }
        syncMirror(toMatch: activeEntries)
    }

    func syncMirror(toMatch activeEntries: [PaceMemoryEntry]) {
        pendingMirrorEntries = activeEntries
        performNextOperationIfAvailable()
    }

    private func performNextOperationIfAvailable() {
        guard !isOperationInFlight else { return }
        if cleanupIsRequired {
            isOperationInFlight = true
            // Await every prior index completion before purging. Otherwise a
            // late Spotlight write could restore a replica after its deletion.
            deleteDomainOperation([spotlightDomainIdentifier]) { [weak self] error in
                guard let self else { return }
                isOperationInFlight = false
                guard error == nil else {
                    if !hasReportedCleanupFailure {
                        print("⚠️ Spotlight legacy screen-history cleanup failed; awaiting retry.")
                        hasReportedCleanupFailure = true
                    }
                    return
                }
                cleanupIsRequired = false
                legacyCleanupIsComplete = true
                hasReportedCleanupFailure = false
                markLegacyCleanupComplete()
                performNextOperationIfAvailable()
            }
            return
        }
        guard let pendingMirrorEntries else { return }
        self.pendingMirrorEntries = nil
        let searchableItems = Self.buildSearchableItems(fromActiveEntries: pendingMirrorEntries,
            domainIdentifier: spotlightDomainIdentifier)
        guard !searchableItems.isEmpty else { return }
        isOperationInFlight = true
        indexOperation(searchableItems) { [weak self] error in
            guard let self else { return }
            isOperationInFlight = false
            if error != nil { print("⚠️ Spotlight memory mirror failed.") }
            performNextOperationIfAvailable()
        }
    }

    // MARK: - Pure mapping helpers

    /// Build the searchable-item list from a flat entry list. Pure
    /// helper so the mapping rules — what becomes the title, which
    /// entries get skipped, how the kind label renders — are
    /// unit-testable without a live CSSearchableIndex.
    nonisolated static func buildSearchableItems(
        fromActiveEntries entries: [PaceMemoryEntry],
        domainIdentifier: String
    ) -> [CSSearchableItem] {
        return entries.compactMap { entry in
            guard entry.isActive, entry.source != .screenWatchHistory else { return nil }
            return buildSearchableItem(forEntry: entry, domainIdentifier: domainIdentifier)
        }
    }

    /// Single-entry mapping. Returns nil when the entry has no
    /// indexable text (we never index an empty record — Spotlight
    /// would surface a blank row).
    nonisolated static func buildSearchableItem(
        forEntry entry: PaceMemoryEntry,
        domainIdentifier: String
    ) -> CSSearchableItem? {
        let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        // Title is a short prefix the Spotlight result row will show
        // first. Bounded so a long entry doesn't push everything else
        // out of the row.
        attributeSet.title = String(trimmedText.prefix(60))
        attributeSet.contentDescription = trimmedText
        attributeSet.contentCreationDate = entry.createdAt
        attributeSet.contentModificationDate = entry.updatedAt
        attributeSet.keywords = ["pace", entry.kind.rawValue] + entry.topicTags
        attributeSet.subject = "Pace memory — \(humanReadableKindLabel(forKind: entry.kind))"

        return CSSearchableItem(
            uniqueIdentifier: entry.id,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
    }

    nonisolated static func humanReadableKindLabel(forKind kind: PaceMemoryEntryKind) -> String {
        switch kind {
        case .conversationTurn: return "conversation"
        case .fact:             return "fact"
        case .preference:       return "preference"
        case .journalEvent:     return "journal event"
        case .summary:          return "summary"
        }
    }
}
