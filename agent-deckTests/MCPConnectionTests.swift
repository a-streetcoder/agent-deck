import XCTest
@testable import agent_deck

/// In-process transport that answers outgoing JSON lines via a pure responder,
/// simulating an MCP server without spawning a process.
actor MCPAsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { guard !open else { return }; open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

/// A controllable duplex transport: tool writes can be held after they begin while
/// cancellation notifications continue through the reentrant actor.
actor MCPBlockingTransport: MCPTransport {
    nonisolated var supportsDuplexServerRequests: Bool { true }
    private var onLine: (@Sendable (String) -> Void)?
    private let toolStarted = MCPAsyncGate()
    private let releaseTool = MCPAsyncGate()
    private let cancellationSent = MCPAsyncGate()
    private var lines: [String] = []

    func start(onLine: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (MCPError?) -> Void) async throws { self.onLine = onLine }
    func send(_ line: String) async throws {
        lines.append(line)
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        switch object?["method"] as? String {
        case "initialize":
            let id = object?["id"] as? Int ?? 0
            onLine?(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-03-26","capabilities":{}}}"#)
        case "tools/call":
            await toolStarted.release()
            await releaseTool.wait()
        case "notifications/cancelled": await cancellationSent.release()
        default: break
        }
    }
    func close() async {}
    func waitForToolWrite() async { await toolStarted.wait() }
    func allowToolSendToFinish() async { await releaseTool.release() }
    func waitForCancellation() async { await cancellationSent.wait() }
    func sentLines() -> [String] { lines }
    func emit(_ line: String) { onLine?(line) }
}

actor MCPContextBox {
    private var stored: MCPCallContext?
    func set(_ context: MCPCallContext?) { stored = context }
    func value() -> MCPCallContext? { stored }
}

actor MCPStubTransport: MCPTransport {
    nonisolated var supportsDuplexServerRequests: Bool { true }
    typealias Responder = @Sendable (String) -> [String]
    private let responder: Responder
    private var onLine: (@Sendable (String) -> Void)?
    private var sent: [String] = []

    init(responder: @escaping Responder) { self.responder = responder }

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (MCPError?) -> Void) async throws {
        self.onLine = onLine
    }

    func send(_ line: String) async throws {
        sent.append(line)
        for response in responder(line) { onLine?(response) }
    }

    func close() async {}
    func sentLines() -> [String] { sent }
}

final class MCPTransportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var linesByConnection: [[String]] = []
    private var closeCounts: [Int: Int] = [:]
    func createID() -> Int { lock.lock(); defer { lock.unlock() }; linesByConnection.append([]); return linesByConnection.count - 1 }
    func record(_ line: String, id: Int) { lock.lock(); defer { lock.unlock() }; linesByConnection[id].append(line) }
    func closed(id: Int) { lock.lock(); defer { lock.unlock() }; closeCounts[id, default: 0] += 1 }
    func lines(for id: Int) -> [String] { lock.lock(); defer { lock.unlock() }; return linesByConnection[id] }
    func connectionCount() -> Int { lock.lock(); defer { lock.unlock() }; return linesByConnection.count }
    func closes(for id: Int) -> Int { lock.lock(); defer { lock.unlock() }; return closeCounts[id, default: 0] }
}

