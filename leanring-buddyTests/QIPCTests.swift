//
//  QIPCTests.swift
//  leanring-buddyTests
//
//  Unit tests for Q Authenticated IPC (Phase 1D.3)
//

import Testing
import Foundation
import CryptoKit
@testable import Pace

@Suite("QIPCTests")
struct QIPCTests {

    @Test("QIPCMessage codable roundtrip")
    func messageCodable() throws {
        let original = QIPCMessage(
            messageId: UUID(),
            sequenceNumber: 42,
            correlationId: UUID(),
            type: .actionRequest,
            payload: ["tool": "fs.read", "path": "/sandbox/data.txt"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QIPCMessage.self, from: data)

        #expect(decoded == original)
    }

    @Test("Envelope HMAC signature verification detects tampering")
    func envelopeTamperingDetection() {
        let key = SymmetricKey(size: .bits256)
        let msg = QIPCMessage(
            type: .intentSubmit,
            payload: ["prompt": "Hello Q"]
        )

        let env = QIPCEnvelope.createSigned(
            sender: "q-desktop",
            receiver: "q-core",
            message: msg,
            sharedKey: key
        )

        // Valid signature passes
        #expect(env.verify(sharedKey: key) == true)

        // Wrong key fails
        let wrongKey = SymmetricKey(size: .bits256)
        #expect(env.verify(sharedKey: wrongKey) == false)

        // Tampered payload message fails
        let tamperedMsg = QIPCMessage(
            messageId: msg.messageId,
            sequenceNumber: msg.sequenceNumber,
            correlationId: msg.correlationId,
            type: .intentSubmit,
            payload: ["prompt": "Malicious override"]
        )
        let tamperedEnv = QIPCEnvelope(
            envelopeId: env.envelopeId,
            sender: env.sender,
            receiver: env.receiver,
            timestamp: env.timestamp,
            capabilityToken: env.capabilityToken,
            provenanceTag: env.provenanceTag,
            message: tamperedMsg,
            signature: env.signature
        )
        #expect(tamperedEnv.verify(sharedKey: key) == false)
    }

    @Test("Bidirectional request-response correlation across authenticated channels")
    func channelRequestResponse() async throws {
        QIPCHub.shared.reset()
        let hubKey = QIPCHub.shared.getSharedKey()

        let coreChannel = QIPCChannel(endpointName: "q-core", sharedKey: hubKey)
        let execChannel = QIPCChannel(endpointName: "q-exec", sharedKey: hubKey)

        // Register handler on execChannel
        execChannel.registerHandler(for: .actionRequest) { envelope in
            let action = envelope.message.payload["tool"] ?? "unknown"
            return QIPCMessage(
                type: .actionResponse,
                payload: ["status": "ok", "executedTool": action]
            )
        }

        // Send request from core to exec
        let response = try await coreChannel.sendRequest(
            type: .actionRequest,
            payload: ["tool": "fs.stat"],
            to: "q-exec",
            timeoutSeconds: 2.0
        )

        #expect(response.type == .actionResponse)
        #expect(response.payload["status"] == "ok")
        #expect(response.payload["executedTool"] == "fs.stat")
    }

    @Test("Channel throws receiverUnavailable when target is missing")
    func missingReceiverError() async {
        QIPCHub.shared.reset()
        let channel = QIPCChannel(endpointName: "q-test")

        do {
            try await channel.send(
                message: QIPCMessage(type: .heartbeat),
                to: "non-existent-endpoint"
            )
            #expect(Bool(false), "Expected error when sending to missing endpoint")
        } catch let err as QIPCError {
            if case .receiverUnavailable = err {
                #expect(true)
            } else {
                #expect(Bool(false), "Expected receiverUnavailable, got \(err)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }
}
