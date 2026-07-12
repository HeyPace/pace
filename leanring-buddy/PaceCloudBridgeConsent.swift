//
//  PaceCloudBridgeConsent.swift
//  leanring-buddy
//
//  Pure decision/state module for the optional cloud-bridge feature.
//  All state persists in UserDefaults under the "pace.cloudBridge." prefix.
//
//  The cloud bridge is the ONLY intentional break of Pace's no-cloud-LLM
//  principle. It is consent-gated: the user must accept an NSAlert before
//  any non-off mode takes effect, and the capsule tints amber while a
//  bridge call is in flight so egress is always visible.
//
//  See docs/prds/cloud-bridge-toggle.md for the full design rationale.
//

import Foundation

/// Which routing mode the user has chosen for the cloud bridge.
/// Default is `.off` — no bridge code runs at all.
nonisolated enum PaceCloudBridgeMode: String, Equatable, Codable, CaseIterable {
    /// Current Pace behavior: local planner only, no bridge code runs.
    case off
    /// Local planner handles action/screen turns; bridge handles turns that
    /// Pace would otherwise refuse as "phoneLargeModel" (too hard locally).
    case hybrid
    /// Every planner call routes through the bridge. Gated behind a 24-hour
    /// soak period so the user has experienced Hybrid before escalating.
    case alwaysBridge
}

/// Which CLI tool the bridge should spawn as the upstream.
nonisolated enum PaceCloudBridgeUpstream: String, Equatable, Codable, CaseIterable {
    case claude
    case codex
    case gemini

    /// Human-readable label for Settings UI and planner displayName.
    var displayLabel: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .gemini: return "Gemini CLI"
        }
    }
}

/// A snapshot of all cloud-bridge preferences at a point in time.
nonisolated struct PaceCloudBridgeConfiguration: Equatable {
    let mode: PaceCloudBridgeMode
    let upstream: PaceCloudBridgeUpstream
    let model: String
    let baseURL: URL
    let hasUserAcceptedConsent: Bool
    /// When the user first successfully routed a turn through the bridge,
    /// used to gate the `alwaysBridge` option behind a 24-hour soak period.
    let firstUsedAt: Date?
}

/// Default bridge endpoint. Must be loopback — validated at use-site by
/// `PaceLocalEndpointGuard.validatedCloudBridgeURL(from:)`.
private let cloudBridgeDefaultBaseURL = URL(string: "http://localhost:3456")!

// MARK: - UserDefaults keys

private enum CloudBridgeUserDefaultsKey: String {
    case mode            = "pace.cloudBridge.mode"
    case upstream        = "pace.cloudBridge.upstream"
    case model           = "pace.cloudBridge.model"
    case hasAcceptedConsent = "pace.cloudBridge.hasAcceptedConsent"
    case firstUsedAt     = "pace.cloudBridge.firstUsedAt"
    // The direct-spawn (`.cliDirect`) path is a DIFFERENT data path from
    // the Node bridge — it spawns the CLI itself rather than talking to a
    // localhost:3456 Node server. Per the privacy design (OpenSpec
    // `codex-general-brain` decision (b)), it gets its own consent flag
    // and soak clock so accepting the bridge does NOT auto-grant the
    // direct-spawn path, and vice versa. Shared store, separate records.
    case hasAcceptedDirectSpawnConsent = "pace.cloudBridge.hasAcceptedDirectSpawnConsent"
    case directSpawnFirstUsedAt        = "pace.cloudBridge.directSpawnFirstUsedAt"
}

// MARK: - PaceCloudBridgeConsent

enum PaceCloudBridgeConsent {

    // MARK: Load

