import Foundation

/// How Pi gets installed or updated when the app does it on the user's behalf.
enum PiInstallMethod: Hashable {
    case homebrew
    case npm
    case piSelfUpdate

    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .piSelfUpdate: "Pi's built-in updater"
        }
    }
}

/// Installs or updates the Pi CLI without leaving the app, using whatever
/// non-interactive tool the machine already has (Homebrew, then npm). When
/// neither exists, `install()` returns nil and the caller hands off to the
/// Terminal flow (Pi's official installer, which can also set up Node).
///
/// Updates are method-aware: a `pi` under /opt/homebrew belongs to Homebrew
/// and updates via `brew upgrade`; any other origin (npm global, pi.dev
/// installer, manual) updates itself via `pi update pi`. The two are never
/// mixed, so Pi's self-updater can't rewrite files inside Homebrew's Cellar
/// and Homebrew never clobbers an npm-owned install.
@MainActor
@Observable
final class PiAutoInstaller {
    enum Phase: Equatable {
        case idle
        case running(method: PiInstallMethod, isUpdate: Bool)
        case failed(message: String)
        case succeeded(method: PiInstallMethod)
    }

    private(set) var phase: Phase = .idle

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    /// Silent install. Returns true when Pi is installed and verified, false
    /// when an attempt ran and failed (`phase` carries the message), and nil
    /// when neither Homebrew nor npm exists so an in-app install isn't
    /// possible — the caller should open the Terminal flow instead.
    func install() async -> Bool? {
        guard !isRunning else { return false }
        // Re-check first: the user may have installed Pi in Terminal moments
        // ago, and a second install on top of a working one is never wanted.
        if await piWorks() {
            phase = .idle
            return true
        }
        guard let method = await detectInstallMethod() else {
            phase = .idle
            return nil
        }
        return await run(method: method, isUpdate: false)
    }

    /// Silent method-aware update of an existing Pi.
    func update(expectedVersion: String? = nil) async -> Bool {
        guard !isRunning else { return false }
        guard let piURL = piResolver.resolve() else {
            phase = .failed(message: "pi is not installed.")
            return false
        }
        let method: PiInstallMethod = Self.isHomebrewOwned(piPath: piURL.path) ? .homebrew : .piSelfUpdate
        return await run(method: method, isUpdate: true, expectedVersion: expectedVersion)
    }

    /// True when the resolved pi binary belongs to the Homebrew formula. The
    /// path prefix alone can't tell: npm's global prefix often lives under
    /// /opt/homebrew too (Homebrew-installed node), and only the formula's
    /// binaries resolve into the pi-coding-agent Cellar keg.
    nonisolated static func isHomebrewOwned(piPath: String) -> Bool {
        URL(fileURLWithPath: piPath).resolvingSymlinksInPath().path.contains("/Cellar/pi-coding-agent/")
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
    }

    private func detectInstallMethod() async -> PiInstallMethod? {
        if await toolWorks("brew") { return .homebrew }
        if await toolWorks("npm") { return .npm }
        return nil
    }

    private func toolWorks(_ tool: String) async -> Bool {
        ((try? await commandRunner.run(
            tool,
            arguments: ["--version"],
            currentDirectoryURL: nil,
            timeout: 15,
            environment: nil
        ))?.exitCode == 0)
    }

    private func piWorks() async -> Bool {
        let piCommand = piResolver.resolve()?.path ?? "pi"
        return ((try? await commandRunner.run(
            piCommand,
            arguments: ["--help"],
            currentDirectoryURL: nil,
            timeout: 6,
            environment: nil
        ))?.exitCode == 0)
    }

    private func run(method: PiInstallMethod, isUpdate: Bool, expectedVersion: String? = nil) async -> Bool {
        phase = .running(method: method, isUpdate: isUpdate)

        let result: CommandResult
        do {
            switch method {
            case .homebrew:
                // The formula's node dependency bottle can take minutes on a
                // fresh machine, hence the generous timeout. NONINTERACTIVE
                // guarantees brew never sits on a prompt we can't answer.
                result = try await commandRunner.run(
                    "brew",
                    arguments: isUpdate ? ["upgrade", "pi-coding-agent"] : ["install", "pi-coding-agent"],
                    currentDirectoryURL: nil,
                    timeout: 900,
                    environment: [
                        "NONINTERACTIVE": "1",
                        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                        "HOMEBREW_NO_ENV_HINTS": "1"
                    ]
                )
            case .npm:
                // --ignore-scripts is Pi's documented install flag (it ships
                // npm-shrinkwrap.json, so skipping postinstall is safe).
                result = try await commandRunner.run(
                    "npm",
                    arguments: ["install", "-g", "--ignore-scripts", "@earendil-works/pi-coding-agent"],
                    currentDirectoryURL: nil,
                    timeout: 420,
                    environment: nil
                )
            case .piSelfUpdate:
                let piCommand = piResolver.resolve()?.path ?? "pi"
                result = try await commandRunner.run(
                    piCommand,
                    arguments: ["update", "pi"],
                    currentDirectoryURL: nil,
                    timeout: 420,
                    environment: nil
                )
            }
        } catch {
            phase = .failed(message: Self.compactFailureMessage(error.localizedDescription))
            return false
        }

        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            phase = .failed(message: Self.compactFailureMessage(detail))
            return false
        }

        // Trust `pi --help`, not the installer's exit code: a "successful"
        // install that left a broken binary must surface as a failure here,
        // not as a confusing still-missing row after a refresh.
        guard await piWorks() else {
            phase = .failed(message: "The install finished but `pi --help` still fails. Try the Terminal install instead.")
            return false
        }

        if isUpdate, let expectedVersion {
            let installedVersion = await PiAgentUpdateService(commandRunner: commandRunner, piResolver: piResolver).loadCurrentVersion()
            guard let installedVersion,
                  PiAgentUpdateService.isVersion(installedVersion, atLeast: expectedVersion) else {
                let current = installedVersion ?? "an unknown version"
                let message: String
                if method == .homebrew {
                    message = "Homebrew finished, but Pi is still \(current) instead of \(expectedVersion). The Homebrew formula may not have caught up with the latest Pi release yet. Try again later."
                } else {
                    message = "The updater finished, but Pi is still \(current) instead of \(expectedVersion)."
                }
                phase = .failed(message: message)
                return false
            }
        }

        phase = .succeeded(method: method)
        return true
    }

    /// Last meaningful lines of installer output, kept short enough for an
    /// inline checklist row.
    private nonisolated static func compactFailureMessage(_ raw: String) -> String {
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(2).joined(separator: " ")
        let message = tail.isEmpty ? "The installer failed without printing an error." : tail
        return message.count > 220 ? String(message.prefix(220)) + "…" : message
    }

}
