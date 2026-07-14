import XCTest
@testable import agent_deck

final class CodexComputerUseBrokerDiscoveryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    private func fixture(name: String = "codex-computer-use-mcp", version: String = "0.2.0", includeScript: Bool = true) throws -> (root: URL, node: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-broker-\(UUID())", isDirectory: true)
        roots.append(base)
        let package = base.appendingPathComponent("variant/node_modules/codex-computer-use-mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("dist", isDirectory: true), withIntermediateDirectories: true)
        let packageJSON: [String: Any] = ["name": name, "version": version]
        let data = try JSONSerialization.data(withJSONObject: packageJSON)
        try data.write(to: package.appendingPathComponent("package.json"))
        if includeScript {
            try "// fixture".write(to: package.appendingPathComponent("dist/mcp-server.js"), atomically: true, encoding: .utf8)
        }
        let node = base.appendingPathComponent("node")
        try "#!/bin/sh\necho v22.0.0\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return (package, node)
    }

    private func writeVariantManifest(packageRoot: URL, digest: String) throws {
        let variantRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        let manifest: [String: Any] = [
            "variant": CodexComputerUseBrokerDiscovery.variantRevision,
            "package": CodexComputerUseBrokerDiscovery.packageName,
            "upstreamVersion": CodexComputerUseBrokerDiscovery.requiredVersion,
            "upstreamDigest": CodexComputerUseBrokerDiscovery.upstreamPackageDigest,
            "packageTreeDigest": digest,
            "approvalHandling": "auto-accept"
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: variantRoot.appendingPathComponent("agent-deck-variant.json")
        )
    }

    func testExactPackageBuildsDeterministicBrokerConfig() throws {
        let fixture = try fixture()
        let support = fixture.root.deletingLastPathComponent().appendingPathComponent("support", isDirectory: true)
        let digest = try XCTUnwrap(CodexComputerUseBrokerDiscovery.packageTreeDigest(at: fixture.root))
        try writeVariantManifest(packageRoot: fixture.root, digest: digest)
        let result = CodexComputerUseBrokerDiscovery.discover(
            applicationSupportDirectory: support,
            candidatePackageRoots: [fixture.root],
            nodeURL: fixture.node,
            nodeMajorVersionProvider: { _ in 22 },
            expectedPackageDigest: digest
        )
        guard case let .available(broker) = result else { return XCTFail("expected available broker, got \(result)") }
        XCTAssertEqual(broker.config.command, fixture.node.path)
        XCTAssertEqual(broker.config.args, [fixture.root.appendingPathComponent("dist/mcp-server.js").path])
        XCTAssertEqual(broker.config.cwd, fixture.root.path)
        XCTAssertEqual(broker.config.env?["CODEX_COMPUTER_USE_HOME"], support.appendingPathComponent("Agent Deck/Computer Use Broker/State/auto-accept.1").path)
        XCTAssertEqual(broker.config.resolvedLifecycle, .lazy)
    }

    func testWrongIdentityVersionAndMissingScriptAreRejected() throws {
        for fixture in [
            try fixture(name: "other"),
            try fixture(version: "0.2.1"),
            try fixture(includeScript: false)
        ] {
            let digest = try XCTUnwrap(CodexComputerUseBrokerDiscovery.packageTreeDigest(at: fixture.root))
            try writeVariantManifest(packageRoot: fixture.root, digest: digest)
            let result = CodexComputerUseBrokerDiscovery.discover(
                candidatePackageRoots: [fixture.root], nodeURL: fixture.node,
                nodeMajorVersionProvider: { _ in 22 }, expectedPackageDigest: digest
            )
            guard case let .unavailable(message) = result else { return XCTFail("invalid package was accepted") }
            XCTAssertTrue(message.contains("auto-accept broker variant"))
        }
    }

    func testVariantDerivationScriptPinsReviewedApprovalChanges() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/derive-computer-use-broker.py"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains(CodexComputerUseBrokerDiscovery.upstreamPackageDigest))
        XCTAssertTrue(script.contains(CodexComputerUseBrokerDiscovery.requiredPackageDigest))
        XCTAssertTrue(script.contains("mcpServerOpenaiFormElicitation: true"))
        XCTAssertTrue(script.contains("approvalPolicy: \"on-request\""))
        XCTAssertTrue(script.contains("action: \"accept\", content: {}"))
    }

    func testTamperedPackageIsRejectedEvenWhenNameAndVersionMatch() throws {
        let fixture = try fixture()
        let digest = try XCTUnwrap(CodexComputerUseBrokerDiscovery.packageTreeDigest(at: fixture.root))
        try writeVariantManifest(packageRoot: fixture.root, digest: digest)
        try "// tampered".write(
            to: fixture.root.appendingPathComponent("dist/direct-broker.js"), atomically: true, encoding: .utf8
        )
        let result = CodexComputerUseBrokerDiscovery.discover(
            candidatePackageRoots: [fixture.root], nodeURL: fixture.node,
            nodeMajorVersionProvider: { _ in 22 }, expectedPackageDigest: digest
        )
        guard case .unavailable = result else { return XCTFail("tampered package was accepted") }
    }

    func testTamperedVariantManifestIsRejected() throws {
        let fixture = try fixture()
        let digest = try XCTUnwrap(CodexComputerUseBrokerDiscovery.packageTreeDigest(at: fixture.root))
        try writeVariantManifest(packageRoot: fixture.root, digest: digest)
        let manifestURL = fixture.root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent-deck-variant.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["approvalHandling"] = "decline"
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let result = CodexComputerUseBrokerDiscovery.discover(
            candidatePackageRoots: [fixture.root], nodeURL: fixture.node,
            nodeMajorVersionProvider: { _ in 22 }, expectedPackageDigest: digest
        )
        guard case .unavailable = result else { return XCTFail("tampered manifest was accepted") }
    }

    func testMissingOrOldNodeIsRejectedBeforePackageResolution() throws {
        let fixture = try fixture()
        let missing = CodexComputerUseBrokerDiscovery.discover(
            candidatePackageRoots: [fixture.root], nodeURL: nil,
            nodeMajorVersionProvider: { _ in 22 }
        )
        let old = CodexComputerUseBrokerDiscovery.discover(
            candidatePackageRoots: [fixture.root], nodeURL: fixture.node,
            nodeMajorVersionProvider: { _ in 20 }
        )
        guard case let .unavailable(missingMessage) = missing,
              case let .unavailable(oldMessage) = old else { return XCTFail("invalid Node runtime was accepted") }
        XCTAssertTrue(missingMessage.contains("Node.js 22"))
        XCTAssertTrue(oldMessage.contains("Node.js 22"))
    }
}
