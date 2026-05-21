import XCTest
@testable import agent_deck

final class ExternalSkillDiscoveryTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoots.removeAll()
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalSkillDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    @discardableResult
    private func writeSkill(
        at directory: URL,
        name: String? = nil,
        description: String? = nil,
        body: String = "Skill body."
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var text = ""
        if name != nil || description != nil {
            text += "---\n"
            if let name { text += "name: \(name)\n" }
            if let description { text += "description: \(description)\n" }
            text += "---\n"
        }
        text += body
        try text.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    // MARK: - Tests

    func testDiscoversNestedSkillRootsSortedByName() async throws {
        let root = try makeTempRoot()
        try writeSkill(at: root.appendingPathComponent("zebra"), name: "Zebra")
        try writeSkill(at: root.appendingPathComponent("nested/alpha"), name: "Alpha")

        let candidates = await ExternalSkillDiscovery.discover(root: root)

        XCTAssertEqual(candidates.map(\.name), ["Alpha", "Zebra"])
    }

    func testStopsDescendingOnceInsideASkillRoot() async throws {
        let root = try makeTempRoot()
        let skill = try writeSkill(at: root.appendingPathComponent("my-skill"), name: "My Skill")
        // A nested SKILL.md under an examples folder must NOT become its own root.
        try writeSkill(at: skill.appendingPathComponent("examples/demo"), name: "Demo")

        let candidates = await ExternalSkillDiscovery.discover(root: root)

        XCTAssertEqual(candidates.map(\.name), ["My Skill"])
    }

    func testSkipsExcludedDirectories() async throws {
        let root = try makeTempRoot()
        try writeSkill(at: root.appendingPathComponent("node_modules/pkg"), name: "Hidden In Node Modules")
        try writeSkill(at: root.appendingPathComponent("real"), name: "Real Skill")

        let candidates = await ExternalSkillDiscovery.discover(root: root)

        XCTAssertEqual(candidates.map(\.name), ["Real Skill"])
    }

    func testRootItselfMayBeASkillRoot() async throws {
        let root = try makeTempRoot()
        try writeSkill(at: root, name: "Root Skill", description: "Lives at the chosen folder.")

        let candidates = await ExternalSkillDiscovery.discover(root: root)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.name, "Root Skill")
        XCTAssertEqual(candidates.first?.description, "Lives at the chosen folder.")
    }

    func testRespectsMaxDepth() async throws {
        let root = try makeTempRoot()
        try writeSkill(at: root.appendingPathComponent("d1/d2/d3"), name: "Deep Skill")

        let shallow = await ExternalSkillDiscovery.discover(root: root, maxDepth: 2)
        XCTAssertTrue(shallow.isEmpty, "A skill below maxDepth should not be discovered.")

        let deep = await ExternalSkillDiscovery.discover(root: root, maxDepth: 16)
        XCTAssertEqual(deep.map(\.name), ["Deep Skill"])
    }

    func testCandidateFallsBackToFolderNameWithoutFrontmatter() async throws {
        let root = try makeTempRoot()
        try writeSkill(at: root.appendingPathComponent("folder-named-skill"), name: nil, description: nil)

        let candidates = await ExternalSkillDiscovery.discover(root: root)

        XCTAssertEqual(candidates.map(\.name), ["folder-named-skill"])
        XCTAssertNil(candidates.first?.description)
    }

    func testCandidateIsNilWithoutSkillFile() throws {
        let root = try makeTempRoot()
        let plainFolder = root.appendingPathComponent("not-a-skill")
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)

        XCTAssertNil(ExternalSkillDiscovery.candidate(at: plainFolder))
    }

    func testParsesFrontmatterFromLargeSkillFile() throws {
        let root = try makeTempRoot()
        // A body well past the bounded frontmatter read window; the name must
        // still be parsed because frontmatter sits at the top of the file.
        let largeBody = String(repeating: "Lorem ipsum dolor sit amet. ", count: 8_000)
        let skill = try writeSkill(
            at: root.appendingPathComponent("big"),
            name: "Big Skill",
            description: "Has a very long body.",
            body: largeBody
        )

        let candidate = try XCTUnwrap(ExternalSkillDiscovery.candidate(at: skill))
        XCTAssertEqual(candidate.name, "Big Skill")
        XCTAssertEqual(candidate.description, "Has a very long body.")
    }

    func testCancellationStopsScanEarly() async throws {
        let root = try makeTempRoot()
        try writeSkill(at: root.appendingPathComponent("a"), name: "A")

        let task = Task { await ExternalSkillDiscovery.discover(root: root) }
        task.cancel()
        let candidates = await task.value

        XCTAssertTrue(candidates.isEmpty, "A cancelled scan returns no candidates.")
    }
}
