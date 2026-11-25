import Foundation

/// Searchable presentation of the current MCP configuration. Commands and arbitrary
/// arguments can contain credentials, so only recognized provider metadata is shown.
nonisolated struct PacePowerConnection: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let searchTerms: [String]
    let suggestedRequest: String
    var source: String { "MCP connection" }
    var status: String { "Configured" }

    static func configured() -> [Self] {
        configured(servers: PaceMCPServerRegistry.loadConfiguredServers())
    }

    static func configured(servers: [String: PaceMCPServerConfiguration]) -> [Self] {
        servers.map { id, configuration in
            let executable = URL(fileURLWithPath: configuration.command).lastPathComponent
            if executable == "browse" && configuration.args.first == "mcp" {
                return Self(
                    id: id, name: "Browse", summary: "Work in your Chrome browser through the Browse extension.",
                    searchTerms: [id, "Browse", "Chrome", "browser", "active tab", "OpenCode"],
                    suggestedRequest: "Use \(id) to tell me the title of my active Chrome tab.")
            }
            let preset = PaceMCPServerCatalog.bundledCatalog.first {
                $0.command == executable && $0.arguments == configuration.args
            }
            let name = preset?.displayName ?? id
            return Self(
                id: id, name: name,
                summary: preset?.description ?? "Configured MCP server. Test the connection to see its tools.",
                searchTerms: [id, name, preset?.slug].compactMap { $0 },
                suggestedRequest: "What can I do with \(id)?")
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

extension CompanionManager {
    func openPowerConnection(_ connection: PacePowerConnection) {
        PaceMainWindowManager.shared.show(companionManager: self, destination: .mcp, focusedMCPServer: connection.id)
    }
}
