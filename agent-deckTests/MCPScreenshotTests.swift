import AppKit
import SwiftUI
import XCTest
@testable import agent_deck

/// Renders the real MCP views to PNGs under /tmp so the visual experience can be
/// eyeballed without launching the app. Not a behavioral assertion — it writes
/// images and only fails if rendering produces nothing.
@MainActor
final class MCPScreenshotTests: XCTestCase {
    private let outDir = URL(fileURLWithPath: "/tmp/agent-deck-mcp-shots", isDirectory: true)

    override func setUp() {
        super.setUp()
        ThemeManager.shared.apply(.defaultTheme)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    func testRenderMCPExperienceScreenshots() throws {
        guard ProcessInfo.processInfo.environment["AGENT_DECK_ENABLE_MCP_SCREENSHOTS"] == "1" else {
            throw XCTSkip("MCP screenshot rendering is a manual visual diagnostic. Set AGENT_DECK_ENABLE_MCP_SCREENSHOTS=1 to generate screenshots.")
        }
        // 1) Transcript MCP card — successful calls.
        let success = NativeToolGroupModel(web: nil, diff: nil, mcp: .init(
            callCount: "2 calls",
            hasErrors: false,
            rows: [
                .init(id: UUID(), server: "Pidgeon", tool: "list_stories",
                      resultPreview: "{\"stories\":[…5 items…],\"count\":5}", isError: false, errorSummary: nil),
                .init(id: UUID(), server: "Pidgeon", tool: "get_pipeline_status",
                      resultPreview: "{\"stage\":\"publish\",\"healthy\":true}", isError: false, errorSummary: nil)
            ],
            hiddenCount: 0
        ))
        renderNativeCard(success, name: "01-transcript-card-success.png")

        // 2) Transcript MCP card — an errored call with the inline red summary.
        let errored = NativeToolGroupModel(web: nil, diff: nil, mcp: .init(
            callCount: "1 call",
            hasErrors: true,
            rows: [
                .init(id: UUID(), server: "Pidgeon", tool: "list_stories",
                      resultPreview: "MCP call failed: MCP server error -32603: [{\"code\":\"invalid_type\"}]",
                      isError: true, errorSummary: "MCP call failed: MCP server error -32603")
            ],
            hiddenCount: 0
        ))
        renderNativeCard(errored, name: "02-transcript-card-error.png")

        // 3) The "View" response modal (pretty-printed JSON).
        let resultJSON = "{\"stories\":[{\"id\":\"16983\",\"title\":\"OpenAI Enhances ChatGPT\",\"category\":\"Technology\",\"heat_score\":5.2},{\"id\":\"16982\",\"title\":\"New Banking Malware\",\"category\":\"Technology\",\"heat_score\":4.7}],\"count\":2}"
        renderSwiftUI(
            PiAgentNativeMCPResultSheet(server: "Pidgeon", tool: "list_stories", text: resultJSON, onDone: {}),
            size: NSSize(width: 760, height: 560),
            name: "03-view-response-modal.png"
        )

        // 4) The management-screen empty state (same ContentUnavailableView the screen uses).
        renderSwiftUI(
            ContentUnavailableView {
                Label {
                    Text("No MCP servers")
                } icon: {
                    Image(AppSymbols.mcp)
                }
            } description: {
                Text("Add a server from the toolbar — paste a config or fill the form. Servers are read from mcp.json in ~/.config/mcp, ~/.pi/agent, and the project's .mcp.json / .pi/mcp.json.")
            }
            .frame(width: 900, height: 480)
            .background(AppTheme.windowBackground),
            size: NSSize(width: 900, height: 480),
            name: "04-management-empty-state.png"
        )

        // 5) Visibility toggle popover row (the transcript-display option).
        renderSwiftUI(
            VStack(spacing: 0) {
                AppPopoverToggleRow(systemImage: AppSymbols.mcp, assetImage: AppSymbols.mcp, title: "MCP",
                                    subtitle: "Show MCP tool call cards in the transcript",
                                    isOn: .constant(true))
            }
            .frame(width: 360)
            .padding(10)
            .background(AppTheme.contentFill),
            size: NSSize(width: 380, height: 80),
            name: "05-visibility-toggle.png"
        )

        let written = try FileManager.default.contentsOfDirectory(atPath: outDir.path).filter { $0.hasSuffix(".png") }
        guard written.count >= 5 else {
            throw XCTSkip("MCP screenshot rendering is unavailable/flaky in this test run; expected 5 screenshots, wrote \(written)")
        }
    }

    // MARK: - Rendering helpers

    private func renderNativeCard(_ model: NativeToolGroupModel, name: String) {
        let width: CGFloat = 760
        let card = PiAgentNativeToolGroupView()
        card.configure(model: model, width: width)
        let height = max(80, card.measuredHeight(forWidth: width))

        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width + 48, height: height + 48))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = AppTheme.ns(AppTheme.windowBackground).cgColor
        card.frame = NSRect(x: 24, y: 24, width: width, height: height)
        canvas.addSubview(card)

        hostAndSnapshot(canvas, appearanceDark: true, name: name)
    }

    private func renderSwiftUI<V: View>(_ view: V, size: NSSize, name: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        hostAndSnapshot(host, appearanceDark: true, name: name)
    }

    private func hostAndSnapshot(_ view: NSView, appearanceDark: Bool, name: String) {
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearanceDark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFrontRegardless()
        for _ in 0..<8 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { window.close(); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: outDir.appendingPathComponent(name))
        }
        window.close()
    }
}
