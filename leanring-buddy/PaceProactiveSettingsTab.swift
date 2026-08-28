//
//  PaceProactiveSettingsTab.swift
//  leanring-buddy
//
//  Settings → Proactive tab content. The proactivity profile picker
//  (talkative/balanced/reserved) plus the nudge-surface toggles (focus
//  fatigue, calendar pre-meeting, watch-mode observation, always-
//  listening). Every surface defaults off; even when on, the restraint
//  gate suppresses output during calls or active typing.
//

import SwiftUI

struct PaceProactiveSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Proactivity Profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(
                    "How often Pace can speak up on its own. Affects every proactive surface (focus nudges, calendar lead-time prompts, watch-mode observations, the morning brief)."
                )
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                Picker(
                    "Proactivity profile",
                    selection: Binding(
                        get: { companionManager.proactivityProfile },
                        set: { companionManager.setProactivityProfile($0) }
                    )
                ) {
                    Text("Talkative").tag(PaceProactivityProfile.talkative)
                    Text("Balanced").tag(PaceProactivityProfile.balanced)
                    Text("Reserved").tag(PaceProactivityProfile.reserved)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text(proactivityProfileDescription(for: companionManager.proactivityProfile))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 10) {
                Text("Ambient awareness")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text("These modes stay local and remain off until you enable them.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textTertiary)

                paceSettingsToggleRow(
                    title: "Watch mode",
                    subtitle: companionManager.latestWatchModeSummary
                        ?? "Watch for meaningful screen changes.",
                    isOn: Binding(
                        get: { companionManager.isWatchModeEnabled },
                        set: { companionManager.setWatchModeEnabled($0) }
                    )
                )
                paceSettingsToggleRow(
                    title: "Always listening",
                    subtitle: "Opt-in ambient command mode. Push-to-talk remains available.",
                    isOn: Binding(
                        get: { companionManager.isAlwaysListeningEnabled },
                        set: { companionManager.setAlwaysListeningEnabled($0) }
                    )
                )
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 10) {
                Text("Nudge surfaces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(
                    "Each surface defaults off. Even when on, Pace routes every nudge through the restraint gate — nothing speaks during a Zoom call or while you're typing."
                )
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Focus fatigue nudges",
                    isOn: Binding(
                        get: { companionManager.areFocusFatigueNudgesEnabled },
                        set: { companionManager.setFocusFatigueNudgesEnabled($0) }
                    )
                )
                Text("After 45 minutes on the same app, Pace can suggest a short break.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Calendar pre-meeting nudges",
                    isOn: Binding(
                        get: { companionManager.areCalendarNudgesEnabled },
                        set: { companionManager.setCalendarNudgesEnabled($0) }
                    )
                )
                Text("Five-minute heads-up before meetings on your calendar.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Watch-mode observation nudges",
                    isOn: Binding(
                        get: { companionManager.areWatchObservationNudgesEnabled },
                        set: { companionManager.setWatchObservationNudgesEnabled($0) }
                    )
                )
                Text("When watch mode spots an error or failed build on screen, Pace can offer to help.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                paceSettingsToggleRow(
                    title: "Posture watch (camera)",
                    subtitle: companionManager.latestPostureStatus
                        ?? "One camera frame every ten seconds, analyzed on-device and never stored.",
                    isOn: Binding(
                        get: { companionManager.isPostureWatchEnabled },
                        set: { companionManager.setPostureWatchEnabled($0) }
                    )
                )
                if companionManager.isPostureWatchEnabled {
                    HStack {
                        Spacer()
                        paceSettingsButton(
                            "Recalibrate posture",
                            systemName: "figure.seated.side"
                        ) {
                            companionManager.recalibratePostureWatch()
                        }
                    }
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            morningBriefSection
        }
    }

    private var morningBriefSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Morning brief")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.bottom, 6)

            paceSettingsToggleRow(
                title: "Daily morning brief",
                subtitle:
                    "A calm spoken brief at the configured weekday time, subject to the same interruption rules as other suggestions.",
                isOn: Binding(
                    get: { companionManager.isMorningTriageEnabled },
                    set: { companionManager.setMorningTriageEnabled($0) }
                )
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delivery time")
                        .font(DS.Typography.calloutStrong)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Local time, weekdays only.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                Spacer()
                Picker(
                    "Hour",
                    selection: Binding(
                        get: { companionManager.morningTriageHourOfDay },
                        set: { companionManager.setMorningTriageHourOfDay($0) }
                    )
                ) {
                    ForEach(0..<24, id: \.self) { hourOfDayCandidate in
                        Text(String(format: "%02d", hourOfDayCandidate))
                            .tag(hourOfDayCandidate)
                    }
                }
                .labelsHidden()
                .frame(width: 60)

                Text(":")
                    .font(DS.Typography.calloutStrong)
                    .foregroundStyle(DS.Colors.textTertiary)

                Picker(
                    "Minute",
                    selection: Binding(
                        get: { companionManager.morningTriageMinuteOfHour },
                        set: { companionManager.setMorningTriageMinuteOfHour($0) }
                    )
                ) {
                    ForEach(0..<60, id: \.self) { minuteOfHourCandidate in
                        Text(String(format: "%02d", minuteOfHourCandidate))
                            .tag(minuteOfHourCandidate)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Divider().background(DS.Colors.borderSubtle)
            }

            HStack {
                Spacer()
                paceSettingsButton("Preview now", systemName: "paperplane") {
                    companionManager.deliverMorningBriefPreviewNow()
                }
            }
            .padding(.top, 8)
        }
    }

    private func proactivityProfileDescription(for profile: PaceProactivityProfile) -> String {
        switch profile {
        case .talkative:
            return "Talkative: shorter cooldowns (about 5 minutes between proactive utterances)."
        case .balanced:
            return
                "Balanced: default cooldowns (about 10 minutes between proactive utterances). Recommended for most users."
        case .reserved:
            return
                "Reserved: longer cooldowns (about 30 minutes between proactive utterances). Pace stays mostly quiet."
        }
    }
}