actor MCPRecordedTransport: MCPTransport {
    nonisolated var supportsDuplexServerRequests: Bool { true }
    private let id: Int; private let recorder: MCPTransportRecorder
    private var onLine: (@Sendable (String) -> Void)?
    init(id: Int, recorder: MCPTransportRecorder) { self.id = id; self.recorder = recorder }
    func start(onLine: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (MCPError?) -> Void) async throws { self.onLine = onLine }
    func send(_ line: String) async throws {
        recorder.record(line, id: id)
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let requestID = object?["id"] as? Int ?? 0
        switch object?["method"] as? String {
        case "initialize":
            let offered = ((object?["params"] as? [String: Any])?["protocolVersion"] as? String) ?? "2025-03-26"
            onLine?(#"{"jsonrpc":"2.0","id":\#(requestID),"result":{"protocolVersion":"\#(offered)","capabilities":{}}}"#)
        case "tools/list": onLine?(#"{"jsonrpc":"2.0","id":\#(requestID),"result":{"tools":[{"name":"list_apps"}]}}"#)
        default: break
        }
    }
    func close() async { recorder.closed(id: id) }
}

/// Deterministically holds individual transport closes so a configure call can be
/// interleaved with a newer one while MCPConnectionManager is reentrant.
actor CloseGate {
    private var entered = 0
    private var entryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var closeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func block() async {
        let index = entered
        entered += 1
        for continuation in entryWaiters.removeValue(forKey: entered) ?? [] { continuation.resume() }
        await withCheckedContinuation { closeWaiters[index] = $0 }
    }

    func waitUntilEntered(_ count: Int) async {
        guard entered < count else { return }
        await withCheckedContinuation { entryWaiters[count, default: []].append($0) }
    }

    func release(_ index: Int) { closeWaiters.removeValue(forKey: index)?.resume() }
}

actor DelayedCloseTransport: MCPTransport {
    private let base: MCPStubTransport
    private let gate: CloseGate

    init(responder: @escaping MCPStubTransport.Responder, gate: CloseGate) {
        self.base = MCPStubTransport(responder: responder)
        self.gate = gate
    }

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (MCPError?) -> Void) async throws {
        try await base.start(onLine: onLine, onClose: onClose)
    }

    func send(_ line: String) async throws { try await base.send(line) }
    func close() async { await gate.block() }
}

/// A small MCP server simulator. `answerCall` lets a test decide each tools/call result.
enum MCPMockServer {
    static func responder(answerCall: @escaping @Sendable (String) -> String?) -> MCPStubTransport.Responder {
        { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"] as? Int
            switch method {
            case "initialize":
                return [#"{"jsonrpc":"2.0","id":\#(id ?? 0),"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"mock","version":"1"}}}"#]
            case "notifications/initialized":
                return []
            case "tools/list":
                let params = object["params"] as? [String: Any]
                let cursor = params?["cursor"] as? String
                if cursor == "page2" {
                    return [#"{"jsonrpc":"2.0","id":\#(id ?? 0),"result":{"tools":[{"name":"add","description":"Add numbers"}]}}"#]
                }
                return [#"{"jsonrpc":"2.0","id":\#(id ?? 0),"result":{"tools":[{"name":"echo","description":"Echo text"}],"nextCursor":"page2"}}"#]
            case "tools/call":
                guard let id else { return [] }
                if let answer = answerCall(line) { return [answer] }
                return [] // no reply -> exercises timeout
            default:
                return []
            }
        }
    }

    static func callResult(id: Int, text: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"\#(text)"}],"isError":false}}"#
    }
}

private final class MCPComputerUseElicitationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingToolCallID: Int?

    func setPendingToolCallID(_ id: Int) { lock.lock(); defer { lock.unlock() }; pendingToolCallID = id }
    func takePendingToolCallID() -> Int? { lock.lock(); defer { lock.unlock() }; return pendingToolCallID }
}

final class MCPConnectionTests: XCTestCase {
    private func context(tool: String = "echo") -> MCPCallContext {
        MCPCallContext(sessionID: UUID(), projectID: "project", server: "mock", tool: tool, requestingAgent: "bound-agent", subagentRunID: UUID())
    }

