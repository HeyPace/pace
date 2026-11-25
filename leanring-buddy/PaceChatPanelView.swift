//
//  PaceChatPanelView.swift
//  leanring-buddy
//
//  Phase 1 of the premium chat panel (PRD: docs/prds/premium-chat-panel.md):
//  a Claude-Desktop-style conversation column — header strip (voice state +
//  gear), transcript with inline tool-activity rows, morning-brief and
//  meeting cards as inline transcript cards, and a permanently docked input.
//
//  Flag-gated: `MenuBarPanelManager` renders this view ONLY when the
//  `useChatPanelAsPrimarySurface` preference is ON (default OFF in phase 1).
//  Flag OFF keeps the shipped `PacePanelChatView` surface byte-identical.
//
//  Backed entirely by EXISTING state — `PaceChatSession` (the shared
//  voice+chat transcript fed by `recordConversationTurn`),
//  `recentActionResults` (the published `PaceActionExecutionObservation`
//  flow), `liveSpeechDraft`, and `inFlightStreamedText`. Every rendering
//  decision that can be pure lives in `PaceChatTranscriptModel`; this file
//  only draws.
//

import SaaSMakerUI
import SwiftUI

struct PaceChatPanelView: View {
    @ObservedObject private var appearanceStore = PaceChatAppearanceStore.shared
    private var appearance: PaceChatAppearance { appearanceStore.appearance }

    @ObservedObject var companionManager: CompanionManager
    // Observed separately: these are their own ObservableObjects, and
    // changes to their @Published state do NOT flow through
    // `companionManager.objectWillChange` — observing only the manager
    // would miss new chat messages and streaming-reply ticks.
    @ObservedObject private var chatSession: PaceChatSession
    @ObservedObject private var streamingSentenceTTSPipeline: StreamingSentenceTTSPipeline
    @ObservedObject private var morningTriageScheduler: PaceMorningTriageScheduler
    @ObservedObject private var meetingController = PaceMeetingModeController.shared

    /// Auto-scroll is the panel's only recurring motion; when the user
    /// has macOS Reduce Motion on, the transcript still follows the
    /// conversation but snaps instead of animating.
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotionIsEnabled

    @FocusState private var isChatInputFocused: Bool

    private let contentSize: CGSize?
    private let composerFocusRequestID: UUID?

    init(companionManager: CompanionManager, contentSize: CGSize? = nil, composerFocusRequestID: UUID?) {
        self.contentSize = contentSize
        self.composerFocusRequestID = composerFocusRequestID
        _companionManager = ObservedObject(wrappedValue: companionManager)
        _chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
        _streamingSentenceTTSPipeline = ObservedObject(
            wrappedValue: companionManager.streamingSentenceTTSPipeline
        )
        _morningTriageScheduler = ObservedObject(
            wrappedValue: companionManager.morningTriageScheduler
        )
    }

