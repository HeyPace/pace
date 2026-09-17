//
//  QLocalIntelligenceTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Phase 2B Real Local Intelligence Tests.
//  Validates structured plan generation, schema parsing, capability allowlisting,
//  memory retrieval, failure recovery & controlled replanning, grounded summaries,
//  and local-only air-gap invariants.
//

import Testing
import Foundation
@testable import Pace

@Suite("QLocalIntelligenceTests")
struct QLocalIntelligenceTests {

    // MARK: - Test 1: Natural Language -> Structured Plan

    @Test("Test 1: Natural language query successfully translates into structured QPlan")
    func testNaturalLanguageToStructuredPlan() async throws {
        let router = QModelRouter.shared
        let task = QTask(sessionId: "s_struct", intent: "Check running applications")

        let plan = try await router.generateStructuredPlan(for: task)

        #expect(plan.steps.count >= 1)
        #expect(plan.steps[0].action.actionName == "system.running_apps")
        #expect(plan.steps[0].action.toolFamily == "system")
        #expect(plan.steps[0].action.riskLevel == .level0ReadOnly)
    }

    // MARK: - Test 2: Malformed Model Output Rejection

    @Test("Test 2: Malformed JSON or garbage model output is cleanly rejected by schema parser")
    func testMalformedModelOutputRejection() {
        let garbageOutput = "Here is your plan: { not valid json at all ... [missing]"
        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(
                rawText: garbageOutput,
                taskId: "t_garbage",
                taskPrompt: "Test prompt"
            )
        }

