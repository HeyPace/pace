//
//  QActionAuthorizerTests.swift
//  leanring-buddyTests
//
//  Unit tests for Pace Action Authorization Integration (Phase 1c.7)
//

import Testing
import Foundation
@testable import Pace

@Suite("QActionAuthorizerTests")
struct QActionAuthorizerTests {

    @Test("Pace actions map accurately to Q capability levels")
    func actionMapping() {
        let clickAction = PaceParsedAction.click(ScreenshotPixelLocation(xInScreenshotPixels: 100, yInScreenshotPixels: 200, screenNumber: 1))
        let metaClick = QActionAuthorizationBridge.mapActionToQMetadata(clickAction)
        #expect(metaClick.toolName == "input.click")
        #expect(metaClick.risk == .level2UserApproval)

        let appAction = PaceParsedAction.openApplication("Safari")
        let metaApp = QActionAuthorizationBridge.mapActionToQMetadata(appAction)
        #expect(metaApp.toolName == "app.launch")
        #expect(metaApp.risk == .level1SafeLocalAction)

        let mailAction = PaceParsedAction.composeMail(PaceMailDraft(recipients: ["user@example.com"], subject: "Hello", body: "World"))
        let metaMail = QActionAuthorizationBridge.mapActionToQMetadata(mailAction)
        #expect(metaMail.toolName == "mail.compose")
        #expect(metaMail.risk == .level3HighRisk)
    }

    @Test("Preflight blocks actions with denylisted filesystem paths")
    func preflightBlocksDenylistedPaths() {
        let maliciousFinder = PaceParsedAction.finder(PaceFinderRequest(
            path: "~/.ssh/id_rsa",
            action: .reveal
        ))

        let decision = QActionAuthorizationBridge.preflightAuthorize(action: maliciousFinder)
        #expect(decision.isDenied)
        if case .deny(let reason, let violation) = decision {
            #expect(violation == .absoluteDenylist)
            #expect(reason.contains(".ssh") || reason.contains("id_rsa"))
        }
    }

    @Test("Preflight allows safe Level 0 and Level 1 actions")
    func preflightAllowsSafeActions() {
        let appAction = PaceParsedAction.openApplication("Notes")
        let decision = QActionAuthorizationBridge.preflightAuthorize(action: appAction)
        #expect(decision.isAllowed)
    }

    // MARK: - HIGH-2: isContextTainted plumbing

    @Test("isContextTainted: true forces a normally-auto-permitted Level 2 action into requiring approval")
    func taintedContextForcesApprovalOnLevel2Action() {
        let clickAction = PaceParsedAction.click(ScreenshotPixelLocation(xInScreenshotPixels: 1, yInScreenshotPixels: 1, screenNumber: 1))

        let untaintedDecision = QActionAuthorizationBridge.preflightAuthorize(action: clickAction, isContextTainted: false)
        #expect(untaintedDecision.requiresApproval, "sanity: click is already Level 2 by itself")

        let taintedDecision = QActionAuthorizationBridge.preflightAuthorize(action: clickAction, isContextTainted: true)
        #expect(taintedDecision.requiresApproval)
    }

    @Test("isContextTainted: true does NOT force approval on Level 0/1 actions — matches Q's own documented Level 0/1 exemption")
    func taintedContextDoesNotAffectLevel0Or1Actions() {
        let clipboardRead = QActionAuthorizationBridge.preflightAuthorize(action: .readClipboard, isContextTainted: true)
        #expect(clipboardRead.isAllowed)

        let launchApp = QActionAuthorizationBridge.preflightAuthorize(action: .openApplication("Notes"), isContextTainted: true)
        #expect(launchApp.isAllowed)
    }

    @Test("isContextTainted: true still forces approval on an already-Level-3 action — taint never downgrades an existing requirement")
    func taintedContextPreservesLevel3ApprovalRequirement() {
        let downloadAction = PaceParsedAction.downloadFile(
            PaceFileDownloadRequest(url: URL(string: "https://example.com/file.pdf")!, suggestedFilename: nil)
        )
        let decision = QActionAuthorizationBridge.preflightAuthorize(action: downloadAction, isContextTainted: true)
        #expect(decision.requiresApproval)
    }

    @Test("Denylisted paths remain denied regardless of taint — deny always outranks requireApproval")
    func denylistedPathsRemainDeniedWhenTainted() {
        let maliciousFinder = PaceParsedAction.finder(PaceFinderRequest(path: "~/.ssh/id_rsa", action: .reveal))
        let decision = QActionAuthorizationBridge.preflightAuthorize(action: maliciousFinder, isContextTainted: true)
        #expect(decision.isDenied)
    }
}
