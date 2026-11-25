//
//  PacePanelChatView.swift
//  leanring-buddy
//
//  The premium notch/corner panel surface: a clean conversation view, like a
//  focused command bar. A compact header (status + gear → Settings + close),
//  the live transcript (your words typed or spoken, Pace's streamed reply,
//  tool use inline), and a sticky input. Everything else — planner/voice/ASR
//  status, toggles, permissions, activity, memory — lives behind the gear in
//  PaceSettingsWindow.
//
//  Replaces the prior `CompanionPanelView` dashboard as the panel's content.
//  `CompanionPanelView` is kept in the tree (not deleted) so it's a one-line
//  revert if needed.
//
//  Backed entirely by existing state: `PaceChatSession` (shared voice+chat
//  transcript), `inFlightStreamedText` (live streamed reply), and the same
//  submit pipeline the chat tab uses. Live speech-to-text and inline tool
//  chips layer in on top of this surface.
//

import SaaSMakerUI
import SwiftUI

struct PacePanelChatView: View {
    private enum Layout {
        static let messageSpacing: CGFloat = 12
    }

    @ObservedObject private var appearanceStore = PaceChatAppearanceStore.shared
    private var appearance: PaceChatAppearance { appearanceStore.appearance }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var chatSession: PaceChatSession
    @ObservedObject private var imageOverlayController: PaceImageOverlayController
    @ObservedObject private var diagramOverlayController: PaceDiagramOverlayController

    @State private var powerBrowser: PacePowerBrowserLocation?
    @State private var scrollTarget: String?
    @State private var mainMessageLimit = 32
    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let contentSize: CGSize?
    private let isEmbeddedInNotch: Bool
    private let composerFocusRequestID: UUID?

