//
//  PaceFlowStoreTests.swift
//  leanring-buddyTests
//
//  Pins the persistence contract for the JSON-backed flow store.
//  Every assertion here drives an injected `directoryURL` so the tests
//  never touch the user's real `Application Support/Pace/flows`
//  directory; that means a developer running the test suite locally
//  can't accidentally clobber a saved flow.
//
//  The store is intentionally Codable round-trippable because
//  `PaceRecipeLibrary.install(...)` writes recipe JSON through the
//  exact same code path. Drift between this test and the bundled
//  recipe schema would break recipe install in production.
//

import XCTest
@testable import Pace

final class PaceFlowStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-flow-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        super.tearDown()
    }

    // MARK: - Round-trip

    func testSaveAndLoadRoundTripsAllFields() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let originalFlow = PaceRecordedFlow(
            name: "Compose mail draft",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: [
                .activateApp(bundleIdentifier: "com.apple.mail"),
                .keyShortcut(key: "cmd+n"),
                .typeText(text: "Quarterly update", secure: false),
                .axPress(rolePath: ["AXWindow", "AXButton"], label: "Send"),
            ]
        )

        try store.save(originalFlow)

        let loadedFlow = try XCTUnwrap(store.load(named: originalFlow.name))
        XCTAssertEqual(loadedFlow.name, originalFlow.name)
        XCTAssertEqual(loadedFlow.steps.count, originalFlow.steps.count)
        XCTAssertEqual(loadedFlow.createdAt.timeIntervalSince1970,
                       originalFlow.createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(loadedFlow.steps, originalFlow.steps)
    }

    func testSecureTypeTextIsRedactedOnDisk() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let flowWithSecret = PaceRecordedFlow(
            name: "login flow",
            createdAt: Date(),
            steps: [
                .typeText(text: "super-secret-passphrase", secure: true),
            ]
        )

        try store.save(flowWithSecret)

        let rawJSONOnDisk = try String(
            contentsOf: temporaryDirectoryURL.appendingPathComponent("login-flow.json"),
            encoding: .utf8
        )
        XCTAssertFalse(rawJSONOnDisk.contains("super-secret-passphrase"))
        XCTAssertTrue(rawJSONOnDisk.contains("<password redacted>"))
    }

    // MARK: - Slug normalization

    func testSlugForSimpleName() {
        XCTAssertEqual(PaceFlowStore.slug(for: "morning standup"), "morning-standup")
    }

    func testSlugCollapsesPunctuationAndMultipleSpaces() {
        XCTAssertEqual(
            PaceFlowStore.slug(for: "  Hello, World!! — flow??  "),
            "hello-world-flow"
        )
    }

    func testSlugCapsAtMaximumLength() {
        let longName = String(repeating: "abc-", count: 64) // 256 chars
        let slug = PaceFlowStore.slug(for: longName)
        XCTAssertLessThanOrEqual(slug.count, PaceFlowStore.maximumSlugLength)
        XCTAssertFalse(slug.hasPrefix("-"))
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func testSlugFallbackForEmptyName() {
        XCTAssertEqual(PaceFlowStore.slug(for: ""), "flow")
        XCTAssertEqual(PaceFlowStore.slug(for: "   "), "flow")
        XCTAssertEqual(PaceFlowStore.slug(for: "???"), "flow")
    }

    func testSlugIsCaseInsensitive() {
        XCTAssertEqual(PaceFlowStore.slug(for: "Morning Standup"), "morning-standup")
        XCTAssertEqual(PaceFlowStore.slug(for: "MORNING STANDUP"), "morning-standup")
    }

    // MARK: - Rename

    func testRenameMovesFlowToNewSlugFile() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let originalFlow = PaceRecordedFlow(
            name: "old name",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: [.keyShortcut(key: "cmd+s")]
        )
        try store.save(originalFlow)

        try store.rename("old name", to: "new name")

        XCTAssertNil(store.load(named: "old name"))
        let renamedFlow = try XCTUnwrap(store.load(named: "new name"))
        XCTAssertEqual(renamedFlow.name, "new name")
        XCTAssertEqual(renamedFlow.steps, originalFlow.steps)
        // createdAt is preserved across renames.
        XCTAssertEqual(
            renamedFlow.createdAt.timeIntervalSince1970,
            originalFlow.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        let oldFileExists = FileManager.default.fileExists(
            atPath: temporaryDirectoryURL.appendingPathComponent("old-name.json").path
        )
        let newFileExists = FileManager.default.fileExists(
            atPath: temporaryDirectoryURL.appendingPathComponent("new-name.json").path
        )
        XCTAssertFalse(oldFileExists)
        XCTAssertTrue(newFileExists)
    }

    func testRenameToSameSlugIsNoOp() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        try store.save(PaceRecordedFlow(
            name: "morning standup",
            createdAt: Date(),
            steps: [.keyShortcut(key: "cmd+s")]
        ))

        // "Morning Standup" and "morning standup" slug to the same
        // filename, so the rename should succeed (overwriting the
        // same file) instead of raising destinationFlowAlreadyExists.
        XCTAssertNoThrow(try store.rename("morning standup", to: "Morning Standup"))
        XCTAssertNotNil(store.load(named: "Morning Standup"))
    }

    func testRenameMissingSourceThrows() {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        XCTAssertThrowsError(try store.rename("does not exist", to: "anything")) { error in
            XCTAssertEqual(error as? PaceFlowStoreError, .sourceFlowNotFound("does not exist"))
        }
    }

    func testRenameToExistingDestinationThrows() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        try store.save(PaceRecordedFlow(name: "alpha", createdAt: Date(), steps: []))
        try store.save(PaceRecordedFlow(name: "beta", createdAt: Date(), steps: []))

        XCTAssertThrowsError(try store.rename("alpha", to: "beta")) { error in
            XCTAssertEqual(
                error as? PaceFlowStoreError,
                .destinationFlowAlreadyExists("beta")
            )
        }
    }

    // MARK: - Delete

    func testDeleteRemovesTheFile() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        try store.save(PaceRecordedFlow(
            name: "doomed",
            createdAt: Date(),
            steps: [.keyShortcut(key: "cmd+w")]
        ))
        XCTAssertNotNil(store.load(named: "doomed"))

        try store.delete(named: "doomed")
        XCTAssertNil(store.load(named: "doomed"))
        let fileExists = FileManager.default.fileExists(
            atPath: temporaryDirectoryURL.appendingPathComponent("doomed.json").path
        )
        XCTAssertFalse(fileExists)
    }

    func testDeleteUnknownFlowIsNoOp() {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        XCTAssertNoThrow(try store.delete(named: "never existed"))
    }

    // MARK: - listAll ordering

    func testListAllReturnsSortedByCreatedAtDescending() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        try store.save(PaceRecordedFlow(
            name: "oldest",
            createdAt: Date(timeIntervalSince1970: 1_000_000_000),
            steps: []
        ))
        try store.save(PaceRecordedFlow(
            name: "middle",
            createdAt: Date(timeIntervalSince1970: 1_500_000_000),
            steps: []
        ))
        try store.save(PaceRecordedFlow(
            name: "newest",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: []
        ))

        let listedFlows = store.listAll()
        XCTAssertEqual(listedFlows.map(\.name), ["newest", "middle", "oldest"])
    }

    func testListAllSkipsMalformedJSON() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        try store.save(PaceRecordedFlow(
            name: "valid",
            createdAt: Date(),
            steps: []
        ))
        // Drop a malformed JSON file into the store directory. listAll
        // should silently skip it instead of crashing.
        let malformedFileURL = temporaryDirectoryURL.appendingPathComponent("broken.json")
        try "{ not really json".write(to: malformedFileURL, atomically: true, encoding: .utf8)

        let listedFlows = store.listAll()
        XCTAssertEqual(listedFlows.map(\.name), ["valid"])
    }

    // MARK: - Atomic write

    func testSaveOverwritesAtomicallyWithoutLeavingTempFiles() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        try store.save(PaceRecordedFlow(
            name: "version one",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: [.keyShortcut(key: "cmd+s")]
        ))
        try store.save(PaceRecordedFlow(
            name: "version one",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            steps: [.keyShortcut(key: "cmd+s"), .keyShortcut(key: "cmd+w")]
        ))

        let reloadedFlow = try XCTUnwrap(store.load(named: "version one"))
        XCTAssertEqual(reloadedFlow.steps.count, 2)

        // No `*.pace.tmp.*` leftovers in the directory.
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let temporaryFileURLs = directoryContents.filter { $0.lastPathComponent.contains(".pace.tmp.") }
        XCTAssertTrue(temporaryFileURLs.isEmpty)
    }

    // MARK: - Legacy migration

    func testMigrateLegacyUserDefaultsFlowsConsumesAndDeletesTheKey() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let userDefaults = UserDefaults(suiteName: "pace.test.\(UUID().uuidString)")!
        defer {
            userDefaults.removeObject(forKey: PaceFlowStore.legacyUserDefaultsKey)
        }

        let legacyFlows = [
            PaceRecordedFlow(name: "legacy a", createdAt: Date(), steps: []),
            PaceRecordedFlow(name: "legacy b", createdAt: Date(), steps: []),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedLegacySnapshot = try encoder.encode(legacyFlows)
        userDefaults.set(encodedLegacySnapshot, forKey: PaceFlowStore.legacyUserDefaultsKey)

        let migratedCount = store.migrateLegacyUserDefaultsFlowsIfNeeded(userDefaults: userDefaults)

        XCTAssertEqual(migratedCount, 2)
        XCTAssertNotNil(store.load(named: "legacy a"))
        XCTAssertNotNil(store.load(named: "legacy b"))
        XCTAssertNil(userDefaults.data(forKey: PaceFlowStore.legacyUserDefaultsKey))
    }

    func testMigrateLegacyUserDefaultsWithNothingToMigrateIsZero() {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let userDefaults = UserDefaults(suiteName: "pace.test.empty.\(UUID().uuidString)")!
        let migratedCount = store.migrateLegacyUserDefaultsFlowsIfNeeded(userDefaults: userDefaults)
        XCTAssertEqual(migratedCount, 0)
    }
}
