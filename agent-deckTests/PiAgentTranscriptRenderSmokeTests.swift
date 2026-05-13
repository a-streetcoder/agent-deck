import AppKit
import SwiftUI
import XCTest
@testable import agent_deck

@MainActor
final class PiAgentTranscriptRenderSmokeTests: XCTestCase {
    func testSingleLineMarkdownBlockquoteDoesNotExpandVertically() throws {
        let source = """
        The `slkiser/opencode-quota` project supports OpenCode Go, but importantly its README says:

        > OpenCode Go — Quota source: Dashboard scraping

        It does **not** use the Go API key for quota. It requires:
        """
        let host = NSHostingView(rootView: MarkdownTextView(source: source).frame(width: 620, alignment: .leading))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 1_000)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        runMainLoop(iterations: 6, delay: 0.02)
        host.layoutSubtreeIfNeeded()

        let height = host.fittingSize.height
        XCTAssertLessThan(
            height,
            180,
            "A single-line Markdown blockquote should render near normal paragraph height, not with a large empty vertical gap. Actual height: \(height)."
        )
    }

    func testTranscriptStackFirstPaintIsNotBlankAfterInitialBottomScroll() throws {
        let host = NSHostingView(rootView: PiAgentTranscriptFirstPaintSmokeView(
            rows: (0..<80).map { "Transcript row \($0)" }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        runMainLoop(iterations: 10, delay: 0.03)
        host.layoutSubtreeIfNeeded()

        let paintedSamples = try nonWhiteSampleCount(in: host)
        XCTAssertGreaterThan(
            paintedSamples,
            100,
            "Transcript first paint rendered blank. This usually means the scroll stack did not materialize rows before manual scrolling."
        )
    }

    func testTranscriptStackDoesNotBlankAfterAppendingAndBottomScroll() throws {
        let host = NSHostingView(rootView: PiAgentTranscriptAppendSmokeView())
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        runMainLoop(iterations: 12, delay: 0.03)
        host.layoutSubtreeIfNeeded()

        let paintedSamples = try nonWhiteSampleCount(in: host)
        XCTAssertGreaterThan(
            paintedSamples,
            100,
            "Transcript rendered blank after appending a sent-message row and scrolling to bottom."
        )
    }

    private func runMainLoop(iterations: Int, delay: TimeInterval) {
        for _ in 0..<iterations {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(delay))
        }
    }

    private func nonWhiteSampleCount(in view: NSView) throws -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("Could not create a bitmap representation for the transcript smoke view.")
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let isOpaqueEnough = color.alphaComponent > 0.1
                let isNotWhite = color.redComponent < 0.92 || color.greenComponent < 0.92 || color.blueComponent < 0.92
                if isOpaqueEnough && isNotWhite {
                    count += 1
                }
            }
        }
        return count
    }
}

private struct PiAgentTranscriptFirstPaintSmokeView: View {
    let rows: [String]
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

    var body: some View {
        ScrollView {
            PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                transcriptRows(rows)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color.white)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .task {
            await Task.yield()
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 40_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
        }
    }
}

private struct PiAgentTranscriptAppendSmokeView: View {
    @State private var rows = (0..<80).map { "Transcript row \($0)" }
    @State private var scrollPosition = ScrollPosition(idType: String.self, edge: .bottom)

    var body: some View {
        ScrollView {
            PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                transcriptRows(rows)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color.white)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .task {
            await Task.yield()
            rows.append("Sent message row")
            await Task.yield()
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 40_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 120_000_000)
            scrollPosition.scrollTo(id: "bottom", anchor: .bottom)
        }
    }
}

@ViewBuilder
private func transcriptRows(_ rows: [String]) -> some View {
    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        Text(row)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
            .background(Color(red: 0.14, green: 0.30, blue: 0.56))
            .id("row-\(index)")
    }

    Color.clear
        .frame(height: 1)
        .id("bottom")
}
