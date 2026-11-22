//
//  PaceLocalStackDoctorTests.swift
//  leanring-buddyTests
//
//  Tests for PaceLocalStackDoctor's pure classification helpers.
//  All checks that hit the real network are intentionally NOT tested here —
//  only the static helpers that classify already-received response bodies
//  are covered, because those are the logic worth protecting from regressions.
//

import Foundation
import Testing

@testable import Pace

struct PaceLocalStackDoctorTests {

    private final class OfflineServiceProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor
    @Test func directCLIDiagnosticsDoNotRequireLMStudioPlannerOrVision() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineServiceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for upstream in [PaceLocalCLIUpstream.codex, .claude] {
            let checks = await PaceLocalStackDoctor().runChecks(plannerTier: .cliDirect,
                cliUpstream: upstream, readMyScreenEnabled: true, urlSession: session)
            #expect(checks.contains { $0.title == "\(upstream.displayLabel) planner" })
            #expect(!checks.contains { ["LM Studio server", "Planner model loaded", "VLM loaded (Read My Screen)"].contains($0.title) })
            #expect(checks.contains { $0.title == "Screen reading" && $0.status == .info })
            let screenDetail = checks.first { $0.title == "Screen reading" }?.detail ?? ""
            if upstream == .codex {
                #expect(screenDetail.contains("captured images to Codex"))
                #expect(screenDetail.contains("skips local VLM and native OCR"))
            } else {
                #expect(screenDetail.contains("text-only context sent to Claude"))
                #expect(screenDetail.contains("Captured images are not sent"))
            }
            let expectedSpeechProvider = BuddyTTSClientFactory.selectedProvider(
                configuredProvider: AppBundleConfiguration.stringValue(forKey: "TTSProvider"),
                useBundledQwen3: PaceBundledModelsSettings.isUsingQwen3TTSInProcess())
            #expect(checks.contains { $0.title == "TTS sidecar" } == (expectedSpeechProvider == .localServer))
            let recall = checks.first { $0.title.hasPrefix("Semantic recall") }
            #expect(recall != nil && recall?.status != .fail)
            if recall?.status == .warn {
                #expect(recall?.detail.contains("Keyword recall remains available") == true)
            }
        }
    }

    @MainActor
    @Test func disabledScreenReadingDoesNotProbeOrAdvertiseVision() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineServiceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let checks = await PaceLocalStackDoctor().runChecks(plannerTier: .cliDirect,
            cliUpstream: .codex, readMyScreenEnabled: false, urlSession: session)
        #expect(!checks.contains { $0.title == "Screen reading" || $0.title.hasPrefix("VLM loaded") })
    }

    // MARK: - embeddingsResponseStatus

    @Test func embeddingsResponseStatusIsOkForValidEmbeddingArray() {
        let validBody = """
        {
            "object": "list",
            "data": [
                {
                    "object": "embedding",
                    "index": 0,
                    "embedding": [0.12, -0.34, 0.56]
                }
            ],
            "model": "text-embedding-nomic-embed-text-v1.5"
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: validBody)
        #expect(status == .ok)
    }

    @Test func embeddingsResponseStatusIsFailForEmptyEmbeddingArray() {
        // A model that loads as type:llm may return an empty embedding array
        // instead of a proper error — still a failure for our purposes.
        let emptyEmbeddingBody = """
        {
            "data": [
                {
                    "embedding": []
                }
            ]
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: emptyEmbeddingBody)
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailForErrorResponse() {
        // LM Studio returns an error object when no embeddings model is loaded.
        let errorBody = """
        {
            "error": {
                "code": "model_not_found",
                "message": "No models loaded"
            }
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: errorBody)
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailForEmptyBody() {
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: "")
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailForMalformedJSON() {
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: "not json at all {{{")
        #expect(status == .fail)
    }

    @Test func embeddingsResponseStatusIsFailWhenDataKeyIsMissing() {
        // A chat-completion response from a non-embedding model looks like this —
        // no "data" key, so the helper correctly fails.
        let chatCompletionBody = """
        {
            "choices": [
                {"message": {"content": "hello"}}
            ]
        }
        """
        let status = PaceLocalStackDoctor.embeddingsResponseStatus(fromResponseBody: chatCompletionBody)
        #expect(status == .fail)
    }

    // MARK: - modelStateInV0ModelsResponse

    @Test func modelStateIsLoadedWhenIdMatchesAndStateIsLoaded() {
        let responseBody = """
        {
            "data": [
                {
                    "id": "google/gemma-3-12b",
                    "state": "loaded",
                    "type": "llm"
                }
            ]
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .loaded)
    }

    @Test func modelStateIsPresentButNotLoadedWhenStateIsNotLoaded() {
        let responseBody = """
        {
            "data": [
                {
                    "id": "google/gemma-3-12b",
                    "state": "not-loaded",
                    "type": "llm"
                }
            ]
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .presentButNotLoaded)
    }

    @Test func modelStateIsNotFoundWhenIdIsAbsent() {
        let responseBody = """
        {
            "data": [
                {
                    "id": "some-other-model",
                    "state": "loaded"
                }
            ]
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .notFound)
    }

    @Test func modelStateIsNotFoundForEmptyDataArray() {
        let responseBody = """
        {
            "data": []
        }
        """
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .notFound)
    }

    @Test func modelStateIsNotFoundForMalformedJSON() {
        let state = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: "not json {{{",
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(state == .notFound)
    }

    @Test func modelStateIsLoadedWhenMultipleModelsAndTargetIsLoaded() {
        // The list contains several models; only the target should match.
        let responseBody = """
        {
            "data": [
                {
                    "id": "text-embedding-nomic-embed-text-v1.5",
                    "state": "loaded",
                    "type": "embeddings"
                },
                {
                    "id": "google/gemma-3-12b",
                    "state": "loaded",
                    "type": "llm"
                },
                {
                    "id": "ui-venus-1.5-2b",
                    "state": "not-loaded",
                    "type": "vlm"
                }
            ]
        }
        """
        let plannerState = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "google/gemma-3-12b"
        )
        #expect(plannerState == .loaded)

        let vlmState = PaceLocalStackDoctor.modelStateInV0ModelsResponse(
            responseBody: responseBody,
            targetModelIdentifier: "ui-venus-1.5-2b"
        )
        #expect(vlmState == .presentButNotLoaded)
    }

    // MARK: - apiV0Root

    @Test func apiV0RootStripsV1SuffixAndAppendsApiV0() {
        let result = PaceLocalStackDoctor.apiV0Root(fromV1BaseURL: "http://localhost:1234/v1")
        #expect(result == "http://localhost:1234/api/v0")
    }

    @Test func apiV0RootLeavesURLUntouchedWhenNoV1Suffix() {
        // If the URL doesn't end in /v1 (unusual config), it falls back to the
        // original so we don't silently break the endpoint.
        let result = PaceLocalStackDoctor.apiV0Root(fromV1BaseURL: "http://localhost:1234")
        #expect(result == "http://localhost:1234")
    }
}
