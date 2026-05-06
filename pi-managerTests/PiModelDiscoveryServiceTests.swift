import XCTest
@testable import pi_manager

final class PiModelDiscoveryServiceTests: XCTestCase {
    func testParsesPiModelListRows() {
        let output = """
provider model context output thinking images
openai gpt-5.2 400k 128k yes yes
anthropic claude-sonnet-4.5 200k 64k no no
"""

        let models = PiModelDiscoveryService.parseAvailableModels(
            from: output,
            exactThinkingLevels: ["openai/gpt-5.2": ["off", "low", "medium", "high"]]
        )

        XCTAssertEqual(models.map(\.identifier), ["openai/gpt-5.2", "anthropic/claude-sonnet-4.5"])
        XCTAssertEqual(models.first?.supportedThinkingLevels, ["off", "low", "medium", "high"])
        XCTAssertEqual(models.last?.supportedThinkingLevels, ["off"])
    }

    func testExtractsProviderAndModelIdentifiers() {
        let output = """
provider model context output thinking images
openai gpt-5.2 400k 128k yes yes
"""

        let identifiers = PiModelDiscoveryService.availableModelIdentifiers(fromPiListOutput: output)

        XCTAssertEqual(identifiers.first?.provider, "openai")
        XCTAssertEqual(identifiers.first?.model, "gpt-5.2")
    }
}
