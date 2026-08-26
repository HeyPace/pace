import Foundation

nonisolated enum PaceCompanionProtocol {
    static let currentVersion = 1
    static let bonjourServiceType = "_pace-companion._tcp"
    static let maximumHeaderByteCount = 64 * 1_024
    static let maximumBinaryPayloadByteCount = 12 * 1_024 * 1_024
    static let maximumUtteranceDurationSeconds: TimeInterval = 60
    static let credentialByteCount = 32
    static let audioContentType = "audio/mp4"
    static let cameraFrameContentType = "image/jpeg"
    static let heartbeatIntervalSeconds: TimeInterval = 5
    static let heartbeatTimeoutSeconds: TimeInterval = 18
    static let maximumReconnectDelaySeconds: TimeInterval = 15
}

nonisolated enum PaceCompanionConnectionPolicy {
    static func reconnectDelaySeconds(afterAttemptNumber attemptNumber: Int) -> TimeInterval {
        let normalizedAttemptNumber = max(1, attemptNumber)
        return min(
            pow(2, Double(normalizedAttemptNumber - 1)),
            PaceCompanionProtocol.maximumReconnectDelaySeconds
        )
    }

    static func heartbeatHasTimedOut(
        lastHeartbeatReceivedAt: Date,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(lastHeartbeatReceivedAt)
            > PaceCompanionProtocol.heartbeatTimeoutSeconds
    }
}

nonisolated enum PaceCompanionMessageKind: String, Codable, CaseIterable, Sendable {
    case pairRequest = "pair_request"
    case pairResponse = "pair_response"
    case unpairRequest = "unpair_request"
    case sessionHello = "session_hello"
    case heartbeat
    case interactionState = "interaction_state"
    case userUtterance = "user_utterance"
    case assistantResponse = "assistant_response"
    case proactiveMessage = "proactive_message"
    case presenceChanged = "presence_changed"
    case cameraFrameRequest = "camera_frame_request"
    case cameraFrameResponse = "camera_frame_response"
    case privacyStateChanged = "privacy_state_changed"
    case error
}

nonisolated enum PaceCompanionInteractionState: String, Codable, Sendable {
    case idle
    case listening
    case transcribing
    case processing
    case speaking
}

nonisolated struct PaceCompanionPairRequest: Codable, Equatable, Sendable {
    let deviceIdentifier: String
    let deviceName: String
}

nonisolated struct PaceCompanionPairResponse: Codable, Equatable, Sendable {
    let serverIdentifier: String
    let serverName: String
    let deviceCredential: String
}

nonisolated struct PaceCompanionUnpairRequest: Codable, Equatable, Sendable {
    let deviceIdentifier: String
}

nonisolated struct PaceCompanionSessionHello: Codable, Equatable, Sendable {
    let deviceIdentifier: String
    let deviceName: String
    let authenticationProof: String
}

nonisolated struct PaceCompanionHeartbeat: Codable, Equatable, Sendable {
    let sequenceNumber: Int
    let acknowledgedSequenceNumber: Int?
}

nonisolated struct PaceCompanionInteractionStateChange: Codable, Equatable, Sendable {
    let state: PaceCompanionInteractionState
    let turnIdentifier: String?
    let usesOffDevicePlanner: Bool

    init(
        state: PaceCompanionInteractionState,
        turnIdentifier: String?,
        usesOffDevicePlanner: Bool = false
    ) {
        self.state = state
        self.turnIdentifier = turnIdentifier
        self.usesOffDevicePlanner = usesOffDevicePlanner
    }
}

nonisolated struct PaceCompanionUserUtterance: Codable, Equatable, Sendable {
    let turnIdentifier: String
    let audioContentType: String
    let audioDurationSeconds: Double
    let binaryByteCount: Int
}

nonisolated struct PaceCompanionAssistantResponse: Codable, Equatable, Sendable {
    let turnIdentifier: String
    let spokenText: String
    let usesOffDevicePlanner: Bool
}

nonisolated struct PaceCompanionProactiveMessage: Codable, Equatable, Sendable {
    let spokenText: String
    let source: String
    let expiresAt: Date?
}

nonisolated struct PaceCompanionPresenceChange: Codable, Equatable, Sendable {
    let isUserPresent: Bool
    let confidence: Double
    let observedAt: Date
}

