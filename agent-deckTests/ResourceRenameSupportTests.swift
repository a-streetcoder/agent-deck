import XCTest
@testable import agent_deck

@MainActor
final class ResourceRenameSupportTests: XCTestCase {
    func testNameValidationRejectsUnsafeNames() throws {
        XCTAssertEqual(try ResourceRenameSupport.normalizedName("  code-review  "), "code-review")
        XCTAssertThrowsError(try ResourceRenameSupport.normalizedName(""))
        XCTAssertThrowsError(try ResourceRenameSupport.normalizedName("../review"))
        XCTAssertThrowsError(try ResourceRenameSupport.normalizedName("review:prod"))
        XCTAssertThrowsError(try ResourceRenameSupport.normalizedName("review\nprod"))
    }

    func testReplacingExistingFrontmatterNamePreservesBody() {
        let input = """
        ---
        name: old-skill
        description: Useful skill
        ---

        Use this skill.
        """

        let output = ResourceRenameSupport.replacingFrontmatterValue(in: input, key: "name", value: "new-skill")

        XCTAssertTrue(output.contains("name: new-skill"))
        XCTAssertTrue(output.contains("description: Useful skill"))
        XCTAssertTrue(output.contains("Use this skill."))
        XCTAssertFalse(output.contains("name: old-skill"))
    }

    func testAddingMissingFrontmatterName() {
        let input = """
        ---
        description: Useful skill
        ---

        Use this skill.
        """

        let output = ResourceRenameSupport.replacingFrontmatterValue(in: input, key: "name", value: "new-skill")

        XCTAssertTrue(output.contains("name: new-skill"))
        XCTAssertTrue(output.contains("description: Useful skill"))
        XCTAssertTrue(output.contains("Use this skill."))
    }

    func testWrappingDocumentWithoutFrontmatter() {
        let output = ResourceRenameSupport.replacingFrontmatterValue(in: "Use this skill.", key: "name", value: "new-skill")

        XCTAssertTrue(output.hasPrefix("---\nname: new-skill\n---"))
        XCTAssertTrue(output.contains("Use this skill."))
    }
}
