//
//  PacePermissionRowsView.swift
//  leanring-buddy
//
//  Notch-panel permission surfaces. Two top-level views live here:
//
//    • `PaceCorePermissionsView` — the "PERMISSIONS" block shown while
//      core TCC permissions (mic, speech, accessibility, screen
//      recording, screen content) are still missing. Each row deep-
//      links into the right macOS System Settings pane on Grant.
//
//    • `PaceToolPermissionsView` — the "LOCAL TOOLS" block shown after
//      the user has all-permissions-granted. Surfaces Automation,
//      Calendar, and Reminders permission state so users see why a
//      tool call will be blocked before invoking it.
//
//  Both views are pure render layers — they call CompanionManager
//  request methods or the WindowPositionManager system-settings deep
//  links and never carry their own state. Extracted from
//  CompanionPanelView.swift; all visual styling is preserved verbatim
//  because the panel design language (dark, capsule "Grant" buttons)
//  doesn't match the lighter helpers in PaceSettingsSharedComponents.
//

import SaaSMakerUI
import SwiftUI

// MARK: - Core permissions block

struct PaceCorePermissionsView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 2) {
            Text("permissions")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            speechRecognitionPermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                pacePanelGrantedBadge
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        pacePanelGrantButtonLabel
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        pacePanelSecondaryButtonLabel("Find App")
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("screen recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                pacePanelGrantedBadge
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    pacePanelGrantButtonLabel
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("screen content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                pacePanelGrantedBadge
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    pacePanelGrantButtonLabel
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                pacePanelGrantedBadge
            } else {
                Button(action: {
                    companionManager.requestMicrophoneAccess()
                }) {
                    pacePanelGrantButtonLabel
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var speechRecognitionPermissionRow: some View {
        let isGranted = companionManager.hasSpeechRecognitionPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("speech recognition")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Needed for on-device transcription")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                pacePanelGrantedBadge
            } else {
                Button(action: {
                    companionManager.requestSpeechRecognitionPermission()
                }) {
                    pacePanelGrantButtonLabel
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Tool permissions block

struct PaceToolPermissionsView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 2) {
            Text("local tools")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            automationPermissionRow
            calendarPermissionRow
            remindersPermissionRow
        }
    }

    private var automationPermissionRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("automation")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Notes, Music, Mail, Things, Shortcuts")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Button(action: {
                WindowPositionManager.openAutomationSettings()
            }) {
                pacePanelSecondaryButtonLabel("Open")
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    private var calendarPermissionRow: some View {
        localToolPermissionRow(
            systemImageName: "calendar",
            title: "Calendar",
            subtitle: "Read your schedule on request",
            isGranted: companionManager.hasCalendarPermission,
            shouldRequestPermission: companionManager.shouldRequestCalendarPermission,
            action: {
                companionManager.requestCalendarPermission()
            }
        )
    }

    private var remindersPermissionRow: some View {
        localToolPermissionRow(
            systemImageName: "checklist",
            title: "Reminders",
            subtitle: "Create reminders on request",
            isGranted: companionManager.hasRemindersPermission,
            shouldRequestPermission: companionManager.shouldRequestRemindersPermission,
            action: {
                companionManager.requestRemindersPermission()
            }
        )
    }

    private func localToolPermissionRow(
        systemImageName: String,
        title: String,
        subtitle: String,
        isGranted: Bool,
        shouldRequestPermission: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: systemImageName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                pacePanelGrantedBadge
            } else {
                Button(action: action) {
                    if shouldRequestPermission {
                        pacePanelGrantButtonLabel
                    } else {
                        pacePanelSecondaryButtonLabel("Open")
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Visual primitives shared between both blocks
//
// These three helpers used to live as `grantedBadge` / `grantButtonLabel`
// / `outlineButtonLabel(_:)` on CompanionPanelView. They are file-private
// here so PaceCorePermissionsView and PaceToolPermissionsView can both
// render the same Loom-style capsule buttons without a third tiny
// shared file. They do NOT match the lighter
// `paceSettingsButton(...)` style in PaceSettingsSharedComponents — the
// notch panel is the darker capsule design and intentionally separate.

@MainActor
@ViewBuilder
fileprivate var pacePanelGrantedBadge: some View {
    SMStatusPill("Granted", tone: .success)
        .fixedSize()
}

@MainActor
@ViewBuilder
fileprivate var pacePanelGrantButtonLabel: some View {
    Text("Grant")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(DS.Colors.textOnAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Colors.accent)
        )
}

@MainActor
@ViewBuilder
private func pacePanelSecondaryButtonLabel(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Colors.controlFill)
        )
}
