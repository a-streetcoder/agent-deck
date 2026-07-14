import XCTest
@testable import agent_deck

final class ProjectDiscoveryTests: XCTestCase {
    func testRootLevelDependencyDirectoriesAreNotProjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("real-project", isDirectory: true)
        let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
        let pods = root.appendingPathComponent("Pods", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pods, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("package.json"))
        try Data().write(to: nodeModules.appendingPathComponent("package.json"))
        try Data().write(to: pods.appendingPathComponent("package.json"))

        let discovered = ProjectDiscovery().discoverProjects(rootDirectoryURLs: [root])

        XCTAssertEqual(discovered.map(\.name), ["real-project"])
    }
}
