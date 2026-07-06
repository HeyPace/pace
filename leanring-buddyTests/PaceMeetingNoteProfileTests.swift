//
//  PaceMeetingNoteProfileTests.swift
//  leanring-buddyTests
//
//  Covers the meeting note profile model + library:
//    - the `general` profile renders a prompt byte-for-byte identical to
//      the legacy `PaceMeetingNotesPrompt.systemPrompt` (compat anchor)
//    - bundled profiles load + validate from the source tree
//    - the bundled slug list matches the shipped set
//    - a tailored profile (standup) renders a multi-section block +
//      grounding request + no decisions
//    - user profiles override bundled by slug; malformed user files are
//      skipped rather than crashing; malformed bundled shape fails validation
//

import Foundation
import Testing

@testable import Pace

struct PaceMeetingNoteProfileTests {

    // MARK: - Compatibility anchor

    @Test func generalProfileRendersLegacyPromptByteForByte() {
        #expect(PaceMeetingNoteProfile.general.renderSystemPrompt() == PaceMeetingNotesPrompt.systemPrompt)
    }

    // MARK: - Bundled loading + validation

    @Test func bundledProfilesValidateFromSourceTree() {
        let issues = PaceMeetingNoteProfileLibrary.validateBundledProfiles(bundle: .main)
        #expect(issues.isEmpty, "expected no validation issues, got: \(issues.map { $0.message }.joined(separator: "; "))")
    }

    @Test func bundledSlugListMatchesShippedSet() {
        #expect(Set(PaceMeetingNoteProfileLibrary.bundledProfileSlugs) == ["general", "standup", "one-on-one"])
    }

    @Test func bundledGeneralJSONMatchesStaticGeneral() {
        // The bundled general.json must render the legacy prompt too, so
        // whichever source the app loads from, `general` is compatible.
        let bundledGeneral = PaceMeetingNoteProfileLibrary
            .loadProfiles(bundle: .main, userDirectory: emptyTempDirectory())
            .first { $0.slug == "general" }
        #expect(bundledGeneral?.renderSystemPrompt() == PaceMeetingNotesPrompt.systemPrompt)
    }

    // MARK: - Tailored profile rendering

    @Test func standupProfileRendersSectionsGroundingAndNoDecisions() throws {
        let standup = PaceMeetingNoteProfileLibrary
            .loadProfiles(bundle: .main, userDirectory: emptyTempDirectory())
            .first { $0.slug == "standup" }
        let rendered = try #require(standup).renderSystemPrompt()
        // Multi-section summary block.
        #expect(rendered.contains("- summary: organize into these labeled sections:"))
        #expect(rendered.contains("Yesterday:"))
        #expect(rendered.contains("Blockers:"))
        // Grounding requested in the JSON shape + the action rule.
        #expect(rendered.contains("\"quote\": string|null"))
        #expect(rendered.contains("verbatim \"quote\""))
        // Standup emits action items but NOT decisions.
        #expect(rendered.contains("- actionItems:"))
        #expect(!rendered.contains("- decisions:"))
        #expect(!rendered.contains("\"decisions\": [string]"))
    }

    // MARK: - User overrides

    @Test func userProfileOverridesBundledBySlug() throws {
        let userDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        let overrideJSON = """
        {"slug":"standup","name":"My Standup","description":"custom","sections":[{"key":"summary","title":"Summary","instruction":"just summarize"}],"emitsActionItems":false,"emitsDecisions":false,"groundsActionItems":false}
        """
        try overrideJSON.write(to: userDir.appendingPathComponent("standup.json"), atomically: true, encoding: .utf8)

        let profiles = PaceMeetingNoteProfileLibrary.loadProfiles(bundle: .main, userDirectory: userDir)
        let standup = profiles.first { $0.slug == "standup" }
        #expect(standup?.name == "My Standup")
        #expect(standup?.emitsActionItems == false)
    }

