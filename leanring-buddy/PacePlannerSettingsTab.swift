//
//  PacePlannerSettingsTab.swift
//  leanring-buddy
//
//  Settings → Planner tab content. The single user-facing tier picker
//  (Local / CLI bridge / Direct API / Apple FM) plus the active-tier
//  configuration sub-panel. See `docs/prds/planner-tier-picker.md`.
//
//  Direct API keys are read from / written to `PaceKeychainStore` via
//  `CompanionManager` helpers; this tab never reads key bytes directly.
//

import AppKit
import SwiftUI

struct PacePlannerSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    // MARK: - Direct API tier state

    /// Buffered API-key text field input. Cleared after Save so the key
    /// is never held in SwiftUI state longer than necessary.
    @State private var directAPIKeyEntryFieldText: String = ""
    /// Outcome of the last "Test" round trip. nil = not yet tested.
    @State private var lastDirectAPITestOutcomeText: String? = nil
    @State private var lastDirectAPITestWasSuccessful: Bool = false
    @State private var isDirectAPITestInFlight: Bool = false
    /// Snapshot of which providers currently have a key stored in
    /// Keychain. Refreshed on view appear and after every save/delete.
    @State private var providersWithStoredDirectAPIKeys: Set<PaceDirectAPIProvider> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            plannerTierPickerSection
            Divider().background(DS.Colors.borderSubtle)
            plannerActiveTierConfigurationSection
        }
        .onAppear {
            refreshProvidersWithStoredDirectAPIKeys()
        }
    }

    private var plannerTierPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backend tier")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            VStack(spacing: 0) {
                ForEach(PacePlannerTier.allCases, id: \.rawValue) { plannerTier in
                    plannerTierRow(plannerTier)
                }
            }
        }
    }

    private func plannerTierRow(_ plannerTier: PacePlannerTier) -> some View {
        let (tierTitle, tierSubtitle) = plannerTierLabels(for: plannerTier)
        let isSelected = companionManager.activePlannerTier == plannerTier
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tierTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(tierSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DS.Colors.accent)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard companionManager.activePlannerTier != plannerTier else { return }
            handlePlannerTierTap(plannerTier)
        }
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    private func plannerTierLabels(for plannerTier: PacePlannerTier) -> (title: String, subtitle: String) {
        switch plannerTier {
        case .local:
            return (
                "Local — LM Studio",
                "On-device reasoner (gemma-3-12b by default). Free. Nothing leaves your Mac."
            )
        case .cliBridge:
            return (
                "CLI bridge",
                "Routes turns through your already-authenticated Claude Code / Codex / Gemini CLI via localhost:3456. Free if you already pay for the CLI."
            )
        case .directAPI:
            return (
                "Direct API (BYO key)",
                "Pace calls Anthropic / OpenAI / OpenRouter directly using a key you paste below. Stored in macOS Keychain only — never in Pace preferences."
            )
        case .appleFoundationModels:
            return (
                "Apple Foundation Models only",
                "Apple's on-device 3B model as the sole planner. Requires Apple Intelligence enabled."
            )
        }
    }

    private func handlePlannerTierTap(_ newPlannerTier: PacePlannerTier) {
        switch newPlannerTier {
        case .local, .appleFoundationModels:
            companionManager.setActivePlannerTier(newPlannerTier)
        case .cliBridge:
            // First-time enablement still goes through the existing
            // NSAlert consent dialog. Rejection reverts to local.
            let consentAccepted = companionManager.requestCloudBridgeConsentIfNeeded()
            guard consentAccepted else {
                companionManager.setActivePlannerTier(.local)
                return
            }
            // If the saved bridge mode is .off (default after first
            // consent), promote it to hybrid so the user immediately
            // benefits from the tier they just picked.
            if companionManager.cloudBridgeMode == .off {
                companionManager.setCloudBridgeMode(.hybrid)
            }
            companionManager.setActivePlannerTier(newPlannerTier)
        case .directAPI:
            // No NSAlert here — the explicit pick is the consent. The
            // sub-panel below requires Save Key + (optionally) Test
            // before turns actually route to the provider.
            companionManager.setActivePlannerTier(newPlannerTier)
        }
    }

    @ViewBuilder
    private var plannerActiveTierConfigurationSection: some View {
        switch companionManager.activePlannerTier {
        case .local:
            plannerLocalDetailPanel
        case .cliBridge:
            plannerCLIBridgeDetailPanel
        case .directAPI:
            plannerDirectAPIDetailPanel
        case .appleFoundationModels:
            plannerAppleFoundationModelsDetailPanel
        }
    }

    private var plannerLocalDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LM Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(companionManager.isLMStudioReachable ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 8, height: 8)
                Text(companionManager.isLMStudioReachable ? "Reachable" : "Not reachable — open LM Studio and load the configured model.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
            }
            Text("Default model: google/gemma-3-12b. Configure model name via Info.plist key LocalPlannerModelIdentifier.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var plannerCLIBridgeDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI bridge")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Configure the upstream CLI, model, and consent in the Cloud bridge tab. This tier reuses that configuration.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Active mode: \(companionManager.cloudBridgeMode.rawValue)  •  Upstream: \(companionManager.cloudBridgeUpstream.displayLabel)  •  Model: \(companionManager.cloudBridgeModel)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var plannerAppleFoundationModelsDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Foundation Models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Free, on-device. Requires Apple Intelligence to be enabled in System Settings. Best for short voice answers and routine tool calls. For harder action plans, upgrade to Local — LM Studio.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            paceSettingsButton("Open Apple Intelligence settings", systemName: "apple.logo") {
                if let appleIntelligenceURL = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension") {
                    NSWorkspace.shared.open(appleIntelligenceURL)
                }
            }
            if companionManager.isLMStudioReachable {
                // LM Studio is already running on the user's machine —
                // surface the upgrade affordance prominently. This is the
                // one-click hop from "first-run default" to "best quality"
                // promised by docs/prds/first-run-experience.md.
                Divider().background(DS.Colors.borderSubtle).padding(.vertical, 4)
                Text("LM Studio is running locally — upgrade for better quality on hard action plans.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                paceSettingsButton("Upgrade to Local — LM Studio", systemName: "arrow.up.circle") {
                    companionManager.setActivePlannerTier(.local)
                }
            }
        }
    }

    private var plannerDirectAPIDetailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: Binding(
                    get: { companionManager.directAPIProvider },
                    set: { newProvider in
                        companionManager.setDirectAPIProvider(newProvider)
                        // Clear the test outcome — provider switch invalidates it.
                        lastDirectAPITestOutcomeText = nil
                    }
                )) {
                    ForEach(PaceDirectAPIProvider.allCases, id: \.rawValue) { directAPIProvider in
                        let storedKeyIndicator = providersWithStoredDirectAPIKeys.contains(directAPIProvider) ? " ✓" : ""
                        Text(directAPIProvider.displayLabel + storedKeyIndicator).tag(directAPIProvider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // API key field + Save/Delete buttons
            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                SecureField("Paste your \(companionManager.directAPIProvider.displayLabel) API key", text: $directAPIKeyEntryFieldText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 10) {
                    let entryFieldTextTrimmed = directAPIKeyEntryFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
                    paceSettingsButton("Save key", systemName: "key.fill") {
                        guard !entryFieldTextTrimmed.isEmpty else { return }
                        let didStore = companionManager.saveDirectAPIKey(
                            entryFieldTextTrimmed,
                            for: companionManager.directAPIProvider
                        )
                        if didStore {
                            directAPIKeyEntryFieldText = ""
                            refreshProvidersWithStoredDirectAPIKeys()
                            lastDirectAPITestOutcomeText = nil
                        }
                    }
                    .disabled(entryFieldTextTrimmed.isEmpty)
                    .opacity(entryFieldTextTrimmed.isEmpty ? 0.45 : 1)

                    paceSettingsButton("Delete key", systemName: "trash") {
                        _ = companionManager.deleteDirectAPIKey(for: companionManager.directAPIProvider)
                        refreshProvidersWithStoredDirectAPIKeys()
                        lastDirectAPITestOutcomeText = nil
                    }
                    .disabled(!providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider))
                    .opacity(providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider) ? 1 : 0.45)
                }
                Text("Keys are stored in macOS Keychain (service com.pace.app.plannerAPIKeys). They never sync via iCloud and never touch UserDefaults, Info.plist, or any log.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Model identifier text field
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    companionManager.directAPIProvider.defaultModelIdentifier,
                    text: Binding(
                        get: { companionManager.directAPIModelIdentifier },
                        set: { companionManager.setDirectAPIModelIdentifier($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            // Custom endpoint URL (only when provider == .custom)
            if companionManager.directAPIProvider == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint URL")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    TextField(
                        "https://example.com/v1/chat/completions",
                        text: Binding(
                            get: { companionManager.directAPICustomEndpointURLString },
                            set: { companionManager.setDirectAPICustomEndpointURLString($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    Text("Must be https. http is only accepted for loopback hosts (local OpenAI-compatible proxies).")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            // Fall-back-on-failure toggle (default OFF per PRD)
            paceSettingsToggleRow(
                title: "Fall back to local on cloud failure",
                subtitle: "Off by default. When on, Pace silently retries failed Direct-API turns against LM Studio. When off, errors surface verbatim so you know what happened.",
                isOn: Binding(
                    get: { companionManager.directAPIFallsBackToLocalOnCloudFailure },
                    set: { companionManager.setDirectAPIFallsBackToLocalOnCloudFailure($0) }
                )
            )

            // Test round-trip button + last outcome row
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    paceSettingsButton(isDirectAPITestInFlight ? "Testing…" : "Test", systemName: "bolt.fill") {
                        runDirectAPITest()
                    }
                    .disabled(
                        isDirectAPITestInFlight
                        || !providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider)
                    )
                    .opacity(
                        (isDirectAPITestInFlight
                         || !providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider))
                        ? 0.45 : 1
                    )

                    if let lastOutcomeText = lastDirectAPITestOutcomeText {
                        HStack(spacing: 6) {
                            Image(systemName: lastDirectAPITestWasSuccessful ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(lastDirectAPITestWasSuccessful ? DS.Colors.success : DS.Colors.warning)
                            Text(lastOutcomeText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer()
                }
                if !providersWithStoredDirectAPIKeys.contains(companionManager.directAPIProvider) {
                    Text("Save an API key for \(companionManager.directAPIProvider.displayLabel) to enable the round-trip test.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
            }
        }
    }

    private func refreshProvidersWithStoredDirectAPIKeys() {
        providersWithStoredDirectAPIKeys = companionManager.providersWithStoredDirectAPIKeys()
    }

    private func runDirectAPITest() {
        isDirectAPITestInFlight = true
        lastDirectAPITestOutcomeText = nil
        Task { @MainActor in
            let testOutcome = await companionManager.runDirectAPITestRoundTrip()
            switch testOutcome {
            case .success(let echoedModelResponse):
                lastDirectAPITestWasSuccessful = true
                lastDirectAPITestOutcomeText = echoedModelResponse.isEmpty
                    ? "OK (empty response)"
                    : echoedModelResponse
            case .failure(let testError):
                lastDirectAPITestWasSuccessful = false
                lastDirectAPITestOutcomeText = testError.localizedDescription
            }
            isDirectAPITestInFlight = false
        }
    }
}
