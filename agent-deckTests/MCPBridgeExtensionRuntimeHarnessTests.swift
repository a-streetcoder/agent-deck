import XCTest
@testable import agent_deck

/// Executes the generated TypeScript through the installed Pi runtime's jiti loader
/// with a minimal ExtensionAPI/UI. This verifies behavior rather than source tokens.
final class MCPBridgeExtensionRuntimeHarnessTests: XCTestCase {
    @MainActor
    func testGeneratedExtensionPreservesMixedContentAndMarksOnlyCorrelatedErrors() throws {
        let node = "/Users/andrea/.hermes/node/bin/node"
        let jiti = "/Users/andrea/.hermes/hermes-agent/node_modules/jiti"
        guard FileManager.default.isExecutableFile(atPath: node), FileManager.default.fileExists(atPath: jiti) else {
            throw XCTSkip("Installed Pi runtime jiti loader is unavailable.")
        }

        let source = try PiNativeSubagentBridgeExtensions.mcpExtensionURL()
        let script = #"""
        const createJiti = require(process.argv[1]);
        const jiti = createJiti(process.cwd() + "/agent-deck-mcp-harness.cjs", { interopDefault: true });
        const loadedExtension = jiti(process.argv[2]);
        const extension = loadedExtension.default ?? loadedExtension;
        let tool;
        let toolResult;
        const pi = {
          registerTool(value) { tool = value; },
          on(name, handler) { if (name === "tool_result") toolResult = handler; }
        };
        extension(pi);
        (async () => {
        const responses = {
          success: JSON.stringify({ version: 1, server: "photos", tool: "inspect", isError: false, content: [
            { type: "text", text: "before" }, { type: "image", data: "AQI=", mimeType: "image/png" }, { type: "text", text: "after" }
          ] }),
          errorA: JSON.stringify({ version: 1, server: "alpha", tool: "fail", isError: true, content: [{ type: "text", text: "first failure" }] }),
          errorB: JSON.stringify({ version: 1, server: "beta", tool: "fail", isError: true, content: [{ type: "text", text: "second failure" }] }),
          fallback: "legacy bridge text"
        };
        const ctx = { ui: { editor: async (_title, payload) => responses[JSON.parse(payload).toolCallId] } };
        const execute = (id) => tool.execute(id, { tool: "server/tool" }, undefined, undefined, ctx);
        const success = await execute("success");
        const [errorA, errorB] = await Promise.all([execute("errorA"), execute("errorB")]);
        const fallback = await execute("fallback");
        const finalize = (id, result) => toolResult({ type: "tool_result", toolName: "mcp", toolCallId: id, input: {}, content: result.content, details: result.details, isError: false });
        const finalizedA = finalize("errorA", errorA);
        const finalizedB = finalize("errorB", errorB);
        const mismatched = finalize("other-call", errorA);
        console.log(JSON.stringify({ success, errorA, errorB, fallback, finalizedA, finalizedB, mismatched }));
        })().catch(error => { console.error(error); process.exit(1); });
        """#
        let output = try run(executable: node, arguments: ["-e", script, jiti, source.path])
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let success = try XCTUnwrap(result?["success"] as? [String: Any])
        XCTAssertEqual((success["content"] as? [[String: Any]])?.map { $0["type"] as? String }, ["text", "image", "text"])
        XCTAssertNil(success["isError"], "Success is not marked through the error hook.")

        let errorA = try XCTUnwrap(result?["errorA"] as? [String: Any])
        XCTAssertNil(errorA["isError"], "Pi 0.80.6 ignores execute-return isError; the hook must set it.")
        let finalizedA = try XCTUnwrap(result?["finalizedA"] as? [String: Any])
        let finalizedB = try XCTUnwrap(result?["finalizedB"] as? [String: Any])
        XCTAssertEqual(finalizedA["isError"] as? Bool, true)
        XCTAssertEqual(finalizedB["isError"] as? Bool, true)
        XCTAssertNil((finalizedA["details"] as? [String: Any])?["__agentDeckMCPBridgeErrorCallID"])
        XCTAssertNil(result?["mismatched"], "A result from another call must not be marked as an MCP error.")

        let fallback = try XCTUnwrap(result?["fallback"] as? [String: Any])
        XCTAssertEqual(((fallback["content"] as? [[String: Any]])?.first?["text"] as? String), "legacy bridge text")
    }

    private func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "NODE_PATH": "/Users/andrea/.hermes/node/lib/node_modules"
        ], uniquingKeysWith: { _, new in new })
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("Generated MCP extension harness failed: \(stderr)")
        }
        return stdout
    }
}
