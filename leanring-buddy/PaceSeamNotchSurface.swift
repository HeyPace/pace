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
                    if isOffDeviceTurn {
                        plannerBadge
                    } else if signalState == .understanding || signalState == .acting {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                            .overlay {
                                Circle().trim(from: 0.05, to: 0.78)
                                    .stroke(
                                        DS.Colors.localSignal,
                                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
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
        .background(Color.black)
        .overlay {
            PaceSeamNotchShape(topShoulderRadius: 10, bottomCornerRadius: 22)
                .stroke(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
        .clipShape(PaceSeamNotchShape(topShoulderRadius: 10, bottomCornerRadius: 22))
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

    var body: some View {
        GeometryReader { geometry in
            let wingWidth = max(0, (geometry.size.width - physicalHousingWidth) / 2)
            HStack(spacing: 0) {
                wingButton(label: "Open Pace", action: onBrandTap) {
                    HStack(spacing: 7) {
                        Image(systemName: "mic")
                            .font(.system(size: 14, weight: .regular))
                        Text("Pace").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.white.opacity(0.94))
                    .fixedSize()
                    .frame(width: wingWidth, height: physicalHousingHeight)
                }
                Color.clear.frame(width: physicalHousingWidth)
                wingButton(label: "Open conversation", action: onChatTap) {
                    HStack(spacing: 7) {
                        Text(isExpanded ? "Close" : "Chat")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: isExpanded ? "xmark" : statusSymbolName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .accessibilityHidden(true)
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
                        .padding(.trailing, 20)
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
        action: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let action {
            Button(action: action) { content().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(hoveredWingLabel == label ? 0.07 : 0))
                }
                .onHover { isHovered in
                    if isHovered {
                        hoveredWingLabel = label
                    } else if hoveredWingLabel == label {
                        hoveredWingLabel = nil
                    }
                }
                .pointerCursor()
                .accessibilityLabel(label)
        } else {
            content()
        }
    }

    private var statusSymbolName: String {
        switch signalState {
        case .ready, .completed: return "bubble.left"
        case .listening: return "mic"
        case .understanding: return "waveform.path"
        case .acting: return "sparkle"
        case .speaking: return "speaker.wave.2"
        case .awaitingApproval: return "hand.raised"
        case .blocked: return "exclamationmark.circle"
        case .failed: return "xmark.circle"
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
