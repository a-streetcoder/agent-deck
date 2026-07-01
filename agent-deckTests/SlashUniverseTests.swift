import XCTest
@testable import agent_deck

@MainActor
final class SlashUniverseTests: XCTestCase {
    func testCategoryPickerOmitsEmptyProjectOnlyCategories() {
        let skill = SlashItem(
            id: "skill:global",
            kind: .skill,
            displayName: "Global Skill",
            description: nil,
            scopeLabel: "Global",
            isActive: false,
            payload: .skill(name: "Global Skill", body: "Use this skill")
        )
        let prompt = SlashItem(
            id: "prompt:global",
            kind: .prompt,
            displayName: "Global Prompt",
            description: nil,
            scopeLabel: "Global",
            isActive: false,
            payload: .prompt(name: "Global Prompt", body: "Use this prompt")
        )
        let universe = SlashUniverse(skills: [skill], prompts: [prompt], commands: [], loops: [])

        let rows = SlashSuggestionRowBuilder.rows(universe: universe, state: SlashSuggestionState(), query: "")

        XCTAssertEqual(rows.map { $0.id }, ["cat:prompt", "cat:skill"])
    }
}
