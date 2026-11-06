import Foundation

nonisolated enum PaceProductivityPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.productivity",
        title: "Productivity",
        summary: "Native calendar, notes, reminders, drafts and system utilities.",
        permissionsUsed: [.calendar, .reminders, .contacts],
        tools: tools,
        promptContributions: []
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .music,
            canonicalName: "music",
            aliases: [],
            schemaExample: #"{"tool":"music","command":"play"}"#,
            description: "control Music. commands: play, pause, play_pause, next, previous.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Controls Music with AppleScript or media keys.",
            observationSummary: "Reports Music command completion or AppleScript errors.",
            exampleUtterance: "play my music"
        ),
        PaceLocalToolDefinition(
            kind: .volume,
            canonicalName: "volume",
            aliases: [],
            schemaExample: #"{"tool":"volume","direction":"down","steps":2}"#,
            description: "adjust system volume.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Posts system volume key events.",
            observationSummary: "No observation.",
            exampleUtterance: "turn the volume down"
        ),
        PaceLocalToolDefinition(
            kind: .brightness,
            canonicalName: "brightness",
            aliases: [],
            schemaExample: #"{"tool":"brightness","direction":"up","steps":2}"#,
            description: "adjust display brightness.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Posts display brightness key events.",
            observationSummary: "No observation.",
            exampleUtterance: "make the screen brighter"
        ),
        PaceLocalToolDefinition(
            kind: .calendar,
            canonicalName: "calendar",
            aliases: [],
            schemaExample: #"{"tool":"calendar","range":"today"}"#,
            description: "read calendar events. ranges: today, tomorrow, week.",
            riskLevel: .readOnly,
            executionSummary: "Reads EventKit calendar events after permission.",
            observationSummary: "Returns event summaries or permission errors.",
            exampleUtterance: "what's on my calendar this week"
        ),
        PaceLocalToolDefinition(
            kind: .calendarCreate,
            canonicalName: "calendar_create",
            aliases: ["calendar_event", "cal_event"],
            schemaExample: #"{"tool":"calendar_create","title":"Design review","start":"2026-06-10T15:00:00-07:00","end":"2026-06-10T16:00:00-07:00"}"#,
            description: "create a local calendar event. start is required; date-only values create all-day events.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates an EventKit calendar event after permission.",
            observationSummary: "Reports event creation or permission errors.",
            exampleUtterance: "add a design review to my calendar tomorrow at 3pm"
        ),
        PaceLocalToolDefinition(
            kind: .reminder,
            canonicalName: "reminder",
            aliases: [],
            schemaExample: #"{"tool":"reminder","title":"follow up with Alex"}"#,
            description: "create a reminder.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates an EventKit reminder after permission.",
            observationSummary: "Reports reminder creation or permission errors.",
            exampleUtterance: "remind me to follow up with Alex"
        ),
        PaceLocalToolDefinition(
            kind: .notes,
            canonicalName: "notes",
            aliases: ["note"],
            schemaExample: #"{"tool":"notes","action":"create","title":"Idea","body":"note text"}"#,
            description: "create, append, or search Apple Notes. actions: create, append, search.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a note in Apple Notes with AppleScript.",
            observationSummary: "Reports note creation or AppleScript errors.",
            exampleUtterance: "take a note: idea for the launch page"
        ),
        PaceLocalToolDefinition(
            kind: .mail,
            canonicalName: "mail",
            aliases: ["compose_email", "email"],
            schemaExample: #"{"tool":"mail","to":"name@example.com","subject":"Hello","body":"draft text"}"#,
            description: "compose a Mail draft; never sends automatically.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates and opens an Apple Mail draft.",
            observationSummary: "Reports draft creation or AppleScript errors.",
            exampleUtterance: "draft an email to Alex saying I'll be late"
        ),
        PaceLocalToolDefinition(
            kind: .things,
            canonicalName: "things",
            aliases: ["things_todo"],
            schemaExample: #"{"tool":"things","title":"Buy milk","notes":"optional"}"#,
            description: "create a Things to-do if Things is installed.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Creates a Things to-do with AppleScript.",
            observationSummary: "Reports creation or missing-app/errors.",
            exampleUtterance: "add buy milk to my Things inbox"
        ),
        PaceLocalToolDefinition(
            kind: .messages,
            canonicalName: "messages",
            aliases: ["message"],
            schemaExample: #"{"tool":"messages","recipient":"Alex","text":"draft text"}"#,
            description: "open Messages and prepare a conversation; sending must be explicit.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Opens Messages or prepares a message draft.",
            observationSummary: "Reports whether Messages was opened.",
            exampleUtterance: "open Messages with Alex"
        ),
        PaceLocalToolDefinition(
            kind: .startTimer,
            canonicalName: "start_timer",
            aliases: ["timer", "set_timer"],
            schemaExample: #"{"tool":"start_timer","duration":"3 minutes","label":"tea"}"#,
            description: "schedule a spoken nudge after a duration. duration accepts \"3 minutes\", \"30s\", \"2 hours\", or a plain seconds number.",
            riskLevel: .appOrSystemMutation,
            executionSummary: "Schedules an in-process Timer that fires a spoken nudge through TTS.",
            observationSummary: "Reports the scheduled fire time, or a validation error if the duration was unparseable.",
            exampleUtterance: "set a 5 minute timer for tea"
        )
    ]
}
