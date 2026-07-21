import AppKit
import SwiftUI
import WebKit
import os

private enum MarkdownSemanticStyler {
    private static let presentationIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
    private static let emphasis = 1
    private static let strong = 2
    private static let code = 4

    static var headingColor: NSColor {
        ThemeManager.shared.markdownHighlightingEnabled ? AppTheme.ns(AppTheme.markdownHeading) : .labelColor
    }

    static var listMarkerColor: NSColor {
        ThemeManager.shared.markdownHighlightingEnabled ? AppTheme.ns(AppTheme.markdownListMarker) : .secondaryLabelColor
    }

    static var listEnumerationColor: NSColor {
        ThemeManager.shared.markdownHighlightingEnabled ? AppTheme.ns(AppTheme.markdownListEnumeration) : .secondaryLabelColor
    }

    static var quoteColor: NSColor {
        ThemeManager.shared.markdownHighlightingEnabled ? AppTheme.ns(AppTheme.markdownQuote) : .secondaryLabelColor
    }

    static var quoteBarColor: NSColor {
        ThemeManager.shared.markdownHighlightingEnabled ? AppTheme.ns(AppTheme.markdownQuoteBar) : AppTheme.nsQuoteBarFill
    }

    static var codeBlockColor: NSColor {
        ThemeManager.shared.markdownHighlightingEnabled ? AppTheme.ns(AppTheme.markdownCode) : .labelColor
    }

    static var quoteFont: NSFont {
        let body = NSFont.preferredFont(forTextStyle: .body)
        guard ThemeManager.shared.markdownHighlightingEnabled else { return body }
        return NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
    }

    static func applyInlineColors(to attributed: NSMutableAttributedString) {
        guard ThemeManager.shared.markdownHighlightingEnabled, attributed.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributed.length)
        var updates: [(NSRange, NSColor, Bool)] = []
        attributed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let intent = (attributes[presentationIntentKey] as? NSNumber)?.intValue ?? 0
            if intent & code != 0 {
                updates.append((range, AppTheme.ns(AppTheme.markdownCode), false))
            } else if intent & strong != 0 {
                updates.append((range, AppTheme.ns(AppTheme.markdownStrong), false))
            } else if intent & emphasis != 0 {
                updates.append((range, AppTheme.ns(AppTheme.markdownEmphasis), false))
            } else if attributes[.link] != nil {
                updates.append((range, AppTheme.ns(AppTheme.markdownLinkText), true))
            }
        }
        for (range, color, underline) in updates {
            attributed.addAttribute(.foregroundColor, value: color, range: range)
            if underline {
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }
}

struct MarkdownDocumentView: View {
    let source: String
    var minimumHeight: CGFloat = 24
    @State private var contentHeight: CGFloat = 0
    @State private var resolvedSource: String?

    var body: some View {
        // The TextKit-based native renderer sizes in microseconds and spawns no
        // helper process. The WKWebView path, by contrast, launches a WebContent
        // process and can block the main thread for hundreds of ms whenever a
        // document appears. So only pay for the web view when the content uses
        // something the native renderer can't draw — images, tables, or raw HTML.
        // Plain markdown (skills, memory, most docs and issue bodies) goes native.
        if MarkdownDocumentView.requiresRichRendering(source) {
            MarkdownWebView(content: resolvedSource ?? source, contentHeight: $contentHeight)
                .frame(height: max(minimumHeight, contentHeight))
                .task(id: source) {
                    resolvedSource = nil
                    resolvedSource = await GitHubMarkdownAttachmentResolver.resolve(in: source)
                }
        } else {
            MarkdownTextView(source: source)
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        }
    }

    /// True when `source` uses markdown the native renderer (headings, paragraphs,
    /// lists, quotes, code) can't render — images, GFM tables, or raw HTML — and so
    /// must go through the web view to look right.
    static func requiresRichRendering(_ source: String) -> Bool {
        if source.contains("![") || source.contains("<img") || source.contains("<table") || source.contains("</") {
            return true
        }
        // GFM table: a header row immediately followed by a |---|---| separator row.
        return source.range(
            of: #"(?m)^\s*\|.*\|\s*\n\s*\|?[\s:|-]*-{2,}[\s:|-]*\|"#,
            options: .regularExpression
        ) != nil
    }
}

private enum GitHubMarkdownAttachmentResolver {
    nonisolated private static let logger = Logger(subsystem: "streetcoding.agent-deck", category: "MarkdownAttachments")
    private static let sourcePattern = #"src=\"(https://github\.com/user-attachments/assets/[^\"]+)\""#

    static func resolve(in markdown: String) async -> String {
        let urls = attachmentURLs(in: markdown)
        guard !urls.isEmpty else { return markdown }
#if DEBUG
        logger.info("Resolving \(urls.count, privacy: .public) GitHub markdown attachment(s).")
#endif
        guard let token = await githubToken() else {
#if DEBUG
            logger.error("Cannot resolve GitHub markdown attachments: `gh auth token --hostname github.com` returned no token.")
#endif
            return markdown
        }

        var resolved = markdown
        for urlString in urls {
#if DEBUG
            logger.info("Fetching GitHub markdown attachment: \(urlString, privacy: .public)")
#endif
            guard let dataURL = await dataURL(for: urlString, token: token) else {
#if DEBUG
                logger.error("Failed to resolve GitHub markdown attachment: \(urlString, privacy: .public)")
#endif
                continue
            }
#if DEBUG
            logger.info("Resolved GitHub markdown attachment to data URL (\(dataURL.count, privacy: .public) characters).")
#endif
            resolved = resolved.replacingOccurrences(of: urlString, with: dataURL)
        }
        return resolved
    }

    private static func attachmentURLs(in markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: sourcePattern) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        var urls: [String] = []
        for match in regex.matches(in: markdown, range: range) where match.numberOfRanges > 1 {
            guard let urlRange = Range(match.range(at: 1), in: markdown) else { continue }
            let value = String(markdown[urlRange])
            if !urls.contains(value) { urls.append(value) }
        }
        return urls
    }

    private static func githubToken() async -> String? {
        await Task.detached(priority: .utility) {
            guard let ghURL = ghExecutableURL() else {
#if DEBUG
                logger.error("Cannot resolve GitHub markdown attachments: `gh` executable was not found in the app environment.")
#endif
                return nil
            }
#if DEBUG
            logger.info("Using gh executable at \(ghURL.path, privacy: .public) for markdown attachment auth.")
#endif
            let process = Process()
            process.executableURL = ghURL
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
#if DEBUG
                    logger.error("gh auth token failed with exit code \(process.terminationStatus, privacy: .public).")
#endif
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
                if token?.isEmpty == false {
                    logger.info("Loaded GitHub token from gh CLI for markdown attachment fetch.")
                } else {
                    logger.error("gh auth token succeeded but stdout was empty.")
                }
#endif
                return token?.isEmpty == false ? token : nil
            } catch {
#if DEBUG
                logger.error("Failed to run gh auth token: \(error.localizedDescription, privacy: .public)")
#endif
                return nil
            }
        }.value
    }

    nonisolated private static func ghExecutableURL() -> URL? {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func dataURL(for urlString: String, token: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentDeck", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
#if DEBUG
                logger.error("Attachment fetch returned a non-HTTP response for \(urlString, privacy: .public).")
#endif
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
#if DEBUG
                logger.error("Attachment fetch failed for \(urlString, privacy: .public): HTTP \(http.statusCode, privacy: .public).")
#endif
                return nil
            }
            guard !data.isEmpty else {
#if DEBUG
                logger.error("Attachment fetch returned empty data for \(urlString, privacy: .public).")
#endif
                return nil
            }
            let mimeType = http.mimeType ?? "image/png"
#if DEBUG
            logger.info("Attachment fetch succeeded for \(urlString, privacy: .public): \(data.count, privacy: .public) bytes, mime \(mimeType, privacy: .public).")
#endif
            return "data:\(mimeType);base64,\(data.base64EncodedString())"
        } catch {
#if DEBUG
            logger.error("Attachment fetch threw for \(urlString, privacy: .public): \(error.localizedDescription, privacy: .public)")
#endif
            return nil
        }
    }
}

// Defers WKWebView construction by one runloop tick so selecting a detail item
// doesn't pay the markdown web-view spin-up cost on the same frame as the click.
struct LazyMarkdownCard<Trailing: View>: View {
    let title: String?
    let source: String
    var minimumHeight: CGFloat = 24
    @ViewBuilder let trailing: Trailing
    @State private var isMounted = false

    init(
        title: String? = nil,
        source: String,
        minimumHeight: CGFloat = 24,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.source = source
        self.minimumHeight = minimumHeight
        self.trailing = trailing()
    }

    var body: some View {
        AppCard(title: title, trailing: { trailing }) {
            if isMounted {
                MarkdownDocumentView(source: source, minimumHeight: minimumHeight)
            } else {
                Color.clear.frame(height: minimumHeight)
            }
        }
        .task(id: source) {
            isMounted = false
            await Task.yield()
            isMounted = true
        }
    }
}

// Wraps the existing native AppKit-based `NativeMarkdownTextContainer` (per-block
// `NSTextView`s in an `NSStackView`) for SwiftUI consumers. Measuring this view
// flows through TextKit's `NSLayoutManager` instead of a SwiftUI body iteration
// over `MarkdownBlock`s, so cells that contain markdown (transcript rows, memory
// previews, GitHub comments, repo-change panes, subagent task cards) become
// orders of magnitude cheaper to size — that was the dominant cost of session
// switching and per-token streaming flushes.
//
// Visual parity with the previous pure-SwiftUI implementation comes from
// `NativeMarkdownTextContainer.view(for:)`, which renders the same six block
// kinds with matching fonts, paddings, indents, code-block backgrounds, and
// quote-bar overlays.
struct MarkdownTextView: View {
    let source: String

    var body: some View {
        NativeMarkdownRepresentable(source: source)
    }
}

private struct NativeMarkdownRepresentable: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> NativeMarkdownTextContainer {
        let view = NativeMarkdownTextContainer()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        configure(view: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownTextContainer, context: Context) {
        configure(view: nsView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let applier = MarkdownSourceApplier()
    }

    // SwiftUI's sizing pass for an NSViewRepresentable goes through this method on
    // macOS 13+. Returning the TextKit-computed height for the proposed width is what
    // makes measurement microseconds-fast — `intrinsicContentSize` alone isn't honoured
    // by SwiftUI's hosting layer, so without this the parent ends up using a wildly
    // wrong placeholder height while the view resolves layout asynchronously.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownTextContainer, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 1 else { return nil }
        let height = nsView.measureHeight(forWidth: width)
        return CGSize(width: width, height: max(1, height))
    }

    static func dismantleNSView(_ nsView: NativeMarkdownTextContainer, coordinator: Coordinator) {
        coordinator.applier.cancel()
        nsView.dismantle()
    }

    private func configure(view: NativeMarkdownTextContainer, coordinator: Coordinator) {
        coordinator.applier.apply(source: source, to: view)
    }
}

private struct NativeMarkdownTextView: NSViewRepresentable {
    let document: CachedMarkdownDocument
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> NativeMarkdownTextContainer {
        let view = NativeMarkdownTextContainer()
        view.onHeightChange = { height in
            if abs(measuredHeight - height) > 0.5 {
                measuredHeight = height
            }
        }
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownTextContainer, context: Context) {
        nsView.onHeightChange = { height in
            if abs(measuredHeight - height) > 0.5 {
                measuredHeight = height
            }
        }
        nsView.configure(document: document)
    }

