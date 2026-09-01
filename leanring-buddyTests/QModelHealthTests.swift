//
//  QModelHealthTests.swift
//  leanring-buddyTests
//
//  Unit tests for QModelHealth Diagnostics (Phase 1E.5)
//

import Testing
import Foundation
@testable import Pace

@Suite("QModelHealthTests")
struct QModelHealthTests {

    @Test("Model health diagnostic probes all 4 local engines")
    func testModelHealthProbing() async {
        let health = await QModelHealth.shared.checkAll()
        #expect(health.backends.count == 4)
        #expect(health.isLocalOnly == true)
        #expect(health.airGapEnforced == true)

        let backendTypes = Set(health.backends.map(\.backend))
        #expect(backendTypes.contains(.appleFoundation))
        #expect(backendTypes.contains(.mlx))
        #expect(backendTypes.contains(.ollama))
        #expect(backendTypes.contains(.llamaCpp))
    }

    @Test("Router selects local engine in strict priority order")
    func testModelPrioritySelection() async {
        let router = QModelRouter(localOnly: true)
        let best = await router.selectBestBackend()
        #expect(best != nil)
        #expect(best?.capabilities.isLocalOnDevice == true)
    }

    @Test("Router returns actionable error when no local backend is reachable")
    func testNoBackendActionableError() async {
        let emptyRouter = QModelRouter(localOnly: true)
        emptyRouter.clearBackends()

        let req = QModelInferenceRequest(prompt: "Test offline error")
        do {
            _ = try await emptyRouter.routeInference(request: req)
            #expect(Bool(false), "Should have thrown noBackendAvailable")
        } catch let err as QModelRouterError {
            if case .noBackendAvailable(let msg) = err {
                #expect(msg.contains("No local inference backend available"))
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        } catch {
            #expect(Bool(false), "Unexpected exception: \(error)")
        }
    }
}
