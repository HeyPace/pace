//
//  PaceActivitySettingsTab.swift
//  leanring-buddy
//
//  Settings → Activity tab content. Surfaces three sub-sections:
//   - Thread summary (verbatim window + idle threshold + show summary
//     toggle + episodic handoff toggle)
//   - Local memory + local retrieval (file folders, retrieval sources,
//     reset button)
//   - Recent actions (last N approved tool calls)
//
//  The thread-memory state mirrors `PaceUserPreferencesStore`; writes
//  go through that store and take effect on the next
//  `CompanionManager.start()` (this is a setup-time surface, not a
//  per-turn control).
//

import AppKit
import SwiftUI

struct PaceActivitySettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    // MARK: - Thread memory state

    @State private var isThreadMemoryEnabledForSettings: Bool = PaceUserPreferencesStore
        .bool(.isThreadMemoryEnabled, default: true)
    @State private var threadMemoryVerbatimWindowSizeForSettings: Int = PaceUserPreferencesStore
        .clampedInt(.threadMemoryVerbatimWindowSize, default: 4, in: 1...8)
    @State private var threadMemoryIdleMinutesForSettings: Int = PaceUserPreferencesStore
        .clampedInt(.threadMemoryIdleMinutes, default: 20, in: 5...60)
    @State private var isThreadMemoryDebugViewEnabledForSettings: Bool = PaceUserPreferencesStore
        .bool(.isThreadMemoryDebugViewEnabled, default: false)
    @State private var isThreadEndingEpisodicHandoffEnabledForSettings: Bool = PaceUserPreferencesStore
        .bool(.isThreadEndingEpisodicHandoffEnabled, default: false)
    /// Tick value used to force a redraw of the debug summary text
    /// when the user clicks "Reset thread now". The summary itself is
    /// pulled from `companionManager.currentThreadMemorySummarySnapshot()`
    /// on each render.
    @State private var threadMemoryRefreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            threadSummarySection

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Local memory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(companionManager.localMemorySummary)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(companionManager.localRetrievalSummary)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                paceSettingsButton("Reset Retrieval", systemName: "arrow.counterclockwise") {
                    companionManager.resetLocalRetrievalIndex()
                }

                localRetrievalFileRootsSection

                VStack(alignment: .leading, spacing: 0) {
                    Text("Retrieval sources")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, 8)

                    ForEach(PaceRetrievalSource.allCases, id: \.rawValue) { source in
                        retrievalSourceToggleRow(source)
                    }
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent actions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                if companionManager.recentActionResults.isEmpty {
                    Text("No approved actions yet.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ForEach(companionManager.recentActionResults.prefix(8)) { actionResult in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(actionResult.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(actionResult.detail)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    // MARK: - Thread summary subsection

    /// Two-tier in-context thread memory controls. Episodic memory has
    /// its own tab; this section is strictly about the rolling verbatim
    /// window + summary that keeps long conversations coherent. They
    /// are intentionally NOT cross-wired — summary recall is loose; the
    /// episodic extractor is precise; coupling them risks low-confidence
    /// facts.
    private var threadSummarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thread summary")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Pace keeps the last few turns verbatim and rolls everything older into a one-paragraph summary so it stays coherent across a long conversation. This conversation only — never saved to disk.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $isThreadMemoryEnabledForSettings) {
                Text("Remember this conversation")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: isThreadMemoryEnabledForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isThreadMemoryEnabled)
                if !newValue {
                    companionManager.resetThreadMemoryNow()
                    threadMemoryRefreshTick &+= 1
                }
            }

            HStack(spacing: 12) {
                Text("Verbatim window")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: $threadMemoryVerbatimWindowSizeForSettings) {
                    ForEach(1...8, id: \.self) { turnPairCount in
                        Text("\(turnPairCount) turn pair\(turnPairCount == 1 ? "" : "s")")
                            .tag(turnPairCount)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: threadMemoryVerbatimWindowSizeForSettings) { _, newValue in
                    PaceUserPreferencesStore.setInt(newValue, for: .threadMemoryVerbatimWindowSize)
                }
            }
            .help("How much exact context the planner sees before falling back to a summary.")

            HStack(spacing: 12) {
                Text("Idle threshold")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("", selection: $threadMemoryIdleMinutesForSettings) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { idleMinutes in
                        Text("\(idleMinutes) minutes").tag(idleMinutes)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .onChange(of: threadMemoryIdleMinutesForSettings) { _, newValue in
                    PaceUserPreferencesStore.setInt(newValue, for: .threadMemoryIdleMinutes)
                }
            }

            paceSettingsButton("Reset thread now", systemName: "arrow.counterclockwise") {
                companionManager.resetThreadMemoryNow()
                threadMemoryRefreshTick &+= 1
            }

            Toggle(isOn: $isThreadMemoryDebugViewEnabledForSettings) {
                Text("Show current summary")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: isThreadMemoryDebugViewEnabledForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isThreadMemoryDebugViewEnabled)
            }

            if isThreadMemoryDebugViewEnabledForSettings {
                let snapshot = companionManager.currentThreadMemorySummarySnapshot()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary version: \(snapshot.summaryVersion)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(snapshot.summaryText ?? "(no summary yet — verbatim window covers the whole session)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(threadMemoryRefreshTick)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.borderSubtle.opacity(0.25))
                .cornerRadius(6)
            }

            Toggle(isOn: $isThreadEndingEpisodicHandoffEnabledForSettings) {
                Text("On session end, share summary with episodic memory")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            .onChange(of: isThreadEndingEpisodicHandoffEnabledForSettings) { _, newValue in
                PaceUserPreferencesStore.setBool(newValue, for: .isThreadEndingEpisodicHandoffEnabled)
            }
            .help("Default off. When on, the final summary is offered to the episodic extractor — the extractor decides whether anything is durable enough to keep.")
        }
    }

    // MARK: - Retrieval file-roots subsection

    private var localRetrievalFileRootsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("File folders")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                paceSettingsButton("Add Folder", systemName: "folder.badge.plus") {
                    chooseLocalRetrievalFileRoots()
                }
                paceSettingsButton("Clear", systemName: "xmark.circle") {
                    companionManager.clearLocalRetrievalFileRootPaths()
                }
                .disabled(companionManager.localRetrievalFileRootPaths.isEmpty)
                .opacity(companionManager.localRetrievalFileRootPaths.isEmpty ? 0.45 : 1)
            }

            if companionManager.localRetrievalFileRootPaths.isEmpty {
                Text("No folders selected. File retrieval will stay skipped unless roots are set in the app bundle.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(companionManager.localRetrievalFileRootPaths, id: \.self) { rootPath in
                        localRetrievalFileRootRow(rootPath)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func localRetrievalFileRootRow(_ rootPath: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 18)

            Text(rootPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            Button {
                companionManager.removeLocalRetrievalFileRootPath(rootPath)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove folder")
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func retrievalSourceToggleRow(_ source: PaceRetrievalSource) -> some View {
        let sourceStatus = companionManager.localRetrievalSourceStatuses.first { $0.source == source }
        let indexedDocumentCount = sourceStatus?.documentCount ?? 0
        let subtitle: String
        if let sourceStatus {
            if let lastError = sourceStatus.lastError {
                if sourceStatus.documentCount > 0 {
                    subtitle = "\(lastError) \(sourceStatus.documentCount) indexed locally."
                } else {
                    subtitle = lastError
                }
            } else {
                subtitle = "\(sourceStatus.documentCount) indexed"
            }
        } else {
            subtitle = "No local documents indexed"
        }

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                companionManager.clearLocalRetrievalSource(source)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(indexedDocumentCount > 0 ? DS.Colors.warning : DS.Colors.textTertiary)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(indexedDocumentCount > 0 ? 0.07 : 0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Clear indexed \(source.displayName.lowercased()) documents")
            .disabled(indexedDocumentCount == 0)
            .opacity(indexedDocumentCount == 0 ? 0.45 : 1)

            Toggle("", isOn: Binding(
                get: { companionManager.isLocalRetrievalSourceEnabled(source) },
                set: { companionManager.setLocalRetrievalSourceEnabled($0, for: source) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private func chooseLocalRetrievalFileRoots() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Add File Retrieval Folders"
        openPanel.prompt = "Add"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.canCreateDirectories = false

        guard openPanel.runModal() == .OK else { return }
        companionManager.addLocalRetrievalFileRootURLs(openPanel.urls)
    }
}
