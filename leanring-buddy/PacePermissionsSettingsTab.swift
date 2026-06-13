//
//  PacePermissionsSettingsTab.swift
//  leanring-buddy
//
//  Settings → Permissions tab content. Status + deep-link rows for the
//  macOS TCC surfaces Pace touches: Accessibility, Screen Recording,
//  Screen Content, Microphone, Speech Recognition, Calendar, Reminders,
//  and Automation. Nothing in this tab requests permission silently —
//  every action is an explicit row tap.
//

import AppKit
import SwiftUI

struct PacePermissionsSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 0) {
            paceSettingsPermissionRow(
                title: "Accessibility",
                subtitle: "Needed for clicks, keys, and AX targeting.",
                isGranted: companionManager.hasAccessibilityPermission,
                actionTitle: "Grant",
                action: { _ = WindowPositionManager.requestAccessibilityPermission() }
            )
            paceSettingsPermissionRow(
                title: "Screen Recording",
                subtitle: "Needed for screenshots and watch mode.",
                isGranted: companionManager.hasScreenRecordingPermission,
                actionTitle: "Grant",
                action: { _ = WindowPositionManager.requestScreenRecordingPermission() }
            )
            paceSettingsPermissionRow(
                title: "Screen Content",
                subtitle: "Needed to enumerate displays before screenshots.",
                isGranted: companionManager.hasScreenContentPermission,
                actionTitle: "Grant",
                action: companionManager.requestScreenContentPermission
            )
            paceSettingsPermissionRow(
                title: "Microphone",
                subtitle: "Needed for push-to-talk.",
                isGranted: companionManager.hasMicrophonePermission,
                actionTitle: "Open",
                action: openMicrophoneSettings
            )
            paceSettingsPermissionRow(
                title: "Speech Recognition",
                subtitle: "On-device transcription.",
                isGranted: companionManager.hasSpeechRecognitionPermission,
                actionTitle: "Grant",
                action: companionManager.requestSpeechRecognitionPermission
            )
            paceSettingsPermissionRow(
                title: "Calendar",
                subtitle: "Needed only for calendar tools.",
                isGranted: companionManager.hasCalendarPermission,
                actionTitle: "Grant",
                action: companionManager.requestCalendarPermission
            )
            paceSettingsPermissionRow(
                title: "Reminders",
                subtitle: "Needed only for reminder tools.",
                isGranted: companionManager.hasRemindersPermission,
                actionTitle: "Grant",
                action: companionManager.requestRemindersPermission
            )
            paceSettingsPermissionRow(
                title: "Automation",
                subtitle: "Per-app prompts for Notes, Music, Mail, Things, Shortcuts, and MCP servers.",
                isGranted: false,
                actionTitle: "Open",
                action: WindowPositionManager.openAutomationSettings
            )
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
