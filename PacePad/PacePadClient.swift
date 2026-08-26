import Combine
import Foundation
import Network
import UIKit

@MainActor
final class PacePadClient: ObservableObject {
    enum Status: Equatable {
        case discovering
        case pairingAvailable(macName: String)
        case connecting(macName: String)
        case connected(macName: String)
        case unavailable(String)
    }

    @Published private(set) var status: Status = .discovering

    var onMessage: ((PaceCompanionMessagePayload) -> Void)?
    var onCameraFrameRequested: ((PaceCompanionCameraFrameRequest) -> Void)?

    private static let keychainServiceIdentifier = "com.pace.pad.companion"
    private static let keychainAccountName = "paired-mac"
    private static let deviceIdentifierDefaultsKey = "PacePadDeviceIdentifier"

    private let browserQueue = DispatchQueue(label: "com.pace.pad.browser", qos: .userInitiated)
    private var browser: NWBrowser?
    private var discoveredEndpoint: NWEndpoint?
    private var discoveredMacName: String?
    private var framedConnection: PaceCompanionFramedConnection?
    private var activeSessionIdentifier = UUID().uuidString
    private var storedCredential: PaceCompanionStoredCredential?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastHeartbeatReceivedAt = Date.distantPast
    private var outgoingHeartbeatSequenceNumber = 0
    private var reconnectAttemptCount = 0
    private let deviceIdentifier: String

