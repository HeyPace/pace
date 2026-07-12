//
//  PaceFailureNarratorTests.swift
//  leanring-buddyTests
//
//  Table-driven tests for the pure templated failure-narrator. Every
//  `PaceFailureKind` must produce a non-empty spoken string and a
//  predictable suggestion shape. The narrator is sealed against
//  random/LLM output, so we can assert exact strings.
//

import XCTest
@testable import Pace

final class PaceFailureNarratorTests: XCTestCase {

    // MARK: - plannerOffline

    func testPlannerOfflineSuggestsOpeningSettings() {
        let narration = PaceFailureNarrator.compose(.plannerOffline)

        XCTAssertFalse(narration.spokenText.isEmpty)
        XCTAssertTrue(narration.spokenText.lowercased().contains("local planner"))
        XCTAssertTrue(narration.spokenText.lowercased().contains("settings"))
        XCTAssertEqual(narration.suggestion, .openSettings)
    }

    // MARK: - missingPermission

    func testMissingAccessibilityPermissionNamesAccessibility() {
        let narration = PaceFailureNarrator.compose(
            .missingPermission(permission: .accessibility)
        )

        XCTAssertTrue(narration.spokenText.contains("Accessibility access"))
        XCTAssertEqual(
            narration.suggestion,
            .openSpecificPermission(.accessibility)
        )
    }

    func testMissingCalendarPermissionNamesCalendar() {
        let narration = PaceFailureNarrator.compose(
            .missingPermission(permission: .calendar)
        )

        XCTAssertTrue(narration.spokenText.contains("Calendar access"))
        XCTAssertEqual(
            narration.suggestion,
            .openSpecificPermission(.calendar)
        )
    }

    func testMissingRemindersPermissionNamesReminders() {
        let narration = PaceFailureNarrator.compose(
            .missingPermission(permission: .reminders)
        )

        XCTAssertTrue(narration.spokenText.contains("Reminders access"))
        XCTAssertEqual(
            narration.suggestion,
            .openSpecificPermission(.reminders)
        )
    }

    func testMissingAutomationPermissionNamesAutomation() {
        let narration = PaceFailureNarrator.compose(
            .missingPermission(permission: .automation)
        )

        XCTAssertTrue(narration.spokenText.contains("Automation access"))
        XCTAssertEqual(
            narration.suggestion,
            .openSpecificPermission(.automation)
        )
    }

    // MARK: - clickMissed

    func testClickMissedWithKnownLabelEchoesLabelLowercased() {
        let narration = PaceFailureNarrator.compose(
            .clickMissed(targetLabel: "Save Draft")
        )

        XCTAssertTrue(narration.spokenText.contains("save draft"))
        XCTAssertTrue(narration.spokenText.lowercased().contains("on this screen"))
        XCTAssertNil(narration.suggestion)
    }

    func testClickMissedWithEmptyLabelFallsBackToGenericCopy() {
        let narration = PaceFailureNarrator.compose(
            .clickMissed(targetLabel: "   ")
        )

        XCTAssertEqual(
            narration.spokenText,
            "I couldn't find that on this screen — want to point it out?"
        )
        XCTAssertNil(narration.suggestion)
    }

    func testClickMissedWithNilLabelFallsBackToGenericCopy() {
        let narration = PaceFailureNarrator.compose(
            .clickMissed(targetLabel: nil)
        )

        XCTAssertEqual(
            narration.spokenText,
            "I couldn't find that on this screen — want to point it out?"
        )
        XCTAssertNil(narration.suggestion)
    }

    // MARK: - sidecarTTSOffline

    func testSidecarTTSOfflineMentionsScriptAndSuggestsScript() {
        let narration = PaceFailureNarrator.compose(.sidecarTTSOffline)

        XCTAssertTrue(narration.spokenText.contains("system voice"))
        XCTAssertTrue(narration.spokenText.contains("scripts/start-tts-server.sh"))
        XCTAssertEqual(narration.suggestion, .runTTSSidecarScript)
    }

    // MARK: - mcpServerNotConfigured

    func testMCPServerNotConfiguredEchoesServerName() {
        let narration = PaceFailureNarrator.compose(
            .mcpServerNotConfigured(name: "altic")
        )

        XCTAssertTrue(narration.spokenText.contains("altic"))
        XCTAssertEqual(
            narration.suggestion,
            .configureMCPServer(name: "altic")
        )
    }

    func testMCPServerNotConfiguredWithEmptyNameUsesGenericReference() {
        let narration = PaceFailureNarrator.compose(
            .mcpServerNotConfigured(name: "  ")
        )

        XCTAssertTrue(narration.spokenText.contains("that MCP server"))
        XCTAssertEqual(
            narration.suggestion,
            .configureMCPServer(name: "that")
        )
    }

    // MARK: - cloudBridgeUpstreamError

    func testCloudBridgeUpstreamErrorNamesProvider() {
        let narration = PaceFailureNarrator.compose(
            .cloudBridgeUpstreamError(provider: "Claude Code")
        )

        XCTAssertTrue(narration.spokenText.contains("Claude Code"))
        XCTAssertTrue(narration.spokenText.lowercased().contains("signed in"))
        XCTAssertEqual(narration.suggestion, .openLocalAIBridgeFolder)
    }

    func testCloudBridgeUpstreamErrorWithEmptyProviderUsesGenericCopy() {
        let narration = PaceFailureNarrator.compose(
            .cloudBridgeUpstreamError(provider: "")
        )

        XCTAssertTrue(narration.spokenText.contains("the cloud bridge"))
        XCTAssertEqual(narration.suggestion, .openLocalAIBridgeFolder)
    }

    // MARK: - Sweep over every kind

    func testEveryKindProducesNonEmptySpokenText() {
        let allKinds: [PaceFailureKind] = [
            .plannerOffline,
            .missingPermission(permission: .accessibility),
            .missingPermission(permission: .calendar),
            .missingPermission(permission: .reminders),
            .missingPermission(permission: .automation),
            .clickMissed(targetLabel: "Save"),
            .clickMissed(targetLabel: nil),
            .sidecarTTSOffline,
            .mcpServerNotConfigured(name: "filesystem"),
            .cloudBridgeUpstreamError(provider: "Codex"),
        ]

        for kind in allKinds {
            let narration = PaceFailureNarrator.compose(kind)
            XCTAssertFalse(
                narration.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Kind \(kind) produced empty spoken text"
            )
        }
    }
}
