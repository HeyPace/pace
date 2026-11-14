import Foundation
import Testing
@testable import Pace

private final class EverydayURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
private final class EverydaySelectedPlanner: BuddyPlannerClient {
    let displayName = "selected"
    let supportsImageInput = true
    var calls = 0
    var receivedPrompt = ""
    var receivedSystem = ""
    var receivedHistory: [(userPlaceholder: String, assistantResponse: String)] = []
    var receivedImages: [(data: Data, label: String)] = []
    func resetForNewTurn() {}
    func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
        calls += 1; receivedPrompt = userPrompt; receivedSystem = systemPrompt
        receivedHistory = conversationHistory; receivedImages = images
        onTextChunk("Selected answer.")
        return ("Selected answer.", 0)
    }
}

@MainActor @Suite(.serialized)
struct PaceEverydayAnswerClientTests {
    private func completed(_ text: String) throws -> Data {
        let event: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [
            ["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]
        ]]]
        return Data(("data: " + String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)! + "\n\n").utf8)
    }

    private func client() -> PaceOpenAIResponsesEverydayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EverydayURLProtocol.self]
        return PaceOpenAIResponsesEverydayClient(session: URLSession(configuration: configuration),
            loadKey: { "injected-test-key" }, isAuthorized: { true })
    }

    @Test func rawQuestionIsOnlyDynamicDataAndAcceptedOnce() async throws {
        let data = try completed("Ice is less dense than water.")
        EverydayURLProtocol.handler = { request in
            var requestBody = request.httpBody
            if requestBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    bytes.append(buffer, count: count)
                }
                requestBody = bytes
            }
            let body = try #require(requestBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(object.keys) == ["model", "reasoning", "store", "stream", "instructions", "input", "max_output_tokens", "text"])
            #expect(object["input"] as? String == "Why does ice float?")
            #expect(object["instructions"] as? String == PaceOpenAIResponsesEverydayClient.instructions)
            #expect(object["model"] as? String == "gpt-6-luna")
            #expect(object["store"] as? Bool == false)
            #expect((object["reasoning"] as? [String: String]) == ["effort": "none"])
            let wire = String(data: body, encoding: .utf8)!
            for forbidden in ["HISTORY_SENTINEL", "RETRIEVAL_SENTINEL", "AMBIENT_SENTINEL", "IMAGE_SENTINEL"] {
                #expect(!wire.contains(forbidden))
            }
            return (200, data)
        }
        let selected = EverydaySelectedPlanner()
        let planner = PaceBoundedTextAnswerPlanner(everydayClient: client(),
            question: PaceEverydayQuestion(currentQuestion: "Why does ice float?"), selectedPlanner: selected)
        var chunks: [String] = []
        let answer = try await planner.generateResponseStreaming(images: [(Data("IMAGE_SENTINEL".utf8), "image")],
            systemPrompt: "AMBIENT_SENTINEL", conversationHistory: [("HISTORY_SENTINEL", "secret")],
            userPrompt: "RETRIEVAL_SENTINEL", onTextChunk: { chunks.append($0) })
        #expect(answer.text == "Ice is less dense than water.")
        #expect(chunks == [answer.text])
        #expect(selected.calls == 0)
    }

    @Test func rejectedCompletedTextFallsBackWithOriginalContextExactlyOnce() async throws {
        for answer in ["", "PACE_USE_SELECTED_PLANNER", "hello [ACTION:bad]", "{\"actions\":[]}"] {
            let data = try completed(answer)
            EverydayURLProtocol.handler = { _ in (200, data) }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedTextAnswerPlanner(everydayClient: client(),
                question: .init(currentQuestion: "question"), selectedPlanner: selected)
            var chunks: [String] = []
            _ = try await planner.generateResponseStreaming(images: [(Data([1]), "image")], systemPrompt: "system",
                conversationHistory: [("prior", "answer")], userPrompt: "retrieval", onTextChunk: { chunks.append($0) })
            #expect(chunks == ["Selected answer."])
            #expect(selected.calls == 1)
            #expect(selected.receivedSystem == "system")
            #expect(selected.receivedPrompt == "retrieval")
            #expect(selected.receivedHistory.first?.userPlaceholder == "prior")
            #expect(selected.receivedImages.first?.data == Data([1]))
        }
    }

    @Test func malformedIncompleteAndRefusedEventsNeverAcceptPartialText() async throws {
        for wire in [
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"unsafe partial\"}\n\n",
            "data: broken\n\n", "data: {\"type\":\"response.incomplete\"}\n\n",
            "data: {\"type\":\"response.refusal.done\"}\n\n"
        ] {
            #expect(throws: (any Error).self) { try PaceOpenAIResponsesEverydayClient.completedAnswer(Data(wire.utf8)) }
        }
    }

    @Test func authorizationAndCancellationNeverFallback() async throws {
        for failure in [URLError(.cancelled), URLError(.userAuthenticationRequired)] {
            EverydayURLProtocol.handler = { _ in throw failure }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedTextAnswerPlanner(everydayClient: client(), question: .init(currentQuestion: "q"), selectedPlanner: selected)
            do { _ = try await planner.generateResponseStreaming(images: [], systemPrompt: "", conversationHistory: [], userPrompt: "", onTextChunk: { _ in Issue.record("no delivery") }) }
            catch {}
            #expect(selected.calls == 0)
        }
        for status in [401, 403, 400] {
            EverydayURLProtocol.handler = { _ in (status, Data()) }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedTextAnswerPlanner(everydayClient: client(), question: .init(currentQuestion: "q"), selectedPlanner: selected)
            do { _ = try await planner.generateResponseStreaming(images: [], systemPrompt: "", conversationHistory: [], userPrompt: "", onTextChunk: { _ in Issue.record("no delivery") }) }
            catch {}
            #expect(selected.calls == 0)
        }
    }

    @Test func fixedInstructionsAcknowledgeMessagesWithoutInventingMicrophoneOrScreenStatus() {
        #expect(PaceOpenAIResponsesEverydayClient.instructions.contains("may come from on-device speech transcription or typing"))
        #expect(PaceOpenAIResponsesEverydayClient.instructions.contains("acknowledge receiving their message"))
        #expect(PaceOpenAIResponsesEverydayClient.instructions.contains("do not claim live microphone or screen status"))
    }

    @Test func optInDefaultsFalseAndUsesNormalSetter() {
        let name = "PaceEverydayAnswerTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!PacePlannerTierStore.fastEverydayAnswersEnabled(defaults: defaults))
        PacePlannerTierStore.setFastEverydayAnswersEnabled(true, defaults: defaults)
        #expect(PacePlannerTierStore.fastEverydayAnswersEnabled(defaults: defaults))
        PacePlannerTierStore.setFastEverydayAnswersEnabled(false, defaults: defaults)
        #expect(!PacePlannerTierStore.fastEverydayAnswersEnabled(defaults: defaults))
    }
}
