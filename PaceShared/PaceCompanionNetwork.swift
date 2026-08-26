import Dispatch
import Foundation
import Network
import Security

nonisolated enum PaceCompanionTLSParameters {
    static func make(materials: [PaceCompanionTLSMaterial]) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        for material in materials {
            let preSharedKey = material.preSharedKey.withUnsafeBytes { keyBytes in
                DispatchData(bytes: keyBytes)
            }
            let identity = material.identity.withUnsafeBytes { identityBytes in
                DispatchData(bytes: identityBytes)
            }
            sec_protocol_options_add_pre_shared_key(
                tlsOptions.securityProtocolOptions,
                preSharedKey as dispatch_data_t,
                identity as dispatch_data_t
            )
        }
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv13
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = Int(PaceCompanionProtocol.heartbeatIntervalSeconds)

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        return parameters
    }
}

@MainActor
final class PaceCompanionFramedConnection {
    enum State: Equatable {
        case preparing
        case ready
        case failed(String)
        case cancelled
    }

    var onStateChange: ((State) -> Void)?
    var onFrameReceived: ((PaceCompanionWireFrame) -> Void)?

    private let connection: NWConnection
    private let networkQueue: DispatchQueue
    private var frameStreamDecoder = PaceCompanionFrameStreamDecoder()
    private var messageDeduplicator = PaceCompanionMessageDeduplicator()
    private var hasStarted = false

    init(connection: NWConnection, queueLabel: String) {
        self.connection = connection
        networkQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor [weak self] in
                self?.handle(connectionState)
            }
        }
        connection.start(queue: networkQueue)
        receiveNextChunk()
    }

    func send(_ frame: PaceCompanionWireFrame) throws {
        let encodedFrame = try PaceCompanionFrameCodec.encode(frame)
        connection.send(
            content: encodedFrame,
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.onStateChange?(.failed(error.localizedDescription))
                }
            }
        )
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] receivedData, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let receivedData, !receivedData.isEmpty {
                    do {
                        let decodedFrames = try frameStreamDecoder.append(receivedData)
                        for decodedFrame in decodedFrames
                        where messageDeduplicator.shouldAccept(
                            messageIdentifier: decodedFrame.message.messageIdentifier
                        ) {
                            onFrameReceived?(decodedFrame)
                        }
                    } catch {
                        onStateChange?(.failed("Invalid companion frame: \(error)"))
                        cancel()
                        return
                    }
                }
                if let error {
                    onStateChange?(.failed(error.localizedDescription))
                    return
                }
                if isComplete {
                    onStateChange?(.cancelled)
                    return
                }
                receiveNextChunk()
            }
        }
    }

    private func handle(_ connectionState: NWConnection.State) {
        switch connectionState {
        case .setup, .waiting:
            onStateChange?(.preparing)
        case .preparing:
            onStateChange?(.preparing)
        case .ready:
            onStateChange?(.ready)
        case .failed(let error):
            onStateChange?(.failed(error.localizedDescription))
        case .cancelled:
            onStateChange?(.cancelled)
        @unknown default:
            onStateChange?(.failed("Unknown local-network state"))
        }
    }
}
