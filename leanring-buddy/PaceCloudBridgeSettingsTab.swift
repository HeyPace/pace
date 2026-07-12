//
//  PaceCloudBridgeSettingsTab.swift
//  leanring-buddy
//
//  Settings → Cloud bridge tab content. The opt-in surface for routing
//  turns through the local-ai Node bridge at localhost:3456, which
//  spawns the user's already-authenticated Claude Code / Codex / Gemini
//  CLI and forwards prompts to its cloud provider. This is the only
//  intentional break of Pace's on-device principle and is consent-gated
//  via `PaceCloudBridgeConsent`.
//

import SwiftUI

struct PaceCloudBridgeSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    /// Reachability result from `GET /health` on the bridge endpoint.
    /// nil = not yet checked, true = reachable, false = unreachable.
    @State private var cloudBridgeIsReachable: Bool? = nil
    @State private var cloudBridgeReachabilityLastCheckedAt: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Explanation banner
            VStack(alignment: .leading, spacing: 6) {
                Text("Opt-in only. Default is Off.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("The cloud bridge routes turns through the local-ai Node server at localhost:3456, which spawns your already-authenticated CLI tool and contacts its cloud provider. This is the only intentional break of Pace's on-device-only principle. First enablement shows a consent dialog.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(DS.Colors.borderSubtle)

            // Mode picker
            VStack(spacing: 0) {
                let canEnableAlwaysBridge = PaceCloudBridgeConsent.canEnableAlwaysBridge(now: Date())

                ForEach(PaceCloudBridgeMode.allCases, id: \.rawValue) { mode in
                    let modeDisplayName: String = {
                        switch mode {
                        case .off:          return "Off (local only)"
                        case .hybrid:       return "Hybrid (bridge for complex turns)"
                        case .alwaysBridge: return "Always bridge"
                        }
                    }()
                    let modeSubtitle: String = {
                        switch mode {
                        case .off:
                            return "Default. No bridge code runs."
                        case .hybrid:
                            return "Bridge handles turns your local planner would refuse. Local planner stays for everything else."
                        case .alwaysBridge:
                            return canEnableAlwaysBridge
                                ? "Every planner call routes through the bridge."
                                : "Available after 24 hours of Hybrid usage."
                        }
                    }()
                    let isDisabled = mode == .alwaysBridge && !canEnableAlwaysBridge

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(modeDisplayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(isDisabled ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                            Text(modeSubtitle)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer()
                        if companionManager.cloudBridgeMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(DS.Colors.accent)
                        }
                    }
                    .padding(.vertical, 12)
                    .opacity(isDisabled ? 0.5 : 1.0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isDisabled else { return }
                        guard mode != companionManager.cloudBridgeMode else { return }

                        if mode != .off {
                            let consentAccepted = companionManager.requestCloudBridgeConsentIfNeeded()
                            guard consentAccepted else {
                                // User rejected consent — revert mode to off.
                                companionManager.setCloudBridgeMode(.off)
                                return
                            }
                        }
                        companionManager.setCloudBridgeMode(mode)
                    }
                    .overlay(alignment: .bottom) {
                        Divider().background(DS.Colors.borderSubtle)
                    }
                }
            }

            Divider().background(DS.Colors.borderSubtle)

            // Upstream picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Upstream CLI")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Picker("", selection: Binding(
                    get: { companionManager.cloudBridgeUpstream },
                    set: { companionManager.setCloudBridgeUpstream($0) }
                )) {
                    ForEach(PaceCloudBridgeUpstream.allCases, id: \.rawValue) { upstream in
                        Text(upstream.displayLabel).tag(upstream)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Model text field
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                let modelPlaceholder: String = {
                    switch companionManager.cloudBridgeUpstream {
                    case .claude:  return "sonnet"
                    case .codex:   return "gpt-4-1106-preview"
                    case .gemini:  return "gemini-2.0-flash"
                    }
                }()

                TextField(modelPlaceholder, text: Binding(
                    get: { companionManager.cloudBridgeModel },
                    set: { companionManager.setCloudBridgeModel($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }

            // Bridge URL (read-only)
            let bridgeURLString = PaceCloudBridgeConsent.loadConfiguration().baseURL.absoluteString
            VStack(alignment: .leading, spacing: 4) {
                Text("Bridge URL")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(bridgeURLString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                Text("Set via Info.plist key CloudBridgeBaseURL. Must be loopback.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Reachability row
            HStack(spacing: 10) {
                Group {
                    if let isReachable = cloudBridgeIsReachable {
                        Circle()
                            .fill(isReachable ? DS.Colors.success : DS.Colors.warning)
                            .frame(width: 8, height: 8)
                        Text(isReachable ? "Bridge reachable" : "Bridge not reachable")
                            .font(.system(size: 12))
                            .foregroundColor(isReachable ? DS.Colors.success : DS.Colors.warning)
                    } else {
                        Circle()
                            .fill(DS.Colors.textTertiary)
                            .frame(width: 8, height: 8)
                        Text("Not checked yet")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                if let checkedAt = cloudBridgeReachabilityLastCheckedAt {
                    Text("(\(checkedAt.formatted(date: .omitted, time: .shortened)))")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()
                paceSettingsButton("Check", systemName: "arrow.clockwise") {
                    checkCloudBridgeReachability()
                }
            }

            Divider().background(DS.Colors.borderSubtle)

            // Revoke consent
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Revoke consent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Clears all bridge state, resets mode to Off.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                paceSettingsButton("Revoke", systemName: "xmark.circle") {
                    PaceCloudBridgeConsent.revokeConsentAndResetAllBridgeState()
                    companionManager.setCloudBridgeMode(.off)
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            checkCloudBridgeReachability()
        }
    }

    private func checkCloudBridgeReachability() {
        let bridgeConfiguration = PaceCloudBridgeConsent.loadConfiguration()
        let healthURL = bridgeConfiguration.baseURL.appendingPathComponent("health")

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                cloudBridgeIsReachable = (200...299).contains(httpStatusCode)
            } catch {
                cloudBridgeIsReachable = false
            }
            cloudBridgeReachabilityLastCheckedAt = Date()
        }
    }
}