    @Test func malformedUserProfileIsSkippedNotFatal() throws {
        let userDir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        try "this is not json {{{".write(to: userDir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        // Should still load bundled profiles without throwing.
        let profiles = PaceMeetingNoteProfileLibrary.loadProfiles(bundle: .main, userDirectory: userDir)
        #expect(profiles.contains { $0.slug == "general" })
        #expect(!profiles.contains { $0.slug == "broken" })
    }

    @Test func unknownSlugResolvesToGeneral() {
        let resolved = PaceMeetingNoteProfileLibrary.profile(forSlug: "does-not-exist", bundle: .main)
        #expect(resolved.slug == "general")
    }

    // MARK: - Shape validation

    @Test func validateProfileShapeCatchesBadShapes() {
        let slugMismatch = PaceMeetingNoteProfile(slug: "actual", name: "N", description: "D", sections: [.init(key: "s", title: "S", instruction: "i")], emitsActionItems: true, emitsDecisions: true, groundsActionItems: false)
        #expect(!PaceMeetingNoteProfileLibrary.validateProfileShape(slugMismatch, expectedSlug: "expected").isEmpty)

        let noSections = PaceMeetingNoteProfile(slug: "x", name: "N", description: "D", sections: [], emitsActionItems: true, emitsDecisions: true, groundsActionItems: false)
        #expect(!PaceMeetingNoteProfileLibrary.validateProfileShape(noSections, expectedSlug: "x").isEmpty)

        let emptyName = PaceMeetingNoteProfile(slug: "x", name: "  ", description: "D", sections: [.init(key: "s", title: "S", instruction: "i")], emitsActionItems: true, emitsDecisions: true, groundsActionItems: false)
        #expect(!PaceMeetingNoteProfileLibrary.validateProfileShape(emptyName, expectedSlug: "x").isEmpty)
    }

    // MARK: - Selection precedence

    private var availableForResolve: [PaceMeetingNoteProfile] {
        [
            .general,
            PaceMeetingNoteProfile(slug: "standup", name: "Daily Standup", description: "d", sections: [.init(key: "s", title: "S", instruction: "i")], emitsActionItems: true, emitsDecisions: false, groundsActionItems: true),
            PaceMeetingNoteProfile(slug: "one-on-one", name: "One-on-One", description: "d", sections: [.init(key: "s", title: "S", instruction: "i")], emitsActionItems: true, emitsDecisions: false, groundsActionItems: true),
        ]
    }

    @Test func explicitSelectionWins() {
        let resolved = PaceMeetingNoteProfileLibrary.resolveProfile(
            explicitSlug: "one-on-one", defaultSlug: "standup", inferredSlug: "standup", available: availableForResolve
        )
        #expect(resolved.slug == "one-on-one")
    }

    @Test func nonGeneralDefaultBeatsInference() {
        let resolved = PaceMeetingNoteProfileLibrary.resolveProfile(
            explicitSlug: nil, defaultSlug: "standup", inferredSlug: "one-on-one", available: availableForResolve
        )
        #expect(resolved.slug == "standup")
    }

    @Test func inferenceUsedWhenDefaultIsGeneral() {
        let resolved = PaceMeetingNoteProfileLibrary.resolveProfile(
            explicitSlug: nil, defaultSlug: "general", inferredSlug: "standup", available: availableForResolve
        )
        #expect(resolved.slug == "standup")
    }

    @Test func fallsBackToGeneralWhenNothingResolves() {
        let resolved = PaceMeetingNoteProfileLibrary.resolveProfile(
            explicitSlug: nil, defaultSlug: "general", inferredSlug: nil, available: availableForResolve
        )
        #expect(resolved.slug == "general")
    }

    @Test func unknownSlugsAreIgnoredAtEachTier() {
        let resolved = PaceMeetingNoteProfileLibrary.resolveProfile(
            explicitSlug: "nope", defaultSlug: "also-nope", inferredSlug: "still-nope", available: availableForResolve
        )
        #expect(resolved.slug == "general")
    }

    @Test func shouldInferOnlyWhenEnabledNoExplicitAndGeneralDefault() {
        #expect(PaceMeetingNoteProfileLibrary.shouldInfer(explicitSlug: nil, defaultSlug: "general", inferenceEnabled: true))
        #expect(!PaceMeetingNoteProfileLibrary.shouldInfer(explicitSlug: nil, defaultSlug: "general", inferenceEnabled: false))
        #expect(!PaceMeetingNoteProfileLibrary.shouldInfer(explicitSlug: "standup", defaultSlug: "general", inferenceEnabled: true))
        #expect(!PaceMeetingNoteProfileLibrary.shouldInfer(explicitSlug: nil, defaultSlug: "standup", inferenceEnabled: true))
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pace-profiles-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func emptyTempDirectory() -> URL {
        makeTempDirectory()
    }
}
