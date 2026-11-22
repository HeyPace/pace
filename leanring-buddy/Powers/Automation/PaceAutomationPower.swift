import Foundation

nonisolated enum PaceAutomationPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.automation",
        title: "Automations",
        summary: "Reusable workflows, recorded flows and installed Shortcuts.",
        permissionsUsed: [.accessibility],
        tools: tools,
        promptContributions: []
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .shortcuts,
            canonicalName: "shortcuts",
            aliases: ["run_shortcut", "shortcut"],
            schemaExample: #"{"tool":"shortcuts","name":"My Shortcut"}"#,
            description: "run a named macOS Shortcut.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Runs a named shortcut through the Shortcuts app.",
            observationSummary: "Reports shortcut execution or AppleScript errors.",
            exampleUtterance: "run my Morning Routine shortcut"
        ),
        PaceLocalToolDefinition(
            kind: .recordFlow,
            canonicalName: "record_flow",
            aliases: ["record_this", "remember_flow"],
            schemaExample: #"{"tool":"record_flow","name":"morning standup setup"}"#,
            description: "start recording a user-demonstrated local flow by name. Recording stores AX/key steps, not pixels.",
            riskLevel: .inputInjection,
            executionSummary: "Starts or stops a local demonstration-recording session.",
            observationSummary: "Reports recording state or missing flow name.",
            exampleUtterance: "record this as my standup setup"
        ),
        PaceLocalToolDefinition(
            kind: .runFlow,
            canonicalName: "run_flow",
            aliases: ["play_flow", "do_flow"],
            schemaExample: #"{"tool":"run_flow","name":"morning standup setup"}"#,
            description: "run a previously recorded local flow by name. User approval is required before replay.",
            riskLevel: .inputInjection,
            executionSummary: "Replays saved AX/key steps through the local executor.",
            observationSummary: "Reports replay start or missing flow.",
            exampleUtterance: "run my standup setup flow"
        )
    ]
}
