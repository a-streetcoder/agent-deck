import XCTest
@testable import agent_deck

@MainActor
final class DesignSystemAccessibilityTests: XCTestCase {
    func testActionTargetsMeetHIGFloor() {
        let regular = AppTheme.Control.regularActionTarget
        let minimum = AppTheme.Control.minimumActionTarget
        XCTAssertEqual(regular, 28)
        XCTAssertGreaterThanOrEqual(regular, minimum)
        XCTAssertGreaterThanOrEqual(minimum, 20)
    }

    func testTypographyFloorTokens() {
        let micro = AppTheme.Font.microSize
        let metadata = AppTheme.Font.metadataSize
        let supporting = AppTheme.Font.supportingSize
        let code = AppTheme.Font.codeSize
        XCTAssertGreaterThanOrEqual(micro, 10)
        XCTAssertGreaterThanOrEqual(metadata, 10)
        XCTAssertGreaterThanOrEqual(supporting, 13)
        XCTAssertGreaterThanOrEqual(code, 13)
    }
}
