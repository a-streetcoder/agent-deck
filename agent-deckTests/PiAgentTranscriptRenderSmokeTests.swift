import AppKit
import SwiftUI
import XCTest
@testable import agent_deck

@MainActor
final class PiAgentTranscriptRenderSmokeTests: XCTestCase {
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        Text(row)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(Color(red: 0.14, green: 0.30, blue: 0.56))
                            .id(index)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
            .background(Color.white)
            .task {
                await Task.yield()
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
