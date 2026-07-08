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

    func testSingleActiveSkillSelectionMaterializesSlashInvocation() {
        let skill = SlashItem(
            id: "skill:active",
            kind: .skill,
            displayName: "Review",
            description: nil,
            scopeLabel: "Project",
            isActive: true,
            payload: .skill(name: "review", body: "Review body", filePath: nil, recordID: nil)
        )

        XCTAssertEqual(SlashItem.materialize(selections: [skill], userText: "check this"), "/skill:review\ncheck this")
    }

    func testMultipleSkillSelectionsInlineBodies() {
        let activeSkill = SlashItem(
            id: "skill:active",
            kind: .skill,
            displayName: "Review",
            description: nil,
            scopeLabel: "Project",
            isActive: true,
            payload: .skill(name: "review", body: "Review body", filePath: nil, recordID: nil)
        )
        let collection = SlashItem(
            id: "collection:plan",
            kind: .skill,
            displayName: "Plan",
            description: nil,
            scopeLabel: "Library",
            isActive: false,
            payload: .skillCollection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Plan", body: "Plan body")
        )

        XCTAssertEqual(SlashItem.selections(afterAdding: collection, to: [activeSkill]).map(\.id), [activeSkill.id, collection.id])
        XCTAssertEqual(
            SlashItem.materialize(selections: [activeSkill, collection], userText: "check this"),
            "Review body\n\nPlan body\n\ncheck this"
        )
        XCTAssertEqual(SlashItem.titleGenerationSource(selections: [activeSkill, collection], userText: "check this"), "check this")
    }

    func testCommandAndPromptSelectionsReplaceExistingSkills() {
        let skill = SlashItem(
            id: "skill:active",
            kind: .skill,
            displayName: "Review",
            description: nil,
            scopeLabel: "Project",
            isActive: true,
            payload: .skill(name: "review", body: "Review body", filePath: nil, recordID: nil)
        )
        let command = SlashItem(
            id: "command:help",
            kind: .command,
            displayName: "help",
            description: nil,
            scopeLabel: nil,
            isActive: true,
            payload: .command(slashName: "/help", commandID: "help")
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

        XCTAssertEqual(SlashItem.selections(afterAdding: command, to: [skill]).map(\.id), [command.id])
        XCTAssertEqual(SlashItem.selections(afterAdding: prompt, to: [skill]).map(\.id), [prompt.id])
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
