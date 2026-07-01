import Foundation
import XCTest
@testable import agent_deck

@MainActor
final class SlashUniverseTests: XCTestCase {
    func testGeneralChatSlashUniverseIsEmptyWithoutProjectFallback() {
        let viewModel = AppViewModel()
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        viewModel.selectedProjectPath = projectURL.path

        let projectFallbackUniverse = viewModel.slashUniverse(forProjectPath: nil, useSelectedProjectFallback: true)
        let generalChatUniverse = viewModel.slashUniverse(forProjectPath: nil, useSelectedProjectFallback: false)

        XCTAssertFalse(projectFallbackUniverse.loops.isEmpty)
        XCTAssertTrue(generalChatUniverse.isEmpty)
    }

    func testCategoryPickerOmitsEmptyProjectOnlyCategories() {
        let skill = SlashItem(
            id: "skill:global",
            kind: .skill,
            displayName: "Global Skill",
            description: nil,
            scopeLabel: "Global",
            isActive: false,
            payload: .skill(name: "Global Skill", body: "Use this skill", filePath: nil, recordID: nil)
        )
        let prompt = SlashItem(
            id: "prompt:global",
            kind: .prompt,
            displayName: "Global Prompt",
            description: nil,
            scopeLabel: "Global",
            isActive: false,
            payload: .prompt(name: "Global Prompt", body: "Use this prompt", filePath: nil, recordID: nil)
        )
        let universe = SlashUniverse(skills: [skill], prompts: [prompt], commands: [], loops: [])

        let rows = SlashSuggestionRowBuilder.rows(universe: universe, state: SlashSuggestionState(), query: "")

        XCTAssertEqual(rows.map { $0.id }, ["cat:prompt", "cat:skill"])
    }
}
