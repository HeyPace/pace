import Testing
@preconcurrency import WhisperKit
@testable import Pace

struct PaceWhisperVocabularyTests {
    @Test func immutableVocabularyTokensAreBoundedAndNeverForceTranscriptPrefixes() {
        var encodedText = ""
        let tokens = WhisperKitTranscriptionProvider.contextualPromptTokens(["Bouncing Ball", "Bounce Coach"], encode: {
            encodedText = $0
            return [-1, 999] + Array(0..<300)
        }, specialTokenBegin: 256)
        #expect(encodedText == " Bouncing Ball, Bounce Coach")
        #expect(tokens.count == 192 && tokens.first == 0 && tokens.last == 191)
        let partialOptions = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .english, contextualPromptTokens: tokens)
        let finalOptions = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .english, contextualPromptTokens: tokens)
        #expect(partialOptions.promptTokens == tokens && finalOptions.promptTokens == tokens)
        #expect(partialOptions.prefixTokens == nil && finalOptions.prefixTokens == nil)
        #expect(partialOptions.language == "en" && !partialOptions.detectLanguage)
        let multilingual = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .automaticJapaneseEnglish, contextualPromptTokens: tokens)
        #expect(multilingual.language == nil && multilingual.detectLanguage)
        let fileOptions = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .english)
        #expect(fileOptions.promptTokens == nil && fileOptions.prefixTokens == nil)
        #expect(WhisperKitTranscriptionProvider.contextualPromptTokens([], encode: { _ in [1] }, specialTokenBegin: 256).isEmpty)
    }
}
