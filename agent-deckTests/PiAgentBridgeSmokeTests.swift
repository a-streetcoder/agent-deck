import XCTest
@testable import agent_deck

@MainActor
final class PiAgentBridgeSmokeTests: XCTestCase {
    func testStreamingFlushCadenceUsesFixedSelectedPolicyAndAdaptiveBackgroundPolicy() {
        XCTAssertEqual(PiAgentRunnerService.streamingFlushDelay(isSelected: true, characterCount: 0), 33_000_000)
        XCTAssertEqual(PiAgentRunnerService.streamingFlushDelay(isSelected: true, characterCount: 10_000), 33_000_000)
        XCTAssertEqual(PiAgentRunnerService.streamingFlushDelay(isSelected: false, characterCount: 999), 33_000_000)
        XCTAssertEqual(PiAgentRunnerService.streamingFlushDelay(isSelected: false, characterCount: 1_000), 45_000_000)
        XCTAssertEqual(PiAgentRunnerService.streamingFlushDelay(isSelected: false, characterCount: 4_000), 60_000_000)
    }

    func testLaunchResourceRelaunchRestartsIdleRunningSessionImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-resource-relaunch-idle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let launchLog = directory.appendingPathComponent("launch.log")
        let script = """
        #!/bin/sh
        printf 'launch\\n' >> \(PiTestSupport.shellSingleQuoted(launchLog.path))
        printf '%s\\n' '{"type":"response","command":"get_state","success":true,"data":{"isStreaming":false}}'
        cat >/dev/null
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Resource Relaunch", project: try PiTestSupport.makeProject(url: directory), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil { runner.isRunning(sessionID: session.id) })
        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.status == .idle
        })
        runner.requestLaunchResourceRelaunch(sessionID: session.id, summary: "launch resources changed")
        XCTAssertTrue(PiTestSupport.waitUntil(timeout: 3) {
            ((try? String(contentsOf: launchLog, encoding: .utf8)) ?? "").split(separator: "\n").count >= 2
        })
    }

    func testIdleParkingStopsResumableIdleRPCClientWithoutMarkingSessionStopped() throws {
        let sessionFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-idle-parking-\(UUID().uuidString).jsonl")
        let harness = try PiTestSupport.makeBridgeHarness(events: [
            [
                "type": "response",
                "command": "get_state",
                "success": true,
                "data": [
                    "sessionFile": sessionFile.path,
                    "isStreaming": false
                ]
            ],
            ["type": "turn_end"]
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.configureIdleParking(timeout: 0.1)
        let session = store.createSession(kind: .project, title: "Idle", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil { runner.isRunning(sessionID: session.id) })
        XCTAssertTrue(PiTestSupport.waitUntil(timeout: 3) { !runner.isRunning(sessionID: session.id) })
        let parkedSession = try XCTUnwrap(store.sessions.first(where: { $0.id == session.id }))
        XCTAssertEqual(parkedSession.status, .idle)
        XCTAssertEqual(parkedSession.piSessionFile, sessionFile.path)
        XCTAssertFalse((store.transcriptsBySessionID[session.id] ?? []).contains { $0.title == "Process Ended" })
    }

    func testConcurrentResumeKeepsOneLaunchAndDrainsStartupInputsInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-startup-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let launchLog = directory.appendingPathComponent("launch.log")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let script = """
        #!/bin/sh
        printf 'launch\\n' >> \(PiTestSupport.shellSingleQuoted(launchLog.path))
        cat > \(PiTestSupport.shellSingleQuoted(stdinLog.path))
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        // Block each discovery independently so the first launch continuation
        // can only resume after the newer generation is installed.
        var discoveryContinuations: [CheckedContinuation<Void, Never>] = []
        var completedDiscoveries = 0
        runner.mcpCatalogProvider = { _ in
            await withCheckedContinuation { continuation in
                discoveryContinuations.append(continuation)
            }
            completedDiscoveries += 1
            return nil
        }
        let session = store.createSession(kind: .project, title: "Startup Send", project: try PiTestSupport.makeProject(url: directory), repository: nil)

