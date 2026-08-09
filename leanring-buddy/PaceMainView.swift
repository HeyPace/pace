//
//  PaceMainView.swift
//  leanring-buddy
//
//  The grouped Command Center shared by Open Pace and Settings entry points.
//

import AppKit
import SwiftUI

struct PaceMainView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var router: PaceCommandCenterRouter

    @State private var destinationSearchText = ""
    @State private var showsAdvancedControls = false
    @State private var showsDestinationHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 280)
        } detail: {
            detail
                .id(router.selectedDestination)
                .transition(.opacity)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: DS.Motion.micro),
                    value: router.selectedDestination
                )
        }
        .background(DS.Colors.surface)
        .frame(minWidth: 820, minHeight: 540)
        .preferredColorScheme(.dark)
        .onChange(of: router.selectedDestination) { _, selectedDestination in
            guard !normalizedSearchText.isEmpty,
                  !searchResults.contains(selectedDestination) else { return }
            destinationSearchText = ""
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsDestinationHelp.toggle()
                } label: {
                    Label("About this section", systemImage: "questionmark.circle")
                }
                .help("Explain this section")
                .popover(isPresented: $showsDestinationHelp, arrowEdge: .bottom) {
                    destinationHelp
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(DS.Colors.localSignal)
                        .frame(width: 7, height: 7)
                        .shadow(color: DS.Colors.localSignal.opacity(0.45), radius: 5, x: 0, y: 2)
                    Text("Pace")
                        .font(DS.Typography.sectionTitle)
                        .foregroundStyle(DS.Colors.textPrimary)
                }
                Text("Command Center")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.top, 18)
            .padding(.bottom, 14)

            List(selection: selectedDestinationBinding) {
                if normalizedSearchText.isEmpty {
                    ForEach(PaceCommandCenterGroup.allCases) { group in
                        let visibleDestinations = primaryDestinations(in: group)
                        if !visibleDestinations.isEmpty {
                            Section(group.rawValue) {
                                ForEach(visibleDestinations) { destination in
                                    destinationRow(destination)
                                }
                            }
                        }
                    }

                    Section {
                        DisclosureGroup(isExpanded: $showsAdvancedControls) {
                            ForEach(advancedDestinations) { destination in
                                destinationRow(destination)
                            }
                        } label: {
                            Label("Advanced controls", systemImage: "slider.horizontal.3")
                                .font(DS.Typography.captionStrong)
                        }
                    } footer: {
                        Text("Extra integrations and troubleshooting controls.")
                    }
                } else if searchResults.isEmpty {
                    Text("No Pace setting matches “\(destinationSearchText)”.")
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    Section("Search results") {
                        ForEach(searchResults) { destination in
                            destinationRow(destination)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .searchable(
                text: $destinationSearchText,
                placement: .sidebar,
                prompt: "Search Pace"
            )

            Button {
                PaceOnboardingWindowManager.shared.show(
                    companionManager: companionManager,
                    isReplay: true
                )
            } label: {
                Label("Getting Started", systemImage: "questionmark.circle")
                    .font(DS.Typography.captionStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.textSecondary)
            .pointerCursor()
            .padding(12)
        }
        .background(DS.Colors.surfaceInset.opacity(0.62))
    }

    private var selectedDestinationBinding: Binding<PaceCommandCenterDestination?> {
        Binding(
            get: { router.selectedDestination },
            set: { destination in
                if let destination {
                    router.select(destination)
                }
            }
        )
    }

    @ViewBuilder
    private func destinationRow(
        _ destination: PaceCommandCenterDestination
    ) -> some View {
        NavigationLink(value: destination) {
            Label(destination.title, systemImage: destination.symbolName)
                .font(DS.Typography.calloutStrong)
                .pointerCursor()
        }
        .tag(destination)
        .accessibilityHint(destination.subtitle)
    }

    private var normalizedSearchText: String {
        destinationSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func primaryDestinations(
        in group: PaceCommandCenterGroup
    ) -> [PaceCommandCenterDestination] {
        PaceCommandCenterDestination.primaryDestinations(in: group)
    }

    private var advancedDestinations: [PaceCommandCenterDestination] {
        PaceCommandCenterDestination.advancedDestinations
    }

    private var searchResults: [PaceCommandCenterDestination] {
        PaceCommandCenterDestination.allCases.filter { destination in
            destination.title.lowercased().contains(normalizedSearchText)
                || destination.subtitle.lowercased().contains(normalizedSearchText)
                || destination.group.rawValue.lowercased().contains(normalizedSearchText)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selectedDestination {
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
            settingsDetail { PaceGeneralSettingsTab(companionManager: companionManager) }
        case .planner:
            settingsDetail { PacePlannerSettingsTab(companionManager: companionManager) }
        case .models:
            settingsDetail { PaceBundledModelsSettingsTab(companionManager: companionManager) }
        case .research:
            settingsDetail { PaceResearchSettingsTab(companionManager: companionManager) }
        case .proactive:
            settingsDetail { PaceProactiveSettingsTab(companionManager: companionManager) }
        case .companion:
            settingsDetail {
                PaceCompanionSettingsTab(controlCenter: companionManager.companionControlCenter)
            }
        case .mcp:
            settingsDetail { PaceMCPSettingsTab(companionManager: companionManager) }
        case .voice:
            settingsDetail { PaceVoiceSettingsTab(companionManager: companionManager) }
        case .cloudBridge:
            settingsDetail { PaceCloudBridgeSettingsTab(companionManager: companionManager) }
        case .flows:
            settingsDetail { PaceFlowsSettingsTab(companionManager: companionManager) }
        case .tasks:
            settingsDetail { PaceTasksSettingsTab(companionManager: companionManager) }
        case .memory:
            settingsDetail { PaceMemorySettingsTab(companionManager: companionManager) }
        case .activity:
            settingsDetail { PaceActivitySettingsTab(companionManager: companionManager) }
        case .debug:
            settingsDetail { PaceDebugSettingsTab(companionManager: companionManager) }
        case .doctor:
            settingsDetail { PaceDoctorSettingsTab(companionManager: companionManager) }
        }
    }

    private func settingsDetail<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                commandCenterHeader
                content()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.surface)
    }

    private var commandCenterHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(router.selectedDestination.title)
                .font(DS.Typography.windowTitle)
                .tracking(-0.45)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(destinationSubtitle)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    private var destinationSubtitle: String {
        router.selectedDestination.subtitle
    }

    private var destinationHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                router.selectedDestination.title,
                systemImage: router.selectedDestination.symbolName
            )
            .font(DS.Typography.headline)
            .foregroundStyle(DS.Colors.textPrimary)

            Text(router.selectedDestination.subtitle)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if router.selectedDestination.isAdvanced {
                Text("Advanced control")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textTertiary)
                Text("Pace’s defaults are suitable for most people. Change this only when you know which runtime behavior you need.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                Text("Changes stay on this Mac unless the control explicitly shows the amber off-device boundary.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .padding(18)
        .frame(width: 310, alignment: .leading)
    }
}

struct PacePermissionsView: View {
    let companionManager: CompanionManager
    @ObservedObject private var permissionService = PacePermissionService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(DS.Typography.windowTitle)
                .tracking(-0.45)
            Text("Live macOS capability state. Pace asks only when a requested feature needs access.")
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textSecondary)

            VStack(spacing: 0) {
                ForEach(PacePermissionKind.allCases, id: \.rawValue) { permissionKind in
                    permissionRow(permissionKind: permissionKind)
                    if permissionKind != PacePermissionKind.allCases.last {
                        Divider().overlay(DS.Colors.borderSubtle)
                    }
                }
            }
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
            .padding(.top, 10)

            Spacer()
        }
        .padding(28)
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
                Text(humanName(permissionKind))
                    .font(DS.Typography.bodyStrong)
                Text(humanDescription(permissionKind))
                    .font(DS.Typography.callout)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.success)
            } else {
                Button("Open Settings") {
                    openSettings(for: permissionKind)
                }
                .buttonStyle(.bordered)
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
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
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
            Text("A local-first macOS voice agent.")
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.surface)
    }
}
