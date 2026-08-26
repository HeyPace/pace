import Combine
import Foundation
import Network

@MainActor
final class PaceCompanionServer: ObservableObject, PacePadOutputDelegate {
    static let shared = PaceCompanionServer()

    enum ConnectionStatus: Equatable {
        case stopped
        case advertising
        case connected(deviceName: String)
        case unavailable(String)
    }

    @Published private(set) var connectionStatus: ConnectionStatus = .stopped
    @Published private(set) var pairingCode: String
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var remotePrivacyState = PaceCompanionPrivacyState(
        isMicrophoneEnabled: false,
        isCameraEnabled: false,
        isSpeakerMuted: false,
        isAllCapturePaused: true
    )

    private static let keychainServiceIdentifier = "com.pace.app.companion"
    private static let keychainAccountName = "paired-ipad"
    private static let serverIdentifierDefaultsKey = "PaceCompanionServerIdentifier"

    private weak var companionManager: CompanionManager?
    private var listener: NWListener?
    private var activeConnection: PaceCompanionFramedConnection?
    private var activeSessionIdentifier: String?
    private var activeDeviceIdentifier: String?
    private var isActiveSessionAuthenticated = false
    private var storedCredential: PaceCompanionStoredCredential?
    private var lastHeartbeatReceivedAt = Date.distantPast
    private var outgoingHeartbeatSequenceNumber = 0
    private var heartbeatTask: Task<Void, Never>?
    private var voiceStateCancellable: AnyCancellable?
    private var offDeviceStateCancellable: AnyCancellable?
    private var pendingCameraFrameContinuations: [String: CheckedContinuation<Data?, Never>] = [:]
    private let listenerQueue = DispatchQueue(
        label: "com.pace.companion-server.listener",
        qos: .userInitiated
    )
    private let serverIdentifier: String

    private init() {
        pairingCode = PaceCompanionSecurity.generatePairingCode()
        if let existingServerIdentifier = UserDefaults.standard.string(
            forKey: Self.serverIdentifierDefaultsKey
        ) {
            serverIdentifier = existingServerIdentifier
        } else {
            let newServerIdentifier = UUID().uuidString
            UserDefaults.standard.set(newServerIdentifier, forKey: Self.serverIdentifierDefaultsKey)
            serverIdentifier = newServerIdentifier
        }
        storedCredential = PaceCompanionKeychain.load(
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
        pairedDeviceName = storedCredential?.remoteName
    }

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        companionManager.pacePadOutputDelegate = self
        voiceStateCancellable = companionManager.$voiceState
            .removeDuplicates(by: { leftState, rightState in
                switch (leftState, rightState) {
                case (.idle, .idle), (.listening, .listening),
                    (.processing, .processing), (.responding, .responding):
                    return true
                default:
                    return false
                }
            })
            .sink { [weak self] voiceState in
                self?.sendInteractionState(voiceState)
            }
        offDeviceStateCancellable = companionManager.$isOffDeviceTurnInFlight
            .removeDuplicates()
            .sink { [weak self, weak companionManager] _ in
                guard let companionManager else { return }
                self?.sendInteractionState(companionManager.voiceState)
            }
        startListener()
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        voiceStateCancellable?.cancel()
        voiceStateCancellable = nil
        offDeviceStateCancellable?.cancel()
        offDeviceStateCancellable = nil
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        clearActiveSession()
        connectionStatus = .stopped
        companionManager?.pacePadOutputDelegate = nil
        companionManager = nil
    }

    func rotatePairingCode() {
        pairingCode = PaceCompanionSecurity.generatePairingCode()
        restartListener()
    }

