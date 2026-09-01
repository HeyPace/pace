//
//  QIPCMessage.swift
//  leanring-buddy
//
//  Q Security Architecture — Strongly Typed IPC Message Definitions (Phase 1D.3).
//

import Foundation

public enum QIPCMessageType: String, Codable, Sendable {
    case intentSubmit = "intent.submit"
    case intentResponse = "intent.response"
    case actionRequest = "action.request"
    case actionResponse = "action.response"
    case permissionPrompt = "permission.prompt"
    case permissionDecision = "permission.decision"
    case bridgeCall = "bridge.call"
    case bridgeResult = "bridge.result"
    case heartbeat = "system.heartbeat"
}

public struct QIPCMessage: Codable, Sendable, Equatable {
    public let messageId: UUID
    public let sequenceNumber: UInt64
    public let correlationId: UUID?
    public let type: QIPCMessageType
    public let payload: [String: String]

    public init(
        messageId: UUID = UUID(),
        sequenceNumber: UInt64 = 0,
        correlationId: UUID? = nil,
        type: QIPCMessageType,
        payload: [String: String] = [:]
    ) {
        self.messageId = messageId
        self.sequenceNumber = sequenceNumber
        self.correlationId = correlationId
        self.type = type
        self.payload = payload
    }
}