    static func dismantleNSView(_ nsView: NativeMarkdownTextContainer, coordinator: ()) {
        nsView.dismantle()
    }
}

/// Applies a markdown *source string* to a `NativeMarkdownTextContainer`,
/// owning the parse-policy state (sync fast path, off-main parse for large
/// growing blocks, and the in-flight de-dup) that used to live inside the
/// SwiftUI representable. Shared by the representable and the native cell so
/// both render markdown identically — and streaming flushes keep hitting the
/// container's in-place update rather than a full rebuild.
final class MarkdownSourceApplier {
    /// The balanced source whose parse is currently in flight (or last applied
    /// async). Guards against re-spawning a parse for the same text and against
    /// a stale async result overwriting a newer one.
    private var pendingSource: String?
    private var parseTask: Task<Void, Never>?

    /// Above this many characters an uncached source is parsed off the main
    /// thread. Below it, the line-based parse is cheap enough that a synchronous
    /// pass costs less than a frame — and staying synchronous keeps the height
    /// measurement (and the transcript's anti-wobble machinery) exact.
    private static let asyncParseThreshold = 4_000

    deinit { parseTask?.cancel() }

    func cancel() { parseTask?.cancel() }

    func apply(source: String, to view: NativeMarkdownTextContainer) {
        let displaySource = StreamingMarkdownBalancer.balance(source)

        // Synchronous fast paths — no wobble, height stays exact this frame:
        //  • cache hit (re-render, scroll-back, unchanged text), or
        //  • small/medium source where a main-thread parse costs < one frame.
        if let cached = MarkdownRenderCache.cachedDocument(for: displaySource) {
            parseTask?.cancel()
            pendingSource = nil
            view.configure(document: cached)
            return
        }
        if displaySource.count <= Self.asyncParseThreshold {
            parseTask?.cancel()
            pendingSource = nil
            view.configure(document: MarkdownRenderCache.document(for: displaySource))
            return
        }

        // Large, uncached source: keep first paint cheap and parse off-main.
        // If the view already has content (streaming growth), it stays on screen;
        // if this is first appearance, the container remains empty until the
        // cached document is applied below. This avoids a main-thread markdown
        // rebuild/measurement hitch when a large transcript row first appears.
        if pendingSource == displaySource { return }
        pendingSource = displaySource
        parseTask?.cancel()
        parseTask = Task { [weak self, weak view] in
            let document = await Task.detached(priority: .userInitiated) {
                MarkdownRenderCache.parseDocument(for: displaySource)
            }.value
            guard !Task.isCancelled, let self, let view else { return }
            MarkdownRenderCache.store(document, for: displaySource)
            guard self.pendingSource == displaySource else { return }
            self.pendingSource = nil
            view.configure(document: document)
        }
    }
}

final class NativeMarkdownTextContainer: NSView {
    private let stackView = NSStackView()
    private var lastDocument: CachedMarkdownDocument?
    private var lastStyleRevision = -1
#if DEBUG
    /// Summary of the most recent `configure(document:)` on ANY container, read
    /// synchronously by the cell-vend profiler right after it triggers a build so
    /// the hitch line can say WHY the row was costly (a full teardown+rebuild of N
    /// block views vs a cheap in-place reconcile). MainActor + synchronous, so the
    /// value belongs to the container the vend just configured. DEBUG attribution
    /// only — never read for behaviour, compiled out of release.
    static var lastConfigureWasRebuild = false
    static var lastConfigureBlockCount = 0
    /// Bumped each time a real markdown (re)build runs. The cell-vend profiler
    /// compares it before/after `spec.configure` to know whether the cost it just
    /// timed was a markdown build at all (vs a non-markdown row like a tool group),
    /// so it never mislabels with a stale rebuild/block-count from an earlier vend.
    static var configureSeq = 0
    /// Instance-level mirror for unit tests: the static `lastConfigureWasRebuild`
    /// is shared across every container in the process, so observing it in tests
    /// that share the app host is unreliable. This property belongs to one
    /// container and is set only by that container's `configure` calls.
    var lastConfigureWasRebuildInstance = false
#endif
    /// Whether a document has ever been applied. Large uncached first paint can
    /// intentionally leave this false while `MarkdownSourceApplier` parses off-main.
    var hasDocument: Bool { lastDocument != nil }
    private var widthConstraint: NSLayoutConstraint?
    private var pendingHeightMeasurement = false
    private var isDismantled = false
    private var lastMeasuredWidth: CGFloat = 0
    private var lastMeasuredHeight: CGFloat = 0
    /// Memoized result of `measureHeight(forWidth:)`, keyed by width. Invalidated
    /// only when the height can actually change: the document changes (wiped in
    /// `configure`) or the width changes (the cache key carries width). A late
    /// per-block intrinsic-size resolution after a rebuild is handled by the
    /// settle loop (`settleMeasurementsRemaining`), not by dropping the cache.
    /// It deliberately does NOT drop every runloop turn, and is NOT dropped in
    /// `layout()` — a stable visible row keeps its measurement across scroll
    /// frames instead of re-running a full TextKit layout on every `sizeThatFits`
    /// probe (that per-frame re-measure was the transcript's 30fps scroll cap).
    private var heightCache: (width: CGFloat, height: CGFloat)?
    /// The width at which every block was last fully laid out (invalidate-all +
    /// double pass). When a later measure comes in at this same width, the blocks are
    /// already wrapped correctly and only the block(s) that changed need re-measuring
    /// — so the streaming re-measure can take a single cheap pass. Reset on rebuild()
    /// (fresh views need the full pass once) so it only fast-paths incremental edits.
    private var lastFullLayoutWidth: CGFloat?
    /// Budget of forced fresh re-measures after a content change, to self-heal a
    /// too-short first measure (per-block TextKit views can report a stale
    /// intrinsic size on the first pass after a rebuild). The debounced
    /// `measureHeight()` decrements this and re-measures fresh until the height
    /// stabilizes, then it returns to 0 — so steady scroll (no content change)
    /// always hits the cache and never forces a TextKit layout.
    private var settleMeasurementsRemaining = 0
    private static let settleMeasurementBudget = 4
    var onHeightChange: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupStackView()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupStackView() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.distribution = .gravityAreas
        stackView.spacing = 8
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    fileprivate func configure(document: CachedMarkdownDocument) {
        isDismantled = false
        let styleRevision = ThemeManager.shared.revision
        let styleChanged = styleRevision != lastStyleRevision
        guard document != lastDocument || styleChanged else {
            scheduleHeightMeasurement()
            return
        }
        let previous = lastDocument
        lastDocument = document
        lastStyleRevision = styleRevision
        // The document changed (the unchanged case returned at the guard above),
        // so any cached height is now stale. `measureHeight(forWidth:)` repopulates,
        // and the settle loop re-measures fresh for a few runloops until the new
        // height stabilizes (covers a too-short first measure after a rebuild).
        heightCache = nil
        settleMeasurementsRemaining = Self.settleMeasurementBudget
        // Streaming hot path: when the frontmatter is unchanged and our block views
        // still line up with the previous document, reconcile in place — reuse every
        // same-shape block view, restyle only the blocks whose text changed, and
        // append/drop the churning tail (the StreamingMarkdownBalancer strips and
        // re-adds half-typed trailing markers every flush, which `reconcileBlocks`
        // absorbs as a trailing add/drop). Crucially this does NOT reset
        // `lastFullLayoutWidth`, so the per-tick `measureHeight` stays on the cheap
        // single pass: a full `rebuild` resets it and forces the cold double pass
        // every tick, which both costs more AND can report a slightly different
        // height each pass — the visible streaming "wobble".
        let viewOffset = document.frontmatter == nil ? 0 : 1
        if !styleChanged, let previous,
           previous.frontmatter == document.frontmatter {
            // Reconcile in place even if the arranged-subview count has drifted
            // from `previous.blocks.count`. `reconcileBlocks` handles insert/remove
            // to restore the invariant, and keeping `lastFullLayoutWidth` intact
            // avoids the cold double-pass that produces visible streaming wobble.
            // A view-count drift is logged as a warning so we can still hunt the
            // root cause, but it no longer forces a full rebuild.
            let expectedViews = viewOffset + previous.blocks.count
            let viewCountMismatch = stackView.arrangedSubviews.count != expectedViews
#if DEBUG
            if viewCountMismatch {
                Self.logIncrementalWarning("reconcile despite viewCount:\(stackView.arrangedSubviews.count)!=\(expectedViews)")
                TranscriptStreamWobbleProbe.recordDocPath(.reconcile, bailReason: "viewCount:\(stackView.arrangedSubviews.count)!=\(expectedViews)")
            } else {
                TranscriptStreamWobbleProbe.recordDocPath(.reconcile)
            }
            Self.lastConfigureWasRebuild = false
            self.lastConfigureWasRebuildInstance = false
            Self.lastConfigureBlockCount = document.blocks.count
            Self.configureSeq &+= 1
#endif
            reconcileBlocks(old: previous.blocks, new: document.blocks, frontOffset: viewOffset)
            scheduleHeightMeasurement()
            return
        }
        // Only the genuinely unexpected case is worth a diagnostic: we had a
        // previous document at the same style revision (so a reconcile *should*
        // have been possible) but the frontmatter didn't match. A `styleChanged`
        // rebuild (theme/highlight toggle) and a first build (fresh recycled
        // container) are expected and stay silent.
        if !styleChanged, previous != nil {
            Self.logIncrementalBail("frontmatter")
        }
#if DEBUG
        if !styleChanged, previous != nil {
            // A bail-to-rebuild mid-stream resets lastFullLayoutWidth → forces the
            // cold double-pass for the next measures. This is the measure-side
            // wobble's root trigger, so name it on the wobble line too.
            TranscriptStreamWobbleProbe.recordDocPath(.rebuild, bailReason: "frontmatter")
        } else if styleChanged {
            TranscriptStreamWobbleProbe.recordDocPath(.styleRebuild)
        } else {
            TranscriptStreamWobbleProbe.recordDocPath(.firstBuild)
        }
        Self.lastConfigureWasRebuild = true
        self.lastConfigureWasRebuildInstance = true
        Self.lastConfigureBlockCount = document.blocks.count
        Self.configureSeq &+= 1
#endif
        rebuild(from: styleChanged ? nil : previous, to: document)
        scheduleHeightMeasurement()
    }

#if DEBUG
    private static let incrementalLog = Logger(subsystem: "streetcoding.agent-deck", category: "MarkdownIncremental")
    private static func logIncrementalBail(_ reason: String) {
        incrementalLog.error("markdown rebuild (incremental bail): \(reason, privacy: .public)")
    }
    private static func logIncrementalWarning(_ reason: String) {
        incrementalLog.warning("markdown reconcile (view-count drift): \(reason, privacy: .public)")
    }
#else
    private static func logIncrementalBail(_ reason: String) {}
    private static func logIncrementalWarning(_ reason: String) {}
#endif

