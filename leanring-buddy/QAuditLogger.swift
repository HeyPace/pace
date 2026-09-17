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
        self.executionSummary = executionSummary.map { Self.boundedSafeField(QSecretRedactor.redact($0)) }
        self.error = error.map { Self.boundedSafeField(QSecretRedactor.redact($0)) }
    }

    /// Audit records must carry safe, bounded metadata — never near-verbatim
    /// user content. `QSecretRedactor.redact` only strips *credential-shaped*
    /// substrings (API keys, PEM blocks, password/token assignments) by its
    /// own design; it cannot and does not generically identify arbitrary
    /// sensitive free text. Confirmed in production: `screen.ocr` and
    /// `agent.completed` entries reached 2,000-5,000+ characters of
    /// near-verbatim OCR'd screen text / spoken response text, none of which
    /// is credential-shaped and so passed the redactor unchanged.
    ///
    /// This is the second, independent guard: redact first (so a credential
    /// pattern anywhere in the string is still caught before truncation could
    /// cut it in half), then hard-cap the length. A truncated field keeps a
    /// short, genuinely useful prefix for a human skimming the log, plus a
    /// SHA-256 hash of the FULL (post-redaction) string and its original
    /// length — real forensic value (an investigator can confirm two records
    /// came from identical content, or match a hash against other evidence)
    /// without ever persisting the sensitive content itself.
    private static let maxAuditFieldCharacterCount = 200

    private static func boundedSafeField(_ redactedValue: String) -> String {
        guard redactedValue.count > maxAuditFieldCharacterCount else { return redactedValue }
        let visiblePrefix = String(redactedValue.prefix(maxAuditFieldCharacterCount))
        let fullContentDigest = SHA256.hash(data: Data(redactedValue.utf8))
        let fullContentHash = fullContentDigest.map { String(format: "%02hhx", $0) }.joined()
        return "\(visiblePrefix)… [truncated: \(redactedValue.count) chars total, sha256=\(fullContentHash)]"
    }

    /// For call sites that KNOW they're about to hand audit logging a
    /// specific, named category of user content that must never appear even
    /// as a truncated excerpt (raw OCR/screen text, raw model prompts or
    /// responses, raw document contents) — construct a pure-metadata
    /// descriptor instead, up front, rather than relying on
    /// `boundedSafeField`'s generic truncate-and-hash backstop to catch it
    /// after the fact. Both use the identical hash/length evidence shape so
    /// there is exactly one "how do we describe omitted content" pattern in
    /// this codebase, not two competing ones.
    public static func safeDescriptor(omittedContent content: String, label: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        let hash = digest.map { String(format: "%02hhx", $0) }.joined()
        return "[\(label) omitted from audit log — \(content.count) chars, sha256=\(hash)]"
    }
}

// MARK: - Audit Logger

public final class QAuditLogger: @unchecked Sendable {
    public static let shared = QAuditLogger()

    private let lock = NSLock()
    private var inMemoryRecords: [QAuditRecord] = []
    private let maxMemoryRecords = 1000
    private let logFileURL: URL?

    /// Bounded rotation: confirmed in production that this file grows
    /// without limit otherwise (reached ~717 MB / 1.58M lines from ordinary
    /// use). 25 MB keeps each file a manageable size for review while
    /// `maxRotatedFileCount` retains a bounded amount of real history for
    /// genuine forensic value — this is retention, not deletion-on-write.
    private let maxLogFileSizeBytes = 25 * 1024 * 1024
    private let maxRotatedFileCount = 3

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
                        // Rotation happens BEFORE the write, and is itself
                        // entirely best-effort (every step uses `try?`): if
                        // any step fails (e.g. a rename fails), the original
                        // file is simply left in place and the write below
                        // still proceeds against it. Auditing itself must
                        // never stop just because rotation couldn't.
                        rotateLogFileIfNeeded(at: logFileURL)

                        if FileManager.default.fileExists(atPath: logFileURL.path) {
                            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                                handle.seekToEndOfFile()
                                handle.write(lineData)
                                handle.closeFile()
                            }
                        } else {
                            try? lineData.write(to: logFileURL, options: .atomic)
                            // Owner-only: this file can carry redacted-but-
                            // still-meaningful operational text (see
                            // boundedSafeField). Applied on every fresh file
                            // (first-ever creation and every post-rotation
                            // recreation) so rotated logs never regress to
                            // more permissive default bits.
                            try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: logFileURL.path
                            )
                        }
                    }
                }
            } catch {
                // Fail-safe: Audit file writing error must not crash the agent
            }
        }
    }

    /// Best-effort size-bounded rotation. Every filesystem operation here
    /// uses `try?` deliberately: a failure at any step (permissions, disk
    /// full, concurrent access) must leave the existing log file usable and
    /// must never throw out of `record()` — rotation failing is acceptable,
    /// auditing failing is not.
    private func rotateLogFileIfNeeded(at logFileURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let currentFileSize = attributes[.size] as? Int,
              currentFileSize >= maxLogFileSizeBytes
        else {
            return
        }

        let fileManager = FileManager.default

        // Drop whatever is at the oldest retained slot, then shift every
        // remaining rotated file up by one, oldest first, so no rename ever
        // overwrites a file still holding real history.
        let oldestRetainedPath = "\(logFileURL.path).\(maxRotatedFileCount)"
        try? fileManager.removeItem(atPath: oldestRetainedPath)

        var index = maxRotatedFileCount - 1
        while index >= 1 {
            let sourcePath = "\(logFileURL.path).\(index)"
            let destinationPath = "\(logFileURL.path).\(index + 1)"
            if fileManager.fileExists(atPath: sourcePath) {
                try? fileManager.moveItem(atPath: sourcePath, toPath: destinationPath)
            }
            index -= 1
        }

        let firstRotatedPath = "\(logFileURL.path).1"
        try? fileManager.moveItem(atPath: logFileURL.path, toPath: firstRotatedPath)
        // Preserve the same restrictive permissions on the rotated-out file
        // — it still holds real (redacted, bounded) audit content.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: firstRotatedPath)
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
