import SaaSMakerUI
import SwiftUI

struct PaceSeamNotchSurface: View {
    let displayMode: PaceLivingNotchDisplayMode
    let physicalHousingWidth: CGFloat
    let physicalHousingHeight: CGFloat
    let signalState: PaceSignalState
    let activityLabel: String
    let isOffDeviceTurn: Bool
    let plannerLabel: String
    var audioPowerLevel: CGFloat = 0
    var colorRoleOverride: PaceSignalColorRole? = nil
    var isCameraActive = false
    var isScreenActive = false
    var hasUnreadScreenSuggestion = false
    var persistentStatus: String? = nil
    var companionStatusColor: Color? = nil
    var onBrandTap: (() -> Void)? = nil
    var onChatTap: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var displayedActivityLabel: String {
        if isOffDeviceTurn { return activityLabel }
        if signalState == .ready || signalState == .completed { return persistentStatus ?? activityLabel }
        return activityLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: physicalHousingHeight)
            if displayMode == .active {
                HStack(spacing: 12) {
                    Text(displayedActivityLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: DS.Motion.micro), value: displayedActivityLabel)
                    if isOffDeviceTurn {
                        plannerBadge
                    } else if signalState == .understanding || signalState == .acting {
                        Group {
                            if reduceMotion {
                                Circle().trim(from: 0.05, to: 0.78)
                                    .stroke(DS.Colors.localSignal, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                            } else {
                                ProgressView().controlSize(.mini).tint(DS.Colors.localSignal)
                            }
                        }
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                    } else {
                        PaceSignalView(
                            state: signalState,
                            isOffDeviceTurn: isOffDeviceTurn,
                            audioPowerLevel: audioPowerLevel,
                            lineCount: 1,
                            colorRoleOverride: colorRoleOverride
                        )
                        .frame(width: 30, height: 15)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 3)
                .frame(height: displayMode.additionalHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .environment(\.smPalette, DS.palette)
        .tint(DS.palette.brand)
        .preferredColorScheme(.dark)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
    }

    private var header: some View {
        PaceSeamNotchHeader(
            physicalHousingWidth: physicalHousingWidth,
            physicalHousingHeight: physicalHousingHeight,
            signalState: signalState,
            isOffDeviceTurn: isOffDeviceTurn,
            isCameraActive: isCameraActive,
            isScreenActive: isScreenActive,
            hasUnreadScreenSuggestion: hasUnreadScreenSuggestion,
            persistentStatus: persistentStatus,
            companionStatusColor: companionStatusColor,
            onBrandTap: onBrandTap,
            onChatTap: onChatTap)
    }

    private var plannerBadge: some View {
        HStack(spacing: 4) {
            Text(plannerLabel)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 7, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(DS.Colors.offDeviceSignal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Off-device planner, " + plannerLabel)
        .frame(maxWidth: 96)
        .fixedSize(horizontal: true, vertical: false)
    }

}

struct PaceSeamNotchHeader: View {
    let physicalHousingWidth: CGFloat
    let physicalHousingHeight: CGFloat
    let signalState: PaceSignalState
    let isOffDeviceTurn: Bool
    var isExpanded = false
    var isCameraActive = false
    var isScreenActive = false
    var hasUnreadScreenSuggestion = false
    var persistentStatus: String? = nil
    var companionStatusColor: Color? = nil
    var onBrandTap: (() -> Void)? = nil
    var onChatTap: (() -> Void)? = nil
    @ObservedObject private var screenReadActivity = PaceScreenReadActivity.shared
    @State private var hoveredWingLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let wingWidth = max(0, (geometry.size.width - physicalHousingWidth) / 2)
            HStack(spacing: 0) {
                wingButton(
                    label: signalState == .listening ? "Finish recording" : "Start voice input",
                    shortcutHint: "Hold \(BuddyPushToTalkShortcut.currentShortcutOption.notchDisplayLabel) to speak",
                    action: onBrandTap
                ) {
                    Image(systemName: signalState == .listening ? "mic.fill" : "mic")
                        .font(.system(size: 16, weight: .regular))
                        .accessibilityHidden(true)
                        .foregroundStyle(signalState == .listening ? DS.Colors.localSignal : Color.white.opacity(0.94))
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                        .animation(.easeOut(duration: DS.Motion.micro), value: signalState == .listening)
                        .fixedSize()
                        .frame(width: min(40, wingWidth), height: physicalHousingHeight)
                }
                .frame(width: wingWidth, height: physicalHousingHeight)
                Color.clear.frame(width: physicalHousingWidth)
                wingButton(
                    label: isExpanded ? "Close conversation" : "Open conversation",
                    shortcutHint: isExpanded
                        ? "Close conversation · Esc"
                        : "Open chat · \(PaceNotchChatShortcut.currentShortcutOption.notchDisplayLabel)",
                    statusDescription: conversationStatusDescription,
                    action: onChatTap
                ) {
                    Group {
                        if isExpanded {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .medium))
                                .accessibilityHidden(true)
                        } else {
                            PaceBrandMark().frame(width: 20, height: 20)
                        }
                    }
                    .overlay {
                        if screenReadActivity.isReading {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.cyan.opacity(0.12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.cyan.opacity(0.65), lineWidth: 0.75)
                                }
                                .frame(width: 28, height: 28)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "eye.fill")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(Color.cyan)
                                        .padding(2)
                                        .background(Color.black, in: Capsule())
                                        .offset(x: 4, y: 3)
                                }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: DS.Motion.micro), value: screenReadActivity.isReading
                    )
                    .foregroundStyle(isOffDeviceTurn ? DS.Colors.offDeviceSignal : Color.white.opacity(0.94))
                    .fixedSize()
                    .frame(width: min(40, wingWidth), height: physicalHousingHeight)
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 4) {
                            if let companionStatusColor {
                                Circle().fill(companionStatusColor).frame(width: 4, height: 4)
                                    .accessibilityLabel(persistentStatus ?? "Companion status")
                            }
                            if isCameraActive {
                                Circle().fill(.green).frame(width: 4, height: 4)
                                    .accessibilityLabel("Camera active")
                            }
                            if isScreenActive || hasUnreadScreenSuggestion {
                                Circle().fill(hasUnreadScreenSuggestion ? .yellow : .cyan).frame(width: 4, height: 4)
                                    .accessibilityLabel(
                                        hasUnreadScreenSuggestion ? "Unread screen suggestion" : "Screen active")
                            }
                        }
                        .fixedSize()
                        .padding(.trailing, 3)
                        .padding(.bottom, 2)
                    }
                }
                .frame(width: wingWidth, height: physicalHousingHeight)
            }
        }
        .frame(height: physicalHousingHeight)
    }

    @ViewBuilder
    private func wingButton<Content: View>(
        label: String,
        shortcutHint: String,
        statusDescription: String = "",
        action: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let cap = content()
            .background(
                hoveredWingLabel == label ? Color.white.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        if let action {
            Button(action: action) { cap.contentShape(Rectangle()) }
                .buttonStyle(PaceNotchButtonStyle(isHovered: hoveredWingLabel == label))
                .onHover { isHovered in
                    if isHovered {
                        hoveredWingLabel = label
                    } else if hoveredWingLabel == label {
                        hoveredWingLabel = nil
                    }
                }
                .pointerCursor()
                .accessibilityLabel(label)
                .accessibilityValue(statusDescription)
                .help(statusDescription.isEmpty ? shortcutHint : statusDescription + " · " + shortcutHint)
        } else {
            cap
        }
    }

    private var conversationStatusDescription: String {
        var descriptions: [String] = []
        if isOffDeviceTurn { descriptions.append("Off-device request active") }
        if isCameraActive { descriptions.append("Camera active") }
        if isScreenActive { descriptions.append("Screen active") }
        if let persistentStatus, companionStatusColor != nil { descriptions.append(persistentStatus) }
        if screenReadActivity.isReading { descriptions.append("Reading your screen") }
        if hasUnreadScreenSuggestion { descriptions.append("Unread screen suggestion") }
        return descriptions.joined(separator: ". ")
    }

}

private struct PaceNotchButtonStyle: ButtonStyle {
    let isHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed && isEnabled ? 0.72 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: DS.Motion.micro), value: configuration.isPressed)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: DS.Motion.micro), value: isHovered)
    }
}

extension PaceNotchChatShortcut.ShortcutOption {
    fileprivate var notchDisplayLabel: String {
        switch self {
        case .commandShiftP: return "⌘⇧P"
        case .commandShiftK: return "⌘⇧K"
        case .commandShiftSpace: return "⌘⇧Space"
        case .controlShiftP: return "⌃⇧P"
        case .controlShiftSpace: return "⌃⇧Space"
        }
    }
}
