import XCTest
@testable import pi_manager

@MainActor
final class PiAgentBridgeSmokeTests: XCTestCase {
    func testManagedSubagentBridgeRoutesRequestAndResponds() throws {
        let payload = #"{"agent":"scout","task":"Map the repo.","context":"fresh","reads":["README.md"]}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-subagent-1", name: "managed_subagent", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var captured: PiManagedSubagentBridgeRequest?
        runner.onManagedSubagentRequest = { _, request, completion in
            captured = request
            completion("subagent accepted")
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            PiTestSupport.extensionUIResponses(in: harness.stdinLog).contains { $0["id"] as? String == "bridge-subagent-1" }
        })
        XCTAssertEqual(captured?.agent, "scout")
        XCTAssertEqual(captured?.task, "Map the repo.")
        XCTAssertEqual(captured?.context, "fresh")
        XCTAssertEqual(captured?.reads, ["README.md"])
        XCTAssertEqual(responseValue(id: "bridge-subagent-1", in: harness.stdinLog), "subagent accepted")
        XCTAssertEqual(store.transcriptsBySessionID[session.id]?.last?.title, "Native Subagent Requested")
    }

    func testManagedChainBridgeRoutesRequestAndResponds() throws {
        let payload = #"{"chain":"review-chain","task":"Review current changes.","worktree":true}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-chain-1", name: "managed_chain", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var captured: PiManagedChainBridgeRequest?
        runner.onManagedChainRequest = { _, request, completion in
            captured = request
            completion("chain accepted")
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-chain-1", in: harness.stdinLog) == "chain accepted" })
        XCTAssertEqual(captured?.chain, "review-chain")
        XCTAssertEqual(captured?.task, "Review current changes.")
        XCTAssertEqual(captured?.worktree, true)
    }

    func testManagedParallelBridgeRoutesRequestAndResponds() throws {
        let payload = #"{"tasks":[{"agent":"scout","task":"Map"},{"agent":"reviewer","task":"Review"}],"concurrency":2,"worktree":true}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-parallel-1", name: "managed_parallel", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var captured: PiManagedParallelBridgeRequest?
        runner.onManagedParallelRequest = { _, request, completion in
            captured = request
            completion("parallel accepted")
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-parallel-1", in: harness.stdinLog) == "parallel accepted" })
        XCTAssertEqual(captured?.tasks.map(\.agent), ["scout", "reviewer"])
        XCTAssertEqual(captured?.concurrency, 2)
        XCTAssertEqual(captured?.worktree, true)
    }

    func testSupervisorListAndAnswerBridgeRoutesWithoutOpeningEditorUI() throws {
        let listEvent = PiRPCBridgeFixtures.bridgeEditor(id: "bridge-list-1", name: "list_supervisor_requests", payload: #"{}"#)
        let answerPayload = #"{"requestID":"request-1","response":"Use worktree."}"#
        let answerEvent = PiRPCBridgeFixtures.bridgeEditor(id: "bridge-answer-1", name: "answer_supervisor_request", payload: answerPayload)
        let harness = try PiTestSupport.makeBridgeHarness(events: [listEvent, answerEvent])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSupervisorRequestsList = { _ in #"[{"id":"request-1","kind":"need_decision"}]"# }
        runner.onSupervisorRequestAnswer = { _, requestID, response in
            "\(requestID): \(response)"
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            responseValue(id: "bridge-list-1", in: harness.stdinLog) != nil
                && responseValue(id: "bridge-answer-1", in: harness.stdinLog) != nil
        })
        XCTAssertEqual(responseValue(id: "bridge-list-1", in: harness.stdinLog), #"[{"id":"request-1","kind":"need_decision"}]"#)
        XCTAssertEqual(responseValue(id: "bridge-answer-1", in: harness.stdinLog), "request-1: Use worktree.")
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testSetAndUpdateSessionPlanBridgePersistPlanAndRespond() throws {
        let setPayload = #"{"items":[{"id":"inspect","title":"Inspect","status":"in_progress"},{"id":"finish","title":"Finish","status":"todo"}]}"#
        let updatePayload = #"{"updates":[{"id":"inspect","status":"done"},{"id":"finish","status":"in_progress"}]}"#
        let harness = try PiTestSupport.makeBridgeHarness(events: [
            PiRPCBridgeFixtures.bridgeEditor(id: "bridge-plan-set", name: "set_session_plan", payload: setPayload),
            PiRPCBridgeFixtures.bridgeEditor(id: "bridge-plan-update", name: "update_session_plan", payload: updatePayload)
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSessionPlanSet = { sessionID, request in
            let plan = store.setSessionPlan(sessionID: sessionID, items: request.items)
            return "set \(plan.items.count)"
        }
        runner.onSessionPlanUpdate = { sessionID, request in
            let plan = store.updateSessionPlan(sessionID: sessionID, updates: request.updates)
            return "updated \(plan?.items.count ?? 0)"
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            responseValue(id: "bridge-plan-set", in: harness.stdinLog) == "set 2"
                && responseValue(id: "bridge-plan-update", in: harness.stdinLog) == "updated 2"
        })
        XCTAssertEqual(store.sessionPlan(for: session.id)?.items.map(\.status), [.done, .inProgress])
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testParentSessionLaunchInjectsNativeBridgeExtensionAndCatalogOnlyWhenEnabled() throws {
        let enabledHarness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { enabledHarness.restoreEnvironment() }

        let enabledStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let enabledRunner = PiAgentRunnerService(store: enabledStore)
        enabledRunner.nativeSubagentCatalogProvider = { _ in "Native catalog prompt." }
        let enabledSession = enabledStore.createSession(kind: .project, title: "Enabled", project: try PiTestSupport.makeProject(), repository: nil)

        enabledRunner.resume(session: enabledSession)
        defer { enabledRunner.stop(sessionID: enabledSession.id) }

        let enabledCommand = try XCTUnwrap(enabledStore.sessions.first(where: { $0.id == enabledSession.id })?.launchCommand)
        XCTAssertTrue(enabledCommand.contains("--extension"))
        XCTAssertTrue(enabledCommand.contains("system-prompt-audit-bridge.ts"))
        XCTAssertTrue(enabledCommand.contains("managed-subagent-bridge.ts"))
        XCTAssertTrue(enabledCommand.contains("--append-system-prompt"))
        XCTAssertTrue(enabledCommand.contains("Native catalog prompt."))

        let disabledHarness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { disabledHarness.restoreEnvironment() }

        let disabledStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let disabledRunner = PiAgentRunnerService(store: disabledStore)
        disabledRunner.nativeSubagentCatalogProvider = { _ in "Native catalog prompt." }
        var disabledSession = disabledStore.createSession(kind: .project, title: "Disabled", project: try PiTestSupport.makeProject(), repository: nil)
        disabledStore.updateSession(disabledSession.id) { $0.subagentsEnabled = false }
        disabledSession = try XCTUnwrap(disabledStore.sessions.first(where: { $0.id == disabledSession.id }))

        disabledRunner.resume(session: disabledSession)
        defer { disabledRunner.stop(sessionID: disabledSession.id) }

        let disabledCommand = try XCTUnwrap(disabledStore.sessions.first(where: { $0.id == disabledSession.id })?.launchCommand)
        XCTAssertTrue(disabledCommand.contains("system-prompt-audit-bridge.ts"))
        XCTAssertFalse(disabledCommand.contains("managed-subagent-bridge.ts"))
        XCTAssertFalse(disabledCommand.contains("--append-system-prompt"))
        XCTAssertFalse(disabledCommand.contains("Native catalog prompt."))
    }

    func testParentSessionCapturesRuntimeSystemPromptAudit() throws {
        let payload = #"{"scope":"parent","systemPrompt":"Final parent prompt from Pi."}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "audit-parent-1", name: "system_prompt_audit", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Audit", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.finalSystemPrompt == "Final parent prompt from Pi."
                && responseValue(id: "audit-parent-1", in: harness.stdinLog) == "System prompt captured."
        })
        XCTAssertNotNil(store.sessions.first(where: { $0.id == session.id })?.finalSystemPromptCapturedAt)
    }

    func testMalformedBridgeStillRespondsAndDoesNotOpenEditorUI() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-plan-bad", name: "set_session_plan", payload: "{not-json"))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-plan-bad", in: harness.stdinLog) != nil })
        XCTAssertEqual(responseValue(id: "bridge-plan-bad", in: harness.stdinLog), "Pi Manager could not parse the session plan request.")
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testNestedBridgeEditorShapeIsRecognized() throws {
        let payload = #"{"items":[{"id":"inspect","title":"Inspect","status":"in_progress"}]}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.nestedBridgeEditor(id: "bridge-plan-nested", name: "set_session_plan", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSessionPlanSet = { sessionID, request in
            let plan = store.setSessionPlan(sessionID: sessionID, items: request.items)
            return "set \(plan.items.count)"
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-plan-nested", in: harness.stdinLog) == "set 1" })
        XCTAssertEqual(store.sessionPlan(for: session.id)?.items.first?.id, "inspect")
    }

    func testRegularEditorRequestStillBecomesInteractiveUIRequest() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.regularEditor(id: "editor-1"))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.uiRequestsBySessionID[session.id]?.id == "editor-1" })
        XCTAssertEqual(store.uiRequestsBySessionID[session.id]?.method, .editor)
        XCTAssertTrue(PiTestSupport.extensionUIResponses(in: harness.stdinLog).isEmpty)
    }

    private func responseValue(id: String, in logURL: URL) -> String? {
        PiTestSupport.extensionUIResponses(in: logURL).first { $0["id"] as? String == id }?["value"] as? String
    }
}
