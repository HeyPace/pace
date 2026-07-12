//
//  PaceBundledModelsSettingsTab.swift
//  leanring-buddy
//
//  Settings → Models tab. Toggles + model identifiers for the
//  in-process MLX runtime. Default state is OFF — existing users
//  must explicitly opt in. The runtime-status row at the top
//  surfaces whether the `mlx-swift-examples` SPM dependency is
//  actually linked, so users aren't left guessing.
//
//  First inference call after enabling the toggle triggers a one-
//  time HuggingFace download via the Hub package built into
//  mlx-swift-examples (~2-3 GB for the 4B planner, ~250 MB for the
//  nomic embedder). No progress UI in this view — the download is
//  blocking on the first turn, and the panel HUD's "thinking…"
//  state already covers that wait visually.
//

import AppKit
import SwiftUI

struct PaceBundledModelsSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var downloadManager = PaceModelDownloadManager.shared

    @State private var isUsingMLXPlanner: Bool = false
    @State private var isUsingMLXEmbedder: Bool = false
    @State private var isUsingMLXVLM: Bool = false
    @State private var isUsingQwen3TTS: Bool = false
    @State private var plannerModelIdentifier: String = ""
    @State private var embedderModelIdentifier: String = ""
    @State private var vlmModelIdentifier: String = ""
    @State private var isPaceTunedTurnExportEnabled: Bool = PaceUserPreferencesStore
        .bool(.isPaceTunedTurnExportEnabled, default: true)

    // Prefetch state — drives the "Download now" UX so users can
    // warm the model on wifi before the first PTT pays the cost.
    @State private var isPlannerPrefetchInFlight: Bool = false
    @State private var plannerPrefetchProgressFraction: Double = 0
    @State private var lastPlannerPrefetchOutcome: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            runtimeStatusSection
            Divider().background(DS.Colors.borderSubtle)
            memoryBudgetSection
            Divider().background(DS.Colors.borderSubtle)
            plannerSection
            Divider().background(DS.Colors.borderSubtle)
            embedderSection
            Divider().background(DS.Colors.borderSubtle)
            vlmSection
            Divider().background(DS.Colors.borderSubtle)
            ttsSection
            Divider().background(DS.Colors.borderSubtle)
            paceTunedExportSection
            Divider().background(DS.Colors.borderSubtle)
            qualityCaveatSection
        }
        .onAppear {
            loadCurrentSettings()
            downloadManager.refreshStates()
        }
    }

    // MARK: - VLM section (Phase C)

    private var vlmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXVLM) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX vision model")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run Qwen3-VL screen analysis via mlx-swift in-process. Drops LM Studio's max-loaded-models requirement for the VLM path. Same model as the LM Studio default — quality unchanged, latency improves by removing the HTTP loopback.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXScreenAnalysisClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXVLM) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessVLM(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "mlx-community/Qwen3-VL-4B-Instruct-4bit",
                    text: $vlmModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXVLM)
                .onSubmit { commitVLMModelIdentifier() }
                Button("Apply") { commitVLMModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXVLM)
            }
            Text("~2.5 GB download on first use. Memory cost ~3 GB resident while the VLM is loaded.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - TTS section (Phase D)

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingQwen3TTS) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process Qwen3 TTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run text-to-speech via WhisperKit's TTSKit instead of the Kokoro Python sidecar. Drops the start-tts-server.sh dependency. ANE-accelerated, sub-200 ms first-audio-out.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceQwen3TTSClient.isRuntimeAvailable)
            .onChange(of: isUsingQwen3TTS) { _, newValue in
                PaceBundledModelsSettings.setUsingQwen3TTSInProcess(newValue)
            }
            Text("~300 MB download on first use. Voice + language are auto-resolved by TTSKit's defaults; per-voice configuration UI is a follow-up.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Runtime status

    private var runtimeStatusSection: some View {
        let plannerLinked = PaceMLXPlannerClient.isRuntimeAvailable
        let embedderLinked = PaceMLXEmbeddingClient.isRuntimeAvailable
        let summaryText = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: plannerLinked,
            embedderRuntimeAvailable: embedderLinked
        )
        let isHealthy = plannerLinked && embedderLinked
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isHealthy ? .green : .yellow)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("MLX Runtime")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(summaryText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Memory budget + brain picker

    /// RAM-aware "pick your brain + see the memory tradeoff" surface.
    /// Combines a planner-brain picker (who you talk to) with a live
    /// estimate of how much RAM the on-device model stack would occupy,
    /// which shrinks the moment you pick a cloud / Apple-FM brain (the
    /// planner weights no longer need to be resident). Everything keys off
    /// `companionManager.activePlannerTier`, so selecting a different brain
    /// re-renders the budget and the bigger-VLM recommendation
    /// automatically.
    private var memoryBudgetSection: some View {
        // ObservedObject dependency: reading `activePlannerTier` here means
        // this whole section re-renders when the brain picker changes it.
        let activePlannerTier = companionManager.activePlannerTier
        let plannerRunsOnDevice = plannerTierRunsOnDevice(activePlannerTier)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Memory budget")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            memoryBudgetSummaryRow(plannerRunsOnDevice: plannerRunsOnDevice)

            // Brain picker — the quick "who do I talk to?" surface. Reuses
            // the exact same tier-selection + consent machinery as the
            // Planner tab via `selectPlannerTierWithConsent`, so there is
            // no duplicated tier/consent logic here.
            VStack(alignment: .leading, spacing: 4) {
                Text("Planner brain")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                VStack(spacing: 0) {
                    ForEach(PacePlannerTier.allCases, id: \.rawValue) { plannerTier in
                        brainPickerRow(plannerTier, activePlannerTier: activePlannerTier)
                    }
                }
            }

            if !plannerRunsOnDevice {
                Text("Your planner runs off this Mac, so the on-device planner weights don't need to stay resident — that RAM can go to a larger VLM for sharper screen reading. Switch the vision model above to a bigger checkpoint if you want.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // One-line pointer to the full per-tier configuration (upstream
            // sub-picker, API keys, test round-trip) which lives on the
            // Planner tab. Kept as a pointer instead of duplicating those
            // controls here — this surface is the quick brain + RAM view.
            Text("Advanced planner settings → Settings → Planner")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    /// The installed-RAM + estimated-resident-footprint row. The estimate
    /// drops when the planner runs off-device because the planner weights
    /// no longer need to be held in memory.
    private func memoryBudgetSummaryRow(plannerRunsOnDevice: Bool) -> some View {
        let installedRAMGigabytes = Double(ProcessInfo.processInfo.physicalMemory)
            / (1024 * 1024 * 1024)
        let estimatedResidentGigabytes = estimatedOnDeviceModelResidentGigabytes(
            plannerRunsOnDevice: plannerRunsOnDevice
        )
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "memorychip")
                .foregroundColor(DS.Colors.textSecondary)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: "%.0f GB installed · ~%.1f GB for Pace's on-device models",
                    installedRAMGigabytes,
                    estimatedResidentGigabytes
                ))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                Text(plannerRunsOnDevice
                     ? "Planner + vision model held in memory while active."
                     : "Planner runs off-device — only the vision model stays resident, freeing RAM.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func brainPickerRow(
        _ plannerTier: PacePlannerTier,
        activePlannerTier: PacePlannerTier
    ) -> some View {
        let (title, subtitle) = brainPickerLabels(for: plannerTier)
        let isSelected = activePlannerTier == plannerTier
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DS.Colors.accent)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard activePlannerTier != plannerTier else { return }
            // Reuse the shared consent + revert-on-cancel policy; the
            // budget re-renders automatically because it keys off
            // `activePlannerTier`.
            companionManager.selectPlannerTierWithConsent(plannerTier)
        }
        .pointerCursor()
        .overlay(alignment: .bottom) {
            Divider().background(DS.Colors.borderSubtle)
        }
    }

    /// Short brain labels for the RAM-aware quick picker. The Planner tab
    /// owns the long-form descriptions + per-tier config; these are the
    /// compact "who + RAM implication" version.
    private func brainPickerLabels(
        for plannerTier: PacePlannerTier
    ) -> (title: String, subtitle: String) {
        switch plannerTier {
        case .local:
            return ("Local — LM Studio", "On-device reasoner. Free. Uses the most RAM.")
        case .appleFoundationModels:
            return ("Apple Foundation Models", "On-device 3B model. Free. Frees planner RAM.")
        case .cliDirect:
            return ("Codex / Claude CLI (direct)", "Direct-spawns your CLI. Off-device, consent-gated. Frees planner RAM.")
        case .cliBridge:
            return ("CLI bridge", "Routes via your CLI through localhost:3456. Off-device, consent-gated. Frees planner RAM.")
        case .directAPI:
            return ("Direct API (BYO key)", "Calls a cloud provider with your key. Off-device. Frees planner RAM.")
        }
    }

    /// Whether the given tier keeps the planner on this Mac. Off-device
    /// tiers (`.cliBridge`, `.cliDirect`, `.directAPI`) let Pace release
    /// the local planner weights. Note this mirrors the on/off-device
    /// axis, not the live consent state — the estimate is a "what if"
    /// guide, so it treats every off-device tier the same regardless of
    /// whether consent has landed yet.
    private func plannerTierRunsOnDevice(_ plannerTier: PacePlannerTier) -> Bool {
        switch plannerTier {
        case .local, .appleFoundationModels:
            return true
        case .cliBridge, .cliDirect, .directAPI:
            return false
        }
    }

    /// Coarse resident-memory estimate for Pace's on-device model stack.
    /// The local planner is the heavy tenant (~9 GB for the bundled 4B
    /// bf16 checkpoint); the VLM adds ~3 GB when in-process vision is on.
    /// When the planner runs off-device its weights are dropped, so only
    /// the VLM cost remains. Intentionally approximate — this is a "see
    /// the tradeoff" guide, not an allocator.
    private func estimatedOnDeviceModelResidentGigabytes(
        plannerRunsOnDevice: Bool
    ) -> Double {
        let approximateLocalPlannerResidentGigabytes = 9.0
        let approximateVLMResidentGigabytes = 3.0
        var estimate = 0.0
        if plannerRunsOnDevice {
            estimate += approximateLocalPlannerResidentGigabytes
        }
        if PaceBundledModelsSettings.isUsingMLXInProcessVLM() {
            estimate += approximateVLMResidentGigabytes
        }
        return estimate
    }

    // MARK: - Planner section

    private var plannerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXPlanner) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX planner")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run the planner via mlx-swift in-process. Drops the LM Studio install dependency for new users. Default ships with Qwen3-4B-Instruct-2507 bf16 + a plan-then-execute prompt scaffold — high-precision, opt-in.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXPlannerClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXPlanner) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessPlanner(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "mlx-community/Qwen3-4B-Instruct-2507-bf16",
                    text: $plannerModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXPlanner)
                .onSubmit { commitPlannerModelIdentifier() }
                Button("Apply") { commitPlannerModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXPlanner)
            }
            // Fast Mode preset — swaps the bf16 identifier for the
            // 4-bit variant of the same checkpoint. ~2x faster
            // inference, ~3x less RAM, ~1-2 points lower on the
            // FM-fixture eval set. Right call on 16 GB Macs.
            HStack(spacing: 10) {
                Button(action: applyFastModePlannerPreset) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text("Fast mode (4-bit)")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!isUsingMLXPlanner || isOnFastModeIdentifier)
                Button(action: applyHighQualityPlannerPreset) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("High quality (bf16)")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!isUsingMLXPlanner || isOnHighQualityIdentifier)
                Spacer()
            }
            Text("On first use, ~8 GB is downloaded into the HuggingFace cache (~/.cache/huggingface). bf16 trades disk + RAM for materially better accuracy than the 4-bit variant; on 16 GB Macs use Fast mode instead. Subsequent launches load from cache.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Prefetch button — lets the user warm the model on
            // wifi instead of paying the multi-GB download wait on
            // their first PTT.
            HStack(spacing: 10) {
                Button(action: triggerPlannerPrefetch) {
                    HStack(spacing: 6) {
                        if isPlannerPrefetchInFlight {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(isPlannerPrefetchInFlight ? "Downloading…" : "Download now")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPlannerPrefetchInFlight || !PaceMLXPlannerClient.isRuntimeAvailable)
                if isPlannerPrefetchInFlight {
                    ProgressView(value: plannerPrefetchProgressFraction)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.0f%%", plannerPrefetchProgressFraction * 100))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer()
            }
            if let lastPlannerPrefetchOutcome {
                Text(lastPlannerPrefetchOutcome)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func triggerPlannerPrefetch() {
        guard !isPlannerPrefetchInFlight else { return }
        isPlannerPrefetchInFlight = true
        plannerPrefetchProgressFraction = 0
        lastPlannerPrefetchOutcome = nil
        let modelIdentifierSnapshot = PaceBundledModelsSettings.plannerModelIdentifier()
        Task { @MainActor in
            do {
                try await PaceMLXPlannerClient.prefetchModel(
                    modelIdentifier: modelIdentifierSnapshot,
                    progressHandler: { progress in
                        Task { @MainActor in
                            plannerPrefetchProgressFraction = progress.fractionCompleted
                        }
                    }
                )
                lastPlannerPrefetchOutcome = "Downloaded — model ready for first PTT"
                plannerPrefetchProgressFraction = 1.0
            } catch {
                lastPlannerPrefetchOutcome = "Download failed: \(error.localizedDescription)"
            }
            isPlannerPrefetchInFlight = false
        }
    }

    // MARK: - Embedder section

    private var embedderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXEmbedder) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX embedder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run semantic-memory embeddings via mlx-swift in-process. Falls back to Apple NaturalLanguage when the model isn't downloaded yet — safe to flip on.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXEmbeddingClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXEmbedder) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessEmbedder(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "nomic-ai/nomic-embed-text-v1.5",
                    text: $embedderModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXEmbedder)
                .onSubmit { commitEmbedderModelIdentifier() }
                Button("Apply") { commitEmbedderModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXEmbedder)
            }
            Text("~250 MB download on first use. Lower recall than LM Studio's nomic model but works offline with zero install steps.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Pausable download row — shows current state + cancel/
            // resume buttons. Inspired by ORB's pausable model
            // downloads.
            if isUsingMLXEmbedder, let entry = embedderDownloadEntry {
                embedderDownloadRow(entry: entry)
            }
        }
    }

    /// The MLX embedder's download entry from the shared download
    /// manager, if it exists.
    private var embedderDownloadEntry: PaceModelDownloadEntry? {
        PaceModelDownloadManager.shared.entries.first(where: { $0.id == "mlx-embedder" })
    }

    /// Download state row with cancel/resume buttons.
    private func embedderDownloadRow(entry: PaceModelDownloadEntry) -> some View {
        HStack(spacing: 10) {
            switch entry.state {
            case .idle:
                Button("Download now") {
                    PaceModelDownloadManager.shared.startDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
                Text("Not downloaded yet — first use will fetch it.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            case .downloading:
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                Text("Downloading…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Cancel") {
                    PaceModelDownloadManager.shared.cancelDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
            case .cancelled:
                Text("Download cancelled — partial cache saved.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Resume") {
                    PaceModelDownloadManager.shared.startDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
            case .ready:
                Text("Model ready")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.success)
            case .failed(let message):
                Text("Download failed: \(message)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                Spacer()
                Button("Retry") {
                    PaceModelDownloadManager.shared.startDownload(entryId: entry.id)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Pace-tuned dataset export

    private var paceTunedExportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isPaceTunedTurnExportEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Contribute anonymized planner turns")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("On by default. Planner turns — including cloud ones like Codex — append to ~/Library/Application Support/Pace/pace-tuned-turns.jsonl after emails, phone numbers, and home paths are redacted; each turn is tagged with which brain produced it. The file never leaves your Mac. Copy into the repo with bash scripts/export-pace-tuned-turns.sh before training. Turn off to stop collecting.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: isPaceTunedTurnExportEnabled) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isPaceTunedTurnExportEnabled)
                if !newValue {
                    PaceTunedTurnExportTrace.clear()
                }
            }
        }
    }

    // MARK: - Quality caveat

    private var qualityCaveatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Bundled MLX is the right choice when you don't have LM Studio installed and don't want to install it. The 4B planner scores ~3-4 points below qwen3-30b-a3b on Pace's FM-fixture eval set, mostly affecting multi-step agent reasoning. For day-to-day voice turns the gap is small. The embedder is a cleaner swap — Apple NaturalLanguage fallback keeps recall working when the MLX model isn't loaded yet.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings IO

    private func loadCurrentSettings() {
        isUsingMLXPlanner = PaceBundledModelsSettings.isUsingMLXInProcessPlanner()
        isUsingMLXEmbedder = PaceBundledModelsSettings.isUsingMLXInProcessEmbedder()
        isUsingMLXVLM = PaceBundledModelsSettings.isUsingMLXInProcessVLM()
        isUsingQwen3TTS = PaceBundledModelsSettings.isUsingQwen3TTSInProcess()
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
        embedderModelIdentifier = PaceBundledModelsSettings.embedderModelIdentifier()
        vlmModelIdentifier = PaceBundledModelsSettings.vlmModelIdentifier()
    }

    private func commitVLMModelIdentifier() {
        PaceBundledModelsSettings.setVLMModelIdentifier(vlmModelIdentifier)
        vlmModelIdentifier = PaceBundledModelsSettings.vlmModelIdentifier()
    }

    private func commitPlannerModelIdentifier() {
        PaceBundledModelsSettings.setPlannerModelIdentifier(plannerModelIdentifier)
        // Reload in case the setter refused an empty/whitespace value
        // — keeps the field in sync with what was actually persisted.
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }

    private func commitEmbedderModelIdentifier() {
        PaceBundledModelsSettings.setEmbedderModelIdentifier(embedderModelIdentifier)
        embedderModelIdentifier = PaceBundledModelsSettings.embedderModelIdentifier()
    }

    // MARK: - Fast Mode preset helpers (Lever #4)

    /// True when the user's current planner identifier matches the
    /// 4-bit Fast Mode preset. Drives the "Fast mode" button's
    /// disabled state.
    private var isOnFastModeIdentifier: Bool {
        plannerModelIdentifier == PaceBundledModelsSettings.fastModePlannerModelIdentifier
    }

    /// True when the current planner identifier is the bf16
    /// "High quality" preset (the Info.plist shipping default).
    private var isOnHighQualityIdentifier: Bool {
        plannerModelIdentifier == PaceBundledModelsSettings.defaultPlannerModelIdentifier
    }

    private func applyFastModePlannerPreset() {
        let fastIdentifier = PaceBundledModelsSettings.fastModePlannerModelIdentifier
        PaceBundledModelsSettings.setPlannerModelIdentifier(fastIdentifier)
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }

    private func applyHighQualityPlannerPreset() {
        let bf16Identifier = PaceBundledModelsSettings.defaultPlannerModelIdentifier
        PaceBundledModelsSettings.setPlannerModelIdentifier(bf16Identifier)
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }
}
