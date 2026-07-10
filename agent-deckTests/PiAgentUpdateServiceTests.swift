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
