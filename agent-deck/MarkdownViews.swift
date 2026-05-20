import AppKit
import SwiftUI
import WebKit

struct MarkdownDocumentView: View {
    let source: String
    var minimumHeight: CGFloat = 24
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        MarkdownWebView(content: source, contentHeight: $contentHeight)
            .frame(height: max(minimumHeight, contentHeight))
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
        configure(view: view)
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownTextContainer, context: Context) {
        configure(view: nsView)
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

    static func dismantleNSView(_ nsView: NativeMarkdownTextContainer, coordinator: ()) {
        nsView.dismantle()
    }

    private func configure(view: NativeMarkdownTextContainer) {
        let displaySource = StreamingMarkdownBalancer.balance(source)
        let document = MarkdownRenderCache.document(for: displaySource)
        view.configure(document: document)
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

private final class NativeMarkdownTextContainer: NSView {
    private let stackView = NSStackView()
    private var lastDocument: CachedMarkdownDocument?
    private var widthConstraint: NSLayoutConstraint?
    private var pendingHeightMeasurement = false
    private var isDismantled = false
    private var lastMeasuredWidth: CGFloat = 0
    private var lastMeasuredHeight: CGFloat = 0
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

    func configure(document: CachedMarkdownDocument) {
        isDismantled = false
        guard document != lastDocument else {
            scheduleHeightMeasurement()
            return
        }
        let previous = lastDocument
        lastDocument = document
        // Try the cheap streaming-friendly path first: when only the last block's text
        // changed (and its kind stayed the same), update that block's text view in place
        // instead of rebuilding the whole NSStackView. This is the hot path for every
        // assistant/thinking flush — without it each token costs a full per-block view
        // tear-down + recreation.
        if let previous, tryIncrementalUpdate(from: previous, to: document) {
            scheduleHeightMeasurement()
            return
        }
        rebuild(document: document)
        scheduleHeightMeasurement()
    }

    private func tryIncrementalUpdate(from previous: CachedMarkdownDocument, to next: CachedMarkdownDocument) -> Bool {
        guard previous.frontmatter == next.frontmatter else { return false }
        let oldBlocks = previous.blocks
        let newBlocks = next.blocks
        guard oldBlocks.count == newBlocks.count, !oldBlocks.isEmpty else { return false }

        // All blocks except (possibly) the last must match byte-for-byte.
        let lastIndex = oldBlocks.count - 1
        for i in 0..<lastIndex where oldBlocks[i] != newBlocks[i] {
            return false
        }

        // Last block: same kind metadata, different text content allowed.
        let oldLast = oldBlocks[lastIndex].kind
        let newLast = newBlocks[lastIndex].kind
        guard Self.sameKindShape(oldLast, newLast) else { return false }

        let viewOffset = next.frontmatter != nil ? 1 : 0
        let viewIndex = viewOffset + lastIndex
        guard viewIndex < stackView.arrangedSubviews.count else { return false }
        let view = stackView.arrangedSubviews[viewIndex]
        guard let textView = Self.firstTextView(in: view) else { return false }

        Self.updateTextView(textView, with: newLast)
        return true
    }

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
        let (font, color, parseInline) = textStyling(for: kind)
        let body = bodyText(from: kind)
        let attr = attributedString(body, font: font, color: color, parseInlineMarkdown: parseInline)
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(attr)
            storage.endEditing()
        }
        textView.invalidateIntrinsicContentSize()
    }

    private static func bodyText(from kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case let .heading(_, text), let .paragraph(text), let .quote(text), let .code(text):
            return text
        case let .bullet(text, _):
            return text
        case let .numbered(_, text, _):
            return text
        }
    }

    private static func textStyling(for kind: MarkdownBlock.Kind) -> (font: NSFont, color: NSColor, parseInlineMarkdown: Bool) {
        switch kind {
        case let .heading(level, _):
            if level <= 1 {
                let title3 = NSFont.preferredFont(forTextStyle: .title3)
                return (NSFontManager.shared.convert(title3, toHaveTrait: .boldFontMask), .labelColor, true)
            } else {
                return (NSFont.preferredFont(forTextStyle: .headline), .labelColor, true)
            }
        case .paragraph, .bullet, .numbered:
            return (NSFont.preferredFont(forTextStyle: .body), .labelColor, true)
        case .quote:
            return (NSFont.preferredFont(forTextStyle: .body), .secondaryLabelColor, true)
        case .code:
            let size = NSFont.preferredFont(forTextStyle: .body).pointSize
            return (.monospacedSystemFont(ofSize: size, weight: .regular), .labelColor, false)
        }
    }

    func dismantle() {
        isDismantled = true
        onHeightChange = nil
    }

    override func layout() {
        super.layout()
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
        configureWidthConstraint(to: width)
        // Force layout so the per-block AutoSizingMarkdownTextView intrinsics resolve
        // before we ask the stack for its fitting size — without this, freshly-rebuilt
        // children may still report stale heights.
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

    private func rebuild(document: CachedMarkdownDocument) {
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
                cornerRadius: 6,
                padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            )
            stackView.addArrangedSubview(frontmatterView)
        }

        for block in document.blocks {
            stackView.addArrangedSubview(Self.view(for: block))
        }
    }

    private func scheduleHeightMeasurement() {
        guard !isDismantled else { return }
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
        let height = ceil(stackView.fittingSize.height)
        guard abs(lastMeasuredHeight - height) > 0.5 || abs(lastMeasuredWidth - width) > 0.5 else { return }
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
            let view = textView(text, font: baseFont, color: .labelColor)
            view.setContentHuggingPriority(.required, for: .vertical)
            return paddedBlock(view, padding: NSEdgeInsets(top: level <= 2 ? 4 : 2, left: 0, bottom: 0, right: 0))
        case let .paragraph(text):
            return textView(text, font: NSFont.preferredFont(forTextStyle: .body), color: .labelColor)
        case let .bullet(text, indentLevel):
            return listRow(marker: bulletMarker(for: indentLevel), text: text, indentLevel: indentLevel, markerWidth: 18)
        case let .numbered(number, text, indentLevel):
            return listRow(marker: "\(number).", text: text, indentLevel: indentLevel, markerWidth: 22)
        case let .quote(text):
            return quoteBlock(text)
        case let .code(text):
            return paddedTextBlock(
                text,
                font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular),
                color: .labelColor,
                fill: AppTheme.nsCodeBlockFill,
                cornerRadius: 10,
                padding: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            )
        }
    }

    private static func listRow(marker: String, text: String, indentLevel: Int, markerWidth: CGFloat) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(max(indentLevel, 0)) * 22, bottom: 0, right: 0)

        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let markerView = NSTextField(labelWithString: marker)
        markerView.translatesAutoresizingMaskIntoConstraints = false
        // Numbered lists use monospaced digits in SwiftUI (`.body.monospacedDigit().weight(.semibold)`).
        // Detect "1.", "2.", … so the marker font matches.
        let isNumberedMarker = marker.last == "." && marker.dropLast().allSatisfy(\.isNumber)
        if isNumberedMarker {
            markerView.font = NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .semibold)
        } else {
            markerView.font = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        }
        markerView.textColor = .secondaryLabelColor
        markerView.alignment = .right
        markerView.setContentHuggingPriority(.required, for: .horizontal)
        markerView.widthAnchor.constraint(greaterThanOrEqualToConstant: markerWidth).isActive = true

        let body = textView(text, font: bodyFont, color: .labelColor)
        row.addArrangedSubview(markerView)
        row.addArrangedSubview(body)
        body.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        return row
    }

    private static func quoteBlock(_ text: String) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        // SwiftUI quote: `.padding(.leading, 12)` with a 3 pt bar overlay = 12 pt total
        // between the bar and the body. Native: 3 pt bar + 9 pt spacing = 12 pt total.
        row.spacing = 9

        let bar = DynamicFillView(fill: AppTheme.nsQuoteBarFill)
        bar.layer?.cornerRadius = 1
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true

        let body = textView(text, font: NSFont.preferredFont(forTextStyle: .body), color: .secondaryLabelColor)
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
        init(fill: NSColor) {
            self.fillColor = fill
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
            }
        }
    }

    private static func paddedTextBlock(_ source: String, font: NSFont, color: NSColor, fill: NSColor, cornerRadius: CGFloat, padding: NSEdgeInsets) -> NSView {
        let container = DynamicFillView(fill: fill)
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

    private static func textView(_ source: String, font: NSFont, color: NSColor, parseInlineMarkdown: Bool = true) -> NSTextView {
        let textView = AutoSizingMarkdownTextView(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.allowsUndo = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.textStorage?.setAttributedString(attributedString(source, font: font, color: color, parseInlineMarkdown: parseInlineMarkdown))
        return textView
    }

    private static func attributedString(_ source: String, font: NSFont, color: NSColor, parseInlineMarkdown: Bool) -> NSAttributedString {
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

private final class AutoSizingMarkdownTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 1)
        }
        let width = max(bounds.width, textContainer.containerSize.width, 1)
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height) + textContainerInset.height * 2 + 1
        return NSSize(width: NSView.noIntrinsicMetric, height: max(1, height))
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
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

