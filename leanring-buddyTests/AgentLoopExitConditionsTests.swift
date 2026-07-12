//
//  AgentLoopExitConditionsTests.swift
//  leanring-buddyTests
//
//  The plan-act-observe loop in `CompanionManager` has two pure
//  decisions it makes every step: (a) did the planner signal [DONE]?
//  (b) how many steps may we run? Both live on `PaceTagParsers` after
//  the May-2026 extraction — testable without standing up the whole
//  pipeline (which needs TCC permissions we can't get under xcodebuild
//  test).
//

import Testing
@testable import Pace

struct AgentLoopExitConditionsTests {

    // MARK: - parseAndStripDoneSignal

    @Test func responseWithoutDoneTagReportsNotDone() async throws {
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "clicking save now")
        #expect(result.didSignalDone == false)
        #expect(result.strippedText == "clicking save now")
    }

    @Test func responseWithDoneTagReportsDoneAndStripsIt() async throws {
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "saved. [DONE]")
        #expect(result.didSignalDone == true)
        #expect(result.strippedText == "saved.")
    }

    @Test func doneTagIsCaseInsensitive() async throws {
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "okay [done]")
        #expect(result.didSignalDone == true)
        #expect(result.strippedText == "okay")
    }

    @Test func multipleDoneTagsAllStrippedAndStillSignalsDone() async throws {
        // Defensive: a planner could emit [DONE] more than once. We
        // strip every occurrence and still report didSignalDone=true.
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "[DONE] all good [DONE]")
        #expect(result.didSignalDone == true)
        #expect(result.strippedText == "all good")
    }

    @Test func doneTagSurroundedByWhitespaceTrimsCleanly() async throws {
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "ok\n  [DONE]   ")
        #expect(result.didSignalDone == true)
        #expect(result.strippedText == "ok")
    }

    @Test func emptyInputReturnsEmptyNotDone() async throws {
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "")
        #expect(result.didSignalDone == false)
        #expect(result.strippedText == "")
    }

    @Test func doneTextWithoutBracketsDoesNotTrigger() async throws {
        // Plain word "done" in narration must NOT be treated as the exit
        // signal — only the bracketed [DONE] tag.
        let result = PaceTagParsers.parseAndStripDoneSignal(from: "the task is done now")
        #expect(result.didSignalDone == false)
        #expect(result.strippedText == "the task is done now")
    }

    // MARK: - readMaxAgentStepCount

    @Test func maxAgentStepCountReturnsDefaultWhenPlistAbsent() async throws {
        // The Info.plist key may or may not be present at test time.
        // Either way, the function must return a value in the
        // documented [1, 30] range.
        let stepCount = PaceTagParsers.readMaxAgentStepCount()
        #expect(stepCount >= 1)
        #expect(stepCount <= 30)
    }
}
