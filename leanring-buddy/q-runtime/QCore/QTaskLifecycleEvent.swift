//
//  QTaskLifecycleEvent.swift
//  leanring-buddy
//
//  Q Security Architecture — Immutable Task Lifecycle Events (Phase 2D).
//  Provides event-sourced task tracking with schema versioning, strict timestamping,
//  and provenance preservation.
//

import Foundation

public enum QTaskLifecycleEventType: String, Codable, Sendable, Equatable {
    case taskCreated = "task.created"
    case taskPlanned = "task.planned"
    case stepStarted = "task.step.started"
    case stepCompleted = "task.step.completed"
    case stepFailed = "task.step.failed"
    case stepVerified = "task.step.verified"
    case goalEvaluated = "task.goal.evaluated"
    case replanRequested = "task.replan.requested"
    case replanCreated = "task.replan.created"
    case permissionRequested = "task.permission.requested"
    case permissionGranted = "task.permission.granted"
    case permissionDenied = "task.permission.denied"
    case securityBlocked = "task.security.blocked"
    case taskPaused = "task.paused"
    case taskResumed = "task.resumed"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
    case taskAborted = "task.aborted"
}

public struct QTaskLifecycleEvent: Codable, Sendable, Equatable {
    public let eventId: String
    public let taskId: String
    public let sessionId: String
    public let eventType: QTaskLifecycleEventType
    public let timestamp: Date
    public let payload: [String: String]
    public let provenance: String
    public let schemaVersion: Int

    public init(
        eventId: String = UUID().uuidString,
        taskId: String,
        sessionId: String,
        eventType: QTaskLifecycleEventType,
        timestamp: Date = Date(),
        payload: [String: String] = [:],
        provenance: String = "trusted:system",
        schemaVersion: Int = 1
    ) {
        self.eventId = eventId
        self.taskId = taskId
        self.sessionId = sessionId
        self.eventType = eventType
        self.timestamp = timestamp
        self.payload = payload
        self.provenance = provenance
        self.schemaVersion = schemaVersion
    }
}
