import Foundation

nonisolated enum PaceIntegrationPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.integrations",
        title: "Integrations",
        summary: "Configured MCP tools, dynamic plugins and approved downloads.",
        permissionsUsed: [.externalTools],
        tools: tools,
        promptContributions: []
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .downloadFile,
            canonicalName: "download_file",
            aliases: ["download", "save_file"],
            schemaExample: #"{"tool":"download_file","url":"https://example.com/report.pdf","name":"report.pdf"}"#,
            description: "download a user-named http(s) URL into ~/Downloads. The product's only network action; always user-commanded.",
            riskLevel: .externalIntegration,
            executionSummary: "Downloads the URL into ~/Downloads with a sanitized, collision-free filename.",
            observationSummary: "Reports the saved filename and byte count, or the failure reason.",
            exampleUtterance: "download the report at example.com/report.pdf"
        )
    ]

    @MainActor
    static func dynamicPluginSection() -> String {
        let lines = PaceDynamicToolRegistry.shared.plannerPromptLines()
        guard !lines.isEmpty else { return "" }
        return "\n    dynamic plugins:\n    \(lines)\n"
    }
}
