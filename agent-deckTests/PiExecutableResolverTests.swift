import XCTest
@testable import agent_deck

final class PiExecutableResolverTests: XCTestCase {
    func testCommonCandidatesIncludesStandardPaths() {
        let candidates = PiExecutableResolver().commonPiCandidates()
        let paths = candidates.map(\.path)

        XCTAssertTrue(paths.contains("/opt/homebrew/bin/pi"), "Should include Apple Silicon Homebrew path")
        XCTAssertTrue(paths.contains("/usr/local/bin/pi"), "Should include Intel Homebrew path")
        XCTAssertTrue(paths.contains("/usr/bin/pi"), "Should include system bin path")
    }

    func testCommonCandidatesIncludesHomeDirectoryPaths() {
        let candidates = PiExecutableResolver().commonPiCandidates()
        let paths = candidates.map(\.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertTrue(paths.contains("\(home)/.pi/agent/bin/pi"), "Should include Pi agent bin")
        XCTAssertTrue(paths.contains("\(home)/.volta/bin/pi"), "Should include Volta")
        XCTAssertTrue(paths.contains("\(home)/.local/bin/pi"), "Should include local bin")
        XCTAssertTrue(paths.contains("\(home)/.npm-global/bin/pi"), "Should include npm global")
        XCTAssertTrue(paths.contains("\(home)/.npm/bin/pi"), "Should include npm bin")
        XCTAssertTrue(paths.contains("\(home)/.nvm/versions/node/current/bin/pi"), "Should include NVM current")
    }

    func testExecutableResolutionFromEnvVar() {
        let tempDir = FileManager.default.temporaryDirectory
        let fakePi = tempDir.appendingPathComponent("fake-pi-for-test")
        try? "#!/bin/sh\necho test".write(to: fakePi, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi.path)
        defer { try? FileManager.default.removeItem(at: fakePi) }

        setenv("AGENT_DECK_PI_PATH", fakePi.path, 1)
        defer { unsetenv("AGENT_DECK_PI_PATH") }

        let resolver = PiExecutableResolver()
        let resolved = resolver.resolve()
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.path, fakePi.path)
    }

    func testExecutableResolutionFromEnvVarWithTildeExpansion() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        setenv("AGENT_DECK_PI_PATH", "\(home)/.local/bin/pi", 1)
        defer { unsetenv("AGENT_DECK_PI_PATH") }

        let tempPi = URL(fileURLWithPath: "\(home)/.local/bin/pi")
        let parentDir = tempPi.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? "#!/bin/sh\necho test".write(to: tempPi, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPi.path)
        defer { try? FileManager.default.removeItem(at: tempPi) }

        let resolver = PiExecutableResolver()
        let resolved = resolver.resolve()
        XCTAssertNotNil(resolved)
    }

    func testResolveReturnsNilWhenPiNotFound() {
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "/nonexistent-path-for-test", 1)
        unsetenv("AGENT_DECK_PI_PATH")
        unsetenv("PI_CLI_PATH")
        defer {
            setenv("PATH", oldPath, 1)
        }

        XCTAssertNil(PiExecutableResolver().resolve())
    }
}