    func unpairCurrentDevice() {
        _ = PaceCompanionKeychain.delete(
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
        storedCredential = nil
        pairedDeviceName = nil
        activeConnection?.cancel()
        clearActiveSession()
        pairingCode = PaceCompanionSecurity.generatePairingCode()
        restartListener()
    }

    func deliverAssistantResponse(
        turnIdentifier: String,
        spokenText: String,
        usesOffDevicePlanner: Bool
    ) -> Bool {
        guard isActiveSessionAuthenticated else { return false }
        return send(
            payload: .assistantResponse(
                PaceCompanionAssistantResponse(
                    turnIdentifier: turnIdentifier,
                    spokenText: spokenText,
                    usesOffDevicePlanner: usesOffDevicePlanner
                )))
    }

    func deliverProactiveMessage(_ utterance: PaceProactiveUtterance) -> Bool {
        guard isActiveSessionAuthenticated else { return false }
        // A connected but paused iPad owns this output route. Treat the message
        // as handled so the proactivity pipeline does not fall back to Mac TTS.
        guard remotePrivacyState.permitsProactiveOutput else { return true }
        return send(
            payload: .proactiveMessage(
                PaceCompanionProactiveMessage(
                    spokenText: utterance.spokenText,
                    source: utterance.source.rawValue,
                    expiresAt: utterance.relevanceWindowExpiresAt
                )))
    }

    private func startListener() {
        listener?.cancel()

        var tlsMaterials: [PaceCompanionTLSMaterial] = []
        if let pairingMaterial = PaceCompanionSecurity.pairingTLSMaterial(pairingCode: pairingCode) {
            tlsMaterials.append(pairingMaterial)
        }
        if let storedCredential,
            let credentialMaterial = PaceCompanionSecurity.credentialTLSMaterial(
                credential: storedCredential.credential,
                deviceIdentifier: storedCredential.remoteIdentifier
            )
        {
            tlsMaterials.append(credentialMaterial)
        }

        do {
            let listener = try NWListener(using: PaceCompanionTLSParameters.make(materials: tlsMaterials))
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Pace on Mac",
                type: PaceCompanionProtocol.bonjourServiceType
            )
            listener.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor [weak self] in
                    self?.accept(newConnection)
                }
            }
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor [weak self] in
                    self?.handle(listenerState)
                }
            }
            listener.start(queue: listenerQueue)
            self.listener = listener
            connectionStatus = .advertising
        } catch {
            connectionStatus = .unavailable(error.localizedDescription)
        }
    }

    private func restartListener() {
        startListener()
    }

    private func accept(_ networkConnection: NWConnection) {
        activeConnection?.cancel()
        clearActiveSession(keepingConnection: true)

        let framedConnection = PaceCompanionFramedConnection(
            connection: networkConnection,
            queueLabel: "com.pace.companion-server.connection"
        )
        framedConnection.onStateChange = { [weak self, weak framedConnection] state in
            guard let self, self.activeConnection === framedConnection else { return }
            switch state {
            case .ready:
                lastHeartbeatReceivedAt = Date()
                startHeartbeatLoop()
            case .failed(let reason):
                connectionStatus = .unavailable(reason)
                clearActiveSession()
            case .cancelled:
                connectionStatus = .advertising
                clearActiveSession()
            case .preparing:
                break
            }
        }
        framedConnection.onFrameReceived = { [weak self, weak framedConnection] frame in
            guard let self, self.activeConnection === framedConnection else { return }
            handle(frame)
        }
        activeConnection = framedConnection
        framedConnection.start()
    }

    private func handle(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            if !isActiveSessionAuthenticated {
                connectionStatus = .advertising
            }
        case .failed(let error):
            connectionStatus = .unavailable(error.localizedDescription)
        case .cancelled:
            if activeConnection == nil {
                connectionStatus = .stopped
            }
        case .setup, .waiting:
            connectionStatus = .advertising
        @unknown default:
            connectionStatus = .unavailable("Unknown Bonjour listener state")
        }
    }

    private func handle(_ frame: PaceCompanionWireFrame) {
        switch frame.message.payload {
        case .pairRequest(let pairRequest):
            handlePairRequest(pairRequest, message: frame.message)
        case .sessionHello(let sessionHello):
            handleSessionHello(sessionHello, message: frame.message)
        default:
            guard isActiveSessionAuthenticated,
                frame.message.sessionIdentifier == activeSessionIdentifier
            else {
                sendError(
                    code: "authentication_required",
                    message: "Pair or authenticate this iPad before sending companion messages.",
                    replyToMessageIdentifier: frame.message.messageIdentifier
                )
                return
            }
            handleAuthenticatedFrame(frame)
        }
    }

    private func handlePairRequest(
        _ pairRequest: PaceCompanionPairRequest,
        message: PaceCompanionMessage
    ) {
        guard !pairRequest.deviceIdentifier.isEmpty,
            !pairRequest.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sendError(
                code: "invalid_pair_request",
                message: "The iPad did not provide a valid device identity.",
                replyToMessageIdentifier: message.messageIdentifier
            )
            return
        }

        let credential = PaceCompanionSecurity.generateCredential()
        let storedCredential = PaceCompanionStoredCredential(
            remoteIdentifier: pairRequest.deviceIdentifier,
            remoteName: pairRequest.deviceName,
            localDeviceIdentifier: serverIdentifier,
            credential: credential
        )
        guard
            PaceCompanionKeychain.store(
                storedCredential,
                serviceIdentifier: Self.keychainServiceIdentifier,
                accountName: Self.keychainAccountName
            )
        else {
            sendError(
                code: "credential_storage_failed",
                message: "Pace could not save the pairing credential in Keychain.",
                replyToMessageIdentifier: message.messageIdentifier
            )
            return
        }

        self.storedCredential = storedCredential
        pairedDeviceName = storedCredential.remoteName
        authenticateSession(
            sessionIdentifier: message.sessionIdentifier,
            deviceIdentifier: pairRequest.deviceIdentifier,
            deviceName: pairRequest.deviceName
        )
        _ = send(
            payload: .pairResponse(
                PaceCompanionPairResponse(
                    serverIdentifier: serverIdentifier,
                    serverName: Host.current().localizedName ?? "Pace on Mac",
                    deviceCredential: credential
                )),
            replyToMessageIdentifier: message.messageIdentifier
        )
        pairingCode = PaceCompanionSecurity.generatePairingCode()

        // Keep the accepted connection alive while refreshing the Bonjour
        // listener so reconnects during this app launch can use the newly
        // issued credential instead of requiring the numeric code again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.restartListener()
        }
    }

    private func handleSessionHello(
        _ sessionHello: PaceCompanionSessionHello,
        message: PaceCompanionMessage
    ) {
        guard let storedCredential,
            storedCredential.remoteIdentifier == sessionHello.deviceIdentifier,
            PaceCompanionSecurity.validateSessionAuthenticationProof(
                sessionHello.authenticationProof,
                credential: storedCredential.credential,
                serverIdentifier: serverIdentifier,
                deviceIdentifier: sessionHello.deviceIdentifier,
                sessionIdentifier: message.sessionIdentifier
            )
        else {
            sendError(
                code: "authentication_failed",
                message: "The stored companion pairing is no longer valid.",
                replyToMessageIdentifier: message.messageIdentifier
            )
            return
        }
        authenticateSession(
            sessionIdentifier: message.sessionIdentifier,
            deviceIdentifier: sessionHello.deviceIdentifier,
            deviceName: sessionHello.deviceName
        )
        _ = send(
            payload: .heartbeat(
                PaceCompanionHeartbeat(
                    sequenceNumber: outgoingHeartbeatSequenceNumber,
                    acknowledgedSequenceNumber: nil
                )))
    }

    private func authenticateSession(
        sessionIdentifier: String,
        deviceIdentifier: String,
        deviceName: String
    ) {
        activeSessionIdentifier = sessionIdentifier
        activeDeviceIdentifier = deviceIdentifier
        isActiveSessionAuthenticated = true
        lastHeartbeatReceivedAt = Date()
        connectionStatus = .connected(deviceName: deviceName)
        sendInteractionState(companionManager?.voiceState ?? .idle)
    }

    private func handleAuthenticatedFrame(_ frame: PaceCompanionWireFrame) {
        switch frame.message.payload {
        case .heartbeat(let heartbeat):
            lastHeartbeatReceivedAt = Date()
            _ = send(
                payload: .heartbeat(
                    PaceCompanionHeartbeat(
                        sequenceNumber: outgoingHeartbeatSequenceNumber,
                        acknowledgedSequenceNumber: heartbeat.sequenceNumber
                    )))
        case .userUtterance(let utterance):
            process(utterance: utterance, audioData: frame.binaryPayload)
        case .presenceChanged(let presenceChange):
            guard remotePrivacyState.permitsCameraMedia else { return }
            companionManager?.companionRuntime.acceptRemotePresenceChange(
                isUserPresent: presenceChange.isUserPresent,
                confidence: presenceChange.confidence,
                observedAt: presenceChange.observedAt
            )
        case .cameraFrameResponse(let cameraFrameResponse):
            guard remotePrivacyState.permitsCameraMedia else { return }
            resolveCameraFrame(
                requestIdentifier: cameraFrameResponse.requestIdentifier,
                imageData: frame.binaryPayload
            )
        case .privacyStateChanged(let privacyState):
            remotePrivacyState = privacyState
            if !privacyState.permitsCameraMedia {
                cancelPendingCameraFrameRequests()
            }
        case .unpairRequest(let unpairRequest):
            guard unpairRequest.deviceIdentifier == activeDeviceIdentifier else {
                sendError(
                    code: "unpair_identity_mismatch",
                    message: "That iPad cannot remove this companion pairing.",
                    replyToMessageIdentifier: frame.message.messageIdentifier
                )
                return
            }
            unpairCurrentDevice()
        case .pairRequest, .pairResponse, .sessionHello, .interactionState,
            .assistantResponse, .proactiveMessage, .cameraFrameRequest, .error:
            sendError(
                code: "unexpected_message",
                message: "That message type is not accepted by Pace on Mac.",
                replyToMessageIdentifier: frame.message.messageIdentifier
            )
        }
    }

    private func process(
        utterance: PaceCompanionUserUtterance,
        audioData: Data
    ) {
        guard remotePrivacyState.permitsMicrophoneMedia else {
            sendError(
                code: "microphone_paused",
                message: "The iPad microphone is paused.",
                replyToMessageIdentifier: nil
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = send(
                payload: .interactionState(
                    PaceCompanionInteractionStateChange(
                        state: .transcribing,
                        turnIdentifier: utterance.turnIdentifier,
                        usesOffDevicePlanner: false
                    )))
            let temporaryAudioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pacepad-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            do {
                try audioData.write(to: temporaryAudioURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporaryAudioURL) }
                let transcript = try await PaceAudioFileTranscriber.transcribeAudioFile(
                    at: temporaryAudioURL
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else {
                    sendError(
                        code: "empty_transcript",
                        message: "I couldn't hear enough speech to answer.",
                        replyToMessageIdentifier: nil
                    )
                    sendInteractionState(.idle)
                    return
                }

                var physicalSceneContext: String?
                if PaceCompanionPhysicalSceneRequestParser.requestsCameraContext(transcript),
                    remotePrivacyState.isCameraEnabled,
                    !remotePrivacyState.isAllCapturePaused,
                    let imageData = await requestCameraFrame(
                        originatingTurnIdentifier: utterance.turnIdentifier,
                        reason: "You asked Pace about the physical scene."
                    )
                {
                    physicalSceneContext = await analyzePhysicalScene(
                        imageData: imageData,
                        userIntent: transcript
                    )
                }

                guard
                    companionManager?.submitPacePadTranscript(
                        transcript,
                        turnIdentifier: utterance.turnIdentifier,
                        physicalSceneContext: physicalSceneContext
                    ) == true
                else {
                    sendError(
                        code: "pace_busy",
                        message: "Pace is finishing another turn. Try again in a moment.",
                        replyToMessageIdentifier: nil
                    )
                    sendInteractionState(.idle)
                    return
                }
            } catch {
                try? FileManager.default.removeItem(at: temporaryAudioURL)
                sendError(
                    code: "transcription_failed",
                    message: "The iPad recording could not be transcribed locally.",
                    replyToMessageIdentifier: nil
                )
                sendInteractionState(.idle)
            }
        }
    }

    private func requestCameraFrame(
        originatingTurnIdentifier: String,
        reason: String
    ) async -> Data? {
        let requestIdentifier = UUID().uuidString
        let expiresAt = Date().addingTimeInterval(8)
        return await withCheckedContinuation { continuation in
            pendingCameraFrameContinuations[requestIdentifier] = continuation
            let didSend = send(
                payload: .cameraFrameRequest(
                    PaceCompanionCameraFrameRequest(
                        requestIdentifier: requestIdentifier,
                        originatingTurnIdentifier: originatingTurnIdentifier,
                        reason: reason,
                        expiresAt: expiresAt
                    )))
            guard didSend else {
                pendingCameraFrameContinuations.removeValue(forKey: requestIdentifier)?.resume(
                    returning: nil
                )
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.pendingCameraFrameContinuations
                    .removeValue(forKey: requestIdentifier)?
                    .resume(returning: nil)
            }
        }
    }

    private func resolveCameraFrame(requestIdentifier: String, imageData: Data) {
        pendingCameraFrameContinuations
            .removeValue(forKey: requestIdentifier)?
            .resume(returning: imageData)
    }

    private func cancelPendingCameraFrameRequests() {
        for pendingContinuation in pendingCameraFrameContinuations.values {
            pendingContinuation.resume(returning: nil)
        }
        pendingCameraFrameContinuations.removeAll()
    }

    private func analyzePhysicalScene(imageData: Data, userIntent: String) async -> String? {
        do {
            let analysisClient =
                try PaceCompanionScreenAnalysisClientFactory
                .makePrivacyPinnedLocalClient()
            let analysis = try await analysisClient.analyzeScreenshot(
                screenshotImageData: imageData,
                userIntent: "Describe only the physical scene details needed to answer: \(userIntent)"
            )
            let description = analysis.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? nil : description
        } catch {
            return nil
        }
    }

    private func sendInteractionState(_ voiceState: CompanionVoiceState) {
        if case .idle = voiceState,
            companionManager?.activePacePadTurnIdentifier != nil
        {
            sendError(
                code: "turn_ended_without_response",
                message: "Pace could not finish that response. Please try again.",
                replyToMessageIdentifier: nil
            )
            companionManager?.abandonActivePacePadTurn()
        }
        let interactionState: PaceCompanionInteractionState =
            switch voiceState {
            case .idle: .idle
            case .listening: .listening
            case .processing: .processing
            case .responding: .speaking
            }
        _ = send(
            payload: .interactionState(
                PaceCompanionInteractionStateChange(
                    state: interactionState,
                    turnIdentifier: companionManager?.activePacePadTurnIdentifier,
                    usesOffDevicePlanner: companionManager?.activePacePadTurnIdentifier != nil
                        && companionManager?.isOffDeviceTurnInFlight == true
                )))
    }

    @discardableResult
    private func send(
        payload: PaceCompanionMessagePayload,
        binaryPayload: Data = Data(),
        replyToMessageIdentifier: String? = nil
    ) -> Bool {
        guard let activeConnection else { return false }
        let message = PaceCompanionMessage(
            payload: payload,
            sessionIdentifier: activeSessionIdentifier ?? "pairing",
            replyToMessageIdentifier: replyToMessageIdentifier
        )
        do {
            try activeConnection.send(
                PaceCompanionWireFrame(
                    message: message,
                    binaryPayload: binaryPayload
                ))
            return true
        } catch {
            return false
        }
    }

    private func sendError(
        code: String,
        message: String,
        replyToMessageIdentifier: String?
    ) {
        _ = send(
            payload: .error(
                PaceCompanionErrorMessage(
                    code: code,
                    message: message,
                    isRecoverable: true
                )),
            replyToMessageIdentifier: replyToMessageIdentifier
        )
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PaceCompanionProtocol.heartbeatIntervalSeconds))
                guard let self, !Task.isCancelled else { return }
                if PaceCompanionConnectionPolicy.heartbeatHasTimedOut(
                    lastHeartbeatReceivedAt: lastHeartbeatReceivedAt
                ) {
                    activeConnection?.cancel()
                    clearActiveSession()
                    connectionStatus = .advertising
                    return
                }
                outgoingHeartbeatSequenceNumber += 1
                _ = send(
                    payload: .heartbeat(
                        PaceCompanionHeartbeat(
                            sequenceNumber: outgoingHeartbeatSequenceNumber,
                            acknowledgedSequenceNumber: nil
                        )))
            }
        }
    }

    private func clearActiveSession(keepingConnection: Bool = false) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if !keepingConnection {
            activeConnection = nil
        }
        activeSessionIdentifier = nil
        activeDeviceIdentifier = nil
        isActiveSessionAuthenticated = false
        remotePrivacyState = PaceCompanionPrivacyState(
            isMicrophoneEnabled: false,
            isCameraEnabled: false,
            isSpeakerMuted: false,
            isAllCapturePaused: true
        )
        cancelPendingCameraFrameRequests()
    }
}
