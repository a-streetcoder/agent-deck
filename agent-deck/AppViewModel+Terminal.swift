import AppKit
import Foundation

// MARK: - External terminal launch

extension AppViewModel {
    func openPiSelfUpdateInTerminal() {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-pi-update-\(operationID.uuidString)")
            .appendingPathExtension("command")
        let updateCommand = terminalPiSelfUpdateCommand()
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport(prepending: resolvedPiPathForShell()))
        \(updateCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: operationID)
        } catch {
#if DEBUG
            NSLog("Failed to create Pi update terminal script: \(error.localizedDescription)")
#endif
        }
    }

    func openPiInstallInTerminal() {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-pi-install-\(operationID.uuidString)")
            .appendingPathExtension("command")
        // Pi's official installer handles every machine state, including
        // missing Node (it offers to set Node up interactively, which works
        // here because Terminal provides a real TTY). Download to a file
        // before running so the installer's prompts read from the terminal,
        // never from a pipe. Never reinstall over a working pi.
        let installCommand = """
        if command -v pi >/dev/null 2>&1; then
          echo "Pi is already installed at $(command -v pi)."
        else
          PI_INSTALLER="$(mktemp -t agent-deck-pi-installer)"
          if curl -fsSL https://pi.dev/install.sh -o "$PI_INSTALLER"; then
            sh "$PI_INSTALLER" || echo "Installer failed. See https://pi.dev for manual instructions."
          else
            echo "Could not download the Pi installer. Check your network, or see https://pi.dev."
          fi
          rm -f "$PI_INSTALLER"
        fi
        echo ""
        echo "Press any key to close."
        read -k 1
        """
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport())
        \(installCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: operationID)
        } catch {
#if DEBUG
            NSLog("Failed to create Pi install terminal script: \(error.localizedDescription)")
#endif
        }
    }

    /// Writes a one-shot `.command` script and opens it in Terminal
    /// (mirrors `openPiInstallInTerminal`).
    func runShellScriptInTerminal(named: String, body: String) {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-\(named)-\(operationID.uuidString)")
            .appendingPathExtension("command")
        let script = """
        #!/bin/zsh
        \(augmentedShellPATHExport())
        \(body)
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: operationID)
        } catch {
#if DEBUG
            NSLog("Failed to create \(named) terminal script: \(error.localizedDescription)")
#endif
        }
    }

    func terminalPiSelfUpdateCommand() -> String {
        let piPath = resolvedPiPathForShell()
        if PiAutoInstaller.isHomebrewOwned(piPath: piPath) {
            return """
            brew upgrade pi-coding-agent || { echo "Homebrew could not update Pi. The formula may not have caught up with the latest Pi release yet."; }
            echo ""
            echo "Press any key to close."
            read -k 1
            """
        }
        return """
        "\(piPath)" update pi || { echo "Pi not found. Install pi or add it to PATH."; }
        echo ""
        echo "Press any key to close."
        read -k 1
        """
    }

    /// Opens the configured terminal app at the selected session's project directory.
    ///
    /// Does **not** resume the Pi session, write a temp `.command`, or inject PATH boilerplate.
    /// Only `cd`s into `launchWorkingDirectory` so the shell prompt is clean (no
    /// `/var/folders/.../pi-deck-open-dir-….command` echo from Terminal's `do script`).
    ///
    /// - Note: Requires a selected session whose working directory exists; otherwise no-ops.
    func openSelectedPiAgentSessionInTerminal() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        acknowledgePiAgentSession(session.id)

        let workingDirectory = session.launchWorkingDirectory.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDir), isDir.boolValue else {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = LanguageStore.shared.t("vm.projectDirectoryMissing")
            }
            return
        }

        openTerminalAtDirectory(workingDirectory, sessionID: session.id)
    }

    /// Open a new terminal window already `cd`'d into `directory` (no temp script).
    ///
    /// - Parameters:
    ///   - directory: Absolute project path. Required; must exist as a directory.
    ///   - sessionID: Session for error reporting. Required.
    func openTerminalAtDirectory(_ directory: String, sessionID: UUID) {
        // Single shell line: Terminal echoes this once; keep it short and purposeful.
        let cdCommand = "cd \(shellQuoted(directory))"
        let trimmedPath = appSettings.piAgentTerminalApplicationPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let selectedTerminalPath = trimmedPath, !selectedTerminalPath.isEmpty else {
            if openInAppleTerminal(cdCommand: cdCommand, sessionID: sessionID) { return }
            // Last resort: open the folder itself (Finder-style) if Terminal AppleScript fails.
            NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
            return
        }

        guard let terminal = SupportedTerminal(appPath: selectedTerminalPath) else {
            let terminalURL = URL(fileURLWithPath: selectedTerminalPath)
            guard FileManager.default.fileExists(atPath: terminalURL.path) else {
                piAgentSessionStore.updateSession(sessionID) { record in
                    record.lastError = LanguageStore.shared.t("vm.terminalAppMissing")
                }
                return
            }
            // Unknown app: open the directory with that app if possible.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: directory, isDirectory: true)],
                withApplicationAt: terminalURL,
                configuration: configuration
            )
            return
        }

        switch terminal {
        case .appleTerminal:
            if openInAppleTerminal(cdCommand: cdCommand, sessionID: sessionID) { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
        case .iTerm:
            if openInITerm(cdCommand: cdCommand, sessionID: sessionID) { return }
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: directory, isDirectory: true)],
                withApplicationAt: URL(fileURLWithPath: selectedTerminalPath),
                configuration: {
                    let c = NSWorkspace.OpenConfiguration()
                    c.activates = true
                    return c
                }()
            )
        case .ghostty, .kitty, .alacritty, .wezTerm:
            if launchTerminalCLI(terminal, appPath: selectedTerminalPath, shellCommand: "\(cdCommand); exec /bin/zsh -i", sessionID: sessionID) {
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
        }
    }

    func openTerminalScript(_ scriptURL: URL, for sessionID: UUID) {
        let trimmedPath = appSettings.piAgentTerminalApplicationPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        // No explicit choice → macOS Terminal.
        guard let selectedTerminalPath = trimmedPath, !selectedTerminalPath.isEmpty else {
            if openInAppleTerminal(scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: defaultTerminalURL(), sessionID: sessionID)
            return
        }

        // An unrecognised app should not survive the validation in Settings, but a stale
        // selection from an older build still might — fall back to a best-effort open.
        guard let terminal = SupportedTerminal(appPath: selectedTerminalPath) else {
            let terminalURL = URL(fileURLWithPath: selectedTerminalPath)
            guard FileManager.default.fileExists(atPath: terminalURL.path) else {
                piAgentSessionStore.updateSession(sessionID) { record in
                    record.lastError = LanguageStore.shared.t("vm.terminalAppMissing")
                }
                return
            }
            openCommandFile(scriptURL, withApplicationAt: terminalURL, sessionID: sessionID)
            return
        }

        switch terminal {
        case .appleTerminal:
            if openInAppleTerminal(scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: defaultTerminalURL(), sessionID: sessionID)
        case .iTerm:
            if openInITerm(scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: URL(fileURLWithPath: selectedTerminalPath), sessionID: sessionID)
        case .ghostty, .kitty, .alacritty, .wezTerm:
            if launchTerminalCLI(terminal, appPath: selectedTerminalPath, scriptURL: scriptURL, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: URL(fileURLWithPath: selectedTerminalPath), sessionID: sessionID)
        }
    }

    /// Launches a CLI-driven terminal (Ghostty, kitty, Alacritty, WezTerm) so it opens a
    /// new window running the prepared `.command` script via `/bin/zsh`. Returns `false`
    /// if the terminal's executable could not be found or started.
    @discardableResult
    func launchTerminalCLI(_ terminal: SupportedTerminal, appPath: String, scriptURL: URL, sessionID: UUID) -> Bool {
        launchTerminalCLI(terminal, appPath: appPath, shellArguments: [scriptURL.path], sessionID: sessionID)
    }

    /// Launch a CLI terminal running `/bin/zsh -lc <shellCommand>` (clean open-dir path).
    ///
    /// - Parameters:
    ///   - terminal: Supported CLI terminal. Required.
    ///   - appPath: Path to the .app bundle. Required.
    ///   - shellCommand: Shell snippet to run then stay interactive. Required.
    ///   - sessionID: Session for error reporting. Required.
    /// - Returns: `true` if the process started.
    @discardableResult
    func launchTerminalCLI(_ terminal: SupportedTerminal, appPath: String, shellCommand: String, sessionID: UUID) -> Bool {
        launchTerminalCLI(terminal, appPath: appPath, shellArguments: ["-lc", shellCommand], sessionID: sessionID)
    }

    /// Shared CLI launcher: `terminal … /bin/zsh` + `shellArguments`.
    ///
    /// - Parameters:
    ///   - terminal: Supported CLI terminal. Required.
    ///   - appPath: Path to the .app bundle. Required.
    ///   - shellArguments: Args after `/bin/zsh` (script path or `-lc cmd`). Required.
    ///   - sessionID: Session for error reporting. Required.
    /// - Returns: `true` if the process started.
    @discardableResult
    func launchTerminalCLI(
        _ terminal: SupportedTerminal,
        appPath: String,
        shellArguments: [String],
        sessionID: UUID
    ) -> Bool {
        guard let launcher = terminal.commandLineLauncher else { return false }
        let executableURL = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(launcher.executable)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return false }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = launcher.leadingArguments + ["/bin/zsh"] + shellArguments
        do {
            try process.run()
            return true
        } catch {
            let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            piAgentSessionStore.updateSession(sessionID) { record in
                record.lastError = LanguageStore.shared.t("vm.couldNotLaunchApp", name, error.localizedDescription)
            }
            return false
        }
    }

    func openCommandFile(_ scriptURL: URL, withApplicationAt terminalURL: URL?, sessionID: UUID) {
        guard let terminalURL else {
            guard NSWorkspace.shared.open(scriptURL) else {
                piAgentSessionStore.updateSession(sessionID) { record in
                    record.lastError = LanguageStore.shared.t("vm.couldNotOpenDefaultTerminal")
                }
                return
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let sessionStore = piAgentSessionStore
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                sessionStore.updateSession(sessionID) { record in
                    record.lastError = error.localizedDescription
                }
            }
        }
    }

    func defaultTerminalURL() -> URL? {
        [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Runs the prepared `#!/bin/zsh` `.command` file in Terminal (install/update scripts).
    @discardableResult
    func openInAppleTerminal(scriptURL: URL, sessionID: UUID) -> Bool {
        // Quote path so spaces work; still echoes the path once (acceptable for long scripts).
        openInAppleTerminal(cdCommand: shellQuoted(scriptURL.path), sessionID: sessionID)
    }

    /// Open Terminal with a short shell line (e.g. `cd '/project'`). Avoids temp `.command` files.
    ///
    /// - Parameters:
    ///   - cdCommand: Shell snippet already shell-quoted as needed. Required.
    ///   - sessionID: Session for error reporting. Required.
    /// - Returns: `true` when AppleScript succeeded.
    @discardableResult
    func openInAppleTerminal(cdCommand: String, sessionID: UUID) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(cdCommand))"
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open Terminal.")
    }

    /// Runs the prepared `.command` file in iTerm (install/update scripts).
    @discardableResult
    func openInITerm(scriptURL: URL, sessionID: UUID) -> Bool {
        // iTerm `command` must be a single executable path — the .command file has a shebang.
        let script = """
        tell application "iTerm"
            activate
            create window with default profile command "\(appleScriptEscaped(scriptURL.path))"
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open iTerm.")
    }

    /// Open iTerm at a project directory via `write text` after creating a default window.
    ///
    /// Avoids `command:` with a multi-line snippet (iTerm would treat it as argv[0] and exit).
    ///
    /// - Parameters:
    ///   - cdCommand: Shell snippet such as `cd '/path'`. Required.
    ///   - sessionID: Session for error reporting. Required.
    /// - Returns: `true` when AppleScript succeeded.
    @discardableResult
    func openInITerm(cdCommand: String, sessionID: UUID) -> Bool {
        let script = """
        tell application "iTerm"
            activate
            create window with default profile
            tell current session of current window
                write text "\(appleScriptEscaped(cdCommand))"
            end tell
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open iTerm.")
    }

    @discardableResult
    func runAppleScript(_ source: String, sessionID: UUID, fallbackMessage: String) -> Bool {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            piAgentSessionStore.updateSession(sessionID) { $0.lastError = fallbackMessage }
            return false
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? fallbackMessage
            piAgentSessionStore.updateSession(sessionID) { record in
                record.lastError = message
            }
            return false
        }
        return true
    }

    func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func resolvedPiPathForShell() -> String {
        PiExecutableResolver().resolve()?.path ?? "pi"
    }

    // Terminal.app launches `.command` scripts with a minimal PATH (no nvm/Homebrew),
    // so `pi`'s `#!/usr/bin/env node` shebang fails to find `node`. Mirror the in-app
    // PATH augmentation from PiAgentProcess.processEnvironment.
    func augmentedShellPATHExport(prepending piPath: String? = nil) -> String {
        var dirs: [String] = []
        if let piPath, !piPath.isEmpty, piPath != "pi" {
            let dir = (piPath as NSString).deletingLastPathComponent
            if !dir.isEmpty { dirs.append(dir) }
        }
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        return "export PATH=\"\(dirs.joined(separator: ":")):$PATH\""
    }

}
