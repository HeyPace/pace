import Foundation

nonisolated enum PaceImagesPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.images",
        title: "Images",
        summary: "Explicit image creation and edits through the consented Codex backend.",
        permissionsUsed: [.offDevicePlanning],
        tools: tools,
        promptContributions: [
            .init(order: 21, applies: { $0.includeInteractiveDiagrams }, render: { _ in imageRules })
        ]
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .generateImage,
            canonicalName: "generate_image",
            aliases: [],
            schemaExample:
                #"{"tool":"generate_image","prompt":"A blue ceramic mug on a white background","title":"Blue mug","edit":false}"#,
            description:
                "Generate one raster image with the selected, consented Codex CLI and show it in Pace. Required prompt (up to8000 characters) and title (up to100). Use edit:true only for a requested change to the active Pace-generated image; Pace attaches that image alone. Never reference local files or ambient screens. Raster images support zoom and save, not rotation. Only use when the user explicitly requests image creation or editing.",
            riskLevel: .readOnly,
            executionSummary: "Generates an image off-device with Codex and opens the native Pace image overlay.",
            observationSummary: "Reports the generated image or an honest failure.",
            exampleUtterance: "generate an image of a blue mug"
        )
    ]

    static let imageRules = """
    For a beautiful raster illustration, photo, painting or image request, call generate_image. Image generation uses the selected, consented Codex CLI off-device; do not promise an image until its result returns. Only generate images when the user explicitly requests creation or an edit. For edits to the active Pace image use edit:true, never paths or ambient-screen attachments; include only the requested visual change in prompt. Use edit:false and a complete brief for a new image. generate_image remains available when desktop actions and screen reading are off; the existing Codex consent requirement still applies.
    \(tools.first(where: { $0.canonicalName == "generate_image" })!.promptLine)
    """
}
