//
//  PaceSignalView.swift
//  leanring-buddy
//
//  Code-native signal geometry shared by onboarding, the notch, and panels.
//

import SwiftUI

extension CompanionVoiceState {
    var nativeRuntimePhase: PaceRuntimeVoicePhase {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .responding: return .responding
        }
    }
}

extension PaceTurnHUDStatus {
    var nativeRuntimePhase: PaceRuntimeHUDPhase {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .understanding: return .understanding
        case .acting: return .acting
        case .needsClarification: return .needsClarification
        case .done: return .done
        case .failed: return .failed
        case .unsupported: return .unsupported
        }
    }
}

@MainActor
extension CompanionManager {
    var nativePanelPresentation: PacePanelPresentationModel {
        PacePanelPresentationModel.resolve(
            voicePhase: voiceState.nativeRuntimePhase,
            hudPhase: currentTurnHUDState.status.nativeRuntimePhase,
            latestActionStatus: recentActionResults.first?.status,
            hasConversationContent: !chatSession.userFacingMessages.isEmpty,
            hasLiveTranscript: !liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasStreamedResponse: !streamingSentenceTTSPipeline.inFlightStreamedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    var nativeEffectiveSignalState: PaceSignalState {
        let currentSignalState = nativePanelPresentation.signalState
        guard allPermissionsGranted == false else {
            return currentSignalState
        }

        // Missing voice or screen permissions must not mask a typed turn that
        // is actively progressing. The idle state still calls out setup.
        return currentSignalState == .ready ? .blocked : currentSignalState
    }

    var nativeEffectiveSignalColorRoleOverride: PaceSignalColorRole? {
        guard allPermissionsGranted == false,
            nativeEffectiveSignalState == .blocked,
            isOffDeviceTurnInFlight == false
        else {
            return nil
        }
        return .local
    }
}

extension PaceSignalColorRole {
    var color: Color {
        switch self {
        case .local: return DS.Colors.localSignal
        case .offDevice: return DS.Colors.offDeviceSignal
        case .approval: return DS.Colors.warning
        case .success: return DS.Colors.success
        case .blocked: return DS.Colors.blocked
        case .failure: return DS.Colors.failure
        }
    }
}

struct PaceSignalView: View {
    let state: PaceSignalState
    let isOffDeviceTurn: Bool
    var audioPowerLevel: CGFloat = 0
    var lineCount: Int = 3
    var colorRoleOverride: PaceSignalColorRole? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: PaceSignalPresentation {
        PaceSignalPresentation.resolve(
            state: state,
            isOffDeviceTurn: isOffDeviceTurn,
            reduceMotion: reduceMotion
        )
    }

    private var signalColor: Color {
        (colorRoleOverride ?? presentation.colorRole).color
    }

    var body: some View {
        Group {
            switch presentation.motionPolicy {
            case .audioReactive where audioPowerLevel > 0.01:
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
                    signalCanvas(phase: timelineContext.date.timeIntervalSinceReferenceDate)
                }
            case .still, .crossfade, .audioReactive:
                signalCanvas(phase: 0)
                    .id(state)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: DS.Motion.stateChange),
            value: state
        )
        .accessibilityHidden(true)
    }

    private func signalCanvas(phase: TimeInterval) -> some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let resolvedLineCount = max(lineCount, 1)

            for lineIndex in 0..<resolvedLineCount {
                let normalizedLineOffset = CGFloat(lineIndex) - CGFloat(resolvedLineCount - 1) / 2
                let verticalOffset = normalizedLineOffset * min(size.height * 0.14, 10)
                let lineOpacity = 1 - abs(normalizedLineOffset) * 0.22
                var path = Path()

                for sampleIndex in 0...80 {
                    let progress = CGFloat(sampleIndex) / 80
                    let xPosition = progress * size.width
                    let envelope = sin(progress * .pi)
                    let yPosition =
                        centerY
                        + verticalOffset
                        + waveformOffset(
                            progress: progress,
                            phase: phase,
                            envelope: envelope,
                            availableHeight: size.height
                        )

                    if sampleIndex == 0 {
                        path.move(to: CGPoint(x: xPosition, y: yPosition))
                    } else {
                        path.addLine(to: CGPoint(x: xPosition, y: yPosition))
                    }
                }

                context.stroke(
                    path,
                    with: .color(signalColor.opacity(lineOpacity)),
                    style: StrokeStyle(lineWidth: lineIndex == resolvedLineCount / 2 ? 2.2 : 1.1, lineCap: .round)
                )
            }
        }
        .shadow(color: signalColor.opacity(0.34), radius: 8, x: 0, y: 3)
    }

    private func waveformOffset(
        progress: CGFloat,
        phase: TimeInterval,
        envelope: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let phaseValue = CGFloat(phase)
        let maximumAmplitude = min(availableHeight * 0.28, 24)

        switch presentation.motionPolicy {
        case .still, .crossfade:
            return staticWaveOffset(progress: progress) * maximumAmplitude * envelope
        case .audioReactive:
            let normalizedAudioPower = min(max(audioPowerLevel * 3.4, 0), 1)
            let travellingWave = sin((progress * 5.5 + phaseValue * 2.2) * .pi)
            return travellingWave * maximumAmplitude * normalizedAudioPower * envelope
        }
    }

    private func staticWaveOffset(progress: CGFloat) -> CGFloat {
        switch state {
        case .ready: return sin(progress * 2 * .pi) * 0.08
        case .listening: return sin(progress * 5 * .pi) * 0.45
        case .understanding: return sin(progress * 4 * .pi) * 0.38
        case .awaitingApproval: return sin(progress * 3 * .pi) * 0.30
        case .acting: return sin(progress * 4 * .pi) * 0.42
        case .speaking: return sin(progress * 5 * .pi) * 0.40
        case .completed: return sin(progress * 2 * .pi) * 0.12
        case .blocked: return sin(progress * 3 * .pi) * 0.16
        case .failed: return sin(progress * 2.5 * .pi) * 0.18
        }
    }
}

struct PaceSignalNotchView: View {
    let state: PaceSignalState
    let isOffDeviceTurn: Bool
    var audioPowerLevel: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: PaceSignalPresentation {
        PaceSignalPresentation.resolve(
            state: state,
            isOffDeviceTurn: isOffDeviceTurn,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(DS.Colors.surfaceInset)
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(presentation.colorRole.color.opacity(0.42), lineWidth: 1)
                }

            PaceSignalView(
                state: state,
                isOffDeviceTurn: isOffDeviceTurn,
                audioPowerLevel: audioPowerLevel,
                lineCount: 1
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .shadow(color: presentation.colorRole.color.opacity(0.20), radius: 14, x: 0, y: 5)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: DS.Motion.stateChange),
            value: state
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pace")
        .accessibilityValue(presentation.accessibilityValue)
    }
}
