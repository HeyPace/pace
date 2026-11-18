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
import SaaSMakerUI
import SwiftUI

struct PaceConversationsView: View {
    @ObservedObject private var appearanceStore = PaceChatAppearanceStore.shared
    private var appearance: PaceChatAppearance { appearanceStore.appearance }

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
            PaceJapanesePracticeControl(companionManager: companionManager)
                .padding(.horizontal, appearance.padding(existing: 24))
                .padding(.bottom, 10)
            PaceDialogueCurrentStatusView(companionManager: companionManager)
                .padding(.horizontal, appearance.padding())
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
                SMSectionHeader("", accent: "conversations", size: 28)
                    .layoutPriority(1)

                SMStatusPill(
                    companionManager.isOffDeviceTurnInFlight ? "off-device" : "on this mac",
                    tone: companionManager.isOffDeviceTurnInFlight ? .warning : .brand
                )
                .fixedSize()

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
        .padding(.horizontal, appearance.padding(existing: 24))
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
                .fill(Color.black)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                }
        )
        .padding(.horizontal, appearance.padding(existing: 24))
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
                            case .activity(let activity):
                                PaceDialogueActivityView(activity: activity) {
                                    PaceSettingsWindowManager.shared.show(companionManager: companionManager, destination: .doctor)
                                }
                            }
                        }
                    }
                    streamingAssistantRowIfActive
                        .id(PaceConversationsView.streamingRowAnchorId)
                }
                .padding(.horizontal, appearance.padding(existing: 24))
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
                    ? "Type below or hold \(BuddyPushToTalkShortcut.currentShortcutOption.notchDisplayLabel) anywhere to talk."
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

    private var filteredThreadRows: [PaceDialogueTranscriptItem] {
        let normalizedSearchQuery =
            searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let actionRowModels = PaceDialogueTranscriptModel.activityRows(
            fromNewestFirst: companionManager.recentActionResults
        ).filter { actionRowModel in
            normalizedSearchQuery.isEmpty
                || actionRowModel.toolDisplayName.lowercased().contains(normalizedSearchQuery)
                || actionRowModel.resultSummaryLine.lowercased().contains(normalizedSearchQuery)
        }
        return PaceDialogueTranscriptModel.items(
            messages: PaceChatTranscriptModel.messageRowModels(
                fromChatMessages: filteredMessages
            ),
            activities: actionRowModels
        )
    }

    private func messageRow(_ message: PaceChatTranscriptMessageRowModel) -> some View {
        PaceDialogueMessageView(
            message: message, appearance: appearance,
            canReplay: companionManager.canReplayChatSpeech,
            onReplay: companionManager.replayChatSpeech)
    }

    @ViewBuilder
    private var streamingAssistantRowIfActive: some View {
        let streamingText = companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
        if PaceDialogueTranscriptModel.shouldShowStreamingReply(
            text: streamingText,
            assistantEventIdentifier: companionManager.activeConversationAssistantEventIdentifier,
            committedMessages: chatSession.messages) {
            PaceDialogueMessageView(message: PaceChatTranscriptMessageRowModel(
                id: "streaming-reply", author: .assistant,
                bodyText: streamingText, createdAt: .distantFuture), appearance: appearance)
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
            .font(appearance.font(size: 14))
            .lineSpacing(appearance.lineSpacing())
            .foregroundStyle(DS.Colors.textPrimary)
            .focused($isInputFocused)
            .onSubmit(submitDraftMessage)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                    .fill(Color.black)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: DS.Radius.surface,
                            style: .continuous
                        )
                        .stroke(
                            isInputFocused
                                ? appearance.controlColor(existing: DS.Colors.localSignal).opacity(0.85)
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
                            : appearance.controlForeground
                    )
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(isDraftEmpty ? DS.Colors.surfaceRaised : appearance.controlColor)
                    )
            }
            .buttonStyle(.plain)
            .paceControlHoverHighlight(cornerRadius: 17, isEnabled: !isDraftEmpty)
            .pointerCursor(isEnabled: !isDraftEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isDraftEmpty)
            .accessibilityLabel("Send message")

            if companionManager.voiceState != .idle {
                Button {
                    companionManager.cancelCurrentTurnFromPanel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 17)
                .pointerCursor()
                .keyboardShortcut(.escape, modifiers: [.command])
                .accessibilityLabel("Stop current request")
                .help("Stop after the current completed action")
            }
        }
        .padding(.horizontal, appearance.padding(existing: 24))
        .padding(.vertical, 14)
        .background(Color.black)
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
struct ShareAndCopyContextMenuItems: View {
    let messageBody: String

    var body: some View {
        Button("copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(messageBody, forType: .string)
        }
        Button("share…") {
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
