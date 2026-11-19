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
        let decoderPromptLimit = max(0, (Constants.maxTokenContext / 2) - 1)
        #expect(tokens.count == decoderPromptLimit && tokens.first == 0 && tokens.last == decoderPromptLimit - 1)
        #expect(Array(tokens.suffix(decoderPromptLimit)) == tokens)
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

    @Test func finalCaptureRetriesQuietSpeechAndRemovesVocabularyAfterEmptyDecode() async throws {
        let options = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .english, contextualPromptTokens: [12])
        let quietAudio: [Float] = [0.005, -0.005]
        var detectorInputs: [[Float]] = []
        var decoderOptions: [DecodingOptions] = []
        let result = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
            quietAudio, options: options, containsSpeech: { audio in
                detectorInputs.append(audio)
                return (audio.first ?? 0) > 0.01
            }, decode: { audio, options in
                #expect(audio == detectorInputs.last)
                decoderOptions.append(options)
                return options.promptTokens == nil ? "Next command" : ""
            }
        )
        #expect(result == "Next command")
        #expect(detectorInputs.first == quietAudio && detectorInputs.count == 2)
        #expect(decoderOptions.count == 2)
        #expect(decoderOptions.first?.promptTokens == [12] && decoderOptions.last?.promptTokens == nil)
        #expect(decoderOptions.allSatisfy { $0.noSpeechThreshold == options.noSpeechThreshold && $0.language == "en" })
    }

    @Test func finalCaptureNeverDecodesAudioRejectedBySpeechDetection() async throws {
        let options = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .english, contextualPromptTokens: [12])
        for audio in [Array(repeating: Float(0), count: 5), [0.005, -0.005]] {
            var decoderCalls = 0
            let result = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
                audio, options: options, containsSpeech: { _ in false }, decode: { _, _ in
                    decoderCalls += 1
                    return "Unexpected words"
                }
            )
            #expect(result.isEmpty && decoderCalls == 0)
        }
    }
}
