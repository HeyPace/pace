import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceScreenRecordingControllerTests {
    @Test func deniedPermissionDoesNotLaunchOrCreateRecordingStorage() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = PaceScreenRecordingController(
            recordingsDirectory: directory, screenRecordingPermissionCheck: { false })
        let result = await controller.start()
        #expect(result.summary.contains("Could not start screen recording"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(controller.status().summary == "Pace has no active screen recording.")
    }

    @Test func unwritableDestinationFailsBeforeStartingCapture() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: fileURL)
        let controller = PaceScreenRecordingController(
            recordingsDirectory: fileURL, screenRecordingPermissionCheck: { true })
        let result = await controller.start()
        #expect(result.summary.contains("Failed to start screen recording"))
        #expect(controller.status().summary == "Pace has no active screen recording.")
    }

    @Test func stoppingWithoutAnOwnedRecordingDoesNotTouchOtherRecordings() async {
        let controller = PaceScreenRecordingController(screenRecordingPermissionCheck: { false })
        let result = await controller.stop()
        #expect(result.summary == "Pace has no active screen recording.")
        controller.shutdown()
    }

    @Test func recordingLifecycleCanBeComposedByThePlanner() {
        for (mode, expectedKind) in [
            ("start_recording", PaceScreenCaptureKind.startRecording),
            ("stop_recording", .stopRecording),
            ("recording_status", .recordingStatus),
        ] {
            let result = PaceActionTagParser.parseActions(
                from: """
                    {"spokenText":"","intent":"action","payload":{"name":"screen_capture","args":{"mode":"\(mode)"}}}
                    """)
            guard case .screenCapture(let kind)? = result.actions.first else {
                Issue.record("Expected screen recording lifecycle action")
                continue
            }
            #expect(kind == expectedKind)
        }
        for (command, expectedKind) in [
            ("stop screen recording", PaceScreenCaptureKind.stopRecording),
            ("screen recording status", .recordingStatus),
            ("open screen recording controls", .recording),
        ] {
            let result = PaceFastActionCommandParser.parse(transcript: command)
            guard case .screenCapture(let kind)? = result?.executionPlan.flattenedActions.first else {
                Issue.record("Expected direct recording command")
                continue
            }
            #expect(kind == expectedKind)
        }
    }
}
