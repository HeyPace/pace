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
}
