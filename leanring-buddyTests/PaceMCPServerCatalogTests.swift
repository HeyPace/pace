//
//  PaceMCPServerCatalogTests.swift
//  leanring-buddyTests
//
//  Exercises the atomic JSON-merge installer end-to-end against a
//  temp `mcp-servers.json`. The catalog itself is pure data so the
//  meaningful assertions are: install preserves unrelated entries,
//  uninstall is a clean remove, and the write is atomic enough that
//  a partial file is never left behind.
//

import Foundation
import Testing

@testable import Pace

struct PaceMCPServerCatalogTests {

    // MARK: - Helpers

    /// Returns a fresh, unique URL inside the temp dir for one test.
    private func makeTemporaryConfigFileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-mcp-catalog-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mcp-servers.json")
    }

    private func readMCPServersDictionary(from configFileURL: URL) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: configFileURL)
        let rawDecoded = try JSONSerialization.jsonObject(with: data)
        guard let rootObject = rawDecoded as? [String: Any],
              let mcpServers = rootObject["mcpServers"] as? [String: [String: Any]] else {
            return [:]
        }
        return mcpServers
    }

    // MARK: - Catalog content

    @Test func bundledCatalogIncludesExpectedSlugs() {
        let bundledSlugs = Set(PaceMCPServerCatalog.bundledCatalog.map(\.slug))
        let expectedSlugs: Set<String> = [
            "filesystem", "fetch", "github", "applescript", "slack", "linear"
        ]
        #expect(bundledSlugs == expectedSlugs)
    }

    @Test func everyCatalogEntryHasNonEmptyCommandAndDisplayName() {
        for catalogEntry in PaceMCPServerCatalog.bundledCatalog {
            #expect(!catalogEntry.command.isEmpty)
            #expect(!catalogEntry.displayName.isEmpty)
            #expect(!catalogEntry.description.isEmpty)
        }
    }

    // MARK: - Install creates the file when missing

    @Test func installCreatesConfigFileWhenItDoesNotExist() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        #expect(!FileManager.default.fileExists(atPath: configFileURL.path))

        let filesystemEntry = PaceMCPServerCatalog.entry(forSlug: "filesystem")!
        try PaceMCPCatalogInstaller.install(filesystemEntry, into: configFileURL)

        #expect(FileManager.default.fileExists(atPath: configFileURL.path))
        let installedServers = try readMCPServersDictionary(from: configFileURL)
        #expect(installedServers["filesystem"] != nil)
        #expect(installedServers["filesystem"]?["command"] as? String == "npx")
    }

    // MARK: - Install preserves existing entries

    @Test func installPreservesUserAddedEntries() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        // Seed the config file with a user-added entry the catalog
        // doesn't know about. The installer must NOT clobber it.
        try FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let preExistingJSON = """
        {
          "mcpServers": {
            "user-custom": {
              "command": "/usr/local/bin/my-server",
              "args": ["--keep-me"]
            }
          }
        }
        """
        try preExistingJSON.write(to: configFileURL, atomically: true, encoding: .utf8)

        let fetchEntry = PaceMCPServerCatalog.entry(forSlug: "fetch")!
        try PaceMCPCatalogInstaller.install(fetchEntry, into: configFileURL)

        let mergedServers = try readMCPServersDictionary(from: configFileURL)
        #expect(mergedServers["fetch"] != nil)
        #expect(mergedServers["user-custom"] != nil)
        let userCustomArgs = mergedServers["user-custom"]?["args"] as? [String]
        #expect(userCustomArgs == ["--keep-me"])
    }

    // MARK: - Install is idempotent / overwrites cleanly

    @Test func installOverwritesExistingCatalogEntryWithoutDuplicating() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        let githubEntry = PaceMCPServerCatalog.entry(forSlug: "github")!
        try PaceMCPCatalogInstaller.install(githubEntry, into: configFileURL)
        try PaceMCPCatalogInstaller.install(githubEntry, into: configFileURL)

        let installedServers = try readMCPServersDictionary(from: configFileURL)
        // Map exact equality on dictionary keys
        #expect(installedServers.keys.contains("github"))
        let environment = installedServers["github"]?["env"] as? [String: String] ?? [:]
        #expect(environment["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_replace_me")
    }

    // MARK: - Uninstall

    @Test func uninstallRemovesSpecifiedSlugAndKeepsOthers() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        let filesystemEntry = PaceMCPServerCatalog.entry(forSlug: "filesystem")!
        let fetchEntry = PaceMCPServerCatalog.entry(forSlug: "fetch")!
        try PaceMCPCatalogInstaller.install(filesystemEntry, into: configFileURL)
        try PaceMCPCatalogInstaller.install(fetchEntry, into: configFileURL)

        try PaceMCPCatalogInstaller.uninstall(slug: "filesystem", from: configFileURL)

        let remainingServers = try readMCPServersDictionary(from: configFileURL)
        #expect(remainingServers["filesystem"] == nil)
        #expect(remainingServers["fetch"] != nil)
    }

    @Test func uninstallOnAbsentSlugIsNoOp() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        let fetchEntry = PaceMCPServerCatalog.entry(forSlug: "fetch")!
        try PaceMCPCatalogInstaller.install(fetchEntry, into: configFileURL)

        // Removing a slug that isn't present must succeed without
        // touching the file's other entries.
        try PaceMCPCatalogInstaller.uninstall(slug: "filesystem", from: configFileURL)

        let remainingServers = try readMCPServersDictionary(from: configFileURL)
        #expect(remainingServers["fetch"] != nil)
    }

    // MARK: - Atomic write semantics

    @Test func installWriteLeavesNoTempFilesBehind() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        let slackEntry = PaceMCPServerCatalog.entry(forSlug: "slack")!
        try PaceMCPCatalogInstaller.install(slackEntry, into: configFileURL)

        let parentDirectory = configFileURL.deletingLastPathComponent()
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: parentDirectory.path)
        let temporarySiblings = directoryContents.filter { name in
            name.hasPrefix(".") && name.contains("pace.tmp")
        }
        #expect(temporarySiblings.isEmpty)
        // The real config file should be the only thing left.
        let visibleSiblings = directoryContents.filter { !$0.hasPrefix(".") }
        #expect(visibleSiblings == ["mcp-servers.json"])
    }

    @Test func isInstalledReportsAccurateState() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        #expect(PaceMCPCatalogInstaller.isInstalled(slug: "filesystem", in: configFileURL) == false)

        let filesystemEntry = PaceMCPServerCatalog.entry(forSlug: "filesystem")!
        try PaceMCPCatalogInstaller.install(filesystemEntry, into: configFileURL)
        #expect(PaceMCPCatalogInstaller.isInstalled(slug: "filesystem", in: configFileURL) == true)

        try PaceMCPCatalogInstaller.uninstall(slug: "filesystem", from: configFileURL)
        #expect(PaceMCPCatalogInstaller.isInstalled(slug: "filesystem", in: configFileURL) == false)
    }

    // MARK: - Tolerant decode

    @Test func installPromotesLegacyServersKeyIntoMCPServersOnFirstWrite() throws {
        let configFileURL = makeTemporaryConfigFileURL()
        defer { try? FileManager.default.removeItem(at: configFileURL.deletingLastPathComponent()) }

        // Earlier `mcp-servers.json` shape used a top-level `servers`
        // key. The reader accepts it; the installer must migrate to
        // the canonical `mcpServers` shape on first write.
        try FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyJSON = """
        {
          "servers": {
            "legacy-entry": { "command": "echo", "args": ["hi"] }
          }
        }
        """
        try legacyJSON.write(to: configFileURL, atomically: true, encoding: .utf8)

        let fetchEntry = PaceMCPServerCatalog.entry(forSlug: "fetch")!
        try PaceMCPCatalogInstaller.install(fetchEntry, into: configFileURL)

        let mergedServers = try readMCPServersDictionary(from: configFileURL)
        #expect(mergedServers["legacy-entry"] != nil)
        #expect(mergedServers["fetch"] != nil)
    }
}
