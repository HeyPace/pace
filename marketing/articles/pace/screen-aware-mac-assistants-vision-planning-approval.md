# Screen-Aware Mac Assistants: Local Vision, Planning, and Action Approval

- **Slug**: `screen-aware-mac-assistants-vision-planning-approval`
- **Target Query**: `screen aware mac assistant local vision action approval`
- **Search Intent**: Informational (Developers, power users, and enterprise IT leaders evaluating how screen-aware AI agents capture desktop context locally, execute multi-step tasks, and enforce action approval safety)
- **Meta Title**: Screen-Aware Mac Assistants: Local Vision, Planning, and Approval
- **Meta Description**: Discover how screen-aware macOS assistants use local vision, Accessibility tree inspection, bounded plan-act-observe loops, and approval gates to automate tasks safely.

---

## Outline

1. **Introduction: What Makes a Mac Assistant "Screen-Aware"?**
   - Moving beyond text prompts: understanding active application state.
   - The dual challenge: capturing rich visual context while preserving user privacy and action safety.
2. **The Local Vision Pipeline: Capture, Inspection, and VLM Fallbacks**
   - High-performance local frame capture via macOS `ScreenCaptureKit`.
   - Structural element extraction via Accessibility (`AXUIElement`) APIs and native OCR.
   - Local Vision-Language Model (VLM) inference for unexposed or complex visual interfaces.
3. **The Multi-Step Plan-Act-Observe Execution Loop**
   - Iterative reasoning: analyzing visual state, planning the next action, and observing results.
   - Bounded execution step limits (`AgentMaxSteps`) to prevent infinite loops.
   - FastPath state change detection and Accessibility polling for low-latency feedback.
4. **Action Safety Framework: Approval Policy, Preflight, and Reversibility**
   - Distinguishing routine navigation from state-mutating or non-undoable actions.
   - User approval prompts for high-risk operations with default-cancel safety.
   - The 5-second floating undo banner and session mutation recovery.
5. **Transparency and Trust Boundaries for Screen-Aware Agents**
   - Keeping screen frames and visual embeddings strictly on-device.
   - Clear visual indicators (Living Notch signal and capsule amber tinting for off-device turns).
   - Local API audit logging (`PaceAPIAuditLog`) for complete operational transparency.
6. **Conclusion and Best Practices for Screen-Aware Desktop Automation**

---

## Article Body

### Introduction: What Makes a Mac Assistant "Screen-Aware"?

Traditional desktop voice assistants operate in a vacuum. When a user asks a basic voice assistant to "click the green submit button in my browser" or "summarize the open document," conventional software fails unless the application exposes explicit, pre-defined voice shortcuts. A truly *screen-aware* assistant bridges this gap by interpreting the user's active display—understanding visual layouts, window hierarchies, active controls, and text content in real time.

However, giving an artificial intelligence agent access to live screen contents introduces dual engineering challenges: processing high-resolution visual data rapidly without streaming desktop video feeds to remote cloud servers, and ensuring that automated screen actions (such as clicking buttons or editing values) occur predictably under explicit user control. Understanding how local vision, multimodal reasoning, and action approval policies interact reveals how modern Mac assistants achieve safe, context-aware automation.

### The Local Vision Pipeline: Capture, Inspection, and VLM Fallbacks

A privacy-preserving screen-aware agent uses a multi-stage local perception pipeline to understand what is happening on screen without transmitting images off the user's Mac:

```
[ScreenCaptureKit Frame Capture] ──► [AXUIElement & Native OCR Inspection]
                                            │
                                            ▼
                               [Is AX/OCR sufficient?]
                                  │               │
                                Yes               No
                                  │               │
                                  ▼               ▼
                        [Direct AX Target]  [Local VLM Fallback]
```

#### 1. High-Performance Frame Capture
Visual perception begins with capturing the display state. On modern macOS systems, local agents utilize Apple's `ScreenCaptureKit` framework. ScreenCaptureKit provides hardware-accelerated, multi-monitor display frame access with minimal CPU overhead, capturing the exact pixel representation of active application windows.

