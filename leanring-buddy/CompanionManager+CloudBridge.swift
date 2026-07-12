//
//  CompanionManager+CloudBridge.swift
//  leanring-buddy
//
//  Extracted from CompanionManager.swift (god-class decomposition Phase A5):
//  cloud bridge mode/upstream/model setters and one-time consent alert.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {

    // MARK: - Cloud bridge published state

    func setCloudBridgeMode(_ mode: PaceCloudBridgeMode) {
        cloudBridgeMode = mode
        PaceCloudBridgeConsent.saveMode(mode)
        // Rebuild the planner so the new mode takes effect on the next turn
        // without requiring an app restart.
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setCloudBridgeUpstream(_ upstream: PaceCloudBridgeUpstream) {
        cloudBridgeUpstream = upstream
        PaceCloudBridgeConsent.saveUpstream(upstream)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    func setCloudBridgeModel(_ model: String) {
        cloudBridgeModel = model
        PaceCloudBridgeConsent.saveModel(model)
        plannerClient = BuddyPlannerClientFactory.makeDefault()
    }

    /// Shows the one-time cloud-bridge consent NSAlert.
    /// Returns true if the user tapped "Use the bridge", false if they cancelled.
    /// Persists acceptance via `PaceCloudBridgeConsent.acceptConsent()` on approval.
    func requestCloudBridgeConsentIfNeeded() -> Bool {
        let currentConfiguration = PaceCloudBridgeConsent.loadConfiguration()
        guard !currentConfiguration.hasUserAcceptedConsent else {
            // Already accepted — no dialog needed.
            return true
        }

        let consentAlert = NSAlert()
        consentAlert.alertStyle = .warning
        consentAlert.messageText = "Send data outside Pace?"
        consentAlert.informativeText = """
The cloud bridge sends your transcript and the planner system \
prompt to the upstream CLI you choose (Claude Code, Codex, or \
Gemini CLI), which in turn calls Anthropic, OpenAI, or Google \
servers respectively. Their data-handling policies apply.

Pace will show an indicator in the menu-bar capsule whenever a \
bridge call is in flight. Push-to-talk text-only turns still \
default to your local planner; the bridge is used only for \
turns Pace would otherwise refuse as "too hard locally."

You can turn this off at any time in Settings → Cloud bridge.
"""
        consentAlert.addButton(withTitle: "Use the bridge")
        consentAlert.addButton(withTitle: "Keep local only")

        NSApp.activate(ignoringOtherApps: true)
        let userResponse = consentAlert.runModal()
        let userAccepted = userResponse == .alertFirstButtonReturn

        if userAccepted {
            PaceCloudBridgeConsent.acceptConsent()
        }
        return userAccepted
    }

    /// Shows the one-time DIRECT-SPAWN consent NSAlert for the
    /// `.cliDirect` tier. This is a DIFFERENT data path from the Node
    /// bridge — Pace spawns your local `codex`/`claude` CLI itself, which
    /// sends the turn off your Mac via that provider — so the bridge
    /// consent does NOT auto-grant it (and vice versa). On acceptance we
    /// persist the direct-spawn consent flag AND start the 24-hour soak
    /// clock so the first real turn is gated exactly like the bridge.
    /// Returns true if the user accepted, false if they cancelled.
    /// The alert defaults to Cancel (the second button is the return key
    /// default is avoided by ordering accept first but the modal's cancel
    /// wiring keeps escape → keep-local).
    func requestDirectSpawnConsentIfNeeded(
        upstream: PaceLocalCLIUpstream
    ) -> Bool {
        guard !PaceCloudBridgeConsent.hasAcceptedDirectSpawnConsent() else {
            // Already accepted — no dialog needed.
            return true
        }

        let consentAlert = NSAlert()
        consentAlert.alertStyle = .warning
        consentAlert.messageText = "Send data outside Pace?"
        consentAlert.informativeText = """
This tier spawns your local \(upstream.displayLabel) CLI directly \
(no bridge server), which sends this turn's transcript and screen \
context off your Mac via that provider — Anthropic for Claude Code, \
OpenAI for Codex. Their data-handling policies apply.

Pace tints the menu-bar capsule amber whenever a direct-spawn turn \
is in flight, and logs each call to the local privacy dashboard.

You can switch back to a local tier at any time in Settings → Planner.
"""
        consentAlert.addButton(withTitle: "Use \(upstream.displayLabel)")
        consentAlert.addButton(withTitle: "Keep local only")

        NSApp.activate(ignoringOtherApps: true)
        let userResponse = consentAlert.runModal()
        let userAccepted = userResponse == .alertFirstButtonReturn

        if userAccepted {
            PaceCloudBridgeConsent.acceptDirectSpawnConsent()
            // Start the 24-hour soak clock now, at consent time — the
            // first real turn is allowed only once it elapses. Mirrors the
            // bridge's "restart the soak gate" behavior on first select.
            PaceCloudBridgeConsent.markDirectSpawnFirstUsedIfUnset(now: Date())
        }
        return userAccepted
    }
}