    init(
        companionManager: CompanionManager,
        isEmbeddedInNotch: Bool = false,
        contentSize: CGSize? = nil,
        composerFocusRequestID: UUID?
    ) {
        self.companionManager = companionManager
        self.isEmbeddedInNotch = isEmbeddedInNotch
        self.contentSize = contentSize
        self.composerFocusRequestID = composerFocusRequestID
        self._chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
        self._imageOverlayController = ObservedObject(wrappedValue: companionManager.imageOverlayController)
        self._diagramOverlayController = ObservedObject(wrappedValue: companionManager.diagramOverlayController)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            turnStage
            PaceThreadLocationBar(session: chatSession, onBack: reveal)
                .padding(.horizontal, appearance.padding())
            transcript
                .opacity(powerBrowser == nil ? 1 : 0)
                .accessibilityHidden(powerBrowser != nil)
                .disabled(powerBrowser != nil)
                .allowsHitTesting(powerBrowser == nil)
                .overlay {
                    if let powerBrowser {
                        PaceChatPowerCatalogBrowser(
                            catalog: powerBrowser.catalog, initialCategory: powerBrowser.category,
                            returnTitle: chatSession.activeThreadRootID == nil ? "Main chat" : "Replies",
                            goBack: {
                                self.powerBrowser = nil
                                isInputFocused = true
                            },
                            performAction: { entry, action in
                                self.powerBrowser = nil
                                companionManager.submitChatPowerCatalogAction(action, entry: entry)
                            }
                        )
                    }
                }
            inputRow
        }
        .frame(
            width: isEmbeddedInNotch ? PaceQuickPanelMetrics.width : contentSize?.width ?? appearance.anchoredWidth(),
            height: isEmbeddedInNotch
                ? PaceQuickPanelMetrics.seamlessContentHeight : contentSize?.height ?? PaceQuickPanelMetrics.height
        )
        .background(conversationBackground)
        .paceRootTheme(isRoot: true)
        .clipShape(
            RoundedRectangle(
                cornerRadius: isEmbeddedInNotch ? 0 : DS.Radius.window,
                style: .continuous
            )
        )
        .shadow(
            color: Color.black.opacity(isEmbeddedInNotch ? 0 : 0.46),
            radius: 22,
            x: 0,
            y: 12
        )
        .onChange(of: chatSession.activeThreadRootID) { powerBrowser = nil }
        .onAppear {
            chatSession.loadHistoryWithoutBlockingInterface()
            isInputFocused = composerFocusRequestID != nil
        }
        .onChange(of: composerFocusRequestID) { _, composerFocusRequestID in
            isInputFocused = composerFocusRequestID != nil
        }
        .onChange(of: isInputFocused) { _, isInputFocused in
            if isInputFocused { companionManager.prewarmFastAnswerCredentialsIfNeeded() }
        }
    }

    // MARK: - Header

    private var conversationBackground: Color {
        isEmbeddedInNotch ? .black : DS.Colors.surface
    }

    private var header: some View {
        HStack(spacing: 9) {
            if !isEmbeddedInNotch {
                PaceBrandMark()
                    .foregroundStyle(DS.Colors.textPrimary)
                    .frame(width: 19, height: 19)
                Text("pace")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            Text(chatSession.activeThreadRootID == nil ? "Main chat" : "Replies")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            if companionManager.isOffDeviceTurnInFlight {
                Text("\(plannerLabel) ↗")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.offDeviceSignal)
                    .help(boundaryHelpText)
            }
            PaceChatOptionsMenu(companionManager: companionManager)
            if !isEmbeddedInNotch {
                iconButton(systemName: "xmark", help: "Close conversation") {
                    NotificationCenter.default.post(
                        name: .paceDismissPanel, object: PaceExplanationDismissalIntent.userInitiated)
                }
                .keyboardShortcut(powerBrowser == nil ? .cancelAction : nil)
            }
        }
        .padding(.horizontal, appearance.padding())
        .frame(height: isEmbeddedInNotch ? 32 : 40)
    }

    private var turnStage: some View {
        PaceDialogueCurrentStatusView(companionManager: companionManager)
            .padding(.horizontal, appearance.padding())
    }

    private func iconButton(
        systemName: String,
        help: String,
        title: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                if let title { Text(title) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, title == nil ? 0 : 6)
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { scrollProxy in
            let sources = Dictionary(uniqueKeysWithValues: visibleMessages.map { ("message-" + $0.id, $0) })
            ScrollView {
                // The panel transcript is deliberately bounded by PaceChatSession.
                // A regular stack keeps the accessibility tree stable while a
                // response is replaced or queued rows are completed; SwiftUI's
                // lazy-layout accessibility bridge can otherwise traverse a
                // changing ForEach from a non-main update group and trap.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Layout.messageSpacing) {
                        if chatSession.activeThreadRootID == nil, chatSession.visibleMessages.count > mainMessageLimit {
                            Button("Show earlier messages") { mainMessageLimit += 32 }
                                .buttonStyle(.plain).font(.callout)
                                .paceControlHoverHighlight(cornerRadius: DS.Radius.control).pointerCursor()
                        }
                        if visibleMessages.isEmpty && liveSpeechDraft.isEmpty && inFlightStreamedText.isEmpty {
                            emptyState.padding(.top, 24)
                        } else {
                            ForEach(threadItems) { item in
                                switch item {
                                case .message(let message):
                                    messageRow(message, source: sources[message.id]).id(item.id)
                                case .activity(let activity):
                                    PaceDialogueActivityView(activity: activity) {
                                        PaceSettingsWindowManager.shared.show(
                                            companionManager: companionManager, destination: .doctor)
                                    }
                                    .id(item.id)
                                }
                            }
                        }
                        if companionManager.isViewingLiveTurn, let imageStatus = imageOverlayController.statusText {
                            artifactLink(title: imageStatus, systemName: "photo", actionLabel: "Open image") {
                                imageOverlayController.show()
                            }
                        }
                        if companionManager.isViewingLiveTurn, let document = diagramOverlayController.document {
                            artifactLink(
                                title: document.title,
                                systemName: document.figure == nil ? "point.3.connected.trianglepath.dotted" : "cube",
                                actionLabel: "Open diagram"
                            ) {
                                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
                            }
                        }
                        if companionManager.isViewingLiveTurn {
                            liveUserBubbleRow
                            streamingReplyRow
                        }
                    }
                    .padding(.vertical, 16)
                    // The scroll target must not add another message gap after the last reply.
                    Color.clear.frame(height: 0).id(Self.streamingAnchorID)
                }
                .padding(.horizontal, appearance.padding())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: scrollTarget) {
                guard let scrollTarget else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollProxy.scrollTo(scrollTarget, anchor: .center)
                self.scrollTarget = nil
            }
            .onChange(of: visibleMessages.last?.id) {
                if scrollTarget == nil { scrollToBottom(scrollProxy) }
            }
            .onChange(of: composerFocusRequestID) { _, composerFocusRequestID in
                guard composerFocusRequestID != nil else { return }
                scrollToBottom(scrollProxy, animated: false)
            }
            .onChange(of: inFlightStreamedText) {
                guard companionManager.isViewingLiveTurn else { return }
                scrollToBottom(scrollProxy, animated: false)
            }
            .onChange(of: liveSpeechDraft) {
                guard companionManager.isViewingLiveTurn else { return }
                scrollToBottom(scrollProxy, animated: false)
            }
            .onChange(of: threadItems.last?.id) {
                scrollToBottom(scrollProxy, animated: false)
            }
            .onAppear { if scrollTarget == nil { scrollToBottom(scrollProxy, animated: false) } }
        }
    }

    private static let streamingAnchorID = "panel-streaming-anchor"

    private var visibleMessages: [PaceChatMessage] {
        chatSession.activeThreadRootID == nil
            ? Array(chatSession.visibleMessages.suffix(mainMessageLimit)) : chatSession.visibleMessages
    }

    private func reveal(_ message: PaceChatMessage) {
        if message.threadRootID == nil {
            let main = chatSession.userFacingMessages.filter { $0.threadRootID == nil }
            if let index = main.firstIndex(where: { $0.id == message.id }) {
                mainMessageLimit = max(mainMessageLimit, main.count - index)
            }
        }
        scrollTarget = message.dialogueScrollID
    }

    private func scrollToBottom(_ scrollProxy: ScrollViewProxy, animated: Bool = true) {
        guard scrollTarget == nil else { return }
        // The streaming anchor row is always present at the very bottom
        // (Color.clear when idle), so it's a stable scroll target across
        // messages, tool chips, the live bubble, and the streamed reply.
        if animated {
            if reduceMotion {
                scrollProxy.scrollTo(Self.streamingAnchorID, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: DS.Motion.micro)) {
                    scrollProxy.scrollTo(Self.streamingAnchorID, anchor: .bottom)
                }
            }
        } else {
            scrollProxy.scrollTo(Self.streamingAnchorID, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What’s on your mind?")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
            HStack(spacing: 8) {
                suggestionButton("Show me a diagram", systemImage: "square.connected.to.line.below") {
                    chatSession.submitUserMessage(
                        "Explain how transformer attention works with an interactive diagram.")
                }
                suggestionButton("What can Pace do?", systemImage: "questionmark.bubble") {
                    chatSession.submitUserMessage("What can you help me do on this Mac?")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(DS.Colors.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
        .pointerCursor()
    }

    private func artifactLink(title: String, systemName: String, actionLabel: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemName)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(actionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
        .pointerCursor()
        .accessibilityLabel("\(actionLabel): \(title)")
    }

    private var threadItems: [PaceDialogueTranscriptItem] {
        let messages = PaceChatTranscriptModel.messageRowModels(fromChatMessages: visibleMessages)
        let activities = companionManager.activitiesInCurrentChat()
        return PaceDialogueTranscriptModel.items(
            messages: messages,
            activities:
                PaceDialogueTranscriptModel.visibleActivities(activities, messages: messages),
            threadRootID: chatSession.activeThreadRootID)
    }

    private func messageRow(_ message: PaceChatTranscriptMessageRowModel, source: PaceChatMessage?) -> some View {
        PaceDialogueMessageView(
            message: message, appearance: appearance,
            powerCatalog: source?.powerCatalog,
            openPowerCategory: { category in
                guard let catalog = source?.powerCatalog else { return }
                isInputFocused = false
                powerBrowser = PacePowerBrowserLocation(catalog: catalog, category: category)
            },
            historicalPowerCount: chatSession.historicalPowerCount(for: source),
            refreshPowers: { chatSession.submitUserMessage("List powers") },
            threadActionTitle: source.flatMap { chatSession.threadActionTitle(for: $0) },
            onThreadAction: {
                guard let source else { return }
                chatSession.openThread(for: source)
            },
            canReplay: companionManager.canReplayChatSpeech,
            onReplay: companionManager.replayChatSpeech)
    }

    @ViewBuilder
    private var streamingReplyRow: some View {
        if PaceDialogueTranscriptModel.shouldShowStreamingReply(
            text: inFlightStreamedText,
            assistantEventIdentifier: companionManager.activeConversationAssistantEventIdentifier,
            committedMessages: chatSession.messages)
        {
            PaceDialogueMessageView(
                message: PaceChatTranscriptMessageRowModel(
                    id: "streaming-reply", author: .assistant,
                    bodyText: inFlightStreamedText, createdAt: .distantFuture), appearance: appearance)
        }
    }

    private var inFlightStreamedText: String {
        companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
    }

    @ViewBuilder
    private var liveUserBubbleRow: some View {
        if !liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            PaceDialogueMessageView(
                message: PaceChatTranscriptMessageRowModel(
                    id: "live-speech-draft", author: .user,
                    bodyText: liveSpeechDraft, createdAt: .distantFuture), appearance: appearance)
        }
    }

    private var liveSpeechDraft: String {
        companionManager.liveSpeechDraft
    }

    // MARK: - Input

    private var inputRow: some View {
        PaceChatComposer(
            companionManager: companionManager, chatSession: chatSession, appearance: appearance,
            focused: $isInputFocused, submit: submitDraft
        )
        .padding(.horizontal, appearance.padding())
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func submitDraft() {
        let trimmed = chatSession.draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chatSession.draftMessageText = ""
        powerBrowser = nil
        chatSession.submitUserMessage(trimmed)
        isInputFocused = true
    }

    // MARK: - Status

    private var plannerLabel: String {
        switch companionManager.activePlannerTier {
        case .local: return "local planner"
        case .appleFoundationModels: return "Apple Intelligence"
        case .cliBridge: return "CLI bridge"
        case .cliDirect: return companionManager.activePlannerTierCLIDirectUpstream.displayLabel
        case .directAPI: return "off-device model"
        }
    }

    private var boundaryHelpText: String {
        if companionManager.isOffDeviceTurnInFlight {
            return "This request is using the off-device model you enabled."
        }
        if companionManager.activePlannerTierIsOffDevice {
            return "Voice stays on your Mac. Requests use the off-device planner you selected."
        }
        return "This request is being processed on this Mac."
    }

}
