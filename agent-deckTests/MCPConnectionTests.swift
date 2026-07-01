import XCTest
@testable import agent_deck

/// In-process transport that answers outgoing JSON lines via a pure responder,
/// simulating an MCP server without spawning a process.
actor MCPStubTransport: MCPTransport {
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

final class MCPConnectionTests: XCTestCase {
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
        let result = try await manager.call(server: "alpha", tool: "echo", arguments: nil)
        XCTAssertEqual(result.combinedText, "ok")
    }

    func testCallUnknownServerThrows() async throws {
        let manager = manager()
        do {
            _ = try await manager.call(server: "ghost", tool: "x", arguments: nil)
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
