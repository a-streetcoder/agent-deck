import XCTest
@testable import agent_deck

/// Coverage for the two-mode Pi extension-loading control and the launch-argument
/// split that keeps Agent Deck's bridges registering before user extensions.
@MainActor
final class PiAgentExtensionLoadingModeTests: XCTestCase {

    // MARK: - Mode persistence

    func testDefaultModeIsAgentDeckManaged() {
        XCTAssertEqual(AppSettings().piAgentExtensionLoadingMode, .agentDeckManaged)
        XCTAssertTrue(AppSettings().disabledPiExtensionIDs.isEmpty)
    }

    func testDecodingMissingModeDefaultsToManaged() throws {
        let data = Data("{}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.piAgentExtensionLoadingMode, .agentDeckManaged)
        XCTAssertTrue(settings.disabledPiExtensionIDs.isEmpty)
    }

    func testDecodingDroppedModeRawValueFallsBackToManaged() throws {
        // "piDefaultsAndAgentDeck" / "customSelectionAndAgentDeck" were removed in the
        // two-mode redesign. Unknown raw values must decode-fallback, not throw.
        for raw in ["piDefaultsAndAgentDeck", "customSelectionAndAgentDeck", "garbage"] {
            let data = Data(#"{"piAgentExtensionLoadingMode":"\#(raw)"}"#.utf8)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(settings.piAgentExtensionLoadingMode, .agentDeckManaged, "raw=\(raw)")
        }
    }

    func testUseMyExtensionsRoundTrips() throws {
        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .useMyExtensions
        settings.disabledPiExtensionIDs = ["path:/tmp/foo.ts"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.piAgentExtensionLoadingMode, .useMyExtensions)
        XCTAssertEqual(decoded.disabledPiExtensionIDs, ["path:/tmp/foo.ts"])
    }

    // MARK: - Mode invariants

    func testBothModesDisableAmbientDiscovery() {
        // The whole point of the redesign: Agent Deck always builds the list itself.
        for mode in PiAgentExtensionLoadingMode.allCases {
            XCTAssertTrue(mode.disablesAmbientPiExtensions, "\(mode) should disable ambient discovery")
            XCTAssertEqual(mode.ambientPiExtensionArguments, ["--no-extensions"])
        }
        XCTAssertEqual(PiAgentExtensionLoadingMode.allCases.count, 2)
    }

    func testOnlyUseMyExtensionsUsesCustomSelection() {
        XCTAssertFalse(PiAgentExtensionLoadingMode.agentDeckManaged.usesCustomPiExtensionSelection)
        XCTAssertTrue(PiAgentExtensionLoadingMode.useMyExtensions.usesCustomPiExtensionSelection)
    }

    // MARK: - Launch argument split

    func testNoExtensionsArgumentForBothModes() {
        for mode in PiAgentExtensionLoadingMode.allCases {
            var settings = AppSettings()
            settings.piAgentExtensionLoadingMode = mode
            XCTAssertEqual(PiAgentLaunchArgumentBuilder.noExtensionsArgument(settings: settings), ["--no-extensions"])
        }
    }

    func testUserSelectedExtensionsEmptyInManagedMode() throws {
        let home = try makeTempHome(extensionFileNames: ["alpha.ts"])
        defer { try? FileManager.default.removeItem(at: home) }
        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .agentDeckManaged
        let args = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: settings,
            projectURL: nil,
            discoveryService: PiExtensionDiscoveryService(homeDirectory: home)
        )
        XCTAssertTrue(args.isEmpty, "managed mode must not emit user --extension args")
    }

    func testUserSelectedExtensionsIncludeEnabledAndExcludeDisabled() throws {
        let home = try makeTempHome(extensionFileNames: ["alpha.ts", "beta.ts"])
        defer { try? FileManager.default.removeItem(at: home) }
        let service = PiExtensionDiscoveryService(homeDirectory: home)

        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .useMyExtensions

        // All enabled: both extensions emit --extension pairs, and there is NO
        // --no-extensions in this list (callers place that flag themselves, first).
        let allArgs = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertFalse(allArgs.contains("--no-extensions"))
        XCTAssertEqual(allArgs.filter { $0 == "--extension" }.count, 2)
        XCTAssertTrue(allArgs.contains { $0.hasSuffix("alpha.ts") })
        XCTAssertTrue(allArgs.contains { $0.hasSuffix("beta.ts") })

        // Deselect alpha → only beta remains.
        let alphaID = "path:" + home.appendingPathComponent(".pi/agent/extensions/alpha.ts").standardizedFileURL.path
        settings.disabledPiExtensionIDs = [alphaID]
        let beta = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertEqual(beta.filter { $0 == "--extension" }.count, 1)
        XCTAssertFalse(beta.contains { $0.hasSuffix("alpha.ts") })
        XCTAssertTrue(beta.contains { $0.hasSuffix("beta.ts") })
    }

    func testManagedModeReinjectsModelProviderPackagesOnly() throws {
        let home = try makeTempHomeWithPackages(
            packages: [
                ("pi-grok-cli", isProvider: true),
                ("pi-subagents", isProvider: false),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let service = PiExtensionDiscoveryService(homeDirectory: home)
        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .agentDeckManaged

        let base = PiAgentLaunchArgumentBuilder.isolatedLaunchBaseArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertEqual(base.first, "--no-extensions")
        XCTAssertTrue(base.contains { $0.hasSuffix("pi-grok-cli/src/index.ts") || $0.contains("/pi-grok-cli/") })
        XCTAssertFalse(base.contains { $0.contains("pi-subagents") })

        let user = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertTrue(user.isEmpty)
    }

    func testUseMyExtensionsDefersNonProviderPackagesAfterBridges() throws {
        let home = try makeTempHomeWithPackages(
            packages: [("pi-subagents", isProvider: false)],
            extensionFileNames: ["alpha.ts"]
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let service = PiExtensionDiscoveryService(homeDirectory: home)
        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .useMyExtensions

        // Early list is model providers only — tool packages must not precede Deck bridges.
        let early = PiAgentLaunchArgumentBuilder.packageExtensionArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertFalse(early.contains { $0.contains("pi-subagents") })

        let user = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertTrue(user.contains { $0.contains("pi-subagents") }, "non-provider packages load with trailing user list")
        XCTAssertTrue(user.contains { $0.hasSuffix("alpha.ts") })
    }

    func testUseMyExtensionsSkipsDeckSupersededPackages() throws {
        let home = try makeTempHomeWithPackages(
            packages: [
                ("pi-ask-user", isProvider: false),
                ("pi-subagents", isProvider: false),
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let service = PiExtensionDiscoveryService(homeDirectory: home)
        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .useMyExtensions

        let user = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: settings, projectURL: nil, discoveryService: service
        )
        XCTAssertFalse(user.contains { $0.contains("pi-ask-user") }, "Deck owns ask_user; skip pi-ask-user")
        XCTAssertTrue(user.contains { $0.contains("pi-subagents") })
    }

    func testIsModelProviderPackageHeuristic() {
        let grok = PiExtensionCandidate(
            id: "path:/tmp/a",
            name: "index",
            launchSource: "/tmp/a",
            source: ScopeID(kind: .package, path: "npm:pi-grok-cli"),
            discoveryKind: .package,
            packageName: "pi-grok-cli"
        )
        let sub = PiExtensionCandidate(
            id: "path:/tmp/b",
            name: "index",
            launchSource: "/tmp/b",
            source: ScopeID(kind: .package, path: "npm:pi-subagents"),
            discoveryKind: .package,
            packageName: "pi-subagents"
        )
        XCTAssertTrue(PiAgentLaunchArgumentBuilder.isModelProviderPackage(grok))
        XCTAssertFalse(PiAgentLaunchArgumentBuilder.isModelProviderPackage(sub))
    }

    func testIsDeckSupersededPackage() {
        let ask = PiExtensionCandidate(
            id: "path:/tmp/ask",
            name: "index",
            launchSource: "/tmp/ask",
            source: ScopeID(kind: .package, path: "npm:pi-ask-user"),
            discoveryKind: .package,
            packageName: "pi-ask-user"
        )
        let scopedAsk = PiExtensionCandidate(
            id: "path:/tmp/ask2",
            name: "index",
            launchSource: "/tmp/ask2",
            source: ScopeID(kind: .package, path: "npm:@juicesharp/rpiv-ask-user-question"),
            discoveryKind: .package,
            packageName: "@juicesharp/rpiv-ask-user-question"
        )
        let sub = PiExtensionCandidate(
            id: "path:/tmp/sub",
            name: "index",
            launchSource: "/tmp/sub",
            source: ScopeID(kind: .package, path: "npm:pi-subagents"),
            discoveryKind: .package,
            packageName: "pi-subagents"
        )
        XCTAssertTrue(PiAgentLaunchArgumentBuilder.isDeckSupersededPackage(ask))
        XCTAssertTrue(PiAgentLaunchArgumentBuilder.isDeckSupersededPackage(scopedAsk))
        XCTAssertFalse(PiAgentLaunchArgumentBuilder.isDeckSupersededPackage(sub))
    }

    // MARK: - Injected bridge list (Session resources popover)

    private func bridgeIDs(
        memory: Bool, exa: Bool, fallback: Bool, subagents: Bool
    ) -> [String] {
        PiNativeSubagentBridgeExtensions.injectedParentBridges(
            memoryEnabled: memory, exaConfigured: exa, fallbackWebFetchAvailable: fallback, subagentsActive: subagents
        ).map(\.id)
    }

    func testInjectedBridgesBaseline() {
        // Nothing conditional → only ask_user.
        XCTAssertEqual(bridgeIDs(memory: false, exa: false, fallback: false, subagents: false), ["ask_user"])
    }

    func testInjectedBridgesExaWinsOverFallback() {
        // Exa configured → show web_exa, never web_fetch (even if fallback available).
        let ids = bridgeIDs(memory: false, exa: true, fallback: true, subagents: false)
        XCTAssertTrue(ids.contains("web_exa"))
        XCTAssertFalse(ids.contains("web_fetch"))
    }

    func testInjectedBridgesFallbackOnlyWhenNoExa() {
        XCTAssertEqual(bridgeIDs(memory: false, exa: false, fallback: true, subagents: false), ["ask_user", "web_fetch"])
        // No exa and no fallback installed → no web entry at all.
        XCTAssertEqual(bridgeIDs(memory: false, exa: false, fallback: false, subagents: false), ["ask_user"])
    }

    func testInjectedBridgesMemoryAndSubagentsAreConditional() {
        let all = bridgeIDs(memory: true, exa: true, fallback: false, subagents: true)
        XCTAssertEqual(Set(all), ["ask_user", "memory", "deck_agents", "web_exa"])
        let none = bridgeIDs(memory: false, exa: true, fallback: false, subagents: false)
        XCTAssertFalse(none.contains("memory"))
        XCTAssertFalse(none.contains("deck_agents"))
    }

    // MARK: - Description reader

    func testDescriptionReaderBlockComment() {
        let src = "/**\n * Terminal notification extension for Pi.\n *\n * Details here.\n */\nimport x\n"
        XCTAssertEqual(PiExtensionDescriptionReader.leadingDescription(fromSource: src), "Terminal notification extension for Pi.")
    }

    func testDescriptionReaderNoLeadingCommentIsNil() {
        XCTAssertNil(PiExtensionDescriptionReader.leadingDescription(fromSource: "import type { ExtensionAPI } from \"x\";\n"))
    }

    func testDescriptionReaderLineComment() {
        XCTAssertEqual(PiExtensionDescriptionReader.leadingDescription(fromSource: "// Quick footer tweak\nexport default {}"), "Quick footer tweak")
    }

    // MARK: - Helpers

    private func makeTempHome(extensionFileNames: [String]) throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ext-home-\(UUID().uuidString)", isDirectory: true)
        let extDir = home.appendingPathComponent(".pi/agent/extensions", isDirectory: true)
        try fm.createDirectory(at: extDir, withIntermediateDirectories: true)
        for name in extensionFileNames {
            try "export default {}\n".write(to: extDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return home
    }

    private func makeTempHomeWithPackages(
        packages: [(name: String, isProvider: Bool)],
        extensionFileNames: [String] = []
    ) throws -> URL {
        let home = try makeTempHome(extensionFileNames: extensionFileNames)
        let fm = FileManager.default
        let agentDir = home.appendingPathComponent(".pi/agent", isDirectory: true)
        try fm.createDirectory(at: agentDir, withIntermediateDirectories: true)

        var packageRefs: [String] = []
        for package in packages {
            packageRefs.append("npm:\(package.name)")
            let pkgDir = home.appendingPathComponent(".pi/agent/npm/node_modules/\(package.name)", isDirectory: true)
            let srcDir = pkgDir.appendingPathComponent("src", isDirectory: true)
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try "export default {}\n".write(to: srcDir.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
            let packageJSON: [String: Any] = [
                "name": package.name,
                "pi": [
                    "extensions": ["./src/index.ts"]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: packageJSON, options: [.prettyPrinted])
            try data.write(to: pkgDir.appendingPathComponent("package.json"))
        }

        let settings: [String: Any] = ["packages": packageRefs]
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try settingsData.write(to: agentDir.appendingPathComponent("settings.json"))
        return home
    }
}
