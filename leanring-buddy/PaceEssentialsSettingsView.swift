import SwiftUI

@MainActor
struct PaceEssentialsSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    let onSelectDestination: (PaceCommandCenterDestination) -> Void

    @State private var showsPrivacyControls = false
    @State private var showsAdvancedControls = false

    private static let privacyDestinations: [PaceCommandCenterDestination] = [
        .privacy, .permissions, .memory, .activity, .usage, .conversations,
    ]

    private static let advancedDestinations = PaceCommandCenterDestination.allCases.filter {
        !privacyDestinations.contains($0) && ![.planner, .voice, .about, .doctor].contains($0)
    }

    private enum Appearance {
        static let surface = Color(hex: "#202124")
        static let raised = Color(hex: "#28292D")
        static let border = Color(hex: "#37383C")
        static let primary = Color(hex: "#F1F1F2")
        static let secondary = Color(hex: "#AAABB1")
        static let tertiary = Color(hex: "#81838C")
        static let link = Color(hex: "#98BAFF")
        static let accent = Color(hex: "#568EF3")
        static let amber = Color(hex: "#E9BC72")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                plannerConnection
                essentialControls
                shortcutStrip
                    .padding(.top, 15)

                VStack(spacing: 0) {
                    disclosure(
                        title: "Privacy & permissions",
                        summary: "Access, memory, processing history",
                        isExpanded: $showsPrivacyControls,
                        destinations: Self.privacyDestinations
                    )
                    disclosure(
                        title: "Advanced",
                        summary: "Tools, automations, models & troubleshooting",
                        isExpanded: $showsAdvancedControls,
                        destinations: Self.advancedDestinations
                    )
                }
                .overlay(alignment: .top) { separator }
                .padding(.top, 15)

                footer
                    .padding(.top, 15)
            }
            .frame(maxWidth: 744)
            .padding(.horizontal, 38)
            .padding(.vertical, 23)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Appearance.surface)
        .foregroundStyle(Appearance.primary)
        .font(.system(size: 12))
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 21, weight: .semibold))
            Spacer()
            Text("pace")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.6)
                .accessibilityHidden(true)
        }
    }

    private var plannerConnection: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Appearance.raised, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Appearance.secondary.opacity(0.4), lineWidth: 0.7)
                }
                .accessibilityHidden(true)

            Text(selectedPlannerTitle)
                .font(.system(size: 13, weight: .semibold))
            Text("Selected")
                .font(.system(size: 12))
                .foregroundStyle(Appearance.secondary)
            Spacer(minLength: 12)
            Text(selectedPlannerUsesOffDeviceTier ? "Off-device reasoning" : "On-device reasoning")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(selectedPlannerUsesOffDeviceTier ? Appearance.amber : Appearance.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    selectedPlannerUsesOffDeviceTier
                        ? Appearance.amber.opacity(0.12) : Appearance.raised,
                    in: RoundedRectangle(cornerRadius: 4)
                )
            destinationLink("Manage…", destination: .planner)
        }
        .padding(.vertical, 15)
        .padding(.top, 7)
        .overlay(alignment: .bottom) { separator }
    }

    private var essentialControls: some View {
        VStack(spacing: 0) {
            settingsRow(
                title: "Voice",
                subtitle: voiceSubtitle
            ) {
                destinationLink("Change…", destination: .voice)
            }
            toggleRow(
                title: "Read my screen",
                subtitle: "Use screen context when your request needs it.",
                isOn: Binding(
                    get: { companionManager.useLocalVLMForScreenContext },
                    set: { companionManager.setUseLocalVLMForScreenContext($0) }
                )
            )
            toggleRow(
                title: "Cursor annotations",
                subtitle: "Show words and pointer labels near your cursor.",
                isOn: Binding(
                    get: { companionManager.areCursorAnnotationsEnabled },
                    set: { companionManager.setCursorAnnotationsEnabled($0) }
                )
            )
            toggleRow(
                title: "Watch mode",
                qualifier: "session only",
                subtitle: watchModeSubtitle,
                isOn: Binding(
                    get: { companionManager.isWatchModeEnabled },
                    set: { companionManager.setWatchModeEnabled($0) }
                ),
                isEnabled: companionManager.useLocalVLMForScreenContext || companionManager.isWatchModeEnabled
            )
            toggleRow(
                title: "Approve risky actions",
                subtitle: "Ask before non-undoable changes and connected-tool actions.",
                isOn: Binding(
                    get: { companionManager.requiresActionApproval },
                    set: { companionManager.setRequiresActionApproval($0) }
                ),
                showsSeparator: false
            )
        }
        .padding(.top, 7)
    }

    private var shortcutStrip: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Text("Hold to talk")
                    .font(.system(size: 11))
                shortcutKeycaps(pushToTalkKeyLabels)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 5)
            Text("One conversation for voice and text")
                .font(.system(size: 10))
                .foregroundStyle(Appearance.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 5)

            Button {
                companionManager.handleNotchChatShortcutPressed()
            } label: {
                HStack(spacing: 9) {
                    Text("Open chat")
                        .font(.system(size: 11))
                    shortcutKeycaps(chatKeyLabels)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .paceControlHoverHighlight(cornerRadius: 5)
            .pointerCursor()
            .accessibilityLabel("Open chat")
            .accessibilityHint(PaceNotchChatShortcut.currentShortcutAccessibilityLabel)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Appearance.raised, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Appearance.border, lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack {
            Text("Audio and speech stay on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Appearance.tertiary)
            Spacer()
            Menu {
                Button("About Pace") { onSelectDestination(.about) }
                Button("Help & diagnostics") { onSelectDestination(.doctor) }
                Button("Getting started") {
                    PaceOnboardingWindowManager.shared.show(companionManager: companionManager, isReplay: true)
                }
            } label: {
                Text("About Pace & help")
                    .font(.system(size: 11))
                    .foregroundStyle(Appearance.link)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
        }
    }

    private var voiceSubtitle: String {
        let voiceSummary = companionManager.activeTTSVoiceSummary
        let qualitySuffix = "(\(voiceSummary.qualityName))"
        let voiceLabel = voiceSummary.voiceName.localizedCaseInsensitiveContains(qualitySuffix)
            ? voiceSummary.voiceName : "\(voiceSummary.voiceName) \(qualitySuffix)"
        return "\(voiceLabel) · speech stays on this Mac."
    }

    private var selectedPlannerTitle: String {
        switch companionManager.activePlannerTier {
        case .local: return "LM Studio"
        case .appleFoundationModels: return "Apple Intelligence"
        case .cliBridge: return "CLI bridge"
        case .cliDirect: return companionManager.activePlannerTierCLIDirectUpstream.displayLabel
        case .directAPI: return "\(companionManager.directAPIProvider.displayLabel) API"
        }
    }

    private var selectedPlannerUsesOffDeviceTier: Bool {
        switch companionManager.activePlannerTier {
        case .local, .appleFoundationModels: return false
        case .cliBridge, .cliDirect, .directAPI: return true
        }
    }

    private var watchModeSubtitle: String {
        guard companionManager.useLocalVLMForScreenContext else {
            return "Turn on Read my screen first. Off at launch and lock."
        }
        if selectedPlannerUsesOffDeviceTier {
            return "Off at launch and lock. Sends redacted screen text to \(selectedPlannerTitle)."
        }
        return "Off at launch and lock. Observations use your local planner."
    }

    private var pushToTalkKeyLabels: [String] {
        switch BuddyPushToTalkShortcut.currentShortcutOption {
        case .shiftFunction: return ["⇧", "fn"]
        case .controlOption: return ["⌃", "⌥"]
        case .shiftControl: return ["⇧", "⌃"]
        case .controlOptionSpace: return ["⌃", "⌥", "Space"]
        case .shiftControlSpace: return ["⇧", "⌃", "Space"]
        }
    }

    private var chatKeyLabels: [String] {
        switch PaceNotchChatShortcut.currentShortcutOption {
        case .commandShiftP: return ["⇧", "⌘", "P"]
        case .commandShiftK: return ["⇧", "⌘", "K"]
        case .commandShiftSpace: return ["⇧", "⌘", "Space"]
        case .controlShiftP: return ["⇧", "⌃", "P"]
        case .controlShiftSpace: return ["⇧", "⌃", "Space"]
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Appearance.border)
            .frame(height: 0.7)
    }

    private func settingsRow<Trailing: View>(
        title: String,
        qualifier: String? = nil,
        subtitle: String,
        showsSeparator: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    if let qualifier {
                        Text("· \(qualifier)")
                            .font(.system(size: 10))
                            .foregroundStyle(Appearance.tertiary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .frame(minHeight: 49)
        .overlay(alignment: .bottom) {
            if showsSeparator { separator }
        }
    }

    private func toggleRow(
        title: String,
        qualifier: String? = nil,
        subtitle: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        showsSeparator: Bool = true
    ) -> some View {
        settingsRow(
            title: title,
            qualifier: qualifier,
            subtitle: subtitle,
            showsSeparator: showsSeparator
        ) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Appearance.accent)
                .disabled(!isEnabled)
                .pointerCursor()
                .accessibilityLabel(title)
                .accessibilityHint(subtitle)
        }
    }

    private func destinationLink(
        _ title: String,
        destination: PaceCommandCenterDestination
    ) -> some View {
        Button { onSelectDestination(destination) } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Appearance.link)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: 4)
        .pointerCursor()
    }

    private func shortcutKeycaps(_ keyLabels: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keyLabels.enumerated()), id: \.offset) { _, keyLabel in
                Text(keyLabel)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 23, minHeight: 22)
                    .padding(.horizontal, keyLabel.count > 1 ? 5 : 0)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                    }
            }
        }
    }

    private func disclosure(
        title: String,
        summary: String,
        isExpanded: Binding<Bool>,
        destinations: [PaceCommandCenterDestination]
    ) -> some View {
        VStack(spacing: 0) {
            Button { isExpanded.wrappedValue.toggle() } label: {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Appearance.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Appearance.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .frame(minHeight: 43)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .paceControlHoverHighlight(cornerRadius: 5)
            .pointerCursor()
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityHint(summary)

            if isExpanded.wrappedValue {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 205), spacing: 18)],
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(destinations) { destination in
                        Button { onSelectDestination(destination) } label: {
                            HStack(spacing: 8) {
                                Text(destinationTitle(destination))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Appearance.secondary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Appearance.tertiary)
                            }
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .paceControlHoverHighlight(cornerRadius: 5)
                        .pointerCursor()
                        .accessibilityHint(destination.subtitle)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottom) { separator }
    }

    private func destinationTitle(_ destination: PaceCommandCenterDestination) -> String {
        switch destination {
        case .general: return "Workflow settings"
        case .conversations: return "Conversation history"
        case .planner: return "Reasoner settings"
        case .cloudBridge: return "Off-device model settings"
        default: return destination.title
        }
    }
}