    @State private var powerBrowser: PacePowerBrowserLocation?
    @State private var scrollTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            PaceDialogueCurrentStatusView(companionManager: companionManager)
                .padding(.horizontal, appearance.padding())
            PaceThreadLocationBar(session: chatSession) { scrollTarget = $0.dialogueScrollID }
                .padding(.horizontal, appearance.padding(existing: 14))
            transcriptColumn
                .opacity(powerBrowser == nil ? 1 : 0)
                .accessibilityHidden(powerBrowser != nil)
                .disabled(powerBrowser != nil)
                .allowsHitTesting(powerBrowser == nil)
                .overlay {
                    if let powerBrowser {
                        PaceCurrentPowerBrowser(
                            location: powerBrowser, companionManager: companionManager,
                            returnTitle: chatSession.activeThreadRootID == nil ? "Main chat" : "Replies",
                            goBack: {
                                self.powerBrowser = nil
                                isChatInputFocused = true
                            },
                            useConnection: { connection in
                                chatSession.prepareDraft(using: connection)
                                self.powerBrowser = nil
                                isChatInputFocused = true
                            },
                            useExample: { example in
                                chatSession.insertPowerExample(example)
                                self.powerBrowser = nil
                                isChatInputFocused = true
                            },
                            performAction: { entry, action in
                                self.powerBrowser = nil
                                companionManager.submitChatPowerCatalogAction(action, entry: entry)
                            }
                        )
                    }
                }
            dockedInputRow
        }
        .frame(width: contentSize?.width ?? 320, height: contentSize?.height ?? 460)
        .background(panelBackground)
        .smTheme(DS.palette)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
        .onChange(of: chatSession.activeThreadRootID) { powerBrowser = nil }
        .onAppear {
            // Re-pull persisted history so turns recorded before this
            // panel first opened (or while it was closed) are present.
            // `loadHistory()` is idempotent — it replaces the rendered
            // transcript wholesale from the same `paceHistory` store
            // `recordConversationTurn` writes to.
            chatSession.loadHistory()
            isChatInputFocused = powerBrowser == nil && composerFocusRequestID != nil
        }
        .onChange(of: composerFocusRequestID) { _, composerFocusRequestID in
            isChatInputFocused = powerBrowser == nil && composerFocusRequestID != nil
        }
    }

    private var panelBackground: some View {
        DS.Colors.background
    }

    // MARK: - Header strip
    //
    // PRD contract: mic/live state on the left (reuses `voiceState`),
    // gear on the right opening the existing settings window. Nothing
    // else — every dashboard section moved behind the gear.

    private var headerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: voiceStateSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(voiceStateColor)
                .frame(width: 16)

            Text(voiceStateDisplayText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
            if companionManager.isOffDeviceTurnInFlight {
                Label("Off-device", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(DS.Colors.offDeviceSignal)
            }

            Spacer()
            if powerBrowser == nil {
                PacePowerSearchButton {
                    isChatInputFocused = false
                    powerBrowser = PacePowerBrowserLocation(catalog: nil, category: nil)
                }
            }
            PaceChatOptionsMenu(companionManager: companionManager)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var voiceStateSymbolName: String {
        switch companionManager.voiceState {
        case .idle:
            return "mic"
        case .listening:
            return "waveform"
        case .processing:
            return "hourglass"
        case .responding:
            return "speaker.wave.2.fill"
        }
    }

    private var voiceStateColor: Color {
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .responding:
            return DS.Colors.accent
        case .processing:
            return DS.Colors.warning
        }
    }

    private var voiceStateDisplayText: String {
        switch companionManager.voiceState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

    // MARK: - Transcript column

    /// Stable scroll target pinned after the last row so auto-scroll has
    /// one anchor across messages, tool rows, inline cards, the live
    /// speech bubble, and the streaming reply.
    private static let transcriptBottomAnchorId = "chat-panel-bottom-anchor"

    private var transcriptColumn: some View {
        ScrollViewReader { scrollProxy in
            let sources = Dictionary(uniqueKeysWithValues: chatSession.visibleMessages.map { ("message-" + $0.id, $0) })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if shouldShowEmptyTranscriptState {
                        emptyTranscriptState
                            .padding(.top, 48)
                    } else {
                        ForEach(threadRows) { threadRow in
                            switch threadRow {
                            case .message(let messageRowModel):
                                messageBubbleRow(messageRowModel, source: sources[messageRowModel.id]).id(threadRow.id)
                            case .activity(let activity):
                                PaceDialogueActivityView(activity: activity) {
                                    PaceSettingsWindowManager.shared.show(
                                        companionManager: companionManager, destination: .doctor)
                                }
                            }
                        }
                    }
                    if chatSession.activeThreadRootID == nil {
                        companionObservationInlineCard
                        morningBriefInlineCard
                        meetingInlineCard
                    }
                    if companionManager.isViewingLiveTurn {
                        liveSpeechDraftBubbleRow
                        streamingReplyBubbleRow
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomAnchorId)
                }
                .padding(appearance.padding(existing: 14))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: scrollTarget) {
                guard let scrollTarget else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollProxy.scrollTo(scrollTarget, anchor: .center)
                self.scrollTarget = nil
            }
            .onChange(of: chatSession.visibleMessages.last?.id) {
                if scrollTarget == nil { scrollTranscriptToBottom(scrollProxy) }
            }
            .onChange(of: composerFocusRequestID) { _, composerFocusRequestID in
                guard composerFocusRequestID != nil else { return }
                scrollTranscriptToBottom(scrollProxy, isAnimated: false)
            }
            .onChange(of: streamingSentenceTTSPipeline.inFlightStreamedText) {
                guard companionManager.isViewingLiveTurn else { return }
                scrollTranscriptToBottom(scrollProxy)
            }
            .onChange(of: companionManager.liveSpeechDraft) {
                guard companionManager.isViewingLiveTurn else { return }
                scrollTranscriptToBottom(scrollProxy)
            }
            .onChange(of: threadRows.last?.id) {
                scrollTranscriptToBottom(scrollProxy)
            }
            .onAppear {
                scrollTranscriptToBottom(scrollProxy, isAnimated: false)
            }
        }
    }

    /// Merged conversation timeline. All merge/sort/state decisions live
    /// in the pure `PaceChatTranscriptModel` layer (unit-tested there).
    private var threadRows: [PaceDialogueTranscriptItem] {
        PaceDialogueTranscriptModel.items(
            messages: PaceChatTranscriptModel.messageRowModels(
                fromChatMessages: chatSession.visibleMessages
            ),
            activities: companionManager.activitiesInCurrentChat(), threadRootID: chatSession.activeThreadRootID
        )
    }

    private var shouldShowEmptyTranscriptState: Bool {
        PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: threadRows.count,
            liveSpeechDraftText: companionManager.liveSpeechDraft,
            inFlightStreamedReplyText: streamingSentenceTTSPipeline.inFlightStreamedText
        ) && !hasInlineEventCards
    }

    /// Inline event cards (morning brief / meeting) render even when the
    /// chat thread itself is empty, so the empty state must yield to them.
    private var hasInlineEventCards: Bool {
        companionManager.pendingCompanionObservationCard != nil
            || morningTriageScheduler.pendingMorningBriefCard != nil
            || meetingController.state != .inactive
            || meetingController.lastMeetingNotes != nil
    }

    private func scrollTranscriptToBottom(
        _ scrollProxy: ScrollViewProxy,
        isAnimated: Bool = true
    ) {
        guard scrollTarget == nil else { return }
        if isAnimated && !accessibilityReduceMotionIsEnabled {
            withAnimation(.easeOut(duration: 0.18)) {
                scrollProxy.scrollTo(Self.transcriptBottomAnchorId, anchor: .bottom)
            }
        } else {
            scrollProxy.scrollTo(Self.transcriptBottomAnchorId, anchor: .bottom)
        }
    }

    private var emptyTranscriptState: some View {
        Text("What’s on your mind?")
            .font(appearance.font(size: 15, weight: .medium))
            .foregroundStyle(DS.Colors.textSecondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Message bubbles

    private func messageBubbleRow(_ message: PaceChatTranscriptMessageRowModel, source: PaceChatMessage?) -> some View {
        PaceDialogueMessageView(
            message: message, appearance: appearance,
            powerCatalog: source?.powerCatalog,
            openPowerCategory: { category in
                guard let catalog = source?.powerCatalog else { return }
                isChatInputFocused = false
                powerBrowser = PacePowerBrowserLocation(catalog: catalog, category: category)
            },
            historicalPowerCount: chatSession.historicalPowerCount(for: source),
            refreshPowers: {
                isChatInputFocused = false
                powerBrowser = PacePowerBrowserLocation(catalog: nil, category: nil)
            },
            threadReplyCount: source.flatMap { chatSession.threadReplyCount(for: $0) },
            onThreadAction: {
                guard let source else { return }
                chatSession.openThread(for: source)
            },
            canReplay: companionManager.canReplayChatSpeech,
            onReplay: companionManager.replayChatSpeech)
    }

    @ViewBuilder
    private var liveSpeechDraftBubbleRow: some View {
        if !companionManager.liveSpeechDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            PaceDialogueMessageView(
                message: PaceChatTranscriptMessageRowModel(
                    id: "live-speech-draft", author: .user,
                    bodyText: companionManager.liveSpeechDraft, createdAt: .distantFuture), appearance: appearance)
        }
    }

    @ViewBuilder
    private var streamingReplyBubbleRow: some View {
        let streamingText = streamingSentenceTTSPipeline.inFlightStreamedText
        if PaceDialogueTranscriptModel.shouldShowStreamingReply(
            text: streamingText,
            assistantEventIdentifier: companionManager.activeConversationAssistantEventIdentifier,
            committedMessages: chatSession.messages)
        {
            PaceDialogueMessageView(
                message: PaceChatTranscriptMessageRowModel(
                    id: "streaming-reply", author: .assistant,
                    bodyText: streamingText, createdAt: .distantFuture), appearance: appearance)
        }
    }

    // MARK: - Companion observation inline card

    @ViewBuilder
    private var companionObservationInlineCard: some View {
        if let content = companionManager.pendingCompanionObservationCard {
            PaceCompanionObservationCardView(
                content: content,
                dismiss: companionManager.dismissCompanionObservationCard
            )
        }
    }

    // MARK: - Morning brief inline card
    //
    // PRD item 5: the morning brief is an event in the conversation, not
    // a permanent dashboard fixture — it renders as an inline transcript
    // card only while a brief is parked and waiting.

    @ViewBuilder
    private var morningBriefInlineCard: some View {
        if let pendingMorningBriefCard = morningTriageScheduler.pendingMorningBriefCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Morning brief")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer(minLength: 0)

                    Button(action: {
                        companionManager.playPendingMorningBrief()
                    }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                    .accessibilityLabel("Play morning brief")
                    .help("Speak the brief now")

                    Button(action: {
                        morningTriageScheduler.dismissPendingCard()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                    .accessibilityLabel("Dismiss morning brief")
                    .help("Dismiss morning brief")
                }

                Text(pendingMorningBriefCard)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
        }
    }

    // MARK: - Meeting inline card
    //
    // PRD item 5: meeting capture/notes render as inline transcript
    // cards when they occur. Reuses the same `PaceMeetingModeController`
    // state the dashboard card read — no new execution paths.

    @ViewBuilder
    private var meetingInlineCard: some View {
        if case .failed(let failureMessage) = meetingController.state {
            meetingFailedInlineCard(failureMessage: failureMessage)
        } else if meetingController.state != .inactive {
            meetingActiveInlineCard
        } else if let meetingNotes = meetingController.lastMeetingNotes {
            meetingNotesResultInlineCard(meetingNotes: meetingNotes)
        }
    }

    private var meetingActiveInlineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(meetingStateLabel(for: meetingController.state).lowercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer(minLength: 0)

                Text(elapsedTimeString(meetingController.captureDurationSeconds))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .monospacedDigit()
            }

            // RMS meter — reuses the live detectedSpeechLevel.
            ProgressView(value: Double(meetingController.detectedSpeechLevel), total: 1.0)
                .progressViewStyle(.linear)
                .tint(DS.Colors.accent)
                .frame(height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func meetingNotesResultInlineCard(meetingNotes: PaceMeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(meetingNotes.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingNotes.transcript, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Copy transcript")
            }

            if meetingNotes.synthesisFailed {
                Text("Notes synthesis failed — transcript saved.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !meetingNotes.summary.isEmpty {
                Text(meetingNotes.summary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !meetingNotes.actionItems.isEmpty {
                Text("action items:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 4)
                ForEach(Array(meetingNotes.actionItems.enumerated()), id: \.offset) { _, actionItem in
                    Text("• \(actionItem.text)\(actionItem.owner.map { " — \($0)" } ?? "")")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !meetingNotes.decisions.isEmpty {
                Text("decisions:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 4)
                ForEach(Array(meetingNotes.decisions.enumerated()), id: \.offset) { _, decision in
                    Text("• \(decision)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func meetingFailedInlineCard(failureMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("meeting failed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text(failureMessage)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func meetingStateLabel(for meetingModeState: PaceMeetingModeState) -> String {
        switch meetingModeState {
        case .inactive:
            return "Meeting"
        case .starting:
            return "Starting meeting…"
        case .active:
            return "Recording meeting"
        case .transcribing:
            return "Transcribing…"
        case .synthesizing:
            return "Writing notes…"
        case .failed:
            return "Meeting failed"
        }
    }

    private func elapsedTimeString(_ elapsedSeconds: TimeInterval) -> String {
        let minutes = Int(elapsedSeconds) / 60
        let seconds = Int(elapsedSeconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Docked input

    private var dockedInputRow: some View {
        PaceChatComposer(
            companionManager: companionManager, chatSession: chatSession, appearance: appearance,
            focused: $isChatInputFocused, submit: submitDraftMessageText
        )
        .padding(.horizontal, appearance.padding(existing: 12))
        .padding(.vertical, 8)
    }

    /// Submits through `PaceChatSession.submitUserMessage`, which appends
    /// the optimistic user row and forwards into the SAME pipeline as
    /// voice (`CompanionManager.submitChatTranscriptFromChatSession`) —
    /// same intent classification, approval policy, and memory writes.
    private func submitDraftMessageText() {
        let trimmedDraftMessageText = chatSession.draftMessageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraftMessageText.isEmpty else { return }
        chatSession.draftMessageText = ""
        powerBrowser = nil
        chatSession.submitUserMessage(trimmedDraftMessageText)
        isChatInputFocused = true
    }
}