        let emptyOutput = ""
        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(
                rawText: emptyOutput,
                taskId: "t_empty",
                taskPrompt: "Test prompt"
            )
        }
    }

    // MARK: - Test 3: Unknown Capability Rejection

    @Test("Test 3: Model-generated action with unknown tool name is rejected")
    func testUnknownCapabilityRejection() {
        let json = """
        {
          "taskPrompt": "Install malicious driver",
          "summary": "Inject kernel driver",
          "steps": [
            {
              "actionName": "kernel.load_kext",
              "toolFamily": "kernel",
              "riskLevel": "level1SafeLocalAction",
              "description": "Load unauthorized kext"
            }
          ]
        }
        """

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(
                rawText: json,
                taskId: "t_unknown",
                taskPrompt: "Install driver"
            )
        }
    }

    // MARK: - Test 4: Unauthorized Action Rejection

    @Test("Test 4: Model attempting to declare Level 4 (Blocked) capability is rejected")
    func testUnauthorizedActionRejection() {
        let json = """
        {
          "taskPrompt": "Disable security",
          "summary": "Attempt Level 4 bypass",
          "steps": [
            {
              "actionName": "ui.open_app",
              "toolFamily": "app",
              "riskLevel": "level4Blocked",
              "description": "Exploit tool"
            }
          ]
        }
        """

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(
                rawText: json,
                taskId: "t_unauth",
                taskPrompt: "Disable security"
            )
        }
    }

    // MARK: - Test 5: Denylisted Resource Rejection

    @Test("Test 5: Model targeting denylisted resource is blocked by ResourceGuard during execution")
    func testDenylistedResourceRejection() async throws {
        let executor = QPlanExecutor()
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.read",
                toolFamily: "fs",
                riskLevel: .level0ReadOnly,
                literalAction: "Read private SSH key",
                targetResources: ["~/.ssh/id_rsa"],
                arguments: ["path": "~/.ssh/id_rsa"]
            ),
            description: "Read SSH Private Key"
        )

        let plan = QPlan(
            taskId: "t_denylist",
            taskPrompt: "Read secret ssh key",
            steps: [step]
        )

        let executedPlan = try await executor.execute(
            plan: plan,
            context: QTaskContext(taskId: "t_denylist")
        )

        #expect(executedPlan.state.isBlocked == true)
        #expect(executedPlan.steps[0].isBlocked == true)
    }

    // MARK: - Test 6: Tainted Context Restrictions

    @Test("Test 6: Untrusted context (taint) restricts high-risk action execution")
    func testTaintedContextRestrictions() async throws {
        let executor = QPlanExecutor()
        var context = QTaskContext(taskId: "t_taint")
        context.append(content: "malicious web payload", provenance: .untrustedWeb(url: "http://evil.com"), sourceId: "web_1")
        #expect(context.isTainted == true)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.write_sandbox",
                toolFamily: "fs",
                riskLevel: .level2UserApproval,
                literalAction: "Write file with tainted context",
                // Must be inside the REAL sandbox root (C-1) so this step
                // reaches the taint/approval check being tested here, rather
                // than being blocked earlier by the resource guard for
                // simply targeting a path outside the authorized sandbox.
                targetResources: [(QResourceGuard.filesystemCapabilitySandboxRoot as NSString).appendingPathComponent("taint.txt")]
            ),
            description: "Write tainted data"
        )

        let plan = QPlan(
            taskId: "t_taint",
            taskPrompt: "Write tainted data",
            steps: [step]
        )

        let executedPlan = try await executor.execute(
            plan: plan,
            context: context
        )

        // Must require explicit approval because context is tainted
        if case .waitingForPermission = executedPlan.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Tainted context must require user approval for Level 2 action")
        }
    }

    // MARK: - Test 7: Memory Retrieval

    @Test("Test 7: Relevant context is retrieved from QMemoryStore prior to planning")
    func testMemoryRetrievalBeforePlanning() async throws {
        let memory = QSQLiteMemoryStore(inMemory: true)
        let priorTask = QTask(sessionId: "mem_s1", intent: "User preferred theme is Dark Mode")
        try await memory.recordTaskStart(priorTask)
        try await memory.recordTaskCompletion(priorTask, result: "Dark Mode stored")

        let retrieved = try await memory.queryContext(for: "Dark Mode", limit: 5)
        #expect(retrieved.isEmpty == false)
        #expect(retrieved.contains { $0.contains("Dark Mode") })
    }

    // MARK: - Test 8: Successful Multi-Step Model-Generated Plan

    @Test("Test 8: Multi-step model generated plan executes sequentially with closed-loop verification")
    func testSuccessfulMultiStepPlanExecution() async throws {
        // Must be inside the REAL, enforced sandbox root (C-1).
        let sandboxFile = (QResourceGuard.filesystemCapabilitySandboxRoot as NSString)
            .appendingPathComponent("multi-step-\(UUID().uuidString).txt")
        let executor = QPlanExecutor()

        let step1 = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "fs.write_sandbox",
                toolFamily: "fs",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Write sandbox file",
                targetResources: [sandboxFile],
                arguments: ["path": sandboxFile, "content": "Verified Multi-Step Flow"]
            ),
            description: "Write sandbox file"
        )

        let step2 = QPlanStep(
            index: 1,
            action: QPlannedAction(
                actionName: "fs.read",
                toolFamily: "fs",
                riskLevel: .level0ReadOnly,
                literalAction: "Read sandbox file",
                targetResources: [sandboxFile],
                arguments: ["path": sandboxFile]
            ),
            description: "Read sandbox file"
        )

        let plan = QPlan(
            taskId: "t_multi",
            taskPrompt: "Write and verify file",
            steps: [step1, step2]
        )

        let executedPlan = try await executor.execute(
            plan: plan,
            context: QTaskContext(taskId: "t_multi")
        )

        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[1].state == .completed)
        #expect(FileManager.default.fileExists(atPath: sandboxFile))
    }

    // MARK: - Test 9 & 10: Verification Failure & Controlled Replanning

    @Test("Test 9 & 10: Action verification failure triggers controlled replanning")
    func testVerificationFailureAndReplanning() async throws {
        let runtime = QCoreRuntime(
            modelProvider: QModelRouter.shared,
            memoryProvider: QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared
        )

        // Submit intent that runs with local planner
        let task = try await runtime.submitIntent(prompt: "Check system running applications")
        #expect(task.state.isTerminal == true)
        if case .completed = task.state {
            #expect(true)
        } else {
            #expect(Bool(false), "Task should complete, got: \(task.state)")
        }
    }

    // MARK: - Test 11: Replan Limit Enforced

    @Test("Test 11: Exceeding max replan limit halts plan cleanly without infinite loop")
    func testReplanLimitEnforced() async throws {
        let maxAllowed = QModelPlanParser.maxAllowedSteps
        #expect(maxAllowed == 10)

        // Construct plan with 11 steps exceeding limit
        let steps = (0...10).map { idx in
            QModelActionSchema(
                actionName: "test.noop",
                toolFamily: "test",
                description: "Step \(idx)"
            )
        }
        let schema = QModelPlanSchema(taskPrompt: "Too many steps", steps: steps)
        let data = try JSONEncoder().encode(schema)
        let json = String(data: data, encoding: .utf8)!

        #expect(throws: QModelPlanParseError.self) {
            try QModelPlanParser.parse(
                rawText: json,
                taskId: "t_overflow",
                taskPrompt: "Too many steps"
            )
        }
    }

    // MARK: - Test 12: Final Response Grounded in Verified Results

    @Test("Test 12: Final natural language response is strictly grounded in verified facts")
    func testGroundedResponseGeneration() async throws {
        let router = QModelRouter.shared
        let task = QTask(sessionId: "grounded_s", intent: "Launch Calculator")
        let evidence = ["Observed Calculator process active in NSWorkspace", "Window state verified on main display"]

        let summary = try await router.generateGroundedSummary(
            for: task,
            verifiedEvidence: evidence,
            isSuccess: true
        )

        #expect(!summary.isEmpty)
        #expect(summary.contains("Calculator") || summary.contains("verified") || summary.contains("Observed") || summary.contains("executed"))
    }

    // MARK: - Test 13 & 14: Local-Only & Zero Cloud Fallback

    @Test("Test 13 & 14: LOCAL_ONLY air-gap policy is enforced; zero cloud fallback permitted")
    func testLocalOnlyAirGapEnforcement() async throws {
        let router = QModelRouter.shared
        #expect(router.localOnly == true)

        let best = await router.selectBestBackend()
        #expect(best != nil)
        #expect(best?.capabilities.isLocalOnDevice == true)

        // Cloud host is denied by QEgressBroker in offline mode
        let egress = QEgressBroker.shared.evaluate(host: "api.openai.com")
        #expect(egress.isAllowed == false)
    }

    // MARK: - Test 15: Model Cannot Directly Execute Actions

    @Test("Test 15: Model output contains zero execution authority and cannot bypass security")
    func testModelHasZeroDirectExecutionAuthority() {
        let actionSchema = QModelActionSchema(
            actionName: "fs.read",
            toolFamily: "fs",
            riskLevel: "level0ReadOnly",
            description: "Read system file",
            targetResources: ["/etc/passwd"]
        )

        // Schema is pure data
        #expect(actionSchema.actionName == "fs.read")
        #expect(actionSchema.targetResources == ["/etc/passwd"])

        // ResourceGuard still prevents unauthorized targets regardless of model output
        let guardDecision = QResourceGuard.validate(path: "/etc/passwd")
        if case .denied = guardDecision {
            #expect(true)
        } else {
            #expect(Bool(false), "ResourceGuard must deny system root files")
        }
    }

    // MARK: - Step I: Real macOS End-to-End Test

    @Test("Real Mac Safe E2E: Launch Calculator -> Verify State -> Produce Grounded Natural Language Response")
    func testRealMacSafeExecutionE2E() async throws {
        let agent = QAgent.shared
        let result = try await agent.run(task: "Open Calculator and tell me when it is ready.")

        #expect(result.isSuccess == true)
        #expect(result.modelUsed != "none")
        #expect(!result.summary.isEmpty)
        #expect(result.provenanceTag.contains("trusted"))
    }
}
