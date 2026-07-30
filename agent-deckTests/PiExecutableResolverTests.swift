import XCTest
@testable import agent_deck

final class PiExecutableResolverTests: XCTestCase {
    func testCommonCandidatesIncludesStandardPaths() {
        let candidates = PiExecutableResolver.commonPiCandidates()
        let paths = candidates.map(\.path)

        XCTAssertTrue(paths.contains("/opt/homebrew/bin/pi"), "Should include Apple Silicon Homebrew path")
        XCTAssertTrue(paths.contains("/usr/local/bin/pi"), "Should include Intel Homebrew path")
        XCTAssertTrue(paths.contains("/usr/bin/pi"), "Should include system bin path")
    }

    func testCommonCandidatesIncludesHomeDirectoryPaths() {
        let candidates = PiExecutableResolver.commonPiCandidates()
        let paths = candidates.map(\.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertTrue(paths.contains("\(home)/.bun/bin/pi"), "Should include Bun global bin")
        XCTAssertTrue(paths.contains("\(home)/Library/pnpm/pi"), "Should include pnpm's macOS home")
        XCTAssertTrue(paths.contains("\(home)/Library/Application Support/pnpm/pi"), "Should include pnpm's Application Support home")
        XCTAssertTrue(paths.contains("\(home)/.local/share/pnpm/pi"), "Should include pnpm's local-share home")
        XCTAssertTrue(paths.contains("\(home)/.pi/agent/bin/pi"), "Should include Pi agent bin")
        XCTAssertTrue(paths.contains("\(home)/.volta/bin/pi"), "Should include Volta")
        XCTAssertTrue(paths.contains("\(home)/.hermes/node/bin/pi"), "Should include Hermes npm prefix")
        XCTAssertTrue(paths.contains("\(home)/.local/bin/pi"), "Should include local bin")
        XCTAssertTrue(paths.contains("\(home)/.npm-global/bin/pi"), "Should include npm global")
        XCTAssertTrue(paths.contains("\(home)/.npm/bin/pi"), "Should include npm bin")
        XCTAssertTrue(paths.contains("\(home)/.nvm/versions/node/current/bin/pi"), "Should include NVM current")
    }

    func testCommonCandidatesIncludesConfiguredBunGlobalBin() {
        let customBin = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-bun-bin-\(UUID().uuidString)")
            .path
        setenv("BUN_INSTALL_BIN", customBin, 1)
        defer { unsetenv("BUN_INSTALL_BIN") }

        XCTAssertTrue(PiExecutableResolver.commonPiCandidates().map(\.path).contains("\(customBin)/pi"))
    }

    func testCommonCandidatesIncludesConfiguredPNPMHome() {
        let customHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-pnpm-home-\(UUID().uuidString)")
            .path
        setenv("PNPM_HOME", customHome, 1)
        defer { unsetenv("PNPM_HOME") }

        XCTAssertTrue(PiExecutableResolver.commonPiCandidates().map(\.path).contains("\(customHome)/pi"))
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

        // Stub the candidate list and default PATH directories empty so neither
        // the fallback candidates nor the standard-PATH fallback can discover a
        // real `pi` installed on this machine (e.g. /opt/homebrew/bin/pi),
        // making the "not found" assertion deterministic across machines.
        let resolver = PiExecutableResolver(candidatesProvider: { [] }, defaultPathDirectories: { [] })
        XCTAssertNil(resolver.resolve())
    }
}

    func testPreferredPathSkipsScan() {
        let tempDir = FileManager.default.temporaryDirectory
        let fakePi = tempDir.appendingPathComponent("preferred-pi-\(UUID().uuidString)")
        try? "#!/bin/sh\necho preferred".write(to: fakePi, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi.path)
        defer {
            try? FileManager.default.removeItem(at: fakePi)
            PiExecutableResolver.setPreferredPath(nil)
        }

        // Even with empty PATH / candidates, preferred path wins.
        PiExecutableResolver.setPreferredPath(fakePi.path)
        let resolver = PiExecutableResolver(candidatesProvider: { [] }, defaultPathDirectories: { [] })
        XCTAssertEqual(resolver.resolve()?.path, fakePi.path)
    }

    func testClearPreferredPathRestoresAutoDetect() {
        PiExecutableResolver.setPreferredPath("/nonexistent/pi-binary-\(UUID().uuidString)")
        defer { PiExecutableResolver.setPreferredPath(nil) }

        // Invalid preferred falls through; with empty candidates stays nil.
        let resolver = PiExecutableResolver(candidatesProvider: { [] }, defaultPathDirectories: { [] }, cacheResults: false)
        unsetenv("AGENT_DECK_PI_PATH")
        unsetenv("PI_CLI_PATH")
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "/nonexistent-path-for-test", 1)
        defer { setenv("PATH", oldPath, 1) }
        XCTAssertNil(resolver.resolve())
    }
