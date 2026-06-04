import XCTest
@testable import agent_deck

@MainActor
final class PiAgentExtensionLoadingModeTests: XCTestCase {
    func testAppSettingsDefaultKeepsAgentDeckManagedExtensionLoading() {
        let settings = AppSettings()

        XCTAssertEqual(settings.piAgentExtensionLoadingMode, .agentDeckManaged)
        XCTAssertTrue(settings.piAgentExtensionLoadingMode.disablesAmbientPiExtensions)
        XCTAssertEqual(settings.piAgentExtensionLoadingMode.ambientPiExtensionArguments, ["--no-extensions"])
        XCTAssertEqual(settings.piAgentExtensionLoadingMode.parentSessionAmbientExtensionArguments, ["--no-extensions"])
        XCTAssertTrue(settings.piAgentExtensionLoadingMode.parentSessionLaunchPreview.contains("--no-extensions"))
    }

    func testPiDefaultsModeOmitsNoExtensionsFromParentLaunchPreview() {
        let mode = PiAgentExtensionLoadingMode.piDefaultsAndAgentDeck

        XCTAssertFalse(mode.disablesAmbientPiExtensions)
        XCTAssertFalse(mode.usesCustomPiExtensionSelection)
        XCTAssertEqual(mode.ambientPiExtensionArguments, [])
        XCTAssertEqual(mode.parentSessionAmbientExtensionArguments, [])
        XCTAssertFalse(mode.parentSessionLaunchPreview.contains("--no-extensions"))
        XCTAssertTrue(mode.parentSessionLaunchPreview.contains("--extension <agent-deck-bridge.ts>"))
        XCTAssertTrue(mode.parentSessionLaunchPreview.contains("Native subagent:"))
        XCTAssertTrue(mode.parentSessionLaunchPreview.contains("Automation helper:"))
    }

    func testCustomSelectionModeUsesNoExtensionsAndSelectedExtensionPreview() {
        let mode = PiAgentExtensionLoadingMode.customSelectionAndAgentDeck

        XCTAssertTrue(mode.disablesAmbientPiExtensions)
        XCTAssertTrue(mode.usesCustomPiExtensionSelection)
        XCTAssertEqual(mode.ambientPiExtensionArguments, ["--no-extensions"])
        XCTAssertTrue(mode.parentSessionLaunchPreview.contains("--extension <checked-pi-extension>"))
        XCTAssertTrue(mode.parentSessionLaunchPreview.contains("--extension <agent-deck-bridge.ts>"))
    }

    func testCustomSelectionLaunchArgumentsIncludeOnlyEnabledDiscoveredExtensions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let globalExtensions = home.appendingPathComponent(".pi/agent/extensions", isDirectory: true)
        let projectExtensions = project.appendingPathComponent(".pi/extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: globalExtensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectExtensions, withIntermediateDirectories: true)
        let globalExtension = globalExtensions.appendingPathComponent("global.ts")
        let projectExtension = projectExtensions.appendingPathComponent("project.ts")
        try "export default () => {};".write(to: globalExtension, atomically: true, encoding: .utf8)
        try "export default () => {};".write(to: projectExtension, atomically: true, encoding: .utf8)

        let service = PiExtensionDiscoveryService(homeDirectory: home)
        let candidates = service.discover(projectRoot: project)
        let disabledID = try XCTUnwrap(candidates.first { $0.name == "global" }?.id)
        var settings = AppSettings()
        settings.piAgentExtensionLoadingMode = .customSelectionAndAgentDeck
        settings.disabledPiExtensionIDs = [disabledID]

        let args = PiAgentLaunchArgumentBuilder.ambientExtensionArguments(settings: settings, projectURL: project, discoveryService: service)

        XCTAssertEqual(args.first, "--no-extensions")
        XCTAssertFalse(args.contains(globalExtension.path))
        XCTAssertTrue(args.contains(projectExtension.path))
    }

    func testDecodingOldSettingsDefaultsToManagedExtensionLoading() throws {
        let data = Data("{}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.piAgentExtensionLoadingMode, .agentDeckManaged)
    }

    func testDecodingUnknownExtensionLoadingModeFallsBackToManaged() throws {
        let data = Data("{\"piAgentExtensionLoadingMode\":\"unknown\"}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.piAgentExtensionLoadingMode, .agentDeckManaged)
    }

    func testDecodingOldSettingsDefaultsDisabledPiExtensionIDsToEmptySet() throws {
        let data = Data("{}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertTrue(settings.disabledPiExtensionIDs.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-extension-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
