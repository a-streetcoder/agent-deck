import AppKit
import XCTest
@testable import agent_deck

/// Headless performance regression gates for the transcript render hot paths.
///
/// These run in-process (offscreen `NSWindow`, no accessibility automation, no
/// visible window) so they can execute in the background while you keep using
/// the real app. They measure the REAL render/measure cost that drives scroll
/// hitches: markdown attribution per entry and the native transcript cell
/// configure → measuredHeight → layout pass that `NSTableView` runs on every
/// row vend and every height re-resolution.
///
/// They are the loop's comparable substrate: the maker runs
///   xcodebuild test -only-testing:agent-deckTests/PerfHeadlessBenchmarks
/// each round and compares the reported `average` times across rounds. The
/// ground-truth hitch *signatures* still come from the live `HangWatchdog`
/// backtraces in `/tmp/agentdeck-hang-*.txt`; these benchmarks are the fast,
/// deterministic regression gate that confirms a fix improved (or did not
/// regress) the measured render cost.
@MainActor
final class PerfHeadlessBenchmarks: XCTestCase {

    /// A representative long transcript: many mixed markdown blocks so the
    /// attribution builder does real work across headings, lists, code, quotes.
    private let largeTranscriptMarkdown: String = {
        let block = """
        # Section heading

        A paragraph with **bold**, *italic*, and `inline code`, plus a [link](https://example.com/path).

        - First list item with some longer descriptive text that wraps across a line.
        - Second list item mentioning tokens, models, and agent delegation.
        - Third list item with a trailing note.

        > A quoted block summarising a previous turn or assistant note.

        ```swift
        func render(_ items: [Item]) -> some View {
            List(items) { item in item.row() }
        }
        ```

        A second paragraph. Agent Deck runs Pi sessions through the installed `pi` CLI in JSONL
        RPC mode and renders the transcript as an NSTableView of NSHostingView-backed cells.

        ---
        """
        return (0..<60).map { _ in block }.joined(separator: "\n\n")
    }()

    /// Per-entry markdown attribution is the cost paid for every visible row on
    /// first render and on every content revision. Regression here scales
    /// directly into scroll/list jank.
    func testLargeTranscriptMarkdownAttributionPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = TranscriptAttributedStringBuilder.attributedString(for: largeTranscriptMarkdown)
        }
    }

    /// First-use sizing for immutable user messages. Each sample is unique so
    /// this measures the renderer-backed Markdown estimate rather than only the
    /// `MessageTextWidth` cache-hit path.
    func testStyledUserBubbleWidthMeasurementPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        var batch = 0
        measure(metrics: [XCTClockMetric()], options: options) {
            for index in 0..<100 {
                _ = PiAgentBubbleWidth.huggedUser(
                    text: "# Heading \(batch)-\(index) with **bold** and `inlineCode()`",
                    paneWidth: 900
                )
            }
            batch += 1
        }
    }

    private func runningPayload(task: String) -> NativeAgentBlockPayload {
        NativeAgentBlockPayload(
            agentName: "explorer",
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

    /// Lightweight custom-drawn diff preview: build, size, and rasterize 40
    /// lines. This keeps the former per-line stack/label hierarchy out of the
    /// fresh diff-row cost and provides a comparable regression metric.
    func testNativeDiffPreviewBatchRenderPerformance() {
        let lines = (0..<40).map { index in
            NativeDiffPreviewLine(
                gutter: index.isMultiple(of: 2) ? "+ \(index)" : "- \(index)",
                content: "let transcriptDiffPreviewLine\(index) = \"A deliberately long line that truncates at the preview edge\"",
                color: index.isMultiple(of: 2) ? .systemGreen : .systemRed,
                background: (index.isMultiple(of: 2) ? NSColor.systemGreen : .systemRed).withAlphaComponent(0.2)
            )
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric()], options: options) {
            let preview = NativeDiffPreviewView(lines: lines)
            preview.frame = NSRect(x: 0, y: 0, width: 800, height: preview.fittingSize.height)
            preview.layoutSubtreeIfNeeded()
            guard let image = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else {
                XCTFail("Could not create diff preview bitmap")
                return
            }
            preview.cacheDisplay(in: preview.bounds, to: image)
        }
    }

    /// Single native run card: configure → measure → layout. This is the exact
    /// flow `NSTableView` runs per visible row when it vends/recycles a cell and
    /// re-resolves its height (the documented cause of scroll hitches).
    func testNativeRunCardConfigureMeasureLayoutPerformance() {
        let rowWidth: CGFloat = 900
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 1200))
        window.contentView = host

        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTClockMetric()], options: options) {
            let card = PiAgentNativeSubagentRunCardView()
            card.configure(payload: runningPayload(task: sampleTask), width: rowWidth)
            host.addSubview(card)
            card.translatesAutoresizingMaskIntoConstraints = false
            let height = card.measuredHeight(forWidth: rowWidth)
            NSLayoutConstraint.deactivate(card.constraints)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: host.topAnchor),
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.widthAnchor.constraint(equalToConstant: rowWidth),
                card.heightAnchor.constraint(equalToConstant: height)
            ])
            host.layoutSubtreeIfNeeded()
            card.removeFromSuperview()
        }
    }

    /// Batch vend of 40 cards in one measured pass: approximates the per-frame
    /// cost the table pays while scrolling a long transcript with many run cards
    /// — the regime where a per-card regression compounds into sustained jank.
    func testNativeRunCardBatchVendPerformance() {
        let rowWidth: CGFloat = 900
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rowWidth, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 1200))
        window.contentView = host

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            var cards: [PiAgentNativeSubagentRunCardView] = []
            for index in 0..<40 {
                let card = PiAgentNativeSubagentRunCardView()
                card.configure(payload: runningPayload(task: sampleTask + " #\(index)"), width: rowWidth)
                let height = card.measuredHeight(forWidth: rowWidth)
                host.addSubview(card)
                card.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: host.topAnchor, constant: CGFloat(index)),
                    card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    card.widthAnchor.constraint(equalToConstant: rowWidth),
                    card.heightAnchor.constraint(equalToConstant: height)
                ])
                cards.append(card)
            }
            host.layoutSubtreeIfNeeded()
            for card in cards { card.removeFromSuperview() }
        }
    }
}
