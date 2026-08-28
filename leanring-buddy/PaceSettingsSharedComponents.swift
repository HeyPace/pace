//
//  PaceSettingsSharedComponents.swift
//  leanring-buddy
//
//  Reusable SwiftUI building blocks shared across the per-tab Settings
//  view files (PaceGeneralSettingsTab, etc.).
//  Extracted from PaceSettingsWindow.swift so each tab file can be split
//  into its own struct without duplicating these tiny row/button helpers.
//
//  These are intentionally pure functions (no companion-manager state)
//  so any tab can import them without dragging extra dependencies in.
//
//  Note: `retrievalSourceToggleRow` stays in PaceActivitySettingsTab
//  because it reads CompanionManager state directly; only the truly
//  pure helpers live here.
//

import SwiftUI

@MainActor
@ViewBuilder
func paceSettingsRowLabel(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title)
            .font(DS.Typography.calloutStrong)
            .foregroundColor(DS.Colors.textPrimary)
        Text(subtitle)
            .font(DS.Typography.caption)
            .foregroundColor(DS.Colors.textTertiary)
    }
}

/// Title/subtitle row with a trailing `Toggle`. Bottom divider so a
/// vertical stack of these forms a clean list without each call site
/// repeating the divider.
@MainActor
@ViewBuilder
func paceSettingsToggleRow(
    title: String,
    subtitle: String,
    isOn: Binding<Bool>
) -> some View {
    HStack(spacing: 12) {
        paceSettingsRowLabel(title: title, subtitle: subtitle)
        Spacer()
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityHint(subtitle)
    }
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) {
        Divider()
            .background(DS.Colors.borderSubtle)
    }
}

/// Title + monospaced value row with bottom divider. Used by the Voice
/// tab and other status-style listings.
@MainActor
@ViewBuilder
func paceSettingsInfoRow(title: String, value: String) -> some View {
    HStack {
        Text(title)
            .font(DS.Typography.calloutStrong)
            .foregroundColor(DS.Colors.textSecondary)
        Spacer()
        Text(value)
            .font(DS.Typography.captionStrong)
            .foregroundColor(DS.Colors.textPrimary)
    }
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
        Divider()
            .background(DS.Colors.borderSubtle)
    }
}

/// Compact icon+title button styled to match the Settings tab visual
/// language. Used everywhere from "Save key" to "Recalibrate posture".
@MainActor
@ViewBuilder
func paceSettingsButton(
    _ title: String,
    systemName: String,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(DS.Typography.captionStrong)
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
        )
    }
    .buttonStyle(.plain)
    .pointerCursor()
}
