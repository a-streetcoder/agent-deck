import AppKit
import XCTest
@testable import agent_deck

@MainActor
final class MarkdownLocalLinkTests: XCTestCase {
    func testRelativeLinkUsesSessionWorkingDirectoryAndDecodesChineseFilename() throws {
        let base = URL(fileURLWithPath: "/tmp/project/worktree", isDirectory: true)
        let link = try XCTUnwrap(URL(string: "docs/%E9%80%90%E9%A1%B5%E7%90%86%E8%A7%A3%E8%AE%B2%E4%B9%89.md"))
        XCTAssertEqual(MarkdownLocalLinkResolver.fileURL(for: link, baseURL: base)?.path,
                       "/tmp/project/worktree/docs/逐页理解讲义.md")
    }

    func testAbsolutePathDoesNotDependOnWorkingDirectory() throws {
        let link = try XCTUnwrap(URL(string: "/tmp/%E8%AE%B2%E4%B9%89.md"))
        XCTAssertEqual(MarkdownLocalLinkResolver.fileURL(for: link, baseURL: nil)?.path, "/tmp/讲义.md")
    }

    func testOtherLinksRemainWithSystemHandler() throws {
        let base = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        for value in ["https://example.com/report", "file:///tmp/report.md", "sandbox:/mnt/data/report.pdf", "#section"] {
            XCTAssertNil(MarkdownLocalLinkResolver.fileURL(for: try XCTUnwrap(URL(string: value)), baseURL: base))
        }
        XCTAssertNil(MarkdownLocalLinkResolver.fileURL(for: try XCTUnwrap(URL(string: "report.md")), baseURL: nil))
    }

    func testRenderedLinkUsesTheCurrentSessionDirectory() throws {
        let container = NativeMarkdownTextContainer(frame: .zero)
        let applier = MarkdownSourceApplier()
        container.linkBaseURL = URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        var opened: URL?
        container.openLocalLink = { opened = $0 }
        applier.apply(source: "[逐页理解讲义](docs/%E8%AE%B2%E4%B9%89.md)", to: container)

        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try XCTUnwrap(textView(in: container))
        let link = try XCTUnwrap(text.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        let delegate = try XCTUnwrap(text.delegate)
        XCTAssertTrue(delegate.textView?(text, clickedOnLink: link, at: 0) == true)
        XCTAssertEqual(opened?.path, "/tmp/worktree/docs/讲义.md")
    }
}
