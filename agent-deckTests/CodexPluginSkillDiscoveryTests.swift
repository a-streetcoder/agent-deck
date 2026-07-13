import XCTest
@testable import agent_deck

@MainActor
final class CodexPluginSkillDiscoveryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexPlugin-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func configure(_ home: URL, keys: [String]) throws {
        let contents = keys.map { "[plugins.\"\($0)\"]\nenabled = false" }.joined(separator: "\n")
        try contents.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func plugin(
        _ home: URL,
        market: String = "market",
        name: String = "demo",
        version: String,
        skills: String = "skills",
        manifestName: String? = nil,
        displayName: String? = nil
    ) throws -> URL {
        let root = home.appendingPathComponent("plugins/cache/\(market)/\(name)/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        var manifest: [String: Any] = ["name": manifestName ?? name, "version": version, "skills": skills]
        if let displayName { manifest["interface"] = ["displayName": displayName] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent(".codex-plugin/plugin.json"))
        let skill = root.appendingPathComponent("\(skills)/sample", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: Sample\n---\nbody".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func marker(_ home: URL, name: String = "demo", valid: Bool = true) throws {
        let url = home.appendingPathComponent("plugins/cache/market/\(name)/.codex-remote-plugin-install.json")
        let value: [String: Any] = valid ? ["schema_version": 1, "remote_plugin_id": "remote-id"] : ["schema_version": 99]
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }

    func testCodexHomeDefaultAndCustom() throws {
        let root = try home()
        XCTAssertEqual(CodexPluginSkillDiscovery.codexHome(environment: [:], home: root).path, root.appendingPathComponent(".codex").path)
        XCTAssertEqual(CodexPluginSkillDiscovery.codexHome(environment: ["CODEX_HOME": "/tmp/custom-codex"], home: root).path, "/tmp/custom-codex")
    }

    func testInstalledFilteringRequiresExactConfigOrValidMarker() throws {
        let home = try home()
        try configure(home, keys: ["demo@market"])
        _ = try plugin(home, name: "demo", version: "1.0.0")
        _ = try plugin(home, name: "stale", version: "1.0.0")
        _ = try plugin(home, name: "remote", version: "1.0.0")
        try marker(home, name: "remote")
        _ = try plugin(home, name: "invalid", version: "1.0.0")
        try marker(home, name: "invalid", valid: false)
        XCTAssertEqual(CodexPluginSkillDiscovery.activePackages(codexHome: home).map { $0.identity.plugin }, ["demo", "remote"])
    }

    func testConfiguredPluginTableAllowsWhitespaceAndTrailingComment() throws {
        let home = try home()
        try "  [ plugins . \"demo@market\" ] # installed\nenabled = false".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = try plugin(home, version: "1.0.0")
        XCTAssertEqual(CodexPluginSkillDiscovery.activePackages(codexHome: home).map { $0.identity.plugin }, ["demo"])
    }

    func testVersionSelectionLocalSemVerAndLexicalFallback() throws {
        let home = try home()
        try configure(home, keys: ["demo@market", "hash@market"])
        _ = try plugin(home, version: "1.9.0")
        _ = try plugin(home, version: "1.10.0-rc.1")
        _ = try plugin(home, version: "1.10.0")
        _ = try plugin(home, version: "local")
        _ = try plugin(home, name: "hash", version: "aaa")
        _ = try plugin(home, name: "hash", version: "bbb")
        let packages = CodexPluginSkillDiscovery.activePackages(codexHome: home)
        XCTAssertEqual(packages.first { $0.identity.plugin == "demo" }?.version, "local")
        XCTAssertEqual(packages.first { $0.identity.plugin == "hash" }?.version, "bbb")
        try FileManager.default.removeItem(at: home.appendingPathComponent("plugins/cache/market/demo/local"))
        XCTAssertEqual(CodexPluginSkillDiscovery.activePackages(codexHome: home).first { $0.identity.plugin == "demo" }?.version, "1.10.0")
    }

    func testInvalidVersionSegmentsDoNotParticipateInSelection() throws {
        let home = try home()
        try configure(home, keys: ["demo@market"])
        _ = try plugin(home, version: "1.0.0")
        _ = try plugin(home, version: "z$invalid")
        XCTAssertEqual(CodexPluginSkillDiscovery.activePackages(codexHome: home).first?.version, "1.0.0")
    }

    func testInvalidSemVerUsesLexicalFallbackAndUnicodeSegmentIsRejected() throws {
        let home = try home()
        try configure(home, keys: ["demo@market"])
        _ = try plugin(home, version: "1.0.0")
        _ = try plugin(home, version: "1.0.0-01") // invalid numeric prerelease identifier
        _ = try plugin(home, version: "1.0.0-β") // invalid non-ASCII cache segment
        XCTAssertEqual(CodexPluginSkillDiscovery.activePackages(codexHome: home).first?.version, "1.0.0-01")
    }

    func testMalformedSelectedPackageFailsClosedAndRejectsEscapes() throws {
        let home = try home()
        try configure(home, keys: ["demo@market", "bad@market"])
        _ = try plugin(home, version: "1.0.0")
        let newest = try plugin(home, version: "2.0.0")
        try "{}".write(to: newest.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
        _ = try plugin(home, name: "bad", version: "1.0.0", skills: "../escape")
        XCTAssertNil(CodexPluginSkillDiscovery.activePackages(codexHome: home).first { $0.identity.plugin == "demo" })
        XCTAssertNil(CodexPluginSkillDiscovery.activePackages(codexHome: home).first { $0.identity.plugin == "bad" })
    }

    func testCandidateDiscoveryRejectsSymlinkedSkillFileEscape() async throws {
        let home = try home()
        try configure(home, keys: ["demo@market"])
        let root = try plugin(home, version: "1.0.0")
        let skillFile = root.appendingPathComponent("skills/sample/SKILL.md")
        let outside = home.appendingPathComponent("outside.md")
        try "---\nname: Outside\n---\nbody".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: skillFile)
        do {
            try FileManager.default.createSymbolicLink(at: skillFile, withDestinationURL: outside)
        } catch {
            throw XCTSkip("Symlink creation is unavailable: \(error.localizedDescription)")
        }
        let candidates = await CodexPluginSkillDiscovery.candidateReferences(codexHome: home)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testStableReferenceFollowsReplacementAndUsesInterfaceDisplayName() throws {
        let home = try home()
        try configure(home, keys: ["demo@market"])
        _ = try plugin(home, version: "1.0.0", skills: "custom", displayName: "Friendly Plugin")
        let ref = CodexPluginSkillReference(marketplace: "market", plugin: "demo", relativeSkillRoot: "sample")
        XCTAssertTrue(CodexPluginSkillDiscovery.resolve(ref, codexHome: home)?.path.contains("1.0.0/custom/sample") == true)
        XCTAssertEqual(CodexPluginSkillDiscovery.activePackages(codexHome: home).first?.displayName, "Friendly Plugin")
        try FileManager.default.removeItem(at: home.appendingPathComponent("plugins/cache/market/demo/1.0.0"))
        _ = try plugin(home, version: "2.0.0", skills: "custom")
        XCTAssertTrue(CodexPluginSkillDiscovery.resolve(ref, codexHome: home)?.path.contains("2.0.0/custom/sample") == true)
    }

    func testSettingsCodablePreservesStableReferences() throws {
        let reference = CodexPluginSkillReference(marketplace: "market", plugin: "demo", relativeSkillRoot: "sample")
        var settings = AppSettings()
        settings.codexPluginSkillReferences = [reference]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.codexPluginSkillReferences, [reference])
    }
}
