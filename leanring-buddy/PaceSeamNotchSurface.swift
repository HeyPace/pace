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

    var displayedActivityLabel: String {
        if isOffDeviceTurn { return activityLabel }
        if signalState == .ready || signalState == .completed { return persistentStatus ?? activityLabel }
        return activityLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            if displayMode == .hardwareIdle {
                Color.clear.frame(height: physicalHousingHeight)
            } else {
                header.frame(height: physicalHousingHeight)
                if displayMode == .hover {
                    HStack {
                        Text("Open Pace")
                            .foregroundStyle(Color.white.opacity(0.78))
                        Spacer()
                        Text("Click to chat")
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 18)
                    .frame(height: displayMode.additionalHeight)
                } else {
                    HStack(spacing: 12) {
                        Text(displayedActivityLabel)
                            .font(.system(size: 12, weight: .medium))
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
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
                    .frame(height: displayMode.additionalHeight)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(displayMode == .hardwareIdle ? Color.clear : Color.black)
        .clipShape(PaceSeamNotchShape(topShoulderRadius: 8, bottomCornerRadius: 18))
    }

    private var header: some View {
        GeometryReader { geometry in
            let wingWidth = max(0, (geometry.size.width - physicalHousingWidth) / 2)
            HStack(spacing: 0) {
                PaceBrandMark()
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .frame(width: wingWidth, height: physicalHousingHeight)
                Color.clear.frame(width: physicalHousingWidth)
                ZStack {
                    Image(systemName: statusSymbolName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isOffDeviceTurn ? DS.Colors.offDeviceSignal : Color.white.opacity(0.76))
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 13)
                    .padding(.bottom, 3)
                }
                .frame(width: wingWidth, height: physicalHousingHeight)
            }
        }
    }

    private var plannerBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(DS.Colors.offDeviceSignal).frame(width: 3, height: 3)
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

    private var statusSymbolName: String {
        if isOffDeviceTurn { return "arrow.up.right.circle" }
        switch signalState {
        case .ready, .completed: return "bubble.left"
        case .listening: return "mic"
        case .understanding, .acting: return "waveform"
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
        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius + resolvedBottomCornerRadius,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.maxY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius - resolvedBottomCornerRadius,
                y: rect.maxY
            )
        )
        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius
            ),
            control: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.maxY
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