    static func loadConfiguration() -> PaceCloudBridgeConfiguration {
        let plistBaseURLString = AppBundleConfiguration.stringValue(forKey: "CloudBridgeBaseURL")
            ?? cloudBridgeDefaultBaseURL.absoluteString
        let validatedBaseURL = PaceLocalEndpointGuard.validatedCloudBridgeURL(
            from: plistBaseURLString
        )

        let rawMode = UserDefaults.standard.string(
            forKey: CloudBridgeUserDefaultsKey.mode.rawValue
        ) ?? PaceCloudBridgeMode.off.rawValue
        let resolvedMode = PaceCloudBridgeMode(rawValue: rawMode) ?? .off

        let rawUpstream = UserDefaults.standard.string(
            forKey: CloudBridgeUserDefaultsKey.upstream.rawValue
        ) ?? defaultUpstreamFromPlist().rawValue
        let resolvedUpstream = PaceCloudBridgeUpstream(rawValue: rawUpstream) ?? .claude

        let resolvedModel = UserDefaults.standard.string(
            forKey: CloudBridgeUserDefaultsKey.model.rawValue
        ) ?? defaultModelFromPlist()

        let hasAcceptedConsent = UserDefaults.standard.bool(
            forKey: CloudBridgeUserDefaultsKey.hasAcceptedConsent.rawValue
        )

        let firstUsedAt: Date?
        if let storedTimeInterval = UserDefaults.standard.object(
            forKey: CloudBridgeUserDefaultsKey.firstUsedAt.rawValue
        ) as? Double {
            firstUsedAt = Date(timeIntervalSinceReferenceDate: storedTimeInterval)
        } else {
            firstUsedAt = nil
        }

        return PaceCloudBridgeConfiguration(
            mode: resolvedMode,
            upstream: resolvedUpstream,
            model: resolvedModel,
            baseURL: validatedBaseURL,
            hasUserAcceptedConsent: hasAcceptedConsent,
            firstUsedAt: firstUsedAt
        )
    }

    // MARK: Save

