//
//  PaceGeneralSettingsTab.swift
//  leanring-buddy
//
//  Settings → General tab content. Keeps the default landing surface to
//  everyday interaction behavior; specialized ambient and proactive
//  controls live in Background Suggestions.
//

import SwiftUI

struct PaceGeneralSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var showsAdvancedWorkflowSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            generalSectionHeader("Core behavior")

            paceSettingsToggleRow(
                title: "Read my screen",
                subtitle: "Use local screen context when a turn needs it.",
                isOn: Binding(
                    get: { companionManager.useLocalVLMForScreenContext },
                    set: { companionManager.setUseLocalVLMForScreenContext($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Approve risky actions",
                subtitle: "Ask before non-undoable local changes, message drafts, shortcuts, and connected-tool actions.",
                isOn: Binding(
                    get: { companionManager.requiresActionApproval },
                    set: { companionManager.setRequiresActionApproval($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Cursor annotations",
                subtitle: "Show transcript, response, and pointer labels near the cursor.",
                isOn: Binding(
                    get: { companionManager.areCursorAnnotationsEnabled },
                    set: { companionManager.setCursorAnnotationsEnabled($0) }
                )
            )
            paceSettingsToggleRow(
                title: "Tuition mode",
                subtitle: "Pace teaches instead of acts: it draws shapes on screen and explains the step, rather than clicking through for you. Turn off when you want it to just do the thing.",
                isOn: Binding(
                    get: { companionManager.isTuitionModeEnabled },
                    set: { companionManager.setIsTuitionModeEnabled($0) }
                )
            )

            DisclosureGroup(isExpanded: $showsAdvancedWorkflowSettings) {
                meetingNotesSubsection
                    .padding(.top, 12)

                automationSubsection
                    .padding(.top, 18)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Advanced workflow settings")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text("Meeting capture, note retention, schedules, and plugins.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .padding(.vertical, 10)
            }
            .padding(.top, 18)
        }
    }

    private func generalSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DS.Typography.captionStrong)
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.bottom, 6)
    }

    // MARK: - Automation subsection

    /// Settings → General → Automation. Toggles for meeting mode,
    /// cron scheduling, and dynamic plugins. All default OFF.
    private var automationSubsection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Automation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            paceSettingsToggleRow(
                title: "Meeting mode",
                subtitle: "Capture system audio (excluding Pace) so Pace can listen during calls. Say \"start meeting mode\" or toggle here.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.bool(for: .isMeetingModeEnabled) },
                    set: { newValue in
                        PaceUserPreferencesStore.setBool(newValue, for: .isMeetingModeEnabled)
                        Task { @MainActor in
                            let controller = PaceMeetingModeController.shared
                            if newValue {
                                controller.isEnabled = true
                                controller.localRetriever = companionManager.localRetriever
                                // Privacy-pinned: meeting synthesis never
                                // uses the active (possibly off-device) tier.
                                controller.plannerClient = BuddyPlannerClientFactory.makeLocalOnlyPlannerForPrivacyPinnedFeatures()
                                await controller.start()
                            } else {
                                controller.isEnabled = false
                                await controller.stop()
                            }
                        }
                    }
                )
            )

            paceSettingsToggleRow(
                title: "Cron scheduling",
                subtitle: "Run recurring planner tasks on a timer. Say \"every 30 minutes check my calendar\" to add a task.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.bool(for: .isCronSchedulerEnabled) },
                    set: { newValue in
                        PaceUserPreferencesStore.setBool(newValue, for: .isCronSchedulerEnabled)
                        PaceCronScheduler.shared.setEnabled(newValue)
                    }
                )
            )

            paceSettingsToggleRow(
                title: "Dynamic plugins",
                subtitle: "Load user-installed tool plugins from ~/Library/Application Support/Pace/plugins/. Auto-repair failed commands via the planner.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.bool(.areDynamicPluginsEnabled, default: false) },
                    set: { newValue in
                        PaceUserPreferencesStore.setBool(newValue, for: .areDynamicPluginsEnabled)
                    }
                )
            )
        }
    }

    // MARK: - Meeting notes subsection

    /// Settings → General → Meeting notes. Retention days, transcription
    /// backend picker, crash-repair button, and the per-source retrieval
    /// toggle for `meetingNotes`.
    private var meetingNotesSubsection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meeting notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Retention")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Days to keep meeting notes in the retrieval index.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Stepper(
                    value: Binding(
                        get: { PaceUserPreferencesStore.meetingNotesRetentionDays() },
                        set: { PaceUserPreferencesStore.setMeetingNotesRetentionDays($0) }
                    ),
                    in: 1...365
                ) {
                    Text("\(PaceUserPreferencesStore.meetingNotesRetentionDays()) days")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcription backend")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("WhisperKit is more accurate on long audio; Apple Speech needs no model download.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Picker(
                    "Backend",
                    selection: Binding(
                        get: { PaceUserPreferencesStore.meetingNotesTranscriptionBackend() },
                        set: { PaceUserPreferencesStore.setMeetingNotesTranscriptionBackend($0) }
                    )
                ) {
                    Text("WhisperKit").tag("whisperkit")
                    Text("Apple Speech").tag("apple")
                }
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Default note profile")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Shapes how notes are organized. General reproduces the classic summary + actions + decisions.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                Picker(
                    "Profile",
                    selection: Binding(
                        get: { PaceUserPreferencesStore.meetingNotesDefaultProfileSlug() },
                        set: { PaceUserPreferencesStore.setMeetingNotesDefaultProfileSlug($0) }
                    )
                ) {
                    ForEach(PaceMeetingNoteProfileLibrary.loadProfiles(), id: \.slug) { profile in
                        Text(profile.name).tag(profile.slug)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider()
                    .background(DS.Colors.borderSubtle)
            }

            paceSettingsToggleRow(
                title: "Auto-detect meeting type",
                subtitle: "When on (and the default profile is General), a local, on-device pass picks the best profile per meeting.",
                isOn: Binding(
                    get: { PaceUserPreferencesStore.isMeetingNotesProfileInferenceEnabled() },
                    set: { PaceUserPreferencesStore.setMeetingNotesProfileInferenceEnabled($0) }
                )
            )

            paceSettingsToggleRow(
                title: "Index meeting notes for recall",
                subtitle: "When on, synthesized notes are journaled so \"what did we decide in standup?\" answers from local history.",
                isOn: Binding(
                    get: { companionManager.isLocalRetrievalSourceEnabled(.meetingNotes) },
                    set: { companionManager.setLocalRetrievalSourceEnabled($0, for: .meetingNotes) }
                )
            )

            HStack {
                Spacer()
                paceSettingsButton("Repair crashed recordings", systemName: "wrench.and.screwdriver") {
                    // Static sweep over EVERY meeting directory — a fresh
                    // recorder instance can't know a crashed meeting's UUID.
                    PaceMeetingAudioRecorder.crashRepairAllMeetingRecordings()
                }
            }
            .padding(.top, 8)
        }
    }
}