#### 2. Accessibility (AX) Tree and Native OCR Inspection
Pixels alone are often inefficient for precise interaction. Before sending display frames to heavy neural network models, the local agent performs lightweight structural inspection. The system queries the macOS Accessibility hierarchy via `AXUIElement` APIs, extracting control identifiers, button labels, text field values, and bounding frame coordinates. Simultaneously, native operating system Optical Character Recognition (OCR) processes visual text blocks. If a target element (such as a standard macOS button or menu item) is exposed in the AX tree, the agent targets it directly with exact coordinate confidence.

#### 3. Local Vision-Language Model (VLM) Fallbacks
When interacting with custom canvas applications, web games, electron apps, or creative software where Accessibility elements are incomplete or unexposed, the agent falls back to a local Vision-Language Model (VLM)—such as `qwen/qwen3.5-4b` multimodal or specialized local UI vision models running over local loopback connections (`127.0.0.1`). The local VLM analyzes the display image alongside the user's request, emitting spatial coordinates or visual tags (e.g., `[POINT:x,y:label]`) to guide the action executor without external network transmission.

### The Multi-Step Plan-Act-Observe Execution Loop

Automating realistic desktop tasks requires more than a single click; it involves a continuous feedback loop of planning, acting, and observing. A screen-aware Mac agent executes this workflow using an iterative multi-step agent loop:

1. **Plan**: The local reasoner analyzes the current transcript, conversation history, and visual screen context to determine the immediate next step.
2. **Act**: The executor dispatches the step—such as clicking a coordinate (`[CLICK:x,y]`), typing text into an active control (`[TYPE:text]`), or pressing a key chord (`[KEY:cmd+s]`). Preference is always given to Accessibility-native presses (`PaceAXTargeter`) before falling back to system mouse events (`CGEvent`).
3. **Observe**: Once the action dispatches, the agent captures an updated screen snapshot or checks Accessibility state changes to verify the result before proceeding.

To guarantee that an agent never gets stuck in an unresolvable loop, execution is subject to strict bounds. The planner enforces a step cap (`AgentMaxSteps`, defaulting to 8 iterations). If a task cannot be completed within the step limit, or if the model emits a final `[DONE]` signal, the agent terminates execution cleanly and reports outcomes to the user.

Furthermore, state verification uses lightweight Accessibility polling ("FastPath observation") to detect visual window changes within milliseconds, returning immediately when an element updates rather than enforcing long static delays.

### Action Safety Framework: Approval Policy, Preflight, and Reversibility

Granting an AI agent the ability to execute physical clicks and keypresses on a desktop computer requires rigorous safety guardrails. A screen-aware Mac assistant enforces safety through a three-tier protection layer:

#### 1. Action Risk Categorization
Not all desktop interactions carry equal risk. Read-only navigation (such as switching tabs, scrolling a page, or reading window titles) carries minimal risk and is permitted to execute fluidly. Conversely, actions that mutate persistent state—such as deleting files, executing system commands, sending emails, or modifying calendar entries—are flagged as high-risk or external operations.

#### 2. Explicit User Approval Prompts
When the user enables action confirmation preferences (`Approve Risky Actions`), any high-risk or non-undoable action halts execution before dispatch. The agent presents an explicit modal prompt detailing the target application and proposed action. The default selection on the approval dialog is set to **Cancel**, ensuring that unattended or ambiguous commands cannot execute without active human consent.

#### 3. Reversible Mutations and Local Undo
When reversible mutations execute (such as creating a note, editing text, or creating a reminder), the agent records the previous state in a session mutation log and displays a floating, 5-second **Undo Banner** near the cursor. Tapping the banner or uttering "undo that" immediately triggers a rollback via the local action executor, restoring the system to its prior state.

