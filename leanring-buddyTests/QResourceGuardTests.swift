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
