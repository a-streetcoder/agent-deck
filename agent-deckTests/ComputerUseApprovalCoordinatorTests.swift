import XCTest
@testable import agent_deck

@MainActor
final class ComputerUseApprovalCoordinatorTests: XCTestCase {
    private func elicitation(message: String = "Allow access?", properties: JSONValue = .object([:]), required: JSONValue? = nil) -> MCPElicitationRequest {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": properties]
        if let required { schema["required"] = required }
        return MCPElicitationRequest(id: .string(UUID().uuidString), params: .object(["message": .string(message), "requestedSchema": .object(schema)]))!
    }

    private func context(sessionID: UUID = UUID(), agent: String? = "bound", run: UUID? = nil) -> MCPCallContext {
        MCPCallContext(sessionID: sessionID, projectID: "project", server: ComputerUseCapability.serverName, tool: "list_apps", requestingAgent: agent, subagentRunID: run)
    }

    private func action(_ value: MCPServerRequestDisposition) -> String? {
        guard case let .result(.object(object)) = value else { return nil }
        return object["action"]?.stringValue
    }

    func testAcceptDeclineAndCancelUseExactResponses() async {
        for expected in ["accept", "decline", "cancel"] {
            let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
            coordinator.setUIServicingRequests(true)
            let context = context()
            let task = Task { await coordinator.enqueue(self.elicitation(), context: context, sessionIsLive: true) }
            await Task.yield()
            let request = try! XCTUnwrap(coordinator.request(for: context.sessionID))
            if expected == "accept" { coordinator.accept(request) }
            else if expected == "decline" { coordinator.decline(request) }
            else { coordinator.cancel(request) }
            let result = await task.value
            XCTAssertEqual(action(result), expected)
            if case let .result(.object(object)) = result { XCTAssertEqual(object["content"], .object([:])) }
        }
    }

    func testFIFOIsPerSessionAndOtherSessionRemainsVisible() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let first = context(), second = context(sessionID: first.sessionID), other = context()
        let one = Task { await coordinator.enqueue(self.elicitation(message: "one"), context: first, sessionIsLive: true) }
        let two = Task { await coordinator.enqueue(self.elicitation(message: "two"), context: second, sessionIsLive: true) }
        let three = Task { await coordinator.enqueue(self.elicitation(message: "other"), context: other, sessionIsLive: true) }
        await Task.yield()
        XCTAssertEqual(coordinator.request(for: first.sessionID)?.message, "one")
        XCTAssertEqual(coordinator.request(for: other.sessionID)?.message, "other")
        coordinator.decline(coordinator.request(for: first.sessionID)!)
        await Task.yield()
        XCTAssertEqual(coordinator.request(for: first.sessionID)?.message, "two")
        coordinator.cancel(coordinator.request(for: first.sessionID)!); coordinator.cancel(coordinator.request(for: other.sessionID)!)
        _ = await (one.value, two.value, three.value)
    }

    func testTimeoutAndTaskCancellationRemoveExactlyOnce() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 0.01)
        coordinator.setUIServicingRequests(true)
        let context = context()
        let task = Task { await coordinator.enqueue(self.elicitation(), context: context, sessionIsLive: true) }
        try? await Task.sleep(for: .milliseconds(40))
        let timedOut = await task.value
        XCTAssertEqual(action(timedOut), "cancel")
        XCTAssertNil(coordinator.request(for: context.sessionID))

        let pending = Task { await coordinator.enqueue(self.elicitation(), context: context, sessionIsLive: true) }
        await Task.yield(); pending.cancel()
        let cancelled = await pending.value
        XCTAssertEqual(action(cancelled), "cancel")
        XCTAssertNil(coordinator.request(for: context.sessionID))
    }

    func testSubagentRunCleanupCancelsOnlyThatExecutionRun() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let run = UUID(), otherRun = UUID(), session = UUID()
        let first = context(sessionID: session, run: run)
        let second = context(sessionID: session, run: otherRun)
        let firstTask = Task { await coordinator.enqueue(self.elicitation(), context: first, sessionIsLive: true) }
        let secondTask = Task { await coordinator.enqueue(self.elicitation(message: "second"), context: second, sessionIsLive: true) }
        await Task.yield()
        coordinator.cancel(subagentRunID: run)
        let firstResult = await firstTask.value
        XCTAssertEqual(action(firstResult), "cancel")
        XCTAssertEqual(coordinator.request(for: session)?.subagentRunID, otherRun)
        coordinator.cancel(coordinator.request(for: session)!)
        _ = await secondTask.value
    }

    func testProductionGraphChildStopDismissesApprovalBeforeRunnerStop() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let executionRunID = UUID(), sessionID = UUID()
        let context = context(sessionID: sessionID, run: executionRunID)
        let task = Task { await coordinator.enqueue(self.elicitation(), context: context, sessionIsLive: true) }
        await Task.yield()
        var stopObservedDismissal = false
        AppViewModel.stopGraphChildExecution(executionRunID, coordinator: coordinator) { id in
            XCTAssertEqual(id, executionRunID)
            stopObservedDismissal = coordinator.request(for: sessionID) == nil
        }
        XCTAssertTrue(stopObservedDismissal)
        let result = await task.value
        XCTAssertEqual(action(result), "cancel")
    }

    func testRequiredFieldsAndUnavailableUIFailClosed() async {
        let coordinator = ComputerUseApprovalCoordinator()
        let context = context(agent: "delegated", run: UUID())
        let required = await coordinator.enqueue(elicitation(properties: .object(["name": .object(["type": .string("string")])]), required: .array([.string("name")])), context: context, sessionIsLive: true)
        XCTAssertEqual(action(required), "decline")
        let unavailable = await coordinator.enqueue(elicitation(), context: context, sessionIsLive: true)
        XCTAssertEqual(action(unavailable), "decline")
    }
}


