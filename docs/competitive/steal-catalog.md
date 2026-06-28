# Steal Catalog — Comprehensive

What the field has that Pace doesn't, organized by product direction. Sourced
from deep code-level dives on FluidVoice, OpenSuperWhisper, Handy, all 15
tracked competitors, 51 untracked projects, and 5 research papers (June 2026).

Pace's product thesis (codified here so future agents don't drift):
**Performance-first local command interface for macOS. 100ms perceived
latency for simple commands. Subagents for parallel work. Jarvis-like
ambient intelligence. Skills as a first-class extensibility surface.
Conversation exists but is a second-class citizen.**

---

## 1. Subagents & Parallel Agent Orchestration

Pace today: single-threaded agent loop. One planner turn → one tool → observe → next turn.

### Shiro — Parallel sub-agents with atomic SQL checkout
- Each sub-agent gets a persona injection, depth guard, and token budget
- Atomic SQL checkout so sub-agents don't stomp each other's state
- Coordinator spawns N parallel workers, merges results
- **Why steal:** "Research X, Y, and Z simultaneously" becomes one turn instead of three sequential turns. Cuts wall-clock time for complex tasks.
- **Complexity:** Large — needs a sub-agent coordinator, state isolation, result merging

### VoiceAgentRAG — Dual-agent (Slow Thinker + Fast Talker)
- Slow Thinker runs in background, predicts follow-up topics, pre-fetches RAG results into FAISS cache
- Fast Talker reads from sub-millisecond cache for the actual response
- Memory Router orchestrates which agent handles which turn
- **Why steal:** This is the architecture for hitting 100ms on RAG-backed turns. The slow agent pre-computes while the user is still talking; the fast agent serves from cache.
- **Complexity:** Large — needs a background pre-fetch engine + semantic cache

### Clicky — Background agents that run while you keep working
- Queue a task ("build a Mac app", "file a Linear ticket") → it runs headless → notifies on completion
- User keeps working in the foreground; agent doesn't block
- **Why steal:** We already have `PaceBackgroundAgentRunner` but it's single-task. The pattern to steal is the *queue + notify* UX — multiple background agents with progress and completion notifications.
- **Complexity:** Medium — extends existing `PaceBackgroundAgentRunner`

### AutoClawd — Persistent per-project knowledge base (markdown world model)
- Each project gets a markdown knowledge base that sub-agents read/write
- Agents persist findings between runs
- **Why steal:** Subagents need shared memory. A per-project markdown knowledge base is the simplest durable shared state.
- **Complexity:** Medium

### LLM-Driven Voice Agents That Collaboratively Talk — Multi-agent vocal resolution
- Specialized voice agents converse with each other to resolve a request
- Central coordinator routes sub-questions to domain experts
- **Why steal:** "Ask the code agent and the calendar agent to coordinate" — multi-expert routing is the user's original `assistant` repo vision.
- **Complexity:** Large

### Recommended for Pace
1. **Sub-agent coordinator** (from Shiro) — spawn N parallel planner turns with budgets, merge results. Start with 2-3 max parallel.
2. **Background agent queue** (from Clicky) — extend `PaceBackgroundAgentRunner` to a multi-slot queue with progress + completion notifications.
3. **Dual-agent pre-fetch** (from VoiceAgentRAG) — background agent pre-computes likely-next-turn context while user is speaking. This is the 100ms enabler for complex turns.

---

## 2. Jarvis-Like Ambient Intelligence & Personality

Pace today: reactive only. User speaks → Pace responds. No ambient awareness, no personality.

### goose-perception — 4-stage ambient pipeline
- Capture (screen, voice, face) → Refiners → Insight Generators → Action Generators
- OCR text from focused windows every 20 seconds
- Face detection for presence and emotion tracking
- Wellness monitoring (overwork, stress, late-night patterns)
- Smart action popup notifications
- **Why steal:** This is the "always-on espionage" layer. Pace's `PaceScreenWatchModeController` is on-demand; this is always-on, low-cost ambient sensing.
- **Complexity:** Medium for the capture layer; Large for insight generation

### Ambient (sgunadhya) — Human memory modeling
- Models 4 memory types: Sensory, Episodic, Semantic, Procedural
- Write-Ahead Log (tsink) for OS state logging
- CozoDB for local Graph/Vector backend
- "Semantic Gravity" equation: Vector Similarity + Time Decay + Reinforcement Learning
- Contextual Affordances surfaced to Menubar
- **Why steal:** This is the memory architecture for "Pace remembers everything you did and can recall it contextually." Far beyond our current two-tier thread memory.
- **Complexity:** Large — but the 4-type memory model is a good design framework even without CozoDB

### ambientghost — Work pattern extraction
- Swift daemon observes NSWorkspace notifications
- Pattern extraction: 2-app n-grams grouped by time window
- LLM semantic analysis of patterns
- Confidence threshold (0.75) for suggestions
- Auto time tracking from window titles
- Work reconstruction (daily standups, timesheets)
- **Why steal:** "What did I do today?" answered from passive observation. We have `PaceAppUsageTracker` but not pattern extraction or semantic analysis.
- **Complexity:** Medium

