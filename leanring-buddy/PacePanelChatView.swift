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

import SwiftUI

struct PacePanelChatView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var chatSession: PaceChatSession
    let isEmbeddedInLivingNotch: Bool

    @FocusState private var isInputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        companionManager: CompanionManager,
        isEmbeddedInLivingNotch: Bool = false
    ) {
        self.companionManager = companionManager
        self._chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
        self.isEmbeddedInLivingNotch = isEmbeddedInLivingNotch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmbeddedInLivingNotch == false {
                header
            }
            turnStage
            if shouldShowCompactPermissionRecovery {
                compactPermissionRecoveryBanner
            }
            transcript
            inputRow
        }
        .frame(
            width: PaceQuickPanelMetrics.width,
            height: PaceQuickPanelMetrics.height
        )
        .background(DS.Colors.surface)
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
        HStack(spacing: 8) {
            Circle()
                .fill(signalColorRole.color)
                .frame(width: 7, height: 7)
                .shadow(color: signalColorRole.color.opacity(0.5), radius: 5, x: 0, y: 2)
            Text("Pace")
                .font(DS.Typography.bodyStrong)
                .foregroundColor(DS.Colors.textPrimary)

            Text(companionManager.isOffDeviceTurnInFlight ? "Off-device" : "On this Mac")
                .font(DS.Typography.captionStrong)
                .foregroundColor(signalColorRole.color)
                .help(boundaryHelpText)

            Spacer()

            iconButton(systemName: "gearshape", help: "Open Pace settings") {
                PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            }
            .keyboardShortcut(",", modifiers: [.command])
            iconButton(systemName: "xmark", help: "Close") {
                NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var turnStage: some View {
        VStack(alignment: .leading, spacing: signalState == .ready ? 6 : 9) {
            HStack {
                Text(signalPresentation.label)
                    .font(DS.Typography.sectionTitle)
                    .foregroundStyle(DS.Colors.textPrimary)

                Spacer()

                if companionManager.allPermissionsGranted {
                    Text(turnStageMetadata)
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(signalColorRole.color)
                }
            }

            if showsActiveSignal {
                PaceSignalView(
                    state: signalState,
                    isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                    audioPowerLevel: companionManager.currentAudioPowerLevel,
                    lineCount: 1,
                    colorRoleOverride: companionManager.nativeEffectiveSignalColorRoleOverride
                )
                .frame(height: 20)
            }

            if companionManager.allPermissionsGranted,
               let currentTurnDetail {
                Text(currentTurnDetail)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, signalState == .ready ? 8 : 10)
        .background(DS.Colors.surfaceInset.opacity(0.72))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(signalPresentation.accessibilityValue)
        .accessibilityValue(currentTurnDetail ?? "")
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(DS.Colors.surfaceRaised))
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: 15)
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
                VStack(alignment: .leading, spacing: 8) {
                    if shouldShowPermissionRecoveryState {
                        permissionRecoveryState.padding(.top, 24)
                    } else if companionManager.nativePanelPresentation.showsEmptyState {
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
                    liveUserBubbleRow
                    streamingReplyRow.id(Self.streamingAnchorID)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [DS.Colors.surfaceInset, DS.Colors.surfaceInset.opacity(0)],
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

    private var shouldShowPermissionRecoveryState: Bool {
        companionManager.allPermissionsGranted == false
            && threadItems.isEmpty
            && liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inFlightStreamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowCompactPermissionRecovery: Bool {
        companionManager.allPermissionsGranted == false
            && shouldShowPermissionRecoveryState == false
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
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text("Hold ⌃⌥ and speak naturally")
                    .font(DS.Typography.bodyStrong)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("or start with one useful request")
                    .font(DS.Typography.callout)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Button("Show what I can automate") {
                chatSession.submitUserMessage("What can you help me automate on this Mac?")
            }
            .buttonStyle(.plain)
            .font(DS.Typography.captionStrong)
            .foregroundStyle(DS.Colors.localSignal)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity)
    }

    private var permissionRecoveryState: some View {
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text("Finish Pace setup")
                    .font(DS.Typography.bodyStrong)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Voice and screen-aware actions need the remaining macOS permissions. You can still type below.")
                    .font(DS.Typography.callout)
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button("Open Permissions") {
                PaceSettingsWindowManager.shared.show(
                    companionManager: companionManager,
                    destination: .permissions
                )
            }
            .buttonStyle(.plain)
            .font(DS.Typography.captionStrong)
            .foregroundStyle(DS.Colors.localSignal)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity)
    }

    private var compactPermissionRecoveryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Colors.localSignal)

            Text("Voice and screen features need permission")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.Colors.textSecondary)

            Spacer(minLength: 8)

            Button("Open Permissions") {
                PaceSettingsWindowManager.shared.show(
                    companionManager: companionManager,
                    destination: .permissions
                )
            }
            .buttonStyle(.plain)
            .font(DS.Typography.captionStrong)
            .foregroundStyle(DS.Colors.textOnAccent)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(DS.Colors.localSignal)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(DS.Colors.surfaceRaised.opacity(0.72))
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
        let messageItems = chatSession.userFacingMessages.map(ThreadItem.message)
        let toolItems = companionManager.recentActionResults
            .filter { $0.status == .completed || $0.status == .failed }
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
                Button("Open Help & Diagnostics") {
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
        return HStack {
            if isFromUser { Spacer(minLength: 32) }
            Text(message.body)
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFromUser ? DS.Colors.localSignal.opacity(0.20) : DS.Colors.surfaceRaised)
                )
                .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
            if !isFromUser { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private var streamingReplyRow: some View {
        if !inFlightStreamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text(inFlightStreamedText)
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Colors.surfaceRaised)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 32)
            }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private var inFlightStreamedText: String {
        companionManager.streamingSentenceTTSPipeline.inFlightStreamedText
    }

    /// The user's words as they speak — a right-aligned in-progress bubble
    /// that fills in live during listening, then is replaced by the committed
    /// message when the turn lands. Slightly more saturated than a committed
    /// user bubble to read as "in progress".
    @ViewBuilder
    private var liveUserBubbleRow: some View {
        if !liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Spacer(minLength: 32)
                Text(liveSpeechDraft)
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Colors.localSignal.opacity(0.28))
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var liveSpeechDraft: String {
        companionManager.liveSpeechDraft
    }

    // MARK: - Input

    private var inputRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Message Pace…", text: $chatSession.draftMessageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1...3)
                    .focused($isInputFocused)
                    .onSubmit(submitDraft)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Colors.surfaceInset)
                            .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        isInputFocused
                                            ? DS.Colors.localSignal.opacity(0.82)
                                            : DS.Colors.borderSubtle,
                                        lineWidth: isInputFocused ? 1.2 : 0.7
                                    )
                            )
                    )

                Button(action: submitDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(isDraftEmpty ? DS.Colors.textTertiary : DS.Colors.localSignal)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 15, isEnabled: !isDraftEmpty)
                .pointerCursor(isEnabled: !isDraftEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isDraftEmpty)
                .accessibilityLabel(
                    companionManager.voiceState == .idle
                        ? "Send message"
                        : "Queue message"
                )
                .help(
                    companionManager.voiceState == .idle
                        ? "Send message"
                        : "Add message to queue"
                )

                if companionManager.voiceState != .idle {
                    Button {
                        companionManager.cancelCurrentTurnFromPanel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: 15)
                    .pointerCursor()
                    .keyboardShortcut(.escape, modifiers: [.command])
                    .accessibilityLabel("Stop current request")
                    .help("Stop after the current completed action")
                }
            }

            if companionManager.queuedChatTurnCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.localSignal)
                    Text(
                        companionManager.queuedChatTurnCount == 1
                            ? "1 message queued"
                            : "\(companionManager.queuedChatTurnCount) messages queued"
                    )
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    Spacer(minLength: 8)
                    Button("Clear") {
                        companionManager.clearQueuedChatTurns()
                    }
                    .buttonStyle(.plain)
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .paceControlHoverHighlight(cornerRadius: 6)
                    .pointerCursor()
                    .accessibilityLabel("Clear queued messages")
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var isDraftEmpty: Bool {
        chatSession.draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitDraft() {
        let trimmed = chatSession.draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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

    private var turnStageMetadata: String {
        if companionManager.isOffDeviceTurnInFlight {
            return "Using enabled off-device model"
        }
        return signalState == .ready ? "⌃⌥ to speak" : "Stays on this Mac"
    }

    private var boundaryHelpText: String {
        companionManager.isOffDeviceTurnInFlight
            ? "This request is using the off-device model you enabled."
            : "This request is being processed on this Mac."
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