nonisolated struct PaceCompanionCameraFrameRequest: Codable, Equatable, Sendable {
    let requestIdentifier: String
    let originatingTurnIdentifier: String
    let reason: String
    let expiresAt: Date
}

nonisolated struct PaceCompanionCameraFrameResponse: Codable, Equatable, Sendable {
    let requestIdentifier: String
    let imageContentType: String
    let capturedAt: Date
    let binaryByteCount: Int
}

nonisolated struct PaceCompanionPrivacyState: Codable, Equatable, Sendable {
    let isMicrophoneEnabled: Bool
    let isCameraEnabled: Bool
    let isSpeakerMuted: Bool
    let isAllCapturePaused: Bool

    var permitsMicrophoneMedia: Bool {
        isMicrophoneEnabled && !isAllCapturePaused
    }

    var permitsCameraMedia: Bool {
        isCameraEnabled && !isAllCapturePaused
    }

    var permitsProactiveOutput: Bool {
        !isAllCapturePaused
    }
}

nonisolated struct PaceCompanionErrorMessage: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let isRecoverable: Bool
}

nonisolated enum PaceCompanionMessagePayload: Equatable, Sendable {
    case pairRequest(PaceCompanionPairRequest)
    case pairResponse(PaceCompanionPairResponse)
    case unpairRequest(PaceCompanionUnpairRequest)
    case sessionHello(PaceCompanionSessionHello)
    case heartbeat(PaceCompanionHeartbeat)
    case interactionState(PaceCompanionInteractionStateChange)
    case userUtterance(PaceCompanionUserUtterance)
    case assistantResponse(PaceCompanionAssistantResponse)
    case proactiveMessage(PaceCompanionProactiveMessage)
    case presenceChanged(PaceCompanionPresenceChange)
    case cameraFrameRequest(PaceCompanionCameraFrameRequest)
    case cameraFrameResponse(PaceCompanionCameraFrameResponse)
    case privacyStateChanged(PaceCompanionPrivacyState)
    case error(PaceCompanionErrorMessage)

    var kind: PaceCompanionMessageKind {
        switch self {
        case .pairRequest: return .pairRequest
        case .pairResponse: return .pairResponse
        case .unpairRequest: return .unpairRequest
        case .sessionHello: return .sessionHello
        case .heartbeat: return .heartbeat
        case .interactionState: return .interactionState
        case .userUtterance: return .userUtterance
        case .assistantResponse: return .assistantResponse
        case .proactiveMessage: return .proactiveMessage
        case .presenceChanged: return .presenceChanged
        case .cameraFrameRequest: return .cameraFrameRequest
        case .cameraFrameResponse: return .cameraFrameResponse
        case .privacyStateChanged: return .privacyStateChanged
        case .error: return .error
        }
    }
}

