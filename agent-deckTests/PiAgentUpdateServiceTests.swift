import XCTest
@testable import agent_deck

final class PiAgentUpdateServiceTests: XCTestCase {
    @MainActor
    func testInstallationSourceDetectsPackageManagerPaths() {
        XCTAssertEqual(
            PiInstallationSource.detect(piPath: "/Users/test/.bun/bin/pi"),
            .bun
        )
        XCTAssertEqual(
            PiInstallationSource.detect(piPath: "/opt/homebrew/Cellar/pi-coding-agent/0.80.3/bin/pi"),
            .homebrew
        )
        XCTAssertEqual(
            PiInstallationSource.detect(piPath: "/Users/test/.nvm/versions/node/v26/bin/pi"),
            .npm
        )
    }

    @MainActor
    func testInstallationSourceRecognizesPiDevAndCustomPackageManagerHomes() {
        XCTAssertEqual(
            PiInstallationSource.detect(piPath: "/Users/test/.pi/agent/bin/pi"),
            .piDev
        )
        XCTAssertEqual(
            PiInstallationSource.detect(
                piPath: "/Users/test/tools/pnpm/pi",
                environment: ["PNPM_HOME": "/Users/test/tools/pnpm"]
            ),
            .pnpm
        )
        XCTAssertEqual(
            PiInstallationSource.detect(
                piPath: "/Users/test/tools/bun-bin/pi",
                environment: ["BUN_INSTALL_BIN": "/Users/test/tools/bun-bin"]
            ),
            .bun
        )
    }

    @MainActor
    func testRuntimeStatusShowsWhenOfficialReleaseIsAheadOfInstallSource() {
        let status = PiAgentRuntimeStatus(
            isInstalled: true,
            currentVersion: "0.80.3",
            installationSource: .homebrew,
            latestOfficialVersion: "0.80.6",
            latestSourceVersion: "0.80.3",
            updateState: .upToDate,
            detail: "Waiting for Homebrew.",
            resolvedPath: "/opt/homebrew/bin/pi"
        )

        XCTAssertTrue(status.isOfficialReleaseAheadOfSource)
    }

    func testVersionComparisonRecognizesTargetAndNewerVersions() {
        XCTAssertTrue(PiAgentUpdateService.isVersion("0.80.6", atLeast: "0.80.6"))
        XCTAssertTrue(PiAgentUpdateService.isVersion("0.80.7", atLeast: "0.80.6"))
        XCTAssertFalse(PiAgentUpdateService.isVersion("0.80.3", atLeast: "0.80.6"))
    }

    func testVersionComparisonHandlesVPrefixAndPrereleases() {
        XCTAssertTrue(PiAgentUpdateService.isVersion("v0.80.6", atLeast: "0.80.6"))
        XCTAssertTrue(PiAgentUpdateService.isNewerVersion("0.80.6", than: "0.80.6-beta.1"))
        XCTAssertFalse(PiAgentUpdateService.isVersion("0.80.6-beta.1", atLeast: "0.80.6"))
    }

    @MainActor
    func testInstallerSelectsNpmBeforeOtherAvailablePackageManagers() async throws {
        let fixture = try PiInstallFixture(availableTools: ["npm", "pnpm", "bun"])
        defer { fixture.remove() }

        let installed = await PiAutoInstaller(commandRunner: fixture.runner, piResolver: fixture.resolver).install()
        let command = await fixture.runner.installCommand()
        XCTAssertTrue(installed ?? false)
        XCTAssertEqual(command, "npm install -g --ignore-scripts @earendil-works/pi-coding-agent")
    }

    @MainActor
    func testInstallerSelectsPnpmThenBunWithoutFallbackAfterSelection() async throws {
        let pnpmFixture = try PiInstallFixture(availableTools: ["pnpm", "bun"])
        defer { pnpmFixture.remove() }
        let pnpmInstalled = await PiAutoInstaller(commandRunner: pnpmFixture.runner, piResolver: pnpmFixture.resolver).install()
        let pnpmCommand = await pnpmFixture.runner.installCommand()
        XCTAssertTrue(pnpmInstalled ?? false)
        XCTAssertEqual(pnpmCommand, "pnpm add -g --ignore-scripts @earendil-works/pi-coding-agent")

        let bunFixture = try PiInstallFixture(availableTools: ["bun"])
        defer { bunFixture.remove() }
        let bunInstalled = await PiAutoInstaller(commandRunner: bunFixture.runner, piResolver: bunFixture.resolver).install()
        let bunCommand = await bunFixture.runner.installCommand()
        XCTAssertTrue(bunInstalled ?? false)
        XCTAssertEqual(bunCommand, "bun add -g --ignore-scripts @earendil-works/pi-coding-agent")
    }