    // Two block kinds have the "same shape" if their layout chrome (paddedBlock, listRow
    // with marker, quote bar, code container) is identical and only the inner text
    // changed. Heading level / list indent / numbered number all affect chrome, so a
    // change in any of them forces a rebuild.
    private static func sameKindShape(_ a: MarkdownBlock.Kind, _ b: MarkdownBlock.Kind) -> Bool {
        switch (a, b) {
        case (.heading(let levelA, _), .heading(let levelB, _)):
            return levelA == levelB
        case (.paragraph, .paragraph):
            return true
        case (.bullet(_, let indentA), .bullet(_, let indentB)):
            return indentA == indentB
        case (.numbered(let numberA, _, let indentA), .numbered(let numberB, _, let indentB)):
            return numberA == numberB && indentA == indentB
        case (.quote, .quote):
            return true
        case (.code, .code):
            return true
        case (.table, .table):
            // A table is a multi-view grid, not a single restyleable text view, so
            // never reuse in place — an unchanged table is skipped by the identity
            // check in `reconcileBlocks`; a changed one swaps in a fresh grid.
            return false
        default:
            return false
        }
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    private static func updateTextView(_ textView: NSTextView, with kind: MarkdownBlock.Kind) {
        let attr: NSAttributedString
        switch kind {
        case let .bullet(text, indentLevel):
            // List items carry their marker + hanging indent inside the same text
            // view, so rebuild the full line (not just the body) on reuse/streaming.
            attr = listAttributedString(marker: bulletMarker(for: indentLevel), text: text, indentLevel: indentLevel, markerWidth: 18)
        case let .numbered(number, text, indentLevel):
            attr = listAttributedString(
                marker: "\(number).",
                text: text,
                indentLevel: indentLevel,
                markerWidth: 22,
                markerColor: MarkdownSemanticStyler.listEnumerationColor
            )
        default:
            let (font, color, parseInline) = textStyling(for: kind)
            attr = attributedString(bodyText(from: kind), font: font, color: color, parseInlineMarkdown: parseInline)
        }
        let decorated = NSMutableAttributedString(attributedString: attr)
        if case .heading(level: 1, _) = kind,
           ThemeManager.shared.markdownHighlightingEnabled,
           decorated.length > 0 {
            decorated.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: decorated.length)
            )
        }
        if let autoSizing = textView as? AutoSizingMarkdownTextView {
            autoSizing.applyContent(decorated)
        } else if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(decorated)
            storage.endEditing()
            textView.invalidateIntrinsicContentSize()
        }
    }

    private static func bodyText(from kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case let .heading(_, text), let .paragraph(text), let .quote(text), let .code(text):
            return text
        case let .bullet(text, _):
            return text
        case let .numbered(_, text, _):
            return text
        case .table:
            // Tables never reuse via the text-view restyle path (see sameKindShape),
            // so this is unreachable; kept for switch exhaustiveness.
            return ""
        }
    }

    private static func textStyling(for kind: MarkdownBlock.Kind) -> (font: NSFont, color: NSColor, parseInlineMarkdown: Bool) {
        switch kind {
        case let .heading(level, _):
            if level <= 1 {
                let title3 = NSFont.preferredFont(forTextStyle: .title3)
                return (NSFontManager.shared.convert(title3, toHaveTrait: .boldFontMask), MarkdownSemanticStyler.headingColor, true)
            } else {
                return (NSFont.preferredFont(forTextStyle: .headline), MarkdownSemanticStyler.headingColor, true)
            }
        case .paragraph, .bullet, .numbered:
            return (NSFont.preferredFont(forTextStyle: .body), .labelColor, true)
        case .quote:
            return (MarkdownSemanticStyler.quoteFont, MarkdownSemanticStyler.quoteColor, true)
        case .code:
            // Keep in sync with the code font in `view(for:)` — one style below body.
            let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
            return (.monospacedSystemFont(ofSize: size, weight: .regular), MarkdownSemanticStyler.codeBlockColor, false)
        case .table:
            // Unreachable (tables rebuild rather than restyle); kept for exhaustiveness.
            return (NSFont.preferredFont(forTextStyle: .body), .labelColor, true)
        }
    }

    func dismantle() {
        isDismantled = true
        onHeightChange = nil
    }

    override func layout() {
        super.layout()
        // NOTE: do NOT invalidate `heightCache` here. `layout()` runs inside the
        // cell's scroll layout pass, and SwiftUI calls `sizeThatFits` several
        // times per pass; wiping the cache mid-pass forces repeated full TextKit
        // layouts every frame (the scroll cap). The cache is invalidated only on
        // a real content change (`configure`) or width change (cache key) — see
        // `heightCache` and the settle loop in `measureHeight()`.
        scheduleHeightMeasurement()
    }

    // SwiftUI sizes this view by calling `NSViewRepresentable.sizeThatFits(...)` which
    // delegates here. AppKit-only callers (e.g. Auto Layout consumers) get the same
    // answer via `intrinsicContentSize`. Computing it through the stack of per-block
    // `AutoSizingMarkdownTextView`s (each backed by TextKit's `NSLayoutManager`) is
    // what makes measurement microseconds-fast — the slow SwiftUI `MarkdownTextView`
    // body iteration is gone.
    func measureHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        // SwiftUI's layout probes call `sizeThatFits` — and thus this — several
        // times in immediate succession at the same width. Serve those repeats
        // from the runloop-scoped cache; a fresh pass (after layout settles, or
        // a scroll-back) finds the cache cleared and re-measures.
        if let heightCache, abs(heightCache.width - width) < 0.5 {
#if DEBUG
            TranscriptStreamWobbleProbe.recordMeasure(path: .cacheHit, width: width, height: heightCache.height)
#endif
            return heightCache.height
        }
        configureWidthConstraint(to: width)
        if let lastFullLayoutWidth, abs(lastFullLayoutWidth - width) < 0.5 {
            // Streaming hot path: width is unchanged since the last full layout, so
            // every block is already wrapped correctly. A block whose text grew
            // self-invalidated its intrinsic (updateTextView → invalidate), and any
            // freshly appended block starts dirty — a single pass re-measures just
            // those and leaves the rest cached, instead of re-laying-out every block.
            stackView.layoutSubtreeIfNeeded()
            let height = ceil(stackView.fittingSize.height)
            heightCache = (width, height)
#if DEBUG
            TranscriptStreamWobbleProbe.recordMeasure(path: .cheapSingle, width: width, height: height)
#endif
            return height
        }
        // Width changed (or first measure after a rebuild). A text view's
        // intrinsicContentSize wraps at max(bounds.width, containerSize.width): on the
        // FIRST pass bounds.width may still be stale-wide, so the text wraps to too few
        // lines and the measured height comes back short — which then gets cached and
        // leaves the last line crowding the card's bottom edge. The first pass assigns
        // each block its real width; we then invalidate the per-block intrinsics and
        // lay out again so they re-wrap at that width before we read the fitting size.
        stackView.layoutSubtreeIfNeeded()
#if DEBUG
        let pass1 = ceil(stackView.fittingSize.height)
#endif
        invalidateBlockIntrinsics(in: stackView)
        stackView.layoutSubtreeIfNeeded()
        let height = ceil(stackView.fittingSize.height)
        heightCache = (width, height)
        lastFullLayoutWidth = width
#if DEBUG
        // pass1 vs height (pass2) diverging means the measure disagreed with itself
        // within one tick — the purest measure-side wobble fingerprint.
        TranscriptStreamWobbleProbe.recordMeasure(path: .coldDouble, width: width, height: height,
                                                  coldPass1: pass1, coldPass2: height)