nonisolated struct PaceCompanionMessage: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let messageIdentifier: String
    let sessionIdentifier: String
    let replyToMessageIdentifier: String?
    let sentAt: Date
    let payload: PaceCompanionMessagePayload

    init(
        payload: PaceCompanionMessagePayload,
        sessionIdentifier: String,
        replyToMessageIdentifier: String? = nil,
        messageIdentifier: String = UUID().uuidString,
        sentAt: Date = Date(),
        protocolVersion: Int = PaceCompanionProtocol.currentVersion
    ) {
        self.protocolVersion = protocolVersion
        self.messageIdentifier = messageIdentifier
        self.sessionIdentifier = sessionIdentifier
        self.replyToMessageIdentifier = replyToMessageIdentifier
        self.sentAt = sentAt
        self.payload = payload
    }

    var kind: PaceCompanionMessageKind {
        payload.kind
    }

    var declaredBinaryByteCount: Int {
        switch payload {
        case .userUtterance(let utterance):
            return utterance.binaryByteCount
        case .cameraFrameResponse(let response):
            return response.binaryByteCount
        default:
            return 0
        }
    }

    func belongs(toSessionIdentifier expectedSessionIdentifier: String) -> Bool {
        !expectedSessionIdentifier.isEmpty && sessionIdentifier == expectedSessionIdentifier
    }

    func validate() throws {
        guard protocolVersion == PaceCompanionProtocol.currentVersion else {
            throw PaceCompanionProtocolValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard !messageIdentifier.isEmpty, !sessionIdentifier.isEmpty else {
            throw PaceCompanionProtocolValidationError.missingMessageIdentity
        }
        guard declaredBinaryByteCount >= 0,
            declaredBinaryByteCount <= PaceCompanionProtocol.maximumBinaryPayloadByteCount
        else {
            throw PaceCompanionProtocolValidationError.invalidBinaryPayloadLength(declaredBinaryByteCount)
        }

        switch payload {
        case .pairRequest(let pairRequest):
            guard Self.containsVisibleText(pairRequest.deviceIdentifier),
                Self.containsVisibleText(pairRequest.deviceName)
            else {
                throw PaceCompanionProtocolValidationError.invalidPairRequest
            }
        case .pairResponse(let pairResponse):
            guard Self.containsVisibleText(pairResponse.serverIdentifier),
                Self.containsVisibleText(pairResponse.serverName),
                Data(base64Encoded: pairResponse.deviceCredential)?.count
                    == PaceCompanionProtocol.credentialByteCount
            else {
                throw PaceCompanionProtocolValidationError.invalidPairResponse
            }
        case .unpairRequest(let unpairRequest):
            guard Self.containsVisibleText(unpairRequest.deviceIdentifier) else {
                throw PaceCompanionProtocolValidationError.invalidUnpairRequest
            }
        case .sessionHello(let sessionHello):
            guard Self.containsVisibleText(sessionHello.deviceIdentifier),
                Self.containsVisibleText(sessionHello.deviceName),
                Self.containsVisibleText(sessionHello.authenticationProof)
            else {
                throw PaceCompanionProtocolValidationError.invalidSessionHello
            }
        case .heartbeat(let heartbeat):
            guard heartbeat.sequenceNumber >= 0,
                heartbeat.acknowledgedSequenceNumber.map({ $0 >= 0 }) ?? true
            else {
                throw PaceCompanionProtocolValidationError.invalidHeartbeat
            }
        case .userUtterance(let utterance):
            guard Self.containsVisibleText(utterance.turnIdentifier),
                utterance.audioContentType == PaceCompanionProtocol.audioContentType,
                utterance.audioDurationSeconds.isFinite,
                utterance.audioDurationSeconds > 0,
                utterance.audioDurationSeconds <= PaceCompanionProtocol.maximumUtteranceDurationSeconds,
                utterance.binaryByteCount > 0
            else {
                throw PaceCompanionProtocolValidationError.invalidUserUtterance
            }
        case .cameraFrameResponse(let response):
            guard Self.containsVisibleText(response.requestIdentifier),
                response.imageContentType == PaceCompanionProtocol.cameraFrameContentType,
                response.binaryByteCount > 0
            else {
                throw PaceCompanionProtocolValidationError.invalidCameraFrameResponse
            }
        case .presenceChanged(let presenceChange):
            guard presenceChange.confidence.isFinite,
                (0...1).contains(presenceChange.confidence)
            else {
                throw PaceCompanionProtocolValidationError.invalidPresenceConfidence
            }
        case .assistantResponse(let response):
            guard Self.containsVisibleText(response.turnIdentifier),
                Self.containsVisibleText(response.spokenText)
            else {
                throw PaceCompanionProtocolValidationError.invalidAssistantResponse
            }
        case .proactiveMessage(let message):
            guard Self.containsVisibleText(message.spokenText),
                Self.containsVisibleText(message.source)
            else {
                throw PaceCompanionProtocolValidationError.invalidProactiveMessage
            }
        case .cameraFrameRequest(let request):
            guard Self.containsVisibleText(request.requestIdentifier),
                Self.containsVisibleText(request.originatingTurnIdentifier),
                Self.containsVisibleText(request.reason)
            else {
                throw PaceCompanionProtocolValidationError.invalidCameraFrameRequest
            }
        case .error(let errorMessage):
            guard Self.containsVisibleText(errorMessage.code),
                Self.containsVisibleText(errorMessage.message)
            else {
                throw PaceCompanionProtocolValidationError.invalidErrorMessage
            }
        default:
            break
        }
    }

    private static func containsVisibleText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case messageIdentifier
        case sessionIdentifier
        case replyToMessageIdentifier
        case sentAt
        case kind
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        messageIdentifier = try container.decode(String.self, forKey: .messageIdentifier)
        sessionIdentifier = try container.decode(String.self, forKey: .sessionIdentifier)
        replyToMessageIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .replyToMessageIdentifier
        )
        sentAt = try container.decode(Date.self, forKey: .sentAt)

        switch try container.decode(PaceCompanionMessageKind.self, forKey: .kind) {
        case .pairRequest:
            payload = .pairRequest(try container.decode(PaceCompanionPairRequest.self, forKey: .body))
        case .pairResponse:
            payload = .pairResponse(try container.decode(PaceCompanionPairResponse.self, forKey: .body))
        case .unpairRequest:
            payload = .unpairRequest(try container.decode(PaceCompanionUnpairRequest.self, forKey: .body))
        case .sessionHello:
            payload = .sessionHello(try container.decode(PaceCompanionSessionHello.self, forKey: .body))
        case .heartbeat:
            payload = .heartbeat(try container.decode(PaceCompanionHeartbeat.self, forKey: .body))
        case .interactionState:
            payload = .interactionState(try container.decode(PaceCompanionInteractionStateChange.self, forKey: .body))
        case .userUtterance:
            payload = .userUtterance(try container.decode(PaceCompanionUserUtterance.self, forKey: .body))
        case .assistantResponse:
            payload = .assistantResponse(try container.decode(PaceCompanionAssistantResponse.self, forKey: .body))
        case .proactiveMessage:
            payload = .proactiveMessage(try container.decode(PaceCompanionProactiveMessage.self, forKey: .body))
        case .presenceChanged:
            payload = .presenceChanged(try container.decode(PaceCompanionPresenceChange.self, forKey: .body))
        case .cameraFrameRequest:
            payload = .cameraFrameRequest(try container.decode(PaceCompanionCameraFrameRequest.self, forKey: .body))
        case .cameraFrameResponse:
            payload = .cameraFrameResponse(try container.decode(PaceCompanionCameraFrameResponse.self, forKey: .body))
        case .privacyStateChanged:
            payload = .privacyStateChanged(try container.decode(PaceCompanionPrivacyState.self, forKey: .body))
        case .error:
            payload = .error(try container.decode(PaceCompanionErrorMessage.self, forKey: .body))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(messageIdentifier, forKey: .messageIdentifier)
        try container.encode(sessionIdentifier, forKey: .sessionIdentifier)
        try container.encodeIfPresent(replyToMessageIdentifier, forKey: .replyToMessageIdentifier)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(payload.kind, forKey: .kind)

        switch payload {
        case .pairRequest(let body): try container.encode(body, forKey: .body)
        case .pairResponse(let body): try container.encode(body, forKey: .body)
        case .unpairRequest(let body): try container.encode(body, forKey: .body)
        case .sessionHello(let body): try container.encode(body, forKey: .body)
        case .heartbeat(let body): try container.encode(body, forKey: .body)
        case .interactionState(let body): try container.encode(body, forKey: .body)
        case .userUtterance(let body): try container.encode(body, forKey: .body)
        case .assistantResponse(let body): try container.encode(body, forKey: .body)
        case .proactiveMessage(let body): try container.encode(body, forKey: .body)
        case .presenceChanged(let body): try container.encode(body, forKey: .body)
        case .cameraFrameRequest(let body): try container.encode(body, forKey: .body)
        case .cameraFrameResponse(let body): try container.encode(body, forKey: .body)
        case .privacyStateChanged(let body): try container.encode(body, forKey: .body)
        case .error(let body): try container.encode(body, forKey: .body)
        }
    }
}

nonisolated enum PaceCompanionProtocolValidationError: Error, Equatable {
    case unsupportedProtocolVersion(Int)
    case missingMessageIdentity
    case invalidBinaryPayloadLength(Int)
    case invalidPairRequest
    case invalidPairResponse
    case invalidUnpairRequest
    case invalidSessionHello
    case invalidHeartbeat
    case invalidUserUtterance
    case invalidCameraFrameResponse
    case invalidPresenceConfidence
    case invalidAssistantResponse
    case invalidProactiveMessage
    case invalidCameraFrameRequest
    case invalidErrorMessage
}
