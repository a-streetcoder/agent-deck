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
        let issue = try makeIssueAttachment(isPullRequest: false)
        let pullRequest = try makeIssueAttachment(isPullRequest: true)

        runner.resume(
            session: session,
            initialPrompt: "<github-issue-context>issue RPC context</github-issue-context>",
            transcriptText: "",
            images: [image],
            issueAttachment: issue
        )
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }
        XCTAssertTrue(PiTestSupport.waitUntil { runner.isRunning(sessionID: session.id) })
        XCTAssertTrue(PiTestSupport.waitUntil { store.sessions.first(where: { $0.id == session.id })?.status == .idle })

        let attachmentOnly = "<file name=\"/tmp/notes.txt\"></file>\nfolder: `/tmp/reports`\n\(paste.marker)"
        runner.send(attachmentOnly, mode: .prompt, to: session.id, images: [image], pasteAttachments: [paste], issueAttachment: pullRequest)
        runner.send("", mode: .prompt, to: session.id, images: [image, image])
        runner.send("Keep this explicit text.", mode: .prompt, to: session.id, images: [image], issueAttachment: issue)

        XCTAssertTrue(PiTestSupport.waitUntil { store.transcript(for: session.id).filter { $0.role == .user }.count == 4 })
        let entries = store.transcript(for: session.id).filter { $0.role == .user }
        XCTAssertEqual(entries[0].text, "<file name=\"image.png\"></file>")
        XCTAssertTrue(entries[1].text.contains("Attached files:\n- notes.txt"), "Canonical inline file syntax remains represented for the transcript renderer.")
        XCTAssertFalse(entries[1].text.contains("Attached a pull request"))
        XCTAssertEqual(entries[1].userAttachments?.images, [image], "Image chips remain in the persisted attachment payload.")
        XCTAssertEqual(entries[1].userAttachments?.issue, pullRequest)
        XCTAssertEqual(entries[1].userAttachments?.pastes, [paste])
        XCTAssertEqual(entries[2].text, "<file name=\"image.png\"></file>\n<file name=\"image.png\"></file>")
        XCTAssertTrue(entries[3].text.hasPrefix("Keep this explicit text."))
        XCTAssertFalse(entries[3].text.contains("Attached an issue"))

        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[0]), "Attached an issue and an image.")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[1]), "Attached a pull request, an image, a file, a folder, and a text paste.")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[2]), "Attached 2 images.")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entries[3]), "Keep this explicit text.")

        XCTAssertTrue(PiTestSupport.waitUntil {
            rpcPromptMessages(in: harness.stdinLog).contains("Keep this explicit text.\n\n<file name=\"image.png\"></file>")
        })
        let messages = rpcPromptMessages(in: harness.stdinLog)
        XCTAssertEqual(messages, [
            "<github-issue-context>issue RPC context</github-issue-context>\n\n<file name=\"image.png\"></file>",
            "<file name=\"/tmp/notes.txt\"></file>\nfolder: `/tmp/reports`\n[paste #1 12 chars]\n\n<file name=\"image.png\"></file>",
            "<file name=\"image.png\"></file>\n<file name=\"image.png\"></file>",
            "Keep this explicit text.\n\n<file name=\"image.png\"></file>"
        ])
        XCTAssertFalse(messages.contains { $0.contains("Attached an issue") || $0.contains("Attached a pull request") })
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
        let issue = try makeIssueAttachment(isPullRequest: false)

        runner.resume(session: session)
        let discoveryStarted = await PiTestSupport.waitUntilAsync { discoveryContinuation != nil }
        XCTAssertTrue(discoveryStarted)
        runner.send("queued issue RPC context", mode: .steer, to: session.id, transcriptText: "", images: [image], issueAttachment: issue)
        let entry = try XCTUnwrap(store.transcript(for: session.id).last(where: { $0.role == .user }))
        XCTAssertEqual(entry.text, "<file name=\"queued.png\"></file>")
        XCTAssertEqual(PiAgentUserMessageContent.displayMessageText(for: entry), "Attached an issue and an image.")

        discoveryContinuation?.resume()
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }
        let queuedInputDelivered = await PiTestSupport.waitUntilAsync {
            rpcPromptMessages(in: stdinLog).contains("queued issue RPC context\n\n<file name=\"queued.png\"></file>")
        }
        XCTAssertTrue(queuedInputDelivered)
        XCTAssertEqual(rpcPromptMessages(in: stdinLog), ["queued issue RPC context\n\n<file name=\"queued.png\"></file>"])
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

    private func makeIssueAttachment(isPullRequest: Bool) throws -> PiAgentIssueAttachment {
        let kind = isPullRequest ? "pulls" : "issues"
        let json = """
        {"repository":"owner/repo","number":42,"title":"Attachment","url":"https://github.com/owner/repo/\(kind)/42","state":"OPEN","isPullRequest":\(isPullRequest),"labels":[],"assignees":[],"createdAt":0,"updatedAt":0,"body":"","subIssues":[],"blockedBy":[],"blocking":[],"comments":[]}
        """
        return try JSONDecoder().decode(PiAgentIssueAttachment.self, from: XCTUnwrap(json.data(using: .utf8)))
    }

    func testPromptSendIncludesSteerFallbackWhenLocalStatusIsIdleButClientIsRunning() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: [
            "type": "response",
            "command": "get_state",
            "success": true,
            "data": ["isStreaming": false]
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Busy Race", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil { runner.isRunning(sessionID: session.id) })
        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.status == .idle
        })

        runner.send("is it finished?", mode: .prompt, to: session.id)

        XCTAssertTrue(PiTestSupport.waitUntil {
            (try? String(contentsOf: harness.stdinLog, encoding: .utf8))?.contains("is it finished?") == true
        })
        let stdin = try String(contentsOf: harness.stdinLog, encoding: .utf8)
        let promptLines = stdin.split(separator: "\n").filter { $0.contains("is it finished?") }
        let promptLine = try XCTUnwrap(promptLines.last)
        XCTAssertTrue(promptLine.contains(#""type":"prompt""#))
        XCTAssertTrue(promptLine.contains(#""streamingBehavior":"steer""#))
    }

    func testSessionThinkingUsesLaunchArgumentAndDoesNotSendDefaultMutatingRPC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-thinking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let argsLog = directory.appendingPathComponent("args.log")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let sessionFile = directory.appendingPathComponent("session.jsonl")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(PiTestSupport.shellSingleQuoted(argsLog.path))
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> \(PiTestSupport.shellSingleQuoted(stdinLog.path))
          case "$line" in
            *'"type":"get_state"'*)
              printf '%s\\n' '{"type":"response","command":"get_state","success":true,"data":{"sessionFile":"\(sessionFile.path)","thinkingLevel":"high","isStreaming":false}}'
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
        let created = store.createSession(kind: .project, title: "Thinking", project: try PiTestSupport.makeProject(url: directory), repository: nil)
        store.updateSession(created.id) {
            $0.modelOverrideProvider = "openai-codex"
            $0.modelOverrideID = "gpt-5.2"
            $0.thinkingLevel = "high"
        }
        let session = try XCTUnwrap(store.sessions.first(where: { $0.id == created.id }))

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil { FileManager.default.fileExists(atPath: stdinLog.path) })
        let args = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(args.contains("--provider\nopenai-codex"))
        XCTAssertTrue(args.contains("--model\ngpt-5.2"))
        XCTAssertTrue(args.contains("--thinking\nhigh"))

        let stdin = try String(contentsOf: stdinLog, encoding: .utf8)
        XCTAssertFalse(stdin.contains("set_thinking_level"))
        XCTAssertFalse(stdin.contains("set_model"))
        let updated = try XCTUnwrap(store.sessions.first(where: { $0.id == session.id }))
        XCTAssertEqual(updated.thinkingLevel, "high")
    }

    func testSessionTitleGenerationUsesLaunchTimeModelThinkingAndDoesNotMutateRPCDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let argsLog = directory.appendingPathComponent("args.log")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(PiTestSupport.shellSingleQuoted(argsLog.path))
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> \(PiTestSupport.shellSingleQuoted(stdinLog.path))
          printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Fix Session Titles"}]}}'
          printf '%s\\n' '{"type":"turn_end"}'
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        var generatedTitle: String?
        var generatedError: Error?
        let titleGenerator = PiSessionTitleGenerationService()
        titleGenerator.generateTitle(
            for: "Something is off in dynamic session titles.",
            model: AvailableModel(provider: "zai", model: "glm-5.1:high", contextWindow: "1M", maxOutput: "64K", supportsThinking: true, supportsImages: false, supportedThinkingLevels: ["off", "low", "medium", "high"]),
            projectURL: directory,
            environment: [:]
        ) { result in
            switch result {
            case let .success(title): generatedTitle = title
            case let .failure(error): generatedError = error
            }
        }

        XCTAssertTrue(PiTestSupport.waitUntil { generatedTitle != nil || generatedError != nil })
        XCTAssertEqual(generatedTitle, "Fix Session Titles")
        XCTAssertNil(generatedError)

        let args = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(args.contains("--provider\nzai"))
        XCTAssertTrue(args.contains("--model\nglm-5.1:off"))
        XCTAssertTrue(args.contains("--system-prompt\n"))
        XCTAssertTrue(args.contains("--append-system-prompt\n\n"))
        XCTAssertTrue(args.contains("--no-context-files"))
        XCTAssertTrue(args.contains("--no-prompt-templates"))
        XCTAssertTrue(args.contains("--no-themes"))
        XCTAssertTrue(args.contains("session title generator"))
        XCTAssertTrue(args.contains("capture the concrete goal or change"))

        let stdin = try String(contentsOf: stdinLog, encoding: .utf8)
        XCTAssertTrue(stdin.contains(#""type":"prompt""#))
        XCTAssertFalse(stdin.contains("set_thinking_level"))
        XCTAssertFalse(stdin.contains("set_model"))
    }

    func testCommitMessageGenerationUsesIsolatedCustomSystemPrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-commit-message-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let argsLog = directory.appendingPathComponent("args.log")
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(PiTestSupport.shellSingleQuoted(argsLog.path))
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> \(PiTestSupport.shellSingleQuoted(stdinLog.path))
          printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Title: Improve Session Title Prompting\\nBody: - Clarifies generated titles around user goals"}]}}'
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        defer { restoreEnv("AGENT_DECK_PI_PATH", oldValue: oldPiPath) }

        var generatedMessage: PiAgentShipService.CommitMessage?
        var generatedError: Error?
        let shipService = PiAgentShipService()
        shipService.generateCommitMessage(
            status: "## main\nM  agent-deck/PiSessionTitleGenerationService.swift",
            diff: "agent-deck/PiSessionTitleGenerationService.swift | 12 ++++++++----",
            model: AvailableModel(provider: "zai", model: "glm-5.1:high", contextWindow: "1M", maxOutput: "64K", supportsThinking: true, supportsImages: false, supportedThinkingLevels: ["off", "low", "medium", "high"]),
            projectURL: directory,
            environment: [:]
        ) { result in
            switch result {
            case let .success(message): generatedMessage = message
            case let .failure(error): generatedError = error
            }
        }

        XCTAssertTrue(PiTestSupport.waitUntil { generatedMessage != nil || generatedError != nil })
        XCTAssertEqual(generatedMessage?.title, "Improve Session Title Prompting")
        XCTAssertEqual(generatedMessage?.body, "- Clarifies generated titles around user goals")
        XCTAssertNil(generatedError)

        let args = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(args.contains("--provider\nzai"))
        XCTAssertTrue(args.contains("--model\nglm-5.1:off"))
        XCTAssertTrue(args.contains("--system-prompt\n"))
        XCTAssertTrue(args.contains("--append-system-prompt\n\n"))
        XCTAssertTrue(args.contains("--no-context-files"))
        XCTAssertTrue(args.contains("--no-prompt-templates"))
        XCTAssertTrue(args.contains("--no-themes"))
        XCTAssertTrue(args.contains("git commit message generator"))
        XCTAssertTrue(args.contains("concrete code or product change"))

        let stdin = try String(contentsOf: stdinLog, encoding: .utf8)
        XCTAssertTrue(stdin.contains(#""type":"prompt""#))
        XCTAssertTrue(stdin.contains("Generate a git commit message for these staged changes"))
        XCTAssertFalse(stdin.contains("set_thinking_level"))
        XCTAssertFalse(stdin.contains("set_model"))
    }

    func testEnvRuntimeEnvironmentMergesBaseGlobalAndRuntimePrecedence() throws {
        let directory = try PiTestSupport.temporaryProjectURL()
        let globalEnv = directory.appendingPathComponent("global.env")
        let projectEnv = directory.appendingPathComponent(".pi/.env")
        try FileManager.default.createDirectory(at: projectEnv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        SHARED=global
        GLOBAL_ONLY=global-value
        QUOTED="hello world"
        INVALID-NAME=ignored
        AGENT_DECK_PARENT_SESSION_ID=global-bad
        """.write(to: globalEnv, atomically: true, encoding: .utf8)
        try """
        SHARED=project
        PROJECT_ONLY=project-value
        AGENT_DECK_PARENT_SESSION_ID=project-bad
        """.write(to: projectEnv, atomically: true, encoding: .utf8)

        let environment = EnvRuntimeEnvironment().environment(
            globalEnv: globalEnv,
            base: [
                "SHARED": "base",
                "BASE_ONLY": "base-value"
            ],
            extra: ["AGENT_DECK_PARENT_SESSION_ID": "runtime-good"]
        )

        XCTAssertEqual(environment["BASE_ONLY"], "base-value")
        XCTAssertEqual(environment["GLOBAL_ONLY"], "global-value")
        XCTAssertNil(environment["PROJECT_ONLY"])
        XCTAssertEqual(environment["QUOTED"], "hello world")
        XCTAssertEqual(environment["SHARED"], "global")
        XCTAssertEqual(environment["AGENT_DECK_PARENT_SESSION_ID"], "runtime-good")
        XCTAssertNil(environment["INVALID-NAME"])
    }

    func testParentSessionDoesNotInjectProjectEnvIntoPiProcess() throws {
        let harness = try PiTestSupport.makeEnvCaptureHarness(keys: [
            "AGENT_DECK_ENV_SMOKE",
            "AGENT_DECK_ENV_COLLIDE",
            "AGENT_DECK_PARENT_SESSION_ID",
            "AGENT_DECK_OPENAI_FAST_CONFIG"
        ])
        defer { harness.restoreEnvironment() }

        let oldCollide = getenv("AGENT_DECK_ENV_COLLIDE").map { String(cString: $0) }
        setenv("AGENT_DECK_ENV_COLLIDE", "base", 1)
        defer { restoreEnv("AGENT_DECK_ENV_COLLIDE", oldValue: oldCollide) }

        let projectURL = try PiTestSupport.temporaryProjectURL()
        let projectEnv = projectURL.appendingPathComponent(".pi/.env")
        try FileManager.default.createDirectory(at: projectEnv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        AGENT_DECK_ENV_SMOKE=project-value
        AGENT_DECK_ENV_COLLIDE=project-wins
        AGENT_DECK_PARENT_SESSION_ID=project-must-not-win
        """.write(to: projectEnv, atomically: true, encoding: .utf8)

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Env", project: try PiTestSupport.makeProject(url: projectURL), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { FileManager.default.fileExists(atPath: harness.envLog.path) })
        let captured = PiTestSupport.capturedEnvironment(in: harness.envLog)
        XCTAssertEqual(captured["AGENT_DECK_ENV_SMOKE"], "")
        XCTAssertEqual(captured["AGENT_DECK_ENV_COLLIDE"], "base")
        XCTAssertEqual(captured["AGENT_DECK_PARENT_SESSION_ID"], session.id.uuidString)
        XCTAssertEqual(captured["AGENT_DECK_OPENAI_FAST_CONFIG"], PiNativeSubagentBridgeExtensions.openAIFastConfigURL().path)
    }

    func testManagedSubagentBridgeRoutesRequestAndResponds() throws {
        let payload = #"{"agent":"explorer","task":"Map the repo.","continueSubagentID":"11111111-1111-1111-1111-111111111111","reads":["README.md"]}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-subagent-1", name: "managed_subagent", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var captured: PiManagedSubagentBridgeRequest?
        runner.onManagedSubagentRequest = { _, request, completion in
            captured = request
            completion("subagent accepted")
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            PiTestSupport.extensionUIResponses(in: harness.stdinLog).contains { $0["id"] as? String == "bridge-subagent-1" }
        })
        XCTAssertEqual(captured?.agent, "explorer")
        XCTAssertEqual(captured?.task, "Map the repo.")
        XCTAssertEqual(captured?.continueSubagentID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(captured?.reads, ["README.md"])
        XCTAssertEqual(responseValue(id: "bridge-subagent-1", in: harness.stdinLog), "subagent accepted")
        XCTAssertEqual(store.transcriptsBySessionID[session.id]?.last?.title, "Deck Agent Requested")
    }

    func testManagedParallelBridgeRoutesRequestAndResponds() throws {
        let payload = #"{"tasks":[{"agent":"explorer","task":"Map"},{"agent":"reviewer","task":"Review"}],"concurrency":2,"worktree":true}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-parallel-1", name: "managed_parallel", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        var captured: PiManagedParallelBridgeRequest?
        runner.onManagedParallelRequest = { _, request, completion in
            captured = request
            completion("parallel accepted")
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-parallel-1", in: harness.stdinLog) == "parallel accepted" })
        XCTAssertEqual(captured?.tasks.map(\.agent), ["explorer", "reviewer"])
        XCTAssertEqual(captured?.concurrency, 2)
        XCTAssertEqual(captured?.worktree, true)
    }

    func testSupervisorListAndAnswerBridgeRoutesWithoutOpeningEditorUI() throws {
        let listEvent = PiRPCBridgeFixtures.bridgeEditor(id: "bridge-list-1", name: "list_supervisor_requests", payload: #"{}"#)
        let answerPayload = #"{"requestID":"request-1","response":"Use worktree."}"#
        let answerEvent = PiRPCBridgeFixtures.bridgeEditor(id: "bridge-answer-1", name: "answer_supervisor_request", payload: answerPayload)
        let harness = try PiTestSupport.makeBridgeHarness(events: [listEvent, answerEvent])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSupervisorRequestsList = { _ in #"[{"id":"request-1","kind":"need_decision"}]"# }
        runner.onSupervisorRequestAnswer = { _, requestID, response in
            "\(requestID): \(response)"
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            responseValue(id: "bridge-list-1", in: harness.stdinLog) != nil
                && responseValue(id: "bridge-answer-1", in: harness.stdinLog) != nil
        })
        XCTAssertEqual(responseValue(id: "bridge-list-1", in: harness.stdinLog), #"[{"id":"request-1","kind":"need_decision"}]"#)
        XCTAssertEqual(responseValue(id: "bridge-answer-1", in: harness.stdinLog), "request-1: Use worktree.")
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testSetAndUpdateSessionPlanBridgePersistPlanAndRespond() throws {
        let setPayload = #"{"items":[{"id":"inspect","title":"Inspect","status":"in_progress"},{"id":"finish","title":"Finish","status":"todo"}]}"#
        let updatePayload = #"{"updates":[{"id":"inspect","status":"done"},{"id":"finish","status":"in_progress"}]}"#
        let harness = try PiTestSupport.makeBridgeHarness(events: [
            PiRPCBridgeFixtures.bridgeEditor(id: "bridge-plan-set", name: "set_session_plan", payload: setPayload),
            PiRPCBridgeFixtures.bridgeEditor(id: "bridge-plan-update", name: "update_session_plan", payload: updatePayload)
        ])
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSessionPlanSet = { sessionID, request in
            let plan = store.setSessionPlan(sessionID: sessionID, items: request.items)
            return "set \(plan.items.count)"
        }
        runner.onSessionPlanUpdate = { sessionID, request in
            let plan = store.updateSessionPlan(sessionID: sessionID, updates: request.updates)
            return "updated \(plan?.items.count ?? 0)"
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            responseValue(id: "bridge-plan-set", in: harness.stdinLog) == "set 2"
                && responseValue(id: "bridge-plan-update", in: harness.stdinLog) == "updated 2"
        })
        XCTAssertEqual(store.sessionPlan(for: session.id)?.items.map(\.status), [.done, .inProgress])
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testNoProjectSessionUsesCatalogProviderAndInjectsMCPBridgeOnlyForNonEmptyCatalog() throws {
        let enabledHarness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { enabledHarness.restoreEnvironment() }

        let enabledStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let enabledRunner = PiAgentRunnerService(store: enabledStore)
        var requestedMode: PiAgentNoProjectMode?
        enabledRunner.mcpCatalogProvider = { session in
            requestedMode = session.effectiveNoProjectMode
            return "Computer Use catalog."
        }
        let enabledSession = enabledStore.createNoProjectCodingAgentSession()
        enabledRunner.resume(session: enabledSession)
        defer { enabledRunner.stop(sessionID: enabledSession.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            enabledStore.sessions.first(where: { $0.id == enabledSession.id })?.launchCommand != nil
        })
        let enabledCommand = try XCTUnwrap(enabledStore.sessions.first(where: { $0.id == enabledSession.id })?.launchCommand)
        XCTAssertEqual(requestedMode, .general)
        XCTAssertTrue(enabledCommand.contains("agent-deck-mcp-bridge.ts"))
        XCTAssertTrue(enabledCommand.contains("Computer Use catalog."))

        let disabledHarness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { disabledHarness.restoreEnvironment() }
        let disabledStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let disabledRunner = PiAgentRunnerService(store: disabledStore)
        disabledRunner.mcpCatalogProvider = { _ in nil }
        let disabledSession = disabledStore.createAgentDeckBuilderSession()
        disabledRunner.resume(session: disabledSession)
        defer { disabledRunner.stop(sessionID: disabledSession.id, recordTranscript: false) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            disabledStore.sessions.first(where: { $0.id == disabledSession.id })?.launchCommand != nil
        })
        let disabledCommand = try XCTUnwrap(disabledStore.sessions.first(where: { $0.id == disabledSession.id })?.launchCommand)
        XCTAssertFalse(disabledCommand.contains("agent-deck-mcp-bridge.ts"))
    }

    func testParentSessionLaunchInjectsNativeBridgeExtensionAndCatalogOnlyWhenEnabled() throws {
        let enabledHarness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { enabledHarness.restoreEnvironment() }

        let enabledStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let enabledRunner = PiAgentRunnerService(store: enabledStore)
        enabledRunner.nativeSubagentCatalogProvider = { _ in "Native catalog prompt." }
        let enabledProjectURL = try PiTestSupport.temporaryProjectURL()
        let projectAppend = enabledProjectURL.appendingPathComponent(".pi/APPEND_SYSTEM.md")
        try FileManager.default.createDirectory(at: projectAppend.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Project append prompt.".write(to: projectAppend, atomically: true, encoding: .utf8)
        var enabledSession = enabledStore.createSession(kind: .project, title: "Enabled", project: try PiTestSupport.makeProject(url: enabledProjectURL), repository: nil)
        enabledStore.updateSession(enabledSession.id) {
            $0.modelOverrideProvider = "zai"
            $0.modelOverrideID = "glm-4.7"
        }
        enabledSession = try XCTUnwrap(enabledStore.sessions.first(where: { $0.id == enabledSession.id }))

        enabledRunner.resume(session: enabledSession)
        defer { enabledRunner.stop(sessionID: enabledSession.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            enabledStore.sessions.first(where: { $0.id == enabledSession.id })?.launchCommand != nil
        })
        let enabledCommand = try XCTUnwrap(enabledStore.sessions.first(where: { $0.id == enabledSession.id })?.launchCommand)
        XCTAssertTrue(enabledCommand.contains("--no-extensions"))
        XCTAssertTrue(enabledCommand.contains("--extension"))
        XCTAssertTrue(enabledCommand.contains("system-prompt-audit-bridge.ts"))
        XCTAssertTrue(enabledCommand.contains("agent-deck-ask-user-bridge.ts"))
        XCTAssertTrue(enabledCommand.contains("agent-deck-web-access.ts"))
        XCTAssertTrue(enabledCommand.contains("agent-deck-openai-fast.ts"))
        XCTAssertTrue(enabledCommand.contains("managed-subagent-bridge.ts"))
        XCTAssertTrue(enabledCommand.contains("--append-system-prompt"))
        XCTAssertTrue(enabledCommand.contains(projectAppend.path))
        XCTAssertTrue(enabledCommand.contains("Native catalog prompt."))
        XCTAssertLessThan(
            try XCTUnwrap(enabledCommand.range(of: projectAppend.path)?.lowerBound),
            try XCTUnwrap(enabledCommand.range(of: "Native catalog prompt.")?.lowerBound)
        )
        XCTAssertTrue(enabledCommand.contains("--provider zai"))
        XCTAssertTrue(enabledCommand.contains("--model glm-4.7"))

        let disabledHarness = try PiTestSupport.makeBridgeHarness(events: [])
        defer { disabledHarness.restoreEnvironment() }

        let disabledStore = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let disabledRunner = PiAgentRunnerService(store: disabledStore)
        disabledRunner.nativeSubagentCatalogProvider = { _ in "Native catalog prompt." }
        var disabledSession = disabledStore.createSession(kind: .project, title: "Disabled", project: try PiTestSupport.makeProject(), repository: nil)
        disabledStore.updateSession(disabledSession.id) { $0.subagentsEnabled = false }
        disabledSession = try XCTUnwrap(disabledStore.sessions.first(where: { $0.id == disabledSession.id }))

        disabledRunner.resume(session: disabledSession)
        defer { disabledRunner.stop(sessionID: disabledSession.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            disabledStore.sessions.first(where: { $0.id == disabledSession.id })?.launchCommand != nil
        })
        let disabledCommand = try XCTUnwrap(disabledStore.sessions.first(where: { $0.id == disabledSession.id })?.launchCommand)
        XCTAssertTrue(disabledCommand.contains("--no-extensions"))
        XCTAssertTrue(disabledCommand.contains("system-prompt-audit-bridge.ts"))
        XCTAssertTrue(disabledCommand.contains("agent-deck-ask-user-bridge.ts"))
        XCTAssertTrue(disabledCommand.contains("agent-deck-web-access.ts"))
        XCTAssertTrue(disabledCommand.contains("agent-deck-openai-fast.ts"))
        XCTAssertFalse(disabledCommand.contains("managed-subagent-bridge.ts"))
        XCTAssertFalse(disabledCommand.contains("--append-system-prompt"))
        XCTAssertFalse(disabledCommand.contains("Native catalog prompt."))
    }

    func testParentAppendPromptResolverMirrorsPiAppendDiscoveryOnlyWhenAgentDeckAppends() throws {
        let root = try PiTestSupport.temporaryProjectURL()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let projectAppend = project.appendingPathComponent(".pi/APPEND_SYSTEM.md")
        let globalAppend = home.appendingPathComponent(".pi/agent/APPEND_SYSTEM.md")
        try FileManager.default.createDirectory(at: projectAppend.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalAppend.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Project append".write(to: projectAppend, atomically: true, encoding: .utf8)
        try "Global append".write(to: globalAppend, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            PiParentAppendPromptResolver.appendSystemPromptArguments(projectURL: project, agentDeckAppendPrompts: [], homeDirectory: home),
            []
        )

        XCTAssertEqual(
            PiParentAppendPromptResolver.appendSystemPromptArguments(projectURL: project, agentDeckAppendPrompts: ["Native catalog"], homeDirectory: home),
            ["--append-system-prompt", projectAppend.path, "--append-system-prompt", "Native catalog"]
        )

        try FileManager.default.removeItem(at: projectAppend)
        XCTAssertEqual(
            PiParentAppendPromptResolver.appendSystemPromptArguments(projectURL: project, agentDeckAppendPrompts: ["Native catalog"], homeDirectory: home),
            ["--append-system-prompt", globalAppend.path, "--append-system-prompt", "Native catalog"]
        )

        try FileManager.default.removeItem(at: globalAppend)
        XCTAssertEqual(
            PiParentAppendPromptResolver.appendSystemPromptArguments(projectURL: project, agentDeckAppendPrompts: ["Native catalog"], homeDirectory: home),
            ["--append-system-prompt", "Native catalog"]
        )
    }

    func testNativeAskUserBridgeHandlesOpenQuestionWithGLM47Session() throws {
        let payload = #"{"question":"What should the release note say?","context":"Need one short sentence.","options":[]}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.nativeAsk(id: "ask-open", payload: payload))
        defer { harness.restoreEnvironment() }
        let (store, runner, session) = try startGLM47BridgeSession(harness: harness)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.uiRequestsBySessionID[session.id]?.id == "ask-open" })
        let request = try XCTUnwrap(store.uiRequestsBySessionID[session.id])
        XCTAssertEqual(request.method, .input)
        XCTAssertEqual(request.title, "What should the release note say?")
        XCTAssertEqual(request.message, "Need one short sentence.")
        XCTAssertEqual(request.responseFormat, .nativeAsk)

        runner.respondToAgentDeckAskRequest(request, value: request.nativeAskFreeformResponseValue("Ship the native ask bridge."))

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "ask-open", in: harness.stdinLog) != nil })
        let response = try XCTUnwrap(nativeAskResponse(id: "ask-open", in: harness.stdinLog))
        XCTAssertEqual(response["kind"] as? String, "freeform")
        XCTAssertEqual(response["text"] as? String, "Ship the native ask bridge.")
        let answer = try XCTUnwrap(store.transcript(for: session.id).last(where: \.isNativeAskResponse))
        XCTAssertEqual(answer.text, "Ship the native ask bridge.")
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testNativeAskUserBridgeHandlesSingleChoiceWithInlineComment() throws {
        let payload = #"{"question":"Which channel?","context":"GLM 4.7 smoke path.","options":[{"title":"Stable","description":"Lowest risk"},{"title":"Beta","description":"Faster feedback"}],"allowComment":true}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.nativeAsk(id: "ask-single", payload: payload))
        defer { harness.restoreEnvironment() }
        let (store, runner, session) = try startGLM47BridgeSession(harness: harness)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.uiRequestsBySessionID[session.id]?.id == "ask-single" })
        let request = try XCTUnwrap(store.uiRequestsBySessionID[session.id])
        XCTAssertEqual(request.method, .select)
        XCTAssertEqual(request.options, ["Stable", "Beta"])
        XCTAssertEqual(request.optionDescriptions["Stable"], "Lowest risk")
        XCTAssertTrue(request.allowsComment)

        runner.respondToAgentDeckAskRequest(request, value: request.nativeAskSelectionResponseValue(selections: ["Stable"], comment: "Use this for the first public build."))

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "ask-single", in: harness.stdinLog) != nil })
        let response = try XCTUnwrap(nativeAskResponse(id: "ask-single", in: harness.stdinLog))
        XCTAssertEqual(response["kind"] as? String, "selection")
        XCTAssertEqual(response["selections"] as? [String], ["Stable"])
        XCTAssertEqual(response["comment"] as? String, "Use this for the first public build.")
        let answer = try XCTUnwrap(store.transcript(for: session.id).last(where: \.isNativeAskResponse))
        XCTAssertEqual(answer.text, "Stable\n\nComment: Use this for the first public build.")
    }

    func testNativeAskUserBridgeHandlesMultipleChoiceWithInlineComment() throws {
        let payload = #"{"question":"Which cases should the smoke test cover?","options":["Open question","Single choice","Multiple choice"],"allowMultiple":true,"allowComment":true}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.nativeAsk(id: "ask-multi", payload: payload))
        defer { harness.restoreEnvironment() }
        let (store, runner, session) = try startGLM47BridgeSession(harness: harness)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.uiRequestsBySessionID[session.id]?.id == "ask-multi" })
        let request = try XCTUnwrap(store.uiRequestsBySessionID[session.id])
        XCTAssertEqual(request.method, .multiSelect)
        XCTAssertTrue(request.allowsComment)

        runner.respondToAgentDeckAskRequest(request, value: request.nativeAskSelectionResponseValue(selections: ["Open question", "Multiple choice"], comment: "Single choice is covered separately."))

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "ask-multi", in: harness.stdinLog) != nil })
        let response = try XCTUnwrap(nativeAskResponse(id: "ask-multi", in: harness.stdinLog))
        XCTAssertEqual(response["kind"] as? String, "selection")
        XCTAssertEqual(response["selections"] as? [String], ["Open question", "Multiple choice"])
        XCTAssertEqual(response["comment"] as? String, "Single choice is covered separately.")
        let answer = try XCTUnwrap(store.transcript(for: session.id).last(where: \.isNativeAskResponse))
        XCTAssertEqual(answer.text, "Open question\nMultiple choice\n\nComment: Single choice is covered separately.")
    }

    func testNativeAskUserBridgeHandlesChoiceFreeformAlternative() throws {
        let payload = #"{"question":"Choose an implementation path.","options":["Use package","Build native"],"allowFreeform":true}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.nativeAsk(id: "ask-freeform-choice", payload: payload))
        defer { harness.restoreEnvironment() }
        let (store, runner, session) = try startGLM47BridgeSession(harness: harness)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.uiRequestsBySessionID[session.id]?.id == "ask-freeform-choice" })
        let request = try XCTUnwrap(store.uiRequestsBySessionID[session.id])
        XCTAssertEqual(request.method, .select)
        XCTAssertTrue(request.allowsFreeform)

        runner.respondToAgentDeckAskRequest(request, value: request.nativeAskFreeformResponseValue("Build native, but keep the same result schema."))

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "ask-freeform-choice", in: harness.stdinLog) != nil })
        let response = try XCTUnwrap(nativeAskResponse(id: "ask-freeform-choice", in: harness.stdinLog))
        XCTAssertEqual(response["kind"] as? String, "freeform")
        XCTAssertEqual(response["text"] as? String, "Build native, but keep the same result schema.")
        let answer = try XCTUnwrap(store.transcript(for: session.id).last(where: \.isNativeAskResponse))
        XCTAssertEqual(answer.text, "Build native, but keep the same result schema.")
    }

    func testNativeAskResponseProjectionRejectsMalformedOrInvalidAnswers() {
        let request = PiAgentUIRequest(
            id: "ask", sessionID: UUID(), method: .select, title: "Choose", message: nil,
            options: ["Stable", "Beta"], optionDescriptions: [:], placeholder: nil, prefill: nil,
            allowsFreeform: true, allowsComment: true, responseFormat: .nativeAsk
        )

        XCTAssertNil(request.nativeAskResponseDisplayText(from: "not-json"))
        XCTAssertNil(request.nativeAskResponseDisplayText(from: #"{"kind":"selection","selections":[]}"#))
        XCTAssertNil(request.nativeAskResponseDisplayText(from: #"{"kind":"selection","selections":["Unknown"]}"#))
        XCTAssertNil(request.nativeAskResponseDisplayText(from: #"{"kind":"freeform","text":"   "}"#))
        XCTAssertNil(request.nativeAskResponseDisplayText(from: #"{"kind":"other"}"#))
    }

    func testParentSessionCapturesRuntimeSystemPromptAudit() throws {
        let payload = #"{"scope":"parent","systemPrompt":"Final parent prompt from Pi."}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "audit-parent-1", name: "system_prompt_audit", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Audit", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil {
            store.sessions.first(where: { $0.id == session.id })?.finalSystemPrompt == "Final parent prompt from Pi."
                && responseValue(id: "audit-parent-1", in: harness.stdinLog) == "System prompt captured."
        })
        XCTAssertNotNil(store.sessions.first(where: { $0.id == session.id })?.finalSystemPromptCapturedAt)
    }

    func testMalformedBridgeStillRespondsAndDoesNotOpenEditorUI() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.bridgeEditor(id: "bridge-plan-bad", name: "set_session_plan", payload: "{not-json"))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-plan-bad", in: harness.stdinLog) != nil })
        XCTAssertEqual(responseValue(id: "bridge-plan-bad", in: harness.stdinLog), "\(AppBrand.displayName) could not parse the session plan request.")
        XCTAssertNil(store.uiRequestsBySessionID[session.id])
    }

    func testNestedBridgeEditorShapeIsRecognized() throws {
        let payload = #"{"items":[{"id":"inspect","title":"Inspect","status":"in_progress"}]}"#
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.nestedBridgeEditor(id: "bridge-plan-nested", name: "set_session_plan", payload: payload))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        runner.onSessionPlanSet = { sessionID, request in
            let plan = store.setSessionPlan(sessionID: sessionID, items: request.items)
            return "set \(plan.items.count)"
        }
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { responseValue(id: "bridge-plan-nested", in: harness.stdinLog) == "set 1" })
        XCTAssertEqual(store.sessionPlan(for: session.id)?.items.first?.id, "inspect")
    }

    func testRegularEditorRequestStillBecomesInteractiveUIRequest() throws {
        let harness = try PiTestSupport.makeBridgeHarness(event: PiRPCBridgeFixtures.regularEditor(id: "editor-1"))
        defer { harness.restoreEnvironment() }

        let store = PiAgentSessionStore(fileURL: PiTestSupport.temporaryStateFile())
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "Bridge", project: try PiTestSupport.makeProject(), repository: nil)

        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id) }

        XCTAssertTrue(PiTestSupport.waitUntil { store.uiRequestsBySessionID[session.id]?.id == "editor-1" })
        XCTAssertEqual(store.uiRequestsBySessionID[session.id]?.method, .editor)
        XCTAssertTrue(PiTestSupport.extensionUIResponses(in: harness.stdinLog).isEmpty)
    }

    func testParentMCPStreamScrubsImagesAndPersistsOrderedBlocks() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let harness = try PiTestSupport.makeBridgeHarness(events: [
            ["type": "tool_execution_start", "toolCallId": "mcp-parent-1", "toolName": "mcp", "args": ["tool": "Pidgeon/preview", "args": ["id": 7]]],
            ["type": "tool_execution_update", "toolCallId": "mcp-parent-1", "toolName": "mcp", "partialResult": ["content": [["type": "text", "text": "updating"], ["type": "image", "mimeType": "image/png", "data": png]]]],
            ["type": "tool_execution_end", "toolCallId": "mcp-parent-1", "toolName": "mcp", "result": ["content": [["type": "text", "text": "before"], ["type": "image", "mimeType": "image/png", "data": png], ["type": "text", "text": "after"]]]]
        ])
        defer { harness.restoreEnvironment() }

        let stateFile = PiTestSupport.temporaryStateFile()
        let store = PiAgentSessionStore(fileURL: stateFile)
        let runner = PiAgentRunnerService(store: store)
        let session = store.createSession(kind: .project, title: "MCP stream", project: try PiTestSupport.makeProject(), repository: nil)
        runner.resume(session: session)
        defer { runner.stop(sessionID: session.id, recordTranscript: false) }

        let receivedFinalResult = await PiTestSupport.waitUntilAsync {
            store.transcript(for: session.id).first?.mcpResultBlocks?.count == 3
        }
        XCTAssertTrue(receivedFinalResult)
        let entry = try XCTUnwrap(store.transcript(for: session.id).first)
        XCTAssertEqual(entry.text, "before\nafter")
        XCTAssertFalse(try XCTUnwrap(entry.rawJSON).contains(png))
        guard case .text("before")? = entry.mcpResultBlocks?[0],
              case let .image(reference)? = entry.mcpResultBlocks?[1],
              case .text("after")? = entry.mcpResultBlocks?[2] else { return XCTFail("Expected ordered MCP result blocks") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reference.localPath)))

        store.flushForTesting()
        let transcriptURL = stateFile.deletingLastPathComponent().appendingPathComponent("agent-session-transcripts/parent-\(session.id.uuidString).json")
        XCTAssertFalse(try String(contentsOf: transcriptURL, encoding: .utf8).contains(png))
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
