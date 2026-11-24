import AppKit
import SwiftUI

struct PaceDialogueMessageView: View {
    let message: PaceChatTranscriptMessageRowModel
    let appearance: PaceChatAppearance
    var threadActionTitle: String? = nil
    var onThreadAction: () -> Void = {}
    var canReplay = false
    var onReplay: (PaceSpeechRequest) -> Void = { _ in }
    @State private var showsJapaneseOriginal = false
    @State private var showsOriginalResponse = false
    @State private var generatedImagePreview: NSImage?

    private var isFromUser: Bool { message.author == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isFromUser { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 8) {
                if !isFromUser {
                    Text("Pace")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                Text(readableMessage(message.bodyText))
                    .font(appearance.font(size: isFromUser ? 13 : 14))
                    .lineSpacing(appearance.lineSpacing(existing: isFromUser ? 3 : 5))
                    .foregroundStyle(DS.Colors.textPrimary.opacity(isFromUser ? 0.9 : 1))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let generatedImagePreview {
                    Image(nsImage: generatedImagePreview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 260, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Generated image: " + message.bodyText)
                }
                if let threadActionTitle {
                    Button(action: onThreadAction) {
                        Label(threadActionTitle, systemImage: "arrowshape.turn.up.left")
                            .font(.caption).foregroundStyle(DS.Colors.textSecondary)
                            .padding(.horizontal, 3).padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .paceControlHoverHighlight(cornerRadius: DS.Radius.control).pointerCursor()
                }
                if let receipt = message.submissionReceipt {
                    Label(receipt, systemImage: receipt == "Sent" ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .accessibilityLabel("Message " + receipt.lowercased())
                }
                if !isFromUser, let speechRequest = message.speechRequest {
                    speechControls(speechRequest)
                    if showsJapaneseOriginal {
                        Text(speechRequest.text)
                            .font(appearance.font(size: 13))
                            .lineSpacing(appearance.lineSpacing(existing: 4))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(DS.Colors.borderSubtle).frame(width: 1)
                            }
                    }
                }
                if let originalResponse = message.originalResponse {
                    Button(showsOriginalResponse ? "Hide original response" : "View original response") {
                        showsOriginalResponse.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .paceControlHoverHighlight(cornerRadius: 4)
                    .pointerCursor()
                    if showsOriginalResponse {
                        Text(originalResponse)
                            .font(appearance.font(size: 11, existing: .system(size: 11, design: .monospaced)))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, isFromUser ? 12 : 0)
            .padding(.vertical, isFromUser ? 9 : 0)
            .background(
                isFromUser ? DS.Colors.controlFill : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
            )
            .contextMenu { ShareAndCopyContextMenuItems(messageBody: message.bodyText) }
            if !isFromUser { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFromUser ? "You" : "Pace")
        .task(id: message.generatedImagePreviewID) {
            generatedImagePreview = nil
            guard let identifier = message.generatedImagePreviewID else { return }
            let previewData = await Task.detached(priority: .utility) {
                PaceGeneratedImageStore.chatPreviewData(for: identifier)
            }.value
            guard !Task.isCancelled, let previewData else { return }
            generatedImagePreview = NSImage(data: previewData)
        }
    }

    private func speechControls(_ speechRequest: PaceSpeechRequest) -> some View {
        HStack(spacing: 10) {
            Button {
                onReplay(speechRequest)
            } label: {
                Label(speechRequest.profile == .japaneseFemale ? "Replay Japanese" : "Replay", systemImage: "play")
            }
            .disabled(!canReplay)
            .paceControlHoverHighlight(cornerRadius: 4, isEnabled: canReplay)
            .pointerCursor(isEnabled: canReplay)
            .help(canReplay ? "Play this reply again" : "Replay is available when Pace is idle and speech is unmuted")
            if message.isEnglishSubtitle, speechRequest.profile == .japaneseFemale {
                Button(showsJapaneseOriginal ? "Hide original" : "Japanese original") {
                    showsJapaneseOriginal.toggle()
                }
                .paceControlHoverHighlight(cornerRadius: 4)
                .pointerCursor()
                .accessibilityValue(showsJapaneseOriginal ? "Expanded" : "Collapsed")
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.bodyText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 20, height: 20)
            }
            .paceControlHoverHighlight(cornerRadius: 4)
            .pointerCursor()
            .help("Copy reply")
            .accessibilityLabel("Copy reply")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(DS.Colors.textTertiary)
        .padding(.top, 3)
    }

    private func readableMessage(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct PaceDialogueActivityView: View {
    let activity: PaceDialogueActivityGroup
    var onOpenDiagnostics: () -> Void = {}
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if activity.needsAttention {
                ForEach(activity.entries) { entry in
                    Label(entry.title, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.failure)
                    Text(entry.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button(isExpanded ? "Less detail" : "More detail") { isExpanded.toggle() }
                        .pointerCursor()
                    Button("Help & diagnostics", action: onOpenDiagnostics)
                        .pointerCursor()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textSecondary)
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .medium))
                        Text("Activity")
                        Text("· \(activity.entries.count) \(activity.entries.count == 1 ? "update" : "updates")")
                            .foregroundStyle(DS.Colors.textTertiary.opacity(0.8))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: 4)
                .pointerCursor()
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                if isExpanded {
                    ForEach(activity.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.system(size: 10, weight: .medium))
                            Text(entry.detail).font(.system(size: 11)).textSelection(.enabled)
                        }
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Colors.borderSubtle.opacity(0.7)).frame(height: 0.5)
        }
    }
}

struct PaceDialogueCurrentStatusView: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var signalState: PaceSignalState { companionManager.nativePanelPresentation.signalState }
    private var hasFailure: Bool { companionManager.currentTurnHUDState.status == .failed }
    private var tracksElapsedTime: Bool { [.listening, .understanding, .acting].contains(signalState) }

    var body: some View {
        if companionManager.isViewingLiveTurn,
            PaceDialogueTranscriptModel.showsCurrentTurnStatus(state: signalState, hasFailure: hasFailure)
        {
            if tracksElapsedTime {
                TimelineView(.periodic(from: .now, by: 1)) { context in status(at: context.date) }
            } else {
                status(at: Date())
            }
        }
    }

    private func status(at date: Date) -> some View {
        let powerClarificationIdentifier = companionManager.pendingSpokenPowerClarification?.identifier
        let feedback = PaceRequestFeedback.resolve(
            state: signalState,
            hudDetail: companionManager.currentTurnHUDState.detail,
            isPreparing: companionManager.buddyDictationManager.isPreparingToRecord,
            isFinalizing: companionManager.buddyDictationManager.isFinalizingTranscript,
            startedAt: companionManager.currentRequestStartedAt, now: date)
        let displayedTitle =
            signalState == .blocked ? companionManager.currentTurnHUDState.title : feedback.title
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if feedback.showsSpinner && !reduceMotion {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    PaceSignalView(
                        state: signalState,
                        isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                        audioPowerLevel: companionManager.currentAudioPowerLevel, lineCount: 1,
                        colorRoleOverride: nil)
                }
            }.frame(width: 28, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedTitle)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if companionManager.currentTurnHUDState.status == .needsClarification {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(companionManager.currentTurnHUDState.options, id: \.self) { option in
                                Button {
                                    companionManager.resolveClarification(
                                        option: option,
                                        powerClarificationIdentifier: powerClarificationIdentifier)
                                } label: {
                                    Text(option)
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(
                                            DS.Colors.controlFill, in: RoundedRectangle(cornerRadius: DS.Radius.control)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .paceControlHoverHighlight(cornerRadius: DS.Radius.control).pointerCursor().fixedSize()
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if companionManager.currentTurnHUDState.status != .needsClarification, let detail = feedback.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
                }
                if companionManager.queuedChatTurnCount > 0 {
                    Text("\(companionManager.queuedChatTurnCount) queued")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Colors.textSecondary)
                }
            }
            Spacer(minLength: 4)
            if let elapsed = feedback.elapsedLabel {
                Text(elapsed).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Colors.textSecondary).monospacedDigit()
                    .accessibilityLabel("Elapsed " + elapsed)
            }
            if hasFailure {
                Button("Details") {
                    PaceSettingsWindowManager.shared.show(companionManager: companionManager, destination: .doctor)
                }.buttonStyle(.plain).font(.system(size: 11)).pointerCursor()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.controlFill.opacity(0.58), in: RoundedRectangle(cornerRadius: DS.Radius.surface))
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pace request status: " + displayedTitle)
    }
}

struct PaceChatVoiceControl: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var dictationManager: PacePushToTalkManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _dictationManager = ObservedObject(wrappedValue: companionManager.buddyDictationManager)
    }