#endif
        return height
    }

    /// Recursively invalidate every `AutoSizingMarkdownTextView`'s cached
    /// intrinsic size so the next layout pass re-measures it at its now-correct
    /// width (text blocks can be nested inside list/quote row stacks).
    private func invalidateBlockIntrinsics(in view: NSView) {
        for sub in view.subviews {
            if let tv = sub as? AutoSizingMarkdownTextView {
                tv.invalidateIntrinsicContentSize()
            } else {
                invalidateBlockIntrinsics(in: sub)
            }
        }
    }

    /// The true laid-out height of the rendered block stack at its current width
    /// (re-measured, not cached) — used by callers to detect when the row was
    /// sized shorter than the content actually needs (the bottom-crop bug).
    var renderedContentHeight: CGFloat {
        invalidateBlockIntrinsics(in: stackView)
        stackView.layoutSubtreeIfNeeded()
        return ceil(stackView.fittingSize.height)
    }

    // Must be side-effect-free: AppKit calls this during the window's update-constraints
    // pass, and `measureHeight` mutates an active layout constraint, which re-enters the
    // constraint engine and loops the window's update-constraints pass until AppKit bails.
    // SwiftUI sizes us via `sizeThatFits` → `measureHeight` directly (NSViewRepresentable
    // doesn't honour intrinsicContentSize), so AppKit's intrinsic path can defer.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private func configureWidthConstraint(to width: CGFloat) {
        if let widthConstraint {
            if abs(widthConstraint.constant - width) > 0.5 {
                widthConstraint.constant = width
            }
        } else {
            widthConstraint = makeWidthConstraint(width)
        }
    }

    // The stack is already pinned to both container edges, so its width is fully
    // determined by the host frame once the view is laid out. This explicit width
    // constraint exists only to drive `fittingSize` during SwiftUI's measurement
    // pass (when the container has no resolved width yet). Keeping it below
    // `.required` lets it yield to the edge pins instead of conflicting with them
    // when SwiftUI's fractional proposal differs from the pixel-rounded frame.
    private func makeWidthConstraint(_ width: CGFloat) -> NSLayoutConstraint {
        let constraint = stackView.widthAnchor.constraint(equalToConstant: width)
        constraint.priority = .required - 1
        constraint.isActive = true
        return constraint
    }

    /// Apply a new document after the incremental (streaming-append) path bailed.
    /// When the frontmatter is unchanged, reconcile the existing block views in
    /// place — reusing a view (and only restyling its text) wherever the block at
    /// that position kept the same kind shape — so a recycled cell scrolling onto
    /// unrelated content reuses its NSTextViews instead of tearing the whole stack
    /// down and rebuilding every block from scratch (the dominant scroll cost).
    /// Frontmatter presence/content changes are rare, so those fall back to a full
    /// teardown for simplicity.
    private func rebuild(from previous: CachedMarkdownDocument?, to document: CachedMarkdownDocument) {
        // Fresh/replaced views need the full invalidate-all + double pass on their
        // first measure (they can report a stale-wide intrinsic), so drop the
        // fast-path marker — only incremental edits at an unchanged width skip it.
        lastFullLayoutWidth = nil

        guard let previous, previous.frontmatter == document.frontmatter else {
            fullRebuild(document: document)
            return
        }
        reconcileBlocks(old: previous.blocks, new: document.blocks,
                        frontOffset: document.frontmatter == nil ? 0 : 1)
    }

    /// Teardown + fresh build of every block. Used for the first build and when
    /// the frontmatter changed.
    private func fullRebuild(document: CachedMarkdownDocument) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        stackView.spacing = document.frontmatter == nil ? 8 : 12

        if let frontmatter = document.frontmatter, !frontmatter.isEmpty {
            let frontmatterView = Self.paddedTextBlock(
                frontmatter,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                color: .secondaryLabelColor,
                fill: AppTheme.nsCodeBlockFill,
                cornerRadius: AppTheme.Chat.chipCornerRadius,
                padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            )
            stackView.addArrangedSubview(frontmatterView)
        }

        for block in document.blocks {
            stackView.addArrangedSubview(Self.view(for: block))
        }
    }

    /// Reconcile the arranged block views (after the optional frontmatter view) to
    /// `new`, reusing position-matched views of the same kind shape. The invariant
    /// (held by every code path here) is that `arrangedSubviews[frontOffset + i]`
    /// renders `old[i]`, so we can compare kinds index-for-index.
    private func reconcileBlocks(old: [MarkdownBlock], new: [MarkdownBlock], frontOffset: Int) {
        for i in 0..<new.count {
            let slot = frontOffset + i
            // A byte-identical block keeps its existing view untouched regardless of
            // shape — covers blocks (like tables) that aren't restyled in place but
            // shouldn't be rebuilt every reconcile while other blocks stream.
            if i < old.count, slot < stackView.arrangedSubviews.count, old[i] == new[i] {
                continue
            }
            let canReuse = i < old.count
                && slot < stackView.arrangedSubviews.count
                && Self.sameKindShape(old[i].kind, new[i].kind)
            if canReuse {
                // Same chrome — leave an identical block untouched, otherwise
                // restyle the inner text view in place. If (unexpectedly) there's
                // no text view to restyle, fall through to a fresh replacement.
                if old[i] == new[i] { continue }
                if let textView = Self.firstTextView(in: stackView.arrangedSubviews[slot]) {
                    Self.updateTextView(textView, with: new[i].kind)
                    continue
                }
            }
            // Kind shape differs (or no view here) — swap in a fresh view.
            let fresh = Self.view(for: new[i])
            if slot < stackView.arrangedSubviews.count {
                let existing = stackView.arrangedSubviews[slot]
                stackView.insertArrangedSubview(fresh, at: slot)
                existing.removeFromSuperview()
            } else {
                stackView.addArrangedSubview(fresh)
            }
        }
        // Drop any blocks the new document no longer has.
        while stackView.arrangedSubviews.count > frontOffset + new.count {
            stackView.arrangedSubviews.last?.removeFromSuperview()
        }
    }

    private func scheduleHeightMeasurement() {
        guard !isDismantled else { return }
        // The debounced measure → `onHeightChange` callback path is only used by
        // the binding-based representable (`NativeMarkdownTextView`). The
        // transcript (`MarkdownTextView`/`NativeMarkdownRepresentable`) sizes via
        // `sizeThatFits` and reports height through the cell's intrinsic size, so
        // it has no `onHeightChange` — running this here just re-measures TextKit
        // on every `layout()` during scroll AND thrashes `heightCache` (it
        // measures at `bounds.width`, while `sizeThatFits` uses the proposed
        // width). Skip entirely when nobody consumes the result.
        guard onHeightChange != nil else { return }
        guard !pendingHeightMeasurement else { return }
        pendingHeightMeasurement = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingHeightMeasurement = false
            guard !self.isDismantled else { return }
            self.measureHeight()
        }
    }

    private func measureHeight() {
        guard !isDismantled else { return }
        guard bounds.width > 0.5 else { return }
        let width = bounds.width.rounded(.up)
        if let widthConstraint {
            widthConstraint.constant = width
        } else {
            widthConstraint = makeWidthConstraint(width)
        }

        guard abs(lastMeasuredWidth - width) > 0.5 || lastDocument != nil else { return }
        // While settling after a content change, force a fresh measurement so a
        // too-short first measure self-corrects; otherwise route through the
        // memoized path so steady scroll is a cache hit (no TextKit layout).
        if settleMeasurementsRemaining > 0 {
            heightCache = nil
        }
        let height = measureHeight(forWidth: width)
        let changed = abs(lastMeasuredHeight - height) > 0.5 || abs(lastMeasuredWidth - width) > 0.5
        if settleMeasurementsRemaining > 0 {
            settleMeasurementsRemaining -= 1
            // Keep re-measuring while the height is still moving and we have
            // budget; the moment it stabilizes, stop forcing fresh measures so
            // scroll returns to pure cache hits.
            if changed && settleMeasurementsRemaining > 0 {
                scheduleHeightMeasurement()
            } else {
                settleMeasurementsRemaining = 0
            }
        }
        guard changed else { return }
        lastMeasuredWidth = width
        lastMeasuredHeight = height
        onHeightChange?(max(1, height))
    }

    private static func view(for block: MarkdownBlock) -> NSView {
        switch block.kind {
        case let .heading(level, text):
            // Match SwiftUI `.title3.weight(.bold)` for level<=1 and `.headline.weight(.semibold)`
            // for level>=2. `NSFont.preferredFont(forTextStyle:)` returns the dynamic-type
            // size, so the headings track the user's text-size setting just like SwiftUI.
            let baseFont: NSFont
            if level <= 1 {
                let title3 = NSFont.preferredFont(forTextStyle: .title3)
                baseFont = NSFontManager.shared.convert(title3, toHaveTrait: .boldFontMask)
            } else {
                // `.headline` on macOS is semibold by default — same as SwiftUI's `.headline.weight(.semibold)`.
                baseFont = NSFont.preferredFont(forTextStyle: .headline)
            }
            let view = textView(text, font: baseFont, color: MarkdownSemanticStyler.headingColor)
            if level == 1, ThemeManager.shared.markdownHighlightingEnabled, let storage = view.textStorage {
                storage.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: 0, length: storage.length)
                )
            }
            view.setContentHuggingPriority(.required, for: .vertical)
            return paddedBlock(view, padding: NSEdgeInsets(top: level <= 2 ? 4 : 2, left: 0, bottom: 0, right: 0))
        case let .paragraph(text):
            return textView(text, font: NSFont.preferredFont(forTextStyle: .body), color: .labelColor)
        case let .bullet(text, indentLevel):
            return listRow(marker: bulletMarker(for: indentLevel), text: text, indentLevel: indentLevel, markerWidth: 18)
        case let .numbered(number, text, indentLevel):
            return listRow(
                marker: "\(number).",
                text: text,
                indentLevel: indentLevel,
                markerWidth: 22,
                markerColor: MarkdownSemanticStyler.listEnumerationColor
            )
        case let .quote(text):
            return quoteBlock(text)
        case let .code(text):
            return paddedTextBlock(
                text,
                // Code renders one text style below body — the GitHub/Notion
                // convention. Reads as code and fits more per line (fewer wraps).
                font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular),
                color: MarkdownSemanticStyler.codeBlockColor,
                fill: AppTheme.nsCodeBlockFill,
                border: AppTheme.nsCodeBlockBorder,
                cornerRadius: AppTheme.Chat.subCardCornerRadius,
                padding: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            )
        case let .table(table):
            return tableBlock(table)
        }
    }

    /// Native GFM table: builds each cell's attributed string (header cells bold,
    /// inline markdown parsed) and hands them to `MarkdownTableView`, which lays the
    /// grid out by hand with equal columns and self-measured row heights. An
    /// `NSGridView` of auto-sizing text views does NOT constrain column widths here,
    /// so cells stacked into one tall column — manual layout
    /// is what actually wraps cells into proper columns.
    private static func tableBlock(_ table: MarkdownTable) -> NSView {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let headerFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)

        func cellAttr(_ text: String, isHeader: Bool, alignment: MarkdownTableAlignment) -> NSAttributedString {
            // Header cells are bold and carry the theme's heading tint (consistent
            // with the rest of the markdown highlighting); body cells use normal text.
            let base = attributedString(
                text,
                font: isHeader ? headerFont : bodyFont,
                color: isHeader ? MarkdownSemanticStyler.headingColor : .labelColor,
                parseInlineMarkdown: true
            )
            let mutable = NSMutableAttributedString(attributedString: base)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 2
            paragraph.alignment = alignment == .center ? .center : (alignment == .trailing ? .right : .natural)
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))
            return mutable
        }

        let columnCount = max(1, table.columnCount)
        let header = (0..<columnCount).map { column in
            cellAttr(column < table.header.count ? table.header[column] : "", isHeader: true, alignment: table.alignment(column))
        }
        let rows = table.rows.map { row in
            (0..<columnCount).map { column in
                cellAttr(column < row.count ? row[column] : "", isHeader: false, alignment: table.alignment(column))
            }
        }
        let view = MarkdownTableView()
        view.configure(headerCells: header, bodyRows: rows)
        return view
    }

    // Gap between the marker column and the text column, in points.
    private static let listMarkerTextGap: CGFloat = 8
    // Each nesting level shifts the whole item right by this much.
    private static let listIndentPerLevel: CGFloat = 22

    private static func listRow(
        marker: String,
        text: String,
        indentLevel: Int,
        markerWidth: CGFloat,
        markerColor: NSColor = MarkdownSemanticStyler.listMarkerColor
    ) -> NSView {
        // A list item is a SINGLE text view: `marker` + tab + body in one attributed
        // string with a hanging-indent paragraph style. Because the marker and the
        // text are one text run on one line, they share a baseline structurally —
        // there is no separate marker view to misalign. Wrapped lines align under the
        // text (headIndent), not under the marker. This is the standard TextKit list
        // layout and removes the baseline/constraint guesswork entirely.
        let tv = textView("", font: NSFont.preferredFont(forTextStyle: .body), color: .labelColor)
        tv.applyContent(
            listAttributedString(
                marker: marker,
                text: text,
                indentLevel: indentLevel,
                markerWidth: markerWidth,
                markerColor: markerColor
            )
        )
        return tv
    }

    /// Build `marker` + tab + body as one attributed string with a hanging indent so
    /// the marker sits at `indentLevel * listIndentPerLevel` and the text (and any
    /// wrapped lines) align at `+ markerWidth + gap`.
    private static func listAttributedString(
        marker: String,
        text: String,
        indentLevel: Int,
        markerWidth: CGFloat,
        markerColor: NSColor = MarkdownSemanticStyler.listMarkerColor
    ) -> NSAttributedString {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        // Numbered lists use monospaced digits in SwiftUI (`.body.monospacedDigit().weight(.semibold)`).
        let isNumberedMarker = marker.last == "." && marker.dropLast().allSatisfy(\.isNumber)
        let markerFont = isNumberedMarker
            ? NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .semibold)
            : NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)

        let result = NSMutableAttributedString(
            string: marker,
            attributes: [.font: markerFont, .foregroundColor: markerColor]
        )
        result.append(NSAttributedString(string: "\t", attributes: [.font: bodyFont]))
        result.append(attributedString(text, font: bodyFont, color: .labelColor, parseInlineMarkdown: true))

        let firstLineIndent = CGFloat(max(indentLevel, 0)) * listIndentPerLevel
        let textColumn = firstLineIndent + markerWidth + listMarkerTextGap
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = firstLineIndent          // marker starts here
        paragraph.headIndent = textColumn                        // wrapped lines align with text
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: textColumn, options: [:])]
        paragraph.defaultTabInterval = textColumn
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func quoteBlock(_ text: String) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        // SwiftUI quote: `.padding(.leading, 12)` with a 3 pt bar overlay = 12 pt total
        // between the bar and the body. Native: 3 pt bar + 9 pt spacing = 12 pt total.
        row.spacing = 9

        let bar = DynamicFillView(fill: MarkdownSemanticStyler.quoteBarColor)
        bar.layer?.cornerRadius = AppTheme.Chat.quoteBarCornerRadius
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let body = textView(
            text,
            font: MarkdownSemanticStyler.quoteFont,
            color: MarkdownSemanticStyler.quoteColor
        )
        row.addArrangedSubview(bar)
        row.addArrangedSubview(body)
        return row
    }

    /// Layer-backed NSView whose `backgroundColor` tracks the view's effective
    /// appearance. `nsColor.cgColor` is a snapshot — setting it once at view
    /// construction freezes the layer at whatever appearance was active then.
    /// Overriding `viewDidChangeEffectiveAppearance` and re-resolving the
    /// dynamic NSColor under the new appearance keeps the layer live across
    /// runtime Light↔Dark switches.
    private final class DynamicFillView: NSView {
        private let fillColor: NSColor
        private let borderColor: NSColor?
        private let borderWidth: CGFloat
        init(fill: NSColor, border: NSColor? = nil, borderWidth: CGFloat = 1) {
            self.fillColor = fill
            self.borderColor = border
            self.borderWidth = borderWidth
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            applyFill()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyFill()
        }
        private func applyFill() {
            // Resolve the dynamic provider under THIS view's effective appearance
            // (not the global one). `performAsCurrentDrawingAppearance` makes
            // `nsColor.cgColor` resolve against the supplied appearance for the
            // duration of the closure.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = fillColor.cgColor
                if let borderColor {
                    layer?.borderColor = borderColor.cgColor
                    layer?.borderWidth = borderWidth
                }
            }
        }
    }

    private static func paddedTextBlock(_ source: String, font: NSFont, color: NSColor, fill: NSColor, border: NSColor? = nil, cornerRadius: CGFloat, padding: NSEdgeInsets) -> NSView {
        let container = DynamicFillView(fill: fill, border: border)
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        let text = textView(source, font: font, color: color, parseInlineMarkdown: false)
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding.left),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding.right),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: padding.top),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding.bottom)
        ])
        return container
    }

    private static func paddedBlock(_ view: NSView, padding: NSEdgeInsets) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: padding.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding.bottom)
        ])
        return container
    }

    private static func textView(_ source: String, font: NSFont, color: NSColor, parseInlineMarkdown: Bool = true) -> AutoSizingMarkdownTextView {
        let textView = AutoSizingMarkdownTextView(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.allowsUndo = false
        // Read-only model output: switch off the idle-time text services AppKit
        // otherwise runs against `textStorage` on every edit. During streaming
        // each appended token is an edit, so spell/grammar/substitution/link/data
        // passes would fire ~30×/sec per block for zero benefit on non-editable
        // content.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.applyContent(attributedString(source, font: font, color: color, parseInlineMarkdown: parseInlineMarkdown))
        return textView
    }

    // Parsed-block memo. Building an attributed block runs `AttributedString(markdown:)`
    // + base-font enumeration + `MarkdownSemanticStyler.applyInlineColors` (the cost the
    // Appearance "markdown highlighting" setting amplifies). The result is a pure function
    // of (source, font, color, parseInline, theme revision), so identical blocks — a
    // recycled cell scrolling back over a message, a static doc re-rendered in
    // issues/memory/subagent — reuse the parse instead of redoing it. Returned values are
    // immutable and every caller copies before mutating, so sharing is safe. Keyed on the
    // theme revision so toggling highlighting / switching theme never serves stale colors.
    private static var attributedStringCache: [String: NSAttributedString] = [:]
    private static var attributedStringCacheOrder: [String] = []
    private static let attributedStringCacheLimit = 512

    private static func attributedString(_ source: String, font: NSFont, color: NSColor, parseInlineMarkdown: Bool) -> NSAttributedString {
        let key = "\(ThemeManager.shared.revision)|\(parseInlineMarkdown ? 1 : 0)|\(font.fontName):\(font.pointSize)|\(color.description)|\(source)"
        if let cached = attributedStringCache[key] { return cached }
        let result = buildAttributedString(source, font: font, color: color, parseInlineMarkdown: parseInlineMarkdown)
        attributedStringCache[key] = result
        attributedStringCacheOrder.append(key)
        if attributedStringCacheOrder.count > attributedStringCacheLimit {
            let evict = attributedStringCacheOrder.removeFirst()
            attributedStringCache.removeValue(forKey: evict)
        }
        return result
    }

    private static func buildAttributedString(_ source: String, font: NSFont, color: NSColor, parseInlineMarkdown: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard parseInlineMarkdown,
              let attributed = try? AttributedString(
                markdown: source,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
              ) else {
            return NSAttributedString(string: source, attributes: base)
        }

        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: color, range: fullRange)
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        applyBaseFont(font, preservingInlineTraitsIn: mutable)
        MarkdownSemanticStyler.applyInlineColors(to: mutable)
        return mutable
    }

    private static func applyBaseFont(_ baseFont: NSFont, preservingInlineTraitsIn attributed: NSMutableAttributedString) {
        let manager = NSFontManager.shared
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            var replacement = baseFont
            if let current = value as? NSFont {
                let traits = manager.traits(of: current)
                if traits.contains(.boldFontMask) {
                    replacement = manager.convert(replacement, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italicFontMask) {
                    replacement = manager.convert(replacement, toHaveTrait: .italicFontMask)
                }
            }
            attributed.addAttribute(.font, value: replacement, range: range)
        }
    }

    private static func bulletMarker(for level: Int) -> String {
        switch max(level, 0) % 3 {
        case 1: return "◦"
        case 2: return "▪"
        default: return "•"
        }
    }
}

