//
//  PaceSkillLoaderTests.swift
//  leanring-buddyTests
//
//  Tests for the .skill.md parser and planner prompt converter.
//  Verifies that frontmatter, steps, and notes are parsed correctly
//  from the Claude Code / OpenFelix-compatible format.
//

import Foundation
import Testing
@testable import Pace

struct PaceSkillLoaderTests {

    // MARK: - Parsing

    /// A complete .skill.md file with frontmatter and steps parses
    /// correctly.
    @Test
    func parseCompleteSkillFile() {
        let markdown = """
        ---
        name: "Test Skill"
        slug: "test-skill"
        description: "A test skill for unit testing"
        category: "work"
        requiredPreferences: ["preferredNotesFolder"]
        trigger: "run test skill"
        ---

        ## Steps

        1. Open Notes app
        2. Create a new note titled "Test"
        3. Add some content

        ## Notes

        This skill is for testing purposes only.
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.name == "Test Skill")
        #expect(skill?.slug == "test-skill")
        #expect(skill?.description == "A test skill for unit testing")
        #expect(skill?.category == "work")
        #expect(skill?.requiredPreferences == ["preferredNotesFolder"])
        #expect(skill?.trigger == "run test skill")
        #expect(skill?.steps.count == 3)
        #expect(skill?.steps[0].instruction == "Open Notes app")
        #expect(skill?.steps[1].instruction == "Create a new note titled \"Test\"")
        #expect(skill?.steps[2].instruction == "Add some content")
        #expect(skill?.notes == "This skill is for testing purposes only.")
    }

    /// A skill file without a trigger still parses (trigger is optional).
    @Test
    func parseSkillWithoutTrigger() {
        let markdown = """
        ---
        name: "No Trigger Skill"
        slug: "no-trigger"
        description: "Skill without a trigger"
        category: "custom"
        requiredPreferences: []
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.trigger == nil)
        #expect(skill?.steps.count == 1)
    }

    /// A skill file without a slug uses the fallback slug.
    @Test
    func parseSkillWithoutSlugUsesFallback() {
        let markdown = """
        ---
        name: "No Slug Skill"
        description: "Skill without a slug"
        category: "custom"
        requiredPreferences: []
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback-slug")

        #expect(skill != nil)
        #expect(skill?.slug == "fallback-slug")
    }

    /// A skill file with no steps returns nil.
    @Test
    func parseSkillWithNoStepsReturnsNil() {
        let markdown = """
        ---
        name: "Empty Skill"
        slug: "empty"
        description: "Skill with no steps"
        category: "custom"
        requiredPreferences: []
        ---

        ## Notes

        No steps here.
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")
        #expect(skill == nil)
    }

    /// A skill file without frontmatter delimiter returns nil.
    @Test
    func parseSkillWithoutFrontmatterReturnsNil() {
        let markdown = "Just some text without frontmatter."

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")
        #expect(skill == nil)
    }

    /// A skill file with empty name returns nil.
    @Test
    func parseSkillWithEmptyNameReturnsNil() {
        let markdown = """
        ---
        name: ""
        slug: "empty-name"
        description: "Skill with empty name"
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")
        #expect(skill == nil)
    }

    /// Required preferences can be parsed as a JSON array.
    @Test
    func parseRequiredPreferencesAsJSONArray() {
        let markdown = """
        ---
        name: "Array Prefs"
        slug: "array-prefs"
        description: "Skill with array prefs"
        requiredPreferences: ["key1", "key2", "key3"]
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.requiredPreferences == ["key1", "key2", "key3"])
    }

    /// Required preferences can be parsed as a comma-separated list.
    @Test
    func parseRequiredPreferencesAsCommaSeparated() {
        let markdown = """
        ---
        name: "Comma Prefs"
        slug: "comma-prefs"
        description: "Skill with comma prefs"
        requiredPreferences: key1, key2, key3
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.requiredPreferences == ["key1", "key2", "key3"])
    }

    /// A skill with a description that defaults to name when empty.
    @Test
    func emptyDescriptionDefaultsToName() {
        let markdown = """
        ---
        name: "Named Skill"
        slug: "named"
        description: ""
        ---

        ## Steps

        1. Do something
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "fallback")

        #expect(skill != nil)
        #expect(skill?.description == "Named Skill")
    }

    // MARK: - Planner prompt conversion

    /// The planner prompt includes the skill name, numbered steps,
    /// and notes.
    @Test
    func toPlannerPromptIncludesAllElements() {
        let skill = PaceSkillFile(
            name: "Test Skill",
            slug: "test-skill",
            description: "A test",
            category: "work",
            requiredPreferences: [],
            trigger: nil,
            steps: [
                PaceSkillStep(instruction: "First step", toolCall: nil),
                PaceSkillStep(instruction: "Second step", toolCall: nil),
                PaceSkillStep(instruction: "Third step", toolCall: nil),
            ],
            notes: "Important context"
        )

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)

        #expect(prompt.contains("Test Skill"))
        #expect(prompt.contains("1. First step"))
        #expect(prompt.contains("2. Second step"))
        #expect(prompt.contains("3. Third step"))
        #expect(prompt.contains("Important context"))
    }

    /// The planner prompt works with a single step.
    @Test
    func toPlannerPromptWithSingleStep() {
        let skill = PaceSkillFile(
            name: "Simple",
            slug: "simple",
            description: "Simple",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Just do it", toolCall: nil)],
            notes: nil
        )

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)

        #expect(prompt.contains("Simple"))
        #expect(prompt.contains("1. Just do it"))
        #expect(!prompt.contains("Context:"))
    }

    /// The planner prompt omits the notes section when nil.
    @Test
    func toPlannerPromptOmitsNilNotes() {
        let skill = PaceSkillFile(
            name: "No Notes",
            slug: "no-notes",
            description: "No notes",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Step", toolCall: nil)],
            notes: nil
        )

        let prompt = PaceSkillLoader.toPlannerPrompt(skill)

        #expect(!prompt.contains("Context:"))
    }

    // MARK: - Sample bundled skill

    /// The bundled sample skill file parses correctly.
    @Test
    func bundledSampleSkillParses() {
        let markdown = """
        ---
        name: "Standup Notes"
        slug: "standup-notes"
        description: "Creates a standup notes document with Yesterday, Today, Blockers sections"
        category: "morning"
        requiredPreferences: []
        trigger: "prepare my standup"
        ---

        ## Steps

        1. Open Notes app
        2. Create a new note titled "Standup - {today's date}"
        3. Add a heading "Yesterday" and list what I accomplished yesterday
        4. Add a heading "Today" and list my planned tasks for today
        5. Add a heading "Blockers" and note any blocking issues

        ## Notes

        This skill helps prepare for daily standup meetings by organizing thoughts into the three standard sections.
        """

        let skill = PaceSkillLoader.parse(skillMarkdown: markdown, fallbackSlug: "standup-notes")

        #expect(skill != nil)
        #expect(skill?.name == "Standup Notes")
        #expect(skill?.slug == "standup-notes")
        #expect(skill?.category == "morning")
        #expect(skill?.trigger == "prepare my standup")
        #expect(skill?.steps.count == 5)
        #expect(skill?.steps[0].instruction == "Open Notes app")
    }

    // MARK: - Serialize / round-trip

    /// A fully-specified skill survives serialize → parse unchanged.
    @Test
    func serializeRoundTripsThroughParse() {
        let original = makeSkill(
            name: "Round Trip",
            slug: "round-trip",
            steps: ["Open Notes", "Type hello"],
            trigger: "go",
            notes: "some notes",
            requiredPreferences: ["preferredNotesApp"]
        )
        let serialized = PaceSkillLoader.serialize(original)
        let parsed = PaceSkillLoader.parse(skillMarkdown: serialized, fallbackSlug: "fallback")
        #expect(parsed == original)
    }

    /// Optional fields (trigger, notes) and an empty preference list are
    /// omitted from the serialized file, and a minimal skill still round-trips.
    @Test
    func serializeOmitsOptionalFields() {
        let minimal = makeSkill(name: "Minimal", slug: "minimal", steps: ["Do the thing"])
        let serialized = PaceSkillLoader.serialize(minimal)
        #expect(!serialized.contains("trigger:"))
        #expect(!serialized.contains("requiredPreferences:"))
        #expect(!serialized.contains("## Notes"))
        let parsed = PaceSkillLoader.parse(skillMarkdown: serialized, fallbackSlug: "fallback")
        #expect(parsed == minimal)
    }

    // MARK: - Save / list / delete

    /// save → listUserSkills → deleteUserSkill against a throwaway directory.
    @Test
    func saveListDeleteRoundTrip() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-skill-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let skill = makeSkill(
            name: "My Test Skill",
            steps: ["Open Notes", "Open Slack"],
            trigger: "test it",
            notes: "hello"
        )
        try PaceSkillLoader.save(skill, to: temporaryDirectory)

        let listedAfterSave = PaceSkillLoader.listUserSkills(in: temporaryDirectory)
        #expect(listedAfterSave.count == 1)
        #expect(listedAfterSave.first?.name == "My Test Skill")
        #expect(listedAfterSave.first?.slug == "my-test-skill")
        #expect(listedAfterSave.first?.steps.count == 2)
        #expect(listedAfterSave.first?.trigger == "test it")

        try PaceSkillLoader.deleteUserSkill(slug: "my-test-skill", in: temporaryDirectory)
        #expect(PaceSkillLoader.listUserSkills(in: temporaryDirectory).isEmpty)
    }

    /// Saving twice with the same name overwrites rather than duplicating.
    @Test
    func saveOverwritesSameSlug() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-skill-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try PaceSkillLoader.save(
            makeSkill(name: "Dupe", steps: ["Step one"]),
            to: temporaryDirectory
        )
        try PaceSkillLoader.save(
            makeSkill(name: "Dupe", steps: ["Step one", "Step two"]),
            to: temporaryDirectory
        )
        let listed = PaceSkillLoader.listUserSkills(in: temporaryDirectory)
        #expect(listed.count == 1)
        #expect(listed.first?.steps.count == 2)
    }

    // MARK: - Structured JSON → skill

    @Test
    func skillFromStructuredJSONDecodesCleanResponse() {
        let json = """
        {"name": "Start My Day", "trigger": "start my day", "steps": ["Open Notes", "Open Slack"], "notes": "morning"}
        """
        let skill = PaceSkillLoader.skillFromStructuredJSON(json, fallbackName: "Custom Skill")
        #expect(skill?.name == "Start My Day")
        #expect(skill?.slug == "start-my-day")
        #expect(skill?.trigger == "start my day")
        #expect(skill?.steps.count == 2)
        #expect(skill?.notes == "morning")
        #expect(skill?.category == "custom")
    }

    @Test
    func skillFromStructuredJSONStripsMarkdownFence() {
        let fenced = """
        ```json
        {"name": "Fenced", "steps": ["Do a thing"]}
        ```
        """
        let skill = PaceSkillLoader.skillFromStructuredJSON(fenced, fallbackName: "Custom Skill")
        #expect(skill?.name == "Fenced")
        #expect(skill?.steps.count == 1)
    }

    @Test
    func skillFromStructuredJSONExtractsObjectFromProse() {
        let prose = "Sure! Here you go: {\"name\": \"Prose\", \"steps\": [\"Open Notes\"]} — enjoy."
        let skill = PaceSkillLoader.skillFromStructuredJSON(prose, fallbackName: "Custom Skill")
        #expect(skill?.name == "Prose")
        #expect(skill?.steps.count == 1)
    }

    @Test
    func skillFromStructuredJSONRejectsEmptySteps() {
        let json = "{\"name\": \"NoSteps\", \"steps\": []}"
        #expect(PaceSkillLoader.skillFromStructuredJSON(json, fallbackName: "Custom Skill") == nil)
    }

    @Test
    func skillFromStructuredJSONDerivesNameFromFirstStepWhenMissing() {
        let json = "{\"steps\": [\"Open Notes\"]}"
        let skill = PaceSkillLoader.skillFromStructuredJSON(json, fallbackName: "Custom Skill")
        // Missing name → derived from the first step, not the generic fallback.
        #expect(skill?.name == "Open Notes")
        #expect(skill?.steps.count == 1)
    }

    @Test
    func skillFromStructuredJSONRejectsGarbage() {
        #expect(PaceSkillLoader.skillFromStructuredJSON("not json at all", fallbackName: "X") == nil)
    }

    // MARK: - Deterministic fallback splitter

    @Test
    func deterministicSplitterExtractsTriggerAndSteps() {
        let skill = PaceSkillLoader.structureSkillDeterministically(
            from: "when I say start my day, open notes then open slack"
        )
        #expect(skill?.trigger == "start my day")
        #expect(skill?.name == "Start my day")
        #expect(skill?.steps.count == 2)
        #expect(skill?.steps.first?.instruction == "Open notes")
    }

    @Test
    func deterministicSplitterWithoutTriggerDerivesNameFromFirstStep() {
        let skill = PaceSkillLoader.structureSkillDeterministically(
            from: "open notes then open slack and check email"
        )
        #expect(skill?.trigger == nil)
        // No trigger → distinctive name derived from the first step (not a
        // generic constant), so two triggerless skills get distinct slugs.
        #expect(skill?.name == "Open notes")
        #expect((skill?.steps.count ?? 0) >= 2)
    }

    @Test
    func deterministicSplitterRejectsEmptyDescription() {
        #expect(PaceSkillLoader.structureSkillDeterministically(from: "   ") == nil)
    }

    // MARK: - Form authoring

    @Test
    func skillFromFormSplitsLinesIntoSteps() {
        let skill = PaceSkillLoader.skillFromForm(
            name: "Morning",
            stepsText: "Open Notes\nOpen Slack\n\n",
            trigger: "morning",
            notes: nil
        )
        #expect(skill?.name == "Morning")
        #expect(skill?.slug == "morning")
        #expect(skill?.steps.count == 2)
        #expect(skill?.trigger == "morning")
    }

    @Test
    func skillFromFormStripsLeadingNumbers() {
        let skill = PaceSkillLoader.skillFromForm(
            name: "Numbered",
            stepsText: "1. Open Notes\n2. Open Slack",
            trigger: nil,
            notes: nil
        )
        #expect(skill?.steps.first?.instruction == "Open Notes")
        #expect(skill?.steps.last?.instruction == "Open Slack")
    }

    @Test
    func skillFromFormRejectsEmptyNameOrSteps() {
        #expect(PaceSkillLoader.skillFromForm(name: "", stepsText: "Open Notes", trigger: nil, notes: nil) == nil)
        #expect(PaceSkillLoader.skillFromForm(name: "X", stepsText: "   \n  ", trigger: nil, notes: nil) == nil)
    }

    // MARK: - Voice command parsing (create + regression)

    @Test
    func parserRecognizesTeachSkillCommand() {
        #expect(createDescription("teach a skill to open notes then open slack") == "open notes then open slack")
        #expect(createDescription("learn a skill: when I say start my day, open notes") == "when I say start my day, open notes")
        #expect(createDescription("create a new skill called morning routine") == "morning routine")
    }

    @Test
    func parserCreateDoesNotSwallowExistingCommands() {
        // The create branch is checked first but must not steal list/install/run.
        #expect(commandKind("list skills") == "list")
        #expect(commandKind("what skills do you have") == "list")
        #expect(commandKind("install the standup skill") == "install")
        #expect(commandKind("run the standup skill") == "run")
        #expect(commandKind("teach a skill to draft my email") == "create")
        // "make a skill list" must route to list, not create a skill named "List".
        #expect(commandKind("make a skill list") == "list")
    }

    // MARK: - Collision + round-trip regressions

    /// Two different triggerless taught skills must not collapse to one slug
    /// and silently overwrite each other on save.
    @Test
    func twoTriggerlessTaughtSkillsGetDistinctSlugsAndBothPersist() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-skill-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstSkill = try #require(
            PaceSkillLoader.structureSkillDeterministically(from: "open notes then write today's date")
        )
        let secondSkill = try #require(
            PaceSkillLoader.structureSkillDeterministically(from: "open slack then post good morning")
        )
        #expect(firstSkill.slug != secondSkill.slug)

        try PaceSkillLoader.save(firstSkill, to: temporaryDirectory)
        try PaceSkillLoader.save(secondSkill, to: temporaryDirectory)
        #expect(PaceSkillLoader.listUserSkills(in: temporaryDirectory).count == 2)
    }

    /// A trigger with embedded quotes and notes with a newline / heading-like
    /// line still round-trip losslessly (values are sanitized before write).
    @Test
    func serializeSanitizesTriggerAndNotesForLosslessRoundTrip() throws {
        let skill = try #require(PaceSkillLoader.skillFromForm(
            name: "Weird Skill",
            stepsText: "Open Notes",
            trigger: "say \"go\" now",
            notes: "line one\n## still notes not a heading"
        ))
        let serialized = PaceSkillLoader.serialize(skill)
        let reparsed = try #require(
            PaceSkillLoader.parse(skillMarkdown: serialized, fallbackSlug: "fallback")
        )
        #expect(reparsed == skill)
        #expect(reparsed.trigger == "say go now")
        #expect(reparsed.notes?.contains("\n") == false)
    }

    // MARK: - Test helpers

    private func makeSkill(
        name: String,
        slug: String? = nil,
        steps: [String],
        trigger: String? = nil,
        notes: String? = nil,
        requiredPreferences: [String] = []
    ) -> PaceSkillFile {
        PaceSkillFile(
            name: name,
            slug: slug ?? PaceFlowStore.slug(for: name),
            description: name,
            category: "custom",
            requiredPreferences: requiredPreferences,
            trigger: trigger,
            steps: steps.map { PaceSkillStep(instruction: $0, toolCall: nil) },
            notes: notes
        )
    }

    /// The raw description a "teach a skill" utterance parses to, or nil.
    private func createDescription(_ transcript: String) -> String? {
        if case let .create(rawDescription) = PaceSkillCommandParser.parse(transcript) {
            return rawDescription
        }
        return nil
    }

    /// A stable label for the parsed command case (avoids needing Equatable).
    private func commandKind(_ transcript: String) -> String {
        switch PaceSkillCommandParser.parse(transcript) {
        case .none: return "nil"
        case .list: return "list"
        case .run: return "run"
        case .install: return "install"
        case .create: return "create"
        }
    }
}
