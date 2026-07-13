import XCTest
@testable import agent_deck

final class CodexPluginMCPDiscoveryTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }

    func testDiscoversEnabledComputerUseFromBundledTemporaryRootAndResolvesRelativePaths() async throws {
        let root = try fixture(version: "1.2.3")
        let runner = FakeRunner(output: list(root: root, enabled: true, version: "1.2.3"))
        let result = await service(runner).discover()
        XCTAssertEqual(result.resources.count, 1)
        let resource = try XCTUnwrap(result.resources.first)
        XCTAssertEqual(resource.id, "computer-use@openai-bundled:computer-use")
        XCTAssertEqual(resource.version, "1.2.3")
        XCTAssertEqual(resource.provenance.marketplace, "openai-bundled")
        XCTAssertEqual(resource.config.command, root.appendingPathComponent("bin/helper").path)
        XCTAssertEqual(resource.config.cwd, root.appendingPathComponent("work").path)
        XCTAssertEqual(resource.config.args, ["--safe", "$(not-evaluated)"])
        XCTAssertEqual(resource.config.env?["TOKEN"], "$UNCHANGED")
        let invocation = await runner.invocation
        XCTAssertEqual(invocation?.arguments, ["plugin", "list", "--json"])
    }

    func testDisabledAndAbsentPluginAreUnavailable() async throws {
        let root = try fixture()
        let disabled = await service(FakeRunner(output: list(root: root, enabled: false))).discover()
        let absent = await service(FakeRunner(output: "{\"installed\":[]}")).discover()
        XCTAssertEqual(disabled.diagnostics, [.pluginDisabled])
        XCTAssertEqual(absent.diagnostics, [.pluginNotInstalled])
    }

    func testMalformedCLIAndMCPDefinitionsFailClosed() async throws {
        let malformedCLI = await service(FakeRunner(output: "not json")).discover()
        XCTAssertEqual(malformedCLI.diagnostics, [.malformedPluginList])
        let root = try fixture(mcp: "{")
        let malformedMCP = await service(FakeRunner(output: list(root: root))).discover()
        XCTAssertEqual(malformedMCP.diagnostics, [.invalidMCPDefinition("it is not valid JSON")])
        try FileManager.default.removeItem(at: root.appendingPathComponent(".mcp.json"))
        let missingMCP = await service(FakeRunner(output: list(root: root))).discover()
        XCTAssertEqual(missingMCP.diagnostics, [.missingMCPDefinition])
    }

    func testTraversalAndSymlinkEscapeAreRejected() async throws {
        let root = try fixture(command: "../outside")
        let traversal = await service(FakeRunner(output: list(root: root))).discover()
        XCTAssertTrue(traversal.resources.isEmpty)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try "#!/bin/sh\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let helper = root.appendingPathComponent("bin/helper")
        try FileManager.default.removeItem(at: helper)
        do { try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: outside) } catch { throw XCTSkip("Symlinks unavailable: \(error)") }
        let symlink = await service(FakeRunner(output: list(root: root))).discover()
        XCTAssertTrue(symlink.resources.isEmpty)
    }

    func testDiscoveryFollowsCLIRootAndVersionUpdates() async throws {
        let old = try fixture(version: "1.0.0")
        let new = try fixture(version: "2.0.0")
        let first = await service(FakeRunner(output: list(root: old, version: "1.0.0"))).discover()
        let second = await service(FakeRunner(output: list(root: new, version: "2.0.0"))).discover()
        XCTAssertEqual(first.resources.first?.version, "1.0.0")
        XCTAssertEqual(second.resources.first?.version, "2.0.0")
        XCTAssertEqual(second.resources.first?.config.cwd, new.appendingPathComponent("work").path)
    }

    func testRunnerTimeoutAndOutputBoundsBecomeActionableDiagnostics() async {
        let timeout = await service(FakeRunner(error: .timedOut)).discover()
        let output = await service(FakeRunner(error: .outputTooLarge)).discover()
        XCTAssertEqual(timeout.diagnostics, [.timedOut])
        XCTAssertEqual(output.diagnostics, [.outputTooLarge])
    }

    func testLiveComputerUseDefinitionResolvesRelativeAppBundleHelper() async throws {
        let root = try fixture(command: "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", args: ["mcp"], cwd: ".")
        let helper = root.appendingPathComponent("Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let result = await service(FakeRunner(output: list(root: root))).discover()
        XCTAssertEqual(result.resources.first?.config.command, helper.path)
        XCTAssertEqual(result.resources.first?.config.args, ["mcp"])
        XCTAssertEqual(result.resources.first?.config.cwd, root.path)
    }

    func testBareCommandIsRejectedRatherThanResolvedFromPATH() async throws {
        let root = try fixture(command: "sh")
        let result = await service(FakeRunner(output: list(root: root))).discover()
        XCTAssertTrue(result.resources.isEmpty)
        XCTAssertEqual(result.diagnostics, [.invalidMCPDefinition("helper executable is missing or outside the plugin root")])
    }

    func testResolverFallsBackToKnownChatGPTCodexLocation() throws {
        let executable = try temporaryExecutable()
        let resolver = CodexExecutableResolver(environment: { ["PATH": "/does-not-exist"] }, candidates: { [executable] })
        XCTAssertEqual(resolver.resolve(), executable)
    }

    func testLiveDiscoveryWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AGENT_DECK_LIVE_CODEX_DISCOVERY"] == "1" || UserDefaults.standard.bool(forKey: "AgentDeckLiveCodexDiscovery") else {
            throw XCTSkip("Live Codex discovery is opt-in.")
        }
        guard CodexExecutableResolver().resolve() != nil else {
            throw XCTSkip("Codex was not found by CodexExecutableResolver (including the bundled ChatGPT location).")
        }
        let result = await CodexPluginMCPDiscovery().discover()
        let resource = try XCTUnwrap(result.resources.first)
        XCTAssertEqual(resource.pluginID, "computer-use@openai-bundled")
        XCTAssertEqual(resource.serverName, "computer-use")
        XCTAssertEqual(resource.config.args, ["mcp"])
        XCTAssertEqual(resource.config.cwd, URL(fileURLWithPath: resource.provenance.source).path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resource.config.command ?? ""))
    }

    func testProcessRunnerBoundsCombinedOutputAndDrainsStderr() async throws {
        let runner = CodexPluginListProcessRunner()
        let output = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "i=0; while [ $i -lt 1000 ]; do echo error >&2; i=$((i+1)); done; echo '{\\\"installed\\\":[]}'"], timeout: 2, maximumOutputBytes: 20_000)
        XCTAssertTrue(output.contains("installed"))
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes x >&2"], timeout: 2, maximumOutputBytes: 1_024)
            XCTFail("expected output limit")
        } catch let error as CodexPluginListRunnerError { XCTAssertEqual(error.diagnostic, .outputTooLarge) }
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 2"], timeout: 0.05, maximumOutputBytes: 1_024)
            XCTFail("expected timeout")
        } catch let error as CodexPluginListRunnerError { XCTAssertEqual(error.diagnostic, .timedOut) }
    }

    private func service(_ runner: FakeRunner) -> CodexPluginMCPDiscovery { CodexPluginMCPDiscovery(runner: runner, executableResolver: Resolver()) }
    private func fixture(version: String = "1.0.0", command: String = "bin/helper", args: [String] = ["--safe", "$(not-evaluated)"], cwd: String = "work", mcp: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex/.tmp/bundled-marketplaces/openai-bundled/computer-use-\(UUID())", isDirectory: true)
        roots.append(root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("bin/helper")
        try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try "{\"name\":\"computer-use\",\"version\":\"\(version)\"}".write(to: root.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
        let arguments = try String(data: JSONEncoder().encode(args), encoding: .utf8).unwrap()
        let definition = mcp ?? "{\"mcpServers\":{\"computer-use\":{\"command\":\"\(command)\",\"args\":\(arguments),\"env\":{\"TOKEN\":\"$UNCHANGED\"},\"cwd\":\"\(cwd)\"}}}"
        try definition.write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        return root
    }

    private func list(root: URL, enabled: Bool = true, version: String = "1.0.0") -> String {
        "{\"installed\":[{\"pluginId\":\"computer-use@openai-bundled\",\"name\":\"computer-use\",\"marketplaceName\":\"openai-bundled\",\"version\":\"\(version)\",\"installed\":true,\"enabled\":\(enabled),\"source\":{\"source\":\"local\",\"path\":\"\(root.path)\"}}]}"
    }

    private func temporaryExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-resolver-\(UUID())")
        roots.append(url)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private extension Optional where Wrapped == String { func unwrap() throws -> String { try XCTUnwrap(self) } }

private actor FakeRunner: CodexPluginListRunning {
    private let output: String?; private let error: CodexPluginListRunnerError?; private(set) var invocation: (executable: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int)?
    init(output: String = "", error: CodexPluginListRunnerError? = nil) { self.output = output; self.error = error }
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> String { invocation = (executable, arguments, timeout, maximumOutputBytes); if let error { throw error }; return output! }
}
private struct Resolver: CodexExecutableResolving { func resolve() -> URL? { URL(fileURLWithPath: "/usr/bin/true") } }
