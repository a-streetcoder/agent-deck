import AppKit
import XCTest
@testable import agent_deck

@MainActor
final class TypographyTests: XCTestCase {
    func testFixedContentHierarchyAndNativeTranscriptParity() {
        XCTAssertEqual(AppTheme.Font.titleSize, 20)
        XCTAssertEqual(AppTheme.Font.sectionTitleSize, 15)
        XCTAssertEqual(AppTheme.Font.primarySize, 14)
        XCTAssertEqual(AppTheme.Font.supportingSize, 13)
        XCTAssertEqual(AppTheme.Font.footnoteSize, 12)
        XCTAssertEqual(AppTheme.Font.metadataSize, 11)
        XCTAssertEqual(AppTheme.Font.microSize, 10)
        XCTAssertEqual(AppTheme.Font.codeSize, 13)

        XCTAssertEqual(NativeTranscriptFont.body().pointSize, AppTheme.Font.primarySize)
        XCTAssertEqual(NativeTranscriptFont.callout().pointSize, AppTheme.Font.supportingSize)
        XCTAssertEqual(NativeTranscriptFont.caption().pointSize, AppTheme.Font.metadataSize)
        XCTAssertEqual(NativeTranscriptFont.caption2().pointSize, AppTheme.Font.microSize)
        XCTAssertEqual(NativeTranscriptFont.code().pointSize, AppTheme.Font.codeSize)
    }

    func testWebMarkdownCSSMatchesFixedHierarchy() {
        let css = MarkdownWebView.css
        XCTAssertTrue(css.contains("font-size: 14px;"))
        XCTAssertTrue(css.contains("h1 { font-size: 20px; }"))
        XCTAssertTrue(css.contains("h2 { font-size: 17px; }"))
        XCTAssertTrue(css.contains("h3, h4, h5, h6 { font-size: 15px; }"))
        XCTAssertEqual(css.components(separatedBy: "font-size: 13px;").count - 1, 3)
    }

    func testNativeMarkdownInlineCodeUsesCanonicalMonospacedCodeFont() {
        let container = NativeMarkdownTextContainer()
        let applier = MarkdownSourceApplier()
        defer {
            applier.cancel()
            container.dismantle()
        }

        let source = "plain `code` **bold** *italic*"
        applier.apply(source: source, to: container)
        guard let textView = firstTextView(in: container), let storage = textView.textStorage else {
            return XCTFail("Expected a native markdown text view")
        }

        let rendered = storage.string as NSString
        let codeRange = rendered.range(of: "code")
        let plainRange = rendered.range(of: "plain")
        let boldRange = rendered.range(of: "bold")
        let italicRange = rendered.range(of: "italic")
        let codeFont = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        let plainFont = storage.attribute(.font, at: plainRange.location, effectiveRange: nil) as? NSFont
        let boldFont = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let italicFont = storage.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont

        XCTAssertEqual(codeFont?.pointSize, AppTheme.Font.codeSize)
        XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertEqual(plainFont?.pointSize, AppTheme.Font.primarySize)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont ?? .systemFont(ofSize: 1)).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: italicFont ?? .systemFont(ofSize: 1)).contains(.italicFontMask))
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }
}