### AutoClawd — Three modes (Ambient, AI Search, Learn)
- Ambient: full always-on pipeline
- AI Search: voice Q&A
- Learn: FUCBC mode (follow user, build context, complete)
- **Why steal:** The mode separation is clean. Pace could have Ambient (always-on espionage) / Command (fast tool execution) / Conversational (second-class citizen) modes.
- **Complexity:** Medium

### JARVIS (ethanplusai) — Personality + audio-reactive particle orb
- British accent personality, dry wit
- Audio-reactive 3D particle orb visualization
- Direct Claude Code integration
- **Why steal:** Personality makes the assistant feel alive. The particle orb is a visual differentiator. We have `GlowBorderWindow` but it's phase-signaling, not personality.
- **Complexity:** Medium for personality (system prompt engineering); Large for 3D orb

### autoclaw — Fn key prediction cards
- Press Fn → shows prediction cards based on session context
- Reads CLAUDE.md, live session JSONL, coding tempo
- Invisible engineering layer between user and Claude Code
- **Why steal:** "Predict what the user needs before they speak." This is the proactive surface that makes Pace feel like Jarvis.
- **Complexity:** Medium

### EnConvo — Context-aware SmartBar
- @ for commands, # for contextual, > for recent chats
- Transforms installed apps into AI Agents
- Context awareness: active apps, selected text, Finder files, open web pages
- **Why steal:** The @/#/> command syntax is a clean UX pattern for a command-first interface.
- **Complexity:** Medium

### Recommended for Pace
1. **Always-on ambient layer** (from goose-perception + ambientghost) — AX tree polling every 2-3s, window/document title tracking, notification observer, clipboard change observer, FS watchers. Low cost, high value.
2. **4-type memory model** (from Ambient) — Sensory (raw screen/audio), Episodic (what happened when), Semantic (extracted facts), Procedural (how to do things). Design framework for upgrading our memory.
3. **Prediction cards** (from autoclaw) — Fn key shows context-aware suggestions before user speaks. This is the "Jarvis knows what you need" surface.
4. **Personality** (from JARVIS) — system prompt engineering for a distinct persona. Small investment, big product feel.

---

## 3. Top Performance (100ms Target)

Pace today: ~600ms-1.8s end-to-end. Sequential pipeline.

### RCLI — Sub-200ms via MetalRT
- Proprietary MetalRT GPU engine, 550 tok/s
- Sub-200ms end-to-end voice latency
- **Why steal:** The benchmark. We can't copy the engine (closed-source), but the target is real. Apple FM + Apple Speech + speculative execution can get us there for simple turns.
- **Complexity:** N/A (benchmark, not code to steal)

### Ichigo — 111ms to first token via mixed-modal early-fusion
- Uniform transformer: speech + text as discrete tokens
- WhisperVQ for speech quantization
- Cross-modal reasoning without adapters
- **Why steal:** The research direction. Early-fusion (speech tokens directly into the LLM) eliminates the STT→LLM serialization. Future architecture if/when we ship a custom model.
- **Complexity:** Large (research, not implementation-ready)

### Handy — Lazy stream close with generation counter
- Keeps microphone stream open for 30s after recording stops
- Generation counter cancels pending closes if new recording starts
- **Why steal:** Eliminates audio stream reinit latency for back-to-back commands. ~100-200ms saved on second command.
- **Complexity:** Small

### Handy — Model idle watcher with auto-unload
- Background thread checks every 10s
- Unloads models after configurable idle timeout (Never/2min/5min)
- Skips unload if recording active
- **Why steal:** Memory management for large models. Frees RAM when user isn't talking, reloads fast when they are.
- **Complexity:** Medium

### Handy — Single-thread lifecycle coordinator
- All events (keyboard, signals, async pipeline) serialized through one mpsc channel
- Eliminates race conditions between trigger sources
- **Why steal:** Pace has scattered delegate callbacks. A single coordinator prevents the race classes we've been patching individually.
- **Complexity:** Small

### Handy — RAII finish guard for panic recovery
- `FinishGuard` struct implements `Drop`, calls `notify_processing_finished()`
- Guarantees coordinator doesn't hang in "Processing" state even on panic
- **Why steal:** Robustness. If a planner turn panics, the agent loop doesn't get stuck.
- **Complexity:** Small

### FluidVoice — Stable prompt prefix KV cache
- Caches prompt prefix in KV cache for local models
- Repeated dictation with same prompt → significant speedup
- **Why steal:** Our system prompt is ~2K tokens and stable. KV-caching it means only the user turn needs to be processed. Major latency win for local planner.
- **Complexity:** Small (if LM Studio / MLX supports it)

### FluidVoice — Audio startup gate
- Actor with `isOpen` flag, delays CoreAudio init 2s after launch
- Prevents EXC_BAD_ACCESS during SwiftUI metadata processing
- **Why steal:** Crash prevention at launch. Audio init races with SwiftUI on some Macs.
- **Complexity:** Small

### FluidVoice — Hotkey health check timer
- 30s periodic check that event tap is functional
- Auto-restart on failure with exponential backoff
- **Why steal:** Event taps fail silently. Health check ensures PTT keeps working.
- **Complexity:** Small

