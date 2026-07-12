//
//  CompanionManagerHeuristicsTests.swift
//  leanring-buddyTests
//
//  Tests the pure-function heuristics that gate the local VLM call.
//  These statics live on `PaceTagParsers` (extracted from
//  `CompanionManager`) so the tests can hit them without standing up
//  the UI state machine.
//

import Testing
@testable import Pace

struct CompanionManagerHeuristicsTests {

    @Test func pureGeneralKnowledgeQueryIsNotScreenReferential() async throws {
        let transcripts = [
            "what is html",
            "explain how async await works in javascript",
            "tell me about the renaissance",
            "summarize machine learning in one sentence"
        ]

        for transcript in transcripts {
            #expect(
                !PaceTagParsers.transcriptIsLikelyScreenReferential(transcript),
                "Expected '\(transcript)' to be classified as general Q&A"
            )
        }
    }

    @Test func actionVerbsTriggerScreenReferentialMatch() async throws {
        let actionTranscripts = [
            "click the save button",
            "type hello world",
            "press enter",
            "scroll down a bit",
            "open the file in xcode",
            "save this for me"
        ]

        for transcript in actionTranscripts {
            #expect(
                PaceTagParsers.transcriptIsLikelyScreenReferential(transcript),
                "Expected '\(transcript)' to be classified as actionable"
            )
        }
    }

    @Test func deicticReferencesToScreenTriggerMatch() async throws {
        let deicticTranscripts = [
            "what is this thing on my screen",
            "what's that menu",
            "where is the run button",
            "show me where to find the settings",
            "point at the toolbar"
        ]

        for transcript in deicticTranscripts {
            #expect(
                PaceTagParsers.transcriptIsLikelyScreenReferential(transcript),
                "Expected '\(transcript)' to be classified as deictic / screen-referential"
            )
        }
    }

    @Test func uiArtifactNamesTriggerMatch() async throws {
        let uiTranscripts = [
            "is there a dialog open",
            "i don't see the sidebar",
            "which tab am i looking at"
        ]

        for transcript in uiTranscripts {
            #expect(
                PaceTagParsers.transcriptIsLikelyScreenReferential(transcript),
                "Expected '\(transcript)' to match on UI artifact name"
            )
        }
    }

    @Test func capitalisationDoesNotAffectMatch() async throws {
        #expect(PaceTagParsers.transcriptIsLikelyScreenReferential("CLICK THE BUTTON"))
        #expect(PaceTagParsers.transcriptIsLikelyScreenReferential("Where Is The Menu"))
    }
}