/// Native GFM table laid out by hand: equal-width columns,
/// each cell a text view measured at the column width, a hairline under the header,
/// and a self height-constraint so the host stack's `fittingSize` includes it.
/// `NSGridView` was tried first but doesn't constrain column widths against the
/// auto-sizing cells, collapsing every cell into one tall column.
private final class MarkdownTableView: NSView {
    private var cellViews: [[NSTextView]] = []   // [row][col]; row 0 is the header
    private let separator = NSBox()
    private var heightConstraint: NSLayoutConstraint!
    /// Bands (full-width row rects) for the zebra-striped body rows, filled in `draw`.
    private var stripeRects: [NSRect] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = true
        separator.isHidden = true
        addSubview(separator)
        heightConstraint = heightAnchor.constraint(equalToConstant: 24)
        heightConstraint.priority = .required - 1
        heightConstraint.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(headerCells: [NSAttributedString], bodyRows: [[NSAttributedString]]) {
        cellViews.forEach { $0.forEach { $0.removeFromSuperview() } }
        cellViews.removeAll()
        let columnCount = max(headerCells.count, bodyRows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { heightConstraint.constant = 1; return }

        let header = (0..<columnCount).map { Self.makeCell(headerCells.indices.contains($0) ? headerCells[$0] : NSAttributedString()) }
        cellViews.append(header)
        header.forEach { addSubview($0) }
        for row in bodyRows {
            let cells = (0..<columnCount).map { Self.makeCell(row.indices.contains($0) ? row[$0] : NSAttributedString()) }
            cellViews.append(cells)
            cells.forEach { addSubview($0) }
        }
        needsLayout = true
    }

    private static func makeCell(_ attr: NSAttributedString) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        // Read-only model output — disable the idle text services (same as the
        // other transcript text views) so streaming edits stay cheap.
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.textStorage?.setAttributedString(attr)
        return tv
    }

    override func layout() {
        super.layout()
        if bounds.width > 0.5 { relayout(width: bounds.width) }
    }

    private func relayout(width: CGFloat) {
        let columnCount = cellViews.first?.count ?? 0
        guard columnCount > 0, width > 1 else { heightConstraint.constant = 1; return }

        let columnGap: CGFloat = 16
        let rowGap: CGFloat = 8
        let separatorGap: CGFloat = 6
        let headerPaddingBottom: CGFloat = 6
        let totalGaps = CGFloat(columnCount - 1) * columnGap
        let usable = max(width - totalGaps, CGFloat(columnCount) * 40)
        let columnWidth = floor(usable / CGFloat(columnCount))

        // Row heights from each cell's own TextKit layout at the column width.
        var rowHeights: [CGFloat] = []
        for row in cellViews {
            var maxH: CGFloat = 0
            for cell in row {
                cell.textContainer?.containerSize = NSSize(width: columnWidth, height: .greatestFiniteMagnitude)
                if let lm = cell.layoutManager, let tc = cell.textContainer {
                    lm.ensureLayout(for: tc)
                    maxH = max(maxH, ceil(lm.usedRect(for: tc).height) + 2)
                }
            }
            rowHeights.append(max(maxH, 18))
        }

        var y: CGFloat = 0
        var stripes: [NSRect] = []
        var bodyOrdinal = 0
        for (rowIdx, row) in cellViews.enumerated() {
            var x: CGFloat = 0
            let rowH = rowHeights[rowIdx]
            for (colIdx, cell) in row.enumerated() {
                cell.frame = NSRect(x: x, y: y, width: columnWidth, height: rowH)
                x += columnWidth
                if colIdx < row.count - 1 { x += columnGap }
            }
            // Zebra-stripe every other body row (header excluded): a faint full-width
            // band behind the cells, padded into the row gaps so the stripes touch.
            if rowIdx > 0 {
                if bodyOrdinal % 2 == 1 {
                    stripes.append(NSRect(x: 0, y: y - rowGap / 2, width: width, height: rowH + rowGap))
                }
                bodyOrdinal += 1
            }
            y += rowH
            if rowIdx == 0 {
                y += headerPaddingBottom
                separator.frame = NSRect(x: 0, y: y, width: width, height: 1)
                separator.isHidden = false
                y += separatorGap
            } else if rowIdx < cellViews.count - 1 {
                y += rowGap
            }
        }

        if stripes != stripeRects {
            stripeRects = stripes
            needsDisplay = true
        }

        let newHeight = max(ceil(y), 1)
        if abs(heightConstraint.constant - newHeight) > 0.5 {
            heightConstraint.constant = newHeight
            invalidateIntrinsicContentSize()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !stripeRects.isEmpty else { return }
        AppTheme.ns(AppTheme.contentSubtleFill.opacity(0.2)).setFill()
        for rect in stripeRects where rect.intersects(dirtyRect) {
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant)
    }
}

private final class AutoSizingMarkdownTextView: NSTextView {
    /// Bumped only when the text content actually changes (`applyContent`), NOT on
    /// layout. The intrinsic-size memo keys on it so a forced settle that re-queries
    /// `intrinsicContentSize` at an unchanged width + content skips the TextKit
    /// `ensureLayout`/`usedRect` pass entirely — the dominant per-vend scroll cost.
    private var contentVersion = 0
    private var cachedIntrinsic: (width: CGFloat, version: Int, height: CGFloat)?
    private var lastIntrinsicInvalidationWidth: CGFloat = -1

    /// Set the rendered text. Routes every content change through one place so the
    /// memo is invalidated exactly when (and only when) the content changes.
    func applyContent(_ attributed: NSAttributedString) {
        contentVersion &+= 1
        cachedIntrinsic = nil
        lastIntrinsicInvalidationWidth = -1
        if let storage = textStorage {
            storage.beginEditing()
            storage.setAttributedString(attributed)
            storage.endEditing()
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        }
        let width = max(bounds.width, textContainer.containerSize.width, 1)
        // Same width + same content as the last computed pass → reuse the height.
        // Height depends only on (text, width, font); font is fixed per view and a
        // dark/light flip doesn't change metrics, so this is exact, not approximate.
        if let cached = cachedIntrinsic, cached.version == contentVersion, abs(cached.width - width) < 0.5 {
            return NSSize(width: NSView.noIntrinsicMetric, height: cached.height)
        }
        // No real width yet: a freshly built block enters the window's
        // update-constraints pass before any layout has assigned it a frame, so
        // wrapping here would run a full TextKit layout at a ~1pt width — one
        // line fragment per word, the single most expensive thing a transcript
        // scroll does, multiplied per block per newly revealed row — and the
        // result is thrown away once the real width lands. Report a placeholder
        // instead (uncached, so this never masks a real measurement); `layout()`
        // invalidates the intrinsic when the frame arrives and the same display
        // cycle re-queries at the true width, paying for exactly one layout.
        if width < 2 {
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = max(1, ceil(layoutManager.usedRect(for: textContainer).height) + textContainerInset.height * 2)
        cachedIntrinsic = (width, contentVersion, height)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        let width = max(bounds.width, 1)
        guard abs(width - lastIntrinsicInvalidationWidth) >= 0.5 else { return }
        lastIntrinsicInvalidationWidth = width
        invalidateIntrinsicContentSize()
    }

    /// Suppress NSTextView's "keep caret/selection visible" auto-scroll.
    ///
    /// On every frame-size change (each streaming token, each cell reconfigure)
    /// NSTextView calls `_centeredScrollRectToVisible:` → `scrollRectToVisible(_:)`,
    /// which walks to the enclosing scroll view and yanks the **transcript's**
    /// scroll position to this text view's origin. With one of these views per
    /// markdown block, that is the transcript "shake" / scroll fight — a console
    /// trace caught it as `-[NSTextView _setFrameSize:forceScroll:]` driving the
    /// clip view's bounds. This view is read-only and always sized to its full
    /// content (see `intrinsicContentSize`), so self-scrolling has no purpose.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        false
    }
}

@MainActor
private enum MarkdownInlineRenderCache {
    private static var cache: [String: AttributedString] = [:]
    private static var order: [String] = []
    private static let limit = 1_024

