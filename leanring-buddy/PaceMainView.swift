import AppKit
import Combine
import Combine
import SaaSMakerUI
import SwiftUI

@MainActor
struct PaceMainView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var router: PaceCommandCenterRouter

    @State private var detailDestination: PaceCommandCenterDestination?

    init(companionManager: CompanionManager, router: PaceCommandCenterRouter) {
        self.companionManager = companionManager
        self.router = router
        _detailDestination = State(initialValue: router.selectedDestination == .general ? nil : router.selectedDestination)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let detailDestination {
                detailToolbar(for: detailDestination)
                Divider().overlay(DS.Colors.borderSubtle)
                detail(for: detailDestination)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaceEssentialsSettingsView(
                    companionManager: companionManager,
                    onSelectDestination: showDestination
                )
            }
        }
        .background(DS.Colors.surface)
        .frame(minWidth: 680, minHeight: 540)
        .font(DS.Typography.body)
        .smTheme(DS.palette)
        .preferredColorScheme(.dark)
        .onReceive(router.$selectedDestination.dropFirst()) { destination in
            detailDestination = destination == .general ? nil : destination
        }
    }

    private func showDestination(_ destination: PaceCommandCenterDestination) {
        detailDestination = destination
        // General is the compatibility Settings entry. Its workflow detail is local navigation.
        if destination != .general {
            router.select(destination)
        }
    }

    private func showEssentials() {
        detailDestination = nil
        router.select(.general)
    }

    private func detailToolbar(for destination: PaceCommandCenterDestination) -> some View {
        HStack(spacing: 16) {
            Button(action: showEssentials) {
                Label("Settings", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .paceControlHoverHighlight(cornerRadius: 6)
            .pointerCursor()
            .accessibilityLabel("Back to Settings")

            Text(detailTitle(for: destination))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 46)
        .background(DS.Colors.surface)
    }

    @ViewBuilder
    private func detail(for destination: PaceCommandCenterDestination) -> some View {
        switch destination {
        case .conversations:
            PaceConversationsView(companionManager: companionManager)
        case .skills:
            PaceSkillsView()
        case .usage:
            PaceUsageAnalyticsView()
        case .privacy:
            PacePrivacyDashboardView(companionManager: companionManager)
        case .permissions:
            PacePermissionsView(companionManager: companionManager)
        case .about:
            PaceAboutView()
        case .general:
            settingsDetail(for: destination) {
                PaceGeneralSettingsTab(companionManager: companionManager, showsCoreBehavior: false)
            }
        case .planner:
            settingsDetail(for: destination) { PacePlannerSettingsTab(companionManager: companionManager) }
        case .models:
            settingsDetail(for: destination) { PaceBundledModelsSettingsTab(companionManager: companionManager) }
        case .research:
            settingsDetail(for: destination) { PaceResearchSettingsTab(companionManager: companionManager) }
        case .proactive:
            settingsDetail(for: destination) {
                PaceProactiveSettingsTab(companionManager: companionManager, showsWatchModeControl: false)
            }
        case .companion:
            settingsDetail(for: destination) {
                PaceCompanionSettingsTab(controlCenter: companionManager.companionControlCenter)
            }
        case .mcp:
            settingsDetail(for: destination) { PaceMCPSettingsTab(companionManager: companionManager) }
        case .voice:
            settingsDetail(for: destination) { PaceVoiceSettingsTab(companionManager: companionManager) }
        case .cloudBridge:
            settingsDetail(for: destination) { PaceCloudBridgeSettingsTab(companionManager: companionManager) }
        case .flows:
            settingsDetail(for: destination) { PaceFlowsSettingsTab(companionManager: companionManager) }
        case .tasks:
            settingsDetail(for: destination) { PaceTasksSettingsTab(companionManager: companionManager) }
        case .memory:
            settingsDetail(for: destination) { PaceMemorySettingsTab(companionManager: companionManager) }
        case .activity:
            settingsDetail(for: destination) { PaceActivitySettingsTab(companionManager: companionManager) }
        case .debug:
            settingsDetail(for: destination) { PaceDebugSettingsTab(companionManager: companionManager) }
        case .doctor:
            settingsDetail(for: destination) { PaceDoctorSettingsTab(companionManager: companionManager) }
        }
    }

    private func settingsDetail<Content: View>(
        for destination: PaceCommandCenterDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(destination.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(30)
            .frame(maxWidth: 804, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(DS.Colors.surface)
    }

    private func detailTitle(for destination: PaceCommandCenterDestination) -> String {
        switch destination {
        case .general: return "Workflow settings"
        case .planner: return "Reasoner settings"
        case .conversations: return "Conversation history"
        case .cloudBridge: return "Off-device model settings"
        default: return destination.title
        }
    }
}

struct PacePermissionsView: View {
    let companionManager: CompanionManager
    @ObservedObject private var permissionService = PacePermissionService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SMSectionHeader("", accent: "permissions", size: 28)
                Text("Live macOS capability state. Pace asks only when a requested feature needs access.")
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textSecondary)

                SMCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(PacePermissionKind.allCases, id: \.rawValue) { permissionKind in
                            permissionRow(permissionKind: permissionKind)
                            if permissionKind != PacePermissionKind.allCases.last {
                                Divider().overlay(DS.Colors.borderSubtle)
                            }
                        }
                    }
                }
                .padding(.top, 10)

                Spacer()
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.surface)
    }

    private func permissionRow(permissionKind: PacePermissionKind) -> some View {
        let isGranted = permissionService.isGranted(permissionKind)
        return HStack(spacing: 16) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(isGranted ? DS.Colors.success : DS.Colors.textTertiary)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(humanName(permissionKind).lowercased())
                    .font(DS.Typography.bodyStrong)
                Text(humanDescription(permissionKind))
                    .font(DS.Typography.callout)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                SMStatusPill("granted", tone: .success)
                    .fixedSize()
            } else {
                Button(
                    permissionKind == .calendar && companionManager.shouldRequestCalendarPermission
                        ? "grant access" : "open settings"
                ) {
                    openSettings(for: permissionKind)
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .pointerCursor()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isGranted ? "Granted" : "Not granted")
    }

    private func humanName(_ permissionKind: PacePermissionKind) -> String {
        switch permissionKind {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        }
    }

    private func humanDescription(_ permissionKind: PacePermissionKind) -> String {
        switch permissionKind {
        case .accessibility: return "Clicks, keystrokes, and the global shortcut."
        case .screenRecording: return "On-device screen understanding when requested."
        case .microphone: return "Push-to-talk voice input."
        case .camera: return "Optional posture watch."
        case .calendar: return "Calendar reads and requested event creation."
        case .reminders: return "Requested reminder creation."
        case .contacts: return "Resolve names for mail drafts."
        }
    }

    private func openSettings(for permissionKind: PacePermissionKind) {
        let settingsURLString: String
        switch permissionKind {
        case .accessibility:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .calendar:
            companionManager.requestCalendarPermission()
            return
        case .reminders:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .contacts:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }
        if let settingsURL = URL(string: settingsURLString) {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

struct PaceAboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            PaceSignalNotchView(state: .ready, isOffDeviceTurn: false)
                .frame(width: 220, height: 64)

            Text("Pace")
                .font(DS.Typography.display)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(DS.Typography.metadata)
                .foregroundColor(DS.Colors.textTertiary)
            Text("A local-first macOS assistant.")
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textSecondary)
            Text(
                "Built with open-source libraries and integrations, including MCP, Peekaboo, Playwright, MLX, WhisperKit, and Sparkle."
            )
            .font(DS.Typography.callout)
            .foregroundColor(DS.Colors.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            Button("open-source credits and licenses") {
                if let noticesURL = Bundle.main.url(forResource: "OpenSourceNotices", withExtension: "txt") {
                    NSWorkspace.shared.open(noticesURL)
                }
            }
            .buttonStyle(.bordered)
            .pointerCursor()

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.surface)
    }
}
