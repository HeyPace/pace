//
//  PaceDeterministicAnswerParser.swift
//  leanring-buddy
//
//  Exact local answers for routine computations that should never depend on
//  a generative planner. Keeping this parser narrow protects trust without
//  turning Pace into a general symbolic-math engine.
//

import Foundation

nonisolated struct PaceDeterministicAnswerParseResult: Equatable {
    let spokenText: String
    let routingDetail: String
}

nonisolated enum PaceDeterministicAnswerParser {
    static func parse(transcript: String) -> PaceDeterministicAnswerParseResult? {
        let candidateExpression = normalizedCandidateExpression(from: transcript)
        guard !candidateExpression.isEmpty,
            let expressionComponents = parseExpressionComponents(candidateExpression),
            let leftOperand = Decimal(
                string: expressionComponents.leftOperandText,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            let rightOperand = Decimal(
                string: expressionComponents.rightOperandText,
                locale: Locale(identifier: "en_US_POSIX")
            )
        else {
            return nil
        }

        let result: Decimal
        switch expressionComponents.operation {
        case .addition:
            result = leftOperand + rightOperand
        case .subtraction:
            result = leftOperand - rightOperand
        case .multiplication:
            result = leftOperand * rightOperand
        case .division:
            guard rightOperand != 0 else {
                return PaceDeterministicAnswerParseResult(
                    spokenText: "I can’t divide by zero.",
                    routingDetail: "deterministic arithmetic · division by zero"
                )
            }
            result = leftOperand / rightOperand
        }

        return PaceDeterministicAnswerParseResult(
            spokenText: formatted(result),
            routingDetail: "deterministic arithmetic · " + expressionComponents.operation.rawValue
        )
    }

    private enum ArithmeticOperation: String {
        case addition
        case subtraction
        case multiplication
        case division
    }

    private struct ExpressionComponents {
        let leftOperandText: String
        let operation: ArithmeticOperation
        let rightOperandText: String
    }

    private static func normalizedCandidateExpression(from transcript: String) -> String {
        var normalizedTranscript =
            transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for wakePrefix in [
            "hey pace, ", "okay pace, ", "ok pace, ", "pace, ",
            "hey pace ", "okay pace ", "ok pace ", "pace ",
        ] {
            if normalizedTranscript.hasPrefix(wakePrefix) {
                normalizedTranscript.removeFirst(wakePrefix.count)
                break
            }
        }

        if let firstQuestionMarkIndex = normalizedTranscript.firstIndex(of: "?") {
            normalizedTranscript = String(normalizedTranscript[..<firstQuestionMarkIndex])
        } else {
            for answerInstruction in [" reply with", " answer with", " give me only"] {
                if let instructionRange = normalizedTranscript.range(of: answerInstruction) {
                    normalizedTranscript = String(normalizedTranscript[..<instructionRange.lowerBound])
                    break
                }
            }
        }

        let removablePrefixes = [
            "please tell me what is ",
            "tell me what is ",
            "what is the result of ",
            "what's the result of ",
            "how much is ",
            "what is ",
            "what's ",
            "please calculate ",
            "calculate ",
            "please compute ",
            "compute ",
        ]
        for removablePrefix in removablePrefixes {
            if normalizedTranscript.hasPrefix(removablePrefix) {
                normalizedTranscript.removeFirst(removablePrefix.count)
                break
            }
        }

        return
            normalizedTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
    }

    private static func parseExpressionComponents(
        _ candidateExpression: String
    ) -> ExpressionComponents? {
        let numberPattern = #"-?(?:\d+(?:\.\d+)?|\.\d+)"#
        let operationPattern = #"multiplied\s+by|divided\s+by|added\s+to|times|plus|minus|over|[+\-*/x×÷]"#
        let pattern = #"^("# + numberPattern + #")\s*("# + operationPattern + #")\s*("# + numberPattern + #")$"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let fullRange = NSRange(
            candidateExpression.startIndex..<candidateExpression.endIndex,
            in: candidateExpression
        )
        guard
            let match = regularExpression.firstMatch(
                in: candidateExpression,
                range: fullRange
            ),
            match.range.location != NSNotFound,
            match.numberOfRanges == 4,
            let leftOperandRange = Range(match.range(at: 1), in: candidateExpression),
            let operationRange = Range(match.range(at: 2), in: candidateExpression),
            let rightOperandRange = Range(match.range(at: 3), in: candidateExpression)
        else {
            return nil
        }

        let operationText = String(candidateExpression[operationRange])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let operation = arithmeticOperation(for: operationText) else {
            return nil
        }

        return ExpressionComponents(
            leftOperandText: String(candidateExpression[leftOperandRange]),
            operation: operation,
            rightOperandText: String(candidateExpression[rightOperandRange])
        )
    }

    private static func arithmeticOperation(for operationText: String) -> ArithmeticOperation? {
        switch operationText {
        case "+", "plus", "added to":
            return .addition
        case "-", "minus":
            return .subtraction
        case "*", "x", "×", "times", "multiplied by":
            return .multiplication
        case "/", "÷", "over", "divided by":
            return .division
        default:
            return nil
        }
    }

    private static func formatted(_ decimalValue: Decimal) -> String {
        var valueToRound = decimalValue
        var roundedValue = Decimal()
        NSDecimalRound(&roundedValue, &valueToRound, 8, .plain)
        return NSDecimalNumber(decimal: roundedValue).stringValue
    }
}
