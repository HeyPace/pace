//
//  PaceSettingsSharedComponents.swift
//  leanring-buddy
//
//  Reusable SwiftUI building blocks shared across the per-tab Settings
//  view files (PaceGeneralSettingsTab, PacePermissionsSettingsTab, etc.).
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
        Spacer()
        Toggle("", isOn: isOn)
            .labelsHidden()
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
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
        Spacer()
        Text(value)
            .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 12, weight: .semibold))
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

/// Permission row used by the Permissions tab. Shows a status dot,
/// title/subtitle, and either a "Granted" label or a trailing action
/// button that deep-links into System Settings.
@MainActor
@ViewBuilder
func paceSettingsPermissionRow(
    title: String,
    subtitle: String,
    isGranted: Bool,
    actionTitle: String,
    action: @escaping () -> Void
) -> some View {
    HStack(spacing: 12) {
        Circle()
            .fill(isGranted ? DS.Colors.success : DS.Colors.warning)
            .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
        Spacer()
        if isGranted {
            Text("Granted")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.success)
        } else {
            paceSettingsButton(actionTitle, systemName: "arrow.up.right.square", action: action)
        }
    }
    .padding(.vertical, 12)
    .overlay(alignment: .bottom) {
        Divider()
            .background(DS.Colors.borderSubtle)
    }
}
