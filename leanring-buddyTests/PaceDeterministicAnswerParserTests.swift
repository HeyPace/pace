//
//  PaceDeterministicAnswerParserTests.swift
//  leanring-buddyTests
//

import Testing

@testable import Pace

struct PaceDeterministicAnswerParserTests {
    @Test func parsesNaturalLanguageMultiplicationExactly() {
        let result = PaceDeterministicAnswerParser.parse(
            transcript: "What is 9 multiplied by 9? Reply with only the result."
        )

        #expect(result?.spokenText == "81")
        #expect(result?.routingDetail == "deterministic arithmetic · multiplication")
    }

    @Test func parsesSymbolicAdditionExactly() {
        let result = PaceDeterministicAnswerParser.parse(
            transcript: "What is 17 + 25? Reply with only the number."
        )

        #expect(result?.spokenText == "42")
    }

    @Test func parsesSubtractionWithNegativeOperand() {
        let result = PaceDeterministicAnswerParser.parse(
            transcript: "Calculate -4 minus 7"
        )

        #expect(result?.spokenText == "-11")
    }

    @Test func parsesDecimalDivisionWithFriendlyPrecision() {
        let result = PaceDeterministicAnswerParser.parse(
            transcript: "How much is 1 divided by 3?"
        )

        #expect(result?.spokenText == "0.33333333")
    }

    @Test func rejectsDivisionByZeroWithoutPlanner() {
        let result = PaceDeterministicAnswerParser.parse(
            transcript: "What is 10 divided by 0?"
        )

        #expect(result?.spokenText == "I can’t divide by zero.")
    }

    @Test func acceptsWakePrefixAndMultiplicationSymbol() {
        let result = PaceDeterministicAnswerParser.parse(
            transcript: "Hey Pace, calculate 12 × 4"
        )

        #expect(result?.spokenText == "48")
    }

    @Test func doesNotCaptureOpenEndedMathQuestions() {
        #expect(
            PaceDeterministicAnswerParser.parse(
                transcript: "Explain why multiplication works"
            ) == nil)
        #expect(
            PaceDeterministicAnswerParser.parse(
                transcript: "What is the square root of 81?"
            ) == nil)
    }
}
