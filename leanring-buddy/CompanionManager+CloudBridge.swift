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

    static func presentPlannerConsentAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: - Cloud bridge published state

    func setCloudBridgeMode(_ mode: PaceCloudBridgeMode) {
        cloudBridgeMode = mode
        PaceCloudBridgeConsent.saveMode(mode)
        // Rebuild the planner so the new mode takes effect on the next turn
        // without requiring an app restart.
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
    }

    func setCloudBridgeUpstream(_ upstream: PaceCloudBridgeUpstream) {
        cloudBridgeUpstream = upstream
        PaceCloudBridgeConsent.saveUpstream(upstream)
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
    }

    func setCloudBridgeModel(_ model: String) {
        cloudBridgeModel = model
        PaceCloudBridgeConsent.saveModel(model)
        screenSuggestionCoordinator.invalidate(clearAnchor: true)
        screenWatchNoteCoordinator.invalidate()
        plannerClient = BuddyPlannerClientFactory.makeDefault()
        PaceLMStudioModelLoader.warmUpConfiguredModelsAsync(plannerClient: plannerClient)
    }

    /// Shows the one-time cloud-bridge consent NSAlert.
    /// Returns true if the user tapped "Use the bridge", false if they cancelled.
    /// Persists acceptance via `PaceCloudBridgeConsent.acceptConsent()` on approval.
    func requestCloudBridgeConsentIfNeeded(
        presentConsentAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = CompanionManager
            .presentPlannerConsentAlert
    ) -> Bool {
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

            Pace marks off-device turns in amber and logs them locally. In hybrid mode, \
            the bridge handles selected requests. In Always Bridge mode, the default \
            planner sends requests through the bridge.

            You can change the bridge mode in Off-device model settings.
            """
        consentAlert.addButton(withTitle: "Use the bridge")
        consentAlert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let userResponse = presentConsentAlert(consentAlert)
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
    /// clock for unattended scheduled tasks; foreground turns work immediately.
    /// Returns true if the user accepted, false if they cancelled.
    func requestDirectSpawnConsentIfNeeded(
        upstream: PaceLocalCLIUpstream,
        presentConsentAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = CompanionManager
            .presentPlannerConsentAlert
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
        consentAlert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let userResponse = presentConsentAlert(consentAlert)
        let userAccepted = userResponse == .alertFirstButtonReturn

        if userAccepted {
            PaceCloudBridgeConsent.acceptDirectSpawnConsent()
            // Start the 24-hour soak clock now, at consent time — the
            // unattended tasks still wait for it; explicitly selected foreground
            // turns can use the CLI immediately.
            PaceCloudBridgeConsent.markDirectSpawnFirstUsedIfUnset(now: Date())
        }
        return userAccepted
    }
}
