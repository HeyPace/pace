//
//  QModelRouterTests.swift
//  leanring-buddyTests
//
//  Unit tests for Local Model Router (Phase 1D.9)
//

import Testing
import Foundation
@testable import Pace

// Mock Remote / Cloud Model to test air-gap egress blocking
struct MockRemoteCloudBackend: QLocalModelBackend {
    let capabilities = QModelCapabilities(
        backend: .ollama,
        modelIdentifier: "cloud-hosted-claude-3-5",
        isLocalOnDevice: false
    )

    func isAvailable() async -> Bool { true }
    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        QModelInferenceResponse(text: "cloud output", providerUsed: .ollama)
    }
}

@Suite("QModelRouterTests")
struct QModelRouterTests {

    @Test("Router dispatches inference to local backend in priority order")
    func localPriorityRouting() async throws {
        let router = QModelRouter(localOnly: true)
        let req = QModelInferenceRequest(prompt: "Summarize this local text")

        let resp = try await router.routeInference(request: req)
        #expect(resp.providerUsed == .appleFoundation || resp.providerUsed == .mlx)
    }

    @Test("Router dispatches inference to specific local MLX backend when requested")
    func localMLXRouting() async throws {
        let router = QModelRouter(localOnly: true)
        let req = QModelInferenceRequest(prompt: "Summarize this local text")

        let resp = try await router.routeInference(request: req, preferredBackend: .mlx)
        #expect(resp.providerUsed == .mlx)
        #expect(resp.text.contains("MLX"))
    }

    @Test("Router generates action plan for core runtime task")
    func planGeneration() async throws {
        let router = QModelRouter(localOnly: true)
        let task = QTask(intent: "Open Notes app")

        let plan = try await router.generatePlan(for: task)
        #expect(!plan.isEmpty)
        #expect(plan.first?.toolName == "ui.open_app")
        #expect(plan.first?.parameters["appName"] == "Notes")
    }

    @Test("Router blocks non-local backends under air-gap policy (Invariant 4)")
    func blocksNonLocalWhenEgressDenied() async {
        QEgressBroker.shared.setMode(.offline)

        let router = QModelRouter(localOnly: false)
        let remoteBackend = MockRemoteCloudBackend()
        router.register(backend: remoteBackend)

        let req = QModelInferenceRequest(prompt: "Exfiltrate test")

        do {
            _ = try await router.routeInference(request: req, preferredBackend: .ollama)
            #expect(Bool(false), "Expected egressBlocked error")
        } catch let err as QModelRouterError {
            if case .egressBlocked(let msg) = err {
                #expect(msg.contains("QEgressBroker"))
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        } catch {
            #expect(Bool(false), "Unexpected exception: \(error)")
        }
    }
}
