//
//  QIPCEnvelope.swift
//  leanring-buddy
//
//  Q Security Architecture — Authenticated IPC Envelope (Phase 1D.3).
//  Provides tamper-evident HMAC signatures, provenance tagging, and capability binding.
//

import Foundation
import CryptoKit

public struct QIPCEnvelope: Codable, Sendable, Equatable {
    public let envelopeId: UUID
    public let sender: String
    public let receiver: String
    public let timestamp: Date
    public let capabilityToken: String?
    public let provenanceTag: String?
    public let message: QIPCMessage
    public let signature: String

    public init(
        envelopeId: UUID = UUID(),
        sender: String,
        receiver: String,
        timestamp: Date = Date(),
        capabilityToken: String? = nil,
        provenanceTag: String? = nil,
        message: QIPCMessage,
        signature: String
    ) {
        self.envelopeId = envelopeId
        self.sender = sender
        self.receiver = receiver
        self.timestamp = timestamp
        self.capabilityToken = capabilityToken
        self.provenanceTag = provenanceTag
        self.message = message
        self.signature = signature
    }

    public static func canonicalSignaturePayload(
        envelopeId: UUID,
        sender: String,
        receiver: String,
        timestamp: Date,
        capabilityToken: String?,
        provenanceTag: String?,
        message: QIPCMessage
    ) -> Data {
        let ts = Int64(timestamp.timeIntervalSince1970)
        let cap = capabilityToken ?? "none"
        let prov = provenanceTag ?? "none"
        let msgType = message.type.rawValue
        let msgId = message.messageId.uuidString
        let corrId = message.correlationId?.uuidString ?? "none"
        let sortedPayload = message.payload.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        let raw = "\(envelopeId.uuidString)|\(sender)|\(receiver)|\(ts)|\(cap)|\(prov)|\(msgType)|\(msgId)|\(corrId)|\(sortedPayload)"
        return Data(raw.utf8)
    }

    public static func createSigned(
        sender: String,
        receiver: String,
        message: QIPCMessage,
        capabilityToken: String? = nil,
        provenanceTag: String? = nil,
        timestamp: Date = Date(),
        sharedKey: SymmetricKey
    ) -> QIPCEnvelope {
        let envId = UUID()
        let payloadData = canonicalSignaturePayload(
            envelopeId: envId,
            sender: sender,
            receiver: receiver,
            timestamp: timestamp,
            capabilityToken: capabilityToken,
            provenanceTag: provenanceTag,
            message: message
        )
        let mac = HMAC<SHA256>.authenticationCode(for: payloadData, using: sharedKey)
        let sigHex = mac.map { String(format: "%02hhx", $0) }.joined()

        return QIPCEnvelope(
            envelopeId: envId,
            sender: sender,
            receiver: receiver,
            timestamp: timestamp,
            capabilityToken: capabilityToken,
            provenanceTag: provenanceTag,
            message: message,
            signature: sigHex
        )
    }

    public func verify(sharedKey: SymmetricKey) -> Bool {
        let expectedPayload = Self.canonicalSignaturePayload(
            envelopeId: envelopeId,
            sender: sender,
            receiver: receiver,
            timestamp: timestamp,
            capabilityToken: capabilityToken,
            provenanceTag: provenanceTag,
            message: message
        )
        guard let expectedSignatureData = Data(hexString: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(expectedSignatureData, authenticating: expectedPayload, using: sharedKey)
    }
}

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(i, offsetBy: 2)
            let bytes = String(hexString[i..<nextIndex])
            if let num = UInt8(bytes, radix: 16) {
                data.append(num)
            } else {
                return nil
            }
            i = nextIndex
        }
        self = data
    }
}
