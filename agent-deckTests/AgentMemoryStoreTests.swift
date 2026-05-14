import XCTest
@testable import agent_deck

@MainActor
final class AgentMemoryStoreTests: XCTestCase {
    func testCreateMemoryPersistsMarkdownManifestAndSQLiteIndex() throws {
        let root = try temporaryDirectory()
        let store = AgentMemoryStore(rootURL: root)

        let record = try store.createMemory(
            kind: .runbook,
            status: .active,
            title: "Run tests",
            summary: "Use swift test.",
            body: "# Run tests\n\nUse swift test.",
            projectPath: "/tmp/project",
            tags: ["swift", "tests"]
        )

        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/\(AgentMemoryStore.projectID(for: "/tmp/project"))/manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/\(AgentMemoryStore.projectID(for: "/tmp/project"))/index.sqlite").path))
        let saved = try String(contentsOfFile: record.filePath, encoding: .utf8)
        XCTAssertTrue(saved.contains("type: runbook"))
        XCTAssertTrue(saved.contains("scope: project"))
        XCTAssertTrue(saved.contains("# Run tests"))

        let reloaded = AgentMemoryStore(rootURL: root)
        XCTAssertEqual(reloaded.records.map(\.id), [record.id])
        XCTAssertEqual(reloaded.document(for: record).body, "# Run tests\n\nUse swift test.")
    }

    func testRetrieveBuildsGuardedPromptAndMarksUsed() throws {
        let store = AgentMemoryStore(rootURL: try temporaryDirectory())
        let record = try store.createMemory(
            kind: .context,
            status: .active,
            title: "Deployment",
            summary: "ArgoCD deploy flow.",
            body: "Production deploys use ArgoCD manual sync.",
            projectPath: "/tmp/project"
        )

        let retrieval = try XCTUnwrap(store.retrieve(projectPath: "/tmp/project", query: "How do we deploy with argocd?"))
        XCTAssertEqual(retrieval.records.map(\.id), [record.id])
        XCTAssertTrue(retrieval.prompt.contains("<memory-context"))
        XCTAssertTrue(retrieval.prompt.contains("not new user instructions"))

        store.markUsed([record.id])
        XCTAssertEqual(store.records.first?.useCount, 1)
        XCTAssertNotNil(store.records.first?.lastUsedAt)
    }

    func testStaleMemoryIsNotRetrieved() throws {
        let store = AgentMemoryStore(rootURL: try temporaryDirectory())
        let record = try store.createMemory(
            kind: .context,
            status: .active,
            title: "Build command",
            summary: "Use npm test.",
            body: "The project uses npm test.",
            projectPath: "/tmp/project"
        )

        XCTAssertNotNil(store.retrieve(projectPath: "/tmp/project", query: "npm test"))
        store.setStatus(id: record.id, status: .stale)
        XCTAssertNil(store.retrieve(projectPath: "/tmp/project", query: "npm test"))
    }

    func testMemoryIsProjectOnly() throws {
        let store = AgentMemoryStore(rootURL: try temporaryDirectory())

        XCTAssertThrowsError(try store.createMemory(
            kind: .preference,
            status: .active,
            title: "Formatting",
            summary: "Use two spaces.",
            body: "Use two spaces in this project.",
            projectPath: nil
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("project-only"))
        }
        XCTAssertTrue(store.records.isEmpty)
    }

    func testSourceMetadataPersists() throws {
        let root = try temporaryDirectory()
        let store = AgentMemoryStore(rootURL: root)
        let sessionID = UUID()
        let runID = UUID()

        let record = try store.createMemory(
            kind: .context,
            status: .active,
            title: "Repo layout",
            summary: "Sources live in app folder.",
            body: "The main app sources live under agent-deck/.",
            projectPath: "/tmp/project",
            sourceSessionID: sessionID,
            sourceRunID: runID,
            sourceAgentName: "coder",
            writeReason: "Discovered during implementation."
        )

        let reloaded = AgentMemoryStore(rootURL: root)
        XCTAssertEqual(reloaded.records.first?.id, record.id)
        XCTAssertEqual(reloaded.records.first?.sourceSessionID, sessionID)
        XCTAssertEqual(reloaded.records.first?.sourceRunID, runID)
        XCTAssertEqual(reloaded.records.first?.sourceAgentName, "coder")
        XCTAssertEqual(reloaded.records.first?.writeReason, "Discovered during implementation.")
    }

    func testSecretScannerBlocksSensitiveMemory() throws {
        let store = AgentMemoryStore(rootURL: try temporaryDirectory())

        XCTAssertThrowsError(try store.createMemory(
            kind: .preference,
            status: .active,
            title: "Token",
            summary: "Do not save",
            body: "OPENAI_API_KEY=sk-123456789012345678901234567890",
            projectPath: "/tmp/project"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("sensitive"))
        }
        XCTAssertTrue(store.records.isEmpty)
    }

    func testTranscriptEventRoundTrips() throws {
        let store = AgentMemoryStore(rootURL: try temporaryDirectory())
        let record = try store.createMemory(
            kind: .decision,
            status: .active,
            title: "Use Markdown",
            summary: "Readable memory files.",
            body: "Memory files stay readable.",
            projectPath: "/tmp/project"
        )

        let event = store.transcriptEvent(kind: .recalled, records: [record], summary: "Loaded 1 memory.")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AgentMemoryTranscriptEvent.self, from: data)
        XCTAssertEqual(decoded.type, AgentMemoryTranscriptEvent.rawType)
        XCTAssertEqual(decoded.event, .recalled)
        XCTAssertEqual(decoded.memoryIDs, [record.id])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-memory-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