    static func attributedString(for source: String) -> AttributedString? {
        let key = cacheKey(for: source)
        if let cached = cache[key] { return cached }
        guard let attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return nil
        }
        cache[key] = attributed
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
        return attributed
    }

    private static func cacheKey(for source: String) -> String {
        var hasher = Hasher()
        hasher.combine(source)
        return "\(source.count):\(hasher.finalize())"
    }
}

// `nonisolated` (the file builds with MainActor default isolation): a pure value
// type that the off-main markdown parse produces and returns across actors.
private nonisolated struct CachedMarkdownDocument: Sendable, Equatable {
    let frontmatter: String?
    let blocks: [MarkdownBlock]
}

private enum StreamingMarkdownBalancer {
    static func balance(_ text: String) -> String {
        let parts = text.components(separatedBy: "```")
        guard parts.count > 1 || !text.isEmpty else { return text }
        let endsInsideOpenFence = parts.count % 2 == 0
        let lastOutsideIndex = endsInsideOpenFence ? nil : parts.count - 1

        var rebuilt = ""
        for (index, part) in parts.enumerated() {
            if index > 0 { rebuilt += "```" }
            rebuilt += index == lastOutsideIndex ? balanceTrailingParagraph(part) : part
        }
        return rebuilt
    }

    private static func balanceTrailingParagraph(_ segment: String) -> String {
        guard let range = segment.range(of: "\n\n", options: .backwards) else {
            return balanceParagraph(segment)
        }
        return String(segment[..<range.upperBound]) + balanceParagraph(String(segment[range.upperBound...]))
    }

    private static func balanceParagraph(_ paragraph: String) -> String {
        var body = stripIncompleteTrailingListMarkerLine(paragraph)
        let trailingWhitespace = trailingWhitespace(in: body)
        body.removeLast(trailingWhitespace.count)
        body = stripFreshlyOpenedTrailingMarker(body)
        body = stripIncompleteTrailingListMarkerLine(body)
        if body.lazy.filter({ $0 == "`" }).count % 2 == 1 { body += "`" }
        if doubleAsteriskCount(in: body) % 2 == 1 { body += "**" }
        return body + String(trailingWhitespace)
    }

    private static func trailingWhitespace(in source: String) -> Substring {
        var start = source.endIndex
        while start > source.startIndex {
            let previous = source.index(before: start)
            guard source[previous] == " " || source[previous] == "\t" || source[previous] == "\n" else { break }
            start = previous
        }
        return source[start..<source.endIndex]
    }

    private static func stripIncompleteTrailingListMarkerLine(_ source: String) -> String {
        var end = source.endIndex
        while end > source.startIndex {
            let previous = source.index(before: end)
            guard source[previous].isWhitespace else { break }
            end = previous
        }
        guard end > source.startIndex else { return source }
        let lineStart = source.range(of: "\n", options: .backwards, range: source.startIndex..<end)?.upperBound ?? source.startIndex
        let marker = source[lineStart..<end].trimmingCharacters(in: .whitespaces)
        guard marker == "-" || marker == "*" || marker == "+" || isOrderedListMarker(marker) else { return source }
        let dropFrom = lineStart > source.startIndex ? source.index(before: lineStart) : source.startIndex
        return String(source[..<dropFrom])
    }

    private static func isOrderedListMarker(_ marker: String) -> Bool {
        guard marker.count >= 2, let last = marker.last, last == "." || last == ")" else { return false }
        return marker.dropLast().allSatisfy(\.isNumber)
    }

    private static func stripFreshlyOpenedTrailingMarker(_ source: String) -> String {
        guard let last = source.last, last == "*" || last == "`" else { return source }
        var start = source.endIndex
        var cursor = source.endIndex
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == last else { break }
            start = previous
            cursor = previous
        }
        let length = source.distance(from: start, to: source.endIndex)
        guard length == 1 || length == 2 else { return source }
        if start == source.startIndex || source[source.index(before: start)].isWhitespace {
            return String(source[..<start])
        }
        return source
    }

    private static func doubleAsteriskCount(in source: String) -> Int {
        var count = 0
        var cursor = source.startIndex
        while let range = source.range(of: "**", range: cursor..<source.endIndex) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }
}

@MainActor
private enum MarkdownRenderCache {
    private static var cache: [String: CachedMarkdownDocument] = [:]
    private static var order: [String] = []
    private static let limit = 256

    static func document(for source: String) -> CachedMarkdownDocument {
        if let cached = cachedDocument(for: source) { return cached }
        let document = parseDocument(for: source)
        store(document, for: source)
        return document
    }

    /// Cache lookup only — no parse. Lets callers take a synchronous fast path
    /// (apply immediately, height stays stable) and only fall back to a parse
    /// when it misses.
    static func cachedDocument(for source: String) -> CachedMarkdownDocument? {
        cache[cacheKey(for: source)]
    }

    /// Pure parse, no cache access. `nonisolated` so it can run on a background
    /// task for large uncached blocks (see `NativeMarkdownRepresentable`) — every
    /// streaming flush of a big message otherwise re-parses the whole source on
    /// the main thread.
    nonisolated static func parseDocument(for source: String) -> CachedMarkdownDocument {
        let parsed = RawFrontmatterParser.parse(source)
        let markdown = parsed?.content ?? source
        return CachedMarkdownDocument(frontmatter: parsed?.frontmatter, blocks: MarkdownBlock.parse(markdown))
    }

    static func store(_ document: CachedMarkdownDocument, for source: String) {
        let key = cacheKey(for: source)
        guard cache[key] == nil else { return }
        cache[key] = document
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
    }

    nonisolated private static func cacheKey(for source: String) -> String {
        var hasher = Hasher()
        hasher.combine(source)
        return "\(source.count):\(hasher.finalize())"
    }
}

nonisolated enum MarkdownTableAlignment: Hashable { case leading, center, trailing }

/// A parsed GFM table. Pure value type so it can be built on the background parse
/// path and rendered natively (`NativeMarkdownTextContainer.tableBlock`).
nonisolated struct MarkdownTable: Hashable {
    var header: [String]
    var alignments: [MarkdownTableAlignment]
    var rows: [[String]]

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    func alignment(_ column: Int) -> MarkdownTableAlignment {
        column < alignments.count ? alignments[column] : .leading
    }
}

