//
//  PaceOverlayPillViews.swift
//  leanring-buddy
//
//  Small, focused SwiftUI voice-state views retained for reuse. The
//  current always-visible voice-state animation lives in
//  PaceMenuBarOverlay.swift so it appears at the notch instead of next
//  to the cursor:
//
//  - `WhisperFlowVoicePillView` replaces the cursor while the user is
//    holding push-to-talk and speaking. Glassmorphic capsule with
//    audio-reactive bars and a subtle idle pulse.
//
//  - `BlueCursorSpinnerView` replaces the cursor while the AI is
//    processing the captured voice input. Codex-style angular spinner.
//
//  Extracted from `OverlayWindow.swift` so each visual sits in its own
//  file with its own tunables.
//

import SwiftUI

/// Compact glassmorphic capsule that replaces the cursor while the user
/// is holding push-to-talk and speaking. Modeled on Whisper Flow's
/// floating voice pill: blurred backdrop, faint gradient stroke,
/// vertical bars inside that respond to audio level with a subtle idle
/// pulse so the pill never feels frozen.
struct WhisperFlowVoicePillView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 7
    /// Bars taper from short → tall → short across the pill, so the
    /// loudest output reads as a centered swell rather than a flat block.
    private let listeningBarHeightProfile: [CGFloat] = [0.45, 0.65, 0.85, 1.0, 0.85, 0.65, 0.45]
    private let pillSize = CGSize(width: 78, height: 26)

    @State private var isFullyPresented: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "#9EC7FF"),
                                    DS.Colors.overlayCursorBlue
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: 2.5,
                            height: barHeight(
                                forBarAtIndex: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .frame(width: pillSize.width, height: pillSize.height)
            .background(
                ZStack {
                    // Dark glassmorphic fill — keeps the pill legible on
                    // any wallpaper without the heavy ultraThinMaterial
                    // blurring out the bars.
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.55))
                    // Inner glow to match the cursor's overlayCursorBlue accent
                    Capsule(style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    DS.Colors.overlayCursorBlue.opacity(0.25),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: pillSize.width * 0.55
                            )
                        )
                    // Hairline gradient stroke for the Whisper Flow edge feel
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.white.opacity(0.05),
                                    DS.Colors.overlayCursorBlue.opacity(0.45)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                }
            )
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.45), radius: 10, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
            .scaleEffect(isFullyPresented ? 1.0 : 0.85)
            .opacity(isFullyPresented ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    isFullyPresented = true
                }
            }
            .onDisappear {
                isFullyPresented = false
            }
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(forBarAtIndex barIndex: Int, timelineDate: Date) -> CGFloat {
        // Idle pulse so the bars breathe gently when no speech is detected.
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.2) + CGFloat(barIndex) * 0.42
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 16 * listeningBarHeightProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 2.0
        return 4 + reactiveHeight + idlePulse
    }
}

/// A small blue spinning indicator that replaces the cursor while the
/// AI is processing voice input.
struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}
