//
//  PaceActionApprovalTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

struct PaceActionApprovalTests {
    @Test func approvalRequestRequiresEnabledPreferenceAndNonEmptySummary() async throws {
        let summary = "1: [system mutation] Open app Safari"

        let enabledRequest = PaceActionApprovalRequest(
            approvalSummary: summary,
            requiresActionApproval: true
        )
        #expect(enabledRequest?.approvalSummary == summary)

        let disabledRequest = PaceActionApprovalRequest(
            approvalSummary: summary,
            requiresActionApproval: false
        )
        #expect(disabledRequest == nil)

        let emptyRequest = PaceActionApprovalRequest(
            approvalSummary: "   ",
            requiresActionApproval: true
        )
        #expect(emptyRequest == nil)
    }

    @Test func approvalRequestBuildsPopupCopyWithRiskSummary() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [input injection] Type text",
            requiresActionApproval: true
        ))

        #expect(request.messageText == "Approve Que actions?")
        #expect(request.informativeText.contains("Que wants to control your Mac:"))
        #expect(request.informativeText.contains("[input injection] Type text"))
        #expect(request.informativeText.contains("Only approve this if it matches what you asked for."))
    }

    @Test func cancellationBlocksExecution() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [system mutation] Open app Music",
            requiresActionApproval: true
        ))

        let shouldExecute = PaceActionApprovalPolicy.shouldExecuteActions(
            request: request,
            decision: .cancel
        )

        #expect(shouldExecute == false)
    }

    @Test func allowOncePermitsExecution() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [read-only] Read calendar",
            requiresActionApproval: true
        ))

        let shouldExecute = PaceActionApprovalPolicy.shouldExecuteActions(
            request: request,
            decision: .allowOnce
        )

        #expect(shouldExecute == true)
    }

    @Test func missingApprovalRequestPassesThrough() async throws {
        #expect(PaceActionApprovalPolicy.shouldExecuteActions(
            request: nil,
            decision: .cancel
        ))
    }

    @Test func routineLocalActionsDoNotRequireExplicitApproval() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast"),
            .openURL("https://example.com"),
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .readClipboard,
            .undoLastMutation
        ])

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: actionPlan) == false)
    }

    @Test func routineLocalActionsSuppressInitialSpokenFeedback() async throws {
        // Phase 2H remediation: .pressKey moved out of this plan — it now requires explicit
        // approval (see PaceActionApprovalPolicy's keyboard-input fix), so it's no longer
        // "routine" in this sense either. A blocking approval dialog is about to interrupt the
        // flow regardless of whether Pace spoke first, so — consistent with every OTHER
        // approval-required action (composeMail, createNote, ...) — it correctly no longer
        // suppresses initial spoken feedback; see keyboardInputActionsRequiringApprovalDoNotSuppressInitialSpokenFeedback below.
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast"),
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .readClipboard
        ])

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: actionPlan))
    }

    @Test func keyboardInputActionsRequiringApprovalDoNotSuppressInitialSpokenFeedback() async throws {
        // Phase 2H remediation: .pressKey/.type/.setTextValue/.editSelectedText now require
        // explicit approval (a blocking dialog), so — like composeMail/createNote/etc. below —
        // they must not suppress the initial spoken acknowledgment either.
        let pressKeyPlan = PaceActionExecutionPlan.serial(actions: [
            .pressKey(name: "s", modifiers: [.command])
        ])
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: pressKeyPlan) == false)

        let typePlan = PaceActionExecutionPlan.serial(actions: [.type("hello")])
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: typePlan) == false)
    }

    @Test func emptyOrRiskyPlansDoNotSuppressInitialSpokenFeedback() async throws {
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            for: PaceActionExecutionPlan(steps: [])
        ) == false)

        let mailDraftPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Status",
                body: "Draft body"
            ))
        ])

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: mailDraftPlan) == false)
    }

    @Test func routinePlannerResponseTextSuppressesInitialSpokenFeedback() async throws {
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: "clicking it. [CLICK:400,300]"
        ))

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: """
            {"spokenText":"Opening Safari.","intent":"action","payload":{"name":"App.launch","args":{"name":"Safari"}}}
            """
        ))
    }

    @Test func answerAndRiskyPlannerResponseTextDoNotSuppressInitialSpokenFeedback() async throws {
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: "html stands for hypertext markup language."
        ) == false)

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: """
            {"spokenText":"Adding that.","intent":"action","payload":{"name":"Reminders.add","args":{"title":"send invoice"}}}
            """
        ) == false)
    }

    @Test func nonUndoableAndExternalActionsRequireExplicitApproval() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Status",
                body: "Draft body"
            )),
            .createNote(PaceNoteRequest(title: "Idea", body: "Ship it")),
            .runShortcut("Publish"),
            .mcp(PaceMCPToolCall(serverName: "altic", toolName: "notes_create", arguments: [:]))
        ])

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: actionPlan))
    }

    @Test func messagesWithDraftTextRequireExplicitApproval() async throws {
        let openOnlyPlan = PaceActionExecutionPlan.serial(actions: [
            .openMessages(PaceMessageRequest(recipient: "Alex", text: nil))
        ])
        let draftTextPlan = PaceActionExecutionPlan.serial(actions: [
            .openMessages(PaceMessageRequest(recipient: "Alex", text: "running late"))
        ])

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: openOnlyPlan) == false)
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: draftTextPlan))
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: openOnlyPlan))
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: draftTextPlan) == false)
    }

    @Test func blockingPreflightIssueRequiresExplicitApproval() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast")
        ])
        let preflightIssues = [
            PaceToolPreflightIssue(
                severity: .blocking,
                title: "Accessibility permission missing",
                repairHint: "Grant Accessibility."
            )
        ]

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(
            for: actionPlan,
            preflightIssues: preflightIssues
        ))
    }
}
