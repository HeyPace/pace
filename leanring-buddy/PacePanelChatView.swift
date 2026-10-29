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
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var chatSession: PaceChatSession
    @ObservedObject private var imageOverlayController: PaceImageOverlayController
    @ObservedObject private var diagramOverlayController: PaceDiagramOverlayController
    let isEmbeddedInLivingNotch: Bool

    @State private var showsHistory = false
    @State private var selectedQuestionIdentifier: String?
    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        companionManager: CompanionManager,
        isEmbeddedInLivingNotch: Bool = false
    ) {
        self.companionManager = companionManager
        self._chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
        self._imageOverlayController = ObservedObject(wrappedValue: companionManager.imageOverlayController)
        self._diagramOverlayController = ObservedObject(wrappedValue: companionManager.diagramOverlayController)
        self.isEmbeddedInLivingNotch = isEmbeddedInLivingNotch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsActiveSignal || companionManager.currentTurnHUDState.status == .failed {
                turnStage
            }
            if showsHistory {
                history
            } else {
                transcript
            }
            inputRow
        }
        .frame(
            width: PaceQuickPanelMetrics.width,
            height: PaceQuickPanelMetrics.height
        )
        .background(DS.Colors.surface)
        .paceRootTheme(isRoot: !isEmbeddedInLivingNotch)
        .clipShape(
            RoundedRectangle(
                cornerRadius: isEmbeddedInLivingNotch ? 0 : DS.Radius.window,
                style: .continuous
            )
        )
        .overlay {
            if isEmbeddedInLivingNotch == false {
                RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            }
        }
        .shadow(
            color: Color.black.opacity(isEmbeddedInLivingNotch ? 0 : 0.46),
            radius: isEmbeddedInLivingNotch ? 0 : 22,
            x: 0,
            y: isEmbeddedInLivingNotch ? 0 : 12
        )
        .onAppear {
            chatSession.loadHistoryWithoutBlockingInterface()
            isInputFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Text("pace")
                .font(.system(size: 14, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(showsHistory ? "History" : "Quick chat")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
            Spacer()
            if selectedQuestionIdentifier != nil && !showsHistory {
                iconButton(systemName: "arrow.uturn.backward", help: "Return to latest conversation") {
                    selectedQuestionIdentifier = nil
                }
            }
            if companionManager.isOffDeviceTurnInFlight {
                Text("\(plannerLabel) ↗")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.offDeviceSignal)
                    .help(boundaryHelpText)
            }
            iconButton(
                systemName: showsHistory ? "bubble.left" : "clock.arrow.circlepath",
                help: showsHistory ? "Return to conversation" : "Conversation history"
            ) {
                showsHistory.toggle()
            }
            iconButton(systemName: "gearshape", help: "Open Pace settings") {
                PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            }
            .keyboardShortcut(",", modifiers: [.command])
            iconButton(systemName: "xmark", help: "Close conversation") {
                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.6)).frame(height: 0.5)
        }
    }

    private var turnStage: some View {
        HStack(spacing: 8) {
            if showsActiveSignal {
                PaceSignalView(
                    state: signalState,
                    isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                    audioPowerLevel: companionManager.currentAudioPowerLevel,
                    lineCount: 1,
                    colorRoleOverride: companionManager.nativeEffectiveSignalColorRoleOverride
                )
                .frame(width: 24, height: 14)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(DS.Colors.failure)
            }
            Text(currentTurnDetail ?? signalPresentation.label)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if companionManager.currentTurnHUDState.status == .failed {
                Button("Details") {
                    PaceSettingsWindowManager.shared.show(companionManager: companionManager, destination: .doctor)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .pointerCursor()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(signalPresentation.accessibilityValue)
    }

    private var showsActiveSignal: Bool {
        switch signalState {
        case .listening, .understanding, .awaitingApproval, .acting, .speaking:
            return true
        case .ready, .completed, .blocked, .failed:
            return false
        }
    }

    private func iconButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: 6)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                // The panel transcript is deliberately bounded by PaceChatSession.
                // A regular stack keeps the accessibility tree stable while a
                // response is replaced or queued rows are completed; SwiftUI's
                // lazy-layout accessibility bridge can otherwise traverse a
                // changing ForEach from a non-main update group and trap.
                VStack(alignment: .leading, spacing: 18) {
                    if visibleMessages.isEmpty && liveSpeechDraft.isEmpty && inFlightStreamedText.isEmpty {
                        emptyState.padding(.top, 24)
                    } else {
                        ForEach(threadItems) { item in
                            switch item {
                            case .message(let message):
                                messageRow(message).id(item.id)
                            case .tool(let actionRecord):
                                toolChipRow(actionRecord).id(item.id)
                            }
                        }
                    }
                    if selectedQuestionIdentifier == nil, let imageStatus = imageOverlayController.statusText {
                        artifactLink(title: imageStatus, systemName: "photo", actionLabel: "Open image") {
                            imageOverlayController.show()
                        }
                    }
                    if selectedQuestionIdentifier == nil, let document = diagramOverlayController.document {
                        artifactLink(
                            title: document.title,
                            systemName: document.figure == nil ? "point.3.connected.trianglepath.dotted" : "cube",
                            actionLabel: "Open diagram"
                        ) {
                            NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
                        }
                    }
                    if selectedQuestionIdentifier == nil {
                        liveUserBubbleRow
                        streamingReplyRow
                    }
                    Color.clear.frame(height: 0).id(Self.streamingAnchorID)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [DS.Colors.surface, DS.Colors.surface.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: chatSession.messages.count) {
                scrollToBottom(scrollProxy)
            }
            .onChange(of: inFlightStreamedText) {
                scrollToBottom(scrollProxy)
            }
            .onChange(of: liveSpeechDraft) {
                scrollToBottom(scrollProxy)
            }
            .onChange(of: companionManager.recentActionResults.count) {
                scrollToBottom(scrollProxy)
            }
            .onAppear { scrollToBottom(scrollProxy, animated: false) }
        }
    }

    private static let streamingAnchorID = "panel-streaming-anchor"

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if chatSession.userFacingMessages.filter({ $0.role == .user }).isEmpty {
                    Text("Your conversations will appear here.")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.vertical, 24)
                }
                ForEach(chatSession.userFacingMessages.filter { $0.role == .user }.reversed()) { message in
                    Button {
                        selectedQuestionIdentifier = message.id
                        showsHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.body)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(message.createdAt, style: .date)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: 7)
                    .pointerCursor()
                    Divider().overlay(DS.Colors.borderSubtle).padding(.horizontal, 12)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleMessages: [PaceChatMessage] {
        PaceChatTranscriptModel.quickPanelMessages(
            chatSession.userFacingMessages, selectedQuestionIdentifier: selectedQuestionIdentifier)
    }

    private func scrollToBottom(_ scrollProxy: ScrollViewProxy, animated: Bool = true) {
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
            Text("AT YOUR PACE")
                .font(DS.Typography.metadata)
                .tracking(1.5)
                .foregroundStyle(DS.Colors.textTertiary)
            Text("What’s on your mind?")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Ask a question, explore an idea, or make something.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.textSecondary)
            HStack(spacing: 8) {
                suggestionButton("Show me a diagram", systemImage: "point.3.connected.trianglepath.dotted") {
                    chatSession.submitUserMessage(
                        "Explain how transformer attention works with an interactive diagram.")
                }
                suggestionButton("What can Pace do?", systemImage: "arrow.up.right") {
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
                .background(DS.Colors.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: 9)
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
        .paceControlHoverHighlight(cornerRadius: 6)
        .pointerCursor()
        .accessibilityLabel("\(actionLabel): \(title)")
    }

    /// A single item in the conversation timeline — either a chat message or
    /// a tool-use event — so tool use renders inline, in order, in the same
    /// thread (not a separate dashboard).
    private enum ThreadItem: Identifiable {
        case message(PaceChatMessage)
        case tool(PaceActionRunRecord)

        var id: String {
            switch self {
            case .message(let message): return "msg-\(message.id)"
            case .tool(let actionRecord): return "tool-\(actionRecord.id)"
            }
        }

        var sortDate: Date {
            switch self {
            case .message(let message): return message.createdAt
            case .tool(let actionRecord): return actionRecord.createdAt
            }
        }
    }

    /// Chat messages + recent tool-use outcomes, merged by time. Only
    /// completed/failed actions become chips (skip the transient "planned"
    /// record so each tool use shows once, as its result).
    private var threadItems: [ThreadItem] {
        let messageItems = visibleMessages.map(ThreadItem.message)
        let toolItems = companionManager.recentActionResults
            .filter {
                ($0.status == .completed || $0.status == .failed)
                    && selectedQuestionIdentifier == nil
                    && $0.createdAt >= (visibleMessages.first?.createdAt ?? Date())
            }
            .map(ThreadItem.tool)
        return (messageItems + toolItems).sorted { $0.sortDate < $1.sortDate }
    }

    /// An inline tool-use chip — a subtle centered capsule that reads as a
    /// system event in the conversation ("opened Hacker News").
    private func toolChipRow(_ actionRecord: PaceActionRunRecord) -> some View {
        let didFail = actionRecord.status == .failed
        let chipText = actionRecord.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? actionRecord.title
            : actionRecord.detail
        return VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: didFail ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                    .font(.system(size: 9, weight: .semibold))
                Text(chipText)
                    .font(DS.Typography.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if didFail {
                Button("open help & diagnostics") {
                    PaceSettingsWindowManager.shared.show(
                        companionManager: companionManager,
                        destination: .doctor
                    )
                }
                .buttonStyle(.plain)
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.Colors.localSignal)
                .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                .pointerCursor()
            }
        }
        .foregroundColor(didFail ? DS.Colors.failure : DS.Colors.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Colors.surfaceRaised)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func messageRow(_ message: PaceChatMessage) -> some View {
        let isFromUser = message.role == .user
        return Text(readableMessage(message.body))
            .font(.system(size: isFromUser ? 17 : 14, weight: isFromUser ? .medium : .regular))
            .tracking(isFromUser ? -0.3 : 0)
            .lineSpacing(isFromUser ? 4 : 6)
            .foregroundStyle(isFromUser ? DS.Colors.textPrimary : DS.Colors.textPrimary.opacity(0.9))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, isFromUser && message.id != visibleMessages.first?.id ? 16 : 0)
    }

    private func readableMessage(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder
    private var streamingReplyRow: some View {
        if !inFlightStreamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(readableMessage(inFlightStreamedText))
                .font(.system(size: 14))
                .lineSpacing(6)
                .foregroundStyle(DS.Colors.textPrimary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var inFlightStreamedText: String {
        companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
    }

    @ViewBuilder
    private var liveUserBubbleRow: some View {
        if !liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(liveSpeechDraft)
                .font(.system(size: 17, weight: .medium))
                .lineSpacing(4)
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveSpeechDraft: String {
        companionManager.liveSpeechDraft
    }

    // MARK: - Input

    private var inputRow: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Pace…", text: $chatSession.draftMessageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .onSubmit(submitDraft)
                    .accessibilityLabel("Message Pace")
                    .padding(.vertical, 5)
                iconButton(
                    systemName: companionManager.voiceState == .listening ? "mic.fill" : "mic",
                    help: companionManager.allPermissionsGranted
                        ? (companionManager.voiceState == .listening ? "Finish recording" : "Speak to Pace")
                        : "Set up voice"
                ) {
                    if companionManager.allPermissionsGranted {
                        if companionManager.voiceState == .listening {
                            companionManager.handleStopButtonTapped()
                        } else {
                            companionManager.beginListeningFromDeepLink()
                        }
                    } else {
                        openVoiceSetup()
                    }
                }
                if companionManager.voiceState != .idle {
                    Button {
                        companionManager.cancelCurrentTurnFromPanel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: 6)
                    .pointerCursor()
                    .keyboardShortcut(.escape, modifiers: [.command])
                    .accessibilityLabel("Stop current request")
                    .help("Stop after the current completed action")
                }
                Button(action: submitDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isDraftEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 6, isEnabled: !isDraftEmpty)
                .pointerCursor(isEnabled: !isDraftEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isDraftEmpty)
                .accessibilityLabel(companionManager.voiceState == .idle ? "Send message" : "Queue message")
                .help(companionManager.voiceState == .idle ? "Send message" : "Add message to queue")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DS.Colors.background.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isInputFocused ? DS.Colors.textSecondary.opacity(0.45) : DS.Colors.borderSubtle, lineWidth: 0.7)
            }
            HStack(spacing: 5) {
                if companionManager.allPermissionsGranted {
                    Text("Hold ⌃⌥ to speak")
                } else {
                    Button("Set up voice") { openVoiceSetup() }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .paceControlHoverHighlight(cornerRadius: 3)
                        .pointerCursor()
                    Text("· Typing is ready")
                }
                Spacer()
                Text("↵ Send")
            }
            .font(.system(size: 10))
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.horizontal, 3)

            if companionManager.queuedChatTurnCount > 0 {
                HStack(spacing: 8) {
                    Text(
                        companionManager.queuedChatTurnCount == 1
                            ? "1 message queued" : "\(companionManager.queuedChatTurnCount) messages queued")
                    Spacer()
                    Button("Clear") { companionManager.clearQueuedChatTurns() }
                        .buttonStyle(.plain)
                        .paceControlHoverHighlight(cornerRadius: 4)
                        .pointerCursor()
                }
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    private func openVoiceSetup() {
        PaceSettingsWindowManager.shared.show(companionManager: companionManager, destination: .permissions)
    }

    private var isDraftEmpty: Bool {
        chatSession.draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitDraft() {
        let trimmed = chatSession.draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedQuestionIdentifier = nil
        showsHistory = false
        chatSession.submitUserMessage(trimmed)
        chatSession.draftMessageText = ""
        isInputFocused = true
    }

    // MARK: - Status

    private var signalState: PaceSignalState {
        companionManager.nativeEffectiveSignalState
    }

    private var signalPresentation: PaceSignalPresentation {
        PaceSignalPresentation.resolve(
            state: signalState,
            isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
            reduceMotion: reduceMotion
        )
    }

    private var signalColorRole: PaceSignalColorRole {
        companionManager.nativeEffectiveSignalColorRoleOverride
            ?? signalPresentation.colorRole
    }

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

    private var currentTurnDetail: String? {
        if !liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveSpeechDraft
        }
        if companionManager.currentTurnHUDState.status != .idle {
            return companionManager.currentTurnHUDState.detail
        }
        if companionManager.allPermissionsGranted == false {
            return "Finish setup for voice and screen-aware actions"
        }
        return nil
    }
}