    static func saveMode(_ mode: PaceCloudBridgeMode) {
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: CloudBridgeUserDefaultsKey.mode.rawValue
        )
    }

    static func saveUpstream(_ upstream: PaceCloudBridgeUpstream) {
        UserDefaults.standard.set(
            upstream.rawValue,
            forKey: CloudBridgeUserDefaultsKey.upstream.rawValue
        )
    }

    static func saveModel(_ model: String) {
        UserDefaults.standard.set(
            model,
            forKey: CloudBridgeUserDefaultsKey.model.rawValue
        )
    }

    // MARK: Consent

    /// Persist the user's explicit acceptance of the cloud-bridge consent dialog.
    /// Must only be called after the user has tapped "Use the bridge" in the
    /// NSAlert — never call this speculatively.
    static func acceptConsent() {
        UserDefaults.standard.set(
            true,
            forKey: CloudBridgeUserDefaultsKey.hasAcceptedConsent.rawValue
        )
    }

    /// Wipe all bridge state and revert mode to `.off`. Called by "Revoke consent"
    /// in Settings so the user can fully opt out and start fresh.
    static func revokeConsentAndResetAllBridgeState() {
        for key in CloudBridgeUserDefaultsKey.allCases {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
    }

    // MARK: First-use timer

    /// Record the first time a turn was routed through the bridge.
    /// Idempotent — calling this after `firstUsedAt` is already set is a no-op.
    static func markFirstUsedIfUnset(now: Date) {
        let alreadySet = UserDefaults.standard.object(
            forKey: CloudBridgeUserDefaultsKey.firstUsedAt.rawValue
        ) != nil
        guard !alreadySet else { return }
        UserDefaults.standard.set(
            now.timeIntervalSinceReferenceDate,
            forKey: CloudBridgeUserDefaultsKey.firstUsedAt.rawValue
        )
    }

    // MARK: Always-bridge gate

    /// The `alwaysBridge` option requires the user to have used Hybrid mode for
    /// at least 24 hours. This prevents an impulsive switch to maximum cloud egress
    /// without any experience of the costs and latency tradeoffs.
    static func canEnableAlwaysBridge(now: Date) -> Bool {
        guard let storedTimeInterval = UserDefaults.standard.object(
            forKey: CloudBridgeUserDefaultsKey.firstUsedAt.rawValue
        ) as? Double else {
            return false
        }
        let firstUsedAt = Date(timeIntervalSinceReferenceDate: storedTimeInterval)
        let minimumSoakDurationInSeconds: TimeInterval = 24 * 60 * 60
        return now.timeIntervalSince(firstUsedAt) >= minimumSoakDurationInSeconds
    }

    // MARK: Direct-spawn (.cliDirect) consent — separate data path

    /// True iff the user has explicitly accepted the DIRECT-SPAWN consent
    /// dialog. Deliberately NOT the same flag as the Node-bridge
    /// `hasAcceptedConsent`: spawning `codex`/`claude` directly sends the
    /// turn off-device through a different mechanism than the bridge, so
    /// accepting one must not silently grant the other.
    static func hasAcceptedDirectSpawnConsent() -> Bool {
        UserDefaults.standard.bool(
            forKey: CloudBridgeUserDefaultsKey.hasAcceptedDirectSpawnConsent.rawValue
        )
    }

    /// Persist explicit acceptance of the direct-spawn consent dialog.
    /// Must only be called after the user tapped the accept button in the
    /// NSAlert — never speculatively.
    static func acceptDirectSpawnConsent() {
        UserDefaults.standard.set(
            true,
            forKey: CloudBridgeUserDefaultsKey.hasAcceptedDirectSpawnConsent.rawValue
        )
    }

    /// Record the first time a turn was routed through the direct-spawn
    /// path. Idempotent — a later call after the timestamp is set is a
    /// no-op. Its own clock, separate from the bridge's `firstUsedAt`, so
    /// the direct-spawn soak restarts independently.
    static func markDirectSpawnFirstUsedIfUnset(now: Date) {
        let alreadySet = UserDefaults.standard.object(
            forKey: CloudBridgeUserDefaultsKey.directSpawnFirstUsedAt.rawValue
        ) != nil
        guard !alreadySet else { return }
        UserDefaults.standard.set(
            now.timeIntervalSinceReferenceDate,
            forKey: CloudBridgeUserDefaultsKey.directSpawnFirstUsedAt.rawValue
        )
    }

    /// The direct-spawn path is usable only once consent is accepted AND
    /// the same 24-hour soak the bridge uses has elapsed since first use.
    /// On the very FIRST selection there is no `directSpawnFirstUsedAt`
    /// yet — this returns false so the first turn falls back to local with
    /// a logged reason and the soak clock starts ticking (the factory
    /// calls `markDirectSpawnFirstUsedIfUnset` at consent time).
    static func canRunDirectSpawnTurn(now: Date) -> Bool {
        guard hasAcceptedDirectSpawnConsent() else { return false }
        guard let storedTimeInterval = UserDefaults.standard.object(
            forKey: CloudBridgeUserDefaultsKey.directSpawnFirstUsedAt.rawValue
        ) as? Double else {
            return false
        }
        let firstUsedAt = Date(timeIntervalSinceReferenceDate: storedTimeInterval)
        let minimumSoakDurationInSeconds: TimeInterval = 24 * 60 * 60
        return now.timeIntervalSince(firstUsedAt) >= minimumSoakDurationInSeconds
    }

    // MARK: Plist helpers

    private static func defaultUpstreamFromPlist() -> PaceCloudBridgeUpstream {
        let rawString = AppBundleConfiguration.stringValue(
            forKey: "CloudBridgeDefaultUpstream"
        ) ?? "claude"
        return PaceCloudBridgeUpstream(rawValue: rawString.lowercased()) ?? .claude
    }

    private static func defaultModelFromPlist() -> String {
        let upstreamDefault = defaultUpstreamFromPlist()
        let plistModel = AppBundleConfiguration.stringValue(
            forKey: "CloudBridgeDefaultModel"
        )
        if let plistModel, !plistModel.isEmpty {
            return plistModel
        }
        // Sensible per-upstream defaults when the plist key is absent.
        switch upstreamDefault {
        case .claude:  return "sonnet"
        case .codex:   return "gpt-4-1106-preview"
        case .gemini:  return "gemini-2.0-flash"
        }
    }
}

// MARK: - CaseIterable for revokeConsentAndResetAllBridgeState

extension CloudBridgeUserDefaultsKey: CaseIterable {
    static var allCases: [CloudBridgeUserDefaultsKey] {
        [
            .mode, .upstream, .model, .hasAcceptedConsent, .firstUsedAt,
            .hasAcceptedDirectSpawnConsent, .directSpawnFirstUsedAt
        ]
    }
}
