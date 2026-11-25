import AVFoundation
import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import Pace

struct PaceWhisperVocabularyTests {
    @Test func immutableVocabularyTokensAreBoundedAndNeverForceTranscriptPrefixes() {
        var encodedText = ""
        let tokens = WhisperKitTranscriptionProvider.contextualPromptTokens(
            ["Bouncing Ball", "Bounce Coach"],
            encode: {
                encodedText = $0
                return [-1, 999] + Array(0..<300)
            }, specialTokenBegin: 256)
        #expect(encodedText == " Bouncing Ball, Bounce Coach")
        let decoderPromptLimit = max(0, (Constants.maxTokenContext / 2) - 1)
        #expect(tokens.count == decoderPromptLimit && tokens.first == 0 && tokens.last == decoderPromptLimit - 1)
        #expect(Array(tokens.suffix(decoderPromptLimit)) == tokens)
        let partialOptions = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: .english, contextualPromptTokens: tokens)
        let finalOptions = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: .english, contextualPromptTokens: tokens)
        #expect(partialOptions.promptTokens == tokens && finalOptions.promptTokens == tokens)
        #expect(partialOptions.prefixTokens == nil && finalOptions.prefixTokens == nil)
        #expect(partialOptions.language == "en" && !partialOptions.detectLanguage)
        let multilingual = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: .automaticJapaneseEnglish, contextualPromptTokens: tokens)
        #expect(multilingual.language == nil && multilingual.detectLanguage)
        let fileOptions = WhisperKitTranscriptionProvider.decodingOptions(languageMode: .english)
        #expect(fileOptions.promptTokens == nil && fileOptions.prefixTokens == nil)
        #expect(
            WhisperKitTranscriptionProvider.contextualPromptTokens([], encode: { _ in [1] }, specialTokenBegin: 256)
                .isEmpty)
    }

    @Test func finalCaptureRetriesQuietSpeechAndRemovesVocabularyAfterEmptyDecode() async throws {
        let options = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: .english, contextualPromptTokens: [12])
        let quietAudio: [Float] = [0.005, -0.005]
        var detectorInputs: [[Float]] = []
        var decoderOptions: [DecodingOptions] = []
        let result = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
            quietAudio, options: options,
            containsSpeech: { audio in
                detectorInputs.append(audio)
                return false
            },
            confirmsAmplifiedSpeech: { audio in
                detectorInputs.append(audio)
                return (audio.first ?? 0) > 0.01
            },
            decode: { audio, options in
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
        let options = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: .english, contextualPromptTokens: [12])
        for audio in [Array(repeating: Float(0), count: 5), [0.005, -0.005]] {
            var decoderCalls = 0
            let result = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
                audio, options: options, containsSpeech: { _ in false }, confirmsAmplifiedSpeech: { _ in false },
                decode: { _, _ in
                    decoderCalls += 1
                    return "Unexpected words"
                }
            )
            #expect(result.isEmpty && decoderCalls == 0)
        }
    }

    @Test func realSpeechDetectorRejectsAmplifiedBackgroundNoise() async throws {
        var noiseGenerator: UInt32 = 47
        let quietNoise: [Float] = (0..<32_000).map { _ in
            noiseGenerator = noiseGenerator &* 1_664_525 &+ 1_013_904_223
            return (Float(noiseGenerator) / Float(UInt32.max) - 0.5) * 0.02
        }
        let options = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: .english, contextualPromptTokens: [12])
        var decoderCalls = 0
        let result = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
            quietNoise, options: options,
            containsSpeech: { try PaceSileroSpeechDetector.containsSpeech(in: $0) },
            confirmsAmplifiedSpeech: {
                try PaceSileroSpeechDetector.containsSpeech(
                    in: $0, minimumProbability: 0.6,
                    minimumConsecutiveFrames: 3)
            },
            decode: { _, _ in
                decoderCalls += 1
                return "Unexpected words"
            }
        )
        #expect(result.isEmpty && decoderCalls == 0)
    }

    @Test func finalCaptureKeepsSuccessfulTextAndSkipsRetryWithoutVocabulary() async throws {
        for (tokens, transcript) in [([12], "Next command"), ([], "")] {
            let options = WhisperKitTranscriptionProvider.decodingOptions(
                languageMode: .automaticJapaneseEnglish, contextualPromptTokens: tokens)
            var decoderCalls = 0
            let result = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
                [0.02], options: options, containsSpeech: { _ in true },
                confirmsAmplifiedSpeech: { _ in false },
                decode: { _, options in
                    decoderCalls += 1
                    #expect(options.language == nil && options.detectLanguage)
                    return transcript
                }
            )
            #expect(result == transcript && decoderCalls == 1)
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PACE_OSS_AUDIO_INTEGRATION"] == "1"),
        .timeLimit(.minutes(1)))
    func quietSpeechSurvivesTheStreamingFinalizer() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pace-command-speech.wav")
        let samples = try PaceAudioFileTranscriber.decodeAudioToMonoFloatSamplesAt16kHz(fileURL: file)
        let peak = try #require(samples.map(abs).max())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        let channel = try #require(buffer.floatChannelData?.pointee)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for sampleIndex in samples.indices {
            channel[sampleIndex] = samples[sampleIndex] * (0.025 / peak)
        }

        let (transcripts, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let session = try await WhisperKitTranscriptionProvider().startStreamingSession(
            contextualPhrases: ["Pace"], onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { text in
                continuation.yield(text)
                continuation.finish()
            },
            onError: { continuation.finish(throwing: $0) }
        )
        defer { session.cancel() }
        session.appendAudioBuffer(buffer)
        session.requestFinalTranscript()
        var received = transcripts.makeAsyncIterator()
        let finalTranscript = try #require(try await received.next())
        #expect(finalTranscript.lowercased().contains("next command"))
    }
}
