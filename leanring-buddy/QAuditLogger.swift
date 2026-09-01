//
//  QAuditLogger.swift
//  leanring-buddy
//
//  Q Security Architecture — Append-Only Local Audit Log & Secret Redactor (Phase 1c.5).
//  Records structured audit events with cryptographic argument hashing and
//  aggressive pattern-based secret redaction (API keys, private keys, passwords).
//

import Foundation
import CryptoKit

// MARK: - Secret Redactor

public enum QSecretRedactor {

    private static let secretRegexes: [NSRegularExpression] = [
        // OpenAI / Anthropic / Generic AI API Keys
        try! NSRegularExpression(pattern: #"(sk-[a-zA-Z0-9_-]{20,})"#, options: []),
        try! NSRegularExpression(pattern: #"(ant-[a-zA-Z0-9_-]{20,})"#, options: []),
        // Google AI Studio / Cloud Keys
        try! NSRegularExpression(pattern: #"(AIza[0-9A-Za-z-_]{35})"#, options: []),
        // GitHub Personal Access Tokens
        try! NSRegularExpression(pattern: #"(ghp_[a-zA-Z0-9]{36})"#, options: []),
        try! NSRegularExpression(pattern: #"(github_pat_[a-zA-Z0-9_]{40,})"#, options: []),
        // Slack Tokens
        try! NSRegularExpression(pattern: #"(xox[baprs]-[0-9A-Za-z-]+)"#, options: []),
        // Bearer Authorization Headers
        try! NSRegularExpression(pattern: #"(?i)Bearer\s+([a-zA-Z0-9_\-\.]{15,})"#, options: []),
        // PEM Private Keys (RSA, EC, PKCS8)
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----"#, options: []),
        // Generic Password / Secret / Token assignments in JSON, YAML, or CLI args
        try! NSRegularExpression(pattern: #"(?i)["']?(password|secret|token|api_?key)["']?\s*[:=]\s*["']?([^\s"',;]+)["']?"#, options: [])
    ]

    /// Redacts all detected credentials, private keys, and tokens from the string.
    public static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var result = input

        for regex in secretRegexes {
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length))
            // Replace in reverse order to preserve string indices
            for match in matches.reversed() {
                let matchRange = match.range
                if match.numberOfRanges > 1 && match.range(at: match.numberOfRanges - 1).location != NSNotFound {
                    // Replace the captured secret group
                    let secretRange = match.range(at: match.numberOfRanges - 1)
                    result = (result as NSString).replacingCharacters(in: secretRange, with: "[REDACTED_SECRET]")
                } else {
                    // Replace entire match (e.g. PEM block)
                    result = (result as NSString).replacingCharacters(in: matchRange, with: "[REDACTED_SECRET]")
                }
            }
        }

        return result
    }
}

// MARK: - Audit Record

public struct QAuditRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let sessionId: String
    public let taskId: String
    public let tool: String
    public let capabilityId: UUID?
    public let riskLevel: QCapabilityLevel
    public let argumentsHash: String
    public let authorizationResult: String
    public let provenance: String
    public let executionSummary: String?
    public let error: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionId: String,
        taskId: String,
        tool: String,
        capabilityId: UUID? = nil,
        riskLevel: QCapabilityLevel,
        rawArguments: String,
        authorizationResult: String,
        provenance: String,
        executionSummary: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.taskId = taskId
        self.tool = tool
        self.capabilityId = capabilityId
        self.riskLevel = riskLevel

        // Hash arguments with SHA-256 so raw arguments with sensitive info are not stored plaintext
        let digest = SHA256.hash(data: Data(rawArguments.utf8))
        self.argumentsHash = digest.map { String(format: "%02hhx", $0) }.joined()

        self.authorizationResult = authorizationResult
        self.provenance = provenance
        self.executionSummary = executionSummary.map { QSecretRedactor.redact($0) }
        self.error = error.map { QSecretRedactor.redact($0) }
    }
}

// MARK: - Audit Logger

public final class QAuditLogger: @unchecked Sendable {
    public static let shared = QAuditLogger()

    private let lock = NSLock()
    private var inMemoryRecords: [QAuditRecord] = []
    private let maxMemoryRecords = 1000
    private let logFileURL: URL?

    public init(customLogURL: URL? = nil) {
        if let custom = customLogURL {
            self.logFileURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let paceDir = appSupport?.appendingPathComponent("Pace", isDirectory: true)
            if let paceDir = paceDir {
                try? FileManager.default.createDirectory(at: paceDir, withIntermediateDirectories: true)
                self.logFileURL = paceDir.appendingPathComponent("q-audit.log")
            } else {
                self.logFileURL = nil
            }
        }
    }

    public func record(_ record: QAuditRecord) {
        lock.lock()
        defer { lock.unlock() }

        inMemoryRecords.append(record)
        if inMemoryRecords.count > maxMemoryRecords {
            inMemoryRecords.removeFirst(inMemoryRecords.count - maxMemoryRecords)
        }

        // Append line to disk if log file is configured
        if let logFileURL = logFileURL {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(record)
                if let line = String(data: data, encoding: .utf8) {
                    let logLine = line + "\n"
                    if let lineData = logLine.data(using: .utf8) {
                        if FileManager.default.fileExists(atPath: logFileURL.path) {
                            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                                handle.seekToEndOfFile()
                                handle.write(lineData)
                                handle.closeFile()
                            }
                        } else {
                            try? lineData.write(to: logFileURL, options: .atomic)
                        }
                    }
                }
            } catch {
                // Fail-safe: Audit file writing error must not crash the agent
            }
        }
    }

    public func getRecentRecords(limit: Int = 100) -> [QAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(limit, inMemoryRecords.count)
        return Array(inMemoryRecords.suffix(count))
    }

    public func clearMemory() {
        lock.lock()
        defer { lock.unlock() }
        inMemoryRecords.removeAll()
    }
}