// `nonisolated` so `parse` and its helpers run on a background task (see
// `MarkdownRenderCache.parseDocument`). Pure string/value logic — no UI state.
private nonisolated struct MarkdownBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String, indentLevel: Int)
        case numbered(Int, String, indentLevel: Int)
        case quote(String)
        case code(String)
        case table(MarkdownTable)
    }

    let id: Int
    let kind: Kind

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var codeFenceIndent = 0
        var inCode = false

        // CommonMark: a fenced code block strips up to the opening fence's own
        // indentation from each content line — so a fence nested inside a list
        // item doesn't render with the list's indentation baked into the code.
        func strippingFenceIndent(_ line: String) -> String {
            var result = Substring(line)
            var removed = 0
            while removed < codeFenceIndent, let first = result.first, first == " " || first == "\t" {
                result = result.dropFirst()
                removed += 1
            }
            return String(result)
        }

        func flushParagraph() {
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.init(id: blocks.count, kind: .paragraph(text)))
        }

        func appendSimple(_ kind: Kind) {
            flushParagraph()
            blocks.append(.init(id: blocks.count, kind: kind))
        }

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indentLevel = Self.indentLevel(for: line)
            if trimmed.hasPrefix("```") {
                if inCode {
                    appendSimple(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    code.removeAll()
                    codeFenceIndent = line.prefix { $0 == " " || $0 == "\t" }.count
                }
                lineIndex += 1
                continue
            }
            if inCode {
                code.append(strippingFenceIndent(line))
                lineIndex += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }
            // GFM table: a `|…|` header line immediately followed by a `|---|`
            // separator. Consume the whole table here (needs lookahead) so its rows
            // don't fall through to the paragraph bucket and render as raw pipes.
            if let consumed = parseTableAhead(lines, from: lineIndex) {
                flushParagraph()
                blocks.append(.init(id: blocks.count, kind: .table(consumed.table)))
                lineIndex = consumed.nextIndex
                continue
            }
            defer { lineIndex += 1 }
            if let heading = parseHeading(trimmed) {
                appendSimple(.heading(level: heading.level, text: heading.text))
            } else if let bullet = parseBullet(trimmed) {
                appendSimple(.bullet(bullet, indentLevel: indentLevel))
            } else if let numbered = parseNumbered(trimmed) {
                appendSimple(.numbered(numbered.number, numbered.text, indentLevel: indentLevel))
            } else if trimmed.hasPrefix(">") {
                appendSimple(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if inCode {
            appendSimple(.code(code.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks.isEmpty ? [.init(id: 0, kind: .paragraph(source))] : blocks
    }

    /// If `lines[index]` is a table header followed by a `|---|` separator, parse
    /// the whole table (header + every contiguous row) and return the index just
    /// past it. Returns nil when there's no table here.
    private static func parseTableAhead(_ lines: [String], from index: Int) -> (table: MarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"), isTableSeparator(separatorLine) else { return nil }

        let header = tableCells(headerLine)
        let alignments = tableAlignments(separatorLine)
        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let row = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, row.contains("|") else { break }
            rows.append(tableCells(row))
            cursor += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), cursor)
    }

    /// A GFM separator row: cells of dashes with optional alignment colons, e.g.
    /// `|---|:--:|---:|`. Strict enough that a paragraph line with a stray pipe
    /// isn't mistaken for one.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var body = Substring(cell.trimmingCharacters(in: .whitespaces))
            guard !body.isEmpty else { return false }
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// Split a `|`-delimited row into trimmed cells, dropping the optional leading
    /// and trailing pipe so interior empty cells are preserved.
    private static func tableCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.first == "|" { body = body.dropFirst() }
        if body.last == "|" { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableAlignments(_ separatorLine: String) -> [MarkdownTableAlignment] {
        tableCells(separatorLine).map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func parseBullet(_ line: String) -> String? {
        guard line.count > 2 else { return nil }
        let prefixes = ["- ", "* ", "+ "]
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func indentLevel(for line: String) -> Int {
        let width = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { total, character in
            total + (character == "\t" ? 4 : 1)
        }
        return min(width / 2, 6)
    }

    private static let numberedListRegex = try? NSRegularExpression(pattern: #"^(\d+)[\.)]\s+(.*)$"#)

    private static func parseNumbered(_ line: String) -> (number: Int, text: String)? {
        guard let regex = numberedListRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let numberRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line),
              let number = Int(line[numberRange]) else { return nil }
        return (number, String(line[textRange]))
    }
}

private final class PassthroughWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let content: String
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var contentHash: Int {
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(colorScheme)
        return hasher.finalize()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "contentHeight")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.websiteDataStore = .nonPersistent()
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = PassthroughWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = Self.dynamicBackgroundColor
        if let scrollView = webView.enclosingScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }
        loadHTML(in: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = Self.dynamicBackgroundColor
        if context.coordinator.lastContentHash != contentHash {
            loadHTML(in: webView, context: context)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
    }

    private func loadHTML(in webView: WKWebView, context: Context) {
        context.coordinator.prepareForContentLoad(contentHash: contentHash)
        webView.loadHTMLString(Self.cachedHTML(for: content, colorScheme: colorScheme), baseURL: nil)
    }

    @MainActor
    private static func cachedHTML(for content: String, colorScheme: ColorScheme) -> String {
        let key = htmlCacheKey(for: content, colorScheme: colorScheme)
        if let cached = htmlCache[key] { return cached }
        let parsed = RawFrontmatterParser.parse(content)
        let markdown = parsed?.content ?? content
        let frontmatterHTML = parsed?.frontmatter.map(Self.frontmatterHTML) ?? ""
        let payload = Self.javaScriptStringLiteral(markdown)

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: https:;">
        <style>\(Self.css)</style>
        <script>\(MarkedJSSource.source)</script>
        </head>
        <body>
            \(frontmatterHTML)
            <div id="markdown-root"></div>
            <script>
                const markdown = \(payload);
                const root = document.getElementById('markdown-root');
                root.innerHTML = marked.parse(markdown, {
                    gfm: true,
                    breaks: false
                });

                function reportHeight() {
                    const bodyStyle = window.getComputedStyle(document.body);
                    const paddingTop = parseFloat(bodyStyle.paddingTop || '0');
                    const paddingBottom = parseFloat(bodyStyle.paddingBottom || '0');
                    const range = document.createRange();
                    range.selectNodeContents(document.body);
                    const rect = range.getBoundingClientRect();
                    const rootRect = root.getBoundingClientRect();
                    const frontmatter = document.querySelector('.frontmatter');
                    const frontmatterRect = frontmatter ? frontmatter.getBoundingClientRect() : { height: 0 };
                    const contentHeight = Math.max(rect.height, rootRect.height + frontmatterRect.height);
                    const height = Math.ceil(contentHeight + paddingTop + paddingBottom + 2);
                    window.webkit.messageHandlers.contentHeight.postMessage(height);
                }

                const heightReportState = { pending: false };
                function scheduleHeightReport() {
                    if (heightReportState.pending) {
                        return;
                    }
                    heightReportState.pending = true;
                    requestAnimationFrame(() => {
                        heightReportState.pending = false;
                        reportHeight();
                    });
                }

                const observer = new MutationObserver(scheduleHeightReport);
                observer.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true });

                reportHeight();
                scheduleHeightReport();
                window.addEventListener('load', scheduleHeightReport, { once: true });
                window.addEventListener('resize', scheduleHeightReport);
            </script>
        </body>
        </html>
        """

        htmlCache[key] = html
        htmlCacheOrder.append(key)
        if htmlCacheOrder.count > htmlCacheLimit {
            let overflow = htmlCacheOrder.count - htmlCacheLimit
            for oldKey in htmlCacheOrder.prefix(overflow) {
                htmlCache[oldKey] = nil
            }
            htmlCacheOrder.removeFirst(overflow)
        }
        return html
    }

    private static func htmlCacheKey(for content: String, colorScheme: ColorScheme) -> String {
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(colorScheme)
        hasher.combine(ThemeManager.shared.revision)
        return "\(content.count):\(hasher.finalize())"
    }

    @MainActor private static var htmlCache: [String: String] = [:]
    @MainActor private static var htmlCacheOrder: [String] = []
    private static let htmlCacheLimit = 64

    private static let dynamicBackgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
            : NSColor(red: 0xFA/255.0, green: 0xFA/255.0, blue: 0xFA/255.0, alpha: 1)
    }

    nonisolated private static func frontmatterHTML(_ frontmatter: String) -> String {
        let escaped = frontmatter
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre class=\"frontmatter\">\(escaped)</pre>"
    }

    nonisolated private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let arrayLiteral = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arrayLiteral.dropFirst().dropLast())
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastContentHash: Int?
        private var lastReportedHeight: CGFloat = 0
        private var contentHeight: Binding<CGFloat>

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func prepareForContentLoad(contentHash: Int) {
            lastContentHash = contentHash
            lastReportedHeight = 0
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight" else { return }
            if let height = message.body as? CGFloat {
                applyContentHeight(height)
            } else if let number = message.body as? NSNumber {
                applyContentHeight(CGFloat(number.doubleValue))
            }
        }

        private func applyContentHeight(_ height: CGFloat) {
            let sanitizedHeight = ceil(max(height, 0))
            guard abs(sanitizedHeight - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = sanitizedHeight

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
                guard let self else { return }
                guard abs(self.contentHeight.wrappedValue - sanitizedHeight) > 0.5 else { return }
                self.contentHeight.wrappedValue = sanitizedHeight
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    /// The base stylesheet is the pre-highlighting appearance. Enabling Markdown
    /// highlighting appends semantic overrides derived from the active app theme.
    private static var css: String {
        let base = cssTemplate.replacingOccurrences(
            of: "__ACCENT_HEX__",
            with: ThemeManager.shared.activeTheme.accent.hexString
        )
        guard ThemeManager.shared.markdownHighlightingEnabled else { return base }
        let theme = ThemeManager.shared.activeTheme
        return base + """

        h1, h2, h3, h4, h5, h6 { color: \(theme.assistant.hexString); }
        h1 { text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 0.14em; }
        strong, b { color: \(theme.tool.hexString); }
        em, i { color: \(theme.tool.lightened(by: 0.16).hexString); }
        a, a:hover { color: \(theme.assistant.hexString); text-decoration: underline; }
        code { color: \(theme.diffAdded.hexString) !important; }
        pre code { color: \(theme.diffAdded.hexString) !important; }
        blockquote {
            color: \(theme.tool.hexString);
            border-left-color: \(theme.tool.hexString);
        }
        ul li::marker { color: \(theme.accent.hexString); }
        ol li::marker { color: \(theme.assistant.hexString); font-weight: 600; }
        hr { border-color: \(theme.stroke.hexString); }
        figcaption { color: \(theme.assistant.hexString); }
        """
    }

    private static let cssTemplate = """
    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }

    body {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        font-size: 16px;
        line-height: 1.6;
        width: 100%;
        max-width: 100%;
        margin: 0;
        padding: 16px 20px 8px;
        overflow-x: hidden;
        color: #222222;
        background-color: #FAFAFA;
        border-radius: 12px;
        -webkit-font-smoothing: antialiased;
        -webkit-user-select: text;
    }

    @media (prefers-color-scheme: dark) {
        body {
            color: #E0E0E0;
            background-color: #1A1A1A;
        }
        a { color: __ACCENT_HEX__; }
        code {
            background-color: #2A2A2A !important;
            color: #E07070 !important;
        }
        pre {
            background-color: #2A2A2A !important;
            border-color: #333333 !important;
            color: #E0E0E0 !important;
        }
        pre code {
            background: none !important;
            color: #E0E0E0 !important;
        }
        blockquote {
            border-left-color: #444444;
            color: #999999;
        }
        table th {
            background-color: #2A2A2A;
            border-color: #444444;
        }
        table td {
            border-color: #333333;
        }
        table tr:nth-child(even) {
            background-color: #222222;
        }
        hr {
            border-color: #333333;
        }
        pre.frontmatter {
            color: #999999;
            background-color: #222222;
            border-color: #333333;
        }
    }

    h1, h2, h3, h4, h5, h6 {
        font-weight: 700;
        line-height: 1.3;
        margin-top: 1.5em;
        margin-bottom: 0.5em;
    }

    body > *:first-child {
        margin-top: 0;
    }

    h1 { font-size: 2em; }
    h2 { font-size: 1.5em; }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.1em; }

    p {
        margin-bottom: 1em;
    }

    a {
        color: #3366AA;
        text-decoration: none;
    }
    a:hover {
        text-decoration: underline;
    }

    code {
        font-family: "SF Mono", SFMono-Regular, Menlo, monospace;
        font-size: 0.85em;
        background-color: #F0F0F0;
        color: #CC3333;
        padding: 0.15em 0.35em;
        border-radius: 3px;
    }

    pre {
        background-color: #F5F5F5;
        border: 1px solid #E0E0E0;
        border-radius: 4px;
        padding: 1em;
        margin-bottom: 1em;
        overflow-x: auto;
        max-width: 100%;
    }

    pre code {
        background: none;
        color: inherit;
        padding: 0;
        font-size: 0.85em;
    }

    blockquote {
        border-left: 3px solid #CCCCCC;
        padding-left: 1em;
        margin-left: 0;
        margin-bottom: 1em;
        color: #666666;
        font-style: italic;
    }

    ul, ol {
        margin-bottom: 1em;
        padding-left: 1.5em;
    }

    li {
        margin-bottom: 0.25em;
    }

    ul.contains-task-list {
        list-style: none;
        padding-left: 0;
    }

    li.task-list-item {
        display: flex;
        align-items: baseline;
        gap: 0.5em;
    }

    li.task-list-item input[type="checkbox"] {
        margin: 0;
    }

    table {
        border-collapse: collapse;
        width: 100%;
        margin-bottom: 1em;
    }

    th, td {
        text-align: left;
        padding: 0.5em 0.75em;
    }

    th {
        font-weight: 600;
        background-color: #F5F5F5;
        border-bottom: 2px solid #DDDDDD;
    }

    td {
        border-bottom: 1px solid #EEEEEE;
    }

    tr:nth-child(even) {
        background-color: #FAFAFA;
    }

    del {
        text-decoration: line-through;
        opacity: 0.6;
    }

    hr {
        border: none;
        border-top: 1px solid #DDDDDD;
        margin: 2em 0;
    }

    img {
        max-width: 100%;
        height: auto;
    }

    #markdown-root {
        width: 100%;
        max-width: 100%;
        overflow-x: hidden;
    }

    #markdown-root > * {
        max-width: 100%;
    }

    pre.frontmatter {
        font-family: "SF Mono", SFMono-Regular, Menlo, monospace;
        font-size: 12px;
        line-height: 1.5;
        color: #333333;
        background-color: #F0F0F0;
        border: 1px solid transparent;
        border-radius: 6px;
        padding: 10px 12px;
        margin-bottom: 24px;
        white-space: pre-wrap;
        word-wrap: break-word;
    }
    """
}

private nonisolated enum RawFrontmatterParser {
    struct Result {
        let frontmatter: String?
        let content: String
    }

    static func parse(_ text: String) -> Result? {
        let lines = text.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                let frontmatterLines = Array(lines[1..<index])
                let frontmatter = frontmatterLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contentStart = min(index + 1, lines.count)
                let content = Array(lines[contentStart...]).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Result(frontmatter: frontmatter.isEmpty ? nil : frontmatter, content: content)
            }
        }

        return nil
    }
}

// MARK: - Transcript NSAttributedString builder
//
// Renders a transcript markdown source into a list of `TranscriptRenderedBlock`s
// for a native AppKit cell. Each "text-like" run of blocks (paragraph, bullet,
// numbered, heading) collapses into one `NSAttributedString` so the cell can
// stand up a single `NSTextView`. Code blocks and blockquotes remain separate
// (rounded background and left-bar respectively can't be expressed purely with
// `NSAttributedString` attribute keys, so the cell renders them with their own
// `NSView` containers).
//
// Visual parity target: SwiftUI `MarkdownTextView` above. The attribute choices
// in this builder mirror the SwiftUI font + colour + paragraph-style decisions
// block-for-block.
//
// Lives in this file so it can reach `MarkdownBlock`, `MarkdownRenderCache`,
// `MarkdownInlineRenderCache`, and `StreamingMarkdownBalancer` without
// promoting any of them out of file-private scope.

enum TranscriptRenderedBlock {
    /// A run of paragraph / list / heading blocks merged with `\n` separators.
    /// The cell renders this as a single `NSTextView`.
    case text(NSAttributedString)
    /// A standalone code fence. Rendered by the cell in an `NSView` with a
    /// `RoundedRectangle`-equivalent fill behind a monospaced `NSTextView`.
    case code(NSAttributedString)
    /// A standalone blockquote. Rendered by the cell with a leading 3 pt
    /// rounded bar matching the SwiftUI `AppTheme.contentStroke` overlay.
    case quote(NSAttributedString)
}

@MainActor
enum TranscriptAttributedStringBuilder {
    /// Returns the structured render plan for `source`. Caches results by the
    /// balanced source string; cells calling this on every streaming flush will
    /// hit the cache when text doesn't change.
    static func blocks(for source: String) -> [TranscriptRenderedBlock] {
        TranscriptAttributedStringCache.blocks(for: source)
    }

    /// Convenience: flatten the block plan into a single attributed string.
    /// Useful for cells that don't need separate views for code/quote blocks
    /// (e.g. compact preview rows) and for tests.
    static func attributedString(for source: String) -> NSAttributedString {
        let pieces = blocks(for: source)
        let result = NSMutableAttributedString()
        for (index, block) in pieces.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            switch block {
            case let .text(s), let .code(s), let .quote(s):
                result.append(s)
            }
        }
        return result
    }
}

@MainActor
private enum TranscriptAttributedStringCache {
    private static var cache: [String: [TranscriptRenderedBlock]] = [:]
    private static var order: [String] = []
    private static let limit = 1_024

    static func blocks(for source: String) -> [TranscriptRenderedBlock] {
        let key = cacheKey(for: source)
        if let cached = cache[key] { return cached }
        let built = build(from: source)
        cache[key] = built
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) { cache[oldKey] = nil }
            order.removeFirst(overflow)
        }
        return built
    }

    private static func cacheKey(for source: String) -> String {
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(ThemeManager.shared.revision)
        return "\(source.count):\(hasher.finalize())"
    }

    private static func build(from source: String) -> [TranscriptRenderedBlock] {
        let balanced = StreamingMarkdownBalancer.balance(source)
        let document = MarkdownRenderCache.document(for: balanced)
        var result: [TranscriptRenderedBlock] = []
        var current = NSMutableAttributedString()

        func flushText() {
            guard current.length > 0 else { return }
            result.append(.text(current))
            current = NSMutableAttributedString()
        }

        for block in document.blocks {
            switch block.kind {
            case let .quote(text):
                flushText()
                result.append(.quote(quoteString(text)))
            case let .code(text):
                flushText()
                result.append(.code(codeString(text)))
            default:
                if current.length > 0 {
                    current.append(NSAttributedString(string: "\n"))
                }
                current.append(renderTextBlock(block, isFirstInGroup: current.length == 0))
            }
        }
        flushText()
        return result
    }

    private static func renderTextBlock(_ block: MarkdownBlock, isFirstInGroup: Bool) -> NSAttributedString {
        switch block.kind {
        case let .heading(level, text):
            return headingString(level: level, text: text, isFirst: isFirstInGroup)
        case let .paragraph(text):
            return paragraphString(text)
        case let .bullet(text, indentLevel):
            return bulletString(text: text, indentLevel: indentLevel)
        case let .numbered(number, text, indentLevel):
            return numberedString(number: number, text: text, indentLevel: indentLevel)
        case let .table(table):
            return tableString(table)
        case .quote, .code:
            return NSAttributedString() // handled by the caller
        }
    }

    /// Monospace, column-aligned rendering of a table for this attributed-string
    /// path (the native transcript uses the `NSGridView` renderer instead).
    private static func tableString(_ table: MarkdownTable) -> NSAttributedString {
        let columnCount = max(1, table.columnCount)
        func padded(_ row: [String]) -> [String] {
            (0..<columnCount).map { $0 < row.count ? row[$0] : "" }
        }
        var widths = [Int](repeating: 0, count: columnCount)
        for row in [padded(table.header)] + table.rows.map(padded) {
            for (column, value) in row.enumerated() { widths[column] = max(widths[column], value.count) }
        }
        func format(_ row: [String]) -> String {
            padded(row).enumerated()
                .map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
        var lines = [format(table.header)]
        lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        lines.append(contentsOf: table.rows.map(format))

        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        return NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: NSMutableParagraphStyle()]
        )
    }

    // MARK: per-kind rendering — mirrors MarkdownTextView.blockView

    private static func headingString(level: Int, text: String, isFirst: Bool) -> NSAttributedString {
        // SwiftUI: level<=1 → .title3.weight(.bold); else → .headline.weight(.semibold).
        // `.headline` on macOS is already semibold; `.title3.bold` we synthesize.
        let baseFont: NSFont = level <= 1
            ? boldVariant(of: NSFont.preferredFont(forTextStyle: .title3))
            : NSFont.preferredFont(forTextStyle: .headline)
        let paragraph = NSMutableParagraphStyle()
        // SwiftUI applies .padding(.top, level <= 2 ? 4 : 2). Block separator already
        // contributes the inter-block gap; the heading itself adds this extra top.
        paragraph.paragraphSpacingBefore = isFirst ? 0 : (level <= 2 ? 4 : 2)
        paragraph.paragraphSpacing = 0
        let result = NSMutableAttributedString(attributedString: inlineAttributedString(for: text, baseAttributes: [
            .font: baseFont,
            .foregroundColor: MarkdownSemanticStyler.headingColor,
            .paragraphStyle: paragraph
        ]))
        if level == 1, ThemeManager.shared.markdownHighlightingEnabled, result.length > 0 {
            result.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: result.length)
            )
        }
        return result
    }

    private static func paragraphString(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 0
        return inlineAttributedString(for: text, baseAttributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
    }

    private static func bulletString(text: String, indentLevel: Int) -> NSAttributedString {
        // SwiftUI bullet: HStack with marker .frame(width: 18, alignment: .trailing)
        // and 8 pt spacing, then inlineText. Re-create with paragraph indents +
        // marker prefix.
        let leading = listIndent(for: indentLevel)
        let markerColumnWidth: CGFloat = 18
        let markerToTextGap: CGFloat = 8
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = leading
        paragraph.headIndent = leading + markerColumnWidth + markerToTextGap
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: leading + markerColumnWidth + markerToTextGap)]
        paragraph.defaultTabInterval = leading + markerColumnWidth + markerToTextGap
        paragraph.paragraphSpacing = 0

        let baseFont = NSFont.preferredFont(forTextStyle: .body)
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask),
            .foregroundColor: MarkdownSemanticStyler.listMarkerColor,
            .paragraphStyle: paragraph
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: bulletMarker(for: indentLevel) + "\t", attributes: markerAttrs))
        result.append(inlineAttributedString(for: text, baseAttributes: bodyAttrs))
        return result
    }

    private static func numberedString(number: Int, text: String, indentLevel: Int) -> NSAttributedString {
        // SwiftUI numbered: HStack with `"\(number)."` .frame(minWidth: 22, alignment: .trailing).
        let leading = listIndent(for: indentLevel)
        let markerColumnWidth: CGFloat = 22
        let markerToTextGap: CGFloat = 8
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = leading
        paragraph.headIndent = leading + markerColumnWidth + markerToTextGap
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: leading + markerColumnWidth + markerToTextGap)]
        paragraph.defaultTabInterval = leading + markerColumnWidth + markerToTextGap
        paragraph.paragraphSpacing = 0

        let baseFont = NSFont.preferredFont(forTextStyle: .body)
        let monoNumberFont = NSFont.monospacedDigitSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: monoNumberFont,
            .foregroundColor: MarkdownSemanticStyler.listEnumerationColor,
            .paragraphStyle: paragraph
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "\(number).\t", attributes: numberAttrs))
        result.append(inlineAttributedString(for: text, baseAttributes: bodyAttrs))
        return result
    }

    private static func quoteString(_ text: String) -> NSAttributedString {
        // The cell adds the leading 3 pt vertical bar overlay; the body itself is
        // themed italic text with 12 pt of leading text padding to clear the bar.
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        paragraph.paragraphSpacing = 0
        return inlineAttributedString(for: text, baseAttributes: [
            .font: MarkdownSemanticStyler.quoteFont,
            .foregroundColor: MarkdownSemanticStyler.quoteColor,
            .paragraphStyle: paragraph
        ])
    }

    private static func codeString(_ text: String) -> NSAttributedString {
        // The cell provides the rounded fill background and the 10 pt padding;
        // the attributed string itself is just monospaced body text.
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        paragraph.paragraphSpacing = 0
        let bodyFontSize = NSFont.preferredFont(forTextStyle: .body).pointSize
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular),
            .foregroundColor: MarkdownSemanticStyler.codeBlockColor,
            .paragraphStyle: paragraph
        ])
    }

    // MARK: helpers

    /// Parses inline-only markdown (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`)
    /// via the same `AttributedString(markdown:options:)` path the SwiftUI views use,
    /// then applies the base attributes while preserving the per-run trait choices
    /// (bold, italic, monospaced) the inline parser produced.
    private static func inlineAttributedString(for source: String, baseAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard let attributed = MarkdownInlineRenderCache.attributedString(for: source) else {
            return NSAttributedString(string: source, attributes: baseAttributes)
        }
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        for (key, value) in baseAttributes where key != .font {
            mutable.addAttribute(key, value: value, range: fullRange)
        }
        if let baseFont = baseAttributes[.font] as? NSFont {
            applyBaseFontPreservingInlineTraits(baseFont, in: mutable)
        }
        MarkdownSemanticStyler.applyInlineColors(to: mutable)
        return mutable
    }

    private static func applyBaseFontPreservingInlineTraits(_ baseFont: NSFont, in attributed: NSMutableAttributedString) {
        let manager = NSFontManager.shared
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            var replacement = baseFont
            var keepMono = false
            if let current = value as? NSFont {
                let traits = manager.traits(of: current)
                if traits.contains(.boldFontMask) {
                    replacement = manager.convert(replacement, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italicFontMask) {
                    replacement = manager.convert(replacement, toHaveTrait: .italicFontMask)
                }
                if current.fontDescriptor.symbolicTraits.contains(.monoSpace) || current.fontName.contains("Mono") {
                    keepMono = true
                }
            }
            if keepMono {
                let weight: NSFont.Weight = manager.traits(of: replacement).contains(.boldFontMask) ? .semibold : .regular
                replacement = NSFont.monospacedSystemFont(ofSize: replacement.pointSize, weight: weight)
            }
            attributed.addAttribute(.font, value: replacement, range: range)
        }
    }

    private static func boldVariant(of font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// SwiftUI MarkdownTextView uses `.padding(.leading, CGFloat(indentLevel) * 18)`
    /// implicitly via `listIndent(for:)` in the inline rendering. Match that here.
    private static func listIndent(for indentLevel: Int) -> CGFloat {
        CGFloat(max(indentLevel, 0)) * 18
    }

    private static func bulletMarker(for indentLevel: Int) -> String {
        // Mirrors `MarkdownTextView.bulletMarker(for:)`.
        switch max(indentLevel, 0) % 3 {
        case 1: return "◦"
        case 2: return "▪"
        default: return "•"
        }
    }
}
