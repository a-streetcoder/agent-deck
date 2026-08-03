import XCTest
@testable import agent_deck

@MainActor
final class PiExtensionDisplayNamingTests: XCTestCase {
    func testUnscopedPackageBaseName() {
        XCTAssertEqual(PiExtensionDisplayNaming.unscopedPackageBaseName("@ff-labs/pi-fff"), "pi-fff")
        XCTAssertEqual(PiExtensionDisplayNaming.unscopedPackageBaseName("pi-ocr"), "pi-ocr")
        XCTAssertEqual(PiExtensionDisplayNaming.unscopedPackageBaseName("  "), "")
    }

    func testPackageNameWinsOverExtensionsFolder() {
        let root = URL(fileURLWithPath: "/tmp/node_modules/pi-ocr")
        let name = PiExtensionDisplayNaming.packageExtensionDisplayName(
            packageName: "pi-ocr",
            packageDirectory: root,
            launchSource: root.appendingPathComponent("extensions/index.ts").path
        )
        XCTAssertEqual(name, "pi-ocr")
    }

    func testPackageNameWinsOverSrcIndex() {
        let root = URL(fileURLWithPath: "/tmp/node_modules/@gotgenes/pi-permission-system")
        let name = PiExtensionDisplayNaming.packageExtensionDisplayName(
            packageName: "@gotgenes/pi-permission-system",
            packageDirectory: root,
            launchSource: root.appendingPathComponent("src/index.ts").path
        )
        XCTAssertEqual(name, "pi-permission-system")
    }

    func testDistIndexJsUsesPackageName() {
        let root = URL(fileURLWithPath: "/tmp/node_modules/pi-blackhole")
        let name = PiExtensionDisplayNaming.packageExtensionDisplayName(
            packageName: "pi-blackhole",
            packageDirectory: root,
            launchSource: root.appendingPathComponent("dist/index.js").path
        )
        XCTAssertEqual(name, "pi-blackhole")
    }

    func testUnusualRelativeKeepsSuffix() {
        let root = URL(fileURLWithPath: "/tmp/node_modules/multi")
        let name = PiExtensionDisplayNaming.packageExtensionDisplayName(
            packageName: "multi",
            packageDirectory: root,
            launchSource: root.appendingPathComponent("plugins/alpha.ts").path
        )
        XCTAssertEqual(name, "multi · plugins/alpha.ts")
    }
}
