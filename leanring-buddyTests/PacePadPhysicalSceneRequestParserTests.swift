import Testing

@testable import Pace

struct PacePadPhysicalSceneRequestParserTests {
    @Test func explicitPhysicalSceneQuestionsRequestOneCameraFrame() {
        for transcript in [
            "Pace, what do you see?",
            "What am I holding right now?",
            "Look around this room and tell me where the mug is.",
            "Can you answer this using the camera?",
            "Could you check through the camera and tell me if the door is open?",
        ] {
            #expect(PaceCompanionPhysicalSceneRequestParser.requestsCameraContext(transcript))
        }
    }

    @Test func ordinaryConversationDoesNotRequestCameraContext() {
        for transcript in [
            "What is on my calendar?",
            "Summarize what I was doing on the Mac.",
            "Remind me to buy coffee tomorrow.",
            "The meeting is in this room tomorrow.",
            "My keyboard is in front of you while I work.",
            "I changed a setting using the camera preferences.",
        ] {
            #expect(
                PaceCompanionPhysicalSceneRequestParser.requestsCameraContext(transcript) == false
            )
        }
    }
}
