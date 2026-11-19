import Foundation
import SwiftUI

nonisolated enum PaceConversationLanguageMode: Equatable, Sendable {
    case standard, japanesePractice

    static func command(_ transcript: String) -> Self? {
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？"))
        if ["start japanese practice", "practice japanese", "let’s practice japanese", "let's practice japanese", "speak japanese with english subtitles", "turn on japanese practice", "日本語の練習を始めて", "日本語で話して"].contains(command) {
            return .japanesePractice
        }
        if ["stop japanese practice", "turn off japanese practice", "back to english", "switch back to english", "英語に戻して", "日本語の練習をやめて"].contains(command) {
            return .standard
        }
        return nil
    }

    func applying(to systemPrompt: String) -> String {
        guard self == .japanesePractice else { return systemPrompt }
        return systemPrompt + "\n\n" + Self.practiceInstructions
    }

    static let practiceInstructions = """
    Japanese conversation practice is explicitly on for this session. Keep every existing tool, action, permission and approval rule. Treat the user as the same person and continue the same conversation; they may speak Japanese or English. Be a patient language teacher. Answer briefly in natural, approachable Japanese, gently correct one useful mistake when appropriate, and ask one contextual follow-up. Avoid interrupting every exchange with corrections or a lecture. Correct only wording or grammar evidenced in the transcript, respect valid names and beginner phrasing, and never claim to assess pronunciation or accent from transcription text alone.
    Return exactly the existing v10 JSON envelope. spokenText is the short Japanese line to speak (at most 2000 characters). payload.englishSubtitle is its faithful English translation (at most 4000 characters), including any useful correction. Use intent answer for conversation. For actions retain the existing intent, payload.name/args or payload.calls and add englishSubtitle alongside them. The Japanese and English must mean the same thing. Do not put tool syntax in either line. Do not add a speak tool merely to narrate your answer; Pace speaks spokenText using the local Japanese voice. Do not translate commands, filenames, addresses or tool arguments. Example: {"spokenText":"今日は何をしましたか。","intent":"answer","payload":{"englishSubtitle":"What did you do today?"}}
    """
}

enum PaceJapanesePracticeRouting {
    enum Decision: Equatable {
        case normalRouting
        case textOnlyConversation
    }

