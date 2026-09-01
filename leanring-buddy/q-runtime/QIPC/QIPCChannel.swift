//
//  QIPCChannel.swift
//  leanring-buddy
//
//  Q Security Architecture — Authenticated IPC Channel & In-Memory Transport (Phase 1D.3).
//

import Foundation
import CryptoKit

public enum QIPCError: Error, Equatable, Sendable {
    case unauthenticated(String)
    case messageTampered(String)
    case timeout(String)
    case receiverUnavailable(String)
    case handlerNotFound(String)
    case channelClosed
}

// MARK: - In-Memory Local IPC Hub

public final class QIPCHub: @unchecked Sendable {
    public static let shared = QIPCHub()

    private let lock = NSRecursiveLock()
    private var channels: [String: QIPCChannel] = [:]
    private var defaultKey = SymmetricKey(size: .bits256)

    public func getSharedKey() -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        return defaultKey
    }

    public func register(endpoint: String, channel: QIPCChannel) {
        lock.lock()
        let old = channels.removeValue(forKey: endpoint)
        channels[endpoint] = channel
        lock.unlock()
        _ = old
    }

    public func unregister(endpoint: String, channel: QIPCChannel? = nil) {
        lock.lock()
        var old: QIPCChannel? = nil
        if let channel {
            if channels[endpoint] === channel {
                old = channels.removeValue(forKey: endpoint)
            }
        } else {
            old = channels.removeValue(forKey: endpoint)
        }
        lock.unlock()
        _ = old
    }

    public func getChannel(for endpoint: String) -> QIPCChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channels[endpoint]
    }

    public func reset() {
        lock.lock()
        let oldChannels = channels
        channels = [:]
        defaultKey = SymmetricKey(size: .bits256)
        lock.unlock()
        _ = oldChannels
    }
}

// MARK: - Authenticated Channel Endpoint

public final class QIPCChannel: @unchecked Sendable {
    public let endpointName: String
    private let sharedKey: SymmetricKey
    private let lock = NSRecursiveLock()
    private var sequenceNumber: UInt64 = 0
    private var handlers: [QIPCMessageType: (QIPCEnvelope) async -> QIPCMessage?] = [:]
    private var pendingContinuations: [UUID: CheckedContinuation<QIPCMessage, Error>] = [:]

    public init(endpointName: String, sharedKey: SymmetricKey? = nil) {
        self.endpointName = endpointName
        let key = sharedKey ?? QIPCHub.shared.getSharedKey()
        self.sharedKey = key
        QIPCHub.shared.register(endpoint: endpointName, channel: self)
    }

    deinit {
        QIPCHub.shared.unregister(endpoint: endpointName, channel: self)
    }

    public func registerHandler(
        for type: QIPCMessageType,
        handler: @escaping (QIPCEnvelope) async -> QIPCMessage?
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[type] = handler
    }

    private func nextSequenceNumber() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequenceNumber += 1
        return sequenceNumber
    }

    /// Dispatches a signed envelope to the target receiver endpoint.
    public func send(
        message: QIPCMessage,
        to receiver: String,
        capabilityToken: String? = nil,
        provenanceTag: String? = nil
    ) async throws {
        guard let targetChannel = QIPCHub.shared.getChannel(for: receiver) else {
            throw QIPCError.receiverUnavailable("Receiver '\(receiver)' not found on IPC hub.")
        }

        let envelope = QIPCEnvelope.createSigned(
            sender: endpointName,
            receiver: receiver,
            message: message,
            capabilityToken: capabilityToken,
            provenanceTag: provenanceTag,
            timestamp: Date(),
            sharedKey: sharedKey
        )

        try await targetChannel.receive(envelope: envelope)
    }

    /// Sends a request and awaits a correlated response message.
    public func sendRequest(
        type: QIPCMessageType,
        payload: [String: String],
        to receiver: String,
        capabilityToken: String? = nil,
        provenanceTag: String? = nil,
        timeoutSeconds: TimeInterval = 10.0
    ) async throws -> QIPCMessage {
        let correlationId = UUID()
        let seq = nextSequenceNumber()
        let requestMsg = QIPCMessage(
            messageId: UUID(),
            sequenceNumber: seq,
            correlationId: correlationId,
            type: type,
            payload: payload
        )

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingContinuations[correlationId] = continuation
            lock.unlock()

            Task {
                do {
                    try await self.send(
                        message: requestMsg,
                        to: receiver,
                        capabilityToken: capabilityToken,
                        provenanceTag: provenanceTag
                    )
                } catch {
                    self.lock.lock()
                    let pending = self.pendingContinuations.removeValue(forKey: correlationId)
                    self.lock.unlock()
                    pending?.resume(throwing: error)
                }
            }

            // Timeout watchdog
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self.lock.lock()
                let pending = self.pendingContinuations.removeValue(forKey: correlationId)
                self.lock.unlock()
                pending?.resume(throwing: QIPCError.timeout("Request to '\(receiver)' timed out after \(timeoutSeconds)s."))
            }
        }
    }

    /// Ingests and verifies an incoming envelope.
    public func receive(envelope: QIPCEnvelope) async throws {
        guard envelope.verify(sharedKey: sharedKey) else {
            throw QIPCError.messageTampered("Invalid HMAC signature on envelope from '\(envelope.sender)'.")
        }

        // Check if this is a response to an existing pending continuation
        if let corrId = envelope.message.correlationId {
            lock.lock()
            let continuation = pendingContinuations.removeValue(forKey: corrId)
            lock.unlock()
            if let continuation {
                continuation.resume(returning: envelope.message)
                return
            }
        }

        // Otherwise invoke registered message handler
        lock.lock()
        let handler = handlers[envelope.message.type]
        lock.unlock()

        if let handler {
            if let responseMsg = await handler(envelope) {
                // If handler returned a response message, reply back to sender
                let reply = QIPCMessage(
                    messageId: UUID(),
                    sequenceNumber: nextSequenceNumber(),
                    correlationId: envelope.message.correlationId ?? envelope.message.messageId,
                    type: responseMsg.type,
                    payload: responseMsg.payload
                )
                try await send(
                    message: reply,
                    to: envelope.sender,
                    capabilityToken: envelope.capabilityToken,
                    provenanceTag: envelope.provenanceTag
                )
            }
        }
    }
}
