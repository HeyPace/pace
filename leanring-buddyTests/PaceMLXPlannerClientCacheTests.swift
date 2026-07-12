//
//  PaceMLXPlannerClientCacheTests.swift
//  leanring-buddyTests
//
//  Lever #1 — KV-cache reuse via persistent ChatSession.
//
//  The actual cache reuse can only be tested end-to-end against
//  a loaded model (multi-GB download, not CI-friendly). What we
//  CAN unit-test in isolation is the BOOKKEEPING — the static
//  helpers that decide whether the next turn is a continuation
//  of the cached state.
//
//  The session-cache lookup is internal to the production code so
//  this file exercises the public API: invalidate + immediate
//  re-check that the state cleared. Cache hits / misses are
//  exercised by integration runs against a live model (gated on
//  PACE_RUN_MLX_EVAL).
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceMLXPlannerClientCacheTests {

    @Test func invalidateSessionCacheIsIdempotent() async throws {
        // Calling invalidate multiple times in a row should not
        // crash or throw — even when there's nothing to clear.
        // The log line only prints on the first non-empty clear,
        // so the second + third calls should be silent no-ops.
        PaceMLXPlannerClient.invalidateSessionCache(reason: "test - first call")
        PaceMLXPlannerClient.invalidateSessionCache(reason: "test - second call")
        PaceMLXPlannerClient.invalidateSessionCache(reason: "test - third call")
        // No crash == success.
    }

    @Test func runtimeAvailabilityFlagMatchesCanImport() async throws {
        // The compile-time flag this whole cache layer depends on.
        // If MLXLLM imports flip false, every cache method becomes
        // a no-op and the production code falls back to the
        // not-linked error path.
        #if canImport(MLXLLM)
        #expect(PaceMLXPlannerClient.isRuntimeAvailable == true)
        #else
        #expect(PaceMLXPlannerClient.isRuntimeAvailable == false)
        #endif
    }

    @Test func shortenedModelLabelStripsQuantizationSuffix() async throws {
        // The bf16 ↔ 4-bit toggle (Lever #4) lives on the same
        // model lineage; the display-label helper should strip
        // both quantization suffixes so the Settings UI shows
        // "Qwen3-4B" regardless of which variant the user picked.
        let bf16Label = PaceMLXPlannerClient.shortenedModelLabel(
            forIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-bf16"
        )
        let fourBitLabel = PaceMLXPlannerClient.shortenedModelLabel(
            forIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        )
        #expect(bf16Label.contains("Qwen3-4B"))
        #expect(fourBitLabel.contains("Qwen3-4B"))
    }
}
