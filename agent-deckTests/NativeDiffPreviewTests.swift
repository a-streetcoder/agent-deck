import AppKit
import XCTest
@testable import agent_deck

@MainActor
final class NativeDiffPreviewTests: XCTestCase {
    private func lines() -> [NativeDiffPreviewLine] {
        [
            .init(gutter: "+ 42", content: "let faster = true", color: .systemGreen, background: .systemGreen.withAlphaComponent(0.2)),
            .init(gutter: "- 43", content: "let slower = false", color: .systemRed, background: .systemRed.withAlphaComponent(0.2))
        ]
    }

    func testSizingTracksRenderedLines() {
        let preview = NativeDiffPreviewView(lines: lines())
        let twoLineHeight = preview.fittingSize.height
        XCTAssertEqual(preview.renderedLineCount, 2)
        XCTAssertGreaterThan(twoLineHeight, 20)

        preview.configure(lines: [lines()[0]])
        XCTAssertEqual(preview.renderedLineCount, 1)
        XCTAssertLessThan(preview.fittingSize.height, twoLineHeight)
    }

    func testAccessibilityExposesEachDiffLine() {
        let preview = NativeDiffPreviewView(lines: lines())
        preview.frame = NSRect(x: 0, y: 0, width: 320, height: preview.fittingSize.height)
        preview.layoutSubtreeIfNeeded()

        let labels = (preview.accessibilityChildren() as? [NSAccessibilityElement])?.compactMap {
            $0.accessibilityLabel()
        }
        XCTAssertEqual(labels, ["+ 42 let faster = true", "- 43 let slower = false"])
    }

    func testRenderingPaintsLineBackgrounds() {
        let preview = NativeDiffPreviewView(lines: lines())
        preview.frame = NSRect(x: 0, y: 0, width: 320, height: preview.fittingSize.height)
        let canvas = NSView(frame: preview.bounds)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        canvas.addSubview(preview)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<3 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        canvas.displayIfNeeded()

        guard let image = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            return XCTFail("Could not create diff preview bitmap")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: image)
        let paintedBackground = (0..<image.pixelsWide).contains { x in
            (0..<image.pixelsHigh).contains { y in
                guard let color = image.colorAt(x: x, y: y) else { return false }
                return color.greenComponent > color.redComponent + 0.05
            }
        }
        XCTAssertTrue(paintedBackground, "Expected the added-line background to be drawn")
    }
}
