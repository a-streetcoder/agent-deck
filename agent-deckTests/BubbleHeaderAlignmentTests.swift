import AppKit
import XCTest
@testable import agent_deck

/// Guards the shared transcript-header geometry on plain user and assistant
/// bubbles. Both roles use the same native bubble view but different glyphs.
@MainActor
final class BubbleHeaderAlignmentTests: XCTestCase {
    private let rowWidth: CGFloat = 900

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
}
