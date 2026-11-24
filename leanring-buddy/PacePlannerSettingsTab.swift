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

    @State private var showsProviderChoices = false

    // MARK: - Direct API tier state

    /// Buffered API-key text field input. Cleared after Save so the key
    /// is never held in SwiftUI state longer than necessary.
    @State private var directAPIKeyEntryFieldText: String = ""
    /// Outcome of the last "Test" round trip. nil = not yet tested.
    @State private var lastDirectAPITestOutcomeText: String? = nil
    @State private var lastDirectAPITestWasSuccessful: Bool = false
    @State private var currentDirectAPITestID: UUID?
    private var isDirectAPITestInFlight: Bool { currentDirectAPITestID != nil }
    /// Snapshot of which providers currently have a key stored in
    /// Keychain. Refreshed on view appear and after every save/delete.
    @State private var providersWithStoredDirectAPIKeys: Set<PaceDirectAPIProvider> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            defaultPlannerSummary
            DisclosureGroup("Change planning provider", isExpanded: $showsProviderChoices) {
                plannerTierPickerSection.padding(.top, 8)
            }
            .font(DS.Typography.bodyStrong)
            .accessibilityIdentifier("pace.planner.choices")
            Divider().background(DS.Colors.borderSubtle)
            plannerActiveTierConfigurationSection
        }
        .onAppear {
            refreshProvidersWithStoredDirectAPIKeys()
        }
    }

    private var defaultPlannerSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Default planner")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.Colors.textSecondary)
            Text(companionManager.plannerClient.displayName)
                .font(DS.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Text(companionManager.defaultPlannerBoundary.label)
                .font(DS.Typography.calloutStrong)
                .foregroundStyle(
                    companionManager.defaultPlannerBoundary == .onDevice
                        ? DS.Colors.textSecondary : DS.Colors.offDeviceSignal)
            Text("Configured provider: \(plannerTierLabels(for: companionManager.activePlannerTier).title)")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Colors.textSecondary)
            if companionManager.defaultPlannerBoundary == .loopbackEndpoint {
                Text("Pace sends requests to a service on this Mac. That service controls onward routing.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pace.planner.summary")
    }

    private var plannerTierPickerSection: some View {
        VStack(spacing: 0) {
            ForEach(PacePlannerTier.allCases, id: \.rawValue) { plannerTier in
                plannerTierRow(plannerTier)
            }
        }
    }

    private func plannerTierRow(_ plannerTier: PacePlannerTier) -> some View {
        let (tierTitle, tierSubtitle) = plannerTierLabels(for: plannerTier)
        let isSelected = companionManager.activePlannerTier == plannerTier
        return Button {
            guard companionManager.activePlannerTier != plannerTier else { return }
            if companionManager.selectPlannerTierWithConsent(plannerTier) { showsProviderChoices = false }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tierTitle)
                        .font(DS.Typography.bodyStrong)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(tierSubtitle)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
        .pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    private func plannerTierLabels(for plannerTier: PacePlannerTier) -> (title: String, subtitle: String) {
        switch plannerTier {
        case .local:
            return (
                "Local model",
                "Use the configured local model. An enabled CLI bridge can also handle requests."
            )
        case .cliBridge:
            return (
                "CLI bridge",
                "Use Claude Code, Codex, or Gemini through the local bridge. The CLI sends requests to its provider."
            )
        case .cliDirect:
            return (
                "Direct CLI (Codex or Claude)",
                "Send planning requests through your signed-in Codex or Claude CLI. Pace asks for consent and logs off-device calls."
            )
        case .directAPI:
            return (
                "Direct API",
                "Send planning requests to your provider using an API key stored in macOS Keychain."
            )
        case .appleFoundationModels:
            return (
                "Apple Foundation Models",
                "Plan on this Mac using Apple Intelligence. Enable it in System Settings."
            )
        }
    }

    @ViewBuilder
    private var plannerActiveTierConfigurationSection: some View {
        switch companionManager.activePlannerTier {
        case .local:
            plannerLocalDetailPanel
        case .cliBridge:
            plannerCLIBridgeDetailPanel
        case .cliDirect:
            plannerCLIDirectDetailPanel
        case .directAPI:
            plannerDirectAPIDetailPanel
        case .appleFoundationModels:
            plannerAppleFoundationModelsDetailPanel
        }
    }

    private var plannerLocalDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local model settings")
                .font(DS.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            if companionManager.plannerClient is LocalPlannerClient {
                Label(
                    companionManager.isLMStudioReachable
                        ? "LM Studio is reachable" : "Open LM Studio and load your model.",
                    systemImage: companionManager.isLMStudioReachable ? "checkmark.circle" : "exclamationmark.circle"
                )
                .font(DS.Typography.callout)
                .foregroundStyle(companionManager.isLMStudioReachable ? DS.Colors.textSecondary : DS.Colors.warning)
            }
            Text("Manage downloaded models in Models on this Mac.")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var plannerCLIBridgeDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI bridge")
                .font(DS.Typography.sectionTitle)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Choose the CLI and model in Off-device model settings, where you can also review consent.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            Text("Active mode: \(companionManager.cloudBridgeMode.rawValue)  •  Upstream: \(companionManager.cloudBridgeUpstream.displayLabel)  •  Model: \(companionManager.cloudBridgeModel)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var plannerCLIDirectDetailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direct CLI")
                .font(DS.Typography.sectionTitle)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            // Upstream sub-picker (Claude Code / Codex). Reuses the same
            // segmented-picker pattern as the Cloud bridge tab; only the
            // two direct-spawnable upstreams are offered (gemini stays on
            // the Node bridge).
            VStack(alignment: .leading, spacing: 8) {
                Text("Upstream CLI")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: Binding(
                    get: { companionManager.activePlannerTierCLIDirectUpstream },
                    set: { companionManager.setCLIDirectUpstream($0) }
                )) {
                    ForEach([PaceLocalCLIUpstream.codex, PaceLocalCLIUpstream.claude], id: \.rawValue) { upstream in
                        Text(upstream.displayLabel).tag(upstream)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Prerequisite hint — turns red when the chosen binary isn't
            // resolvable on PATH so the user fixes it before the first
            // turn instead of hitting a runtime failure.
            let chosenUpstream = companionManager.activePlannerTierCLIDirectUpstream
            let binaryIsOnPath = PaceLocalCLIPlannerClient.isUpstreamBinaryOnPath(chosenUpstream)
            HStack(spacing: 8) {
                Circle()
                    .fill(binaryIsOnPath ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 8, height: 8)
                Text(binaryIsOnPath
                     ? "`\(chosenUpstream.executableName)` found on PATH."
                     : "needs `\(chosenUpstream.executableName)` on PATH — \(PaceLocalCLIPlannerClient.missingBinaryPreflightMessage(for: chosenUpstream))")
                    .font(.system(size: 11))
                    .foregroundColor(binaryIsOnPath ? DS.Colors.textTertiary : DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }

            if chosenUpstream == .codex {
                paceSettingsToggleRow(
                    title: "Fast everyday answers",
                    subtitle:
                        "While automatic Codex is selected, use OpenAI gpt-6-luna for simple questions and explicit screen summaries or photos. With Read My Screen on, screen answers include current images, screen context and conversation history. Uses your OpenAI API credits. Voice stays local. Save an OpenAI key under Direct API first.",
                    isOn: Binding(
                        get: { companionManager.fastEverydayAnswersEnabled },
                        set: { companionManager.setFastEverydayAnswersEnabled($0) }))
            }

            Text(
                "When this CLI handles a request, it sends the transcript and any included screen context to \(chosenUpstream.displayLabel). Pace marks the turn in amber and logs the call locally."
            )
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var plannerAppleFoundationModelsDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Foundation Models")
                .font(DS.Typography.sectionTitle)
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Free, on-device. Requires Apple Intelligence to be enabled in System Settings. Best for short voice answers and routine tool calls. You can choose another provider at any time."
            )
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            paceSettingsButton("open Apple Intelligence settings", systemName: "apple.logo") {
                if let appleIntelligenceURL = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension") {
                    NSWorkspace.shared.open(appleIntelligenceURL)
                }
            }

        }
    }

    private var plannerDirectAPIDetailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(DS.Typography.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Picker("", selection: Binding(
                    get: { companionManager.directAPIProvider },
                    set: { newProvider in
                            directAPIKeyEntryFieldText = ""
                        companionManager.setDirectAPIProvider(newProvider)
                            invalidateDirectAPITest()
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
                    .font(DS.Typography.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                SecureField("Paste your \(companionManager.directAPIProvider.displayLabel) API key", text: $directAPIKeyEntryFieldText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 10) {
                    let entryFieldTextTrimmed = directAPIKeyEntryFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
                    paceSettingsButton("save key", systemName: "key.fill") {
                        guard !entryFieldTextTrimmed.isEmpty else { return }
                        let didStore = companionManager.saveDirectAPIKey(
                            entryFieldTextTrimmed,
                            for: companionManager.directAPIProvider
                        )
                        if didStore {
                            directAPIKeyEntryFieldText = ""
                            refreshProvidersWithStoredDirectAPIKeys()
                            invalidateDirectAPITest()
                        }
                    }
                    .disabled(entryFieldTextTrimmed.isEmpty)
                    .opacity(entryFieldTextTrimmed.isEmpty ? 0.45 : 1)

                    paceSettingsButton("delete key", systemName: "trash") {
                        _ = companionManager.deleteDirectAPIKey(for: companionManager.directAPIProvider)
                        refreshProvidersWithStoredDirectAPIKeys()
                        invalidateDirectAPITest()
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
                    .font(DS.Typography.sectionTitle)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                TextField(
                    companionManager.directAPIProvider.defaultModelIdentifier,
                    text: Binding(
                        get: { companionManager.directAPIModelIdentifier },
                        set: {
                            invalidateDirectAPITest()
                            companionManager.setDirectAPIModelIdentifier($0)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            // Custom endpoint URL (only when provider == .custom)
            if companionManager.directAPIProvider == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint URL")
                        .font(DS.Typography.sectionTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    TextField(
                        "https://example.com/v1/chat/completions",
                        text: Binding(
                            get: { companionManager.directAPICustomEndpointURLString },
                            set: {
                                invalidateDirectAPITest()
                                companionManager.setDirectAPICustomEndpointURLString($0)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    Text("Must be https. http is only accepted for loopback hosts (local OpenAI-compatible proxies).")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            // Test round-trip button + last outcome row
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    paceSettingsButton(isDirectAPITestInFlight ? "testing…" : "test", systemName: "bolt.fill") {
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

    private func invalidateDirectAPITest() {
        currentDirectAPITestID = nil
        lastDirectAPITestOutcomeText = nil
    }

    private func runDirectAPITest() {
        let testID = UUID()
        currentDirectAPITestID = testID
        lastDirectAPITestOutcomeText = nil
        Task { @MainActor in
            guard currentDirectAPITestID == testID else { return }
            let testOutcome = await companionManager.runDirectAPITestRoundTrip()
            guard currentDirectAPITestID == testID else { return }
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
            currentDirectAPITestID = nil
        }
    }
}
