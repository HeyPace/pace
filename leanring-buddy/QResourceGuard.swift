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
            let normalizedJail = canonicalJail.hasSuffix("/") ? canonicalJail : canonicalJail + "/"
            let normalizedTarget = canonical.hasSuffix("/") ? canonical : canonical + "/"

            guard normalizedTarget.hasPrefix(normalizedJail) || canonical == canonicalJail else {
                return .denied(
                    reason: "Path '\(canonical)' escapes the permitted jail scope '\(canonicalJail)'.",
                    violation: .scopeViolation
                )
            }
        }

        return .allowed(canonicalPath: canonical)
    }
}
