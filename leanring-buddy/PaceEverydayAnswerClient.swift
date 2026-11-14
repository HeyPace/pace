import Foundation

nonisolated struct PaceEverydayQuestion: Equatable, Sendable {
    let currentQuestion: String
}

nonisolated struct PacePassiveScreenQuestion: Sendable {
    struct Image: Sendable {
        let jpegData: Data
        let label: String
    }

    struct Exchange: Sendable {
        let user: String
        let assistant: String
    }

    let images: [Image]
    let systemPrompt: String
    let conversationHistory: [Exchange]
    let userPrompt: String

    var imageByteCount: Int { images.reduce(0) { $0 + $1.jpegData.count } }
    var inputCharacterCount: Int {
        systemPrompt.utf8.count + userPrompt.utf8.count
            + images.reduce(0) { $0 + $1.label.utf8.count }
            + conversationHistory.reduce(0) { $0 + $1.user.utf8.count + $1.assistant.utf8.count }
    }
}

@MainActor
protocol PacePassiveScreenAnswerClient {
    func answerScreen(_ question: PacePassiveScreenQuestion) async throws -> String
}

@MainActor
protocol PaceEverydayAnswerClient {
    func answer(_ question: PaceEverydayQuestion) async throws -> String
}

nonisolated enum PaceEverydayAnswerError: Error, LocalizedError {
    case missingKey
    case consentRevoked
    case httpFailure(Int)
    case invalidResponse
    case refused

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Fast answers need an OpenAI key in Planner settings."
        case .consentRevoked: return "Fast answers require the current Codex off-device consent and fast-answer opt-in."
        case .httpFailure(let status): return "OpenAI fast answer failed (HTTP \(status)). Check API access and credits."
        case .invalidResponse: return "OpenAI did not complete a valid text answer."
        case .refused: return "OpenAI declined this fast-answer request."
        }
    }
}

@MainActor
final class PaceOpenAIResponsesEverydayClient: PaceEverydayAnswerClient, PacePassiveScreenAnswerClient {
    static let model = "gpt-6-luna"
    static let instructions = "You are Pace, a concise voice assistant. The current message may come from on-device speech transcription or typing. If asked whether you can hear the user, acknowledge receiving their message; do not claim live microphone or screen status. " + PaceBoundedTextAnswerPlanner.answerInstructions
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
    private let session: URLSession
    private let loadKey: () -> String?
    private let isAuthorized: () -> Bool
    private let auditLog: PaceAPIAuditLog

    init(session: URLSession? = nil,
         loadKey: @escaping () -> String? = { PaceKeychainStore.loadAPIKey(for: .openai) },
         auditLog: PaceAPIAuditLog = .shared,
         isAuthorized: @escaping () -> Bool) {
        self.session = session ?? Self.sharedSession
        self.loadKey = loadKey
        self.isAuthorized = isAuthorized
        self.auditLog = auditLog
    }

    func answer(_ question: PaceEverydayQuestion) async throws -> String {
        try await completedResponse(
            input: question.currentQuestion, instructions: Self.instructions,
            operation: "everyday.answer", route: "currentQuestionOnly",
            inputCharacterCount: Self.instructions.count + question.currentQuestion.count)
    }

