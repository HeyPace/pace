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
                Text("How often Pace can speak up on its own. Affects every proactive surface (focus nudges, calendar lead-time prompts, watch-mode observations, the morning brief).")
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
                Text("Nudge surfaces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Each surface defaults off. Even when on, Pace routes every nudge through the restraint gate — nothing speaks during a Zoom call or while you're typing.")
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

                Toggle(
                    "Always-Listening (wake word)",
                    isOn: Binding(
                        get: { companionManager.isAlwaysListeningEnabled },
                        set: { companionManager.setAlwaysListeningEnabled($0) }
                    )
                )
                Text("Audio buffer never persists. Battery impact ~5% per 3-hour session.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            // Wave 2 adds episodic memory access
        }
    }

    private func proactivityProfileDescription(for profile: PaceProactivityProfile) -> String {
        switch profile {
        case .talkative:
            return "Talkative: shorter cooldowns (about 5 minutes between proactive utterances)."
        case .balanced:
            return "Balanced: default cooldowns (about 10 minutes between proactive utterances). Recommended for most users."
        case .reserved:
            return "Reserved: longer cooldowns (about 30 minutes between proactive utterances). Pace stays mostly quiet."
        }
    }
}
