//
//  PaceFastActionExpandedKeyboardTests.swift
//  leanring-buddyTests
//
//  Lever #5 — expanded keyboard fast-paths. Each pattern below
//  short-circuits the planner entirely: when these utterances
//  match, latency drops from ~hundreds of ms (model + TTFT +
//  TTS) to single-digit ms (parse + post a key event).
//
//  Tests are deliberately written one-pattern-per-test so a
//  future regression points at the exact phrase that broke.
//

import Foundation
import Testing
@testable import Pace

struct PaceFastActionExpandedKeyboardTests {

    @Test func lockScreenPhrasesShortCircuitToControlCommandQ() async throws {
        let phrases = [
            "lock", "lock my mac", "lock the mac",
            "lock screen", "lock my screen", "lock the screen",
        ]
        for phrase in phrases {
            let result = PaceFastActionCommandParser.parse(transcript: phrase)
            #expect(result != nil, "Expected fast-path match for: \(phrase)")
            #expect(result?.spokenText == "locking.")
        }
    }

    @Test func screenshotPhrasesShortCircuitToCommandShift3() async throws {
        let phrases = [
            "screenshot", "take a screenshot",
            "capture screen", "capture the screen",
        ]
        for phrase in phrases {
            let result = PaceFastActionCommandParser.parse(transcript: phrase)
            #expect(result != nil, "Expected fast-path match for: \(phrase)")
            #expect(result?.spokenText == "screenshot taken.")
        }
    }

    @Test func regionScreenshotPhrasesShortCircuitToCommandShift4() async throws {
        let result = PaceFastActionCommandParser.parse(transcript: "capture region")
        #expect(result?.spokenText == "select the area.")
    }

    @Test func hideAppPhrasesShortCircuitToCommandH() async throws {
        let phrases = ["hide window", "hide this app", "hide the app", "command h", "cmd h"]
        for phrase in phrases {
            let result = PaceFastActionCommandParser.parse(transcript: phrase)
            #expect(result?.spokenText == "hiding.", "Failed for: \(phrase)")
        }
    }

    @Test func minimizePhrasesShortCircuitToCommandM() async throws {
        let result = PaceFastActionCommandParser.parse(transcript: "minimize window")
        #expect(result?.spokenText == "minimizing.")
    }

    @Test func missionControlPhrasesShortCircuit() async throws {
        let phrases = ["mission control", "show all windows"]
        for phrase in phrases {
            let result = PaceFastActionCommandParser.parse(transcript: phrase)
            #expect(result?.spokenText == "mission control.", "Failed for: \(phrase)")
        }
    }

    @Test func showDesktopPhrasesShortCircuit() async throws {
        let result = PaceFastActionCommandParser.parse(transcript: "show desktop")
        #expect(result?.spokenText == "showing the desktop.")
    }

    @Test func copyAndPasteAndSelectAllAreFastPaths() async throws {
        #expect(PaceFastActionCommandParser.parse(transcript: "copy")?.spokenText == "copied.")
        #expect(PaceFastActionCommandParser.parse(transcript: "paste")?.spokenText == "pasting.")
        #expect(
            PaceFastActionCommandParser.parse(transcript: "select all")?.spokenText
                == "all selected."
        )
    }

    @Test func findOnPageIsAFastPath() async throws {
        #expect(PaceFastActionCommandParser.parse(transcript: "find on page")?.spokenText == "find ready.")
    }

    @Test func reloadPageIsAFastPath() async throws {
        let phrases = ["refresh", "reload", "reload page", "command r"]
        for phrase in phrases {
            let result = PaceFastActionCommandParser.parse(transcript: phrase)
            #expect(result?.spokenText == "reloading.", "Failed for: \(phrase)")
        }
    }

    @Test func wakePrefixesAreStrippedBeforeMatching() async throws {
        // The parser's wake-prefix stripping should let "pace lock"
        // and "hey pace screenshot" hit the same fast-paths.
        #expect(
            PaceFastActionCommandParser.parse(transcript: "pace lock")?.spokenText == "locking."
        )
        #expect(
            PaceFastActionCommandParser.parse(transcript: "hey pace screenshot")?.spokenText
                == "screenshot taken."
        )
    }

    @Test func trailingPunctuationIsTolerated() async throws {
        // Apple Speech sometimes adds trailing periods; the parser
        // strips them during normalization.
        #expect(PaceFastActionCommandParser.parse(transcript: "lock.")?.spokenText == "locking.")
        #expect(PaceFastActionCommandParser.parse(transcript: "screenshot!")?.spokenText == "screenshot taken.")
    }

    @Test func unrelatedPhrasesDoNotMatchKeyboardShortcuts() async throws {
        // Make sure expanded patterns aren't too greedy. These
        // utterances should NOT be a keyboard-shortcut fast-path —
        // they should fall through (and either hit a different
        // fast-path or return nil).
        let unrelatedKeyboardPhrases = [
            "what time is it",          // not a keyboard shortcut
            "what's on my calendar",    // not a keyboard shortcut
            "summarize this article",   // needs the planner
        ]
        for phrase in unrelatedKeyboardPhrases {
            let result = PaceFastActionCommandParser.parse(transcript: phrase)
            // Result MAY be non-nil if another fast-path matches,
            // but it must NOT use "locking." / "minimizing." /
            // "mission control." etc.
            if let spokenText = result?.spokenText {
                #expect(
                    spokenText != "locking." && spokenText != "minimizing." && spokenText != "mission control.",
                    "Phrase '\(phrase)' incorrectly matched a keyboard shortcut: \(spokenText)"
                )
            }
        }
    }
}
