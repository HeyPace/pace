//
//  PaceConversationsView.swift
//  leanring-buddy
//
//  Chat surface for the Conversations tab of the main window. Renders
//  the live, ordered transcript backed by `PaceChatSession` — which in
//  turn reads/writes through the same `paceHistory` retrieval index
//  that voice turns already persist to, so voice and chat always share
//  one canonical conversation. Below the transcript is a sticky text
//  input: Enter dispatches through the same `submitChatTranscriptFrom…`
//  pipeline a `pace://chat` deeplink uses. The notch panel stays
//  voice-first; THIS surface is the text-fallback PRD deliverable.
//
//  The search field from the prior read-only list view is preserved as
//  an in-line filter so an existing user habit ("open Pace, search for
//  what we talked about last week") still works.
//

import Foundation
import SwiftUI

struct PaceConversationsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var chatSession: PaceChatSession

    @State private var searchQuery: String = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chatHeader
            searchField
            transcriptScrollView
            chatInputRow
        }
        .background(DS.Colors.surface)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            chatSession.loadHistoryWithoutBlockingInterface()
            isInputFocused = true
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Conversations")
                    .font(DS.Typography.windowTitle)
                    .tracking(-0.45)
                    .foregroundStyle(DS.Colors.textPrimary)

                Text(companionManager.isOffDeviceTurnInFlight ? "Off-device" : "On this Mac")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(
                        companionManager.isOffDeviceTurnInFlight
                            ? DS.Colors.offDeviceSignal
                            : DS.Colors.localSignal
                    )

                Spacer()
                muteToggleButton
                headerIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh conversations"
                ) {
                    chatSession.loadHistoryWithoutBlockingInterface()
                }
            }

            Text("Your voice and typed turns share one private conversation history.")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var muteToggleButton: some View {
        let isMuted = chatSession.isChatTTSMuted
        return headerIconButton(
            systemName: isMuted ? "speaker.slash" : "speaker.wave.2",
            help: isMuted
                ? "Replies are silent this session. Unmute Pace."
                : "Pace speaks replies. Mute this session."
        ) {
            chatSession.isChatTTSMuted.toggle()
        }
    }

    private func headerIconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(DS.Colors.surfaceRaised)
                )
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: 15)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
            TextField("Search past turns", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Colors.surfaceInset)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                }
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Transcript

    private var transcriptScrollView: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if filteredThreadRows.isEmpty {
                        emptyState
                            .padding(.top, 72)
                    } else {
                        ForEach(filteredThreadRows) { threadRow in
                            switch threadRow {
                            case .message(let messageRowModel):
                                messageRow(messageRowModel)
                            case .toolActivity(let toolActivityRowModel):
                                toolActivityRow(toolActivityRowModel)
                            }
                        }
                    }
                    streamingAssistantRowIfActive
                        .id(PaceConversationsView.streamingRowAnchorId)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: chatSession.messages.count) {
                scrollToBottom(scrollViewProxy: scrollViewProxy)
            }
            .onChange(of: companionManager.recentActionResults.count) {
                scrollToBottom(scrollViewProxy: scrollViewProxy)
            }
            .onChange(of: companionManager.streamingSentenceTTSPipeline.inFlightStreamedText) {
                scrollToBottom(scrollViewProxy: scrollViewProxy)
            }
            .onAppear {
                scrollToBottom(scrollViewProxy: scrollViewProxy, animated: false)
            }
        }
    }

    private static let streamingRowAnchorId = "streaming-assistant-row-anchor"

    private func scrollToBottom(scrollViewProxy: ScrollViewProxy, animated: Bool = true) {
        let targetId: String = {
            if companionManager.streamingSentenceTTSPipeline.inFlightStreamedText.isEmpty == false {
                return PaceConversationsView.streamingRowAnchorId
            }
            return filteredThreadRows.last?.id
                ?? PaceConversationsView.streamingRowAnchorId
        }()
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                scrollViewProxy.scrollTo(targetId, anchor: .bottom)
            }
        } else {
            scrollViewProxy.scrollTo(targetId, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PaceSignalNotchView(state: .ready, isOffDeviceTurn: false)
                .frame(width: 140, height: 44)
            Text(searchQuery.isEmpty ? "Start with one useful request." : "No matching turns.")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(
                searchQuery.isEmpty
                    ? "Type below or hold Control + Option anywhere to talk."
                    : "Try a shorter phrase or clear the search."
            )
            .font(DS.Typography.callout)
            .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredMessages: [PaceChatMessage] {
        chatSession.filteredMessages(matching: searchQuery)
    }

    private var filteredThreadRows: [PaceChatThreadRowModel] {
        let normalizedSearchQuery =
            searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let actionRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromNewestFirstActionRunRecords: companionManager.recentActionResults
        ).filter { actionRowModel in
            normalizedSearchQuery.isEmpty
                || actionRowModel.toolDisplayName.lowercased().contains(normalizedSearchQuery)
                || actionRowModel.resultSummaryLine.lowercased().contains(normalizedSearchQuery)
        }
        return PaceChatTranscriptModel.threadRows(
            messageRowModels: PaceChatTranscriptModel.messageRowModels(
                fromChatMessages: filteredMessages
            ),
            toolActivityRowModels: actionRowModels
        )
    }

    private func messageRow(_ messageRowModel: PaceChatTranscriptMessageRowModel) -> some View {
        let isFromUser = messageRowModel.author == .user
        return HStack(alignment: .bottom, spacing: 0) {
            if isFromUser {
                Spacer(minLength: 120)
            }

            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(isFromUser ? "You" : "Pace")
                        .font(DS.Typography.captionStrong)
                    Text(messageRowModel.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(DS.Typography.caption)
                }
                .foregroundStyle(DS.Colors.textTertiary)

                Text(messageRowModel.bodyText)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                            .fill(
                                isFromUser
                                    ? DS.Colors.localSignal.opacity(0.20)
                                    : DS.Colors.surfaceRaised
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: DS.Radius.surface,
                                    style: .continuous
                                )
                                .stroke(
                                    isFromUser
                                        ? DS.Colors.localSignal.opacity(0.26)
                                        : DS.Colors.borderSubtle.opacity(0.70),
                                    lineWidth: 0.7
                                )
                            }
                    )
                    .contextMenu {
                        ShareAndCopyContextMenuItems(messageBody: messageRowModel.bodyText)
                    }
            }
            .frame(maxWidth: 620, alignment: isFromUser ? .trailing : .leading)

            if !isFromUser {
                Spacer(minLength: 120)
            }
        }
    }

    private func toolActivityRow(
        _ toolActivityRowModel: PaceChatToolActivityRowModel
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: toolActivityRowModel.resultState.systemSymbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(toolActivityColor(for: toolActivityRowModel.resultState))

            Text(toolActivityRowModel.toolDisplayName)
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(1)

            Text(toolActivityRowModel.resultSummaryLine)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surfaceRaised)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.7)
                }
        )
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(toolActivityRowModel.resultState.displayLabel): "
                + "\(toolActivityRowModel.toolDisplayName). "
                + toolActivityRowModel.resultSummaryLine
        )
    }

    private func toolActivityColor(
        for resultState: PaceChatToolActivityResultState
    ) -> Color {
        switch resultState {
        case .running:
            return DS.Colors.localSignal
        case .done:
            return DS.Colors.success
        case .failed:
            return DS.Colors.warning
        }
    }

    @ViewBuilder
    private var streamingAssistantRowIfActive: some View {
        let streamingText = companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
        if !streamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Pace")
                            .font(DS.Typography.captionStrong)
                        Text("responding")
                            .font(DS.Typography.caption)
                    }
                    .foregroundStyle(DS.Colors.localSignal)

                    Text(streamingText)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(
                                cornerRadius: DS.Radius.surface,
                                style: .continuous
                            )
                            .fill(DS.Colors.surfaceRaised)
                        )
                }
                .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 120)
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var chatInputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "Message Pace…",
                text: $chatSession.draftMessageText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(DS.Typography.body)
            .foregroundStyle(DS.Colors.textPrimary)
            .focused($isInputFocused)
            .onSubmit(submitDraftMessage)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                    .fill(DS.Colors.surfaceInset)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: DS.Radius.surface,
                            style: .continuous
                        )
                        .stroke(
                            isInputFocused
                                ? DS.Colors.localSignal.opacity(0.85)
                                : DS.Colors.borderSubtle,
                            lineWidth: isInputFocused ? 1.2 : 0.8
                        )
                    }
            )
            .help("Return sends. Shift + Return inserts a new line.")

            Button(action: submitDraftMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        isDraftEmpty
                            ? DS.Colors.textTertiary
                            : DS.Colors.textOnAccent
                    )
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(isDraftEmpty ? DS.Colors.surfaceRaised : DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .paceControlHoverHighlight(cornerRadius: 17, isEnabled: !isDraftEmpty)
            .pointerCursor(isEnabled: !isDraftEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isDraftEmpty)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(DS.Colors.surfaceRaised.opacity(0.34))
        .overlay(alignment: .top) {
            Divider()
                .background(DS.Colors.borderSubtle)
        }
    }

    private var isDraftEmpty: Bool {
        chatSession.draftMessageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func submitDraftMessage() {
        let trimmedDraftMessage = chatSession.draftMessageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraftMessage.isEmpty else { return }
        chatSession.submitUserMessage(trimmedDraftMessage)
        chatSession.draftMessageText = ""
        isInputFocused = true
    }
}

// MARK: - Share + Copy context menu items

/// Right-click menu actions for a chat message. The Share entry
/// hands the message to NSSharingServicePicker; the Copy entry
/// stays in pasteboard land for users who'd rather paste it
/// themselves. The view embeds a hidden NSView via
/// NSViewRepresentable so NSSharingServicePicker has a real
/// AppKit anchor to position itself against.
private struct ShareAndCopyContextMenuItems: View {
    let messageBody: String

    var body: some View {
        Button("Copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(messageBody, forType: .string)
        }
        Button("Share…") {
            presentSystemSharePickerAnchoredToKeyWindow()
        }
    }

    /// Anchor the share picker to whichever NSView is currently
    /// receiving events in the key window. Using the key window's
    /// content view as the anchor is what every other right-click-
    /// initiated share picker on macOS does, and it produces the
    /// expected "share sheet floats near where I right-clicked"
    /// behaviour without us having to thread a per-row NSView
    /// reference through SwiftUI.
    private func presentSystemSharePickerAnchoredToKeyWindow() {
        guard let anchorView = NSApp.keyWindow?.contentView else { return }
        PaceMessageShareService.presentSharePicker(
            forText: messageBody,
            anchoredTo: anchorView
        )
    }
}