### Transparency and Trust Boundaries for Screen-Aware Agents

Because screen-aware agents inspect active window contents, user trust requires total transparency regarding how visual data is handled:

- **Local Processing Default**: All captured display frames, OCR text buffers, and VLM visual embeddings remain strictly in local RAM and are discarded after turn completion. No screen images are uploaded to remote servers.
- **Visual State Communication**: Active agent states (listening, reasoning, acting, speaking) are explicitly rendered in native UI elements (such as a Living Notch signal or status panel).
- **Off-Device Disclosures**: If the user explicitly opts into an off-device reasoning model (such as a cloud API or CLI bridge to external models), the menu bar capsule turns **amber**, and every off-device request is logged to a local JSONL audit trail (`~/Library/Application Support/Pace/api-audit-log.jsonl`).
- **Loopback Endpoint Guarding**: All local model communication interfaces bind strictly to `127.0.0.1`, preventing external devices on the local network from querying local VLM or planner interfaces.

### Conclusion and Best Practices for Screen-Aware Desktop Automation

Screen-aware Mac assistants represent a major evolution in desktop productivity, combining high-speed visual capture with intelligent action execution. By pairing local ScreenCaptureKit frame acquisition with Accessibility tree inspection, local VLM fallbacks, bounded plan-act-observe loops, explicit action approval gates, and transparent local audit logging, users can automate daily desktop workflows safely and privately.

---

## Internal-Link Suggestions

- Link to `/` (Homepage) when introducing screen-aware Mac voice agents.
- Link to `/privacy` when highlighting local screen frame retention and zero-cloud trust boundaries.
- Link to `/screen-aware-ai-assistant-mac` for a detailed technical breakdown of ScreenCaptureKit and local VLM integration.
- Link to `/mac-ai-assistant-actions` when discussing Accessibility (`AXUIElement`) actions, click targeting, and safety approvals.
- Link to `/private-voice-assistant-mac` when describing the voice-to-action interaction loop.

---

## Clear Next Action

To see how screen-aware local vision and action approvals operate on your desktop, visit our [Screen-Aware Assistant Guide](https://heypace.app/screen-aware-ai-assistant-mac) or review the complete security model on our [Privacy Page](https://heypace.app/privacy).

---

## Source Notes

> **Notice**: This section is non-publishable developer context citing authoritative files from the repository and noting relevant hardware or technical limitations.

- **Authoritative Repository Files**:
  - `AGENTS.md`: Establishes the requirement for local VLM/AX perception, on-device default constraints, and amber status signaling during off-device turns.
  - `PRODUCT.md`: Outlines positioning, core capabilities, action approval principles, and local trust boundaries.
  - `PROJECT_STATUS.md`: Documents shipped features including ScreenCaptureKit multi-monitor capture, `PaceAXTargeter`, `PaceSetOfMarkClickRecovery`, `AgentMaxSteps` loop capping, FastPath observation, and the 5-second `PaceUndoBanner`.
  - `docs/architecture/systems.md`: Details `PaceAXTargeter`, `PaceActionApproval`, `PaceActionExecutor`, `BuddyPlannerClient`, and local loopback isolation.
  - `leanring-buddy/PaceActionExecutor.swift` & `PaceActionApproval.swift`: Source implementations for AX-first click targeting, approval alerts, and undo state handling.
- **Hardware Dependencies & Technical Limitations**:
  - ScreenCaptureKit frame capture requires macOS 14.2 or later.
  - Local VLM reasoning (`qwen/qwen3.5-4b` multimodal or `ui-venus`) requires Apple Silicon hardware with sufficient unified memory (12–25+ GB recommended).
  - Accessibility tree targeting requires user-granted Accessibility permissions under macOS System Settings → Privacy & Security → Accessibility.
  - Development builds using `xcodebuild` from terminal invalidate TCC grants; local testing must use Xcode (Cmd+R) or isolated test harnesses (`scripts/test-pace.sh`).
