# What Pace Can Do

Pace's abilities split into two layers: **tools** (discrete actions it executes)
and **capability classes** (whole behaviors that aren't single tools). The tools
are the canonical, drift-checked list; the classes are the surrounding system.

`docs/architecture/overview.md` is the system map. This page is the user-facing "what can
I ask it" reference.

## Tools (the action catalog)

The 29 local tools live in `PaceToolRegistry.localTools` and are surfaced,
auto-generated, in **Command Center → Use Pace → Automations** (every tool has a name, an
example utterance, and a risk badge). Startup validation refuses to launch if
any tool lacks an example utterance, so the Skills tab can never go stale.

Grouped:

- **Screen control** — click, double-click, scroll, type text, press keys, snap window
- **Apps & web** — open app (`open_app`), open URL (`open_url`), open Messages, open/reveal in Finder
- **System** — volume, brightness, Music control, read clipboard, undo last edit
- **Productivity** — Calendar read/create, reminders, Apple Notes (create/append/search), Mail draft, Things to-do, run a Shortcut
- **Text editing** — dictate into the focused field, voice-edit selected text ("make this more concise")
- **Utility** — start a timer, download a file to ~/Downloads, record/run a saved flow, call an MCP tool

Multi-action commands ride in a single planner response (the v10 envelope's
`payload.calls`), not across multiple turns — see
[conversation-model.md](conversation-model.md) for why.

## Capability classes (beyond tools)

**Native interaction surfaces** — first launch opens a skippable three-scene
journey: Pace's local signal, three live macOS permissions, then one editable
typed or spoken request sent through the same real request and approval path as
everyday use. A real response or completed action hands off into the persistent
Living Notch signal; blocked and failed turns remain visible without a fake
success moment. On a notched MacBook, the idle surface exactly matches the
camera housing and adds compact state and signal wings beside it on hover or
while Pace is active. On click, the same clipped surface extends equally left,
right, and downward to reveal the complete quick panel. Pace
does not draw a fake notch on other displays; the global shortcut still opens
the centered quick panel. Everyday use stays in the notch and present-turn quick panel. Durable work,
history, privacy, customization, and help live in one searchable, resizable
Command Center that shows at most four primary choices per group and places
advanced integrations behind progressive disclosure. It remembers the last destination. Blue means the active turn
is local; amber explicitly marks an enabled off-device planner boundary. All
cinematic travel has a Reduce Motion alternative, and the introduction can be
replayed from the Command Center without clearing permissions or data.

**Understanding the screen** — describe what's on screen, answer questions about
it, point the cursor at / click a named element. Backed by the local VLM +
OCR + AX tree (`PaceScreenContextService`).

**Knowledge & chitchat** — pure-knowledge questions ("what is HTTP?") route to a
fast text-only planner with no screen capture; chitchat gets a canned instant
reply. Routing is `PaceIntentClassifier`.

**Memory** — three distinct layers:
- *Durable preferences* — "remember my preferred browser" (`PaceLocalMemoryStore`)
- *Episodic memory* — lasting facts extracted from turns, surfaced across sessions
- *Conversational thread memory* — this-conversation coherence (see [conversation-model.md](conversation-model.md))

**Time / journal recall** — "what did I do today?" answers from the screen-watch
and app-usage journals (`PaceScreenWatchJournal`, `PaceAppUsageJournal`).

**Local retrieval (RAG)** — grounds answers in your own Calendar, Mail, Notes,
Contacts, Reminders, explicitly-chosen file folders, and past Pace turns
(`PaceLocalRetrieval`). Each source is permission-aware and individually
toggleable; nothing is crawled without an explicit root.

**Modes** — push-to-talk (the floor), always-listening / "hey pace" wake word,
barge-in (interrupt mid-speech by speaking, with echo rejection during TTS
playback), watch mode (observe the screen and emit change events), meeting mode
(capture system audio excluding Pace's own output), in-window chat (text instead
of voice).

**Always-On Companion Mode (default OFF)** — the local evidence/world-model,
memory, and silence-first intervention policy are implemented. Typed evidence
can promote into episodic, semantic, spatial, and routine records; a routine
requires three unique supporting observations. Existing ambient/watch sources
and the production low-rate AVFoundation/Vision camera source emit only
non-identifying person presence and conservative matches for explicitly taught
local Vision feature prints. Ambient voice uses a local pre-STT
Core ML gate that uses the bundled `PaceWakeWordClassifier` with exact labels
`hey_pace` and `background`; missing or invalid assets fail closed before STT.
Accepted wakes enter the bounded conversation path. Silent cards and spoken
interventions are separately default-off; both flow through intervention policy
and speech also passes the live restraint/cooldown path. Hardware and manual
`Cmd+R` acceptance remain unmeasured release follow-ups, not passed checks. See
[companion-mode-privacy.md](companion-mode-privacy.md) for capture, retention,
local-only, correction, and threat-model details and
[companion-mode-dogfood.md](companion-mode-dogfood.md) for acceptance thresholds.

**Proactive surfaces (all default OFF)** — posture watch, focus-fatigue nudges,
calendar pre-meeting nudges, watch-mode observation nudges, the weekday morning
brief. Every one flows through `PaceRestraintGate` (stays silent during a
call / when you're actively typing).

**External integrations (MCP)** — anything a configured Model Context Protocol
server exposes. Configured via `~/.config/pace/mcp-servers.json` or the one-tap
catalog in Settings → MCP (filesystem, fetch, applescript, composio — github/slack/linear route through composio).

**Automation (all default OFF)** — four opt-in automation surfaces in Settings →
General → Automation:
- *Meeting mode* — captures system audio (excluding Pace's own TTS) via SCStream
  so Pace can listen during calls. Voice: "start meeting mode" / "stop meeting
  mode" (`PaceMeetingModeController`).
- *Cron scheduling* — recurring planner tasks on a timer. Voice: "every 30
  minutes check my calendar" (`PaceCronScheduler`).
- *Dynamic plugins* — user-installed shell-command tools from
  `~/Library/Application Support/Pace/plugins/`, with planner-powered auto-repair
  of failed commands (`PaceDynamicToolRegistry`).
- *Background agents* — run headless planner turns in the background. Voice: "in
  the background, draft a reply to..." (`PaceBackgroundAgentRunner`).

**Skills** — `.skill.md` files in `Resources/skills/` define reusable multi-step
workflows that are parsed into planner prompts. Voice: "run the standup skill"
(`PaceSkillLoader`).

**Local automation reuse** — “list my automations” builds a non-persisted local
catalog over bundled typed automations, bounded Pace Programs, recorded flows,
planner-grounded skills, and installed macOS Shortcuts. Each entry discloses
its execution mode. “Run
automation &lt;name&gt;” remains an exact model-free command, while ordinary requests
such as “help me plan my day” or “what does tomorrow look like?” are matched
locally using exact authored aliases and Nomic/Apple sentence embeddings;
token overlap never authorizes execution. Automatic execution requires one candidate above both a confidence
threshold and winner margin; ambiguity falls through without running a catalog
entry unless the on-device Apple language model resolves it confidently or asks
the user to clarify. “Create an automation …” and “teach a skill …” share a
privacy-pinned local authoring ladder: fixed typed calls first, a bounded Pace
Program for simple weekday/hour/frontmost-app branches or literal repetition
second, and a planner-grounded skill when the workflow needs live contextual
interpretation. Every program branch validates before persistence; runs flatten
into the typed action pipeline without invoking a model. Raw Lua, JavaScript,
shell, network, arbitrary file, and direct Accessibility authority are not
available. User typed definitions and programs live in separate Application
Support directories. The 17 bundled
entries span Notes templates, Calendar reads, timers, Finder folders,
current-window layouts, bounded media control, weekly review, and end-of-day
reset. Recorded flows, skills, Shortcuts, cron, and background agents keep their
distinct executors. Catalog metadata never enters planner prompts or
conversation memory (`PaceAutomationCatalog`, `PaceUserAutomationStore`,
`PaceUserProgramStore`, `PaceShortcutsAutomationProvider`).

**Apple Foundation Models tool-calling** — when the planner tier is Apple FM,
multi-step tool calls are serialized from the typed `PaceFMTurnResponse.toolCalls`
array into `<tool_calls>` JSON blocks that the existing action parser executes.

**Telemetry** — E2E turn latency, STT latency, VLM latency, and token throughput
are recorded per turn via `PaceTelemetryLog` and visible in the benchmark script
`scripts/benchmark_ttfsw.sh`.

**Entry points** — voice (PTT/wake word), text (chat), and `pace://` deeplinks
(`listen`, `chat`, `watch`, `panel`) from Raycast / Shortcuts.

## What stays on-device

Everything above is local. The only off-device action is `download_file`, which
fetches a user-named http(s) URL into ~/Downloads on explicit command — and the
opt-in cloud-bridge / Direct-API planner tiers, which are consent-gated and
default-off. See `docs/architecture/overview.md` for the privacy posture.

## How a command is routed (fastest → slowest)

1. **Fast path** (`PaceFastActionCommandParser`) — deterministic, no model, no
   screen: open app/URL/known site, media, volume, brightness, undo, window
   snap, common key shortcuts. Sub-200ms.
2. **Automation parsers** — deterministic, no model: installed Shortcuts ("run
   my Morning Routine shortcut"), cron scheduling ("every 30 minutes..."),
   background agents ("in the background..."), meeting mode ("start meeting
   mode"), skills ("run the standup skill"). Routes to the relevant module
   before the planner.
3. **Text-only planner** — pure-knowledge answers, no screen capture.
4. **Screen pipeline** — VLM + planner, for commands that genuinely need to see
   or act on the screen. The VLM is skipped for launch/navigate verbs that don't
   reference an on-screen element (see `PaceTagParsers.transcriptIsLikelyScreenReferential`).

The Settings → Debug tab shows, per turn, which lane handled it, the latency,
the raw planner output, the parsed tool calls, and the dispatch outcome.