    var body: some View {
        let action = PaceChatVoiceAction.resolve(for: companionManager)
        HStack(spacing: 4) {
            switch action {
            case .allowMicrophone:
                control("Allow microphone", icon: "mic", help: "Allow Pace to use your microphone for voice input") {
                    companionManager.requestMicrophoneAccess()
                }
            case .allowSpeechRecognition:
                control(
                    "Allow speech recognition", icon: "waveform",
                    help: "Allow the selected speech provider to transcribe your voice"
                ) {
                    companionManager.requestSpeechRecognitionPermission()
                }
            case .checkVoiceModel:
                control(
                    "Check voice model", icon: "waveform",
                    help: "The transcription model is loading. Open Voice settings to see its status."
                ) {
                    PaceSettingsWindowManager.shared.show(companionManager: companionManager, destination: .voice)
                }
            case .retryPracticeMicrophone:
                control(
                    "Retry Japanese microphone", icon: "arrow.clockwise",
                    help: dictationManager.japanesePracticePreparationStatus
                ) {
                    dictationManager.prepareJapanesePracticeTranscriptionIfNeeded()
                }
            case .preparingPracticeMicrophone:
                Label("Preparing Japanese microphone…", systemImage: "waveform")
            case .start:
                control("Speak to Pace", icon: "mic", help: "Start voice input") {
                    companionManager.handleMicrophoneButtonTapped()
                }
                if companionManager.hasAccessibilityPermission {
                    Text("Hold " + BuddyPushToTalkShortcut.currentShortcutOption.notchDisplayLabel)
                        .foregroundStyle(DS.Colors.textTertiary)
                        .accessibilityLabel(
                            "Voice shortcut: hold " + BuddyPushToTalkShortcut.currentShortcutOption.notchDisplayLabel)
                }
            case .finishRecording:
                control("Finish recording", icon: "mic.fill", help: "Finish voice input and transcribe") {
                    companionManager.handleMicrophoneButtonTapped()
                }
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(DS.Colors.textSecondary)
    }

    private func control(_ title: String, icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .padding(.horizontal, 4)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
        .pointerCursor()
        .help(help)
    }
}

struct PaceThreadLocationBar: View {
    @ObservedObject var session: PaceChatSession
    let onBack: (PaceChatMessage) -> Void

    var body: some View {
        if session.activeThreadRootID != nil {
            let root = session.activeThreadRoot
            HStack(spacing: 8) {
                Button {
                    if let root { onBack(root) }
                    session.returnToMainChat()
                } label: {
                    Label("Main chat", systemImage: "chevron.left")
                        .padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .paceControlHoverHighlight(cornerRadius: DS.Radius.control)
                .pointerCursor().help("Return to the original message in main chat")
                Divider().frame(height: 13)
                Text("Replying to").fontWeight(.semibold)
                if let root {
                    Text(PaceChatTranscriptModel.displayedBodyText(forChatMessage: root))
                        .lineLimit(1).foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 5)
        }
    }
}

@MainActor
extension CompanionManager {
    var isViewingLiveTurn: Bool {
        let root =
            buddyDictationManager.isDictationInProgress || voiceState == .listening
            ? captureThreadRootID : activeConversationUserEvent?.threadRootID
        return root == chatSession.activeThreadRootID
    }

    func activitiesInCurrentChat() -> [PaceChatToolActivityRowModel] {
        PaceDialogueTranscriptModel.activityRows(fromNewestFirst: recentActionResults).filter { row in
            guard let turn = row.turnIdentifier else { return chatSession.activeThreadRootID == nil }
            return chatSession.threadRootID(forTurnID: turn) == chatSession.activeThreadRootID
        }
    }
}

extension PaceChatSession {
    func threadActionTitle(for message: PaceChatMessage) -> String? {
        guard activeThreadRootID == nil else { return nil }
        let count = replyCount(for: message)
        if count == 0 { return "Reply in thread" }
        return count == 1 ? "1 reply" : "\(count) replies"
    }
}

extension PaceChatMessage {
    var dialogueScrollID: String {
        let row = PaceChatTranscriptModel.messageRowModel(fromChatMessage: self)
        if row.author == .assistant && row.origin == .progress {
            return "dialogue-activity-" + (row.turnIdentifier ?? "unlinked-message-" + row.id)
        }
        return PaceDialogueTranscriptItem.message(row).id
    }
}
