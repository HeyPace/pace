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
                        .animation(.easeOut(duration: DS.Motion.micro), value: displayedActivityLabel)
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
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(displayMode == .hover ? 0.18 : displayMode == .active ? 0.07 : 0), lineWidth: 0.5)
                .animation(.easeOut(duration: DS.Motion.micro), value: displayMode)
                .allowsHitTesting(false)
        }
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
    var persistentStatus: String? = nil
    var companionStatusColor: Color? = nil
    var onBrandTap: (() -> Void)? = nil
    var onChatTap: (() -> Void)? = nil
    @State private var hoveredWingLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let wingWidth = max(0, (geometry.size.width - physicalHousingWidth) / 2)
            HStack(spacing: 0) {
                wingButton(
                    label: "Open Pace",
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
                        .frame(width: wingWidth, height: physicalHousingHeight)
                }
                Color.clear.frame(width: physicalHousingWidth)
                wingButton(
                    label: isExpanded ? "Close conversation" : "Open conversation",
                    shortcutHint: isExpanded ? "Close conversation · Esc" : "Open chat · \(PaceNotchChatShortcut.currentShortcutOption.notchDisplayLabel)",
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
                    .foregroundStyle(isOffDeviceTurn ? DS.Colors.offDeviceSignal : Color.white.opacity(0.94))
                    .fixedSize()
                    .frame(width: wingWidth, height: physicalHousingHeight)
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
                            if isScreenActive {
                                Circle().fill(.cyan).frame(width: 4, height: 4)
                                    .accessibilityLabel("Screen active")
                            }
                        }
                        .fixedSize()
                        .padding(.trailing, 12)
                        .padding(.bottom, 2)
                    }
                }
            }
        }
        .frame(height: physicalHousingHeight)
    }

    @ViewBuilder
    private func wingButton<Content: View>(
        label: String,
        shortcutHint: String,
        action: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let cap = content()
            .background(hoveredWingLabel == label ? Color.white.opacity(0.08) : Color.clear)
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
                .help(shortcutHint)
        } else {
            cap
        }
    }

}

private struct PaceNotchButtonStyle: ButtonStyle {
    let isHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.96 : isHovered ? 1.04 : 1)
            .opacity(configuration.isPressed && isEnabled ? 0.72 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: DS.Motion.micro), value: configuration.isPressed)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: DS.Motion.micro), value: isHovered)
    }
}

private extension BuddyPushToTalkShortcut.ShortcutOption {
    var notchDisplayLabel: String {
        switch self {
        case .shiftFunction: return "⇧fn"
        case .controlOption: return "⌃⌥"
        case .shiftControl: return "⌃⇧"
        case .controlOptionSpace: return "⌃⌥Space"
        case .shiftControlSpace: return "⌃⇧Space"
        }
    }
}

private extension PaceNotchChatShortcut.ShortcutOption {
    var notchDisplayLabel: String {
        switch self {
        case .commandShiftP: return "⌘⇧P"
        case .commandShiftK: return "⌘⇧K"
        case .commandShiftSpace: return "⌘⇧Space"
        case .controlShiftP: return "⌃⇧P"
        case .controlShiftSpace: return "⌃⇧Space"
        }
    }
}

struct PaceSeamNotchShape: Shape {
    let topShoulderRadius: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let resolvedTopShoulderRadius = min(topShoulderRadius, rect.width / 4, rect.height / 2)
        let resolvedBottomCornerRadius = min(
            bottomCornerRadius,
            rect.width / 4,
            rect.height / 2
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.minY + resolvedTopShoulderRadius
            ),
            control1: CGPoint(
                x: rect.minX + (resolvedTopShoulderRadius * 0.7),
                y: rect.minY
            ),
            control2: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.minY + (resolvedTopShoulderRadius * 0.35)
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius
            )
        )
        path.addCurve(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius + resolvedBottomCornerRadius,
                y: rect.maxY
            ),
            control1: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius * 0.447_715
            ),
            control2: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius + resolvedBottomCornerRadius * 0.447_715,
                y: rect.maxY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius - resolvedBottomCornerRadius,
                y: rect.maxY
            )
        )
        path.addCurve(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius
            ),
            control1: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius - resolvedBottomCornerRadius * 0.447_715,
                y: rect.maxY
            ),
            control2: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius * 0.447_715
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.minY + resolvedTopShoulderRadius
            )
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.minY + (resolvedTopShoulderRadius * 0.35)
            ),
            control2: CGPoint(
                x: rect.maxX - (resolvedTopShoulderRadius * 0.7),
                y: rect.minY
            )
        )
        path.closeSubpath()
        return path
    }
}
