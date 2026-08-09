//
//  PaceFlowsSettingsTab.swift
//  leanring-buddy
//
//  Settings → Flows tab content. Shows the user's saved flows
//  (record/rename/delete/play-once). Extracted
//  from PaceSettingsWindow.swift so each tab lives in its own file.
//

import SwiftUI

struct PaceFlowsSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    // MARK: - Saved-flow row state
    //
    // Carries the in-flight rename text per flow slug, plus the most
    // recent operation message (rename / delete / play-once) so the
    // Settings UI can surface "Renamed X → Y" or "Couldn't find Y on
    // the screen" without owning a full UI model.
    @State private var flowRowRenameDrafts: [String: String] = [:]
    @State private var flowRowEditingFlowName: String? = nil
    @State private var lastSavedFlowActionMessage: String? = nil
    @State private var savedFlowRefreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved flows")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Literal UI sequences you've recorded. Use \"do <name>\" to run one, or say \"list my automations\" for every reusable workflow.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                savedFlowsList
            }
        }
    }

    private var savedFlowsList: some View {
        let savedFlows = companionManager.flowStore.listAll()
        return Group {
            if savedFlows.isEmpty {
                Text("Record your first flow by saying 'remember this flow as <name>'.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let lastSavedFlowActionMessage {
                        Text(lastSavedFlowActionMessage)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.accent)
                            .padding(.bottom, 6)
                    }
                    ForEach(savedFlows) { savedFlow in
                        savedFlowRow(savedFlow)
                    }
                }
            }
        }
        .id(savedFlowRefreshTick)
    }

    /// One row per saved flow. Shows the name, step count + createdAt,
    /// and a trailing row of "Rename / Delete / Play once" buttons.
    /// When the user taps Rename the name becomes a TextField the user
    /// can edit; pressing Enter / clicking Save commits via
    /// `PaceFlowStore.rename(...)`.
    private func savedFlowRow(_ savedFlow: PaceRecordedFlow) -> some View {
        let slug = PaceFlowStore.slug(for: savedFlow.name)
        let isEditingRename = (flowRowEditingFlowName == savedFlow.name)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if isEditingRename {
                    TextField(
                        savedFlow.name,
                        text: Binding(
                            get: { flowRowRenameDrafts[slug] ?? savedFlow.name },
                            set: { flowRowRenameDrafts[slug] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit {
                        commitRenameForSettings(originalFlowName: savedFlow.name)
                    }
                } else {
                    Text(savedFlow.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                Text("\(savedFlow.steps.count) step\(savedFlow.steps.count == 1 ? "" : "s") · saved \(savedFlow.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                if isEditingRename {
                    paceSettingsButton("Save", systemName: "checkmark.circle") {
                        commitRenameForSettings(originalFlowName: savedFlow.name)
                    }
                    paceSettingsButton("Cancel", systemName: "xmark.circle") {
                        flowRowEditingFlowName = nil
                        flowRowRenameDrafts[slug] = savedFlow.name
                    }
                } else {
                    paceSettingsButton("Play once", systemName: "play.circle") {
                        playSavedFlowOnceFromSettings(savedFlow)
                    }
                    paceSettingsButton("Rename", systemName: "pencil") {
                        flowRowEditingFlowName = savedFlow.name
                        flowRowRenameDrafts[slug] = savedFlow.name
                    }
                    paceSettingsButton("Delete", systemName: "trash") {
                        deleteSavedFlowFromSettings(savedFlow)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func commitRenameForSettings(originalFlowName: String) {
        let slug = PaceFlowStore.slug(for: originalFlowName)
        let newName = (flowRowRenameDrafts[slug] ?? originalFlowName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != originalFlowName else {
            flowRowEditingFlowName = nil
            return
        }
        do {
            try companionManager.flowStore.rename(originalFlowName, to: newName)
            lastSavedFlowActionMessage = "Renamed \(originalFlowName) → \(newName)."
        } catch PaceFlowStoreError.destinationFlowAlreadyExists(let conflictingName) {
            lastSavedFlowActionMessage = "A flow named \(conflictingName) already exists."
        } catch {
            lastSavedFlowActionMessage = "Couldn't rename \(originalFlowName)."
        }
        flowRowEditingFlowName = nil
        savedFlowRefreshTick &+= 1
    }

    private func deleteSavedFlowFromSettings(_ savedFlow: PaceRecordedFlow) {
        do {
            try companionManager.flowStore.delete(named: savedFlow.name)
            lastSavedFlowActionMessage = "Deleted \(savedFlow.name)."
        } catch {
            lastSavedFlowActionMessage = "Couldn't delete \(savedFlow.name)."
        }
        savedFlowRefreshTick &+= 1
    }

    private func playSavedFlowOnceFromSettings(_ savedFlow: PaceRecordedFlow) {
        // Pre-approves the flow for the current session (the user
        // clicked Play once — that IS the approval) and kicks off the
        // existing replayer path.
        companionManager.beginFlowReplay(savedFlow)
        lastSavedFlowActionMessage = "Replaying \(savedFlow.name) — \(savedFlow.steps.count) step\(savedFlow.steps.count == 1 ? "" : "s")."
    }

}
