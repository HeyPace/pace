//
//  QResourceGuardTests.swift
//  leanring-buddyTests
//
//  Adversarial Security Tests for QResourceGuard (Phase 1c.4)
//

import Testing
import Foundation
@testable import Pace

@Suite("QResourceGuardTests")
struct QResourceGuardTests {

    let tempDirectory: String = {
        let path = NSTemporaryDirectory() + "q_resource_guard_test_" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    @Test("Absolute denylist blocks SSH keys and directories")
    func blocksSSHDirectory() {
        let sshPath = "~/.ssh/id_rsa"
        let outcome = QResourceGuard.validate(path: sshPath)
        #expect(!outcome.isAllowed)
        if case .denied(let reason, let violation) = outcome {
            #expect(violation == .absoluteDenylist)
            #expect(reason.contains(".ssh") || reason.contains("id_rsa"))
        }

        let sshDir = "~/.ssh"
        let outcomeDir = QResourceGuard.validate(path: sshDir)
        #expect(!outcomeDir.isAllowed)
    }

    @Test("Absolute denylist blocks Keychains directory")
    func blocksKeychainsDirectory() {
        let keychainPath = "~/Library/Keychains/login.keychain-db"
        let outcome = QResourceGuard.validate(path: keychainPath)
        #expect(!outcome.isAllowed)
        if case .denied(_, let violation) = outcome {
            #expect(violation == .absoluteDenylist)
        }
    }

    @Test("Blocks .env and sensitive credential files")
    func blocksEnvAndSecretFiles() {
        let env1 = "/Users/hani/Developer/project/.env"
        let outcome1 = QResourceGuard.validate(path: env1)
        #expect(!outcome1.isAllowed)

        let env2 = "/Users/hani/Developer/project/.env.production"
        let outcome2 = QResourceGuard.validate(path: env2)
        #expect(!outcome2.isAllowed)

        let pemFile = "/Users/hani/Developer/project/server.pem"
        let outcomePem = QResourceGuard.validate(path: pemFile)
        #expect(!outcomePem.isAllowed)

        let keyFile = "/Users/hani/Developer/project/private.key"
        let outcomeKey = QResourceGuard.validate(path: keyFile)
        #expect(!outcomeKey.isAllowed)
    }

    @Test("Blocks sensitive system directories")
    func blocksSystemDirectories() {
        let sys1 = "/etc/passwd"
        let outcome1 = QResourceGuard.validate(path: sys1)
        #expect(!outcome1.isAllowed)

        let sys2 = "/System/Library/CoreServices"
        let outcome2 = QResourceGuard.validate(path: sys2)
        #expect(!outcome2.isAllowed)

        let sys3 = "/bin/sh"
        let outcome3 = QResourceGuard.validate(path: sys3)
        #expect(!outcome3.isAllowed)
    }

    @Test("Adversarial: ../ traversal escapes are canonicalized and caught by denylist")
    func dotDotTraversalToDenylist() {
        let sneakySSH = "/tmp/fake_dir/../../" + (NSHomeDirectory() as NSString).lastPathComponent + "/.ssh/id_rsa"
        let outcome = QResourceGuard.validate(path: sneakySSH)
        #expect(!outcome.isAllowed)
    }

    @Test("Adversarial: ../ traversal escapes are caught by path jail confinement")
    func dotDotTraversalOutOfJail() {
        let jail = tempDirectory + "/allowed_jail"
        try? FileManager.default.createDirectory(atPath: jail, withIntermediateDirectories: true)

        let validInside = jail + "/subfolder/file.txt"
        let outcomeValid = QResourceGuard.validate(path: validInside, allowedJailPrefix: jail)
        #expect(outcomeValid.isAllowed)

        let sneakyEscape = jail + "/subfolder/../../outside_jail.txt"
        let outcomeEscape = QResourceGuard.validate(path: sneakyEscape, allowedJailPrefix: jail)
        #expect(!outcomeEscape.isAllowed)
        if case .denied(let reason, let violation) = outcomeEscape {
            #expect(violation == .scopeViolation)
            #expect(reason.contains("escapes the permitted jail scope"))
        }
    }

    @Test("Adversarial: Symlink escapes are resolved to real target and validated against denylist and jail")
    func symlinkEscape() throws {
        let jail = tempDirectory + "/symlink_jail"
        try? FileManager.default.createDirectory(atPath: jail, withIntermediateDirectories: true)

        // Create a symlink inside the jail pointing to an unauthorized directory outside
        let outsideTarget = tempDirectory + "/secret_outside"
        try? FileManager.default.createDirectory(atPath: outsideTarget, withIntermediateDirectories: true)
        let symlinkPath = jail + "/link_to_outside"

        try? FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: outsideTarget)

        // Validating the symlink path inside jail must fail because its real target is outside the jail
        let outcome = QResourceGuard.validate(path: symlinkPath + "/data.txt", allowedJailPrefix: jail)
        #expect(!outcome.isAllowed)
        if case .denied(_, let violation) = outcome {
            #expect(violation == .scopeViolation)
        }
    }
}

// MARK: - validateSandboxedFilesystemAccess (C-1: fs.read / fs.write_sandbox allowlist)

