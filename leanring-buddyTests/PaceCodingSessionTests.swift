import Foundation
import Testing
@testable import Pace

private actor CodingEventCollector {
    var events: [PaceCodingSessionEvent] = []
    var approvals: [PaceActionApprovalRequest] = []
    var shouldSuspendProgress = false
    var shouldSuspendFinal = false
    var finalContinuation: CheckedContinuation<Void, Never>?
    var isFinalSuspended: Bool { finalContinuation != nil }
    func suspendFinal() { shouldSuspendFinal = true }
    func resumeFinal() { finalContinuation?.resume(); finalContinuation = nil }
    var progressContinuation: CheckedContinuation<Void, Never>?
    var isProgressSuspended: Bool { progressContinuation != nil }
    func suspendProgress() { shouldSuspendProgress = true }
    func resumeProgress() { progressContinuation?.resume(); progressContinuation = nil }
    func record(_ event: PaceCodingSessionEvent) async {
        events.append(event)
        if shouldSuspendFinal, case .conversation(let message) = event, message.eventID.hasPrefix("coding-final-") {
            await withCheckedContinuation { finalContinuation = $0 }
        }
        if shouldSuspendProgress, case .conversation(let message) = event, message.origin == .progress {
            await withCheckedContinuation { progressContinuation = $0 }
        }
    }
    func approval(_ request: PaceActionApprovalRequest) { approvals.append(request) }
    var conversationEvents: [ConversationEvent] { events.compactMap { if case .conversation(let event) = $0 { return event }; return nil } }
}