### OpenSuperWhisper — Parallel audio conversion
- Files >10s split by CPU core count
- `DispatchQueue.concurrent` workers, lock-protected writes
- 609% speedup on 8 cores
- **Why steal:** If we ever process long audio (meeting transcription, file transcription), this pattern cuts processing time dramatically.
- **Complexity:** Medium

### OpenSuperWhisper — Multi-channel audio mixing with RMS energy detection
- Calculates RMS per channel, only mixes active channels
- Avoids silent channels degrading quality
- **Why steal:** Better STT accuracy from multi-mic setups (MacBook mic + external).
- **Complexity:** Medium

### Recommended for Pace
1. **STT-during-speech** — process audio chunks via VAD segmentation while user is still talking, commit on silence. Biggest single latency win (~200ms).
2. **Lazy stream close** (from Handy) — keep mic stream open 30s after last command. Saves ~100-200ms on back-to-back commands.
3. **KV cache for system prompt** (from FluidVoice) — cache the ~2K-token system prompt prefix. Saves ~100-300ms on local planner turns.
4. **Single-thread lifecycle coordinator** (from Handy) — serialize all PTT/signal/pipeline events. Prevents races, simplifies state management.
5. **Speculative tool execution** — for high-confidence rule-based commands, execute before planner confirms. Saves ~300-500ms.
6. **Pre-warmed Apple FM session** — keep session hot between turns. Saves ~100ms.

---

## 4. Skills System (First-Class)

Pace today: `PaceSkillLoader` parses `.skill.md` files. Basic.

### OpenFelix — Skill system with auto-install
- Skills auto-install on first run
- Shares OpenClaw format (community ecosystem)
- **Why steal:** Community skill sharing. If we adopt a standard format, users can share skills.
- **Complexity:** Medium

### Ari (Windows) — SKILL.md skills + plugins + MCP
- Skills defined in SKILL.md files
- Plugins for extensibility
- MCP for external tools
- Three-tier extensibility
- **Why steal:** The three-tier model (skills = prompt templates, plugins = code, MCP = external servers) is clean. We have all three but they're not positioned as a unified extensibility story.
- **Complexity:** Small (positioning, not new code)

