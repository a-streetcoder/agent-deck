import AppKit
import XCTest
@testable import agent_deck

/// Guards the shared transcript-header geometry on plain user and assistant
/// bubbles. Both roles use the same native bubble view but different glyphs.
@MainActor
final class BubbleHeaderAlignmentTests: XCTestCase {
    private let rowWidth: CGFloat = 900
    private let userWidthRegressionText = "just deployed, let's see if it fixes it"

    private func payload(role: NativeBubblePayload.Role) -> NativeBubblePayload {
        let isUser = role == .user
        return NativeBubblePayload(
            role: role,
            headerTitle: isUser ? "You" : "Coding Agent",
            iconSymbol: isUser ? "person.crop.circle.fill" : nil,
            markdownSource: "Header alignment test.",
            copyText: "Header alignment test.",
            copySide: isUser ? .leading : .trailing,
            isThreadChild: !isUser,
            isUserHugged: isUser
        )
    }

    private func configureAndLayout(role: NativeBubblePayload.Role) -> (card: NSView, header: NSTextField, icon: NSImageView) {
        let payload = payload(role: role)
        let measure = PiAgentNativeBubbleView()
        measure.configure(payload: payload, width: rowWidth)
        let measuredHeight = measure.measuredHeight(forWidth: rowWidth)

        let view = PiAgentNativeBubbleView()
        view.configure(payload: payload, width: rowWidth)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: measuredHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: measuredHeight))
        window.contentView = host
        window.orderFrontRegardless()
        host.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: rowWidth),
            view.heightAnchor.constraint(equalToConstant: measuredHeight)
        ])
        view.settleLayoutImmediately()
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        guard let card = view.subviews.first(where: { candidate in
                  candidate.subviews.compactMap { $0 as? NSTextField }
                      .contains(where: { $0.stringValue == payload.headerTitle })
              }),
              let header = card.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == payload.headerTitle }),
              let icon = card.subviews.compactMap({ $0 as? NSImageView }).first(where: { imageView in
                  imageView.constraints.contains(where: {
                      $0.firstAttribute == .height &&
                      abs($0.constant - NativeTranscriptFont.headerIconSize) < 0.5
                  })
              }) else {
            preconditionFailure("Could not locate the bubble header and icon")
        }
        return (card, header, icon)
    }

    func testUserAndAssistantHeadersUseSharedDeterministicGeometry() {
        for role in [NativeBubblePayload.Role.user, .assistant] {
            let (card, header, icon) = configureAndLayout(role: role)
            XCTAssertEqual(header.frame.height, NativeTranscriptFont.headerIconSize, accuracy: 0.5)
            XCTAssertTrue(card.constraints.contains(where: { constraint in
                constraint.firstAttribute == .centerY &&
                ((constraint.firstItem as? NSView) === header || (constraint.secondItem as? NSView) === header) &&
                ((constraint.firstItem as? NSView) === icon || (constraint.secondItem as? NSView) === icon)
            }))
        }
    }

    func testUserBubbleNaturalWidthUsesRenderedTranscriptBodyFont() {
        let expected = ceil(
            (userWidthRegressionText as NSString).size(
                withAttributes: [.font: NativeTranscriptFont.body()]
            ).width
        )

        XCTAssertEqual(
            MessageTextWidth.naturalWidth(of: userWidthRegressionText),
            expected,
            accuracy: 0.5
        )
    }

    func testUserBubbleUsesNaturalWidthWithoutPrematureFinalWordWrap() throws {
        let payload = NativeBubblePayload(
            role: .user,
            headerTitle: "You",
            iconSymbol: "person.crop.circle.fill",
            markdownSource: userWidthRegressionText,
            copyText: userWidthRegressionText,
            copySide: .leading,
            isThreadChild: false,
            isUserHugged: true
        )
        let measuredHeightView = PiAgentNativeBubbleView()
        measuredHeightView.configure(payload: payload, width: rowWidth)
        let measuredHeight = measuredHeightView.measuredHeight(forWidth: rowWidth)

        let view = PiAgentNativeBubbleView()
        view.configure(payload: payload, width: rowWidth)
        view.frame = NSRect(x: 0, y: 0, width: rowWidth, height: measuredHeight)
        view.settleLayoutImmediately()

        let card = try XCTUnwrap(view.subviews.first)
        let textView = try XCTUnwrap(firstTextView(in: card))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        var lineCount = 0
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.enumerateLineFragments(
                forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
            ) { _, _, _, _, _ in
                lineCount += 1
            }
            XCTAssertGreaterThan(textContainer.containerSize.width, 0)
        }

        XCTAssertEqual(lineCount, 1)
        XCTAssertLessThan(
            card.frame.width,
            PiAgentBubbleWidth.replyCap(for: rowWidth),
            "A short user message should hug its content rather than fill the response-card cap."
        )
    }

    func testLongUserBubbleStillStopsAtTheDefinedMaximumWidth() {
        let paneWidth: CGFloat = 2_000
        let expectedCap = min(
            paneWidth * PiAgentBubbleWidth.userCapMultiplier,
            PiAgentBubbleWidth.userCapMax
        )

        XCTAssertEqual(
            PiAgentBubbleWidth.huggedUser(
                text: String(repeating: "This message must eventually wrap. ", count: 100),
                paneWidth: paneWidth
            ),
            expectedCap,
            accuracy: 0.5
        )
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }
}