private struct CachedMarkdownDocument: Sendable, Equatable {
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
        if body.filter({ $0 == "`" }).count % 2 == 1 { body += "`" }
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
        let key = cacheKey(for: source)
        if let cached = cache[key] { return cached }

        let parsed = RawFrontmatterParser.parse(source)
        let markdown = parsed?.content ?? source
        let document = CachedMarkdownDocument(frontmatter: parsed?.frontmatter, blocks: MarkdownBlock.parse(markdown))
        cache[key] = document
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
        return document
    }

    private static func cacheKey(for source: String) -> String {
        var hasher = Hasher()
        hasher.combine(source)
        return "\(source.count):\(hasher.finalize())"
    }
}

private struct MarkdownBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String, indentLevel: Int)
        case numbered(Int, String, indentLevel: Int)
        case quote(String)
        case code(String)
    }

    let id: Int
    let kind: Kind

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

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

        for line in lines {
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
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:;">
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

    private static let css = """
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
        -webkit-font-smoothing: antialiased;
        -webkit-user-select: text;
    }

    @media (prefers-color-scheme: dark) {
        body {
            color: #E0E0E0;
            background-color: #1A1A1A;
        }
        a { color: #6699CC; }
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

private enum RawFrontmatterParser {
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
        case .quote, .code:
            return NSAttributedString() // handled by the caller
        }
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
        return inlineAttributedString(for: text, baseAttributes: [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
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
            .foregroundColor: NSColor.secondaryLabelColor,
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
            .foregroundColor: NSColor.secondaryLabelColor,
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
        // muted-colour text with 12 pt of leading text padding to clear the bar.
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 0
        paragraph.paragraphSpacing = 0
        return inlineAttributedString(for: text, baseAttributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.secondaryLabelColor,
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
            .foregroundColor: NSColor.labelColor,
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
