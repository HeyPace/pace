import Foundation
import Testing

@testable import Pace

struct PaceCompanionProtocolTests {
    @Test func controlMessageRoundTripsThroughTheWireCodec() throws {
        let message = PaceCompanionMessage(
            payload: .presenceChanged(
                PaceCompanionPresenceChange(
                    isUserPresent: true,
                    confidence: 0.93,
                    observedAt: Date(timeIntervalSince1970: 2_000_000_000)
                )),
            sessionIdentifier: "test-session",
            messageIdentifier: "presence-message"
        )
        let encodedFrame = try PaceCompanionFrameCodec.encode(PaceCompanionWireFrame(message: message))
        var streamDecoder = PaceCompanionFrameStreamDecoder()
        let decodedFrames = try streamDecoder.append(encodedFrame)

        #expect(decodedFrames.count == 1)
        #expect(decodedFrames.first?.message.messageIdentifier == message.messageIdentifier)
        #expect(decodedFrames.first?.message.sessionIdentifier == message.sessionIdentifier)
        #expect(decodedFrames.first?.message.payload == message.payload)
        #expect(decodedFrames.first?.binaryPayload.isEmpty == true)
    }

    @Test func binaryMessagesWaitForTheCompletePayloadAcrossNetworkChunks() throws {
        let audioData = Data(repeating: 0xA5, count: 4_096)
        let message = PaceCompanionMessage(
            payload: .userUtterance(
                PaceCompanionUserUtterance(
                    turnIdentifier: "turn-one",
                    audioContentType: "audio/mp4",
                    audioDurationSeconds: 3.5,
                    binaryByteCount: audioData.count
                )),
            sessionIdentifier: "test-session"
        )
        let encodedFrame = try PaceCompanionFrameCodec.encode(
            PaceCompanionWireFrame(
                message: message,
                binaryPayload: audioData
            ))
        var streamDecoder = PaceCompanionFrameStreamDecoder()

        #expect(try streamDecoder.append(encodedFrame.prefix(17)).isEmpty)
        #expect(try streamDecoder.append(encodedFrame.dropFirst(17).prefix(500)).isEmpty)
        let decodedFrames = try streamDecoder.append(encodedFrame.dropFirst(517))

        #expect(decodedFrames.count == 1)
        #expect(decodedFrames.first?.message.messageIdentifier == message.messageIdentifier)
        #expect(decodedFrames.first?.message.payload == message.payload)
        #expect(decodedFrames.first?.binaryPayload == audioData)
    }

    @Test func processingStatePreservesOffDeviceTrustBeforeTheResponseArrives() throws {
        let stateChange = PaceCompanionInteractionStateChange(
            state: .processing,
            turnIdentifier: "turn-one",
            usesOffDevicePlanner: true
        )
        let encodedFrame = try PaceCompanionFrameCodec.encode(
            PaceCompanionWireFrame(
                message: PaceCompanionMessage(
                    payload: .interactionState(stateChange),
                    sessionIdentifier: "test-session"
                )))
        var streamDecoder = PaceCompanionFrameStreamDecoder()

        let decodedFrame = try #require(streamDecoder.append(encodedFrame).first)

        #expect(decodedFrame.message.payload == .interactionState(stateChange))
    }

    @Test func unpairRequestPreservesTheAuthenticatedDeviceIdentity() throws {
        let unpairRequest = PaceCompanionUnpairRequest(deviceIdentifier: "pace-ipad")
        let encodedFrame = try PaceCompanionFrameCodec.encode(
            PaceCompanionWireFrame(
                message: PaceCompanionMessage(
                    payload: .unpairRequest(unpairRequest),
                    sessionIdentifier: "test-session"
                )))
        var streamDecoder = PaceCompanionFrameStreamDecoder()

        let decodedFrame = try #require(streamDecoder.append(encodedFrame).first)

        #expect(decodedFrame.message.payload == .unpairRequest(unpairRequest))
    }

