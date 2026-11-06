import Foundation

nonisolated enum PaceComputerUsePower {
    static let definition = PacePowerDefinition(
        identifier: "pace.computer",
        title: "Computer use",
        summary: "Grounded desktop actions through shared preflight and approval.",
        permissionsUsed: [.accessibility],
        tools: tools,
        promptContributions: [
            .init(order: 30, applies: { $0.turnKind == .screen && $0.includeAgentMode }, render: { catalog in renderAgentModeRulesBlock(plannerToolListText: catalog.tools.map(\.promptLine).joined(separator: "\n")) })
        ]
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .click,
            canonicalName: "click",
            aliases: [],
            schemaExample: #"{"tool":"click","x":400,"y":300,"screen":1}"#,
            description: "click screenshot pixel coordinates.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a click through Accessibility or CGEvent.",
            observationSummary: "No observation unless coordinate conversion fails.",
            exampleUtterance: "click the Save button"
        ),
        PaceLocalToolDefinition(
            kind: .doubleClick,
            canonicalName: "double_click",
            aliases: ["doubleclick"],
            schemaExample: #"{"tool":"double_click","x":400,"y":300,"screen":1}"#,
            description: "double-click screenshot pixel coordinates.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a double-click through CGEvent.",
            observationSummary: "No observation unless coordinate conversion fails.",
            exampleUtterance: "double click that icon"
        ),
        PaceLocalToolDefinition(
            kind: .type,
            canonicalName: "type",
            aliases: [],
            schemaExample: #"{"tool":"type","text":"exact text"}"#,
            description: "type exact text into the focused field.",
            riskLevel: .inputInjection,
            executionSummary: "Types literal text into the focused app.",
            observationSummary: "No observation.",
            exampleUtterance: "type hello world"
        ),
        PaceLocalToolDefinition(
            kind: .setValue,
            canonicalName: "set_value",
            aliases: ["ax_set_value"],
            schemaExample: #"{"tool":"set_value","text":"replacement text","action":"selection"}"#,
            description: "set focused text or replace selected text through Accessibility. actions: focused, selection.",
            riskLevel: .inputInjection,
            executionSummary: "Uses AXValue to update focused or selected text.",
            observationSummary: "Reports whether text was updated or no editable target was found.",
            exampleUtterance: "make this selection more concise"
        ),
        PaceLocalToolDefinition(
            kind: .undo,
            canonicalName: "undo_last",
            aliases: ["undo"],
            schemaExample: #"{"tool":"undo_last"}"#,
            description: "undo the last editable text change made by Pace.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Restores the previous AX value from Pace's session mutation log.",
            observationSummary: "Reports whether an undoable mutation was restored.",
            exampleUtterance: "undo that"
        ),
        PaceLocalToolDefinition(
            kind: .key,
            canonicalName: "key",
            aliases: ["press_key"],
            schemaExample: #"{"tool":"key","key":"cmd+shift+t"}"#,
            description: "press a key or key chord.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a keyboard event with optional modifiers.",
            observationSummary: "No observation unless the key is unknown.",
            exampleUtterance: "press command S"
        ),
        PaceLocalToolDefinition(
            kind: .clipboard,
            canonicalName: "clipboard_read",
            aliases: ["clipboard"],
            schemaExample: #"{"tool":"clipboard_read"}"#,
            description: "read current clipboard text only when explicitly requested.",
            riskLevel: .readOnly,
            executionSummary: "Reads text from NSPasteboard without modifying it.",
            observationSummary: "Returns a bounded clipboard text preview or empty-text status.",
            exampleUtterance: "what's on my clipboard?"
        ),
        PaceLocalToolDefinition(
            kind: .window,
            canonicalName: "window_snap",
            aliases: ["window", "snap_window"],
            schemaExample: #"{"tool":"window_snap","position":"left"}"#,
            description: "move/resize the focused window. positions: left, right, top, bottom, maximize, center.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Moves and resizes the focused window with Accessibility.",
            observationSummary: "Reports whether the focused window was snapped.",
            exampleUtterance: "snap this window to the left half"
        ),
        PaceLocalToolDefinition(
            kind: .scroll,
            canonicalName: "scroll",
            aliases: [],
            schemaExample: #"{"tool":"scroll","direction":"down","amount":5}"#,
            description: "scroll the focused surface.",
            riskLevel: .inputInjection,
            executionSummary: "Posts a scroll wheel event.",
            observationSummary: "No observation.",
            exampleUtterance: "scroll down"
        ),
        PaceLocalToolDefinition(
            kind: .openApp,
            canonicalName: "open_app",
            aliases: ["open_application"],
            schemaExample: #"{"tool":"open_app","app":"Safari"}"#,
            description:
                "open a local Mac app by display name. For Chrome, optional profile is a directory (Default or Profile N), or work to use the saved work profile.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Launches or activates an app with NSWorkspace.",
            observationSummary: "No observation unless the app cannot be resolved.",
            exampleUtterance: "open Safari"
        ),
        PaceLocalToolDefinition(
            kind: .openURL,
            canonicalName: "open_url",
            aliases: ["open_website", "website"],
            schemaExample: #"{"tool":"open_url","url":"https://example.com"}"#,
            description:
                "open a website or URL. Optional browser selects Chrome/Safari/etc.; profile selects a Chrome directory (Default or Profile N), or work for the saved work profile.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens a URL with NSWorkspace.",
            observationSummary: "Reports invalid URLs and opened URLs.",
            exampleUtterance: "open Safari to anthropic.com"
        ),
        PaceLocalToolDefinition(
            kind: .codexSession,
            canonicalName: "codex_session",
            aliases: [],
            schemaExample: #"{"tool":"codex_session","directory":"~/projects/my-app"}"#,
            description:
                "open an interactive Codex session in Warp in an existing folder. directory is a concrete absolute or ~/ path; ask for the folder when unknown. Does not execute a model-generated shell command or bypass Codex trust/approval prompts.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a Warp tab config with a fixed Codex executable and opens it.",
            observationSummary: "Reports launch requested or a missing folder/tool; sign-in and trust remain in Warp.",
            exampleUtterance: "start Codex in ~/projects/my-app"
        ),
        PaceLocalToolDefinition(
            kind: .finder,
            canonicalName: "finder",
            aliases: ["open_finder", "reveal_file"],
            schemaExample: #"{"tool":"finder","path":"~/Downloads","action":"open"}"#,
            description: "open or reveal a local file/folder in Finder.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens or reveals a local path with NSWorkspace.",
            observationSummary: "Reports missing paths and opened/revealed paths.",
            exampleUtterance: "open my Downloads folder"
        )
    ]

    static let desktopToolRecoveryGuidance = """
    Native Pace actions remain available alongside Peekaboo. Honor requests to use native controls. Prefer App.launch and App.openURL for known app/site launches without inventory. If an editor has no actionable document window, activate the requested app and perform the user-requested new-document shortcut with Key.press; then end that action batch and observe the new document in the next iteration before typing. A failed observation is not evidence that a dispatched shortcut failed: retry the read instead of creating another document. Do not treat blank pixels_only/no_matching_accessibility_window menu-bar surfaces as document windows or repeatedly inspect them. For uncertain mutations, obtain a fresh observation before deciding whether another action is needed; never replay a may_have_dispatched action blindly.
    """

    @MainActor
    private static func renderAgentModeRulesBlock(plannerToolListText: String) -> String {
        """
        agent mode — when the user asks you to *do* something, prefer the typed v10 JSON envelope. it is parsed after generation, stripped before TTS, approved if needed, then executed.

        v10 envelope shape:
        {
          "spokenText": "short narration the user should hear",
          "intent": "action",
          "payload": {"name":"Mail.draft","args":{"to":["alex@example.com"],"subject":"Hello","body":"draft text"}}
        }

        for routine visible/reversible actions such as AX.press, App.launch, Key.press, Window.snap, Music.control, Volume.adjust, Brightness.adjust, Clipboard.read, Undo.last, and simple open-url/open-app, set spokenText to "" unless the user needs an explanation. the action, HUD, and any result/error text are the feedback. speak only for answers, clarifications, risky/non-undoable actions, failures, or user-visible summaries.

        for dictation use:
        {"spokenText":"","intent":"dictate","payload":{"text":"exact text to type","target":"focused"}}

        for selected-text edits use:
        {"spokenText":"rewriting that.","intent":"edit","payload":{"replacement":"new text","target":"selection"}}
        when the user asks for a common deterministic selected-text transform and no model rewrite is needed, use command instead:
        {"spokenText":"","intent":"edit","payload":{"command":"make this shorter","target":"selection"}}

        drawing, circling, highlighting, or marking something on screen is an ACTION, never dictate or edit. use intent "action" with payload name Draw.annotation:
        {"spokenText":"here's the apple menu.","intent":"action","payload":{"name":"Draw.annotation","args":{"shapes":[{"kind":"ellipse","x":40,"y":-40,"width":120,"height":120,"color":"red"}]}}}
        each entry in args.shapes MUST be a JSON object with separate named keys — NOT a flat list of values or "key=value" strings. correct: {"kind":"ellipse","x":40,"y":-40,"width":120,"height":120,"color":"red"}. WRONG (never do this): ["ellipse","x=540","y=300","width=120","color=red"] or ["ellipse",540,300,120,120,"red"].
        Draw.annotation args.shapes coords are screenshot pixels (same space as click). shape kinds and their required object keys:
        - rect / ellipse: {"kind":"ellipse","x":INT,"y":INT,"width":INT,"height":INT}  (x,y is the TOP-LEFT of the box; for a circle set width==height. to circle a target centered at (cx,cy) with size S, use x=cx-S/2, y=cy-S/2, width=S, height=S)
        - line / arrow: {"kind":"arrow","x1":INT,"y1":INT,"x2":INT,"y2":INT}
        - polygon: {"kind":"polygon","points":[[INT,INT],[INT,INT],[INT,INT]]}
        per shape you may add "color" (red, blue, green, yellow, orange) and "label" (≤60 chars). "draw a red circle around X" → one ellipse object whose box is centered on X's coordinates, with "color":"red". "highlight X" → one rect object around X. NEVER answer a draw/circle/highlight request with intent dictate or edit, and NEVER just say you'll draw without emitting the Draw.annotation action.

        supported typed action names (payload.name) include:
            App.launch, App.openURL, AX.press, AX.doublePress, AX.setValue, AX.scroll, Key.press, Undo.last, Clipboard.read, Window.snap, Music.control, Volume.adjust, Brightness.adjust, Calendar.read, Calendar.createEvent, Reminders.add, Notes.create, Notes.append, Notes.search, Mail.draft, Shortcut.run, Things.create, Messages.open, Finder.open, Finder.reveal, Draw.annotation, Clear.annotations, Screen.capture, meeting, Codex.session, MCP.call.

        for a MULTI-STEP task (a numbered list, or "do X then Y then Z"), emit ONE envelope whose payload has a "calls" array — each entry is {"name":...,"args":{...}}, run in order. do NOT emit only the first step and stop; you are NOT re-invoked between steps. example for "open safari, open a new tab, then search":
        {"spokenText":"opening safari and searching.","intent":"action","payload":{"calls":[
          {"name":"App.launch","args":{"app":"Safari"}},
          {"name":"Key.press","args":{"key":"cmd+t"}},
          {"name":"Key.press","args":{"key":"cmd+l"}}
        ]}}
        put steps that need a focus/keyboard change in separate calls, in order.

        when pointing is useful, append [POINT:x,y:label:desktop] inside spokenText for global desktop coordinates from Peekaboo/AX inspection. Use the center of the freshly observed target's bounds; desktop points can be negative on other displays. For a supplied Pace screenshot, use [POINT:x,y:label:screenN] with that screenshot's pixel coordinates and screen number. Never mix these coordinate spaces. If a named app's target is absent from the current screen context, inspect that app with Peekaboo before answering. legacy <tool_calls> blocks and action tags are still accepted as fallbacks.

        tool_calls shape:
        - outer array = sequential steps.
        - inner array = tool calls that may run in parallel.
        - keep mouse/keyboard/focus-changing calls in separate single-call steps unless the user explicitly needs parallel reads.

        example:
        <tool_calls>
        [
          [
            {"tool":"open_app","app":"Music"},
            {"tool":"open_url","url":"https://example.com"}
          ],
          [
            {"tool":"music","command":"play"},
            {"tool":"volume","direction":"down","steps":2}
          ]
        ]
        </tool_calls>

        available tools:
        \(plannerToolListText)

            For computer-use tasks, ground clicks, typing, keys, and scrolling in the supplied screenshot or AX/OCR context. Observe the result on the next step before continuing with dependent actions. Never claim a visible state change solely from issuing an action. If screen context is unavailable, ask the user to enable Read My Screen and the required permissions rather than inventing coordinates. Prefer direct app/URL tools for launches that do not need screen context.

            Use Codex.session with a concrete directory to start an interactive Codex session in Warp. Ask which folder when it is unknown. Screen.capture mode screenshot/recording opens native selection controls. Modes start_recording, stop_recording, and recording_status manage an actual main-display recording; use them when asked to start/stop screen recording. Meeting controls local audio recording. Ask whether screen or meeting audio when recording is ambiguous. Compose multiple calls for multi-app requests; never invent a saved routine unless the user taught it.
        \(PaceIntegrationPower.dynamicPluginSection())

        external MCP tools:
        - use {"tool":"mcp","server":"altic","name":"notes_create","arguments":{"title":"Idea","body":"note text"}} when the user asks for an integration that is exposed by a configured MCP server.
        - if a configured MCP server exposes native tool names, you may also use {"tool":"notes_search","server":"altic","query":"roadmap"}.
        - do not invent server names. only use MCP servers explicitly provided by system/developer context or visible configuration.

        external SaaS routing rule: use configured servers whose exact tool schemas have been supplied. Prefer an official service integration when available; Composio is optional and must be configured and connected before use. Never invent an account connection or tool name. For Slack visible-channel requests, an already signed-in Slack window can be read through Peekaboo with screen permission; that does not imply API access or unseen-channel access. Apple-native Calendar, reminders, notes, mail drafts, contacts, and files stay on the local native tools. Do not send messages or mutate external services unless the user explicitly requested that action. Read-only requests may only use read tools.


        tool choice rules:
        - if the user asks to create, make, add, or save a note, use {"tool":"notes","action":"create","title":"...","body":"..."} with the user's requested text in body. do not use open_app Notes for note creation.
        - if the user asks to add text to an existing note, use {"tool":"notes","action":"append","title":"...","body":"..."}. if they ask to find notes, use {"tool":"notes","action":"search","query":"..."}.
        - use open_app only when the user asked to open or launch an app, not when a more specific tool exists.
            - to OPEN AN APP emit open_app / App.launch with the app name: "open chrome" → Google Chrome, "launch xcode" → Xcode, "open spotify" → Spotify, "open safari" → Safari, "open the calculator" → Calculator. to OPEN A WEBSITE emit open_url / App.openURL with the full https url: "open hacker news" → https://news.ycombinator.com, "go to github.com" → https://github.com. an app NAME is NOT a website: never invent a domain like safari.com for an app — "open safari" is App.launch Safari, never App.openURL. only use App.openURL when the user names a real web address or domain. for "open <site> on <browser>" (e.g. "open hacker news on chrome") emit App.openURL with url and browser; honor an explicit Chrome profile using profile. opening an app or site NEVER requires seeing it on screen first and is NEVER a "can't see it" refusal.

        legacy tags are still accepted:
        - [CLICK:x,y]               left-click at screenshot pixel (x,y). add :screenN for non-cursor screens.
        - [DOUBLE_CLICK:x,y]        double-click, same coord space.
        - [TYPE:exact text]         types the literal text into whatever is focused.
        - [KEY:Return]              press a named key. modifiers chain with +: [KEY:cmd+s], [KEY:cmd+shift+t]. supported: Return Tab Space Delete Escape Up Down Left Right Home End PageUp PageDown.
        - [SCROLL:up:3]             scroll up 3 lines. [SCROLL:down:5] also works.
        - [OPEN_APP:Safari]         open a local mac app by display name. use for "open safari", "launch xcode", etc.
        - [VOLUME:up:2]             raise volume by 2 steps. [VOLUME:down] lowers by the default 2 steps.
        - [BRIGHTNESS:up]           raise display brightness. [BRIGHTNESS:down:3] lowers by 3 steps.

        only emit tool calls/action tags when the user clearly asked you to *do* something. when unsure, point and ask.

        multi-step recap: when you already know the steps up front (a numbered list, or "do X then Y then Z"), put them ALL in the single envelope's payload.calls array — you are not re-invoked between them. only fall back to the legacy one-step-at-a-time <tool_calls>+[DONE] loop below when a later step genuinely depends on reading the screen AFTER an earlier step lands (e.g. "open the file menu, then click whatever recent file shows up") and you cannot know it in advance.

        read-only inspection exception: after Peekaboo app/window listing or see, or a Playwright snapshot/screenshot, Pace WILL call you again with the tool results, including for structured envelopes. A window list only discovers the target; inspect its content next if necessary. Answer the user's actual question from that evidence without further actions once sufficient. Never treat a successful inventory as a completed explanation. Do not repeat an inspection that already supplied the needed evidence.

        legacy per-step loop (screen-dependent steps only) — emit THIS step's tool_calls/action tags + a one-sentence narration, do NOT emit [DONE], and you'll be re-invoked with a fresh screenshot; emit [DONE] once the whole task is done. one short narration per step. loop bails at AgentMaxSteps (default 8).
        """
    }

}