private actor CodingFixtureTransport: PaceCodingTransport {
    let stream: AsyncStream<PaceCodingTransportEvent>
    let continuation: AsyncStream<PaceCodingTransportEvent>.Continuation
    var requests: [(String, [String: PaceMCPJSONValue])] = []
    var replies: [(PaceMCPJSONValue, PaceMCPJSONValue?, String?)] = []
    var cwd = ""
    var threadID = "thread-owned"
    var turnNumber = 0
    var unsafePolicy = false
    var interrupted = false
    var sendsEarlyCompletion = false
    var sendsEarlyItems = false
    var failsTurnStart = false
    func failTurnStart() { failsTurnStart = true }
    func setThreadID(_ identifier: String) { threadID = identifier }
    var suspendedThreadStart: CheckedContinuation<Void, Never>?
    var shouldSuspendThreadStart = false
    var isThreadStartSuspended: Bool { suspendedThreadStart != nil }
    func suspendThreadStart() { shouldSuspendThreadStart = true }
    func resumeThreadStart() { suspendedThreadStart?.resume(); suspendedThreadStart = nil }
    var suspendedOpen: CheckedContinuation<Void, Never>?
    var shouldSuspendOpen = false
    var isOpenSuspended: Bool { suspendedOpen != nil }
    var shutdownCount = 0
    func suspendOpen() { shouldSuspendOpen = true }
    func resumeOpen() { suspendedOpen?.resume(); suspendedOpen = nil }
    var suspendedTurnStart: CheckedContinuation<Void, Never>?
    var shouldSuspendTurnStart = false
    var isTurnStartSuspended: Bool { suspendedTurnStart != nil }
    func suspendTurnStart() { shouldSuspendTurnStart = true }
    func resumeTurnStart() { suspendedTurnStart?.resume(); suspendedTurnStart = nil }
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func open() async {
        if shouldSuspendOpen { await withCheckedContinuation { suspendedOpen = $0 } }
    }
    func events() -> AsyncStream<PaceCodingTransportEvent> { stream }
    func shutdown() { shutdownCount += 1; continuation.yield(.disconnected); continuation.finish() }
    func reply(id: PaceMCPJSONValue, result: PaceMCPJSONValue?, error: String?) { replies.append((id, result, error)) }
    func send(_ method: String, params: [String: PaceMCPJSONValue], id: PaceMCPJSONValue? = nil) {
        var message: [String: PaceMCPJSONValue] = ["method": .string(method), "params": .object(params)]
        if let id { message["id"] = id }
        continuation.yield(.message(message))
    }
    func disconnect() { continuation.yield(.disconnected) }
    func setCwd(_ cwd: String) { self.cwd = cwd }
    func setUnsafe() { unsafePolicy = true }
    func setEarlyItems() { sendsEarlyItems = true }
    func setEarlyCompletion() { sendsEarlyCompletion = true }
    func request(_ method: String, params: [String: PaceMCPJSONValue]) async throws -> PaceMCPJSONValue {
        requests.append((method, params))
        switch method {
        case "thread/start", "thread/resume":
            if method == "thread/start", shouldSuspendThreadStart { await withCheckedContinuation { suspendedThreadStart = $0 } }
            try Task.checkCancellation()
            cwd = params["cwd"]?.codingString ?? cwd
            return .object(["cwd": .string(cwd), "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
                "thread": .object(["id": .string(threadID)]), "sandbox": .object([
                    "type": .string(unsafePolicy ? "dangerFullAccess" : "workspaceWrite"), "writableRoots": .array([.string(cwd)]),
                    "networkAccess": .bool(false), "excludeTmpdirEnvVar": .bool(true), "excludeSlashTmp": .bool(true)])])
        case "thread/read": return .object(["thread": .object(["id": .string(threadID), "cwd": .string(cwd), "turns": .array([])])])
        case "turn/start":
            turnNumber += 1
            if shouldSuspendTurnStart { await withCheckedContinuation { suspendedTurnStart = $0 } }
            try Task.checkCancellation()
            if failsTurnStart { throw PaceCodingError.invalidProtocol }
            if sendsEarlyItems {
                for (identifier, phase, text) in [("progress", "commentary", "Working on the test."), ("final", "final_answer", "Fixed the exact test.")] {
                    send("item/completed", params: ["threadId": .string(threadID), "turnId": .string("turn-\(turnNumber)"),
                        "item": .object(["type": .string("agentMessage"), "id": .string(identifier), "phase": .string(phase), "text": .string(text)])])
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            if sendsEarlyCompletion {
                send("turn/completed", params: ["threadId": .string(threadID), "turn": .object(["id": .string("turn-\(turnNumber)"), "status": .string("completed")])])
            }
            return .object(["turn": .object(["id": .string("turn-\(turnNumber)")])])
        case "turn/interrupt":
            interrupted = true
            send("turn/completed", params: ["threadId": .string(threadID), "turn": .object(["id": .string("turn-\(turnNumber)"), "status": .string("interrupted")])])
            return .object([:])
        default: throw PaceCodingError.invalidProtocol
        }
    }
}

@Suite(.serialized)
struct PaceCodingSessionTests {
    private func fixture() throws -> (URL, PaceCodingSessionStore, CodingFixtureTransport, CodingEventCollector, PaceCodingSessionCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaceCodingFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PaceCodingSessionStore(directory: directory.appendingPathComponent("private"))
        let transport = CodingFixtureTransport()
        let collector = CodingEventCollector()
        let coordinator = PaceCodingSessionCoordinator(store: store, transportFactory: { _ in transport },
            eventSink: { await collector.record($0) }, approve: { request in await collector.approval(request); return .allowOnce })
        return (directory, store, transport, collector, coordinator)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("fixture event did not arrive"); throw CancellationError()
    }

    @Test func durableStartTerminalCorrelationAndExactlyOneCanonicalFinal() async throws {
        let (directory, store, transport, collector, coordinator) = try fixture()
        let result = try await coordinator.execute(.start(directory: directory.path, task: "Fix a test"), conversationTurnIdentifier: "original-user-event", authorized: true)
        #expect(result.contains("running"))
        let session = try #require(store.load().first)
        #expect(session.lastTurnID?.rawValue == "turn-1")
        let requests = await transport.requests
        #expect(requests[0].0 == "thread/start")
        #expect(requests[0].1["ephemeral"] == .bool(false))
        #expect(requests[1].1["cwd"] == .string(directory.resolvingSymlinksInPath().path))
        #expect(requests[1].1["model"] == nil)
        #expect(requests[1].1["sandboxPolicy"]?.codingObject?["networkAccess"] == .bool(false))
        let item: [String: PaceMCPJSONValue] = ["threadId": .string("thread-owned"), "turnId": .string("turn-1"),
            "item": .object(["type": .string("agentMessage"), "id": .string("answer"), "text": .string("Fixed the failing test.")])]
        await transport.send("item/completed", params: item)
        await transport.send("item/completed", params: item)
        await transport.send("turn/completed", params: ["threadId": .string("other-thread"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        #expect(try store.load().first?.state == .running)
        let terminal: [String: PaceMCPJSONValue] = ["threadId": .string("thread-owned"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])]
        await transport.send("turn/completed", params: terminal)
        await transport.send("turn/completed", params: terminal)
        try await waitUntil { await collector.conversationEvents.count == 1 }
        let event = try #require(await collector.conversationEvents.first)
        #expect(event.text == "Fixed the failing test.")
        #expect(event.turnID == "original-user-event")
        #expect(try store.load().first?.state == .completed)
        let saved = try String(contentsOf: store.directory.appendingPathComponent("sessions-v1.json"), encoding: .utf8)
        #expect(!saved.contains("Fix a test"))
        #expect(!saved.contains("Fixed the failing test"))
        await coordinator.shutdown()
    }

    @Test func busyWorkspaceAndUnsafeEffectivePolicyCannotStartAnotherTurn() async throws {
        let (directory, _, transport, _, coordinator) = try fixture()
        _ = try await coordinator.execute(.start(directory: directory.path, task: "task"), conversationTurnIdentifier: nil, authorized: true)
        do { _ = try await coordinator.execute(.start(directory: directory.path, task: "duplicate"), conversationTurnIdentifier: nil, authorized: true); Issue.record("must reject busy workspace") } catch {}
        #expect(await transport.turnNumber == 1)
        await coordinator.shutdown()
        let (otherDirectory, _, unsafe, _, blocked) = try fixture()
        await unsafe.setUnsafe()
        do { _ = try await blocked.execute(.start(directory: otherDirectory.path, task: "task"), conversationTurnIdentifier: nil, authorized: true); Issue.record("must reject broad policy") } catch {}
        #expect(await unsafe.turnNumber == 0)
        await blocked.shutdown()
    }

    @Test func processCrashRequiresExplicitResumeWithoutTaskReplayAndCancellationNeedsTerminal() async throws {
        let (directory, store, transport, collector, coordinator) = try fixture()
        _ = try await coordinator.execute(.start(directory: directory.path, task: "first task"), conversationTurnIdentifier: "first", authorized: true)
        await transport.disconnect()
        try await waitUntil { (try? store.load().first?.state) == .needsResume }
        #expect(await transport.turnNumber == 1)
        let session = try #require(store.load().first)
        let resumedTransport = CodingFixtureTransport()
        await resumedTransport.setCwd(directory.resolvingSymlinksInPath().path)
        let restarted = PaceCodingSessionCoordinator(store: store, transportFactory: { _ in resumedTransport },
            eventSink: { await collector.record($0) }, approve: { _ in .cancel })
        let status = try await restarted.execute(.status(sessionID: nil), conversationTurnIdentifier: nil, authorized: false)
        #expect(status.contains("needsResume"))
        #expect(await resumedTransport.turnNumber == 0)
        _ = try await restarted.execute(.resume(sessionID: session.id, task: "new explicit task"), conversationTurnIdentifier: "resume-user", authorized: true)
        #expect(await resumedTransport.requests.contains { $0.0 == "thread/read" })
        #expect(await resumedTransport.requests.contains { $0.0 == "thread/resume" })
        let cancelled = try await restarted.execute(.cancel(sessionID: session.id), conversationTurnIdentifier: nil, authorized: false)
        #expect(cancelled.contains("interrupted"))
        #expect(await resumedTransport.interrupted)
        #expect(try store.load().first?.state == .interrupted)
        await restarted.shutdown()
    }

    @Test func runtimeApprovalOnlyAllowsExactScopedRequestOnceAndRejectsElevations() async throws {
        let (directory, _, transport, collector, coordinator) = try fixture()
        _ = try await coordinator.execute(.start(directory: directory.path, task: "task"), conversationTurnIdentifier: nil, authorized: true)
        var params: [String: PaceMCPJSONValue] = ["threadId": .string("thread-owned"), "turnId": .string("turn-1"),
            "itemId": .string("shell-1"), "kind": .string("humanCommand"), "command": .string("swift test"), "cwd": .string(directory.path)]
        await transport.send("item/commandExecution/requestApproval", params: params, id: .number(100))
        try await waitUntil { await transport.replies.count == 1 }
        #expect(await transport.replies.first?.1?.codingObject?["decision"] == .string("accept"))
        #expect(await collector.approvals.first?.approvalSummary.contains("swift test") == true)
        params["networkApprovalContext"] = .object(["host": .string("example.com")])
        await transport.send("item/commandExecution/requestApproval", params: params, id: .number(101))
        await transport.send("unknown/method", params: params, id: .number(102))
        try await waitUntil { await transport.replies.count == 3 }
        let replies = await transport.replies
        #expect(replies[1].1?.codingObject?["decision"] == .string("cancel"))
        #expect(replies[2].2 != nil)
        #expect(await collector.approvals.count == 1)
        params.removeValue(forKey: "networkApprovalContext")
        params.removeValue(forKey: "kind")
        await transport.send("item/commandExecution/requestApproval", params: params, id: .number(103))
        try await waitUntil { await transport.replies.count == 4 }
        #expect(await transport.replies.last?.1?.codingObject?["decision"] == .string("cancel"))
        #expect(await collector.approvals.count == 1)
        await coordinator.shutdown()
    }





    @Test func distinctWorkspaceSourcesCannotSpoofThreadsAndMayReuseServerApprovalIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaceCodingSources-" + UUID().uuidString)
        let firstPath = directory.appendingPathComponent("first").path
        let secondPath = directory.appendingPathComponent("second").path
        try FileManager.default.createDirectory(atPath: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: secondPath, withIntermediateDirectories: true)
        let first = CodingFixtureTransport(), second = CodingFixtureTransport()
        await first.setThreadID("first-thread"); await second.setThreadID("second-thread")
        let canonicalFirst = try PaceCodingSessionCoordinator.workspace(firstPath)
        let canonicalSecond = try PaceCodingSessionCoordinator.workspace(secondPath)
        let store = PaceCodingSessionStore(directory: directory.appendingPathComponent("state"))
        let collector = CodingEventCollector()
        let coordinator = PaceCodingSessionCoordinator(store: store,
            transportFactory: { $0.path == canonicalFirst.path ? first : second }, eventSink: { await collector.record($0) },
            approve: { request in await collector.approval(request); return .allowOnce })
        _ = try await coordinator.execute(.start(directory: firstPath, task: "First task"), conversationTurnIdentifier: "first", authorized: true)
        await second.suspendTurnStart()
        let secondStartup = Task { try await coordinator.execute(.start(directory: secondPath, task: "Second task"), conversationTurnIdentifier: "second", authorized: true) }
        try await waitUntil { await second.isTurnStartSuspended }
        await first.send("item/completed", params: ["threadId": .string("second-thread"), "turnId": .string("turn-1"),
            "item": .object(["id": .string("spoofed-final"), "type": .string("agentMessage"), "text": .string("SPOOFED_SLOT_RESULT")])])
        try await Task.sleep(for: .milliseconds(10))
        await second.resumeTurnStart()
        _ = try await secondStartup.value
        await first.send("turn/completed", params: ["threadId": .string("second-thread"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        for (transport, thread, workspace) in [(first, "first-thread", canonicalFirst), (second, "second-thread", canonicalSecond)] {
            await transport.send("item/commandExecution/requestApproval", params: ["threadId": .string(thread), "turnId": .string("turn-1"),
                "itemId": .string("checkpoint"), "kind": .string("humanCommand"), "command": .string("swift test"), "cwd": .string(workspace.path)], id: .number(1))
        }
        try await waitUntil {
            let firstCount = await first.replies.count
            let secondCount = await second.replies.count
            return firstCount == 1 && secondCount == 1
        }
        #expect(await first.replies.first?.1?.codingObject?["decision"] == .string("accept"))
        #expect(await second.replies.first?.1?.codingObject?["decision"] == .string("accept"))
        #expect(try store.load().first { $0.directory.path == canonicalSecond.path }?.state.isBusy == true)
        #expect(await collector.conversationEvents.isEmpty)
        #expect(await collector.approvals.count == 2)
        await second.send("turn/completed", params: ["threadId": .string("second-thread"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        try await waitUntil { await collector.conversationEvents.contains { $0.eventID.hasPrefix("coding-final-") } }
        #expect(await collector.conversationEvents.allSatisfy { !$0.text.contains("SPOOFED_SLOT_RESULT") })
        await coordinator.shutdown()
    }

    @Test func terminalRetirementCannotCloseSlotReservedByNewStart() async throws {
        let (directory, store, transport, collector, coordinator) = try fixture()
        _ = try await coordinator.execute(.start(directory: directory.path, task: "First task"), conversationTurnIdentifier: "first", authorized: true)
        await collector.suspendFinal()
        await transport.send("turn/completed", params: ["threadId": .string("thread-owned"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        try await waitUntil { await collector.isFinalSuspended }
        await transport.setThreadID("second-thread")
        await transport.suspendThreadStart()
        let second = Task { try await coordinator.execute(.start(directory: directory.path, task: "Second task"), conversationTurnIdentifier: "second", authorized: true) }
        try await waitUntil { await transport.isThreadStartSuspended }
        await collector.resumeFinal()
        try await Task.sleep(for: .milliseconds(10))
        #expect(await transport.shutdownCount == 0)
        await transport.resumeThreadStart()
        _ = try await second.value
        #expect(await transport.shutdownCount == 0)
        #expect(try store.load().first { $0.threadID.rawValue == "second-thread" }?.state == .running)
        await coordinator.shutdown()
    }

    @Test func fullCatalogFailsSpecificallyBeforeLaunchingAnythingAndKeepsHistory() async throws {
        let (directory, store, transport, _, coordinator) = try fixture()
        let canonical = try PaceCodingSessionCoordinator.workspace(directory.path)
        let saved = (0..<200).map { index in PaceCodingSessionSnapshot(id: .init(), directory: canonical,
            threadID: .init(rawValue: "old-\(index)"), lastTurnID: nil, conversationTurnIdentifier: nil, state: .completed, updatedAt: Date()) }
        try store.save(saved)
        do { _ = try await coordinator.execute(.start(directory: directory.path, task: "Task"), conversationTurnIdentifier: nil, authorized: true); Issue.record("full catalog must reject before launch") }
        catch { #expect(error.localizedDescription.contains("200-session coding catalog is full")) }
        #expect(await transport.requests.isEmpty)
        #expect(try store.load().count == 200)
        await coordinator.shutdown()
    }

    @Test func failedStartupInSecondWorkspaceCannotStopFirstWorkspaceOrSpoofItsThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaceCodingIsolation-" + UUID().uuidString)
        let firstWorkspace = directory.appendingPathComponent("first").resolvingSymlinksInPath()
        let secondWorkspace = directory.appendingPathComponent("second").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: firstWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
        let first = CodingFixtureTransport(), second = CodingFixtureTransport()
        await first.setThreadID("first-thread"); await second.setThreadID("second-thread")
        await second.failTurnStart()
        let store = PaceCodingSessionStore(directory: directory.appendingPathComponent("state"))
        let coordinator = PaceCodingSessionCoordinator(store: store, transportFactory: { $0.path == firstWorkspace.path ? first : second },
            eventSink: { _ in }, approve: { _ in .cancel })
        _ = try await coordinator.execute(.start(directory: firstWorkspace.path, task: "First task"), conversationTurnIdentifier: "first", authorized: true)
        do { _ = try await coordinator.execute(.start(directory: secondWorkspace.path, task: "Second task"), conversationTurnIdentifier: "second", authorized: true); Issue.record("second startup must fail") }
        catch {}
        #expect(await first.shutdownCount == 0)
        #expect(await second.shutdownCount > 0)
        #expect(try store.load().first { $0.directory.path == firstWorkspace.path }?.state == .running)
        await first.send("turn/completed", params: ["threadId": .string("second-thread"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        try await Task.sleep(for: .milliseconds(10))
        #expect(try store.load().first { $0.directory.path == secondWorkspace.path }?.state == .needsResume)
        await coordinator.shutdown()
    }

    @Test func resumeCannotRaceAnotherSessionWritingTheSameWorkspace() async throws {
        let (directory, store, transport, _, coordinator) = try fixture()
        let old = PaceCodingSessionSnapshot(id: .init(), directory: directory.resolvingSymlinksInPath(),
            threadID: .init(rawValue: "older-thread"), lastTurnID: nil, conversationTurnIdentifier: nil, state: .completed, updatedAt: Date())
        try store.save([old])
        _ = try await coordinator.execute(.start(directory: directory.path, task: "Current task"), conversationTurnIdentifier: "new", authorized: true)
        do { _ = try await coordinator.execute(.resume(sessionID: old.id, task: "Older task"), conversationTurnIdentifier: "old", authorized: true); Issue.record("workspace must have one writer") }
        catch { #expect(error.localizedDescription.contains("busy")) }
        #expect(await transport.requests.filter { $0.0 == "thread/resume" }.isEmpty)
        await coordinator.shutdown()
    }

    @Test func actualEscalationShapeIsDeniedWithoutModalOrAcceptance() async throws {
        let (directory, _, transport, collector, coordinator) = try fixture()
        _ = try await coordinator.execute(.start(directory: directory.path, task: "Task"), conversationTurnIdentifier: nil, authorized: true)
        await transport.send("item/commandExecution/requestApproval", params: ["threadId": .string("thread-owned"),
            "turnId": .string("turn-1"), "itemId": .string("echo-check"), "kind": .string("command"),
            "command": .string("/bin/echo PACE_APPROVAL_FIXTURE"), "cwd": .string(directory.path),
            "proposedExecpolicyAmendment": .array([.string("/bin/echo"), .string("PACE_APPROVAL_FIXTURE")])], id: .number(17))
        try await waitUntil { await transport.replies.count == 1 }
        #expect(await transport.replies.first?.1?.codingObject?["decision"] == .string("cancel"))
        #expect(await collector.approvals.isEmpty)
        await coordinator.shutdown()
    }

    @Test func shutdownDuringOpenWaitsForStaleCandidateAndNeverStartsThread() async throws {
        let (directory, _, transport, _, coordinator) = try fixture()
        await transport.suspendOpen()
        let starting = Task { try await coordinator.execute(.start(directory: directory.path, task: "Fix test"),
            conversationTurnIdentifier: "origin", authorized: true) }
        try await waitUntil { await transport.isOpenSuspended }
        let shutdown = Task { await coordinator.shutdown() }
        try await waitUntil { await transport.shutdownCount > 0 }
        await transport.resumeOpen()
        await shutdown.value
        do { _ = try await starting.value; Issue.record("closed coordinator cannot return a newly opened candidate") }
        catch { #expect(error is CancellationError || error is PaceCodingError) }
        #expect(await transport.requests.isEmpty)
        do { _ = try await coordinator.execute(.status(sessionID: nil), conversationTurnIdentifier: nil, authorized: false)
            Issue.record("closed coordinator rejects new work")
        } catch { #expect(error is PaceCodingError) }
    }

    @Test func cancelDuringTurnStartInterruptsNewIdentityAfterResponseInsteadOfLosingRequest() async throws {
        let (directory, store, transport, _, coordinator) = try fixture()
        await transport.suspendTurnStart()
        let start = Task { try await coordinator.execute(.start(directory: directory.path, task: "Fix test"),
            conversationTurnIdentifier: "origin", authorized: true) }
        try await waitUntil { await transport.isTurnStartSuspended }
        let session = try #require(store.load().first)
        let cancelling = try await coordinator.execute(.cancel(sessionID: session.id), conversationTurnIdentifier: nil, authorized: false)
        #expect(cancelling.contains("Waiting for its turn identity"))
        #expect(await transport.requests.filter { $0.0 == "turn/interrupt" }.isEmpty)
        await transport.resumeTurnStart()
        _ = try await start.value
        try await waitUntil { (try? store.load().first?.state) == .interrupted }
        #expect(await transport.requests.last { $0.0 == "turn/interrupt" }?.1["turnId"] == .string("turn-1"))
        await coordinator.shutdown()
    }

    @Test func terminalCannotOvertakeQueuedFinalWhileProgressRecorderIsSuspended() async throws {
        let (directory, _, transport, collector, coordinator) = try fixture()
        await collector.suspendProgress()
        await transport.setEarlyItems()
        let start = Task { try await coordinator.execute(.start(directory: directory.path, task: "Fix test"),
            conversationTurnIdentifier: "origin", authorized: true) }
        try await waitUntil { await collector.isProgressSuspended }
        await transport.send("turn/completed", params: ["threadId": .string("thread-owned"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        for _ in 0..<20 { await Task.yield() }
        await collector.resumeProgress()
        _ = try await start.value
        try await waitUntil { await collector.conversationEvents.contains { $0.eventID.hasPrefix("coding-final-") } }
        #expect(await collector.conversationEvents.last?.text == "Fixed the exact test.")
        await coordinator.shutdown()
    }

    @Test func strictParserAndExecutorReachAllFourOperationsWithControlsAvailableWhenDisabled() async throws {
        let identifier = UUID().uuidString
        for arguments in [
            "\"operation\":\"start\",\"directory\":\"/tmp/workspace\",\"task\":\"Fix test\"",
            "\"operation\":\"resume\",\"sessionID\":\"\(identifier)\",\"task\":\"Continue\"",
            "\"operation\":\"status\"", "\"operation\":\"cancel\",\"sessionID\":\"\(identifier)\""
        ] {
            let result = PaceActionTagParser.parseActions(from: "{\"spokenText\":\"Coding\",\"intent\":\"action\",\"payload\":{\"name\":\"coding_session\",\"args\":{\(arguments)}}}")
            #expect(result.actions.count == 1)
            guard case .codingSession(let command) = try #require(result.actions.first) else { Issue.record("missing coding command"); return }
            await MainActor.run {
                #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: result.executionPlan) == command.requiresExecutionConsent)
            }
            let executor = await PaceActionExecutor(actionsAreEnabledOverride: false)
            await MainActor.run { executor.executeCodingSession = { _ in .init(toolName: "coding_session", summary: "owned control reached") } }
            let observation = await executor.executeSingleAction(.codingSession(command), screenCaptures: [])
            #expect(observation?.summary == (command.requiresExecutionConsent ? "Coding not started. EnableActions is disabled." : "owned control reached"))
        }
        #expect(PaceCodingSessionCommand.parse(["operation": .string("status"), "networkAccess": .bool(true)]) == nil)
        #expect(PaceCodingSessionCommand.localControl("cancel that coding task") == .cancel(sessionID: nil))
        #expect(PacePowerCatalog.preinstalled.owner(of: .codingSession)?.id == "pace.coding")
        #expect(PacePowerCatalog.preinstalled.powers.count == 11)
    }
}


private actor CodingApprovalGate {
    private var continuation: CheckedContinuation<PaceActionApprovalDecision, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async -> PaceActionApprovalDecision { await withCheckedContinuation { continuation = $0 } }
    func cancel() { continuation?.resume(returning: .cancel); continuation = nil }
}

@MainActor
private final class CodingRoutingPlanner: BuddyPlannerClient {
    let displayName = "Fixture coding planner"
    let supportsImageInput = false
    var calls = 0
    var response = ""
    var receivedPrompt = ""
    func resetForNewTurn() {}
    func generateResponseStreaming(images: [(data: Data, label: String)], systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
        calls += 1
        receivedPrompt = userPrompt
        #expect(images.isEmpty)
        #expect(systemPrompt.contains("coding_session"))
        return (response, 0)
    }
}

@MainActor @Suite(.serialized)
struct PaceCodingManagerTests {
    @Test func naturalStartReachesSelectedPlannerApprovalAndExecutorWhileControlsNeedNoPlanner() async throws {
        let (manager, _, speech) = PaceConversationRecorderTests().makeDismissalFixture()
        let planner = CodingRoutingPlanner()
        planner.response = #"{"spokenText":"Starting coding","intent":"action","payload":{"name":"coding_session","args":{"operation":"start","directory":"/tmp/fixture-repo","task":"Fix the test"}}}"#
        manager.plannerClient = planner
        manager.codingSessionCoordinator = PaceCodingSessionCoordinator(store: PaceCodingSessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            eventSink: { _ in }, approve: { _ in .cancel })
        manager.textOnlyPlannerClient = planner
        manager.activePlannerTier = .local
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        var commands: [PaceCodingSessionCommand] = []
        var approvalCount = 0
        manager.actionApprovalPresentationOverride = { request in
            #expect(request.approvalSummary.contains("Fix the test")); approvalCount += 1; return .allowOnce
        }
        manager.actionExecutor.executeCodingSession = { command in
            commands.append(command); return .init(toolName: "coding_session", summary: "Coding session fixture running")
        }
        for transcript in ["work on /tmp/fixture-repo with Codex and fix the test", "Start a retained coding session in /tmp/fixture-repo and fix the test"] {
            manager.beginConversationRequest(transcript)
            let lease = manager.turnLeaseRegistry.beginTurn()
            await manager.sendTranscriptToPlannerWithScreenshotAsync(transcript: transcript, turnLease: lease)
        }
        #expect(planner.calls == 2)
        #expect(commands.count == 2)
        #expect(approvalCount == 2)
        #expect(!speech.spokenTexts.isEmpty)
        // No selected planner is needed to inspect owned work when actions are revoked.
        let collector = CodingEventCollector()
        let store = PaceCodingSessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        manager.codingSessionCoordinator = PaceCodingSessionCoordinator(store: store,
            transportFactory: { _ in CodingFixtureTransport() }, eventSink: { await collector.record($0) }, approve: { _ in .cancel })
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: false)
        let transcript = "coding status"
        manager.beginConversationRequest(transcript)
        let lease = manager.turnLeaseRegistry.beginTurn()
        await manager.sendTranscriptToPlannerWithScreenshotAsync(transcript: transcript, turnLease: lease)
        #expect(planner.calls == 2)
        #expect(manager.chatSession.messages.last?.body == "No retained coding sessions.")
    }

    @Test func closingDuringInitialApprovalCannotLaunchNewCodingJob() async throws {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let planner = CodingRoutingPlanner()
        planner.response = #"{"spokenText":"Starting","intent":"action","payload":{"name":"coding_session","args":{"operation":"start","directory":"/tmp/fixture-repo","task":"Fix test"}}}"#
        manager.plannerClient = planner
        manager.codingSessionCoordinator = PaceCodingSessionCoordinator(store: PaceCodingSessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            eventSink: { _ in }, approve: { _ in .cancel })
        manager.activePlannerTier = .local
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        var executions = 0
        manager.actionExecutor.executeCodingSession = { _ in executions += 1; return .init(toolName: "coding_session", summary: "must not run") }
        manager.actionApprovalPresentationOverride = { _ in
            manager.turnLeaseRegistry.invalidateCurrentTurn()
            return .allowOnce
        }
        let transcript = "work on /tmp/fixture-repo with Codex and fix test"
        manager.beginConversationRequest(transcript)
        let lease = manager.turnLeaseRegistry.beginTurn()
        await manager.sendTranscriptToPlannerWithScreenshotAsync(transcript: transcript, turnLease: lease)
        #expect(executions == 0)
    }
    @Test func foregroundCodingReplyRespectsMuteAndRevokedTurnWhileBackgroundFinalStaysWritten() async throws {
        let (manager, persister, speech) = PaceConversationRecorderTests().makeDismissalFixture()
        manager.beginConversationRequest("coding status")
        let lease = manager.turnLeaseRegistry.beginTurn()
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(true)
        await manager.deliverCodingForegroundReply("Coding is running.", transcript: "coding status", turnLease: lease)
        #expect(speech.spokenTexts.isEmpty)
        manager.streamingSentenceTTSPipeline.setMutedForCurrentTurn(false)
        manager.turnLeaseRegistry.invalidateCurrentTurn()
        await manager.deliverCodingForegroundReply("Late acknowledgement", transcript: "coding status", turnLease: lease)
        #expect(speech.spokenTexts.isEmpty)
        let event = ConversationEvent(eventID: "coding-final-fixture", turnID: "original-coding-turn",
            role: .pace, origin: .assistant, text: "Coding completed.")
        manager.handleCodingSessionEvent(.conversation(event))
        manager.handleCodingSessionEvent(.conversation(event))
        #expect(persister.events[event.eventID] == event)
        #expect(speech.spokenTexts.isEmpty)
    }

    @Test func shortForegroundSpeechKeepsFullSessionDetailsWrittenInTheSameCanonicalReply() async throws {
        let (manager, persister, speech) = PaceConversationRecorderTests().makeDismissalFixture()
        let message = "Coding session C80E9056-8F17-4457-8DA9-A0302F12A8B8 · /tmp/very/long/workspace · running"
        manager.beginConversationRequest("coding status")
        let lease = manager.turnLeaseRegistry.beginTurn()
        await manager.deliverCodingForegroundReply(message, transcript: "coding status", turnLease: lease)
        let short = "Coding in workspace is running."
        #expect(speech.spokenTexts.contains(short))
        #expect(!speech.spokenTexts.contains { $0.contains("C80E9056") || $0.contains("/tmp/") })
        #expect(persister.events.values.contains { $0.text == short + "\n\n" + message })
        #expect(CompanionManager.shortCodingAcknowledgement(message + "\n" + message) == "You have 2 retained coding sessions. Their details are in chat.")
    }

    @Test func routingKeepsQuestionsAndWarpLaunchesOnTheirExistingPaths() {
        for request in ["work on ~/projects/app with Codex and fix tests", "start a retained coding session in /tmp/app and add tests", "resume the coding task and add tests", "please continue my coding session with a new test"] {
            #expect(PaceCodingPower.requestsRetainedCoding(request))
        }
        for request in ["How do I fix a corrupted git repository?", "change my GitHub repository visibility", "What is a coding session?", "show the coding task on my screen", "open a codex session to fix tests in ~/proj", "start Codex in ~/projects/app", "launch Codex in Warp", "Start a Codex session in /tmp/app and fix tests"] {
            #expect(!PaceCodingPower.requestsRetainedCoding(request))
        }
    }

    @Test func foregroundCancellationCannotCancelApprovedStartupAndUnrelatedCloseDoesNotInterruptIt() async throws {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("PaceCodingBackground-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let transport = CodingFixtureTransport()
        await transport.suspendTurnStart()
        let store = PaceCodingSessionStore(directory: workspace.appendingPathComponent("state"))
        manager.codingSessionCoordinator = PaceCodingSessionCoordinator(store: store, transportFactory: { _ in transport }, eventSink: { _ in }, approve: { _ in .cancel })
        let foreground = Task { try await manager.performOwnedCodingCommand(.start(directory: workspace.path, task: "Fix task"), conversationTurnIdentifier: "original", authorized: true) }
        let deadline = Date().addingTimeInterval(3)
        while !(await transport.isTurnStartSuspended), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        foreground.cancel()
        manager.dismissCodingApprovals()
        await transport.resumeTurnStart()
        _ = try await foreground.value
        #expect(try store.load().first?.state == .running)
        #expect(await transport.shutdownCount == 0)
        #expect(await transport.requests.filter { $0.0 == "turn/interrupt" }.isEmpty)
        await manager.codingSessionCoordinator.shutdown()
    }

    @Test func spokenResumeReceivesOwnedSessionMetadataWithoutOldTaskOrTranscript() async throws {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaceVoiceResume-" + UUID().uuidString)
        let store = PaceCodingSessionStore(directory: directory.appendingPathComponent("state"))
        let saved = PaceCodingSessionSnapshot(id: .init(), directory: directory, threadID: .init(rawValue: "retained-thread"),
            lastTurnID: nil, conversationTurnIdentifier: "PRIVATE_PRIOR_EVENT", state: .completed, updatedAt: Date())
        try store.save([saved])
        manager.codingSessionCoordinator = PaceCodingSessionCoordinator(store: store, eventSink: { _ in }, approve: { _ in .cancel })
        let planner = CodingRoutingPlanner()
        planner.response = "{\"spokenText\":\"Resuming\",\"intent\":\"action\",\"payload\":{\"name\":\"coding_session\",\"args\":{\"operation\":\"resume\",\"sessionID\":\"\(saved.id.rawValue.uuidString)\",\"task\":\"Add tests\"}}}"
        manager.plannerClient = planner
        manager.activePlannerTier = .local
        manager.actionExecutor = PaceActionExecutor(actionsAreEnabledOverride: true)
        manager.actionApprovalPresentationOverride = { _ in .allowOnce }
        var resumed: PaceCodingSessionCommand?
        manager.actionExecutor.executeCodingSession = { command in resumed = command; return .init(toolName: "coding_session", summary: "Resumed.") }
        let request = "resume the coding task and add tests"
        manager.beginConversationRequest(request)
        let lease = manager.turnLeaseRegistry.beginTurn()
        await manager.sendTranscriptToPlannerWithScreenshotAsync(transcript: request, turnLease: lease)
        #expect(resumed == .resume(sessionID: saved.id, task: "Add tests"))
        #expect(planner.receivedPrompt.contains(saved.id.rawValue.uuidString))
        #expect(planner.receivedPrompt.contains(directory.lastPathComponent))
        #expect(!planner.receivedPrompt.contains("PRIVATE_PRIOR_EVENT"))
    }

    @Test func closingAnUnrelatedExplanationCannotInterruptAwaitingBackgroundCoding() async throws {
        let (manager, _, _) = PaceConversationRecorderTests().makeDismissalFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaceCodingModal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PaceCodingSessionStore(directory: directory.appendingPathComponent("state"))
        let transport = CodingFixtureTransport()
        let approval = CodingApprovalGate()
        manager.codingSessionCoordinator = PaceCodingSessionCoordinator(store: store, transportFactory: { _ in transport },
            eventSink: { _ in }, approve: { _ in await approval.wait() })
        _ = try await manager.performOwnedCodingCommand(.start(directory: directory.path, task: "Task"), conversationTurnIdentifier: "owned", authorized: true)
        await transport.send("item/commandExecution/requestApproval", params: ["threadId": .string("thread-owned"), "turnId": .string("turn-1"),
            "itemId": .string("checkpoint"), "kind": .string("humanCommand"), "command": .string("swift test"), "cwd": .string(directory.path)], id: .number(9))
        let deadline = Date().addingTimeInterval(3)
        while !(await approval.isWaiting), Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await approval.isWaiting)
        #expect(!manager.codingApprovalIsPresented)
        manager.dismissCodingApprovals()
        try await Task.sleep(for: .milliseconds(10))
        #expect(try store.load().first?.state == .awaitingApproval)
        #expect(await transport.requests.filter { $0.0 == "turn/interrupt" }.isEmpty)
        await approval.cancel()
        await manager.codingSessionCoordinator.shutdown()
    }

}
