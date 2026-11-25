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
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!,
                cacheStoragePolicy: .notAllowed)
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
    var beforeReturn: (() -> Void)?
    func resetForNewTurn() {}
    func generateResponseStreaming(
        images: [(data: Data, label: String)], systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        calls += 1
        receivedPrompt = userPrompt
        receivedSystem = systemPrompt
        receivedHistory = conversationHistory
        receivedImages = images
        onTextChunk("Selected answer.")
        beforeReturn?()
        return ("Selected answer.", 0)
    }
}

@MainActor @Suite(.serialized)
struct PaceEverydayAnswerClientTests {
    private func completed(_ text: String, usage: [String: Int]? = nil) throws -> Data {
        var response: [String: Any] = [
            "status": "completed",
            "output": [
                [
                    "type": "message", "role": "assistant", "status": "completed",
                    "content": [["type": "output_text", "text": text]],
                ]
            ],
        ]
        response["usage"] = usage
        let event: [String: Any] = ["type": "response.completed", "response": response]
        return Data(
            ("data: " + String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)! + "\n\n").utf8
        )
    }

    private func client(
        isAuthorized: @escaping () -> Bool = { true },
        loadKey: @escaping () async throws -> String? = { "injected-test-key" },
        invalidateKey: @escaping () -> Void = {},
        auditLog: PaceAPIAuditLog = .shared,
    ) -> PaceOpenAIResponsesEverydayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EverydayURLProtocol.self]
        return PaceOpenAIResponsesEverydayClient(
            session: URLSession(configuration: configuration),
            loadKey: loadKey, invalidateKey: invalidateKey, auditLog: auditLog, isAuthorized: isAuthorized)
    }

    @Test func authenticationRejectionInvalidatesKeyWithoutRetrying() async throws {
        for status in [401, 403] {
            var requests = 0
            var invalidations = 0
            EverydayURLProtocol.handler = { _ in
                requests += 1
                return (status, Data())
            }
            let answerClient = client(invalidateKey: { invalidations += 1 })
            do {
                _ = try await answerClient.answer(.init(currentQuestion: "What is seven times nine?"))
                Issue.record("Expected authentication failure")
            } catch PaceEverydayAnswerError.httpFailure(let receivedStatus) {
                #expect(receivedStatus == status)
            }
            #expect(requests == 1)
            #expect(invalidations == 1)
        }
    }

    @Test func authorizationRevokedDuringCredentialFetchPreventsAPIRequest() async throws {
        var authorized = true
        EverydayURLProtocol.handler = { _ in
            Issue.record("A revoked turn must not send after credential retrieval")
            return (500, Data())
        }
        let answerClient = client(
            isAuthorized: { authorized },
            loadKey: {
                await Task.yield()
                authorized = false
                return "injected-test-key"
            })
        do {
            _ = try await answerClient.answer(.init(currentQuestion: "What is seven times nine?"))
            Issue.record("Expected consent revocation")
        } catch PaceEverydayAnswerError.consentRevoked {}
    }

    @Test func credentialFailureDoesNotExposeProviderErrorDetails() async throws {
        struct PrivateCredentialFailure: LocalizedError {
            var errorDescription: String? { "private-credential-provider-output" }
        }
        EverydayURLProtocol.handler = { _ in
            Issue.record("A failed credential fetch must not send")
            return (500, Data())
        }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let audit = PaceAPIAuditLog(logFileURL: logURL)
        let answerClient = client(loadKey: { throw PrivateCredentialFailure() }, auditLog: audit)
        do {
            _ = try await answerClient.answer(.init(currentQuestion: "What is seven times nine?"))
            Issue.record("Expected unavailable credential")
        } catch PaceEverydayAnswerError.missingKey {}
        let entries = audit.readAllEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.inputCharacterCount == 0)
        #expect(PacePrivacyDashboardAggregator.aggregate(auditEntries: entries).totalOffDeviceCallCount == 0)
    }

    @Test func revocationDuringFailedCredentialFetchDoesNotPromoteToCodex() async throws {
        var authorized = true
        let selected = EverydaySelectedPlanner()
        let answerClient = client(
            isAuthorized: { authorized },
            loadKey: {
                await Task.yield()
                authorized = false
                throw URLError(.cannotConnectToHost)
            })
        let planner = PaceBoundedTextAnswerPlanner(
            everydayClient: answerClient, question: .init(currentQuestion: "What is seven times nine?"),
            selectedPlanner: selected, recordDecision: { _ in })
        do {
            _ = try await planner.generateResponseStreaming(
                images: [], systemPrompt: "", conversationHistory: [], userPrompt: "What is seven times nine?",
                onTextChunk: { _ in Issue.record("Revocation must prevent delivery") })
            Issue.record("Expected consent revocation")
        } catch PaceEverydayAnswerError.consentRevoked {}
        #expect(selected.calls == 0)
    }

    @Test func providerUsageReachesTheAuditWithoutAnotherRequest() async throws {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-everyday-usage-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let auditLog = PaceAPIAuditLog(logFileURL: logURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EverydayURLProtocol.self]
        let response = try completed("63", usage: ["input_tokens": 157, "output_tokens": 2])
        var requestCount = 0
        EverydayURLProtocol.handler = { _ in
            requestCount += 1
            return (200, response)
        }
        let answerClient = PaceOpenAIResponsesEverydayClient(
            session: URLSession(configuration: configuration),
            loadKey: { "injected-test-key" }, auditLog: auditLog, isAuthorized: { true })
        let answer = try await answerClient.answer(.init(currentQuestion: "What is seven times nine?"))
        let entries = auditLog.readAllEntries()
        #expect(answer == "63")
        #expect(requestCount == 1)
        #expect(entries.count == 1)
        let snapshot = PacePrivacyDashboardAggregator.aggregate(auditEntries: entries)
        #expect(snapshot.totalOffDeviceCallCount == 1)
        #expect(snapshot.totalOffDeviceBytesSent > 0)
        #expect(snapshot.perTargetStats.first?.target == "openai/" + PaceOpenAIResponsesEverydayClient.model)
        #expect(entries.first?.inputTokenCount == 157)
        #expect(entries.first?.outputTokenCount == 2)
        #expect(entries.first?.outputCharacterCount == 2)
    }

    @Test func unavailableUsageStaysUnknownInsteadOfBecomingZero() throws {
        let usageSamples: [[String: Int]?] = [nil, ["input_tokens": -1, "output_tokens": -2]]
        for usage in usageSamples {
            var reportedInput: Int?
            var reportedOutput: Int?
            _ = try PaceOpenAIResponsesEverydayClient.completedAnswer(completed("63", usage: usage)) {
                reportedInput = $0
                reportedOutput = $1
            }
            #expect(reportedInput == nil)
            #expect(reportedOutput == nil)
        }
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
            #expect(
                Set(object.keys) == [
                    "model", "reasoning", "store", "stream", "instructions", "input", "max_output_tokens", "text",
                ])
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
        let planner = PaceBoundedTextAnswerPlanner(
            everydayClient: client(),
            question: PaceEverydayQuestion(currentQuestion: "Why does ice float?"), selectedPlanner: selected)
        var chunks: [String] = []
        let answer = try await planner.generateResponseStreaming(
            images: [(Data("IMAGE_SENTINEL".utf8), "image")],
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
            let planner = PaceBoundedTextAnswerPlanner(
                everydayClient: client(),
                question: .init(currentQuestion: "question"), selectedPlanner: selected)
            var chunks: [String] = []
            _ = try await planner.generateResponseStreaming(
                images: [(Data([1]), "image")], systemPrompt: "system",
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
            "data: {\"type\":\"response.refusal.done\"}\n\n",
        ] {
            #expect(throws: (any Error).self) { try PaceOpenAIResponsesEverydayClient.completedAnswer(Data(wire.utf8)) }
        }
    }

    @Test func authorizationAndCancellationNeverFallback() async throws {
        for failure in [URLError(.cancelled), URLError(.userAuthenticationRequired)] {
            EverydayURLProtocol.handler = { _ in throw failure }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedTextAnswerPlanner(
                everydayClient: client(), question: .init(currentQuestion: "q"), selectedPlanner: selected)
            do {
                _ = try await planner.generateResponseStreaming(
                    images: [], systemPrompt: "", conversationHistory: [], userPrompt: "",
                    onTextChunk: { _ in Issue.record("no delivery") })
            } catch {}
            #expect(selected.calls == 0)
        }
        for status in [401, 403, 400] {
            EverydayURLProtocol.handler = { _ in (status, Data()) }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedTextAnswerPlanner(
                everydayClient: client(), question: .init(currentQuestion: "q"), selectedPlanner: selected)
            do {
                _ = try await planner.generateResponseStreaming(
                    images: [], systemPrompt: "", conversationHistory: [], userPrompt: "",
                    onTextChunk: { _ in Issue.record("no delivery") })
            } catch {}
            #expect(selected.calls == 0)
        }
    }

    @Test func fixedInstructionsAcknowledgeMessagesWithoutInventingMicrophoneOrScreenStatus() {
        #expect(
            PaceOpenAIResponsesEverydayClient.instructions.contains(
                "may come from on-device speech transcription or typing"))
        #expect(PaceOpenAIResponsesEverydayClient.instructions.contains("acknowledge receiving their message"))
        #expect(
            PaceOpenAIResponsesEverydayClient.instructions.contains("do not claim live microphone or screen status"))
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

    private func screenQuestion() -> PacePassiveScreenQuestion {
        .init(
            images: [.init(jpegData: Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9]), label: "current display")],
            systemPrompt: "COMPACT_SCREEN_INSTRUCTIONS",
            conversationHistory: [.init(user: "HISTORY_QUESTION", assistant: "HISTORY_ANSWER")],
            userPrompt: "What does this photo show? AX_CURRENT_ELEMENT")
    }

    private func screenAnswer(
        _ planner: PaceBoundedScreenAnswerPlanner,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let question = screenQuestion()
        return try await planner.generateResponseStreaming(
            images: question.images.map { ($0.jpegData, $0.label) }, systemPrompt: question.systemPrompt,
            conversationHistory: question.conversationHistory.map { ($0.user, $0.assistant) },
            userPrompt: question.userPrompt, onTextChunk: onTextChunk
        ).text
    }

    private nonisolated func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw PaceEverydayAnswerError.invalidResponse }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    @Test func screenRequestIncludesActualImagesAXHistoryAndOriginalInstructionsWithoutTools() async throws {
        let question = screenQuestion()
        let response = try completed("The photo shows a red bicycle.")
        var calls = 0
        EverydayURLProtocol.handler = { request in
            calls += 1
            let body = try bodyData(request)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(
                Set(object.keys) == [
                    "model", "reasoning", "store", "stream", "instructions", "input", "max_output_tokens", "text",
                ])
            #expect(object["model"] as? String == "gpt-6-luna")
            #expect(object["store"] as? Bool == false)
            #expect(object["reasoning"] as? [String: String] == ["effort": "none"])
            #expect(object["instructions"] as? String == question.systemPrompt)
            let input = try #require(object["input"] as? [[String: Any]])
            #expect(input.count == 3)
            #expect(input[0]["role"] as? String == "user")
            #expect(input[0]["content"] as? String == "HISTORY_QUESTION")
            #expect(input[1]["role"] as? String == "assistant")
            #expect(input[1]["content"] as? String == "HISTORY_ANSWER")
            let content = try #require(input[2]["content"] as? [[String: Any]])
            #expect(content[0]["text"] as? String == question.userPrompt)
            #expect(content[1]["text"] as? String == question.images[0].label)
            #expect(content[2]["type"] as? String == "input_image")
            #expect(
                content[2]["image_url"] as? String == "data:image/jpeg;base64,"
                    + question.images[0].jpegData.base64EncodedString())
            return (200, response)
        }
        let selected = EverydaySelectedPlanner()
        let planner = PaceBoundedScreenAnswerPlanner(
            screenClient: client(), selectedPlanner: selected,
            isAuthorized: { true }, recordDecision: { _, _ in })
        var chunks: [String] = []
        let answer = try await screenAnswer(planner, onTextChunk: { chunks.append($0) })
        #expect(calls == 1)
        #expect(answer == "The photo shows a red bicycle.")
        #expect(chunks == [answer])
        #expect(selected.calls == 0)
    }

    @Test func screenAuditRecordsImageBytesAndActualProviderUsageWithoutContent() async throws {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "pace-screen-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = PaceAPIAuditLog(logFileURL: logURL)
        let response = try completed("A bicycle.", usage: ["input_tokens": 1200, "output_tokens": 4])
        EverydayURLProtocol.handler = { _ in (200, response) }
        _ = try await client(auditLog: log).answerScreen(screenQuestion())
        let entries = log.readAllEntries()
        #expect(entries.count == 1)
        #expect(PacePrivacyDashboardAggregator.aggregate(auditEntries: entries).totalOffDeviceCallCount == 1)
        #expect(entries.first?.operation == "screen.answer")
        #expect(entries.first?.inputTokenCount == 1200)
        #expect(entries.first?.outputTokenCount == 4)
        #expect(entries.first?.detail?.contains("imageBytes=5") == true)
        #expect(entries.first?.detail?.contains("reasoning=none store=false") == true)
        #expect(entries.first?.inputCharacterCount == screenQuestion().inputCharacterCount + 5)
        let wire = try String(contentsOf: logURL, encoding: .utf8)
        for forbidden in ["AX_CURRENT_ELEMENT", "HISTORY_QUESTION", "A bicycle."] {
            #expect(!wire.contains(forbidden))
        }
    }

    @Test func safeScreenJSONIsNormalizedButActionsAndVisualCommandsAlwaysFallbackOnce() async throws {
        for safe in [
            "A photo of a bicycle.", "{\"spokenText\":\"A photo of a bicycle.\",\"intent\":\"answer\",\"payload\":{}}",
            "{\"spokenText\":\"A photo of a bicycle.\"}",
        ] {
            let response = try completed(safe)
            EverydayURLProtocol.handler = { _ in (200, response) }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedScreenAnswerPlanner(
                screenClient: client(), selectedPlanner: selected,
                isAuthorized: { true }, recordDecision: { _, _ in })
            var chunks: [String] = []
            let answer = try await screenAnswer(planner, onTextChunk: { chunks.append($0) })
            #expect(answer == "A photo of a bicycle.")
            #expect(chunks == [answer])
            #expect(selected.calls == 0)
        }
        let rejected = [
            "", "PACE_USE_SELECTED_PLANNER", "partial [CLICK:1,2]", "Look [POINT:1,2:photo]", "Look [point:1,2:photo]",
            "[DONE]", "[done]",
            "{\"spokenText\":\"Unsafe\",\"intent\":\"action\",\"payload\":{}}",
            "{\"spokenText\":\"Unsafe\",\"intent\":\"answer\",\"payload\":{\"calls\":[]}}",
            "{\"spokenText\":\"Unsafe\",\"actions\":[]}", "{bad", "[1,2]",
        ]
        for unsafe in rejected {
            let response = try completed(unsafe)
            EverydayURLProtocol.handler = { _ in (200, response) }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedScreenAnswerPlanner(
                screenClient: client(), selectedPlanner: selected,
                isAuthorized: { true }, recordDecision: { _, _ in })
            var chunks: [String] = []
            #expect(try await screenAnswer(planner, onTextChunk: { chunks.append($0) }) == "Selected answer.")
            #expect(chunks == ["Selected answer."])
            #expect(selected.calls == 1)
            #expect(selected.receivedPrompt == screenQuestion().userPrompt)
            #expect(selected.receivedSystem == screenQuestion().systemPrompt)
            #expect(selected.receivedImages.first?.data == screenQuestion().images.first?.jpegData)
            #expect(selected.receivedHistory.first?.userPlaceholder == "HISTORY_QUESTION")
        }
    }

    @Test func screenSummaryAcceptsOnlyInactivePointingFields() throws {
        let valid = #"{"spokenText":"The page shows a bicycle.","pointAtElementId":-1,"clickElementId":-1}"#
        #expect(try PaceBoundedScreenAnswerPlanner.validatedSpokenAnswer(valid) == "The page shows a bicycle.")
        for value in ["0", "1", "null", "true", "\"-1\""] {
            for field in ["pointAtElementId", "clickElementId"] {
                let invalid = "{\"spokenText\":\"Unsafe\",\"\(field)\":\(value)}"
                #expect(throws: PaceEverydayAnswerError.self) {
                    try PaceBoundedScreenAnswerPlanner.validatedSpokenAnswer(invalid)
                }
            }
        }
    }

    @Test func screenMalformedSSEMissingKeyAndTransientErrorsPromoteOnlyOnceWithoutPartialSpeech() async throws {
        let responses: [(Int, Data)] = [
            (429, Data()), (503, Data()),
            (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"never speak this\"}\n\n".utf8)),
            (200, Data("data: broken\n\n".utf8)),
            (200, Data("data: {\"type\":\"response.incomplete\"}\n\n".utf8)),
        ]
        for response in responses {
            var calls = 0
            EverydayURLProtocol.handler = { _ in
                calls += 1
                return response
            }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedScreenAnswerPlanner(
                screenClient: client(), selectedPlanner: selected,
                isAuthorized: { true }, recordDecision: { _, _ in })
            var chunks: [String] = []
            _ = try await screenAnswer(planner, onTextChunk: { chunks.append($0) })
            #expect(calls == 1)
            #expect(selected.calls == 1)
            #expect(chunks == ["Selected answer."])
        }
        EverydayURLProtocol.handler = { _ in
            Issue.record("Missing key must not send a request")
            return (500, Data())
        }
        let selected = EverydaySelectedPlanner()
        let planner = PaceBoundedScreenAnswerPlanner(
            screenClient: client(loadKey: { nil }), selectedPlanner: selected,
            isAuthorized: { true }, recordDecision: { _, _ in })
        _ = try await screenAnswer(planner, onTextChunk: { _ in })
        #expect(selected.calls == 1)
    }

    @Test func revokedScreenAuthorizationStopsSendDeliveryAndFallback() async throws {
        var authorized = true
        EverydayURLProtocol.handler = { _ in
            Issue.record("Revoked authorization must not send")
            return (500, Data())
        }
        let deniedClient = client(
            isAuthorized: { authorized },
            loadKey: {
                authorized = false
                return "injected-test-key"
            })
        let deniedSelected = EverydaySelectedPlanner()
        let deniedPlanner = PaceBoundedScreenAnswerPlanner(
            screenClient: deniedClient, selectedPlanner: deniedSelected,
            isAuthorized: { authorized }, recordDecision: { _, _ in })
        do {
            _ = try await screenAnswer(deniedPlanner, onTextChunk: { _ in Issue.record("No revoked delivery") })

            Issue.record("Expected revocation")
        } catch PaceEverydayAnswerError.consentRevoked {}
        #expect(deniedSelected.calls == 0)

        for status in [200, 503] {
            authorized = true
            let response = try completed("Must remain private.")
            EverydayURLProtocol.handler = { _ in
                authorized = false
                return (status, response)
            }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedScreenAnswerPlanner(
                screenClient: client(isAuthorized: { authorized }), selectedPlanner: selected,
                isAuthorized: { authorized }, recordDecision: { _, _ in })
            do {
                _ = try await screenAnswer(planner, onTextChunk: { _ in Issue.record("No revoked delivery") })

                Issue.record("Expected revocation")
            } catch {}
            #expect(selected.calls == 0)
        }

        authorized = true
        EverydayURLProtocol.handler = { _ in (503, Data()) }
        let fallbackSelected = EverydaySelectedPlanner()
        let fallbackPlanner = PaceBoundedScreenAnswerPlanner(
            screenClient: client(), selectedPlanner: fallbackSelected,
            isAuthorized: { authorized }, onSourceSelected: { source in if source == .selected { authorized = false } },
            recordDecision: { _, _ in })
        do {
            _ = try await screenAnswer(fallbackPlanner, onTextChunk: { _ in Issue.record("No revoked delivery") })

            Issue.record("Expected revocation")
        } catch {}
        #expect(fallbackSelected.calls == 0)

        authorized = true
        let suspendedSelected = EverydaySelectedPlanner()
        suspendedSelected.beforeReturn = { authorized = false }
        let suspendedPlanner = PaceBoundedScreenAnswerPlanner(
            screenClient: client(), selectedPlanner: suspendedSelected,
            isAuthorized: { authorized }, recordDecision: { _, _ in })
        do {
            _ = try await screenAnswer(
                suspendedPlanner, onTextChunk: { _ in Issue.record("No revoked fallback delivery") })

            Issue.record("Expected revocation")
        } catch {}
        #expect(suspendedSelected.calls == 1)
    }

    @Test func screenCancellationAuthenticationPolicyAndRefusalNeverFallback() async throws {
        let refusal = Data("data: {\"type\":\"response.refusal.done\"}\n\n".utf8)
        let responses: [(Int, Data)] = [(401, Data()), (403, Data()), (400, Data()), (600, Data()), (200, refusal)]
        for response in responses {
            EverydayURLProtocol.handler = { _ in response }
            let selected = EverydaySelectedPlanner()
            let planner = PaceBoundedScreenAnswerPlanner(
                screenClient: client(), selectedPlanner: selected,
                isAuthorized: { true }, recordDecision: { _, _ in })
            do {
                _ = try await screenAnswer(planner, onTextChunk: { _ in Issue.record("No delivery") })

                Issue.record("Expected failure")
            } catch {}
            #expect(selected.calls == 0)
        }
        EverydayURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let selected = EverydaySelectedPlanner()
        let planner = PaceBoundedScreenAnswerPlanner(
            screenClient: client(), selectedPlanner: selected,
            isAuthorized: { true }, recordDecision: { _, _ in })
        do {
            _ = try await screenAnswer(planner, onTextChunk: { _ in Issue.record("No cancelled delivery") })

            Issue.record("Expected cancellation")
        } catch {}
        #expect(selected.calls == 0)
    }

    @Test func screenTaskCancellationBeforeSendNeverFallsBack() async throws {
        EverydayURLProtocol.handler = { _ in
            Issue.record("Cancelled task must not send")
            return (500, Data())
        }
        let selected = EverydaySelectedPlanner()
        let cancelledClient = client(loadKey: {
            withUnsafeCurrentTask { $0?.cancel() }
            return "injected-test-key"
        })
        let planner = PaceBoundedScreenAnswerPlanner(
            screenClient: cancelledClient, selectedPlanner: selected,
            isAuthorized: { true }, recordDecision: { _, _ in })
        let cancelled = await Task { @MainActor in
            do {
                _ = try await screenAnswer(planner, onTextChunk: { _ in Issue.record("No cancelled delivery") })
                return false
            } catch is CancellationError { return true } catch { return false }
        }.value
        #expect(cancelled)
        #expect(selected.calls == 0)
    }

    @Test func screenFactoryPreservesExplicitModelsAndNonPassiveOrNonCodexRequests() {
        let defaultCodex = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: nil)
        let explicitCodex = PaceLocalCLIPlannerClient(upstream: .codex, modelIdentifier: "gpt-6")
        let claude = PaceLocalCLIPlannerClient(upstream: .claude, modelIdentifier: nil)
        for (selected, passive, enabled, tier, upstream) in [
            (defaultCodex, false, true, PacePlannerTier.cliDirect, PaceLocalCLIUpstream.codex),
            (defaultCodex, true, false, .cliDirect, .codex),
            (explicitCodex, true, true, .cliDirect, .codex),
            (claude, true, true, .cliDirect, .claude),
            (defaultCodex, true, true, .local, .codex),
        ] {
            let planner = BuddyPlannerClientFactory.makePassiveScreenAnswerPlanner(
                usesPassiveScreenPrompt: passive, selectedPlanner: selected, tier: tier, upstream: upstream,
                hasAcceptedDirectSpawnConsent: true, canRunDirectSpawnTurn: true, fastEverydayAnswersEnabled: enabled,
                isScreenReadAuthorized: { true }, onSourceSelected: { _ in })
            #expect(planner is PaceLocalCLIPlannerClient)
        }
        let planner = BuddyPlannerClientFactory.makePassiveScreenAnswerPlanner(
            usesPassiveScreenPrompt: true, selectedPlanner: defaultCodex, tier: .cliDirect, upstream: .codex,
            hasAcceptedDirectSpawnConsent: true, canRunDirectSpawnTurn: true, fastEverydayAnswersEnabled: true,
            isScreenReadAuthorized: { true }, onSourceSelected: { _ in })
        #expect(planner is PaceBoundedScreenAnswerPlanner)
    }

}
