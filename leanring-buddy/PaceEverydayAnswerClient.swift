import Foundation

nonisolated struct PaceEverydayQuestion: Equatable, Sendable {
    let currentQuestion: String
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
final class PaceOpenAIResponsesEverydayClient: PaceEverydayAnswerClient {
    static let model = "gpt-6-luna"
    static let instructions = "You are Pace, a concise voice assistant. " + PaceBoundedTextAnswerPlanner.answerInstructions
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

    init(session: URLSession? = nil,
         loadKey: @escaping () -> String? = { PaceKeychainStore.loadAPIKey(for: .openai) },
         isAuthorized: @escaping () -> Bool) {
        self.session = session ?? Self.sharedSession
        self.loadKey = loadKey
        self.isAuthorized = isAuthorized
    }

    func answer(_ question: PaceEverydayQuestion) async throws -> String {
        try Task.checkCancellation()
        guard isAuthorized() else { throw PaceEverydayAnswerError.consentRevoked }
        let startedAt = Date()
        var outcome = "failed"
        defer {
            PaceAPIAuditLog.shared.record(subsystem: "planner.openai.responses", operation: "everyday.answer",
                target: Self.model, durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                outcome: outcome, detail: "route=currentQuestionOnly model=\(Self.model) reasoning=none store=false")
        }
        guard let key = loadKey(), !key.isEmpty else { throw PaceEverydayAnswerError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model, "reasoning": ["effort": "none"], "store": false,
            "max_output_tokens": 1024, "text": ["verbosity": "low"],
            "stream": true, "instructions": Self.instructions, "input": question.currentQuestion,
        ])
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
        let answer = try Self.completedAnswer(data)
        outcome = "completed"
        return answer
    }

    nonisolated static func completedAnswer(_ data: Data) throws -> String {
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
                  let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
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
        return texts.joined(separator: "\n")
    }
}
