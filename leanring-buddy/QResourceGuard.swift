//
//  QResourceGuard.swift
//  leanring-buddy
//
//  Q Security Architecture — Resource Guard & Path Jail (Phase 1c.4).
//  Provides strict path canonicalization, symlink resolution, path jail confinement,
//  and absolute denylist enforcement against credential and system directories.
//

import Foundation

public enum QPathValidationOutcome: Equatable, Sendable {
    case allowed(canonicalPath: String)
    case denied(reason: String, violation: QViolationKind)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var canonicalPath: String? {
        if case .allowed(let path) = self { return path }
        return nil
    }
}

public enum QResourceGuard {

    private static let homeDirectory: String = {
        let home = NSHomeDirectory()
        return (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? home
    }()

    /// Absolute Denylist Directory Patterns (canonical path prefixes)
    public static var absoluteDenylistDirectoryPrefixes: [String] {
        let home = homeDirectory
        return [
            "\(home)/Library/Keychains",
            "\(home)/.ssh",
            "\(home)/.aws",
            "\(home)/.gnupg",
            "\(home)/.config/gh",
            "\(home)/Library/Application Support/Google/Chrome",
            "\(home)/Library/Application Support/Arc/User Data",
            "\(home)/Library/Application Support/BraveSoftware",
            "\(home)/Library/Application Support/Firefox",
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/private/etc",
            "/etc"
        ]
    }

    /// Sensitive Filename and Extension Patterns
    public static let sensitiveFilenamePatterns: [String] = [
        ".env",
        ".env.",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        "id_dsa",
        ".npmrc",
        ".pypirc"
    ]

    public static let sensitiveExtensions: Set<String> = [
        "pem",
        "key",
        "pkcs12",
        "p12",
        "pfx",
        "kdbx",
        "keystore"
    ]

    // MARK: - Path Canonicalization

    /// Resolves `~`, removes `..` and `.`, and follows all symlinks to their ultimate target via realpath.
    /// Handles both existing files and non-existent new target paths.
    public static func canonicalize(path: String) -> String {
        var expanded = path
        if expanded.hasPrefix("~") {
            expanded = (homeDirectory as NSString).appendingPathComponent(String(expanded.dropFirst(1)))
        }

        let standardized = (expanded as NSString).standardizingPath

        // If the path exists directly, realpath resolves all symlinks
        if let cString = realpath(standardized, nil) {
            defer { free(cString) }
            return String(cString: cString)
        }

        // For non-existent files (e.g. creating a new file), walk up to the nearest existing ancestor
        var parent = standardized
        var suffix: [String] = []

        while parent != "/" && !parent.isEmpty {
            let lastComponent = (parent as NSString).lastPathComponent
            suffix.insert(lastComponent, at: 0)
            parent = (parent as NSString).deletingLastPathComponent

            if let cString = realpath(parent, nil) {
                defer { free(cString) }
                var canonicalParent = String(cString: cString)
                for part in suffix {
                    canonicalParent = (canonicalParent as NSString).appendingPathComponent(part)
                }
                return (canonicalParent as NSString).standardizingPath
            }
        }

        return standardized
    }

    // MARK: - Validation Against Denylist & Jails

    /// Validates an input path against the absolute denylist, sensitive file rules, and optional jail scope.
    public static func validate(
        path: String,
        allowedJailPrefix: String? = nil
    ) -> QPathValidationOutcome {
        let canonical = canonicalize(path: path)

        // 1. Check Absolute Denylist Prefixes
        for denylistPrefix in absoluteDenylistDirectoryPrefixes {
            let normalizedDeny = denylistPrefix.hasSuffix("/") ? denylistPrefix : denylistPrefix + "/"
            let normalizedTarget = canonical.hasSuffix("/") ? canonical : canonical + "/"

            if normalizedTarget.hasPrefix(normalizedDeny) || canonical == denylistPrefix {
                return .denied(
                    reason: "Access to protected directory '\(denylistPrefix)' is absolutely denied.",
                    violation: .absoluteDenylist
                )
            }
        }

        // 2. Check Sensitive Filename Patterns & Extensions
        let filename = (canonical as NSString).lastPathComponent
        for sensitivePattern in sensitiveFilenamePatterns {
            if filename == sensitivePattern || filename.hasPrefix(sensitivePattern) {
                return .denied(
                    reason: "Access to credential file pattern '\(sensitivePattern)' is absolutely denied.",
                    violation: .absoluteDenylist
                )
            }
        }

        let ext = (canonical as NSString).pathExtension.lowercased()
        if sensitiveExtensions.contains(ext) {
            return .denied(
                reason: "Access to sensitive key/certificate extension '.\(ext)' is absolutely denied.",
                violation: .absoluteDenylist
            )
        }

        // 3. Check Jail Confinement (if a jail root was specified)
        if let jail = allowedJailPrefix {
            let canonicalJail = canonicalize(path: jail)
            guard isContained(canonical, within: canonicalJail) else {
                return .denied(
                    reason: "Path '\(canonical)' escapes the permitted jail scope '\(canonicalJail)'.",
                    violation: .scopeViolation
                )
            }
        }

        return .allowed(canonicalPath: canonical)
    }

    /// True when `canonicalTarget` is `canonicalRoot` itself or a descendant of it.
    /// Both paths MUST already be canonicalized (via `canonicalize(path:)`) before
    /// calling this — it performs a plain prefix comparison and does no path
    /// resolution of its own.
    private static func isContained(_ canonicalTarget: String, within canonicalRoot: String) -> Bool {
        let normalizedRoot = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        let normalizedTarget = canonicalTarget.hasSuffix("/") ? canonicalTarget : canonicalTarget + "/"
        return normalizedTarget.hasPrefix(normalizedRoot) || canonicalTarget == canonicalRoot
    }

    // MARK: - Filesystem Capability Sandbox (fs.read / fs.write_sandbox)
    //
    // The two autonomous filesystem capabilities (`fs.read`, `fs.write_sandbox`)
    // are registered at Level 0/1 — auto-allowed by QPermissionGate with no user
    // approval. Unlike `validate(path:allowedJailPrefix:)` above (a denylist that
    // callers may OPTIONALLY jail), this is a fail-closed ALLOWLIST: the single
    // fixed root below is the only location these two capabilities may ever
    // reach, full stop. It is a source-level constant — never derived from model
    // output, task parameters, Info.plist, or any other input an attacker or a
    // compromised/malicious model could influence.

    /// The sole authorized root for `fs.read` / `fs.write_sandbox`. Created on
    /// first access if missing. Resolved once and cached — resolving on every
    /// call would let a change to the real directory's identity after launch
    /// silently redefine the boundary out from under an already-running process.
    public static let filesystemCapabilitySandboxRoot: String = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        let base = appSupport ?? URL(fileURLWithPath: homeDirectory)
        let root = base.appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("q-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return canonicalize(path: root.path)
    }()

    /// Validates a path for the `fs.read` / `fs.write_sandbox` capabilities only.
    /// Default is DENY: a path is allowed if and only if, after resolving `~`,
    /// `..`, `.`, and every symlink in the chain, it resolves to
    /// `filesystemCapabilitySandboxRoot` itself or a descendant of it. Resolving
    /// BEFORE the containment check (rather than string-matching the raw input)
    /// is what defeats `../` traversal, a symlink planted inside the sandbox
    /// that points outside it, and absolute-path substitution — the decision is
    /// made against where the path actually leads on disk, not its literal text.
    /// The fixed sensitive-filename/extension checks from `validate(path:)` are
    /// re-applied even for in-sandbox paths as defense in depth.
    public static func validateSandboxedFilesystemAccess(path: String) -> QPathValidationOutcome {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .denied(
                reason: "Empty path is not a valid filesystem-sandbox target.",
                violation: .scopeViolation
            )
        }

        let canonical = canonicalize(path: trimmed)
        let sandboxRoot = filesystemCapabilitySandboxRoot

        guard isContained(canonical, within: sandboxRoot) else {
            return .denied(
                reason: "Path '\(canonical)' is outside the authorized filesystem sandbox " +
                    "'\(sandboxRoot)'. Autonomous filesystem access is confined to this sandbox only.",
                violation: .scopeViolation
            )
        }

        let filename = (canonical as NSString).lastPathComponent
        for sensitivePattern in sensitiveFilenamePatterns {
            if filename == sensitivePattern || filename.hasPrefix(sensitivePattern) {
                return .denied(
                    reason: "Access to credential file pattern '\(sensitivePattern)' is denied, even inside the sandbox.",
                    violation: .absoluteDenylist
                )
            }
        }

        let ext = (canonical as NSString).pathExtension.lowercased()
        if sensitiveExtensions.contains(ext) {
            return .denied(
                reason: "Access to sensitive key/certificate extension '.\(ext)' is denied, even inside the sandbox.",
                violation: .absoluteDenylist
            )
        }

        return .allowed(canonicalPath: canonical)
    }
}