extension ComputerUseApprovalCoordinatorTests {
    private func appArguments(_ app: JSONValue) -> JSONValue { .object(["app": app]) }

    func testControlGrantsAreScopedToParentBoundAndDelegatedRequesters() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let session = UUID(), runA = UUID(), runB = UUID()
        let parent = context(sessionID: session, agent: nil)
        let bound = context(sessionID: session, agent: "bound")
        let childA = context(sessionID: session, agent: "child", run: runA)
        let childB = context(sessionID: session, agent: "child", run: runB)
        let task = Task { await coordinator.authorize(appArguments: self.appArguments(.string(" Safari.app ")), context: childA, sessionIsLive: true) }
        await Task.yield()
        let request = try! XCTUnwrap(coordinator.request(for: session))
        XCTAssertEqual(request.kind, .controlApp)
        XCTAssertEqual(request.appTarget, "safari.app")
        XCTAssertTrue(request.message.contains("Allow"))
        coordinator.accept(request)
        let taskResult = await task.value
        XCTAssertEqual(taskResult, .authorized)
        XCTAssertTrue(coordinator.hasGrant(appArguments: appArguments(.string("safari.app")), context: childA))
        XCTAssertFalse(coordinator.hasGrant(appArguments: appArguments(.string("safari.app")), context: parent))
        XCTAssertFalse(coordinator.hasGrant(appArguments: appArguments(.string("safari.app")), context: bound))
        XCTAssertFalse(coordinator.hasGrant(appArguments: appArguments(.string("safari.app")), context: childB))
    }

    func testSameKeyControlCoalescesAndAcceptResumesAllWaiters() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let context = context(agent: "agent")
        let one = Task { await coordinator.authorize(appArguments: self.appArguments(.string("com.apple.Safari")), context: context, sessionIsLive: true) }
        let two = Task { await coordinator.authorize(appArguments: self.appArguments(.string("com.apple.safari")), context: context, sessionIsLive: true) }
        await Task.yield()
        let request = try! XCTUnwrap(coordinator.request(for: context.sessionID))
        XCTAssertEqual(request.appTarget, "com.apple.safari")
        coordinator.accept(request)
        let oneResult = await one.value
        let twoResult = await two.value
        XCTAssertEqual(oneResult, .authorized)
        XCTAssertEqual(twoResult, .authorized)
    }

    func testControlDenialCancellationTimeoutAndMalformedArgumentsFailClosed() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 0.01)
        coordinator.setUIServicingRequests(true)
        let context = context()
        let invalid = await coordinator.authorize(appArguments: nil, context: context, sessionIsLive: true)
        let missing = await coordinator.authorize(appArguments: .object([:]), context: context, sessionIsLive: true)
        let nonString = await coordinator.authorize(appArguments: appArguments(.number(1)), context: context, sessionIsLive: true)
        let control = await coordinator.authorize(appArguments: appArguments(.string("bad\u{7f}")), context: context, sessionIsLive: true)
        XCTAssertEqual(invalid, .denied(.invalidArguments))
        XCTAssertEqual(missing, .denied(.missingApp))
        XCTAssertEqual(nonString, .denied(.nonStringApp))
        XCTAssertEqual(control, .denied(.appContainsControlCharacters))
        let timed = Task { await coordinator.authorize(appArguments: self.appArguments(.string("Safari")), context: context, sessionIsLive: true) }
        try? await Task.sleep(for: .milliseconds(40))
        let timedResult = await timed.value
        XCTAssertEqual(timedResult, .denied(.expired))
        let cancelled = Task { await coordinator.authorize(appArguments: self.appArguments(.string("Notes")), context: context, sessionIsLive: true) }
        await Task.yield(); cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertEqual(cancelledResult, .denied(.cancelled))
    }

    func testControlRevocationAndServiceElicitationDoNotCreateGrants() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let session = UUID(), run = UUID()
        let child = context(sessionID: session, agent: "child", run: run)
        let task = Task { await coordinator.authorize(appArguments: self.appArguments(.string("/Applications/Safari.app")), context: child, sessionIsLive: true) }
        await Task.yield(); coordinator.accept(coordinator.request(for: session)!)
        _ = await task.value
        XCTAssertTrue(coordinator.hasGrant(appArguments: appArguments(.string("/Applications/Safari.app")), context: child))
        coordinator.revoke(subagentRunID: run)
        XCTAssertFalse(coordinator.hasGrant(appArguments: appArguments(.string("/Applications/Safari.app")), context: child))
        let elicitationTask = Task { await coordinator.enqueue(self.elicitation(), context: child, sessionIsLive: true) }
        await Task.yield(); coordinator.accept(coordinator.request(for: session)!)
        _ = await elicitationTask.value
        XCTAssertFalse(coordinator.hasGrant(appArguments: appArguments(.string("/Applications/Safari.app")), context: child))
        coordinator.revoke(sessionID: session)
        coordinator.revokeAll()
    }
}

extension ComputerUseApprovalCoordinatorTests {
    func testCancellingOneCoalescedControlWaiterDoesNotCancelTheOther() async {
        let coordinator = ComputerUseApprovalCoordinator(timeout: 10)
        coordinator.setUIServicingRequests(true)
        let context = context()
        let first = Task { await coordinator.authorize(appArguments: self.appArguments(.string("Safari")), context: context, sessionIsLive: true) }
        let second = Task { await coordinator.authorize(appArguments: self.appArguments(.string("Safari")), context: context, sessionIsLive: true) }
        await Task.yield()
        first.cancel()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .denied(.cancelled))
        let request = try! XCTUnwrap(coordinator.request(for: context.sessionID))
        coordinator.accept(request)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, .authorized)
    }
}