    static func decision(
        mode: PaceConversationLanguageMode, route: PaceIntentRoute, transcript: String,
        hasScreenSuggestion: Bool, hasActiveVisualContext: Bool
    ) -> Decision {
        guard mode == .japanesePractice, route == .fullPipeline,
              !hasScreenSuggestion, !hasActiveVisualContext,
              PaceFastActionCommandParser.parse(transcript: transcript) == nil,
              PaceIntentClarifier.clarification(for: transcript) == nil else { return .normalRouting }
        let normalizedTranscript = transcript.lowercased()
        let words = Set(normalizedTranscript.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let computerWords: Set<String> = [
            "screen", "screens", "window", "windows", "app", "apps", "application", "browser",
            "computer", "desktop", "file", "files", "folder", "folders", "menu", "button", "tab",
            "click", "tap", "press", "drag", "scroll", "open", "close", "launch", "navigate",
            "save", "delete", "send", "type", "paste", "copy", "select", "download", "upload",
            "run", "execute", "play", "pause", "stop",
            "record", "screenshot", "camera", "microphone", "terminal", "code", "coding",
            "email", "calendar", "reminder", "research", "search", "investigate", "compare",
            "power", "powers", "workflow", "shortcut", "chrome", "safari", "website", "url",
        ]
        let japaneseComputerCues = [
            "画面", "スクリーン", "ウィンドウ", "アプリ", "ブラウザ", "パソコン", "コンピュータ",
            "ファイル", "フォルダ", "メニュー", "ボタン", "クリック", "タップ", "ドラッグ", "スクロール",
            "起動", "開いて", "開く", "閉じ", "保存", "削除", "送信", "入力", "実行", "再生", "停止",
            "検索", "調べ", "ダウンロード", "アップロード", "貼り付け", "コピー", "選択", "設定",
            "録画", "録音", "メール", "カレンダー", "リマインダー", "パワー", "ショートカット",
            "ワークフロー", "コード", "ターミナル", "見せて", "見て", "描いて", "ここを",
            "アイコン", "タブ", "サイドバー", "ツールバー", "ダイアログ",
            "入力欄", "チェックボックス", "押して", "押す", "選ん", "移動", "音量", "ミュート",
            "明るさ", "消して", "切り替え", "戻して", "操作", "マウス", "キーボード", "カーソル",
            "リンク", "ウェブ", "サイト", "スクショ",
        ]
        let requestSentences = normalizedTranscript.components(separatedBy: CharacterSet(charactersIn: "。！？!?.\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
        let operationRequests = ["音楽をかけて", "音楽かけて", "リマインドして"]
        let politeEndings = [
            "", "ください", "下さい", "くださいね", "くれる", "くれますか", "くれない", "くれませんか",
            "もらえる", "もらえない", "もらえますか", "もらえませんか", "ほしい", "ほしいです",
            "欲しい", "欲しいです", "ね", "よ", "ちょうだい", "お願いします",
        ]
        let hasOperationRequest = requestSentences.contains { sentence in
            operationRequests.contains { request in
                politeEndings.contains { sentence.hasSuffix(request + $0) }
            }
        }
        guard !hasOperationRequest, words.isDisjoint(with: computerWords),
              !japaneseComputerCues.contains(where: normalizedTranscript.contains),
              !normalizedTranscript.contains("://") else { return .normalRouting }
        return .textOnlyConversation
    }
}

nonisolated enum PaceFinalSpeechDeliveryPurpose: Equatable, Sendable {
    case assistantReply
    case operationalFeedback
}

nonisolated struct PaceBilingualReply: Equatable, Sendable {
    let speechRequest: PaceSpeechRequest
    let englishSubtitle: String

    private static func normalizedSpokenText(_ text: String) -> String {
        let strippedDone = PaceTagParsers.parseAndStripDoneSignal(from: text).strippedText
        return PaceTagParsers.parsePointingCoordinates(from: strippedDone).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ response: String) throws -> Self {
        guard let data = response.data(using: .utf8), data.count <= 128 * 1024,
              case .object(let envelope) = try? JSONDecoder().decode(PaceMCPJSONValue.self, from: data),
              Set(envelope.keys).isSubset(of: ["spokenText", "intent", "payload"]),
              case .string(let intent)? = envelope["intent"],
              ["answer", "action", "dictate", "edit", "clarify", "refuse"].contains(intent),
              case .string(let spokenText)? = envelope["spokenText"],
              case .object(let payload)? = envelope["payload"],
              case .string(let englishSubtitle)? = payload["englishSubtitle"],
              !englishSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              englishSubtitle.count <= 4000, spokenText.count <= 2000,
              let speechRequest = PaceSpeechRequest.parse(arguments: ["text": .string(normalizedSpokenText(spokenText)), "profile": .string("japanese_female"), "englishSubtitle": .string(englishSubtitle)]),
              speechRequest.text.unicodeScalars.contains(where: { (0x3040...0x30ff).contains($0.value) || (0x4e00...0x9fff).contains($0.value) }),
              !spokenText.contains("<tool_calls"), !englishSubtitle.contains("<tool_calls"),
              !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
              !englishSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            throw PaceJapanesePracticeError.invalidReply
        }
        return Self(speechRequest: speechRequest, englishSubtitle: englishSubtitle.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

nonisolated enum PaceJapanesePracticeError: LocalizedError {
    case invalidReply
    var errorDescription: String? {
        "Japanese practice needs both a Japanese reply and English subtitles. Please try again."
    }
}

@MainActor
extension CompanionManager {
    func setJapanesePracticeEnabled(_ enabled: Bool, transcript: String? = nil) {
        if enabled, !ttsClient.supportsSpeechProfile(.japaneseFemale) {
            let failure = "Japanese practice needs the local Kokoro Japanese voice. The selected speech backend does not support it."
            if let transcript { recordConversationTurn(userTranscript: transcript, assistantResponse: failure) }
            else { recordAssistantNarration(failure, origin: .failure) }
            responseOverlayManager.updateStreamingText(failure)
            responseOverlayManager.finishStreaming()
            currentTurnHUDState = .failed(failure)
            if transcript != nil || voiceState == .idle { voiceState = .idle }
            return
        }
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        cancelActiveTurnTasks(preservingConversationRequest: transcript != nil)
        ttsClient.stopPlayback()
        streamingSentenceTTSPipeline.resetForNewTurn()
        clearLastSpokenReplyState()
        conversationLanguageMode = enabled ? .japanesePractice : .standard
        activeConversationLanguageMode = conversationLanguageMode
        activeBilingualReply = nil
        streamingSentenceTTSPipeline.setConversationLanguageModeForCurrentTurn(conversationLanguageMode)
        buddyDictationManager.usesJapanesePracticeTranscription = enabled
        let status = enabled
            ? "Japanese practice is on. I’ll speak Japanese with English subtitles. You can speak Japanese or English."
            : "Japanese practice is off. Back to your usual voice and language."
        if let transcript { recordConversationTurn(userTranscript: transcript, assistantResponse: status) }
        else { recordAssistantNarration(status, origin: .progress) }
        responseOverlayManager.updateStreamingText(status)
        responseOverlayManager.finishStreaming()
        voiceState = .idle
        currentTurnHUDState = .done(enabled ? "Japanese practice · English subtitles" : "Japanese practice off")
    }

    func speakStandardNarration(_ text: String) async throws {
        guard conversationLanguageMode == .standard, !streamingSentenceTTSPipeline.isMutedForCurrentTurn else { return }
        try await ttsClient.speakText(text)
    }

    func prepareBilingualReplyIfNeeded(_ response: String, turnLease: PaceTurnLease) throws {
        guard isActiveTurn(turnLease), activeConversationLanguageMode == .japanesePractice else { return }
        let reply = try PaceBilingualReply.parse(response)
        activeBilingualReply = reply
        streamingSentenceTTSPipeline.setBilingualReplyForCurrentTurn(reply)
    }

    func conversationDisplayText(for speechText: String) -> String {
        guard activeConversationLanguageMode == .japanesePractice,
              let activeBilingualReply,
              activeBilingualReply.speechRequest.text == speechText else { return speechText }
        return activeBilingualReply.englishSubtitle
    }

    func conversationSpeechRequest(for speechText: String) -> PaceSpeechRequest? {
        guard activeConversationLanguageMode == .japanesePractice,
              activeBilingualReply?.speechRequest.text == speechText else { return nil }
        return activeBilingualReply?.speechRequest
    }
}

struct PaceJapanesePracticeControl: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var dictationManager: PacePushToTalkManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._dictationManager = ObservedObject(wrappedValue: companionManager.buddyDictationManager)
    }

    private var isEnabled: Bool { companionManager.conversationLanguageMode == .japanesePractice }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isEnabled {
                    Image(systemName: "character.bubble")
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text("Japanese practice")
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text("· English subtitles")
                        .foregroundStyle(DS.Colors.textTertiary)
                    Spacer(minLength: 8)
                    Button("End practice") { companionManager.setJapanesePracticeEnabled(false) }
                        .help("Restore your usual language and voice")
                        .accessibilityLabel("End Japanese practice")
                        .paceControlHoverHighlight(cornerRadius: 4)
                        .pointerCursor()
                } else {
                    Button {
                        companionManager.setJapanesePracticeEnabled(true)
                    } label: {
                        Label("Practice Japanese", systemImage: "character.bubble")
                    }
                    .help("Speak Japanese with English subtitles; local Japanese and English recognition")
                    .accessibilityLabel("Turn on Japanese practice")
                    .paceControlHoverHighlight(cornerRadius: 4)
                    .pointerCursor()
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(DS.Colors.textTertiary)
            if isEnabled, !dictationManager.japanesePracticePreparationStatus.isEmpty {
                Text(dictationManager.japanesePracticePreparationStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .help(dictationManager.japanesePracticePreparationStatus)
            }
        }
    }
}