    @MainActor
    func testInstallerDoesNotFallThroughAfterPackageManagerFailure() async throws {
        let fixture = try PiInstallFixture(availableTools: ["npm", "pnpm", "bun"], failingInstallTool: "npm")
        defer { fixture.remove() }

        let installed = await PiAutoInstaller(commandRunner: fixture.runner, piResolver: fixture.resolver).install()
        let commands = await fixture.runner.installCommands()
        XCTAssertFalse(installed ?? true)
        XCTAssertEqual(commands, ["npm install -g --ignore-scripts @earendil-works/pi-coding-agent"])
    }

    @MainActor
    func testSuccessfulCommandDoesNotCountAsUpdateWhenVersionStaysOld() async throws {
        let fixture = try PiUpdateFixture(versionAfterUpdate: "0.80.3")
        defer { fixture.remove() }

        let installer = PiAutoInstaller(commandRunner: fixture.runner, piResolver: fixture.resolver)
        let succeeded = await installer.update(expectedVersion: "0.80.6")

        XCTAssertFalse(succeeded)
        guard case let .failed(message) = installer.phase else {
            return XCTFail("Expected post-update verification failure, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("0.80.3"))
        XCTAssertTrue(message.contains("0.80.6"))
    }

    @MainActor
    func testUpdateSucceedsWhenCommandInstallsExpectedVersion() async throws {
        let fixture = try PiUpdateFixture(versionAfterUpdate: "0.80.6")
        defer { fixture.remove() }

        let installer = PiAutoInstaller(commandRunner: fixture.runner, piResolver: fixture.resolver)
        let succeeded = await installer.update(expectedVersion: "0.80.6")

        XCTAssertTrue(succeeded)
        guard case .succeeded(method: .piSelfUpdate) = installer.phase else {
            return XCTFail("Expected verified update success, got \(installer.phase)")
        }
    }
}

private struct PiUpdateFixture {
    let executableURL: URL
    let runner: FakePiUpdateCommandRunner
    let resolver: PiExecutableResolver

    init(versionAfterUpdate: String) throws {
        let fakeExecutableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-fake-pi-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: fakeExecutableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExecutableURL.path)
        executableURL = fakeExecutableURL
        runner = FakePiUpdateCommandRunner(versionAfterUpdate: versionAfterUpdate)
        resolver = PiExecutableResolver(
            candidatesProvider: { [fakeExecutableURL] },
            defaultPathDirectories: { [] },
            cacheResults: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: executableURL)
    }
}

private struct PiInstallFixture {
    let executableURL: URL
    let runner: FakePiInstallCommandRunner
    let resolver: PiExecutableResolver

    init(availableTools: Set<String>, failingInstallTool: String? = nil) throws {
        let fakeExecutableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-fake-pi-install-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: fakeExecutableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExecutableURL.path)
        executableURL = fakeExecutableURL
        runner = FakePiInstallCommandRunner(availableTools: availableTools, failingInstallTool: failingInstallTool)
        resolver = PiExecutableResolver(
            candidatesProvider: { [fakeExecutableURL] },
            defaultPathDirectories: { [] },
            cacheResults: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: executableURL)
    }
}

private actor FakePiInstallCommandRunner: CommandRunning {
    private let availableTools: Set<String>
    private let failingInstallTool: String?
    private var recordedInstallCommands: [String] = []
    private var isPiInstalled = false

    init(availableTools: Set<String>, failingInstallTool: String?) {
        self.availableTools = availableTools
        self.failingInstallTool = failingInstallTool
    }

    func installCommand() -> String? { recordedInstallCommands.last }
    func installCommands() -> [String] { recordedInstallCommands }

    func run(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        if arguments == ["--version"] {
            return CommandResult(stdout: "", stderr: "", exitCode: availableTools.contains(command) ? 0 : 1)
        }
        if arguments == ["--help"] {
            return CommandResult(stdout: isPiInstalled ? "Pi help" : "", stderr: "", exitCode: isPiInstalled ? 0 : 1)
        }
        recordedInstallCommands.append(([command] + arguments).joined(separator: " "))
        let didFail = failingInstallTool == command
        if !didFail { isPiInstalled = true }
        return CommandResult(
            stdout: didFail ? "" : "Installed",
            stderr: didFail ? "Failed" : "",
            exitCode: didFail ? 1 : 0
        )
    }
}

private actor FakePiUpdateCommandRunner: CommandRunning {
    private var currentVersion = "0.80.3"
    private let versionAfterUpdate: String

    init(versionAfterUpdate: String) {
        self.versionAfterUpdate = versionAfterUpdate
    }

    func run(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        switch arguments {
        case ["--version"]:
            return CommandResult(stdout: currentVersion, stderr: "", exitCode: 0)
        case ["update", "pi"]:
            currentVersion = versionAfterUpdate
            return CommandResult(stdout: "Update command completed.", stderr: "", exitCode: 0)
        case ["--help"]:
            return CommandResult(stdout: "Pi help", stderr: "", exitCode: 0)
        default:
            return CommandResult(stdout: "", stderr: "Unexpected arguments: \(arguments)", exitCode: 1)
        }
    }
}
