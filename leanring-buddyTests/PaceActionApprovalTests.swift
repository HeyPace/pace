//
//  PaceActionApprovalTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Pace

struct PaceActionApprovalTests {
    @Test func linearObservationRequiresTheExactOfficialReadOnlyConfiguration() {
        let plan = PaceActionExecutionPlan.serial(actions: [
            .mcp(PaceMCPToolCall(serverName: "linear", toolName: "list_issues", arguments: [:]))
        ])
        let configuration = PaceMCPServerConfiguration(
            command: "npx",
            args: ["-y", "mcp-remote@0.14.3", "https://mcp.linear.app/mcp/readonly"]
        )
        #expect(PaceActionApprovalPolicy.permitsObservationOnly(plan, configuredServers: ["linear": configuration]))
        #expect(!PaceActionApprovalPolicy.permitsObservationOnly(plan, configuredServers: [:]))
        let writeConfiguration = PaceMCPServerConfiguration(
            command: "npx", args: ["-y", "mcp-remote@0.14.3", "https://mcp.linear.app/mcp"])
        #expect(
            !PaceActionApprovalPolicy.permitsObservationOnly(plan, configuredServers: ["linear": writeConfiguration]))
        let alteredConfiguration = PaceMCPServerConfiguration(
            command: configuration.command, args: configuration.args, env: ["NODE_OPTIONS": "--require custom.js"])
        #expect(
            !PaceActionApprovalPolicy.permitsObservationOnly(plan, configuredServers: ["linear": alteredConfiguration]))
    }

    @Test func structuredInspectionNeedsAnAnswerButMutationAndAnswersDoNot() {
        let inventory = PaceActionTagParser.parseActions(
            from:
                #"{"spokenText":"Inspecting TextEdit.","intent":"action","payload":{"name":"MCP.call","args":{"server":"peekaboo","tool":"window","arguments":{"action":"list","app":"TextEdit"}}}}"#
        )
        let inspection = PaceParsedAction.mcp(
            PaceMCPToolCall(serverName: "peekaboo", toolName: "see", arguments: [:]))
        #expect(PaceActionApprovalPolicy.needsAnswerAfterInspection(inventory.executionPlan))
        #expect(PaceActionApprovalPolicy.needsAnswerAfterInspection(.serial(actions: [inspection])))
        #expect(!PaceActionApprovalPolicy.needsAnswerAfterInspection(.serial(actions: [inspection, .type("text")])))
        let answer = PaceActionTagParser.parseActions(
            from:
                #"{"spokenText":"Launch review is Tuesday at 14:00.","intent":"answer"}"#)
        #expect(!PaceActionApprovalPolicy.needsAnswerAfterInspection(answer.executionPlan))
    }

    @Test func screenExplanationCannotBecomeDictation() {
        let transcript =
            "Read my screen and explain the visible TextEdit checklist. Include the test identifier. Do not click or change anything."
        let plannerResponse =
            #"{"intent":"dictate","payload":{"text":"read my screen and explain the visible textedit checklist"},"spokenText":"reading your screen now."}"#
        let parsedResponse = PaceActionTagParser.parseActions(from: plannerResponse)

        #expect(PaceActionApprovalPolicy.requestsObservationOnly(transcript))
        #expect(!PaceActionApprovalPolicy.permitsObservationOnly(parsedResponse.executionPlan))
    }

    @Test func observationOnlyAllowsInspectionButRejectsMixedMutationPlans() {
        let inspectScreen = PaceParsedAction.mcp(
            PaceMCPToolCall(serverName: "peekaboo", toolName: "see", arguments: [:]))
        #expect(PaceActionApprovalPolicy.permitsObservationOnly(.serial(actions: [inspectScreen])))
        #expect(
            !PaceActionApprovalPolicy.permitsObservationOnly(
                .serial(actions: [inspectScreen, .type("unexpected text")])))
        #expect(
            !PaceActionApprovalPolicy.permitsObservationOnly(
                .serial(actions: [
                    .mcp(PaceMCPToolCall(serverName: "peekaboo", toolName: "click", arguments: [:]))
                ])))
    }

    @Test func pointingWithoutClickingRequiresObservationOnly() {
        #expect(PaceActionApprovalPolicy.requestsObservationOnly("Point at the File menu without clicking."))
        #expect(PaceActionApprovalPolicy.requestsObservationOnly("Read my screen. Do not take any actions."))
        #expect(!PaceActionApprovalPolicy.requestsObservationOnly("Click the File menu."))
        #expect(!PaceActionApprovalPolicy.requestsObservationOnly("Type this checklist in TextEdit."))
        #expect(!PaceActionApprovalPolicy.requestsObservationOnly("Type the words read only in TextEdit."))
    }

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

        #expect(request.messageText == "Approve Pace actions?")
        #expect(request.informativeText.contains("Pace wants to control your Mac:"))
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
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast"),
            .pressKey(name: "s", modifiers: [.command]),
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .readClipboard
        ])

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: actionPlan))
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
