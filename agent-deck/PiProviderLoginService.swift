import AppKit
import SwiftUI

/// Drives Pi's own provider login flow from inside Agent Deck.
///
/// Pi exposes no auth method over RPC, so a small Node bridge calls
/// `ModelRuntime.login(provider, type, interaction)`. Pi performs every
/// credential write under its own lock; Agent Deck only relays interaction
/// prompts and never passes a credential in process arguments or environment.
@MainActor
@Observable
final class PiProviderLoginService {
    struct SelectOption: Equatable, Identifiable {
        let id: String
        let label: String
    }

    enum PromptKind: String, Equatable {
        case text
        case secret
        case manualCode = "manual_code"

        var requiresSecureEntry: Bool { self == .secret }
        /// Pi's ordinary text prompts may intentionally use Enter as confirmation.
        var requiresNonEmptyEntry: Bool { self != .text }
    }

    enum Phase: Equatable {
        case launching
        case opening(url: URL, instructions: String?)
        case prompt(promptID: Int, kind: PromptKind, message: String, placeholder: String?)
        case select(promptID: Int, message: String, options: [SelectOption])
        case deviceCode(userCode: String, verificationURI: URL)
        case progress(String)
        case success
        case failure(String)
    }

    private(set) var providerID: String = ""
    private(set) var phase: Phase = .launching
    /// Invoked once on successful login so the catalog/auth state can refresh.
    var onCompleted: (@MainActor () -> Void)?

    private var process: PiAgentProcess?
    private var didFinish = false
    private let sentinel = "@@ADAUTH@@"

    /// Spawns Pi's login bridge. Resolves Node + pi up front so a missing
    /// toolchain fails gracefully instead of crashing the child.
    func start(providerID: String, authType: String) {
        start(providerID: providerID, authType: authType, action: "login")
    }

    /// Removes credentials through Pi's locked credential store.
    func startLogout(providerID: String) {
        start(providerID: providerID, authType: "", action: "logout")
    }

