//
//  PaceMCPSettingsTab.swift
//  leanring-buddy
//
//  Settings → MCP tab content. Three sub-sections:
//   - Config file (path + Create/Open/Reveal/Refresh buttons)
//   - Curated catalog of bundled MCP servers (one-tap install/remove)
//   - List of currently-configured servers
//
//  Catalog install/uninstall performs an atomic JSON merge into
//  `mcp-servers.json` via `PaceMCPCatalogInstaller`, preserving every
//  hand-edited server entry the user already has.
//

import AppKit
import SwiftUI

struct PaceMCPSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    var connectionFocus: PaceCommandCenterRouter.ConnectionFocus? = nil

    @State private var configuredMCPServerNames: [String] = PaceMCPServerRegistry.loadConfiguredServers().keys.sorted()
    /// Last per-catalog-slug operation feedback so the install card can
    /// show "Installed ✓" / "Removed" / "Failed: …" after each tap.
    /// Resets to nil on a fresh refresh so stale outcomes don't linger.
    @State private var lastCatalogActionBySlug: [String: String] = [:]
    /// In-memory editing state for the Composio API key SecureField.
    /// Never persisted in @State — Save commits it to Keychain via
    /// `PaceMCPSecretStore`; the field clears after save so the SwiftUI
    /// tree never holds the secret across re-renders.
    @State private var composioAPIKeyEditingDraft: String = ""
    /// Mirror of `PaceMCPSecretStore.hasSecret(...)` re-evaluated on
    /// appear / save / remove so the "Key in Keychain: yes/no"
    /// indicator stays in sync without polling.
    @State private var composioKeyIsStoredInKeychain: Bool = false
    /// Save/Remove feedback for the Composio key row.
    @State private var composioKeyStatusFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Configured connections (\(configuredMCPServerNames.count))")
                    .font(DS.Typography.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .id("pace.mcp.configured")

                if let name = connectionFocus?.serverName, !configuredMCPServerNames.contains(name) {
                    Text("“\(name)” is no longer configured. Open the configuration file to review your connections.")
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                if configuredMCPServerNames.isEmpty {
                    Text(
                        "Choose an MCP server below or open the configuration file to add a connection."
                    )
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(focusedServerNames, id: \.self) { serverName in
                        PaceConnectionTestView(serverName: serverName, showsServerName: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Configuration file")
                    .font(DS.Typography.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(PaceMCPServerRegistry.configurationPaths[0].path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                paceSettingsButton("Open configuration", systemName: "doc.badge.gearshape") {
                    createMCPConfigIfNeeded()
                    openPrimaryMCPConfig()
                    refreshMCPServerNames()
                }
                paceSettingsButton("Show in Finder", systemName: "folder") {
                    createMCPConfigIfNeeded()
                    NSWorkspace.shared.activateFileViewerSelecting([PaceMCPServerRegistry.configurationPaths[0]])
                    refreshMCPServerNames()
                }
                paceSettingsButton("Refresh", systemName: "arrow.clockwise") {
                    refreshMCPServerNames()
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            mcpCatalogSection
        }
        .onChange(of: connectionFocus) { _, _ in refreshMCPServerNames() }
        .onAppear {
            refreshMCPServerNames()
            refreshComposioKeyState()
        }
    }

    /// Curated MCP server catalog rendered as one-tap install cards.
    /// Each card writes/removes a single server entry in
    /// `mcp-servers.json` via `PaceMCPCatalogInstaller`, which performs
    /// an atomic JSON merge that preserves every other server the user
    /// has already configured by hand.
    private var mcpCatalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available connections")
                .font(DS.Typography.sectionTitle)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Install a server from the bundled catalog, then select Test Connection to check its tools. Composio connects to a hosted service."
            )
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(PaceMCPServerCatalog.bundledCatalog) { catalogEntry in
                    mcpCatalogCardRow(entry: catalogEntry)
                    if catalogEntry.slug == "composio"
                        && configuredMCPServerNames.contains(catalogEntry.slug)
                    {
                        composioKeyEditorRow
                    }
                }
            }
        }
    }

    private var composioKeyEditorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Composio API key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("Key in Keychain: \(composioKeyIsStoredInKeychain ? "yes" : "no")")
                    .font(.system(size: 11))
                    .foregroundColor(composioKeyIsStoredInKeychain ? DS.Colors.success : DS.Colors.textTertiary)
            }
            HStack(spacing: 8) {
                SecureField("paste composio API key", text: $composioAPIKeyEditingDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                paceSettingsButton("save", systemName: "checkmark.circle") {
                    saveComposioAPIKey()
                }
                if composioKeyIsStoredInKeychain {
                    paceSettingsButton("Remove", systemName: "xmark.circle") {
                        removeComposioAPIKey()
                    }
                }
            }
            if let statusFeedback = composioKeyStatusFeedback {
                Text(statusFeedback)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Stored in macOS Keychain; auto-injected into the Composio subprocess at launch. Never written to the mcp-servers.json file or to any log."
            )
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
    }

    private func saveComposioAPIKey() {
        let trimmedKey =
            composioAPIKeyEditingDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            composioKeyStatusFeedback = "Paste a key before tapping Save."
            return
        }
        let didStore = PaceMCPSecretStore.storeSecret(
            trimmedKey,
            server: "composio",
            key: "COMPOSIO_API_KEY"
        )
        if didStore {
            composioAPIKeyEditingDraft = ""
            composioKeyIsStoredInKeychain = true
            composioKeyStatusFeedback = "Saved to Keychain."
        } else {
            composioKeyStatusFeedback = "Save failed — see Console for the Keychain status code."
        }
    }

    private func removeComposioAPIKey() {
        let didDelete = PaceMCPSecretStore.deleteSecret(
            server: "composio",
            key: "COMPOSIO_API_KEY"
        )
        if didDelete {
            composioKeyIsStoredInKeychain = false
            composioKeyStatusFeedback = "Removed from Keychain."
        } else {
            composioKeyStatusFeedback = "Remove failed — see Console for the Keychain status code."
        }
    }

    private func refreshComposioKeyState() {
        composioKeyIsStoredInKeychain = PaceMCPSecretStore.hasSecret(
            server: "composio",
            key: "COMPOSIO_API_KEY"
        )
    }

    private func mcpCatalogCardRow(entry: PaceMCPServerCatalogEntry) -> some View {
        let isInstalled = configuredMCPServerNames.contains(entry.slug)
        let statusFeedback = lastCatalogActionBySlug[entry.slug]
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isInstalled ? DS.Colors.success : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if isInstalled {
                        Text("installed")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(DS.Colors.success.opacity(0.12))
                            )
                    }
                }
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let setupNote = entry.setupNote {
                    Text(setupNote)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let statusFeedback {
                    Text(statusFeedback)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                if isInstalled {
                    paceSettingsButton("Remove", systemName: "trash") {
                        uninstallCatalogEntry(entry)
                    }
                } else {
                    paceSettingsButton("Install", systemName: "arrow.down.circle") {
                        installCatalogEntry(entry)
                    }
                }
                if let docsURL = entry.setupDocsURL {
                    paceSettingsButton("Setup guide", systemName: "book") {
                        NSWorkspace.shared.open(docsURL)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func installCatalogEntry(_ entry: PaceMCPServerCatalogEntry) {
        let configURL = PaceMCPServerRegistry.configurationPaths[0]
        do {
            try PaceMCPCatalogInstaller.install(entry, into: configURL)
            // Composio's key lives in Keychain (sentinel "" env value
            // in the catalog entry), so the user doesn't have to edit
            // the JSON. Other servers still use the legacy placeholder
            // flow.
            if entry.slug == "composio" {
                lastCatalogActionBySlug[entry.slug] =
                    "Installed. Paste your COMPOSIO_API_KEY in the key field below; it'll be auto-injected at launch."
            } else {
                lastCatalogActionBySlug[entry.slug] =
                    "Installed. Use Test Connection below to verify the server and complete any required sign-in."
            }
            refreshMCPServerNames()
            refreshComposioKeyState()
        } catch {
            lastCatalogActionBySlug[entry.slug] = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstallCatalogEntry(_ entry: PaceMCPServerCatalogEntry) {
        let configURL = PaceMCPServerRegistry.configurationPaths[0]
        do {
            try PaceMCPCatalogInstaller.uninstall(slug: entry.slug, from: configURL)
            lastCatalogActionBySlug[entry.slug] = "Removed from \(configURL.lastPathComponent)."
            refreshMCPServerNames()
            refreshComposioKeyState()
        } catch {
            lastCatalogActionBySlug[entry.slug] = "Remove failed: \(error.localizedDescription)"
        }
    }

    private var focusedServerNames: [String] {
        guard let focused = connectionFocus?.serverName, configuredMCPServerNames.contains(focused) else {
            return configuredMCPServerNames
        }
        return [focused] + configuredMCPServerNames.filter { $0 != focused }
    }

    private func refreshMCPServerNames() {
        configuredMCPServerNames = PaceMCPServerRegistry.loadConfiguredServers().keys.sorted()
        NotificationCenter.default.post(name: .paceMCPConfigurationRefreshed, object: nil)
    }

    private func createMCPConfigIfNeeded() {
        let configURL = PaceMCPServerRegistry.configurationPaths[0]
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }

        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.defaultMCPConfigText.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            print("⚠️ Pace Settings: could not create MCP config: \(error)")
        }
    }

    private func openPrimaryMCPConfig() {
        NSWorkspace.shared.open(PaceMCPServerRegistry.configurationPaths[0])
    }

    private static let defaultMCPConfigText = PaceMCPServerRegistry.starterConfigurationJSON
}

extension Notification.Name {
    fileprivate static let paceMCPConfigurationRefreshed = Notification.Name("pace.mcp.configurationRefreshed")
}

struct PaceConnectionTestView: View {
    let serverName: String
    var showsServerName = false

    var body: some View {
        ConnectionCheck(serverName: serverName, showsServerName: showsServerName)
            .id(serverName)
    }

    private struct ConnectionCheck: View {
        let serverName: String
        let showsServerName: Bool
        @State private var requestID: UUID?
        @State private var testedRevision: Int?
        @State private var status: String?
        @State private var advertisedTools: [String]?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if showsServerName {
                        Circle().fill(advertisedTools == nil ? DS.Colors.textTertiary : DS.Colors.success)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(serverName).font(DS.Typography.bodyStrong)
                        Spacer()
                    }
                    paceSettingsButton(
                        requestID == nil ? "Test Connection" : "Connecting…", systemName: "bolt.horizontal.circle"
                    ) {
                        advertisedTools = nil
                        status = "Connecting. Complete any provider sign-in in your browser."
                        requestID = UUID()
                    }
                    .disabled(requestID != nil)
                    .accessibilityLabel("Test connection to \(serverName)")
                }
                if let status {
                    Text(status)
                        .font(DS.Typography.caption)
                        .foregroundStyle(advertisedTools == nil ? DS.Colors.textSecondary : DS.Colors.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let advertisedTools, !advertisedTools.isEmpty {
                    MCPAdvertisedToolsView(names: advertisedTools)
                }
            }
            .padding(.vertical, showsServerName ? 4 : 0)
            .accessibilityIdentifier("pace.mcp.connection.\(serverName)")
            .task(id: requestID) {
                guard let requestID else { return }
                await test(requestID)
            }
            .onDisappear { requestID = nil }
            .onReceive(NotificationCenter.default.publisher(for: .paceMCPConfigurationRefreshed)) { _ in
                invalidateIfConfigurationChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                invalidateIfConfigurationChanged()
            }
        }

        private func invalidateIfConfigurationChanged() {
            guard let testedRevision,
                PaceMCPServerRegistry.loadConfiguredServers()[serverName].map(revision) != testedRevision
            else { return }
            self.testedRevision = nil
            requestID = nil
            advertisedTools = nil
            status = "Configuration changed. Test the connection again."
        }

        // Keep only a process-local comparison token between explicit tests.
        private func revision(_ config: PaceMCPServerConfiguration) -> Int {
            var hasher = Hasher()
            hasher.combine(config.command)
            hasher.combine(config.args)
            hasher.combine(config.workingDirectory)
            hasher.combine(config.env)
            return hasher.finalize()
        }

        @MainActor private func test(_ id: UUID) async {
            defer { if requestID == id { requestID = nil } }
            guard let configuration = PaceMCPServerRegistry.loadConfiguredServers()[serverName] else {
                testedRevision = nil
                status = "This connection is no longer configured."
                return
            }
            testedRevision = revision(configuration)
            do {
                let client = PaceMCPStdioClient(
                    serverConfigurations: [serverName: configuration], requestTimeoutInSeconds: 90)
                let catalog = try await client.toolCatalog(serverName: serverName)
                guard !Task.isCancelled && requestID == id else { return }
                invalidateIfConfigurationChanged()
                guard requestID == id else { return }
                struct AdvertisedTool: Decodable { let name: String }
                let tools = try JSONDecoder().decode([AdvertisedTool].self, from: Data(catalog.utf8))
                let names = tools.map(\.name).sorted()
                guard !names.contains("") else {
                    status = "The server returned an invalid tool catalog."
                    return
                }
                advertisedTools = names
                status = "Server connected · \(names.count) \(names.count == 1 ? "tool" : "tools") available."
            } catch {
                guard !Task.isCancelled && requestID == id else { return }
                invalidateIfConfigurationChanged()
                guard requestID == id else { return }
                status =
                    "Unavailable: \(error.localizedDescription). Check the server setup, complete sign-in, then retry."
            }
        }
    }
}

private struct MCPAdvertisedToolsView: View {
    let names: [String]
    @State private var query = ""

    var body: some View {
        DisclosureGroup("Available tools (\(names.count))") {
            VStack(alignment: .leading, spacing: 8) {
                if names.count > 8 {
                    TextField("Find a tool", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Find a tool")
                }
                let matches = names.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                if matches.isEmpty {
                    Text("No matching tools").foregroundStyle(DS.Colors.textSecondary)
                } else {
                    Text(matches.joined(separator: "\n"))
                        .font(DS.Typography.metadata)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(DS.Typography.callout)
    }
}
