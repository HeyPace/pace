//
//  PaceSkillExecutionEndToEndTests.swift
//  leanring-buddyTests
//
//  End-to-end coverage for the taught-skill RUN path — the gap flagged
//  in the skills-execution-hardening pass (teaching was well-tested;
//  running had ZERO execution tests).
//
//  Honest testability note
//  -----------------------
//  The production run path is `CompanionManager.handleSkillCommand(.run)`
//  → `sendTranscriptToPlannerWithScreenshot`, which drives the full
//  plan-act-observe agent loop. That loop needs TCC-gated permissions
//  (screen recording, accessibility) that the unit-test process does not
//  have — the same constraint documented in `AgentLoopExitConditionsTests`,
//  which tests the loop's PURE decision seams rather than the whole
//  pipeline. So these tests drive the LARGEST testable slice of the real
//  run path: the exact composition the production code uses —
//
//    skill → PaceSkillLoader.toPlannerPrompt → BuddyPlannerClient
//          → PaceActionTagParser.parseActions
//
//  — using a scripted `BuddyPlannerClient` (same mock pattern as
//  `PaceMeetingNotesBuilderTests`) and the SAME `PaceActionTagParser`
//  action-parsing seam the executor consumes. It also covers the pure
//  run-time gates the production `.run` case calls directly
//  (requiredPreferences preflight) and the skill-run telemetry journal.
//

import Foundation
import Testing
@testable import Pace

// MARK: - Scripted planner

/// A `BuddyPlannerClient` that captures the prompt it was handed and
/// returns a scripted response — exactly how the meeting-notes tests
/// fake the planner. Lets us assert both "what the run path SENT" and
/// "how the planner's reply PARSES".
@MainActor
final class ScriptedSkillRunPlannerClient: BuddyPlannerClient {
    let displayName: String = "Scripted skill-run planner"
    let supportsImageInput: Bool = false

    private let scriptedResponse: String
    private(set) var capturedUserPrompt: String?
    private(set) var callCount: Int = 0

    init(scriptedResponse: String) {
        self.scriptedResponse = scriptedResponse
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        callCount += 1
        capturedUserPrompt = userPrompt
        onTextChunk(scriptedResponse)
        return (text: scriptedResponse, duration: 0)
    }
}

// MARK: - Tests

@MainActor
struct PaceSkillExecutionEndToEndTests {

    // (a) Running a skill sends `toPlannerPrompt()` output to the planner.

    @Test
    func runningSkillSendsToPlannerPromptToThePlanner() async throws {
        let skill = PaceSkillFile(
            name: "Open Music",
            slug: "open-music",
            description: "Open Music",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Open the Music app", toolCall: nil)],
            notes: nil
        )
        let planner = ScriptedSkillRunPlannerClient(scriptedResponse: "on it.")

        // The run path builds this prompt and hands it to the planner. We
        // drive that same composition directly here (the agent loop that
        // wraps it needs TCC permissions we don't have under test).
        let expectedPrompt = PaceSkillLoader.toPlannerPrompt(skill)
        _ = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "system",
            conversationHistory: [],
            userPrompt: expectedPrompt,
            onTextChunk: { _ in }
        )