### local-jarvis — #[skill] proc-macro for skills
- Rust proc-macro that auto-registers functions as skills
- Skills are typed, compiled, not just markdown
- **Why steal:** For compiled skills (Swift equivalent would be a macro or code-gen), type safety and IDE support. Markdown skills are good for prompt templates; compiled skills for real logic.
- **Complexity:** Large (Swift doesn't have proc-macros; would need code-gen)

### OpenClicky — Bundled skills + wiki seed in AppResources
- Ships with pre-packaged skills and a knowledge seed
- Users get useful capabilities immediately
- **Why steal:** We have `Resources/recipes/` and `Resources/skills/standup-notes.skill.md`. Expand the bundled catalog.
- **Complexity:** Small (content, not code)

### Recommended for Pace
1. **Expand bundled skill catalog** — ship 10-20 skills out of the box (standup, email-zero, focus-mode, code-review, meeting-notes, etc.)
2. **Skill marketplace format** — adopt/extend the `.skill.md` format so skills are portable. Version field, dependency field, author field.
3. **Three-tier extensibility positioning** — Skills (prompt templates) / Plugins (shell commands via `PaceDynamicToolRegistry`) / MCP (external servers). Make this visible in Settings.
4. **Skill composition** — skills should be able to invoke other skills and tools. "Run the standup skill" → skill calls calendar tool, notes tool, TTS.

---

## 5. STT (Speech-to-Text)

Pace today: Apple `SFSpeechRecognizer` (on-device, batch, no streaming).

### FluidVoice — Parakeet Realtime (FluidAudio) streaming STT
- True streaming via CoreML, 160ms chunks
- Near-zero latency between speaking and seeing words
- Delta processing: only processes new audio samples
- **Why steal:** Fastest STT on Mac. If we add Parakeet as a provider, this is the streaming path.
- **Complexity:** Large (CoreML model integration)

### FluidVoice — macOS 26 SpeechAnalyzer
- New `SpeechAnalyzer` API (macOS 26+)
- Streaming with model download via AssetInventory
- Buffer conversion for format compatibility
- **Why steal:** When we target macOS 26, this is the native streaming STT successor to SFSpeechRecognizer.
- **Complexity:** Medium

### FluidVoice — Vocabulary boosting with CTC models
- JSON-backed vocabulary config
- Terms with weights and aliases
- CTC tokenization for custom terms
- **Why steal:** Dramatically improves recognition of names, jargon, project-specific terms. "Pace", "CompanionManager", "qwen3-30b-a3b" should be in the vocabulary.
- **Complexity:** Medium

### OpenSuperWhisper — Multi-engine architecture with protocol abstraction
- `TranscriptionEngine` protocol: initialize, transcribe, cancel, getSupportedLanguages
- Engine selection persisted, hot-swappable
- **Why steal:** We have a provider layer but it's Apple Speech or nothing. A clean protocol makes adding Parakeet/Whisper/SpeechAnalyzer trivial.
- **Complexity:** Medium

### OpenSuperWhisper — Single-modifier PTT (Left Cmd, Fn, Right Option)
- CGEvent tap with `kCGEventFlagChanged` mask
- Maps modifier keys to specific keycodes
- Hold-to-record vs toggle configurable
- **Why steal:** Much more ergonomic than ctrl+option. Fn as PTT is the Dottie pattern.
- **Complexity:** Medium

### FluidVoice — Modifier-only shortcut with hold detection
- Press-and-hold on modifier keys (hold Option to dictate)
- Tap vs hold distinction
- Automatic press simulation for continuous dictation
- **Why steal:** Even better than single-modifier — hold to dictate, tap to toggle. Best ergonomics.
- **Complexity:** Medium

### Recommended for Pace
1. **STT provider protocol** (from OpenSuperWhisper) — abstract the engine so Parakeet/Whisper/SpeechAnalyzer can be added.
2. **Vocabulary boosting** (from FluidVoice) — add "Pace", project names, tool names to STT vocabulary.
3. **Single-modifier PTT** (from OpenSuperWhisper) — Fn as PTT option.
4. **Parakeet Flash as provider** (from FluidVoice) — fastest STT on Mac, ~200ms.

---

## 6. Typing & Text Insertion

Pace today: basic CGEvent typing.

### FluidVoice — Multi-method text insertion pipeline
- PID-targeted CGEvent → AX → HID → Clipboard → char-by-char
- Fallback chain ensures text always gets inserted
- **Why steal:** Maximum app compatibility. Some apps reject CGEvent.
- **Complexity:** Medium

### FluidVoice — Focus snapshot & restoration
- Captures focused element before overlay interaction
- Restores focus after overlay dismisses
- Queue-based snapshot storage for thread safety
- **Why steal:** Prevents focus loss when showing overlays. Critical for seamless workflow.
- **Complexity:** Medium

### FluidVoice — Clipboard session management with restore
- Saves full clipboard state (all types, not just text)
- Restores after paste-based insertion
- Semaphore for concurrent access safety
- **Why steal:** Using clipboard for text insertion disrupts user's clipboard. Restore preserves their data.
- **Complexity:** Small

### FluidVoice — Layout-aware key code lookup
- TIS (Text Input Services) API scans keyboard layout
- Maps characters to virtual key codes for current layout
- QWERTY fallback for non-Latin layouts
- **Why steal:** Essential for international users. Cmd+V fails on Dvorak/Russian without this.
- **Complexity:** Small

### FluidVoice — Text-before-cursor capture for capitalization
- AX to get text before cursor in focused field
- Determines if next word should be capitalized
- **Why steal:** Improves continuous dictation quality. Context-aware capitalization.
- **Complexity:** Small

### FluidVoice — AX-based text selection with range fallback
- Primary: `kAXSelectedTextAttribute`
- Fallback: `kAXSelectedTextRangeAttribute` + `kAXValueAttribute` (reconstructs from range)
- **Why steal:** Works across more apps. Enables "rewrite this" / "edit selection" mode.
- **Complexity:** Small

### OpenSuperWhisper — Caret position detection for UI placement
- AX `kAXBoundsForRangeParameterizedAttribute` to get caret bounds
- Coordinate conversion from AX (top-left) to Cocoa (bottom-left)
- **Why steal:** Place indicators/overlays near cursor instead of fixed position.
- **Complexity:** Medium

### Handy — Multiple paste methods with fallback
- CtrlV, Direct, ShiftInsert, CtrlShiftV, ExternalScript
- Configurable per app
- **Why steal:** Different apps need different paste methods (terminals use Shift+Insert).
- **Complexity:** Medium

### Handy — Auto-submit with configurable key
- Enter / Ctrl+Enter / Cmd+Enter after paste
- 50ms delay after paste before submit
- **Why steal:** Voice agents often need to submit forms or send messages. Reduces friction.
- **Complexity:** Small

### Recommended for Pace
1. **Multi-method typing pipeline** (from FluidVoice) — fallback chain for max compatibility.
2. **Clipboard restore** (from FluidVoice) — save/restore clipboard around paste-based insertion.
3. **Text selection capture** (from FluidVoice) — enables rewrite/edit mode.
4. **Layout-aware key codes** (from FluidVoice) — international keyboard support.
5. **Auto-submit** (from Handy) — Enter after paste for chat/message apps.

---

## 7. UX & Visualization

Pace today: menu-bar capsule + notch overlay + glow border.

### FluidVoice — Multi-mode notch with state machine
- Modes: dictation, edit, rewrite, write, command
- State machine: idle → showing → visible → hiding
- Generation counter to invalidate stale operations
- Compact vs expanded presentation per screen type
- Bottom overlay alternative for non-notch Macs
- **Why steal:** The state-machine race prevention is production-tested. Multi-mode is what Priority 13 (Premium UI) needs.
- **Complexity:** Medium

### FluidVoice — Expanded command output in notch
- Separate notch instance for full conversation history
- Chat management (new/switch/clear) from notch
- Recent chats dropdown
- **Why steal:** Review full agent conversation in notch without opening a window.
- **Complexity:** Medium

### FluidVoice — Step-based agent execution with UI-visible state
- AgentStep enum: thinking, checking, executing, verifying, completed
- Each step type has distinct UI
- Tool calls include `purpose` field for step classification
- **Why steal:** User visibility into what the agent is doing. Builds trust during long tasks.
- **Complexity:** Medium

### FluidVoice — Streaming UI with thinking token separation
- Separate buffers for thinking tokens vs content
- Adaptive throttling based on content length
- Model-specific thinking token parsers (Standard, Nemo, SeparateField)
- **Why steal:** Real-time reasoning visibility. Handles different model thinking formats.
- **Complexity:** Medium

### ORB — Glow border phase signaling
- Glowing border around screen: listening / planning / executing
- **Why steal:** We have `GlowBorderWindow` but it's basic. ORB's phase signaling is the polished version.
- **Complexity:** Small (we mostly have this)

### JARVIS — Audio-reactive particle orb
- 3D particle visualization reacting to audio
- Multiple visualizer styles (Orb / Particles / Wave Rings)
- **Why steal:** The "Jarvis feel." A visual differentiator that makes Pace feel alive.
- **Complexity:** Large (3D rendering)

### LocalNotch — Hover-to-open notch
- Hover over notch → opens panel
- Type to ask → disappears
- Zero window management
- **Why steal:** Even more minimal than click-to-open. Frictionless interaction.
- **Complexity:** Small

### EnConvo — SmartBar with @/#/> syntax
- @ for commands, # for contextual, > for recent chats
- **Why steal:** Clean command syntax for a command-first interface.
- **Complexity:** Medium

### Recommended for Pace
1. **Multi-mode notch state machine** (from FluidVoice) — the foundation for Priority 13.
2. **Step-based agent execution UI** (from FluidVoice) — show thinking/checking/executing/verifying.
3. **Streaming thinking tokens** (from FluidVoice) — real-time reasoning visibility.
4. **Audio-reactive visualizer** (from JARVIS) — the Jarvis feel. Start with 2D, iterate to 3D.

---

## 8. Memory & Context

Pace today: two-tier thread memory (K=4 verbatim + rolling summary), survives quit/relaunch.

### Ambient — 4-type human memory modeling
- Sensory: raw screen/audio captures
- Episodic: what happened when (timestamps + events)
- Semantic: extracted facts and relationships
- Procedural: how to do things (learned workflows)
- **Why steal:** Far beyond our conversation-only memory. Enables "Pace remembers your projects, your habits, your preferences."
- **Complexity:** Large

### Shiro — Hybrid RAG knowledge graph (sqlite-vec + FTS5)
- Vector + keyword search in one SQLite file
- Live knowledge graph updates on every tool call
- **Why steal:** Rich memory that queries can reason over. Better than our flat JSON thread memory.
- **Complexity:** Large

### Impulse — Per-project SwiftData memory
- Conversations scoped to projects
- SwiftData schema with project relationships
- **Why steal:** Developers work on multiple projects. Per-project context isolation is natural.
- **Complexity:** Medium

### RCLI — Local RAG (hybrid vector + BM25)
- ~4ms retrieval over 5K+ chunks
- Local embedding model
- **Why steal:** Document intelligence. "Search my notes and emails for X." We have BM25 but not vector search.
- **Complexity:** Large

### ambientghost — Work pattern n-grams
- 2-app n-grams grouped by time window
- LLM semantic analysis of patterns
- Confidence threshold for suggestions
- **Why steal:** "When you open Xcode after Slack, you usually want to..." — pattern-based predictions.
- **Complexity:** Medium

### Recommended for Pace
1. **Per-project memory** (from Impulse) — scope conversations and context to projects.
2. **4-type memory model** (from Ambient) — design framework for upgrading memory beyond conversation.
3. **Local RAG with vector search** (from RCLI/Shiro) — query documents, notes, emails locally.
4. **Work pattern extraction** (from ambientghost) — predict what user needs from observation patterns.

---

## 9. MCP & Extensibility

Pace today: stdio MCP client, 6-server bundled catalog.

### Vox — MCP client (stdio, SSE, HTTP)
- Full transport support across all three types
- **Why steal:** We only support stdio. SSE/HTTP enable remote MCP servers.
- **Complexity:** Medium

### axmcp — Three AX-focused MCP servers
- axmcp (any app), xcmcp (Xcode/simulators), computer-use-mcp (Codex contract)
- 20+ AX tools: ax_apps, ax_tree, ax_find, ax_click, ax_type, ax_menu, etc.
- **Why steal:** Comprehensive AX automation via MCP. Could replace some of our hand-built tools.
- **Complexity:** Medium

### AXorcist — Chainable AX queries with fuzzy matching
- Type-safe API with compile-time safety
- Chainable queries, path-based locators
- Real-time change monitoring
- Batch operations
- **Why steal:** Our AX code is imperative. A chainable, fuzzy-matched query API would be much cleaner.
- **Complexity:** Medium

### axcli — Playwright/Puppeteer-style API for macOS apps
- snapshot → read → act → verify workflow
- Background-safe via CGEventPostToPid
- Multiple click strategies (auto/ax/cg/cg-pid)
- Watch mode for AX notifications
- **Why steal:** The snapshot→read→act→verify loop is the right abstraction for AX automation.
- **Complexity:** Medium

### computer-use-mcp — Layered input ladder
- AX action → per-window event → per-PID event → global cursor
- Background-safe (doesn't move real cursor or steal focus)
- z-order hit-testing for apps with poor AX trees
- **Why steal:** Background-safe automation is critical for subagents. They shouldn't move the user's cursor.
- **Complexity:** Medium

### Open Claudex — App-aware virtual cursor overlay
- Shows virtual cursor for the agent, separate from real cursor
- Post-action screenshots for verification
- Works with logged-in Chrome profile
- **Why steal:** Visual feedback for background agent actions without disrupting user.
- **Complexity:** Medium

### Recommended for Pace
1. **SSE/HTTP MCP transport** (from Vox) — enable remote MCP servers.
2. **Layered input ladder** (from computer-use-mcp) — background-safe automation for subagents.
3. **AX query API** (from AXorcist/axcli) — chainable, fuzzy-matched AX queries.
4. **Virtual cursor overlay** (from Open Claudex) — visualize subagent actions without disrupting user.

---

## 10. Screen Understanding

Pace today: VLM screenshot + AX element map, on-demand.

### Fazm — AX API control (300+ apps)
- Structured UI tree, not screenshots
- More reliable, more token-efficient
- **Why steal:** We use AX for clicks but VLM for understanding. Fazm proves AX-first is viable for full understanding.
- **Complexity:** Large (but we have `PaceAXScreenReader` as a foundation)

### OmniParser (Microsoft) — Screen parsing for vision agents
- Interactive Region Detection Model
- Icon functional description model
- Predicts whether elements are interactable
- **Why steal:** Better than our raw VLM screenshot. Structured region detection + icon descriptions.
- **Complexity:** Large

### UiPath Screen Agent — Two-stage architecture
- Action Planner (high-level reasoning) + UI Element Grounder (low-level execution)
- Crop-and-refine method for precise grounding
- **Why steal:** Separating "what to do" from "where exactly to click" is the right architecture. Our planner does both in one pass.
- **Complexity:** Large

### ScreenAgent — Three-phase pipeline (planning, execution, reflection)
- Planning → Acting → Reflecting loop
- Reflection inspired by Kolb's experiential learning
- **Why steal:** We have plan → act → observe. Adding explicit reflection ("did that work? what should I do differently?") improves success rate.
- **Complexity:** Medium

### Sai — Pure vision-based approach
- Doesn't parse HTML/DOM, operates at visual layer
- Multi-step Plan → Act → Verify loop
- **Why steal:** For apps with poor AX trees, pure vision is the fallback. Our Set-of-Mark recovery is a step toward this.
- **Complexity:** Medium (we have the infrastructure)

### eye2byte — Context Packs
- Multi-monitor capture (active/specific/all)
- Voice narration with noise removal
- Annotations (arrows, circles, rectangles, freehand, text)
- Screen clips with keyframe extraction
- Image optimization (5x smaller, zero quality loss)
- **Why steal:** Rich context capture for the planner. Annotations let user point at things.
- **Complexity:** Medium

### Recommended for Pace
1. **AX-first understanding** (from Fazm) — use AX tree as primary, VLM as fallback. More reliable, more token-efficient.
2. **Two-stage grounding** (from UiPath) — separate "what to click" (planner) from "where exactly" (grounder).
3. **Reflection phase** (from ScreenAgent) — add explicit "did that work?" to the agent loop.
4. **Context packs** (from eye2byte) — rich screen + voice + annotation capture.

---

## 11. Dictation Fast Path

Pace today: agent-first. Every turn goes through the planner.

### FluidVoice — Dictation post-processing pipeline
- STT → AI enhancement (formatting, capitalization, punctuation) → paste
- No planner, no screen capture, no VLM
- Provider abstraction (local AI, Apple Intelligence, cloud)
- **Why steal:** The 80% of voice turns that are just "type this" don't need the planner. Sub-500ms.
- **Complexity:** Medium

### FluidVoice — Rewrite mode (text selection → LLM → replace)
- Capture selected text via AX
- Send to LLM with rewrite prompt
- Replace selection with result
- **Why steal:** "Make this more formal" / "fix the grammar" — a whole new interaction mode.
- **Complexity:** Small

### FluidVoice — App-aware prompt routing
- Different system prompts per app (formal for Mail, casual for Slack)
- Prompt routing scope: all apps vs selected apps
- **Why steal:** Context-aware dictation. The dictation fast path should adapt to the target app.
- **Complexity:** Medium

### FluidVoice — Prompt test coordinator
- Intercept hotkey to test prompts without typing to other apps
- Shows raw transcription, processed output, errors
- **Why steal:** Critical for prompt engineering. Test dictation prompts without disrupting workflow.
- **Complexity:** Small

### Recommended for Pace
1. **Dictation fast path** (from FluidVoice) — STT → Apple FM cleanup → paste. No planner. Sub-500ms.
2. **Rewrite mode** (from FluidVoice) — capture selection → LLM → replace.
3. **App-aware prompts** (from FluidVoice) — different cleanup prompts per target app.
4. **Prompt test mode** (from FluidVoice) — test dictation prompts without side effects.

---

## 12. Distribution & Infrastructure

Pace today: build-from-Xcode, no OTA updates.

### OpenClicky / Ora — Sparkle OTA updates
- Signed appcast.xml for automatic updates
- Downloadable DMG releases
- **Why steal:** Users can't get updates without rebuilding. Sparkle is the macOS standard.
- **Complexity:** Medium

### MacTalk — Signed & notarized DMG builds
- Proper macOS distribution with code signing and notarization
- **Why steal:** Required for distribution outside of build-from-source.
- **Complexity:** Medium

### McClaw — CLI Bridge architecture (~30MB RAM)
- Delegates to official CLI tools (Claude, Codex, etc.)
- No background server, instant launch, near-zero CPU at idle
- **Why steal:** Our LM Studio sidecar is heavy. A CLI bridge to existing tools is lighter.
- **Complexity:** Medium

### your-local-agent — One-command installation
- curl script detects hardware (RAM, chip, disk)
- Auto-downloads right model for exact hardware
- Configures everything and wires shell aliases
- **Why steal:** Frictionless first-run. Hardware detection + auto-config.
- **Complexity:** Medium

### Recommended for Pace
1. **Sparkle OTA updates** (from OpenClicky/Ora) — signed appcast, auto-update.
2. **Signed & notarized DMG** (from MacTalk) — proper distribution.
3. **Hardware-aware first-run** (from your-local-agent) — detect RAM/chip, recommend model.

---

## 13. Security & Trust

Pace today: approval gates, undo banners, failure narration, privacy dashboard.

### FluidVoice — Provider fingerprinting for verification
- SHA256 of (baseURL + apiKey) to detect credential changes
- Requires re-verification after changes
- **Why steal:** Ensures API keys are verified before use. Detects when user changes credentials.
- **Complexity:** Small

### FluidVoice — Local endpoint detection
- Auto-detects localhost/private IP ranges
- Skips API key requirement for local endpoints
- **Why steal:** UX improvement. No API key needed for LM Studio / Ollama.
- **Complexity:** Small

### Handy — SecretMap with Debug redaction
- Custom Debug impl shows `[REDACTED]` for non-empty values
- Prevents accidental API key leaks in logs/crash reports
- **Why steal:** Security. We use Keychain but should also redact in debug output.
- **Complexity:** Small

### MCP Client for Azure — Tool Approval Dialog
- Allow / Allow All / Deny per tool
- OAuth2 flow for server authorization
- **Why steal:** Granular tool approval. We have approval gates but not per-tool "allow all" scope.
- **Complexity:** Small

### Jarvis (Linux) — Command whitelisting + allowed directories
- Only specific commands allowed
- File access restricted to configured directories
- **Why steal:** Sandboxing for tool execution. Limits blast radius.
- **Complexity:** Medium

### Recommended for Pace
1. **Provider fingerprinting** (from FluidVoice) — detect credential changes.
2. **Debug redaction** (from Handy) — redact secrets in all debug output.
3. **Per-tool "allow all" scope** (from MCP Client for Azure) — reduce approval fatigue.
4. **Command whitelisting** (from Jarvis) — sandbox for dynamic plugins.

---

## 14. Internationalization

Pace today: English-only.

### Handy — Full i18n with 10+ languages
- i18next with ESLint enforcement (no hardcoded strings)
- Community translation contributions
- **Why steal:** If we go beyond English, this is the model.
- **Complexity:** Large

### OpenSuperWhisper — Asian language autocorrect
- `huacnlee/autocorrect` for CJK punctuation/spacing
- C library wrapper
- **Why steal:** Fixes common STT spacing issues in Chinese/Japanese/Korean.
- **Complexity:** Small

### Handy — Chinese variant conversion (Simplified ↔ Traditional)
- OpenCC library for character conversion
- Auto-converts based on selected language
- **Why steal:** If we support Chinese, this is essential.
- **Complexity:** Small

### OpenSuperWhisper — Keyboard layout detection
- Detects ANSI/ISO/JIS physical keyboard type
- Resolves key labels for current layout
- Visual keyboard for onboarding
- **Why steal:** Foundation for international keyboard support.
- **Complexity:** Medium

### Recommended for Pace
1. **Keyboard layout detection** (from OpenSuperWhisper) — foundation for international support.
2. **CJK autocorrect** (from OpenSuperWhisper) — if adding Asian language support.
3. **i18n framework** (from Handy) — when ready for multi-language.

---

## 15. Misc Quality Patterns

### FluidVoice — Chat session management with switching
- Multiple independent chat sessions
- Create/switch/delete/persist
- Can't switch while processing
- **Why steal:** Multiple concurrent agent conversations (one for coding, one for research).
- **Complexity:** Medium

### FluidVoice — Turn-limited agent loop
- Hard limit (20 turns) prevents infinite loops
- Auto-save after each turn
- **Why steal:** Prevents runaway agent loops. We should have this.
- **Complexity:** Small

### FluidVoice — Destructive command confirmation
- Auto-detects rm, git clean, etc.
- Requires confirmation before execution
- **Why steal:** Safety for terminal/shell commands. We have approval gates but not destructive-command detection.
- **Complexity:** Small

### FluidVoice — Post-transcription edit tracking
- Detects if user immediately edits (backspace/Cmd+A) freshly-typed output
- Time window based on word count
- Privacy: only metadata, no content
- **Why steal:** Quality metric. If user edits Pace's output, the model/prompt needs improvement.
- **Complexity:** Small

### FluidVoice — Model-specific thinking token parsers
- StandardThinkingParser (`<think>` tags)
- NemoThinkingParser (no opening tag)
- SeparateFieldThinkingParser (reasoning_content field)
- ThinkingParserFactory selects by model name
- **Why steal:** Handles diverse model formats. We use qwen3 and Apple FM; adding models means handling their thinking formats.
- **Complexity:** Medium

### Handy — Configurable reasoning effort
- `ReasoningConfig` with effort (OpenAI-style) and exclude (OpenRouter-style)
- Disable reasoning for simple tasks, enable for complex
- **Why steal:** Cost/latency optimization. Simple dictation doesn't need reasoning tokens.
- **Complexity:** Small

### Handy — Structured LLM output with JSON schema
- `response_format` with `json_schema` type, `strict: true`
- Guarantees structured output from LLM
- **Why steal:** Prevents parsing failures for tool calls. Apple FM tool-calling could benefit.
- **Complexity:** Small

### FluidVoice — Bounded in-memory event queue
- Max 200 events, drops oldest when full
- Flush at 20 events or 30 seconds
- **Why steal:** Memory-safe telemetry. Our `PaceTelemetryLog` should have bounds.
- **Complexity:** Small

### FluidVoice — Aggregated keychain storage
- All API keys in single JSON blob in keychain
- Fewer keychain operations, faster, atomic updates
- **Why steal:** We use `PaceKeychainStore` per-key. Aggregated is more efficient.
- **Complexity:** Small

### FluidVoice — Smart pause/resume with state tracking
- Pauses media only if playing
- Resumes only if it paused
- Double-resume protection with NSLock
- **Why steal:** We have media tools but not smart pause/resume tracking.
- **Complexity:** Small

### Recommended for Pace
1. **Turn-limited agent loop** (from FluidVoice) — prevent infinite loops.
2. **Destructive command detection** (from FluidVoice) — safety for shell commands.
3. **Post-transcription edit tracking** (from FluidVoice) — quality metric.
4. **Configurable reasoning effort** (from Handy) — disable reasoning for simple tasks.
5. **Chat session management** (from FluidVoice) — multiple concurrent conversations.

---

## Priority Matrix

Organized by impact on the product thesis (performance + subagents + Jarvis-like + skills):

### Sprint 1 — Performance Foundation
- STT-during-speech (VAD segmentation, commit on silence)
- Lazy stream close (mic stays warm 30s)
- KV cache for system prompt
- Single-thread lifecycle coordinator
- Speculative tool execution for rule-based commands
- Dictation fast path (STT → Apple FM cleanup → paste)

### Sprint 2 — Subagents & Parallelism
- Sub-agent coordinator (spawn N parallel planner turns)
- Background agent queue (multi-slot with progress + notifications)
- Dual-agent pre-fetch (background pre-computes likely-next context)
- Layered input ladder (background-safe automation for subagents)

### Sprint 3 — Ambient Intelligence (Jarvis Layer)
- Always-on AX tree polling (every 2-3s, frontmost app)
- Window/document title tracking
- Notification Center observer
- Clipboard change observer
- FS watchers (Downloads, Desktop, project dirs)
- Prediction cards (Fn key shows context-aware suggestions)

### Sprint 4 — Skills & Extensibility
- Expand bundled skill catalog (10-20 skills)
- Skill marketplace format (versioned, portable)
- Three-tier extensibility positioning (Skills / Plugins / MCP)
- Skill composition (skills invoke tools and other skills)
- SSE/HTTP MCP transport

### Sprint 5 — UX & Personality
- Multi-mode notch state machine
- Step-based agent execution UI
- Streaming thinking tokens
- Audio-reactive visualizer (Jarvis feel)
- Personality via system prompt engineering

### Sprint 6 — Memory & RAG
- Per-project memory
- 4-type memory model (Sensory / Episodic / Semantic / Procedural)
- Local RAG with vector search
- Work pattern extraction

### Sprint 7 — Distribution
- Sparkle OTA updates
- Signed & notarized DMG
- Hardware-aware first-run

---

## Sources

- FluidVoice (altic-dev/FluidVoice) — 3.6k stars, GPLv3, Swift
- OpenSuperWhisper (starmel/OpenSuperWhisper) — 1.3k stars, MIT, Swift
- Handy (cjpais/Handy) — 25.1k stars, Tauri/Rust+React
- 15 tracked competitors in `website/src/config/competitors.ts`
- 51 untracked projects discovered via web search
- 5 research papers (AURA, VoiceAgentRAG, ScreenAgent, SeeClick, Ichigo)

Full subagent research outputs:
- FluidVoice: 59 patterns cataloged
- OpenSuperWhisper: 22 patterns cataloged
- Handy: 30 patterns cataloged
- Competitors: 15 products analyzed
- Untracked: 51 projects + 5 papers discovered
