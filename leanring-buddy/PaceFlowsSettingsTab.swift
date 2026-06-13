//
//  PaceFlowsSettingsTab.swift
//  leanring-buddy
//
//  Settings → Flows tab content. Shows the bundled recipe library plus
//  the user's saved flows (record/rename/delete/play-once). Extracted
//  from PaceSettingsWindow.swift so each tab lives in its own file.
//

import SwiftUI

struct PaceFlowsSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    // MARK: - Recipe library state
    //
    // The bundled recipes are loaded once on view appear; the
    // installed-set is recomputed from `PaceFlowStore` whenever the
    // refresh tick changes (after install/uninstall) so the row
    // buttons can flip between "Install" and "Installed · Uninstall".
    @State private var bundledRecipesForSettings: [PaceBundledRecipe] = []
    @State private var installedRecipeSlugsForSettings: Set<String> = []
    @State private var recipeLibraryRefreshTick: Int = 0
    @State private var lastRecipeActionMessage: String? = nil

    // MARK: - Saved-flow row state
    //
    // Carries the in-flight rename text per flow slug, plus the most
    // recent operation message (rename / delete / play-once) so the
    // Settings UI can surface "Renamed X → Y" or "Couldn't find Y on
    // the screen" without owning a full UI model.
    @State private var flowRowRenameDrafts: [String: String] = [:]
    @State private var flowRowEditingFlowName: String? = nil
    @State private var lastSavedFlowActionMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recipe library")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("One-click flows Pace ships out of the box. Install adds them to your saved flows; run them by name.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastRecipeActionMessage {
                    Text(lastRecipeActionMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(bundledRecipesForSettings, id: \.slug) { bundledRecipe in
                        recipeLibraryRow(bundledRecipe)
                    }
                }
                .id(recipeLibraryRefreshTick)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Saved flows")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Flows you've recorded, plus any recipes installed above. Use \"do <name>\" to run.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                savedFlowsList
            }
        }
        .onAppear {
            reloadRecipeLibrary()
        }
    }

    private func recipeLibraryRow(_ bundledRecipe: PaceBundledRecipe) -> some View {
        let isAlreadyInstalled = installedRecipeSlugsForSettings.contains(bundledRecipe.slug)
        let missingPreferenceKeys = bundledRecipe.requiredPreferences.filter { requiredPreferenceKey in
            guard let resolvedKey = PaceLocalMemoryKey(rawValue: requiredPreferenceKey) else {
                return true
            }
            return PaceLocalMemoryStore.string(for: resolvedKey) == nil
        }
        let canInstallNow = missingPreferenceKeys.isEmpty

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bundledRecipe.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(bundledRecipe.description)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !canInstallNow {
                    Text("Set \(missingPreferenceKeys.joined(separator: ", ")) in preferences first.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
            }
            Spacer()
            if isAlreadyInstalled {
                paceSettingsButton("Uninstall", systemName: "minus.circle") {
                    uninstallRecipeFromSettings(bundledRecipe)
                }
            } else {
                paceSettingsButton("Install", systemName: "plus.circle") {
                    installRecipeFromSettings(bundledRecipe)
                }
                .disabled(!canInstallNow)
                .opacity(canInstallNow ? 1 : 0.45)
                .help(canInstallNow
                      ? "Save this recipe into your flows."
                      : "Missing preference: \(missingPreferenceKeys.joined(separator: ", "))")
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
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
        .id(recipeLibraryRefreshTick)
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
        recipeLibraryRefreshTick &+= 1
    }

    private func deleteSavedFlowFromSettings(_ savedFlow: PaceRecordedFlow) {
        do {
            try companionManager.flowStore.delete(named: savedFlow.name)
            lastSavedFlowActionMessage = "Deleted \(savedFlow.name)."
        } catch {
            lastSavedFlowActionMessage = "Couldn't delete \(savedFlow.name)."
        }
        recipeLibraryRefreshTick &+= 1
    }

    private func playSavedFlowOnceFromSettings(_ savedFlow: PaceRecordedFlow) {
        // Pre-approves the flow for the current session (the user
        // clicked Play once — that IS the approval) and kicks off the
        // existing replayer path.
        companionManager.beginFlowReplay(savedFlow)
        lastSavedFlowActionMessage = "Replaying \(savedFlow.name) — \(savedFlow.steps.count) step\(savedFlow.steps.count == 1 ? "" : "s")."
    }

    private func reloadRecipeLibrary() {
        bundledRecipesForSettings = PaceRecipeLibrary.loadBundledRecipes()
        recomputeInstalledRecipeSlugs()
    }

    private func recomputeInstalledRecipeSlugs() {
        let flowStore = PaceFlowStore()
        let installedSlugs = bundledRecipesForSettings
            .filter { PaceRecipeLibrary.isInstalled($0, in: flowStore) }
            .map { $0.slug }
        installedRecipeSlugsForSettings = Set(installedSlugs)
    }

    private func installRecipeFromSettings(_ bundledRecipe: PaceBundledRecipe) {
        do {
            try PaceRecipeLibrary.install(bundledRecipe, into: PaceFlowStore())
            lastRecipeActionMessage = "Installed \(bundledRecipe.name)."
        } catch PaceRecipeInstallError.missingRequiredPreference(let requiredPreferenceKey) {
            lastRecipeActionMessage = "Set \(requiredPreferenceKey) in preferences before installing."
        } catch PaceRecipeInstallError.alreadyInstalled {
            lastRecipeActionMessage = "\(bundledRecipe.name) is already installed."
        } catch {
            lastRecipeActionMessage = "Couldn't install \(bundledRecipe.name)."
        }
        recomputeInstalledRecipeSlugs()
        recipeLibraryRefreshTick &+= 1
    }

    private func uninstallRecipeFromSettings(_ bundledRecipe: PaceBundledRecipe) {
        PaceRecipeLibrary.uninstall(slug: bundledRecipe.slug, from: PaceFlowStore())
        lastRecipeActionMessage = "Removed \(bundledRecipe.name)."
        recomputeInstalledRecipeSlugs()
        recipeLibraryRefreshTick &+= 1
    }
}