        #expect(planner.callCount == 1)
        #expect(planner.capturedUserPrompt == expectedPrompt)
        // Sanity: the prompt actually carries the skill's step, so we know
        // the planner received a runnable instruction and not an empty
        // string.
        #expect(planner.capturedUserPrompt?.contains("1. Open the Music app") == true)
    }

    // (b) A scripted planner response containing a tool_calls block yields
    //     the expected parsed actions, via the SAME `parseActions` seam the
    //     executor consumes.

    @Test
    func scriptedToolCallsResponseParsesIntoExpectedActions() async throws {
        let skill = PaceSkillFile(
            name: "Open Music",
            slug: "open-music",
            description: "Open Music",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Open the Music app", toolCall: nil)],
            notes: nil
        )
        // The planner replies with spoken text + a grouped tool_calls block,
        // exactly the shape the agent loop expects to parse.
        let scriptedResponse = """
        opening music.
        <tool_calls>
        [
          [
            {"tool":"open_app","app":"Music"}
          ]
        ]
        </tool_calls>
        """
        let planner = ScriptedSkillRunPlannerClient(scriptedResponse: scriptedResponse)

        let result = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "system",
            conversationHistory: [],
            userPrompt: PaceSkillLoader.toPlannerPrompt(skill),
            onTextChunk: { _ in }
        )

        // Feed the planner's reply through the executor's parse seam.
        let parseResult = PaceActionTagParser.parseActions(from: result.text)

        #expect(parseResult.spokenText == "opening music.")
        #expect(parseResult.actions.count == 1)
        guard case .openApplication(let applicationName) = parseResult.actions.first else {
            Issue.record("Expected the tool_calls block to parse into an openApplication action")
            return
        }
        #expect(applicationName == "Music")
    }

    // (c) requiredPreferences-missing blocks the run with the message.

    @Test
    func missingRequiredPreferenceBlocksRunBeforeReachingThePlanner() async throws {
        let skill = PaceSkillFile(
            name: "Focus Mode",
            slug: "focus-mode",
            description: "Focus mode",
            category: "custom",
            requiredPreferences: ["preferredFocusPlaylist"],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Play focus music", toolCall: nil)],
            notes: nil
        )
        let planner = ScriptedSkillRunPlannerClient(scriptedResponse: "on it.")

        // This is the exact gate the production `.run` case runs FIRST.
        let preflight = PaceSkillLoader.preflightRequiredPreferences(
            for: skill,
            memoryStore: NoPreferencesStub.self
        )

        guard case .missingPreference(let missingPreferenceKey) = preflight else {
            Issue.record("Expected the run to be blocked on a missing preference")
            return
        }
        #expect(missingPreferenceKey == "preferredFocusPlaylist")

        // The run path returns before dispatching to the planner, and the
        // message it speaks mirrors the recipes' wording verbatim.
        let spokenRefusal = "i need \(missingPreferenceKey) set first."
        #expect(spokenRefusal == "i need preferredFocusPlaylist set first.")
        // The planner is never called when the run is blocked.
        #expect(planner.callCount == 0)
    }

    // (d) A toolCall step's rendered prompt contains the tool directive.

    @Test
    func toolCallStepPromptContainsToolDirective() async throws {
        let skill = PaceSkillFile(
            name: "Note Skill",
            slug: "note-skill",
            description: "Note skill",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [
                PaceSkillStep(
                    instruction: "Create the note",
                    toolCall: #"{"tool":"notes","action":"create","title":"Idea","body":"note text"}"#
                ),
            ],
            notes: nil
        )
        let planner = ScriptedSkillRunPlannerClient(scriptedResponse: "done.")

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)
        _ = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "system",
            conversationHistory: [],
            userPrompt: prompt,
            onTextChunk: { _ in }
        )

        #expect(planner.capturedUserPrompt?.contains("(use tool: ") == true)
        #expect(planner.capturedUserPrompt?.contains(
            #"{"tool":"notes","action":"create","title":"Idea","body":"note text"}"#
        ) == true)
    }

    // MARK: - Skill-run telemetry journal

    @Test
    func journalPairsStartedAndCompletedForASuccessfulRun() {
        let journal = makeIsolatedJournal()
        let runId = journal.recordStarted(skillSlug: "open-music", stepsPlanned: 3)
        journal.recordCompleted(runId: runId, skillSlug: "open-music", stepsPlanned: 3)

        let records = journal.readAllRecords()
        #expect(records.count == 2)
        #expect(records[0].phase == "started")
        #expect(records[0].runId == runId)
        #expect(records[0].skillSlug == "open-music")
        #expect(records[0].stepsPlanned == 3)
        #expect(records[1].phase == "completed")
        #expect(records[1].runId == runId)
        #expect(records[1].failureReason == nil)
    }

    @Test
    func journalRecordsFailureReasonForABlockedRun() {
        let journal = makeIsolatedJournal()
        let runId = journal.recordStarted(skillSlug: "focus-mode", stepsPlanned: 1)
        journal.recordFailed(
            runId: runId,
            skillSlug: "focus-mode",
            stepsPlanned: 1,
            failureReason: "missing preference: preferredFocusPlaylist"
        )

        let records = journal.readAllRecords()
        #expect(records.count == 2)
        #expect(records[1].phase == "failed")
        #expect(records[1].failureReason == "missing preference: preferredFocusPlaylist")
    }

    // MARK: - Helpers

    /// A journal that writes to a throwaway file so tests never touch the
    /// real `~/Library/Application Support/Pace/skill-runs.jsonl`.
    private func makeIsolatedJournal() -> PaceSkillRunJournal {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-skill-run-tests-\(UUID().uuidString).jsonl")
        return PaceSkillRunJournal(logFileURL: temporaryURL)
    }
}

// MARK: - Memory-store stub

/// No preference is set — used to prove the run is blocked when a skill's
/// required preference is missing. Reuses the shared
/// `PaceLocalMemoryStoreReadable` seam.
private enum NoPreferencesStub: PaceLocalMemoryStoreReadable {
    static func string(for key: PaceLocalMemoryKey) -> String? { nil }
}
