import Foundation
import Testing
@testable import Pace

struct PaceUtilityCommandTests {
    @Test func commandPayloadsPreserveCaseAndPaths() {
        #expect(
            PaceUtilityCommand.parse("Read aloud using Kokoro Hello Pace!")
                == .speak(text: "Hello Pace!", useKokoro: true))
        #expect(PaceUtilityCommand.parse("say aloud Hello") == .speak(text: "Hello", useKokoro: false))
        #expect(
            PaceUtilityCommand.parse("transcribe audio \"~/Desktop/Meeting One.wav\"")
                == .transcribeAudio(path: "~/Desktop/Meeting One.wav"))
        #expect(PaceUtilityCommand.parse("Check for updates.") == .checkUpdates)
        #expect(PaceUtilityCommand.parse("transcribe file something") == nil)
        #expect(PaceUtilityCommand.parse("research software updates") == nil)
    }

    @Test func updateCheckRepliesDescribeTheUpdaterResult() {
        #expect(PaceUtilityCommand.updateCheckReply(for: .started) == "Checking for Pace updates.")
        #expect(
            PaceUtilityCommand.updateCheckReply(for: .alreadyInProgress)
                == "An update check is already in progress.")
    }

    private var speechFixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/pace-command-speech.wav")
    }

    @Test func bundledSileroDetectsRealSpeech() throws {
        let samples = try PaceAudioFileTranscriber.decodeAudioToMonoFloatSamplesAt16kHz(fileURL: speechFixtureURL)
        #expect(try PaceSileroSpeechDetector.containsSpeech(in: samples))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACE_OSS_AUDIO_INTEGRATION"] == "1"))
    func installedWhisperKitTranscribesTheCommandFixture() async throws {
        let transcript = try await PaceAudioFileTranscriber.transcribeAudioFile(at: speechFixtureURL)
        #expect(transcript.lowercased().contains("next command"))
    }

    @Test func bundledSileroRejectsSilenceWithoutModelDownloads() throws {
        #expect(try !PaceSileroSpeechDetector.containsSpeech(in: Array(repeating: 0, count: 16000)))
        #expect(try !PaceSileroSpeechDetector.containsSpeech(in: []))
    }
}

struct PaceAutoUpdateControllerTests {
    @Test @MainActor func onlyBooleanTrueMarksALocalDevelopmentBuild() {
        #expect(PaceAutoUpdateController.isLocalDevelopmentBuild(infoDictionary: ["PaceLocalDevelopmentBuild": true]))
        #expect(!PaceAutoUpdateController.isLocalDevelopmentBuild(infoDictionary: ["PaceLocalDevelopmentBuild": false]))
        #expect(!PaceAutoUpdateController.isLocalDevelopmentBuild(infoDictionary: [:]))
        #expect(!PaceAutoUpdateController.isLocalDevelopmentBuild(infoDictionary: ["PaceLocalDevelopmentBuild": "true"]))
    }

    @Test @MainActor func localDevelopmentBuildDeclinesManualUpdates() {
        let autoUpdateController = PaceAutoUpdateController(infoDictionary: ["PaceLocalDevelopmentBuild": true])
        let result = autoUpdateController.checkForUpdatesManually()

        #expect(result == .disabledForLocalDevelopmentBuild)
        #expect(
            PaceUtilityCommand.updateCheckReply(for: result)
                == "Public updates are disabled for this local development build of Pace.")
    }
}