    private func start(providerID: String, authType: String, action: String) {
        self.providerID = providerID
        phase = .launching
        didFinish = false

        let resolver = PiExecutableResolver()
        guard let node = resolver.resolveNode() else {
            phase = .failure("Couldn't find Node. Install it, or sign in from the terminal with `pi`, then return here.")
            return
        }
        guard let piPath = resolver.resolve()?.path else {
            phase = .failure("Couldn't find the pi binary. Install it, or sign in from the terminal with `pi`.")
            return
        }

        let configuration = PiAgentProcess.Configuration(
            arguments: ["--input-type=module", "--eval", Self.bridgeScript],
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: [
                "AGENT_DECK_PI_PATH": piPath,
                "AGENT_DECK_AUTH_PROVIDER": providerID,
                "AGENT_DECK_AUTH_TYPE": authType,
                "AGENT_DECK_AUTH_ACTION": action
            ],
            executableURL: node
        )

        do {
            process = try PiAgentProcess(
                configuration: configuration,
                onStdoutLines: { [weak self] lines in
                    Task { @MainActor in self?.handleStdout(lines) }
                },
                onStderrLines: { _ in },
                onTermination: { [weak self] code in
                    Task { @MainActor in self?.handleTermination(code) }
                }
            )
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    /// Sends a prompted value or chosen option id back to the bridge.
    func submit(promptID: Int, value: String) {
        writeResponse(["id": promptID, "value": value])
        phase = .progress("Working…")
    }

    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        process?.terminate()
        process = nil
        phase = .failure("Cancelled.")
    }

    func reopenBrowser() {
        if case let .opening(url, _) = phase { NSWorkspace.shared.open(url) }
    }

    func openVerificationPage() {
        if case let .deviceCode(_, uri) = phase { NSWorkspace.shared.open(uri) }
    }

    // MARK: - Bridge IO

    private func writeResponse(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        process?.writeJSONLine(json)
    }

    private func handleStdout(_ lines: [String]) {
        for line in lines where line.hasPrefix(sentinel) {
            let payload = String(line.dropFirst(sentinel.count))
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["t"] as? String
            else { continue }
            apply(type: type, object: object)
        }
    }

    private func apply(type: String, object: [String: Any]) {
        switch type {
        case "auth_url":
            if let urlString = object["url"] as? String, let url = URL(string: urlString) {
                phase = .opening(url: url, instructions: object["instructions"] as? String)
                NSWorkspace.shared.open(url)
            }
        case "device_code":
            if let userCode = object["userCode"] as? String,
               let uriString = object["verificationUri"] as? String,
               let uri = URL(string: uriString) {
                phase = .deviceCode(userCode: userCode, verificationURI: uri)
            }
        case "progress":
            phase = .progress(object["message"] as? String ?? "Working…")
        case "prompt":
            if let id = object["id"] as? Int {
                phase = .prompt(
                    promptID: id,
                    kind: PromptKind(rawValue: object["promptType"] as? String ?? "text") ?? .text,
                    message: object["message"] as? String ?? "Enter a value",
                    placeholder: object["placeholder"] as? String
                )
            }
        case "select":
            if let id = object["id"] as? Int {
                let options = (object["options"] as? [[String: Any]] ?? []).compactMap { entry -> SelectOption? in
                    guard let optionID = entry["id"] as? String, let label = entry["label"] as? String else { return nil }
                    return SelectOption(id: optionID, label: label)
                }
                phase = .select(
                    promptID: id,
                    message: object["message"] as? String ?? "Choose an option",
                    options: options
                )
            }
        case "done":
            finishSuccess()
        case "error":
            finishFailure(object["message"] as? String ?? "Login failed.")
        default:
            break
        }
    }

    private func handleTermination(_ code: Int32) {
        process = nil
        guard !didFinish else { return }
        if code == 0 {
            finishSuccess()
        } else {
            finishFailure("The login helper exited unexpectedly (code \(code)).")
        }
    }

    private func finishSuccess() {
        guard !didFinish else { return }
        didFinish = true
        phase = .success
        onCompleted?()
    }

    private func finishFailure(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        phase = .failure(message)
    }

    /// ESM script run via `node --input-type=module --eval`. It locates the
    /// installed package, then relays `ModelRuntime.login` interactions over stdio.
    /// Protocol lines on stdout are prefixed with `@@ADAUTH@@`; responses arrive
    /// on stdin as `{ "id":n, "value":"…" }` (or `{ "id":n, "cancel":true }`).
    static let bridgeScript = #"""
    import { existsSync, realpathSync } from 'node:fs';
    import { dirname, resolve } from 'node:path';
    import { createInterface } from 'node:readline';

    const SENTINEL = '@@ADAUTH@@';
    const send = (m) => process.stdout.write(SENTINEL + JSON.stringify(m) + '\n');
    const fail = (message) => { send({ t: 'error', message: String(message) }); process.exit(1); };

    function findIndex() {
      const candidates = [];
      const piPath = process.env.AGENT_DECK_PI_PATH;
      if (piPath && existsSync(piPath)) {
        try {
          const real = realpathSync(piPath);
          // cli.js and index.js are siblings in dist/.
          candidates.push(resolve(dirname(real), 'index.js'));
          let dir = dirname(real);
          for (let i = 0; i < 10; i++) {
            candidates.push(resolve(dir, 'node_modules/@earendil-works/pi-coding-agent/dist/index.js'));
            candidates.push(resolve(dir, 'node_modules/@mariozechner/pi-coding-agent/dist/index.js'));
            const parent = dirname(dir);
            if (parent === dir) break;
            dir = parent;
          }
        } catch {}
      }
      candidates.push(
        '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js',
        '/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js',
        '/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/index.js',
        '/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/dist/index.js',
      );
      return candidates.find((p) => existsSync(p));
    }

    const providerId = process.env.AGENT_DECK_AUTH_PROVIDER;
    const authType = process.env.AGENT_DECK_AUTH_TYPE;
    const action = process.env.AGENT_DECK_AUTH_ACTION;
    if (!providerId || (action !== 'login' && action !== 'logout') || (action === 'login' && authType !== 'oauth' && authType !== 'api_key')) {
      fail('Missing or invalid provider authentication.');
    }

    const indexPath = findIndex();
    if (!indexPath) fail('Could not locate the pi package. Make sure pi is installed.');

    let ModelRuntime;
    try {
      ({ ModelRuntime } = await import(indexPath));
    } catch (e) {
      fail(e && e.message ? e.message : e);
    }
    if (!ModelRuntime || typeof ModelRuntime.create !== 'function') {
      fail('This Pi version does not expose dynamic provider authentication. Update Pi and try again.');
    }

    const pending = new Map();
    let nextId = 1;
    const ask = (base) => new Promise((res, rej) => {
      const id = nextId++;
      pending.set(id, { res, rej });
      send({ ...base, id });
    });

    createInterface({ input: process.stdin }).on('line', (line) => {
      let msg;
      try { msg = JSON.parse(line); } catch { return; }
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      if (msg.cancel) p.rej(new Error('cancelled'));
      else p.res(msg.value);
    });

    // Hold the event loop open while we await stdin replies. readline + an open
    // stdin don't reliably keep Node alive when it's idle at a prompt, so the
    // process can exit with code 13 (unsettled top-level await) the instant a
    // flow's first step is a prompt — e.g. GitHub Copilot's enterprise-domain
    // question, before any socket/timer exists. A long interval guarantees it.
    process.stdin.resume();
    const keepAlive = setInterval(() => {}, 1 << 30);

    try {
      const runtime = await ModelRuntime.create({ allowModelNetwork: false });
      if (action === 'logout') {
        await runtime.logout(providerId);
      } else {
        const provider = runtime.getProvider(providerId);
        if (!provider || !provider.auth || !provider.auth[authType]) {
          throw new Error(`Provider "${providerId}" does not advertise ${authType} authentication.`);
        }
        await runtime.login(providerId, authType, {
          prompt: (p) => {
            if (p.type === 'select') {
              return ask({ t: 'select', message: p.message, options: p.options });
            }
            return ask({ t: 'prompt', promptType: p.type, message: p.message, placeholder: p.placeholder });
          },
          notify: (event) => {
            if (event.type === 'auth_url') {
              send({ t: 'auth_url', url: event.url, instructions: event.instructions });
            } else if (event.type === 'device_code') {
              send({ t: 'device_code', userCode: event.userCode, verificationUri: event.verificationUri, intervalSeconds: event.intervalSeconds });
            } else {
              send({ t: 'progress', message: event.message || 'Working…' });
            }
          },
        });
      }
      clearInterval(keepAlive);
      send({ t: 'done' });
      process.exit(0);
    } catch (e) {
      clearInterval(keepAlive);
      fail(e && e.message ? e.message : e);
    }
    """#
}