    func answerScreen(_ question: PacePassiveScreenQuestion) async throws -> String {
        var input: [[String: Any]] = []
        for exchange in question.conversationHistory {
            input.append(["role": "user", "content": exchange.user])
            input.append(["role": "assistant", "content": exchange.assistant])
        }
        var currentContent: [[String: Any]] = [["type": "input_text", "text": question.userPrompt]]
        for image in question.images {
            currentContent.append(["type": "input_text", "text": image.label])
            currentContent.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64," + image.jpegData.base64EncodedString(),
            ])
        }
        input.append(["role": "user", "content": currentContent])
        return try await completedResponse(
            input: input, instructions: question.systemPrompt,
            operation: "screen.answer", route: "passiveScreenContext",
            inputCharacterCount: question.inputCharacterCount + question.imageByteCount,
            imageByteCount: question.imageByteCount)
    }

    private func completedResponse(
        input: Any, instructions: String, operation: String, route: String,
        inputCharacterCount: Int, imageByteCount: Int = 0
    ) async throws -> String {
        try Task.checkCancellation()
        guard isAuthorized() else { throw PaceEverydayAnswerError.consentRevoked }
        let startedAt = Date()
        var outcome = "failed"
        var inputTokenCount: Int?
        var outputTokenCount: Int?
        var outputCharacterCount: Int?
        defer {
            auditLog.record(
                subsystem: "planner.openai.responses", operation: operation,
                target: Self.model, durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                outcome: outcome, inputCharacterCount: inputCharacterCount,
                outputCharacterCount: outputCharacterCount,
                detail: "route=\(route) model=\(Self.model) reasoning=none store=false imageBytes=\(imageByteCount)",
                inputTokenCount: inputTokenCount, outputTokenCount: outputTokenCount)
        }
        do {
            guard let key = loadKey(), !key.isEmpty else { throw PaceEverydayAnswerError.missingKey }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": Self.model, "reasoning": ["effort": "none"], "store": false,
                "max_output_tokens": 1024, "text": ["verbosity": "low"],
                "stream": true, "instructions": instructions, "input": input,
            ])
            try Task.checkCancellation()
            guard isAuthorized() else { throw PaceEverydayAnswerError.consentRevoked }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw PaceEverydayAnswerError.invalidResponse }
            guard response.statusCode == 200 else { throw PaceEverydayAnswerError.httpFailure(response.statusCode) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw PaceEverydayAnswerError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard isAuthorized() else { throw PaceEverydayAnswerError.consentRevoked }
            let answer = try Self.completedAnswer(data) { inputTokens, outputTokens in
                inputTokenCount = inputTokens
                outputTokenCount = outputTokens
            }
            outputCharacterCount = answer.count
            outcome = "completed"
            return answer
        } catch {
            switch error {
            case is CancellationError: outcome = "cancelled"
            case PaceEverydayAnswerError.consentRevoked: outcome = "consentRevoked"
            case PaceEverydayAnswerError.refused: outcome = "refused"
            case PaceEverydayAnswerError.httpFailure(let status): outcome = "httpFailure=\(status)"
            case PaceEverydayAnswerError.missingKey: outcome = "missingKey"
            case PaceEverydayAnswerError.invalidResponse: outcome = "invalidResponse"
            case let error as URLError where error.code == .cancelled: outcome = "cancelled"
            default: break
            }
            throw error
        }
    }

    nonisolated static func completedAnswer(_ data: Data, reportUsage: ((Int?, Int?) -> Void)? = nil) throws -> String {
        guard data.count <= 1_048_576, let wireText = String(data: data, encoding: .utf8) else {
            throw PaceEverydayAnswerError.invalidResponse
        }
        var completedResponse: [String: Any]?
        var dataLines: [String] = []
        func consumeEvent() throws {
            guard !dataLines.isEmpty else { return }
            defer { dataLines.removeAll() }
            let payload = dataLines.joined(separator: "\n")
            if payload == "[DONE]" { return }
            guard let bytes = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let type = event["type"] as? String else { throw PaceEverydayAnswerError.invalidResponse }
            guard completedResponse == nil else { throw PaceEverydayAnswerError.invalidResponse }
            if type == "response.refusal.delta" || type == "response.refusal.done" { throw PaceEverydayAnswerError.refused }
            if type == "response.failed" || type == "response.incomplete" || type == "error" {
                throw PaceEverydayAnswerError.invalidResponse
            }
            if type == "response.completed" {
                guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else {
                    throw PaceEverydayAnswerError.invalidResponse
                }
                completedResponse = response
            }
        }
        for line in wireText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { try consumeEvent() }
            else if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            else if !line.hasPrefix("event:") && !line.hasPrefix(":") { throw PaceEverydayAnswerError.invalidResponse }
        }
        // A truncated final event is never a successful completion.
        guard dataLines.isEmpty, let completedResponse,
              let output = completedResponse["output"] as? [[String: Any]] else { throw PaceEverydayAnswerError.invalidResponse }
        var texts: [String] = []
        for item in output {
            guard item["type"] as? String == "message", item["role"] as? String == "assistant",
                  item["status"] as? String == "completed", let content = item["content"] as? [[String: Any]] else {
                throw PaceEverydayAnswerError.invalidResponse
            }
            for part in content {
                if part["type"] as? String == "refusal" { throw PaceEverydayAnswerError.refused }
                guard part["type"] as? String == "output_text", let text = part["text"] as? String else {
                    throw PaceEverydayAnswerError.invalidResponse
                }
                texts.append(text)
            }
        }
        let usage = completedResponse["usage"] as? [String: Any]
        func nonnegativeCount(_ key: String) -> Int? {
            guard let count = usage?[key] as? Int, count >= 0 else { return nil }
            return count
        }
        reportUsage?(nonnegativeCount("input_tokens"), nonnegativeCount("output_tokens"))
        return texts.joined(separator: "\n")
    }
}