    init() {
        if let existingDeviceIdentifier = UserDefaults.standard.string(
            forKey: Self.deviceIdentifierDefaultsKey
        ) {
            deviceIdentifier = existingDeviceIdentifier
        } else {
            let newDeviceIdentifier = UUID().uuidString
            UserDefaults.standard.set(newDeviceIdentifier, forKey: Self.deviceIdentifierDefaultsKey)
            deviceIdentifier = newDeviceIdentifier
        }
        storedCredential = PaceCompanionKeychain.load(
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
    }

    func start() {
        reconnectTask?.cancel()
        reconnectTask = nil
        browser?.cancel()
        let browser = NWBrowser(
            for: .bonjour(type: PaceCompanionProtocol.bonjourServiceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] browserState in
            Task { @MainActor [weak self] in
                self?.handle(browserState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handle(results)
            }
        }
        browser.start(queue: browserQueue)
        self.browser = browser
        status = .discovering
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        browser?.cancel()
        browser = nil
        framedConnection?.cancel()
        framedConnection = nil
    }

    func retryDiscovery() {
        reconnectTask?.cancel()
        reconnectTask = nil
        let previousConnection = framedConnection
        framedConnection = nil
        previousConnection?.cancel()
        start()
    }

    func pair(using pairingCode: String) {
        guard let normalizedPairingCode = PaceCompanionSecurity.normalizedPairingCode(pairingCode),
            let discoveredEndpoint,
            let discoveredMacName
        else {
            status = .unavailable("Enter the six-digit code shown by Pace on the Mac.")
            return
        }
        connect(
            endpoint: discoveredEndpoint,
            macName: discoveredMacName,
            tlsMaterial: PaceCompanionSecurity.pairingTLSMaterial(
                pairingCode: normalizedPairingCode
            ),
            isPairingConnection: true
        )
    }

    func unpair() {
        let didSendUnpairRequest = send(
            payload: .unpairRequest(
                PaceCompanionUnpairRequest(deviceIdentifier: deviceIdentifier)
            ))
        guard didSendUnpairRequest else {
            clearLocalPairing()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.clearLocalPairing()
        }
    }

    func forgetStalePairing() {
        clearLocalPairing()
    }

    var hasStoredPairing: Bool {
        storedCredential != nil
    }

    private func clearLocalPairing() {
        _ = PaceCompanionKeychain.delete(
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
        storedCredential = nil
        framedConnection?.cancel()
        framedConnection = nil
        activeSessionIdentifier = UUID().uuidString
        status = discoveredMacName.map { .pairingAvailable(macName: $0) } ?? .discovering
    }

    func sendUtterance(
        audioData: Data,
        durationSeconds: TimeInterval,
        turnIdentifier: String
    ) -> Bool {
        send(
            payload: .userUtterance(
                PaceCompanionUserUtterance(
                    turnIdentifier: turnIdentifier,
                    audioContentType: PaceCompanionProtocol.audioContentType,
                    audioDurationSeconds: durationSeconds,
                    binaryByteCount: audioData.count
                )),
            binaryPayload: audioData
        )
    }

    func sendPresenceChange(
        isUserPresent: Bool,
        confidence: Double,
        observedAt: Date
    ) {
        _ = send(
            payload: .presenceChanged(
                PaceCompanionPresenceChange(
                    isUserPresent: isUserPresent,
                    confidence: confidence,
                    observedAt: observedAt
                )))
    }

    func sendPrivacyState(_ privacyState: PaceCompanionPrivacyState) {
        _ = send(payload: .privacyStateChanged(privacyState))
    }

    func sendCameraFrame(
        requestIdentifier: String,
        imageData: Data,
        capturedAt: Date
    ) {
        _ = send(
            payload: .cameraFrameResponse(
                PaceCompanionCameraFrameResponse(
                    requestIdentifier: requestIdentifier,
                    imageContentType: PaceCompanionProtocol.cameraFrameContentType,
                    capturedAt: capturedAt,
                    binaryByteCount: imageData.count
                )),
            binaryPayload: imageData
        )
    }

    private func handle(_ browserState: NWBrowser.State) {
        switch browserState {
        case .failed(let error):
            status = .unavailable(error.localizedDescription)
            scheduleReconnect()
        case .cancelled:
            break
        case .ready, .setup, .waiting:
            if framedConnection == nil {
                status = .discovering
            }
        @unknown default:
            status = .unavailable("Unknown local-network discovery state")
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        guard let selectedResult = preferredResult(from: results) else {
            if framedConnection == nil {
                status = .discovering
            }
            return
        }
        discoveredEndpoint = selectedResult.endpoint
        discoveredMacName = serviceName(from: selectedResult.endpoint)
        let macName = discoveredMacName ?? "Pace on Mac"

        if let storedCredential,
            let credentialMaterial = PaceCompanionSecurity.credentialTLSMaterial(
                credential: storedCredential.credential,
                deviceIdentifier: storedCredential.localDeviceIdentifier
            )
        {
            connect(
                endpoint: selectedResult.endpoint,
                macName: macName,
                tlsMaterial: credentialMaterial,
                isPairingConnection: false
            )
        } else {
            status = .pairingAvailable(macName: macName)
        }
    }

    private func preferredResult(from results: Set<NWBrowser.Result>) -> NWBrowser.Result? {
        if let storedCredential {
            return results.first(where: {
                serviceName(from: $0.endpoint) == storedCredential.remoteName
            }) ?? results.first
        }
        return results.first
    }

    private func serviceName(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        return name
    }

    private func connect(
        endpoint: NWEndpoint,
        macName: String,
        tlsMaterial: PaceCompanionTLSMaterial?,
        isPairingConnection: Bool
    ) {
        guard framedConnection == nil, let tlsMaterial else { return }
        reconnectTask?.cancel()
        activeSessionIdentifier = UUID().uuidString
        status = .connecting(macName: macName)

        let connection = NWConnection(
            to: endpoint,
            using: PaceCompanionTLSParameters.make(materials: [tlsMaterial])
        )
        let framedConnection = PaceCompanionFramedConnection(
            connection: connection,
            queueLabel: "com.pace.pad.connection"
        )
        framedConnection.onStateChange = { [weak self, weak framedConnection] state in
            guard let self, self.framedConnection === framedConnection else { return }
            switch state {
            case .ready:
                lastHeartbeatReceivedAt = Date()
                reconnectAttemptCount = 0
                if isPairingConnection {
                    sendPairRequest()
                } else {
                    sendSessionHello()
                }
                startHeartbeatLoop()
            case .failed(let reason):
                heartbeatTask?.cancel()
                heartbeatTask = nil
                self.framedConnection = nil
                status = .unavailable(reason)
                scheduleReconnect()
            case .cancelled:
                heartbeatTask?.cancel()
                heartbeatTask = nil
                self.framedConnection = nil
                status = .discovering
                scheduleReconnect()
            case .preparing:
                break
            }
        }
        framedConnection.onFrameReceived = { [weak self, weak framedConnection] frame in
            guard let self, self.framedConnection === framedConnection else { return }
            handle(frame)
        }
        self.framedConnection = framedConnection
        framedConnection.start()
    }

    private func sendPairRequest() {
        _ = send(
            payload: .pairRequest(
                PaceCompanionPairRequest(
                    deviceIdentifier: deviceIdentifier,
                    deviceName: UIDevice.current.name
                )))
    }

    private func sendSessionHello() {
        guard let storedCredential,
            let authenticationProof = PaceCompanionSecurity.sessionAuthenticationProof(
                credential: storedCredential.credential,
                serverIdentifier: storedCredential.remoteIdentifier,
                deviceIdentifier: deviceIdentifier,
                sessionIdentifier: activeSessionIdentifier
            )
        else {
            unpair()
            return
        }
        _ = send(
            payload: .sessionHello(
                PaceCompanionSessionHello(
                    deviceIdentifier: deviceIdentifier,
                    deviceName: UIDevice.current.name,
                    authenticationProof: authenticationProof
                )))
    }

    private func handle(_ frame: PaceCompanionWireFrame) {
        guard frame.message.belongs(toSessionIdentifier: activeSessionIdentifier) else { return }
        switch frame.message.payload {
        case .pairResponse(let pairResponse):
            let newCredential = PaceCompanionStoredCredential(
                remoteIdentifier: pairResponse.serverIdentifier,
                remoteName: pairResponse.serverName,
                localDeviceIdentifier: deviceIdentifier,
                credential: pairResponse.deviceCredential
            )
            guard
                PaceCompanionKeychain.store(
                    newCredential,
                    serviceIdentifier: Self.keychainServiceIdentifier,
                    accountName: Self.keychainAccountName
                )
            else {
                status = .unavailable("The pairing credential could not be saved in Keychain.")
                return
            }
            storedCredential = newCredential
            status = .connected(macName: pairResponse.serverName)
        case .heartbeat(let heartbeat):
            lastHeartbeatReceivedAt = Date()
            if heartbeat.acknowledgedSequenceNumber == nil {
                _ = send(
                    payload: .heartbeat(
                        PaceCompanionHeartbeat(
                            sequenceNumber: outgoingHeartbeatSequenceNumber,
                            acknowledgedSequenceNumber: heartbeat.sequenceNumber
                        )))
            }
            if case .connected = status {
                break
            }
            status = .connected(macName: storedCredential?.remoteName ?? discoveredMacName ?? "Pace on Mac")
        case .cameraFrameRequest(let request):
            onCameraFrameRequested?(request)
        case .interactionState, .assistantResponse, .proactiveMessage, .error:
            onMessage?(frame.message.payload)
        case .pairRequest, .unpairRequest, .sessionHello, .userUtterance, .presenceChanged,
            .cameraFrameResponse, .privacyStateChanged:
            break
        }
    }

    @discardableResult
    private func send(
        payload: PaceCompanionMessagePayload,
        binaryPayload: Data = Data()
    ) -> Bool {
        guard let framedConnection else { return false }
        do {
            try framedConnection.send(
                PaceCompanionWireFrame(
                    message: PaceCompanionMessage(
                        payload: payload,
                        sessionIdentifier: activeSessionIdentifier
                    ),
                    binaryPayload: binaryPayload
                ))
            return true
        } catch {
            status = .unavailable("The local connection could not send that message.")
            return false
        }
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
                    framedConnection?.cancel()
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

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectAttemptCount += 1
        let delaySeconds = PaceCompanionConnectionPolicy.reconnectDelaySeconds(
            afterAttemptNumber: reconnectAttemptCount
        )
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self, !Task.isCancelled else { return }
            reconnectTask = nil
            start()
        }
    }
}
