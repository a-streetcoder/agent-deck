import XCTest
@testable import agent_deck

@MainActor
final class CodingAgentRecentRowTests: XCTestCase {
    func testGeneralChatRecentRowUsesBubbleSymbolEvenWhenNoProjectLookupFallsBack() throws {
        var session = try PiTestSupport.makeParentSession()
        session.projectPath = ""
        session.projectName = PiAgentSessionRecord.noProjectDisplayName

        let project = try PiTestSupport.makeProject()
        let row = CodingAgentRecentRow(
            session: session,
            project: project,
            isSelected: false,
            isRunning: false,
            hasUIRequest: false,
            hasActiveLoop: false,
            onDelete: {}
        )

        XCTAssertEqual(row.iconSymbolName, "bubble.left.and.bubble.right")
        XCTAssertNil(row.iconImageURL)
        XCTAssertNil(row.iconAssetName)
    }

    func testProjectRecentRowKeepsProjectIconFallback() throws {
        let project = try PiTestSupport.makeProject()
        var session = try PiTestSupport.makeParentSession(projectURL: project.url)
        session.projectPath = project.path
        session.projectName = project.name

        let row = CodingAgentRecentRow(
            session: session,
            project: project,
            isSelected: false,
            isRunning: false,
            hasUIRequest: false,
            hasActiveLoop: false,
            onDelete: {}
        )

        XCTAssertEqual(row.iconSymbolName, project.fallbackSymbolName)
        XCTAssertEqual(row.iconImageURL, project.iconFileURL)
        XCTAssertEqual(row.iconAssetName, project.projectType.assetName)
    }
}
