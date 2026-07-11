import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import agent_deck

@MainActor
final class ComposerAndLoopLayoutTests: XCTestCase {
    private static var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 12
    }

    func testSubagentPickerRowSurvivesRepeatedWidthCyclesAndReturnsToStableWideGeometry() {
        let startedAt = Date()
        let agent = PiTestSupport.makeAgent(
            name: "implementation-specialist-with-a-deliberately-long-name",
            model: "openai/gpt-5.4-mini",
            thinking: "medium"
        )
        let host = NSHostingView(rootView: AnyView(PiAgentSubagentPickerRowLayoutFixture(agent: agent, width: 760)))
        let window = makeConstrainedWindow(host: host)
        Self.windows.append(window)
        func measureRow(at width: CGFloat) -> CGSize {
            host.rootView = AnyView(PiAgentSubagentPickerRowLayoutFixture(agent: agent, width: width))
            return resizeAndMeasure(window: window, host: host, width: width)
        }

        let wide = measureRow(at: 760)
        let narrow = measureRow(at: 420)
        XCTAssertGreaterThan(narrow.height, wide.height + 10, "The compact picker row must stack rather than compress its controls.")

        for width: CGFloat in [760, 420, 559, 560, 561, 420, 760, 560, 420, 760] {
            let geometry = measureRow(at: width)
            assertFinite(geometry)
            XCTAssertLessThanOrEqual(geometry.width, width + 0.5, "Picker content must not widen its host.")
        }

        let returnedWide = measureRow(at: 760)
        XCTAssertEqual(returnedWide.width, wide.width, accuracy: 0.5)
        XCTAssertEqual(returnedWide.height, wide.height, accuracy: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10, "The complete resize regression must remain live.")
    }

    func testLoopPickerRowUsesRealCompactFallback() {
        let content = Text("Artifact / Markdown output")
            .frame(width: 360, height: 28, alignment: .leading)
        let host = NSHostingView(rootView: AnyView(LoopPickerRow("Write Target") { content }.frame(width: 760, alignment: .leading)))
        let window = makeConstrainedWindow(host: host)
        Self.windows.append(window)

        let wide = resizeAndMeasure(window: window, host: host, width: 760)
        host.rootView = AnyView(LoopPickerRow("Write Target") { content }.frame(width: 420, alignment: .leading))
        let narrow = resizeAndMeasure(window: window, host: host, width: 420)
        XCTAssertGreaterThan(narrow.height, wide.height + 10, "The production Loop picker row must use its stacked fallback when its inline candidate does not fit.")
    }

    func testLoopLaunchSheetResizesAtSupportedWidthsAndUsesPickerRowFallback() throws {
        let startedAt = Date()
        let session = try PiTestSupport.makeParentSession()
        let agents = [PiTestSupport.makeAgent(name: "explorer"), PiTestSupport.makeAgent(name: "implementer")]
        let host = NSHostingView(rootView: AnyView(LoopLaunchSheet(
            session: session,
            activeRun: nil,
            initialDraft: LoopDraft(goal: "Validate adaptive loop-launch layout."),
            availableAgents: agents,
            projectAgents: agents,
            onCancel: {},
            onLaunch: { _ in }
        )))
        let window = makeConstrainedWindow(host: host)
        Self.windows.append(window)

        var firstPass: [CGFloat: CGSize] = [:]
        for width: CGFloat in [420, 560, 760] {
            let geometry = resizeAndMeasure(window: window, host: host, width: width, height: 800)
            firstPass[width] = geometry
            assertFinite(geometry)
            XCTAssertLessThanOrEqual(geometry.width, width + 0.5, "Loop content must not force the host wider at \(width)pt.")
        }

        for width: CGFloat in [760, 420, 560, 420, 760, 560, 420, 760] {
            let geometry = resizeAndMeasure(window: window, host: host, width: width, height: 800)
            assertFinite(geometry)
            XCTAssertLessThanOrEqual(geometry.width, width + 0.5)
        }

        for width: CGFloat in [420, 560, 760] {
            let returned = resizeAndMeasure(window: window, host: host, width: width, height: 800)
            let initial = try XCTUnwrap(firstPass[width])
            XCTAssertEqual(returned.width, initial.width, accuracy: 0.5)
            XCTAssertEqual(returned.height, initial.height, accuracy: 0.5)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10, "The complete Loop resize regression must remain live.")
    }

    private func makeConstrainedWindow(host: NSHostingView<AnyView>) -> NSWindow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 800))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.orderFrontRegardless()
        return window
    }

    private func resizeAndMeasure(window: NSWindow, host: NSHostingView<AnyView>, width: CGFloat, height: CGFloat = 400) -> CGSize {
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        window.contentView?.layoutSubtreeIfNeeded()
        return NSSize(width: host.bounds.width, height: host.fittingSize.height)
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            drainAndCloseWindows()
        }
        super.tearDown()
    }

    private static func drainAndCloseWindows() {
        // Detach hosted content while its window is still valid, then flush the
        // resulting invalidations before ordering out and closing the window.
        // Keeping the retired views alive through the final flush avoids an
        // AppKit display-cycle update targeting a deallocated hosting view.
        let retiredContent = windows.compactMap(\.contentView)
        windows.forEach { $0.contentView = NSView() }
        for _ in 0..<3 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        windows.forEach { $0.orderOut(nil) }
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        windows.forEach { $0.close() }
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        withExtendedLifetime(retiredContent) {}
        windows.removeAll()
    }

    private func assertFinite(_ size: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(size.width.isFinite, file: file, line: line)
        XCTAssertTrue(size.height.isFinite, file: file, line: line)
        XCTAssertGreaterThan(size.width, 0, file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
    }
}