/// Adversarial coverage for the fail-closed allowlist backing `fs.read` /
/// `fs.write_sandbox`. Unlike `validate(path:allowedJailPrefix:)` above (an
/// optional jail a caller may or may not supply), this function has exactly
/// ONE authorized root, fixed at the source level
/// (`QResourceGuard.filesystemCapabilitySandboxRoot`), and default is deny.
/// These tests exercise the REAL production root — there is no injection
/// seam, and testing against the actual constant is the more faithful proof
/// that the boundary these two capabilities rely on is actually enforced.
@Suite("QResourceGuardSandboxedFilesystemAccessTests")
struct QResourceGuardSandboxedFilesystemAccessTests {

    private var sandboxRoot: String { QResourceGuard.filesystemCapabilitySandboxRoot }

    /// A fresh, per-test subdirectory inside the real sandbox root, cleaned
    /// up after the test so runs don't accumulate files on the developer's
    /// real disk.
    private func makeScratchDirectory(testName: String = #function) throws -> String {
        let scratch = (sandboxRoot as NSString).appendingPathComponent("test-\(testName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        return scratch
    }

    @Test("A path directly inside the real sandbox root is allowed")
    func allowsPathInsideSandboxRoot() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let target = scratch + "/allowed-file.txt"
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: target)
        #expect(outcome.isAllowed)
    }

    @Test("The sandbox root itself is allowed")
    func allowsSandboxRootItself() {
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: sandboxRoot)
        #expect(outcome.isAllowed)
    }

    @Test("Adversarial: absolute-path substitution outside the sandbox is denied")
    func deniesAbsolutePathOutsideSandbox() {
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: "/etc/passwd")
        #expect(!outcome.isAllowed)
        if case .denied(_, let violation) = outcome {
            #expect(violation == .scopeViolation)
        }
    }

    @Test("Adversarial: home-directory paths outside the sandbox are denied even though they're user-owned")
    func deniesHomeDirectoryPathsOutsideSandbox() {
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: "~/.ssh/id_rsa")
        #expect(!outcome.isAllowed)

        let outcome2 = QResourceGuard.validateSandboxedFilesystemAccess(path: "~/Documents/notes.txt")
        #expect(!outcome2.isAllowed)
        if case .denied(_, let violation) = outcome2 {
            #expect(violation == .scopeViolation)
        }
    }

    @Test("Adversarial: ../ traversal from inside the sandbox to outside is denied")
    func deniesDotDotTraversalOutOfSandbox() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // Walk up enough levels to guarantee escape regardless of how deep
        // the real sandbox root happens to be nested.
        let escapeAttempt = scratch + "/" + String(repeating: "../", count: 20) + "etc/passwd"
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: escapeAttempt)
        #expect(!outcome.isAllowed)
        if case .denied(let reason, let violation) = outcome {
            #expect(violation == .scopeViolation)
            #expect(reason.contains("outside the authorized filesystem sandbox"))
        }
    }

    @Test("Adversarial: a symlink planted inside the sandbox pointing outside it is denied")
    func deniesSymlinkEscapingSandbox() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let outsideTarget = NSTemporaryDirectory() + "q_sandbox_escape_target_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: outsideTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outsideTarget) }

        let symlinkPath = scratch + "/escape_link"
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: outsideTarget)

        // The symlink's NAME is inside the sandbox; its REAL target is not —
        // canonicalization must resolve to the real target before the
        // containment check runs, so this must be denied.
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: symlinkPath + "/data.txt")
        #expect(!outcome.isAllowed)
        if case .denied(_, let violation) = outcome {
            #expect(violation == .scopeViolation)
        }
    }

    @Test("Defense in depth: a sensitive extension inside the sandbox is still denied")
    func deniesSensitiveExtensionEvenInsideSandbox() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: scratch + "/leaked.pem")
        #expect(!outcome.isAllowed)
        if case .denied(_, let violation) = outcome {
            #expect(violation == .absoluteDenylist)
        }
    }

    @Test("Defense in depth: a credential filename pattern inside the sandbox is still denied")
    func deniesCredentialFilenameEvenInsideSandbox() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: scratch + "/.env")
        #expect(!outcome.isAllowed)
    }

    @Test("Empty path is denied")
    func deniesEmptyPath() {
        #expect(!QResourceGuard.validateSandboxedFilesystemAccess(path: "").isAllowed)
        #expect(!QResourceGuard.validateSandboxedFilesystemAccess(path: "   ").isAllowed)
    }

    @Test("A sibling directory that merely shares the sandbox root as a string prefix is still denied")
    func deniesPrefixSharingSiblingDirectory() {
        // e.g. sandboxRoot = ".../Pace/q-sandbox" — a sibling literally named
        // ".../Pace/q-sandbox-evil" shares a raw string prefix but is NOT a
        // descendant; the trailing-slash normalization in `isContained`
        // exists specifically so this is rejected, not silently allowed.
        let siblingLookalike = sandboxRoot + "-evil/data.txt"
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: siblingLookalike)
        #expect(!outcome.isAllowed)
    }

    @Test("A newly-created (not-yet-existing) file inside the sandbox is allowed")
    func allowsNewFileInsideSandbox() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let brandNewFile = scratch + "/does-not-exist-yet-\(UUID().uuidString).txt"
        #expect(!FileManager.default.fileExists(atPath: brandNewFile))
        let outcome = QResourceGuard.validateSandboxedFilesystemAccess(path: brandNewFile)
        #expect(outcome.isAllowed)
    }
}