    @Test func codecRejectsADeclaredBinaryLengthMismatch() {
        let message = PaceCompanionMessage(
            payload: .cameraFrameResponse(
                PaceCompanionCameraFrameResponse(
                    requestIdentifier: "camera-request",
                    imageContentType: "image/jpeg",
                    capturedAt: Date(),
                    binaryByteCount: 12
                )),
            sessionIdentifier: "test-session"
        )

        #expect(throws: PaceCompanionFrameCodecError.self) {
            try PaceCompanionFrameCodec.encode(
                PaceCompanionWireFrame(
                    message: message,
                    binaryPayload: Data(repeating: 0, count: 11)
                ))
        }
    }

    @Test func unsupportedProtocolVersionsFailBeforeDispatch() {
        let message = PaceCompanionMessage(
            payload: .heartbeat(
                PaceCompanionHeartbeat(
                    sequenceNumber: 1,
                    acknowledgedSequenceNumber: nil
                )),
            sessionIdentifier: "test-session",
            protocolVersion: PaceCompanionProtocol.currentVersion + 1
        )

        #expect(throws: PaceCompanionProtocolValidationError.self) {
            try message.validate()
        }
    }

    @Test func duplicateMessagesAreRejectedWithinTheBoundedWindow() {
        var messageDeduplicator = PaceCompanionMessageDeduplicator(
            maximumRememberedMessageCount: 2
        )

        let acceptedFirstMessage = messageDeduplicator.shouldAccept(messageIdentifier: "one")
        let acceptedDuplicateMessage = messageDeduplicator.shouldAccept(messageIdentifier: "one")
        let acceptedSecondMessage = messageDeduplicator.shouldAccept(messageIdentifier: "two")
        let acceptedThirdMessage = messageDeduplicator.shouldAccept(messageIdentifier: "three")
        let acceptedExpiredFirstMessage = messageDeduplicator.shouldAccept(messageIdentifier: "one")

        #expect(acceptedFirstMessage)
        #expect(acceptedDuplicateMessage == false)
        #expect(acceptedSecondMessage)
        #expect(acceptedThirdMessage)
        #expect(acceptedExpiredFirstMessage)
    }

    @Test func messageSessionMustMatchTheActiveConnectionSession() {
        let message = PaceCompanionMessage(
            payload: .heartbeat(
                PaceCompanionHeartbeat(
                    sequenceNumber: 1,
                    acknowledgedSequenceNumber: nil
                )),
            sessionIdentifier: "current-session"
        )

        #expect(message.belongs(toSessionIdentifier: "current-session"))
        #expect(message.belongs(toSessionIdentifier: "stale-session") == false)
        #expect(message.belongs(toSessionIdentifier: "") == false)
    }

    @Test func utteranceValidationEnforcesTheTapToTalkDurationBound() {
        let message = PaceCompanionMessage(
            payload: .userUtterance(
                PaceCompanionUserUtterance(
                    turnIdentifier: "turn-one",
                    audioContentType: PaceCompanionProtocol.audioContentType,
                    audioDurationSeconds: PaceCompanionProtocol.maximumUtteranceDurationSeconds + 1,
                    binaryByteCount: 1
                )),
            sessionIdentifier: "test-session"
        )

        #expect(throws: PaceCompanionProtocolValidationError.invalidUserUtterance) {
            try message.validate()
        }
    }

    @Test func presenceConfidenceMustBeFiniteAndNormalized() {
        let message = PaceCompanionMessage(
            payload: .presenceChanged(
                PaceCompanionPresenceChange(
                    isUserPresent: true,
                    confidence: 1.1,
                    observedAt: Date()
                )),
            sessionIdentifier: "test-session"
        )

        #expect(throws: PaceCompanionProtocolValidationError.invalidPresenceConfidence) {
            try message.validate()
        }
    }

    @Test func capturePauseClosesEveryRemoteMediaGate() {
        let pausedPrivacyState = PaceCompanionPrivacyState(
            isMicrophoneEnabled: true,
            isCameraEnabled: true,
            isSpeakerMuted: false,
            isAllCapturePaused: true
        )

        #expect(pausedPrivacyState.permitsMicrophoneMedia == false)
        #expect(pausedPrivacyState.permitsCameraMedia == false)
        #expect(pausedPrivacyState.permitsProactiveOutput == false)
    }

    @Test func individualPrivacyControlsKeepUnrelatedCapabilitiesAvailable() {
        let cameraOnlyPrivacyState = PaceCompanionPrivacyState(
            isMicrophoneEnabled: false,
            isCameraEnabled: true,
            isSpeakerMuted: true,
            isAllCapturePaused: false
        )

        #expect(cameraOnlyPrivacyState.permitsMicrophoneMedia == false)
        #expect(cameraOnlyPrivacyState.permitsCameraMedia)
        #expect(cameraOnlyPrivacyState.permitsProactiveOutput)
    }

    @Test func reconnectBackoffIsExponentialAndBounded() {
        #expect(PaceCompanionConnectionPolicy.reconnectDelaySeconds(afterAttemptNumber: 0) == 1)
        #expect(PaceCompanionConnectionPolicy.reconnectDelaySeconds(afterAttemptNumber: 1) == 1)
        #expect(PaceCompanionConnectionPolicy.reconnectDelaySeconds(afterAttemptNumber: 2) == 2)
        #expect(PaceCompanionConnectionPolicy.reconnectDelaySeconds(afterAttemptNumber: 4) == 8)
        #expect(PaceCompanionConnectionPolicy.reconnectDelaySeconds(afterAttemptNumber: 5) == 15)
        #expect(PaceCompanionConnectionPolicy.reconnectDelaySeconds(afterAttemptNumber: 20) == 15)
    }

    @Test func heartbeatTimeoutUsesTheSharedProtocolBoundary() {
        let lastHeartbeatReceivedAt = Date(timeIntervalSince1970: 1_000)

        #expect(
            PaceCompanionConnectionPolicy.heartbeatHasTimedOut(
                lastHeartbeatReceivedAt: lastHeartbeatReceivedAt,
                now: Date(timeIntervalSince1970: 1_017.99)
            ) == false
        )
        #expect(
            PaceCompanionConnectionPolicy.heartbeatHasTimedOut(
                lastHeartbeatReceivedAt: lastHeartbeatReceivedAt,
                now: Date(timeIntervalSince1970: 1_018.01)
            )
        )
    }

    @Test func pairingResponseRequiresAnExactCredentialAndVisibleIdentity() {
        let invalidPairingResponse = PaceCompanionMessage(
            payload: .pairResponse(
                PaceCompanionPairResponse(
                    serverIdentifier: "pace-mac",
                    serverName: "Pace on Mac",
                    deviceCredential: Data(repeating: 0, count: 31).base64EncodedString()
                )),
            sessionIdentifier: "pairing-session"
        )

        #expect(throws: PaceCompanionProtocolValidationError.invalidPairResponse) {
            try invalidPairingResponse.validate()
        }
    }

    @Test func heartbeatSequenceNumbersCannotBeNegative() {
        let invalidHeartbeat = PaceCompanionMessage(
            payload: .heartbeat(
                PaceCompanionHeartbeat(
                    sequenceNumber: -1,
                    acknowledgedSequenceNumber: nil
                )),
            sessionIdentifier: "current-session"
        )

        #expect(throws: PaceCompanionProtocolValidationError.invalidHeartbeat) {
            try invalidHeartbeat.validate()
        }
    }

    @Test func credentialProofBindsTheDeviceServerAndSession() throws {
        let credential = PaceCompanionSecurity.generateCredential()
        let proof = try #require(
            PaceCompanionSecurity.sessionAuthenticationProof(
                credential: credential,
                serverIdentifier: "pace-mac",
                deviceIdentifier: "pace-ipad",
                sessionIdentifier: "session-one"
            ))

        #expect(
            PaceCompanionSecurity.validateSessionAuthenticationProof(
                proof,
                credential: credential,
                serverIdentifier: "pace-mac",
                deviceIdentifier: "pace-ipad",
                sessionIdentifier: "session-one"
            ))
        #expect(
            PaceCompanionSecurity.validateSessionAuthenticationProof(
                proof,
                credential: credential,
                serverIdentifier: "pace-mac",
                deviceIdentifier: "pace-ipad",
                sessionIdentifier: "different-session"
            ) == false)
    }

    @Test func pairingCodesAcceptReadableFormattingButRequireSixAsciiDigits() {
        #expect(PaceCompanionSecurity.normalizedPairingCode("123 456") == "123456")
        #expect(PaceCompanionSecurity.normalizedPairingCode("123-456") == "123456")
        #expect(PaceCompanionSecurity.normalizedPairingCode("12345") == nil)
        #expect(PaceCompanionSecurity.normalizedPairingCode("code 123456") == nil)
        #expect(PaceCompanionSecurity.normalizedPairingCode("１２３４５６") == nil)
    }
}