    func testIntegerServerRequestIDCannotResolvePendingClientCallAndDeclines() async throws {
        let responder: MCPStubTransport.Responder = { line in
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let id = object?["id"] as? Int ?? 0
            switch object?["method"] as? String {
            case "initialize": return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-03-26","capabilities":{}}}"#]
            case "tools/call": return [#"{"jsonrpc":"2.0","id":\#(id),"method":"elicitation/create","params":{"message":"x","requestedSchema":{"type":"object","properties":{}}}}"#, MCPMockServer.callResult(id: id, text: "after-request")]
            default: return []
            }
        }
        let transport = MCPStubTransport(responder: responder)
        let connection = MCPConnection(name: "mock", config: MCPServerConfig(command: "noop"), transportFactory: { _ in transport })
        let result = try await connection.callTool(name: "echo", arguments: nil, context: context())
        XCTAssertEqual(result.combinedText, "after-request")
        try? await Task.sleep(for: .milliseconds(20))
        let sent = await transport.sentLines().joined()
        XCTAssertTrue(sent.contains(#""action":"decline""#))
    }

    func testHandlerUsesExactNegotiatedVersionAndReceivesContext() async throws {
        let seen = MCPContextBox()
        let responder: MCPStubTransport.Responder = { line in
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let id = object?["id"] as? Int ?? 0
            switch object?["method"] as? String {
            case "initialize": return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{}}}"#]
            case "tools/call": return [#"{"jsonrpc":"2.0","id":"elicitation-id","method":"elicitation/create","params":{"message":"x","requestedSchema":{"type":"object","properties":{}}}}"#]
            default: return []
            }
        }
        let transport = MCPStubTransport(responder: responder)
        let connection = MCPConnection(name: "mock", config: MCPServerConfig(command: "noop"), requestTimeout: .milliseconds(100), serverRequestHandler: { _, callContext in await seen.set(callContext); return .result(.object(["action": .string("accept")])) }, transportFactory: { _ in transport })
        let callContext = context()
        do { _ = try await connection.callTool(name: "echo", arguments: nil, context: callContext); XCTFail("expected timeout") } catch { }
        try? await Task.sleep(for: .milliseconds(20))
        let receivedContext = await seen.value()
        let sent = await transport.sentLines().joined()
        XCTAssertEqual(receivedContext, callContext)
        XCTAssertTrue(sent.contains(#""id":"elicitation-id""#))
    }
    func testSecondElicitationForOneToolCallDeclinesWithoutCancellingOriginal() async throws {
        let gate = MCPAsyncGate()
        let responder: MCPStubTransport.Responder = { line in
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let id = object?["id"] as? Int ?? 0
            switch object?["method"] as? String {
            case "initialize": return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{}}}"#]
            case "tools/call": return [
                #"{"jsonrpc":"2.0","id":"first","method":"elicitation/create","params":{"message":"first","requestedSchema":{"type":"object","properties":{}}}}"#,
                #"{"jsonrpc":"2.0","id":"second","method":"elicitation/create","params":{"message":"second","requestedSchema":{"type":"object","properties":{}}}}"#
            ]
            default: return []
            }
        }
        let transport = MCPStubTransport(responder: responder)
        let connection = MCPConnection(name: "mock", config: MCPServerConfig(command: "noop"), requestTimeout: .milliseconds(100), interactiveRequestTimeout: .seconds(1), serverRequestHandler: { request, _ in
            if request.id == .string("first") { await gate.wait() }
            return .result(MCPRequestFactory.elicitationResponse(action: "accept"))
        }, transportFactory: { _ in transport })
        let callContext = context()
        let call = Task { try await connection.callTool(name: "echo", arguments: nil, context: callContext) }
        try? await Task.sleep(for: .milliseconds(20))
        let beforeRelease = await transport.sentLines().joined()
        XCTAssertTrue(beforeRelease.contains(#""id":"second""#))
        XCTAssertTrue(beforeRelease.contains(#""action":"decline""#))
        XCTAssertFalse(beforeRelease.contains(#""id":"first","jsonrpc":"2.0","result":{"action":"accept""#))
        await gate.release()
        do { _ = try await call.value } catch { }
        let sent = await transport.sentLines().joined()
        XCTAssertTrue(sent.contains(#""id":"first""#))
        XCTAssertTrue(sent.contains(#""action":"accept""#))
    }

    func testHandlerEnabledConnectionRejectsMissingOrFutureSelectedProtocolVersion() async {
        for result in [#"{}"#, #"{"protocolVersion":"2026-01-01","capabilities":{}}"#] {
            let responder: MCPStubTransport.Responder = { line in
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                guard object?["method"] as? String == "initialize" else { return [] }
                let id = object?["id"] as? Int ?? 0
                return [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#]
            }
            let transport = MCPStubTransport(responder: responder)
            let connection = MCPConnection(name: "mock", config: MCPServerConfig(command: "noop"), serverRequestHandler: { _, _ in .result(.object([:])) }, transportFactory: { _ in transport })
            do { _ = try await connection.callTool(name: "echo", arguments: nil, context: context()); XCTFail("expected rejected negotiation") }
            catch { XCTAssertTrue(error.localizedDescription.contains("protocol") || error.localizedDescription.contains("missing")) }
        }
    }

    private func makeBlockingConnection(timeout: Duration = .seconds(5)) -> (MCPConnection, MCPBlockingTransport) {
        let transport = MCPBlockingTransport()
        return (MCPConnection(name: "mock", config: MCPServerConfig(command: "noop"), requestTimeout: timeout, transportFactory: { _ in transport }), transport)
    }

    func testCancellationAfterBlockingWriteSendsOneCancelledNotification() async throws {
        let (connection, transport) = makeBlockingConnection()
        let callContext = context()
        let call = Task { try await connection.callTool(name: "echo", arguments: nil, context: callContext) }
        await transport.waitForToolWrite()
        call.cancel()
        do { _ = try await call.value; XCTFail("expected cancellation") } catch { }
        await transport.waitForCancellation()
        let lines = await transport.sentLines()
        XCTAssertEqual(lines.filter { $0.contains("notifications/cancelled") }.count, 1)
        XCTAssertTrue(lines.contains { $0.contains(#""requestId":2"#) })
        await transport.allowToolSendToFinish()
        await transport.emit(#"{"jsonrpc":"2.0","id":2,"result":{"content":[]}}"#)
    }

    func testTimeoutAfterBlockingWriteSendsOneCancelledNotification() async throws {
        let (connection, transport) = makeBlockingConnection(timeout: .milliseconds(100))
        let callContext = context()
        let call = Task { try await connection.callTool(name: "echo", arguments: nil, context: callContext) }
        await transport.waitForToolWrite()
        do { _ = try await call.value; XCTFail("expected timeout") } catch { }
        await transport.waitForCancellation()
        let lines = await transport.sentLines()
        XCTAssertEqual(lines.filter { $0.contains("notifications/cancelled") }.count, 1)
        XCTAssertTrue(lines.contains { $0.contains(#""requestId":2"#) })
        await transport.allowToolSendToFinish()
    }

    func testCloseAfterBlockingWriteResolvesOnceAndIgnoresLateResponse() async throws {
        let (connection, transport) = makeBlockingConnection()
        let callContext = context()
        let call = Task { try await connection.callTool(name: "echo", arguments: nil, context: callContext) }
        await transport.waitForToolWrite()
        await connection.close()
        do { _ = try await call.value; XCTFail("expected cancellation") } catch { }
        // `close()` detaches the transport before failing pending calls, so it does
        // not promise a cancellation notification on a channel being torn down.
        await transport.allowToolSendToFinish()
        await transport.emit(#"{"jsonrpc":"2.0","id":2,"result":{"content":[]}}"#)
        let lines = await transport.sentLines()
        XCTAssertEqual(lines.filter { $0.contains("notifications/cancelled") }.count, 0)
    }

    func testAlreadyCancelledCallNeverWritesToolRequest() async throws {
        let (connection, transport) = makeBlockingConnection()
        let gate = MCPAsyncGate()
        let callContext = context()
        let call = Task { () throws -> MCPCallResult in
            await gate.wait()
            return try await connection.callTool(name: "echo", arguments: nil, context: callContext)
        }
        call.cancel()
        await gate.release()
        do { _ = try await call.value; XCTFail("expected cancellation") } catch { }
        let lines = await transport.sentLines()
        XCTAssertFalse(lines.contains { $0.contains("tools/call") })
    }

    private func makeConnection(timeout: Duration = .seconds(5),
                               answerCall: @escaping @Sendable (String) -> String?) -> MCPConnection {
        let responder = MCPMockServer.responder(answerCall: answerCall)
        return MCPConnection(
            name: "mock",
            config: MCPServerConfig(command: "noop"),
            requestTimeout: timeout,
            transportFactory: { _ in MCPStubTransport(responder: responder) }
        )
    }

    func testHandshakeThenListToolsPaginates() async throws {
        let connection = makeConnection { _ in nil }
        let tools = try await connection.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo", "add"])
        XCTAssertEqual(tools.first?.description, "Echo text")
    }

    func testCallToolReturnsCombinedText() async throws {
        let connection = makeConnection { line in
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            return MCPMockServer.callResult(id: id?["id"] as? Int ?? 0, text: "pong")
        }
        let result = try await connection.callTool(name: "echo", arguments: .object(["text": .string("ping")]))
        XCTAssertEqual(result.combinedText, "pong")
        XCTAssertEqual(result.isError, false)
    }

    func testCallToolNormalizesStringifiedObjectArguments() async throws {
        let connection = makeConnection { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["method"] as? String == "tools/call",
                  let id = object["id"] as? Int,
                  let params = object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any],
                  let text = arguments["text"] as? String,
                  let limit = arguments["limit"] as? Int else {
                return nil
            }
            return MCPMockServer.callResult(id: id, text: "\(text):\(limit)")
        }
        let result = try await connection.callTool(name: "echo", arguments: .string("{\"text\":\"ping\",\"limit\":2}"))
        XCTAssertEqual(result.combinedText, "ping:2")
    }

    func testCallToolTreatsWhitespaceStringArgumentsAsEmptyObject() async throws {
        let connection = makeConnection { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["method"] as? String == "tools/call",
                  let id = object["id"] as? Int,
                  let params = object["params"] as? [String: Any],
                  let arguments = params["arguments"] as? [String: Any],
                  arguments.isEmpty else {
                return nil
            }
            return MCPMockServer.callResult(id: id, text: "empty")
        }
        let result = try await connection.callTool(name: "echo", arguments: .string("  \n\t  "))
        XCTAssertEqual(result.combinedText, "empty")
    }

    func testCallToolRejectsMalformedStringArgumentsClientSide() async throws {
        let connection = makeConnection { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int ?? 0
            return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"server zod"}}"#
        }
        do {
            _ = try await connection.callTool(name: "echo", arguments: .string("{ nope"))
            XCTFail("expected client-side invalid arguments error")
        } catch let error as MCPError {
            guard case let .invalidArguments(message) = error else { return XCTFail("expected .invalidArguments, got \(error)") }
            XCTAssertTrue(message.contains("malformed JSON string"))
        }
    }

    func testCallToolRejectsNonObjectJSONStringArgumentsClientSide() async throws {
        let connection = makeConnection { _ in
            XCTFail("invalid arguments should be rejected before contacting the MCP server")
            return nil
        }
        do {
            _ = try await connection.callTool(name: "echo", arguments: .string("[1,2]"))
            XCTFail("expected client-side invalid arguments error")
        } catch let error as MCPError {
            guard case let .invalidArguments(message) = error else { return XCTFail("expected .invalidArguments, got \(error)") }
            XCTAssertTrue(message.contains("did not parse to an object"))
        }
    }

    func testCallToolTimesOutWhenServerSilent() async throws {
        let connection = makeConnection(timeout: .milliseconds(120)) { _ in nil }
        do {
            _ = try await connection.callTool(name: "echo", arguments: nil)
            XCTFail("expected timeout")
        } catch let error as MCPError {
            guard case .timeout = error else { return XCTFail("expected .timeout, got \(error)") }
        }
    }

    func testRpcErrorSurfacesAsMCPError() async throws {
        let connection = makeConnection { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int ?? 0
            return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"boom"}}"#
        }
        do {
            _ = try await connection.callTool(name: "echo", arguments: nil)
            XCTFail("expected rpc error")
        } catch let error as MCPError {
            guard case let .rpc(code, message) = error else { return XCTFail("expected .rpc, got \(error)") }
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "boom")
        }
    }
}

final class MCPConnectionManagerTests: XCTestCase {
    private func manager() -> MCPConnectionManager {
        let responder = MCPMockServer.responder { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int ?? 0
            return MCPMockServer.callResult(id: id, text: "ok")
        }
        return MCPConnectionManager(
            requestTimeout: .seconds(5),
            transportFactory: { _ in MCPStubTransport(responder: responder) }
        )
    }

    func testDiscoverCatalogScopedToAssignedServers() async throws {
        let manager = manager()
        await manager.configure(servers: [
            MCPServerEntry(name: "alpha", config: MCPServerConfig(command: "a"), sourcePath: "/a"),
            MCPServerEntry(name: "beta", config: MCPServerConfig(command: "b"), sourcePath: "/b")
        ])
        let scoped = await manager.discoverCatalog(serverNames: ["alpha"])
        XCTAssertEqual(Set(scoped.map(\.server)), ["alpha"])
        XCTAssertEqual(Set(scoped.map(\.tool)), ["echo", "add"])
        XCTAssertTrue(scoped.contains { $0.qualifiedName == "alpha/echo" })
    }

    func testSearchAndDescribeUseCache() async throws {
        let manager = manager()
        await manager.configure(servers: [
            MCPServerEntry(name: "alpha", config: MCPServerConfig(command: "a"), sourcePath: "/a")
        ])
        _ = await manager.discoverCatalog(serverNames: ["alpha"])
        let hits = await manager.search(query: "echo", serverNames: ["alpha"])
        XCTAssertEqual(hits.map(\.qualifiedName), ["alpha/echo"])
        let descriptor = await manager.describe(server: "alpha", tool: "add")
        XCTAssertEqual(descriptor?.description, "Add numbers")
    }

    func testCallRoutesToServer() async throws {
        let manager = manager()
        await manager.configure(servers: [
            MCPServerEntry(name: "alpha", config: MCPServerConfig(command: "a"), sourcePath: "/a")
        ])
        let result = try await manager.call(server: "alpha", tool: "echo", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "alpha", tool: "echo"))
        XCTAssertEqual(result.combinedText, "ok")
    }

    func testProvenanceCollisionReplacesEligibleConnectionWithoutElicitation() async {
        let recorder = MCPTransportRecorder()
        let manager = MCPConnectionManager(transportFactory: { _ in
            MCPRecordedTransport(id: recorder.createID(), recorder: recorder)
        })
        let config = MCPServerConfig(command: "same-helper")
        let plugin = MCPServerEntry(name: "codex-computer-use", config: config, sourcePath: "/plugin", provenance: .codexPlugin(version: "1", availability: "Available"), toolPolicy: .computerUseObservationOnly)
        await manager.setServerRequestHandler { _, _ in .result(MCPRequestFactory.elicitationResponse(action: "accept")) }
        await manager.configure(servers: [plugin])
        _ = await manager.discoverCatalog(serverNames: [plugin.name])
        XCTAssertTrue(recorder.lines(for: 0).joined().contains(#""elicitation":{}"#))

        let collision = MCPServerEntry(name: plugin.name, config: config, sourcePath: "/user", provenance: .config, toolPolicy: .unrestricted)
        await manager.configure(servers: [collision])
        _ = await manager.discoverCatalog(serverNames: [collision.name])
        XCTAssertEqual(recorder.connectionCount(), 2, "one untrusted transport replaces the eligible transport")
        XCTAssertGreaterThanOrEqual(recorder.closes(for: 0), 1, "the replaced eligible transport closes")
        XCTAssertTrue(recorder.lines(for: 1).contains { $0.contains("initialize") })
        XCTAssertFalse(recorder.lines(for: 1).joined().contains("elicitation"), "untrusted replacement must not advertise elicitation")
    }

    func testComputerUseCatalogAllowsExactlyObservationToolsRoutesStateThroughElicitationAndDeniesActions() async throws {
        let contextBox = MCPContextBox()
        let fixture = MCPComputerUseElicitationFixture()
        let responder: MCPStubTransport.Responder = { line in
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            let id = object?["id"] as? Int ?? 0
            switch object?["method"] as? String {
            case "initialize":
                return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"mock"}}}"#]
            case "tools/list":
                return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"list_apps"},{"name":"get_app_state"},{"name":"click"},{"name":"perform_secondary_action"},{"name":"set_value"},{"name":"select_text"},{"name":"scroll"},{"name":"drag"},{"name":"press_key"},{"name":"type_text"}]}}"#]
            case "tools/call":
                let tool = ((object?["params"] as? [String: Any])?["name"] as? String) ?? ""
                if tool == "get_app_state" {
                    fixture.setPendingToolCallID(id)
                    return [#"{"jsonrpc":"2.0","id":"approval","method":"elicitation/create","params":{"message":"Observe Agent Deck?","requestedSchema":{"type":"object","properties":{}}}}"#]
                }
                return [MCPMockServer.callResult(id: id, text: "ok")]
            default:
                guard object?["id"] as? String == "approval", let toolCallID = fixture.takePendingToolCallID() else { return [] }
                return [#"{"jsonrpc":"2.0","id":\#(toolCallID),"result":{"content":[{"type":"text","text":"Agent Deck window"},{"type":"image","data":"AQI=","mimeType":"image/png"}],"isError":false}}"#]
            }
        }
        let transport = MCPStubTransport(responder: responder)
        let manager = MCPConnectionManager(transportFactory: { _ in transport })
        await manager.setServerRequestHandler { _, context in
            await contextBox.set(context)
            return .result(MCPRequestFactory.elicitationResponse(action: "decline"))
        }
        await manager.configure(servers: [
            MCPServerEntry(name: "codex-computer-use", config: MCPServerConfig(command: "helper"), sourcePath: "/transient/.mcp.json", provenance: .codexPlugin(version: "1", availability: "Available"), toolPolicy: .computerUseObservationOnly)
        ])
        let catalog = await manager.discoverCatalog(serverNames: ["codex-computer-use"])
        let sessionID = UUID()
        let listAppsResult = try await manager.call(server: "codex-computer-use", tool: "list_apps", arguments: nil, context: MCPCallContext(sessionID: sessionID, projectID: nil, server: "codex-computer-use", tool: "list_apps"))
        let stateResult = try await manager.call(server: "codex-computer-use", tool: "get_app_state", arguments: .object(["app": .string("Agent Deck")]), context: MCPCallContext(sessionID: sessionID, projectID: nil, server: "codex-computer-use", tool: "get_app_state"))
        XCTAssertEqual(catalog.map(\.tool), ["list_apps", "get_app_state"])
        XCTAssertEqual(listAppsResult.combinedText, "ok")
        XCTAssertEqual(stateResult.content?.map(\.type), ["text", "image"])
        let envelope = PiMCPBridgeCallResultEnvelope.callResult(stateResult, server: "codex-computer-use", tool: "get_app_state")
        XCTAssertEqual(envelope.content.map(\.type), ["text", "image"])
        XCTAssertEqual(envelope.content[0].text, "Agent Deck window")
        XCTAssertEqual(envelope.content[1].data, "AQI=")
        let elicitedContext = await contextBox.value()
        XCTAssertEqual(elicitedContext?.tool, "get_app_state", "get_app_state must use the normal elicitation bridge path")
        let linesAfterObservation = await transport.sentLines()
        XCTAssertTrue(linesAfterObservation.contains { $0.contains(#""protocolVersion":"2025-06-18""#) })
        XCTAssertTrue(linesAfterObservation.contains { $0.contains(#""id":"approval""#) && $0.contains(#""action":"decline""#) })
        for (offset, action) in ["click", "perform_secondary_action", "set_value", "select_text", "scroll", "drag", "press_key", "type_text"].enumerated() {
            let before = await transport.sentLines().filter { $0.contains(#""method":"tools/call""#) }.count
            let subagentRunID = offset.isMultiple(of: 2) ? nil : UUID()
            do {
                _ = try await manager.call(server: "codex-computer-use", tool: action, arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "codex-computer-use", tool: action, requestingAgent: subagentRunID == nil ? nil : "child", subagentRunID: subagentRunID))
                XCTFail("\(action) must be denied before transport use")
            } catch let error as MCPError {
                XCTAssertEqual(error, .policyDenied("Codex Computer Use is observation-only in Agent Deck; only list_apps and get_app_state are allowed."))
            }
            let after = await transport.sentLines().filter { $0.contains(#""method":"tools/call""#) }.count
            XCTAssertEqual(after, before, "\(action) must not reach the MCP transport")
        }
    }

    func testComputerUseAuthorizationErrorIsRuntimeDiagnostic() async {
        let responder = MCPMockServer.responder { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int ?? 0
            return #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"Automation denied (-1743)"}],"isError":true}}"#
        }
        let manager = MCPConnectionManager(transportFactory: { _ in MCPStubTransport(responder: responder) })
        await manager.configure(servers: [
            MCPServerEntry(name: "codex-computer-use", config: MCPServerConfig(command: "helper"), sourcePath: "/transient/.mcp.json", provenance: .codexPlugin(version: "1", availability: "Available"), toolPolicy: .computerUseObservationOnly)
        ])
        do {
            _ = try await manager.call(server: "codex-computer-use", tool: "list_apps", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "codex-computer-use", tool: "list_apps"))
            XCTFail("expected authorization diagnostic")
        } catch let error as MCPError {
            XCTAssertEqual(error, .runtimeAuthorization("Computer Use needs macOS Automation permission (error -1743). In System Settings > Privacy & Security > Automation, allow Agent Deck to control the installed Computer Use/Codex component—not Pi—then retry. Agent Deck will not request, reset, or change macOS permissions automatically. Original helper error: Automation denied (-1743)"))
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testUnavailableServerNeverConfiguresOrConnects() async {
        let manager = manager()
        await manager.configure(servers: [
            MCPServerEntry(name: "codex-computer-use", config: MCPServerConfig(), sourcePath: "", provenance: .codexPlugin(version: nil, availability: "Unavailable"), toolPolicy: .computerUseObservationOnly, availabilityDiagnostic: "disabled")
        ])
        let connectedBefore = await manager.hasLiveConnection("codex-computer-use")
        let catalog = await manager.discoverCatalog(serverNames: ["codex-computer-use"])
        let connectedAfter = await manager.hasLiveConnection("codex-computer-use")
        XCTAssertFalse(connectedBefore)
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertFalse(connectedAfter)
    }

    @MainActor
    func testRefreshCoordinatorCannotRestoreOldConfigAfterInterleavedClose() async throws {
        let gate = CloseGate()
        let responder = MCPMockServer.responder { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int ?? 0
            return MCPMockServer.callResult(id: id, text: "new")
        }
        let manager = MCPConnectionManager(transportFactory: { config in
            guard config.command != "old-helper" else { throw MCPError.transportFailed("stale config restored") }
            return DelayedCloseTransport(responder: responder, gate: gate)
        })
        // Seed a live connection so both refreshes must await close().
        await manager.configure(servers: [MCPServerEntry(name: "server", config: MCPServerConfig(command: "new-helper"), sourcePath: "/seed")])
        _ = try await manager.call(server: "server", tool: "echo", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "server", tool: "echo"))

        let coordinator = MCPConfigurationRefreshCoordinator()
        let older = coordinator.begin()
        let oldEntry = MCPServerEntry(name: "server", config: MCPServerConfig(command: "old-helper"), sourcePath: "/old")
        let oldTask = Task { await coordinator.configureIfCurrent(older, servers: [oldEntry], manager: manager) }
        await gate.waitUntilEntered(1)

        let newer = coordinator.begin()
        let newEntry = MCPServerEntry(name: "server", config: MCPServerConfig(command: "new-helper"), sourcePath: "/new")
        let newTask = Task { await coordinator.configureIfCurrent(newer, servers: [newEntry], manager: manager) }

        // The newer refresh is now submitted with its new root while the old close is
        // blocked. e80c4c1 allowed the old operation to resume last and commit
        // old-helper; the shared generation must reject it before manager mutation.
        let newerApplied = await newTask.value
        await gate.release(0)
        let olderApplied = await oldTask.value
        let finalConfig = await manager.configuredConfig(server: "server")
        XCTAssertTrue(newerApplied)
        XCTAssertFalse(olderApplied)
        XCTAssertEqual(finalConfig?.command, "new-helper")

        let result = try await manager.call(server: "server", tool: "echo", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "server", tool: "echo"))
        XCTAssertEqual(result.combinedText, "new")
    }

    @MainActor
    func testLateStaleConfigureDoesNotAdvanceEpochWhileNewestCloseIsSuspended() async throws {
        let gate = CloseGate()
        let responder = MCPMockServer.responder { line in
            let id = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["id"] as? Int ?? 0
            return MCPMockServer.callResult(id: id, text: "new")
        }
        let manager = MCPConnectionManager(transportFactory: { config in
            guard config.command != "old-helper" else { throw MCPError.transportFailed("stale config restored") }
            return DelayedCloseTransport(responder: responder, gate: gate)
        })
        await manager.configure(servers: [MCPServerEntry(name: "server", config: MCPServerConfig(command: "seed-helper"), sourcePath: "/seed")])
        _ = try await manager.call(server: "server", tool: "echo", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "server", tool: "echo"))

        let coordinator = MCPConfigurationRefreshCoordinator()
        let staleToken = coordinator.begin()
        let newestToken = coordinator.begin()
        let newest = MCPServerEntry(name: "server", config: MCPServerConfig(command: "new-helper"), sourcePath: "/new")
        let stale = MCPServerEntry(name: "server", config: MCPServerConfig(command: "old-helper"), sourcePath: "/old")
        let newestTask = Task {
            await manager.configure(servers: [newest], refreshToken: newestToken, refreshCoordinator: coordinator)
        }
        await gate.waitUntilEntered(1)

        // This stale submission arrives after newest has entered and suspended in
        // close(). It must return before incrementing configurationEpoch.
        await manager.configure(servers: [stale], refreshToken: staleToken, refreshCoordinator: coordinator)
        await gate.release(0)
        await newestTask.value

        let finalConfig = await manager.configuredConfig(server: "server")
        let result = try await manager.call(server: "server", tool: "echo", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "server", tool: "echo"))
        XCTAssertEqual(finalConfig?.command, "new-helper")
        XCTAssertEqual(result.combinedText, "new")
    }

    func testCallUnknownServerThrows() async throws {
        let manager = manager()
        do {
            _ = try await manager.call(server: "ghost", tool: "x", arguments: nil, context: MCPCallContext(sessionID: UUID(), projectID: nil, server: "ghost", tool: "x"))
            XCTFail("expected serverNotConfigured")
        } catch let error as MCPError {
            guard case .serverNotConfigured = error else { return XCTFail("got \(error)") }
        }
    }

    func testResolveAddress() {
        XCTAssertEqual(MCPConnectionManager.resolveAddress("srv/tool", serverHint: nil)?.server, "srv")
        XCTAssertEqual(MCPConnectionManager.resolveAddress("srv/tool", serverHint: nil)?.tool, "tool")
        XCTAssertEqual(MCPConnectionManager.resolveAddress("tool", serverHint: "srv")?.server, "srv")
        XCTAssertNil(MCPConnectionManager.resolveAddress("tool", serverHint: nil))
    }
}
