import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import agent_deck

/// Drives the card's production DEBUG stress binding after its first appearance,
/// matching the app journey's state transition instead of a static collapsed card.
private struct PickerCardStressLifecycleFixture: View {
    var viewModel: AppViewModel
    let session: PiAgentSessionRecord
    @State private var isExpanded = false

    var body: some View {
        PiAgentSessionSubagentPickerCard(
            viewModel: viewModel,
            session: session,
            stressExpansionRequest: isExpanded
        )
        .onAppear {
            DispatchQueue.main.async { isExpanded = true }
        }
    }
}

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
        let host = NSHostingView(rootView: AnyView(PiAgentSubagentPickerRowLayoutFixture(agent: agent, width: 1_024)))
        let window = makeConstrainedWindow(host: host)
        Self.windows.append(window)
        func measureRow(at width: CGFloat) -> CGSize {
            host.rootView = AnyView(PiAgentSubagentPickerRowLayoutFixture(agent: agent, width: width))
            return resizeAndMeasure(window: window, host: host, width: width)
        }

        let wide = measureRow(at: 1_024)
        let medium = measureRow(at: 800)
        let narrow = measureRow(at: 420)
        XCTAssertEqual(medium.height, wide.height, accuracy: 0.5, "Model and thinking controls must remain inline at ordinary composer widths.")
        XCTAssertGreaterThan(narrow.height, medium.height + 10, "Only genuinely compact rows should stack their controls.")

        // The production layout receives host width minus 16pt row padding.
        // Exercise both the 654pt compact/inline and 938pt medium/wide thresholds.
        for width: CGFloat in [1_024, 420, 669, 670, 671, 953, 954, 955, 420, 800, 1_024] {
            let geometry = measureRow(at: width)
            assertFinite(geometry)
            XCTAssertLessThanOrEqual(geometry.width, width + 0.5, "Picker content must not widen its host.")
        }

        let returnedWide = measureRow(at: 1_024)
        XCTAssertEqual(returnedWide.width, wide.width, accuracy: 0.5)
        XCTAssertEqual(returnedWide.height, wide.height, accuracy: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10, "The complete resize regression must remain live.")
    }

    func testExpandedPickerCatalogStaysBoundedInsideActiveSessionSplitViewDuringResizeCycles() {
        let startedAt = Date()
        let viewModel = AppViewModel()
        let session = try! PiTestSupport.makeParentSession()
        let host = NSHostingView(rootView: AnyView(realPickerCardSplitFixture(viewModel: viewModel, session: session, width: 760)))
        let window = makeConstrainedWindow(host: host)
        Self.windows.append(window)

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        for width: CGFloat in [760, 620, 980, 680, 1_120, 760, 620, 980] {
            host.rootView = AnyView(realPickerCardSplitFixture(viewModel: viewModel, session: session, width: width))
            let geometry = resizeAndMeasure(window: window, host: host, width: width, height: 820)
            assertFinite(geometry)
            XCTAssertEqual(geometry.width, width, accuracy: 0.5)
            XCTAssertLessThanOrEqual(
                host.fittingSize.height,
                820,
                "The expanded catalog must remain scroll-bounded rather than becoming the active split view's intrinsic minimum height."
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
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

    /// Hosts the production card (including its DEBUG stress catalog) in the
    /// same HSplitView/composer lifecycle as PiAgentScreen. This intentionally
    /// does not reconstruct picker rows, so it catches intrinsic-size feedback
    /// introduced by the card itself.
    private func realPickerCardSplitFixture(viewModel: AppViewModel, session: PiAgentSessionRecord, width: CGFloat) -> some View {
        HSplitView {
            Color.clear
                .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                PickerCardStressLifecycleFixture(viewModel: viewModel, session: session)
                Divider()
                Text("Composer")
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            }
            .padding(18)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: 820)
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