        runner.resume(session: session)
        let firstDiscoveryStarted = await PiTestSupport.waitUntilAsync { discoveryContinuations.count == 1 }
        XCTAssertTrue(firstDiscoveryStarted)
        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }
        let secondDiscoveryStarted = await PiTestSupport.waitUntilAsync { discoveryContinuations.count == 2 }
        XCTAssertTrue(secondDiscoveryStarted)
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.status, .starting)

        runner.send("first queued during startup", mode: .steer, to: session.id)
        runner.send("second queued during startup", mode: .steer, to: session.id)
        discoveryContinuations.removeFirst().resume()
        let firstDiscoveryCompleted = await PiTestSupport.waitUntilAsync { completedDiscoveries == 1 }
        XCTAssertTrue(firstDiscoveryCompleted)
        discoveryContinuations.removeFirst().resume()

        let delivered = await PiTestSupport.waitUntilAsync {
            (try? String(contentsOf: stdinLog, encoding: .utf8))?.contains("second queued during startup") == true
        }
        XCTAssertTrue(delivered)
        let stdin = try String(contentsOf: stdinLog, encoding: .utf8)
        let queuedLines = stdin.split(separator: "\n").filter { $0.contains("queued during startup") }
        XCTAssertEqual(queuedLines.count, 2)
        XCTAssertTrue(queuedLines.allSatisfy { $0.contains(#""type":"prompt""#) && $0.contains(#""streamingBehavior":"steer""#) })
        XCTAssertLessThan(
            try XCTUnwrap(stdin.range(of: #""type":"get_messages""#)?.lowerBound),
            try XCTUnwrap(stdin.range(of: "first queued during startup")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(stdin.range(of: "first queued during startup")?.lowerBound),
            try XCTUnwrap(stdin.range(of: "second queued during startup")?.lowerBound)
        )
        XCTAssertEqual((try String(contentsOf: launchLog, encoding: .utf8)).split(separator: "\n").count, 1)
        XCTAssertFalse((store.transcriptsBySessionID[session.id] ?? []).contains {
            $0.role == .error && $0.text.contains("Resume the session")
        })
    }

    func testLaunchPreparationTimeoutFailsWithoutStartingPiOrChangingSessionFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-startup-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let launchLog = directory.appendingPathComponent("launch.log")
        let script = """
        #!/bin/sh
        printf 'launch\\n' >> \(PiTestSupport.shellSingleQuoted(launchLog.path))
        cat >/dev/null
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store, launchSetupTimeout: .milliseconds(50))
        var discoveryContinuation: CheckedContinuation<Void, Never>?
        runner.mcpCatalogProvider = { _ in
            await withCheckedContinuation { discoveryContinuation = $0 }
            return nil
        }
        let session = store.createSession(kind: .project, title: "Startup Timeout", project: try PiTestSupport.makeProject(url: directory), repository: nil)

        runner.resume(session: session, initialPrompt: "unsent prompt")
        let failed = await PiTestSupport.waitUntilAsync {
            store.sessions.first(where: { $0.id == session.id })?.status == .failed
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchLog.path))
        XCTAssertNil(store.sessions.first(where: { $0.id == session.id })?.piSessionFile)
        XCTAssertTrue((store.transcriptsBySessionID[session.id] ?? []).contains {
            $0.title == "Launch Timed Out" && $0.text.contains("Pi was not started")
        })

        discoveryContinuation?.resume()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchLog.path))
    }

    func testStopDuringMCPDiscoveryPreventsStartupLaunchAndQueuedDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-stop-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let launchLog = directory.appendingPathComponent("launch.log")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let script = """
        #!/bin/sh
        printf 'launch\\n' >> \(PiTestSupport.shellSingleQuoted(launchLog.path))
        cat > \(PiTestSupport.shellSingleQuoted(stdinLog.path))
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var discoveryContinuation: CheckedContinuation<Void, Never>?
        var completedDiscovery = false
        runner.mcpCatalogProvider = { _ in
            await withCheckedContinuation { discoveryContinuation = $0 }
            completedDiscovery = true
            return nil
        }
        let session = store.createSession(kind: .project, title: "Stop Startup", project: try PiTestSupport.makeProject(url: directory), repository: nil)

        runner.resume(session: session)
        let discoveryStarted = await PiTestSupport.waitUntilAsync { discoveryContinuation != nil }
        XCTAssertTrue(discoveryStarted)
        runner.send("discarded startup input", mode: .steer, to: session.id)
        runner.stop(sessionID: session.id, recordTranscript: false)
        discoveryContinuation?.resume()
        let discoveryCompleted = await PiTestSupport.waitUntilAsync { completedDiscovery }
        XCTAssertTrue(discoveryCompleted)

        XCTAssertFalse(FileManager.default.fileExists(atPath: launchLog.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stdinLog.path))
        XCTAssertEqual(store.sessions.first(where: { $0.id == session.id })?.status, .stopped)
        XCTAssertTrue((store.transcriptsBySessionID[session.id] ?? []).contains {
            $0.title == "Queued Input Discarded" && $0.text.contains("1 message was not delivered")
        })
    }

    func testAttachmentOnlyTranscriptProjectionLeavesCanonicalTextAndRPCPromptsUnchanged() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: [
            "type": "response",
            "command": "get_state",
            "success": true,
            "data": ["isStreaming": false]
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Attachments", project: try PiTestSupport.makeProject(), repository: nil)
        let image = PiAgentImageAttachment(name: "image.png", mimeType: "image/png", data: "aGVsbG8=", sizeBytes: 5)
        let paste = PiAgentPasteAttachment(id: 1, marker: "[paste #1 12 chars]", text: "pasted text")

        runner.resume(
            session: session,
            initialPrompt: "startup with image",
            transcriptText: "",
            images: [image]
        )
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }
        XCTAssertTrue(PiTestSupport.waitUntil { runner.isRunning(sessionID: session.id) })
        XCTAssertTrue(PiTestSupport.waitUntil { store.sessions.first(where: { $0.id == session.id })?.status == .idle })

        let attachmentOnly = "<file name=\"/tmp/notes.txt\"></file>\nfolder: `/tmp/reports`\n\(paste.marker)"
        runner.send(attachmentOnly, mode: .prompt, to: session.id, images: [image], pasteAttachments: [paste])
        runner.send("", mode: .prompt, to: session.id, images: [image, image])
        runner.send("Keep this explicit text.", mode: .prompt, to: session.id, images: [image])

        XCTAssertTrue(PiTestSupport.waitUntil { store.transcript(for: session.id).filter { $0.role == .user }.count == 4 })
        let entries = store.transcript(for: session.id).filter { $0.role == .user }
        XCTAssertEqual(entries[0].text, "<file name=\"image.png\"></file>")
        XCTAssertTrue(entries[1].text.contains("Attached files:\n- notes.txt"), "Canonical inline file syntax remains represented for the transcript renderer.")
        XCTAssertEqual(entries[1].userAttachments?.images, [image], "Image chips remain in the persisted attachment payload.")
        XCTAssertNil(entries[1].userAttachments?.issue)
        XCTAssertEqual(entries[1].userAttachments?.pastes, [paste])
        XCTAssertEqual(entries[2].text, "<file name=\"image.png\"></file>\n<file name=\"image.png\"></file>")
        XCTAssertTrue(entries[3].text.hasPrefix("Keep this explicit text."))

        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[0]), "Attached an image.")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[1]), "Attached an image, a file, a folder, and a text paste.")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[2]), "Attached 2 images.")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[3]), "Keep this explicit text.")

        XCTAssertTrue(PiTestSupport.waitUntil {
            rpcPromptMessages(in: harness.stdinLog).contains("Keep this explicit text.\n\n<file name=\"image.png\"></file>")
        })
        let messages = rpcPromptMessages(in: harness.stdinLog)
        XCTAssertEqual(messages, [
            "startup with image\n\n<file name=\"image.png\"></file>",
            "<file name=\"/tmp/notes.txt\"></file>\nfolder: `/tmp/reports`\n[paste #1 12 chars]\n\n<file name=\"image.png\"></file>",
            "<file name=\"image.png\"></file>\n<file name=\"image.png\"></file>",
            "Keep this explicit text.\n\n<file name=\"image.png\"></file>"
        ])
    }

    func testQueuedStartupAttachmentProjectionKeepsCanonicalTranscriptAndRPC() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-queued-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        try "#!/bin/sh\ncat > \(PiTestSupport.shellSingleQuoted(stdinLog.path))\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var discoveryContinuation: CheckedContinuation<Void, Never>?
        runner.mcpCatalogProvider = { _ in
            await withCheckedContinuation { discoveryContinuation = $0 }
            return nil
        }
        let session = store.createSession(kind: .project, title: "Queued Attachments", project: try PiTestSupport.makeProject(url: directory), repository: nil)
        let image = PiAgentImageAttachment(name: "queued.png", mimeType: "image/png", data: "aGVsbG8=", sizeBytes: 5)

        runner.resume(session: session)
        let discoveryStarted = await PiTestSupport.waitUntilAsync { discoveryContinuation != nil }
        XCTAssertTrue(discoveryStarted)
        runner.send("queued attachment RPC context", mode: .steer, to: session.id, transcriptText: "", images: [image])
        let entry = try XCTUnwrap(store.transcript(for: session.id).last(where: { $0.role == .user }))
        XCTAssertEqual(entry.text, "<file name=\"queued.png\"></file>")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entry), "Attached an image.")

        discoveryContinuation?.resume()
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }
        let queuedInputDelivered = await PiTestSupport.waitUntilAsync {
            rpcPromptMessages(in: stdinLog).contains("queued attachment RPC context\n\n<file name=\"queued.png\"></file>")
        }
        XCTAssertTrue(queuedInputDelivered)
        XCTAssertEqual(rpcPromptMessages(in: stdinLog), ["queued attachment RPC context\n\n<file name=\"queued.png\"></file>"])
    }

    func testRunnerRerunMatchesAndResendsCanonicalAttachmentTextWithoutTranscriptProjection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-rerun-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let forkSessionFile = directory.appendingPathComponent("fork.jsonl")
        let canonical = #"<file name="shot.png"></file>"#
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> \(PiTestSupport.shellSingleQuoted(stdinLog.path))
          case "$line" in
            *'"type":"get_fork_messages"'*)
              printf '%s\\n' '{"type":"response","command":"get_fork_messages","success":true,"data":{"messages":[{"entryId":"fork-entry","text":"<file name=\\"shot.png\\"></file>"}]}}'
              ;;
            *'"type":"fork"'*)
              printf '%s\\n' '{"type":"response","command":"fork","success":true,"data":{"text":"<file name=\\"shot.png\\"></file>"}}'
              ;;
            *'"type":"get_state"'*)
              printf '%s\\n' '{"type":"response","command":"get_state","success":true,"data":{"sessionFile":"\(forkSessionFile.path)","sessionId":"fork-session","isStreaming":false}}'
              ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Rerun Attachments", project: try PiTestSupport.makeProject(url: directory), repository: nil)
        let image = PiAgentImageAttachment(name: "shot.png", mimeType: "image/png", data: "aGVsbG8=", sizeBytes: 5)
        let rawJSON = String(data: try JSONEncoder().encode(PiAgentUserEntryAttachments(images: [image], pastes: nil, issue: nil)), encoding: .utf8)
        let sourceEntry = PiAgentTranscriptEntry(sessionID: session.id, role: .user, title: "Prompt", text: canonical, rawJSON: rawJSON)
        store.append(sourceEntry)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }
        XCTAssertTrue(PiTestSupport.waitUntil { runner.isRunning(sessionID: session.id) })
        runner.fork(
            sessionID: session.id,
            userMessageText: canonical,
            userMessageIndex: 0,
            sourceEntryID: sourceEntry.id,
            rerun: .init(images: [image])
        )

        XCTAssertTrue(PiTestSupport.waitUntil {
            rpcPromptMessages(in: stdinLog).contains(canonical)
        })
        XCTAssertEqual(rpcPromptMessages(in: stdinLog), [canonical])
        let resentEntry = try XCTUnwrap(store.transcript(for: session.id).last(where: { $0.role == .user }))
        XCTAssertEqual(resentEntry.text, canonical)
        XCTAssertEqual(resentEntry.userAttachments?.images, [image], "Re-run retains the original image payload even though its canonical message already has the file tag.")
    }

    private func rpcPromptMessages(in logURL: URL) -> [String] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "prompt",
                  let message = object["message"] as? String else {
                return nil
            }
            return message
        }
    }


    private func responseValue(id: String, in logURL: URL) -> String? {
        PiTestSupport.extensionUIResponses(in: logURL).first { $0["id"] as? String == id }?["value"] as? String
    }

    private func nativeAskResponse(id: String, in logURL: URL) -> [String: Any]? {
        guard let value = responseValue(id: id, in: logURL),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func startGLM47BridgeSession(harness: PiTestSupport.RPCHarness) throws -> (PiAgentSessionStore, PiAgentRunnerService, PiAgentSessionRecord) {
        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var session = store.createSession(kind: .project, title: "Ask Bridge", project: try PiTestSupport.makeProject(), repository: nil)
        store.updateSession(session.id) {
            $0.modelOverrideProvider = "zai"
            $0.modelOverrideID = "glm-4.7"
        }
        session = try XCTUnwrap(store.sessions.first(where: { $0.id == session.id }))
        runner.resume(session: session)
        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.launchCommand != nil
        })
        let launchCommand = try XCTUnwrap(store.sessions.first(where: { $0.id == session.id })?.launchCommand)
        XCTAssertTrue(launchCommand.contains("--provider zai"))
        XCTAssertTrue(launchCommand.contains("--model glm-4.7"))
        XCTAssertTrue(launchCommand.contains("agent-deck-ask-user-bridge.ts"))
        _ = harness
        return (store, runner, session)
    }

    private func restoreEnv(_ key: String, oldValue: String?) {
        if let oldValue {
            setenv(key, oldValue, 1)
        } else {
            unsetenv(key)
        }
    }
}

private extension PiAgentRunnerService {
    func respondToAgentDeckAskRequest(_ request: PiAgentUIRequest, value: String) {
        respondToExtensionUI(sessionID: request.sessionID, requestID: request.id, value: value)
    }
}
