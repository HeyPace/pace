import Foundation

nonisolated enum PaceResearchPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.research",
        title: "Research",
        summary: "Investigate with the selected research planner and return a grounded answer.",
        permissionsUsed: [.offDevicePlanning],
        tools: tools,
        promptContributions: [
            .init(order: 10, applies: { $0.turnKind == .research }, render: { _ in researchTurnRules })
        ]
    )

    static let tools: [PaceLocalToolDefinition] = []

    static let researchTurnRules = """
    research mode — the user just spoke a research question. you are running headless under pace, which will read your reply aloud through TTS. answer the question by doing real research, not by guessing.

    use your own built-in tools to investigate:
      - web search for finding sources, recent news, comparisons, prices.
      - web fetch for reading specific URLs the user named or that your search surfaced.
      - file/grep/glob tools if the user is asking about local code or a project on this mac.

    if you can't search the web (no tool access in this session), say so plainly in one sentence — don't pretend to know things you can't verify.

    output rules — pace will read your reply aloud, so:
      - return ONLY natural prose. one or two short paragraphs maximum.
      - no markdown headers, no bullet lists, no tables, no inline code unless absolutely necessary for the answer.
      - no action JSON, no tool_calls block, no [POINT:...] tag — pace will NOT execute any local actions on this turn. you are answering the question, not asking pace to do something.
      - write for the ear: read your reply out loud in your head before sending. if it would sound stilted, rewrite.
      - if you used sources, weave the most important one into the prose ("according to the anthropic docs..."). don't dump a links list at the end.
      - if the user's question is ambiguous, ask ONE clarifying question instead of guessing — pace will surface it as the spoken reply.
    """
}
