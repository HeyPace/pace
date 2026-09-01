//
//  PaceTurnHUDView.swift
//  leanring-buddy
//
//  Notch-panel turn HUD card. Renders the current PaceTurnHUDState
//  (listening / understanding / acting / needs-clarification / done /
//  failed / unsupported) and the live QPlan multi-step execution checklist.
//

import SwiftUI

struct PaceTurnHUDView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turnHUDSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(turnHUDColor)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(companionManager.currentTurnHUDState.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail = companionManager.currentTurnHUDState.detail,
                   !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Live QPlan Multi-Step Checklist (Phase 2A.2)
                if let snapshot = companionManager.activeQPlanSnapshot,
                   !snapshot.steps.isEmpty,
                   !snapshot.isTerminal {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(snapshot.steps) { step in
                            HStack(spacing: 6) {
                                Text(step.statusGlyph)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(glyphColor(for: step))
                                    .frame(width: 10)
                                Text("\(step.index + 1)  \(step.description)")
                                    .font(.system(size: 9))
                                    .foregroundColor(stepTextColor(for: step))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                if companionManager.currentTurnHUDState.status == .needsClarification,
                   !companionManager.currentTurnHUDState.options.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(companionManager.currentTurnHUDState.options, id: \.self) { option in
                            Button(action: {
                                companionManager.resolveClarification(option: option)
                            }) {
                                Text(option)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.07))
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private var turnHUDSymbol: String {
        switch companionManager.currentTurnHUDState.status {
        case .idle:
            return "checkmark.circle"
        case .listening:
            return "waveform"
        case .understanding:
            return "magnifyingglass"
        case .acting:
            return "cursorarrow"
        case .needsClarification:
            return "questionmark.circle"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle"
        case .unsupported:
            return "lock.shield"
        }
    }

    private var turnHUDColor: Color {
        switch companionManager.currentTurnHUDState.status {
        case .idle:
            return DS.Colors.textTertiary
        case .listening:
            return Color.blue
        case .understanding:
            return Color.cyan
        case .acting:
            return Color.orange
        case .needsClarification:
            return Color.yellow
        case .done:
            return Color.green
        case .failed:
            return Color.red
        case .unsupported:
            return Color.purple
        }
    }

    private func glyphColor(for step: QRuntimeStepSnapshot) -> Color {
        switch step.state {
        case .completed:
            return Color.green
        case .executing:
            return Color.blue
        case .verifying:
            return Color.orange
        case .waitingForPermission:
            return Color.yellow
        case .blocked, .failed:
            return Color.red
        case .pending, .skipped:
            return DS.Colors.textTertiary
        }
    }

    private func stepTextColor(for step: QRuntimeStepSnapshot) -> Color {
        switch step.state {
        case .executing, .verifying, .waitingForPermission:
            return DS.Colors.textPrimary
        case .completed:
            return DS.Colors.textSecondary
        case .pending, .skipped:
            return DS.Colors.textTertiary
        case .blocked, .failed:
            return DS.Colors.textSecondary
        }
    }
}
