import AppKit
import XCTest
@testable import agent_deck

/// Diagnostic for the cropped subagent run card: drives the REAL native card
/// through the same configure → measure → layout flow the transcript cell uses
/// and checks that the measured height actually contains the laid-out content.
@MainActor
final class SubagentCardMeasureDiagnosticTests: XCTestCase {

    private func runningPayload(task: String) -> NativeAgentBlockPayload {
        NativeAgentBlockPayload(
            agentName: "explorer",
            agentDescription: "Quickly maps unfamiliar projects and reports the relevant files and data flow.",
            whenToUse: "Use for focused reconnaissance before implementation.",
            statusText: "Running",
            statusColor: .systemBlue,
            isActive: true,
            avatarURL: nil,
            outcomePill: nil,
            task: task,
            durationText: nil,
            modelText: "openai-codex/gpt-5.4-mini:low",
            tokensText: nil,
            actions: [
                .init(symbol: "info.circle", help: "Run details") { _ in },
                .init(symbol: "doc.text.magnifyingglass", help: "Prompt") { _ in },
                .init(symbol: "text.bubble", help: "Transcript") { _ in },
                .init(symbol: "stop.circle.fill", help: "Stop", isDestructive: true) { _ in }
            ]
        )
    }

    private let sampleTask = """
    Investigate why toggling an agent for the current project rebuilds the whole \
    agent view. Look at AppViewModel, the agents screen, and any observable state \
    that the toggle writes. Report the invalidation chain and the minimal fix.
    """

    func testNameAndModelMetadataAreOpticallyCentered() {
        let block = PiAgentNativeAgentBlockView()
        let payload = runningPayload(task: sampleTask)
        block.configure(payload)

        let width: CGFloat = 900
        let height = block.measuredHeight(forWidth: width)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.addSubview(block)
        NSLayoutConstraint.activate([
            block.topAnchor.constraint(equalTo: host.topAnchor),
            block.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            block.widthAnchor.constraint(equalToConstant: width),
            block.heightAnchor.constraint(equalToConstant: height)
        ])
        host.layoutSubtreeIfNeeded()

        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { subview in
                (subview as? NSTextField).map { [$0] } ?? labels(in: subview)
            }
        }
        let allLabels = labels(in: block)
        guard let name = allLabels.first(where: { $0.stringValue == payload.agentName }),
              let model = allLabels.first(where: { $0.stringValue == payload.modelText }),
              let row = name.superview as? NSStackView,
              model.superview === row else {
            return XCTFail("Could not locate the shared subagent name/model row")
        }

        XCTAssertEqual(row.alignment, .centerY)
        XCTAssertEqual(name.frame.midY, model.frame.midY, accuracy: 0.5)
    }

    func testRunCardMeasuredHeightContainsContent() {
        let rowWidth: CGFloat = 900

        let card = PiAgentNativeSubagentRunCardView()
        card.configure(payload: runningPayload(task: sampleTask), width: rowWidth)
        let measured = card.measuredHeight(forWidth: rowWidth)
        print("DIAG measured(after configure) = \(measured)")

        // Lay the card out at exactly the measured height, like the table does.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 1200))
        window.contentView = host
        host.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.widthAnchor.constraint(equalToConstant: rowWidth),
            card.heightAnchor.constraint(equalToConstant: measured)
        ])
        host.layoutSubtreeIfNeeded()

        // Walk the deepest content bottom inside the card.
        var maxBottom: CGFloat = 0
        func walk(_ view: NSView, offsetY: CGFloat) {
            for sub in view.subviews where !sub.isHidden {
                let bottom = offsetY + sub.frame.maxY
                maxBottom = max(maxBottom, bottom)
                walk(sub, offsetY: offsetY + sub.frame.minY)
            }
        }
        walk(card, offsetY: 0)
        print("DIAG laid-out content bottom = \(maxBottom), measured = \(measured)")

        XCTAssertGreaterThan(measured, 90, "measured height suspiciously small")
        XCTAssertLessThanOrEqual(maxBottom, measured + 1,
            "content overflows the measured height — row will crop")

        // Re-measure after layout: must be stable (no oscillation between passes).
        let second = card.measuredHeight(forWidth: rowWidth)
        print("DIAG measured(after layout) = \(second)")
        XCTAssertEqual(measured, second, accuracy: 1.0,
            "measure not idempotent — estimate↔measure wobble")
    }

    /// The cell measures BEFORE any configure when a recycled/new view reports
    /// via the async layout path — make sure that path can't poison the cache
    /// with a tiny height that a later configure won't correct.
    func testMeasureBeforeConfigureThenAfter() {
        let rowWidth: CGFloat = 900
        let card = PiAgentNativeSubagentRunCardView()
        let bare = card.measuredHeight(forWidth: rowWidth)
        print("DIAG measured(bare, never configured) = \(bare)")
        card.configure(payload: runningPayload(task: sampleTask), width: rowWidth)
        let configured = card.measuredHeight(forWidth: rowWidth)
        print("DIAG measured(after configure) = \(configured)")
        XCTAssertGreaterThan(configured, bare - 1)
    }

    func testExpandableMarkdownCollapsedMeasure() {
        let task = PiAgentNativeExpandableMarkdown()
        task.configure(source: sampleTask)
        for width in [200.0, 400.0, 700.0] as [CGFloat] {
            let h = task.measuredHeight(forWidth: width)
            print("DIAG expandable collapsed h@\(width) = \(h)")
            XCTAssertGreaterThan(h, 15)
        }
    }
}
