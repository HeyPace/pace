import AppKit
import SwiftUI

struct PaceDialogueMessageView: View {
    let message: PaceChatTranscriptMessageRowModel
    let appearance: PaceChatAppearance
    var canReplay = false
    var onReplay: (PaceSpeechRequest) -> Void = { _ in }
    @State private var showsJapaneseOriginal = false
    @State private var showsOriginalResponse = false

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
                    .foregroundStyle(isFromUser ? DS.Colors.textSecondary : DS.Colors.textPrimary.opacity(0.94))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: isFromUser ? 12 : 0))
            .overlay {
                if isFromUser {
                    RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                }
            }
            .contextMenu { ShareAndCopyContextMenuItems(messageBody: message.bodyText) }
            if !isFromUser { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFromUser ? "You" : "Pace")
    }

    private func speechControls(_ speechRequest: PaceSpeechRequest) -> some View {
        HStack(spacing: 10) {
            Button { onReplay(speechRequest) } label: {
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
                Button { isExpanded.toggle() } label: {
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

    private var signalState: PaceSignalState { companionManager.nativeEffectiveSignalState }
    private var hasFailure: Bool { companionManager.currentTurnHUDState.status == .failed }

    var body: some View {
        if PaceDialogueTranscriptModel.showsCurrentTurnStatus(state: signalState, hasFailure: hasFailure) {
            HStack(spacing: 8) {
                PaceSignalView(
                    state: signalState, isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                    audioPowerLevel: companionManager.currentAudioPowerLevel, lineCount: 1,
                    colorRoleOverride: companionManager.nativeEffectiveSignalColorRoleOverride)
                    .frame(width: 24, height: 14)
                Text(companionManager.currentTurnHUDState.detail ?? PaceSignalPresentation.resolve(
                    state: signalState, isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                    reduceMotion: true).label)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if hasFailure {
                    Button("Details") {
                        PaceSettingsWindowManager.shared.show(companionManager: companionManager, destination: .doctor)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .pointerCursor()
                }
            }
            .padding(.vertical, 8)
        }
    }
}

@MainActor
enum PaceChatReturnHandling {
    @discardableResult
    static func handle(modifiers: NSEvent.ModifierFlags, editor: NSTextView?, submit: () -> Void) -> Bool {
        guard let editor, !editor.hasMarkedText() else { return false }
        if !modifiers.intersection([.shift, .option, .control]).isEmpty {
            editor.insertNewlineIgnoringFieldEditor(nil)
        } else {
            submit()
        }
        return true
    }
}

@MainActor
private final class PaceChatComposerContext {
    weak var anchor: NSView?
    var editor: NSTextView? { anchor?.window?.firstResponder as? NSTextView }
}

private struct PaceChatComposerAnchor: NSViewRepresentable {
    let composerContext: PaceChatComposerContext
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        composerContext.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
}

private struct PaceChatReturnSubmitModifier: ViewModifier {
    let submit: () -> Void
    @State private var composerContext = PaceChatComposerContext()

    func body(content: Content) -> some View {
        content
            .background(PaceChatComposerAnchor(composerContext: composerContext)
                .frame(width: 0, height: 0).allowsHitTesting(false))
            .onSubmit {
                guard composerContext.editor?.hasMarkedText() != true else { return }
                if let event = NSApp.currentEvent, let window = composerContext.anchor?.window,
                    event.window === window, event.type == .keyDown, [36, 76].contains(event.keyCode) {
                    PaceChatReturnHandling.handle(modifiers: event.modifierFlags,
                        editor: composerContext.editor, submit: submit)
                } else {
                    submit()
                }
            }
            .onKeyPress(.return, phases: .down) { keyPress in
                var modifiers: NSEvent.ModifierFlags = []
                if keyPress.modifiers.contains(.shift) { modifiers.insert(.shift) }
                if keyPress.modifiers.contains(.option) { modifiers.insert(.option) }
                if keyPress.modifiers.contains(.control) { modifiers.insert(.control) }
                if keyPress.modifiers.contains(.command) { modifiers.insert(.command) }
                return PaceChatReturnHandling.handle(modifiers: modifiers,
                    editor: composerContext.editor, submit: submit) ? .handled : .ignored
            }
    }
}

@MainActor
extension View {
    func paceChatSubmitOnReturn(_ submit: @escaping () -> Void) -> some View {
        modifier(PaceChatReturnSubmitModifier(submit: submit))
    }
}
