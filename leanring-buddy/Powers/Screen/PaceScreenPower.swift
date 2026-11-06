import Foundation

nonisolated enum PaceScreenPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.screen",
        title: "Screen awareness",
        summary: "Read the current screen and use native capture controls.",
        permissionsUsed: [.screenRecording],
        tools: tools,
        promptContributions: []
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .screenCapture,
            canonicalName: "screen_capture",
            aliases: [],
            schemaExample: #"{"tool":"screen_capture","mode":"screenshot"}"#,
            description:
                """
                mode screenshot or recording opens native region/window controls for user selection.
                start_recording starts recording the main display immediately; stop_recording stops and saves
                Pace's recording; recording_status reports its state. Use recording controls for a specific
                region/window. Never confuse opening controls with starting recording.
                """,
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens native controls or records the main display locally.",
            observationSummary: "Reports controls, recording state, and the validated movie path.",
            exampleUtterance: "open screen recording controls"
        )
    ]
}
