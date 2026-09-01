//
//  QProvenance.swift
//  leanring-buddy
//
//  Q Security Architecture — Provenance & Taint Tracking Foundation (Phase 1c.6).
//  Models data origin hierarchy, context taint propagation, and
//  enforces automatic capability downgrade when untrusted inputs are present.
//

import Foundation

// MARK: - Provenance Kind

public enum QProvenanceKind: Codable, Sendable, Equatable, CustomStringConvertible {
    case trustedUser(channel: String)
    case trustedLocal
    case trustedSystem
    case untrustedWeb(url: String?)
    case untrustedFile(path: String?)
    case untrustedScreen
    case untrustedOCR
    case untrustedTool(toolName: String)
    case untrustedPhone

    public var isTrusted: Bool {
        switch self {
        case .trustedUser, .trustedLocal, .trustedSystem:
            return true
        case .untrustedWeb, .untrustedFile, .untrustedScreen, .untrustedOCR, .untrustedTool, .untrustedPhone:
            return false
        }
    }

    public var rawTag: String {
        switch self {
        case .trustedUser(let channel):
            return "trusted:user:\(channel)"
        case .trustedLocal:
            return "trusted:local"
        case .trustedSystem:
            return "trusted:system"
        case .untrustedWeb(let url):
            return "untrusted:web\(url.map { ":\($0)" } ?? "")"
        case .untrustedFile(let path):
            return "untrusted:file\(path.map { ":\($0)" } ?? "")"
        case .untrustedScreen:
            return "untrusted:screen"
        case .untrustedOCR:
            return "untrusted:ocr"
        case .untrustedTool(let name):
            return "untrusted:tool:\(name)"
        case .untrustedPhone:
            return "untrusted:phone"
        }
    }

    public var description: String { rawTag }
}

// MARK: - Provenance Tag

public struct QProvenanceTag: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: QProvenanceKind
    public let sourceId: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: QProvenanceKind,
        sourceId: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sourceId = sourceId
        self.timestamp = timestamp
    }

    public var isTrusted: Bool { kind.isTrusted }
}

// MARK: - Taint-Tracked Context Item

public struct QContextItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let content: String
    public let provenance: QProvenanceTag

    public init(
        id: UUID = UUID(),
        content: String,
        provenance: QProvenanceTag
    ) {
        self.id = id
        self.content = content
        self.provenance = provenance
    }
}

// MARK: - Task Context with Taint Propagation

public struct QTaskContext: Sendable, Equatable {
    public let taskId: String
    public private(set) var items: [QContextItem] = []

    public init(taskId: String) {
        self.taskId = taskId
    }

    public mutating func append(content: String, provenance: QProvenanceKind, sourceId: String = "context") {
        let tag = QProvenanceTag(kind: provenance, sourceId: sourceId)
        let item = QContextItem(content: content, provenance: tag)
        items.append(item)
    }

    public mutating func append(item: QContextItem) {
        items.append(item)
    }

    /// Context is tainted if any context item originated from an untrusted source
    public var isTainted: Bool {
        items.contains { !$0.provenance.isTrusted }
    }

    /// List of all untrusted provenance tags currently present in this context
    public var untrustedSources: [QProvenanceTag] {
        items.compactMap { $0.provenance.isTrusted ? nil : $0.provenance }
    }

    /// Merges another context into this one, propagating taint
    public mutating func merge(from other: QTaskContext) {
        items.append(contentsOf: other.items)
    }

    /// Clear all items
    public mutating func clear() {
        items.removeAll()
    }
}
