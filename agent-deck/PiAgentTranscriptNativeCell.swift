import AppKit
import SwiftUI
import Symbols
import os

// Native (pure AppKit) rendering for transcript message bubbles. Replaces the
// SwiftUI card hosted in an NSHostingView for the common text rows so scrolling
// never re-runs SwiftUI layout or re-parses markdown on the layout pass.
//
// Layout mirrors the SwiftUI message row exactly: a full-width row holding a
// fixed-width "card" (rounded role-tinted chrome + header + markdown) on one
// side, with the hover-revealed copy/fork glass buttons floating in the gutter
// on the other side (never overlapping the card, never affecting its height):
//   • replies   → card left-aligned at replyCap; copy floats to the RIGHT
//   • questions → card hugged width, right-aligned; fork+copy float to the LEFT

/// Fork affordance for a user-question bubble: the single "Fork as Pi session"
/// action plus an optional list of agents for the "Fork as 1:1 agent chat…"
/// submenu, plus the re-run action (fork at this message and send it
/// immediately). Carries closures, so the enclosing payload isn't Equatable.
struct ForkModel {
    let onForkSession: () -> Void
    let onRerun: () -> Void
    let agentOptions: [ForkAgentOption]
}

struct ForkAgentOption {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
}

// MARK: - Generalized native-row seam

/// A pure-AppKit transcript row view. Self-measures (the owning cell adds the
/// row insets) and releases per-content resources before reuse. Every native
/// block type conforms to this so the cell can drive them all through one path.
protocol PiAgentNativeRowContent: NSView {
    init()
    /// Content height for a given full row width (EXCLUDES the cell's row insets).
    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat
    /// Called when the cell is about to reuse the view for different content.
    func prepareForReuseIfNeeded()
    /// Apply pending layout immediately (recycled cells may draw before the async
    /// layout pass). Default forces a synchronous subtree layout.
    func settleLayoutImmediately()
    /// Set by the cell. The view calls this when its own content height changes
    /// at runtime (e.g. expanding an inline list) so the cell re-measures and the
    /// table re-tiles the row. Views with fixed height never call it.
    var onIntrinsicHeightChange: (() -> Void)? { get set }
}

extension PiAgentNativeRowContent {
    func prepareForReuseIfNeeded() {}
    func settleLayoutImmediately() { layoutSubtreeIfNeeded() }
}

/// A type-erased native transcript row. Built once in the items pass; the cell
/// creates/reuses the concrete view, configures it for the row width, and reads
/// its measured height. Using a spec (instead of one enum case + cell branch per
/// view type) keeps the cell's native path uniform as more row types go native.
final class NativeRowSpec {
    enum PrewarmPolicy {
        /// Cheap enough for the normal idle prewarm window.
        case immediate
        /// May build AppKit/Markdown subtrees; only speculate after a longer idle window.
        case extendedIdle
        /// Never build speculatively offscreen.
        case disabled
    }

    /// Identifies the concrete view class so a recycled cell can reuse a view of
    /// the same type and only swap content rather than rebuild it.
    let typeID: ObjectIdentifier
    let prewarmPolicy: PrewarmPolicy
    let make: () -> NSView
    let configure: (NSView, CGFloat) -> Void
    let measure: (NSView, CGFloat) -> CGFloat
    let reset: (NSView) -> Void
    let settle: (NSView) -> Void
    let setHeightCallback: (NSView, (() -> Void)?) -> Void

    private init(
        typeID: ObjectIdentifier,
        prewarmPolicy: PrewarmPolicy,
        make: @escaping () -> NSView,
        configure: @escaping (NSView, CGFloat) -> Void,
        measure: @escaping (NSView, CGFloat) -> CGFloat,
        reset: @escaping (NSView) -> Void,
        settle: @escaping (NSView) -> Void,
        setHeightCallback: @escaping (NSView, (() -> Void)?) -> Void
    ) {
        self.typeID = typeID
        self.prewarmPolicy = prewarmPolicy
        self.make = make
        self.configure = configure
        self.measure = measure
        self.reset = reset
        self.settle = settle
        self.setHeightCallback = setHeightCallback
    }

    /// Build a spec for a concrete native row view type `V`. `configure` receives
    /// the typed view and the row width; height comes from `measuredHeight`.
    static func of<V: PiAgentNativeRowContent>(
        _ type: V.Type,
        prewarmPolicy: PrewarmPolicy = .extendedIdle,
        configure: @escaping (V, CGFloat) -> Void
    ) -> NativeRowSpec {
        NativeRowSpec(
            typeID: ObjectIdentifier(V.self),
            prewarmPolicy: prewarmPolicy,
            make: { V() },
            configure: { view, width in configure(view as! V, width) },
            measure: { view, width in (view as! V).measuredHeight(forWidth: width) },
            reset: { view in (view as! V).prepareForReuseIfNeeded() },
            settle: { view in (view as! V).settleLayoutImmediately() },
            setHeightCallback: { view, cb in (view as! V).onIntrinsicHeightChange = cb }
        )
    }
}

/// Presentation-only filtering for automatically rendered transcript images. It
/// deliberately leaves the persisted entry and copy text untouched.
enum PiAgentTranscriptImagePresentation {
    static func projectedSource(
        _ source: String,
        references: [PiAgentTranscriptImageReference],
        showImages: Bool
    ) -> String {
        guard !showImages, !source.isEmpty else { return source }

        struct Token {
            let range: NSRange
            let source: String
            let alwaysImage: Bool
        }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let patterns: [(String, Int, Bool)] = [
            (#"!\[[^\]]*\]\(([^\s\)]+)(?:\s+\"[^\"]*\")?\)"#, 1, true),
            (#"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"'][^>]*>"#, 1, true),
            (#"data:image/[^\s\)>\"']+"#, 0, true),
            (#"https://[^\s\)>\"']+"#, 0, false)
        ]
        let protectedRanges = protectedRanges(in: source)
        let tokens: [Token] = patterns.flatMap { (pattern, sourceGroup, alwaysImage) -> [Token] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return regex.matches(in: source, range: fullRange).compactMap { match in
                guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
                let sourceRange = match.range(at: sourceGroup)
                guard sourceRange.location != NSNotFound,
                      let range = Range(sourceRange, in: source) else { return nil }
                return Token(range: match.range, source: String(source[range]), alwaysImage: alwaysImage)
            }
        }

        let removals = tokens
            .sorted { $0.range.location < $1.range.location }
            .reduce(into: [NSRange]()) { ranges, token in
                guard token.alwaysImage || references.contains(where: { reference in
                    reference.source == token.source
                        || (reference.source == "data-url" && token.source.lowercased().hasPrefix("data:image/"))
                        || reference.remoteURL == token.source
                        || reference.localPath == token.source
                        || reference.name == URL(fileURLWithPath: token.source).lastPathComponent
                }) else { return }
                guard !ranges.contains(where: { NSIntersectionRange($0, token.range).length > 0 }) else { return }
                ranges.append(token.range)
            }

        return removals.reversed().reduce(source) { result, range in
            guard let stringRange = Range(range, in: result) else { return result }
            return result.replacingCharacters(in: stringRange, with: "")
        }
    }

    /// Matches the native bubble parser's exclusions for URLs that are text/code,
    /// rather than automatically rendered image tokens.
    static func protectedRanges(in source: String) -> [NSRange] {
        let patterns = [
            #"(?s)```.*?```"#,
            #"`[^`]*`"#,
            #"(?<!!)\[[^\]]+\]\([^\)]*\)"#
        ]
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
            return regex.matches(in: source, range: fullRange).map(\.range)
        }
    }
}

/// Typed payload for a native message bubble. Built once in the items pass; the
/// cell configures a `PiAgentNativeBubbleView` from it.
struct NativeBubblePayload {
    enum Role: Equatable { case user, assistant, thinking, tool, error, stderr, status, raw }
    enum CopySide: Equatable { case leading, trailing }

    var role: Role
    var headerTitle: String
    /// SF Symbol name for the header icon; `nil` renders the bundled "pi" logo.
    var iconSymbol: String?
    var markdownSource: String
    var imageReferences: [PiAgentTranscriptImageReference] = []
    var showInlineImagePreviews: Bool = true
    /// Small bold label above the body (e.g. "Reasoning" for thinking rows).
    var bodyPrefix: String?
    var copyText: String
    var copySide: CopySide
    /// Thread-child rows use tighter padding than standalone cards.
    var isThreadChild: Bool
    /// User question bubbles hug their content width and sit at the trailing edge.
    var isUserHugged: Bool = false
    /// Hover-revealed fork affordance (user questions only).
    var fork: ForkModel? = nil
}

// MARK: - Shared transcript image component

/// Polished native image attachment used by assistant bubbles and MCP/tool rows.
/// Keeps images session-owned (it only reads the materialized path), exposes the
/// same preview/reveal/copy actions everywhere, and remains cheap to measure.
final class PiAgentNativeTranscriptImageAttachmentView: NSView {
    enum DisplayStyle { case inline, tile }

    private let container = NSView()
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "Downloading image…")
    private let captionLabel = NSTextField(labelWithString: "")
    private var reference: PiAgentTranscriptImageReference?
    private var caption: String = ""
    private var displayStyle: DisplayStyle = .inline
    private var popover: NSPopover?
    private var imageHeightC: NSLayoutConstraint!
    private var imageWidthC: NSLayoutConstraint!

    private static let maxImageWidth: CGFloat = 180
    private static let maxImageHeight: CGFloat = 140
    private static let minImageHeight: CGFloat = 72
    private static let tileWidth: CGFloat = 104
    private static let tileImageHeight: CGFloat = 58
    private static let imageVInset: CGFloat = 6
    private static let captionGap: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        addSubview(container)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = NativeTranscriptFont.caption(.semibold)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        container.addSubview(placeholder)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = NativeTranscriptFont.caption2()
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.maximumNumberOfLines = 1
        addSubview(captionLabel)

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openPreview)))

        imageHeightC = imageView.heightAnchor.constraint(equalToConstant: 120)
        imageWidthC = container.widthAnchor.constraint(equalToConstant: Self.maxImageWidth)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            imageWidthC,
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.imageVInset),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.imageVInset),
            imageHeightC,
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 10),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            captionLabel.topAnchor.constraint(equalTo: container.bottomAnchor, constant: Self.captionGap),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(reference: PiAgentTranscriptImageReference, caption: String, width: CGFloat, style: DisplayStyle = .inline) {
        popover?.close()
        popover = nil
        self.reference = reference
        self.caption = caption.isEmpty ? reference.name : caption
        self.displayStyle = style
        let thumbnailWidth = Self.thumbnailWidth(for: width, style: style)
        imageWidthC.constant = thumbnailWidth
        imageHeightC.constant = Self.imageHeight(reference: reference, width: thumbnailWidth, style: style)
        captionLabel.stringValue = self.caption
        toolTip = reference.source ?? reference.remoteURL ?? reference.localPath ?? reference.name
        imageView.image = reference.localPath.flatMap { TranscriptImageLoader.thumbnailImage(at: URL(fileURLWithPath: $0)) }
        imageView.isHidden = imageView.image == nil
        placeholder.isHidden = imageView.image != nil
        placeholder.stringValue = reference.isRemotePlaceholder ? "Downloading image…" : "Preview unavailable"
        buildMenu()
        applyColors()
    }

    static func measuredHeight(reference: PiAgentTranscriptImageReference, width: CGFloat, style: DisplayStyle = .inline) -> CGFloat {
        let font = NativeTranscriptFont.caption2()
        let imageContentHeight = imageHeight(reference: reference, width: thumbnailWidth(for: width, style: style), style: style)
        let containerHeight = imageContentHeight + imageVInset * 2
        return containerHeight + captionGap + ceil(font.ascender - font.descender + font.leading)
    }


    private static func thumbnailWidth(for width: CGFloat, style: DisplayStyle) -> CGFloat {
        switch style {
        case .inline: return max(96, min(maxImageWidth, width))
        case .tile: return tileWidth
        }
    }

    private static func imageHeight(reference: PiAgentTranscriptImageReference, width: CGFloat, style: DisplayStyle) -> CGFloat {
        if style == .tile { return tileImageHeight }
        guard let path = reference.localPath,
              let image = TranscriptImageLoader.thumbnailImage(at: URL(fileURLWithPath: path)),
              image.size.width > 0 else { return 96 }
        return min(maxImageHeight, max(minImageHeight, width * image.size.height / image.size.width))
    }

    override var intrinsicContentSize: NSSize {
        guard let reference else { return NSSize(width: NSView.noIntrinsicMetric, height: 120) }
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.measuredHeight(reference: reference, width: max(1, bounds.width), style: displayStyle))
    }

    override func layout() {
        super.layout()
        if let reference {
            let thumbnailWidth = Self.thumbnailWidth(for: max(1, bounds.width), style: displayStyle)
            imageWidthC.constant = thumbnailWidth
            imageHeightC.constant = Self.imageHeight(reference: reference, width: thumbnailWidth, style: displayStyle)
        }
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            container.layer?.borderColor = AppTheme.ns(AppTheme.contentStroke).cgColor
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        if reference?.localPath != nil {
            menu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Copy Path", action: #selector(copyPath), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Source", action: #selector(copySource), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        self.menu = menu
    }

    @objc private func openPreview() {
        guard let reference, reference.localPath != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PiAgentTranscriptImagePopoverController(reference: reference, caption: caption)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    @objc private func revealInFinder() {
        guard let path = reference?.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyPath() {
        let value = reference?.localPath ?? reference?.remoteURL ?? reference?.source ?? ""
        copy(value)
    }

    @objc private func copySource() {
        let value = reference?.source ?? reference?.remoteURL ?? reference?.localPath ?? ""
        copy(value)
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private final class PiAgentTranscriptImagePopoverController: NSViewController {
    private let reference: PiAgentTranscriptImageReference
    private let caption: String

    init(reference: PiAgentTranscriptImageReference, caption: String) {
        self.reference = reference
        self.caption = caption
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        root.addSubview(stack)

        if let path = reference.localPath, let image = TranscriptImageLoader.previewImage(at: URL(fileURLWithPath: path)) {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyDown
            let nativeWidth = max(1, image.size.width)
            let nativeHeight = max(1, image.size.height)
            let scale = min(1, min(760 / nativeWidth, 560 / nativeHeight))
            let width = ceil(nativeWidth * scale)
            let height = ceil(nativeHeight * scale)
            imageView.widthAnchor.constraint(equalToConstant: width).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: height).isActive = true
            stack.addArrangedSubview(imageView)
        }
        let label = NSTextField(labelWithString: caption.isEmpty ? reference.name : caption)
        label.font = NativeTranscriptFont.caption()
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12)
        ])
        view = root
    }
}

/// A full-width transcript row: a sized, role-tinted card plus hover-revealed
/// glass copy/fork buttons in the gutter. Self-measures via
/// `measuredHeight(forWidth:)`; the owning cell adds the row insets.
final class PiAgentNativeBubbleView: NSView, PiAgentNativeRowContent {
    /// The bubble proper — rounded chrome drawn by its own layer; holds the
    /// header + markdown. Sized to `replyCap` / hugged width and aligned left
    /// (replies) or right (questions). The buttons live OUTSIDE it.
    private let cardView = NSView()
    private let iconView = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let prefixLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private var markdownContainers: [NativeMarkdownTextContainer] = []
    private var markdownAppliers: [MarkdownSourceApplier] = []

    // Hover-revealed copy (+ fork) buttons, real Liquid Glass via NSGlassEffectView.
    // The glyphs are NSImageViews (not NSButtons) so we can drive the SF Symbol
    // replace transition (doc.on.doc → checkmark) exactly like SwiftUI's
    // .contentTransition(.symbolEffect(.replace)); clicks come via gestures.
    private let buttonStack = NSStackView()
    private let copyGlass = NSGlassEffectView()
    private let copyIcon = NSImageView()
    private let forkGlass = NSGlassEffectView()
    private let forkIcon = NSImageView()
    private let rerunGlass = NSGlassEffectView()
    private let rerunIcon = NSImageView()
    private var copiedResetWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    private var payload: NativeBubblePayload?

    /// Bubbles have fixed height per content; never fired (satisfies the protocol).
    var onIntrinsicHeightChange: (() -> Void)?

    private let headerSpacing: CGFloat = 8
    private let prefixSpacing: CGFloat = 6
    /// Gap between the card edge and the nearest button, matching the SwiftUI
    /// overlay (button offset 38 = 28pt button + 10pt gap).
    private let gutterGap: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = AppTheme.Chat.bubbleCornerRadius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.borderWidth = 1
        cardView.layer?.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
            "transform": NSNull()
        ]
        addSubview(cardView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        NativeTranscriptFont.configureHeaderLabel(headerLabel)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.font = NSFont.systemFont(ofSize: AppTheme.Font.captionSize, weight: .semibold)
        prefixLabel.textColor = .secondaryLabelColor
        prefixLabel.isHidden = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 8
        contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cardView.addSubview(iconView)
        cardView.addSubview(headerLabel)
        cardView.addSubview(prefixLabel)
        cardView.addSubview(contentStack)

        setupButtons()
        buildConstraints()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Fonts

    /// The shared transcript header font (footnote semibold, width-expanded) —
    /// every card + bubble title routes through one definition.
    static var headerFont: NSFont { NativeTranscriptFont.header }

    // MARK: Layout

    private var hPad: CGFloat { (payload?.isThreadChild ?? false) ? AppTheme.Chat.bubbleChildHPadding : AppTheme.Chat.bubbleHPadding }
    private var vPad: CGFloat { (payload?.isThreadChild ?? false) ? AppTheme.Chat.bubbleChildVPadding : AppTheme.Chat.bubbleVPadding }

    // cardView placement / size — a fixed width plus a SINGLE, never-toggled
    // leading constraint. Its constant is set once in configure() from the known
    // row-width param: replies → 0 (column edge), questions → width − cardWidth
    // (right-aligned). It anchors to the cell's leading edge (always x=0, stable
    // regardless of when the live cell width resolves) so the card lands on the
    // correct side on the first layout. Using ONE constraint (no trailing pin to
    // toggle) makes over-constraint — and the 0↔309 flip it caused — impossible.
    private var cardWidthC: NSLayoutConstraint!
    private var cardLeadingC: NSLayoutConstraint!
    // inner content (pinned to cardView)
    private var iconLeadingC: NSLayoutConstraint!
    private var iconTopC: NSLayoutConstraint!
    private var contentLeadingC: NSLayoutConstraint!
    private var contentTrailingC: NSLayoutConstraint!
    private var contentBottomC: NSLayoutConstraint!
    private var contentTopC: NSLayoutConstraint!
    private var prefixTopC: NSLayoutConstraint!
    private var prefixLeadingC: NSLayoutConstraint!
    private var headerTrailingC: NSLayoutConstraint!

    private func buildConstraints() {
        cardWidthC = cardView.widthAnchor.constraint(equalToConstant: 100)
        cardLeadingC = cardView.leadingAnchor.constraint(equalTo: leadingAnchor)

        iconLeadingC = iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad)
        iconTopC = iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: vPad)
        headerTrailingC = headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -hPad)
        prefixLeadingC = prefixLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad)
        prefixTopC = prefixLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
        contentLeadingC = contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: hPad)
        contentTrailingC = contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -hPad)
        contentBottomC = contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -vPad)
        // The cell imposes a fixed height (NSView-Encapsulated-Layout-Height). If a
        // measured height is even 1pt short of the content's required intrinsic
        // height, that fixed height vs. the required content height is unsatisfiable
        // and AppKit logs a constraint-conflict storm. Let this bottom pin yield
        // (just below required) so the fixed cell height always wins gracefully.
        contentBottomC.priority = NSLayoutConstraint.Priority(999)
        contentTopC = contentStack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidthC,
            iconLeadingC, iconTopC,
            iconView.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            headerLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            headerLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerTrailingC,
            prefixLeadingC,
            contentLeadingC, contentTrailingC, contentTopC, contentBottomC
        ])
        // The one and only horizontal placement constraint. Always active; its
        // constant is set per-configure (0 for replies, width−cardWidth for
        // right-aligned questions).
        cardLeadingC.isActive = true
    }



    override func layout() {
        super.layout()
        // Numeric bottom-crop detector (debug-only; the re-measure is too costly
        // for the production layout path). With TranscriptHoverDebug on, if the
        // rendered markdown needs more height than it was allocated, log the
        // exact deficit to /tmp so the automated harness can read it.
        guard Self.hoverDebug else { return }
        let allocated = contentStack.bounds.height
        guard allocated > 1 else { return }
        let needed = contentStack.fittingSize.height
        let deficit = needed - allocated
        guard deficit > 0.5 else { return }
        let line = "role=\(String(describing: payload?.role)) needed=\(Int(needed)) "
            + "allocated=\(Int(allocated)) deficit=\(Int(deficit)) "
            + "cardH=\(Int(cardView.bounds.height)) vPad=\(Int(vPad)) ⚠️CROP\n"
        if let d = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/agentdeck-mdclip.txt")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: url) }
        }
    }

    // MARK: Card sizing

    private func cardWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        guard let payload else { return rowWidth }
        if payload.isUserHugged {
            return max(1, min(rowWidth, PiAgentBubbleWidth.huggedUser(text: payload.markdownSource, paneWidth: rowWidth)))
        }
        return max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
    }

    // MARK: Configure

    func configure(payload: NativeBubblePayload, width rowWidth: CGFloat) {
        self.payload = payload
        cardView.layer?.removeAllAnimations()

        // Padding can change with style; keep constraints in sync.
        iconLeadingC.constant = hPad
        iconTopC.constant = vPad
        headerTrailingC.constant = -hPad
        prefixLeadingC.constant = hPad
        contentLeadingC.constant = hPad
        contentTrailingC.constant = -hPad
        contentBottomC.constant = -vPad

        // Fix the card width and its single leading-offset constant from the
        // KNOWN row-width param (not a live frame): questions sit right-aligned
        // (leading = width − cardWidth), replies at the column edge (0). One
        // always-active constraint anchored to the stable cell-leading edge — no
        // second pin to over-constrain, no bounds.width timing, no 0↔309 flip.
        let cardW = cardWidth(forRowWidth: rowWidth)
        cardWidthC.constant = cardW
        cardLeadingC.constant = payload.isUserHugged ? max(0, rowWidth - cardW) : 0
        // Ensure the new constant is applied before the (possibly recycled) cell
        // next draws — viewWillDraw lays out only if the subtree is dirty.
        needsLayout = true

        // Header — the glyph is tinted to the bubble's own role color in
        // applyChromeColors(); the title text keeps its role header color.
        headerLabel.stringValue = payload.headerTitle
        if let symbol = payload.iconSymbol {
            iconView.image = NativeTranscriptFont.headerIcon(symbol)
        } else {
            iconView.image = NSImage(named: "pi")
            iconView.image?.isTemplate = true
        }

        // Optional body prefix (e.g. "Reasoning").
        if let prefix = payload.bodyPrefix, !prefix.isEmpty {
            prefixLabel.stringValue = prefix
            prefixLabel.isHidden = false
            contentTopC.isActive = false
            prefixTopC.isActive = true
            contentTopC = contentStack.topAnchor.constraint(equalTo: prefixLabel.bottomAnchor, constant: prefixSpacing)
            contentTopC.isActive = true
        } else {
            prefixLabel.isHidden = true
            prefixTopC.isActive = false
            contentTopC.isActive = false
            contentTopC = contentStack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: headerSpacing)
            contentTopC.isActive = true
        }

        // Body — split around image tokens so attachments appear near their source.
        configureContentBlocks(payload: payload, innerWidth: max(1, cardW - hPad * 2))

        // Buttons: presence, order, and which gutter they float in.
        forkGlass.isHidden = payload.fork == nil
        rerunGlass.isHidden = payload.fork == nil
        configureButtonStack(side: payload.copySide, hasFork: payload.fork != nil)

        applyChromeColors()
    }

    /// Apply pending Auto Layout changes without allowing layer-backed views to
    /// animate from a recycled position. The constraints can be correct while a
    /// backing layer still paints an old presentation position for a frame; this
    /// keeps the first drawn frame and hover reveal in the final geometry.
    func settleLayoutImmediately() {
        cardView.layer?.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSubtreeIfNeeded()
        cardView.layoutSubtreeIfNeeded()
        buttonStack.layoutSubtreeIfNeeded()
        CATransaction.commit()
        cardView.layer?.removeAllAnimations()
    }

    // MARK: Chrome colors

    private var headerColor: NSColor {
        guard let role = payload?.role else { return .labelColor }
        return role == .assistant ? AppTheme.ns(AppTheme.piLogo) : .labelColor
    }

    private func roleBaseColor(_ role: NativeBubblePayload.Role) -> NSColor {
        switch role {
        case .user: return AppTheme.ns(AppTheme.roleUser)
        case .assistant: return AppTheme.ns(AppTheme.brandAccent)
        case .thinking: return AppTheme.ns(AppTheme.roleThinking)
        case .tool: return AppTheme.ns(AppTheme.roleTool)
        case .error: return AppTheme.ns(AppTheme.roleError)
        case .stderr: return AppTheme.ns(AppTheme.roleStderr)
        case .status, .raw: return AppTheme.ns(AppTheme.roleStatus)
        }
    }

    private func applyChromeColors() {
        guard let payload else { return }
        let neutral = payload.role == .status || payload.role == .raw
        let base = roleBaseColor(payload.role)
        let fillOpacity: CGFloat = payload.isThreadChild ? AppTheme.roleFillOpacity : AppTheme.roleFillStrongOpacity
        let fill: NSColor = neutral
            ? AppTheme.ns(AppTheme.contentSubtleFill).withAlphaComponent(0.7)
            : base.withAlphaComponent(fillOpacity)
        let stroke: NSColor = neutral
            ? AppTheme.ns(AppTheme.contentStroke)
            : base.withAlphaComponent(AppTheme.roleStrokeOpacity)

        // Resolve through the view's effective appearance so light/dark is exact.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cardView.layer?.backgroundColor = fill.cgColor
            cardView.layer?.borderColor = stroke.cgColor
        }
        // The glyph takes the bubble's own color (the same `base` driving the
        // fill/stroke); neutral status/raw rows get a muted glyph to match their
        // neutral fill.
        iconView.contentTintColor = neutral ? AppTheme.ns(AppTheme.mutedText) : base
        headerLabel.textColor = headerColor
        // Glass button glyphs use the primary label color — matches the SwiftUI
        // AppCopyIconButton / AppForkIconButton (.foregroundStyle(.primary)).
        copyIcon.contentTintColor = .labelColor
        forkIcon.contentTintColor = .labelColor
        rerunIcon.contentTintColor = .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
    }

    // MARK: Height

    /// Row height for a given full row width (excludes the cell's row insets).
    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let inner = max(1, cardWidth(forRowWidth: rowWidth) - hPad * 2)
        var h = vPad + headerRowHeight() + headerSpacing
        if let prefix = payload?.bodyPrefix, !prefix.isEmpty {
            h += ceil(prefixLabel.intrinsicContentSize.height) + prefixSpacing
        }
        let presentation = imagePresentation()
        let blocks = Self.contentBlocks(source: presentation.source, references: presentation.references)
        var isFirst = true
        var markdownIndex = 0
        for block in blocks {
            let blockHeight: CGFloat
            switch block {
            case .markdown(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let container = markdownContainer(at: markdownIndex)
                markdownApplier(at: markdownIndex).apply(source: text, to: container)
                markdownIndex += 1
                blockHeight = container.measureHeight(forWidth: inner)
            case .image(let reference, _):
                blockHeight = PiAgentNativeTranscriptImageAttachmentView.measuredHeight(reference: reference, width: inner)
            }
            if !isFirst { h += contentStack.spacing }
            h += blockHeight
            isFirst = false
        }
        h += vPad
        return ceil(h)
    }

    private func headerRowHeight() -> CGFloat {
        NativeTranscriptFont.headerIconSize
    }

    private enum ContentBlock {
        case markdown(String)
        case image(PiAgentTranscriptImageReference, caption: String)
    }

    private func configureContentBlocks(payload: NativeBubblePayload, innerWidth: CGFloat) {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let presentation = imagePresentation()
        let blocks = Self.contentBlocks(source: presentation.source, references: presentation.references)
        var markdownIndex = 0
        for block in blocks {
            switch block {
            case .markdown(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let container = markdownContainer(at: markdownIndex)
                markdownApplier(at: markdownIndex).apply(source: text, to: container)
                markdownIndex += 1
                contentStack.addArrangedSubview(container)
            case .image(let reference, let caption):
                let image = PiAgentNativeTranscriptImageAttachmentView()
                image.configure(reference: reference, caption: caption, width: innerWidth)
                contentStack.addArrangedSubview(image)
            }
        }
        while markdownContainers.count > markdownIndex {
            markdownAppliers.removeLast().cancel()
            markdownContainers.removeLast()
        }
    }

    private func imagePresentation() -> (source: String, references: [PiAgentTranscriptImageReference]) {
        guard let payload else { return ("", []) }
        return (
            PiAgentTranscriptImagePresentation.projectedSource(
                payload.markdownSource,
                references: payload.imageReferences,
                showImages: payload.showInlineImagePreviews
            ),
            payload.showInlineImagePreviews ? payload.imageReferences : []
        )
    }

    private func markdownContainer(at index: Int) -> NativeMarkdownTextContainer {
        while markdownContainers.count <= index {
            let container = NativeMarkdownTextContainer()
            container.setContentHuggingPriority(.defaultLow, for: .horizontal)
            container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            markdownContainers.append(container)
        }
        return markdownContainers[index]
    }

    private func markdownApplier(at index: Int) -> MarkdownSourceApplier {
        while markdownAppliers.count <= index { markdownAppliers.append(MarkdownSourceApplier()) }
        return markdownAppliers[index]
    }

    private static func contentBlocks(source: String, references: [PiAgentTranscriptImageReference]) -> [ContentBlock] {
        guard !references.isEmpty else { return [.markdown(source)] }
        let tokens = imageTokens(in: source)
        var blocks: [ContentBlock] = []
        var used = Set<UUID>()
        var cursor = source.startIndex
        for token in tokens {
            guard let reference = references.first(where: { ref in
                !used.contains(ref.id) && (
                    ref.source == token.src
                        || (ref.source == "data-url" && token.src.lowercased().hasPrefix("data:image/"))
                        || ref.remoteURL == token.src
                        || ref.localPath == token.src
                        || ref.name == URL(fileURLWithPath: token.src).lastPathComponent
                )
            }) else { continue }
            if cursor < token.range.lowerBound { blocks.append(.markdown(String(source[cursor..<token.range.lowerBound]))) }
            used.insert(reference.id)
            blocks.append(.image(reference, caption: token.caption.isEmpty ? reference.name : token.caption))
            cursor = token.range.upperBound
        }
        if cursor < source.endIndex { blocks.append(.markdown(String(source[cursor...]))) }
        for reference in references where !used.contains(reference.id) {
            blocks.append(.image(reference, caption: reference.name))
        }
        return blocks.isEmpty ? [.markdown(source)] : blocks
    }

    private static func imageTokens(in source: String) -> [(range: Range<String.Index>, src: String, caption: String)] {
        let patterns: [(String, Int, Int?)] = [
            (#"!\[([^\]]*)\]\(([^\s\)]+)(?:\s+\"[^\"]*\")?\)"#, 2, 1),
            (#"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"'][^>]*>"#, 1, nil),
            (#"data:image/[^\s\)>\"']+"#, 0, nil),
            (#"https://[^\s\)>\"']+"#, 0, nil)
        ]
        var matches: [(range: Range<String.Index>, src: String, caption: String)] = []
        let protectedRanges = plainImageURLProtectedRanges(in: source)
        for (pattern, srcGroup, captionGroup) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: nsRange) {
                let isPlainURLPattern = srcGroup == 0
                guard (!isPlainURLPattern || !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })),
                      let full = Range(match.range, in: source),
                      let srcRange = Range(match.range(at: srcGroup), in: source) else { continue }
                var caption = ""
                if let captionGroup, match.range(at: captionGroup).location != NSNotFound, let capRange = Range(match.range(at: captionGroup), in: source) {
                    caption = String(source[capRange])
                } else if let alt = htmlAttribute("alt", in: String(source[full])) {
                    caption = alt
                }
                matches.append((full, String(source[srcRange]), caption))
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func plainImageURLProtectedRanges(in source: String) -> [NSRange] {
        PiAgentTranscriptImagePresentation.protectedRanges(in: source)
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\#(name)=[\"']([^\"']*)[\"']"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    // MARK: Copy / fork buttons (Liquid Glass)

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func glassIcon(_ glass: NSGlassEffectView, _ icon: NSImageView, symbol: String, help: String, action: Selector) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = AppTheme.Chat.panelCornerRadius
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = Self.symbolImage(symbol)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleNone
        icon.toolTip = help
        glass.contentView = icon
        glass.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: action))
        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: 28),
            glass.heightAnchor.constraint(equalToConstant: 28),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupButtons() {
        glassIcon(copyGlass, copyIcon, symbol: "doc.on.doc", help: "Copy message", action: #selector(copyTapped))
        glassIcon(forkGlass, forkIcon, symbol: "arrow.trianglehead.branch", help: "Fork session…", action: #selector(forkTapped))
        glassIcon(rerunGlass, rerunIcon, symbol: "arrow.clockwise", help: "Re-run from here (rewinds the conversation and resends this message)", action: #selector(rerunTapped))
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.alphaValue = 0
        addSubview(buttonStack)
        // Vertically centered on the card — matches the SwiftUI overlay(alignment:
        // .leading/.trailing), which centers the buttons on the card's edge.
        buttonStackCenterC = buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        buttonStackCenterC.isActive = true
    }

    private var buttonStackCenterC: NSLayoutConstraint!
    private var buttonStackSideC: NSLayoutConstraint?

    /// Rebuilds the button stack order/edge and floats it in the gutter beside
    /// the card: leading copy → [rerun][fork][copy] to the LEFT of the card;
    /// trailing copy → [copy][fork][rerun] to the RIGHT (rerun always outboard).
    private func configureButtonStack(side: NativeBubblePayload.CopySide, hasFork: Bool) {
        buttonStack.arrangedSubviews.forEach { buttonStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch side {
        case .leading:
            if hasFork {
                buttonStack.addArrangedSubview(rerunGlass)
                buttonStack.addArrangedSubview(forkGlass)
            }
            buttonStack.addArrangedSubview(copyGlass)
        case .trailing:
            buttonStack.addArrangedSubview(copyGlass)
            if hasFork {
                buttonStack.addArrangedSubview(forkGlass)
                buttonStack.addArrangedSubview(rerunGlass)
            }
        }
        buttonStackSideC?.isActive = false
        switch side {
        case .leading:
            // Float to the LEFT of the (right-aligned) card.
            buttonStackSideC = buttonStack.trailingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: -gutterGap)
        case .trailing:
            // Float to the RIGHT of the (left-aligned) card.
            buttonStackSideC = buttonStack.leadingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: gutterGap)
        }
        buttonStackSideC?.isActive = true
    }

    @objc private func copyTapped() {
        guard let text = payload?.copyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Animate doc.on.doc → checkmark and back after ~1.1s, matching the
        // SwiftUI AppCopyIconButton's .symbolEffect(.replace) + copied feedback.
        copiedResetWork?.cancel()
        if let checkmark = Self.symbolImage("checkmark") {
            copyIcon.setSymbolImage(checkmark, contentTransition: .replace)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let doc = Self.symbolImage("doc.on.doc") else { return }
            self.copyIcon.setSymbolImage(doc, contentTransition: .replace)
        }
        copiedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    @objc private func forkTapped() {
        guard let fork = payload?.fork else { return }
        if fork.agentOptions.isEmpty {
            fork.onForkSession()
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let piItem = NSMenuItem(title: "Fork as Pi session", action: #selector(forkPiSessionSelected), keyEquivalent: "")
        piItem.target = self
        menu.addItem(piItem)
        let parent = NSMenuItem(title: "Fork as 1:1 agent chat…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, option) in fork.agentOptions.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(forkAgentSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = !option.isDisabled
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: forkGlass.bounds.height + 2), in: forkGlass)
    }

    @objc private func rerunTapped() { payload?.fork?.onRerun() }

    @objc private func forkPiSessionSelected() { payload?.fork?.onForkSession() }

    @objc private func forkAgentSelected(_ item: NSMenuItem) {
        guard let options = payload?.fork?.agentOptions, item.tag >= 0, item.tag < options.count else { return }
        options[item.tag].action()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { detectHoverMove("enter") { self.setButtonsVisible(true) } }
    override func mouseExited(with event: NSEvent) { detectHoverMove("exit") { self.setButtonsVisible(false) } }

    /// Movement detector for the "You bubble shifts on hover" bug. Records the
    /// card's x before the hover transition, re-checks after layout settles AND
    /// again after the reveal animation, and if the card actually moved writes a
    /// loud line to `/tmp/agentdeck-hover-shift.txt` (+ the OS log) naming the
    /// before→after x and the geometry, so a single hover tells us definitively
    /// whether it moves and which value changed. Always active for question
    /// bubbles (rare event, low noise); set `TranscriptHoverDebug` to also log
    /// the stable (no-move) cases as confirmation.
    private static let hoverLog = Logger(subsystem: "streetcoding.agent-deck", category: "HoverShift")
    private static let hoverDebug: Bool = {
#if DEBUG
        UserDefaults.standard.bool(forKey: "TranscriptHoverDebug")
#else
        false
#endif
    }()

    private func detectHoverMove(_ phase: String, _ action: () -> Void) {
        // Fast path: hover is a hot interaction. `action` (setButtonsVisible)
        // already settles layout, so do nothing else unless the diagnostic is
        // explicitly enabled. The diagnostic below forces a second synchronous
        // layout, schedules an async re-check, and writes to disk on the main
        // thread — none of which belongs on every hover.
        guard Self.hoverDebug else { action(); return }
        let before = cardView.frame.minX
        action()
        settleLayoutImmediately()
        report(phase: "\(phase)-sync", before: before, after: cardView.frame.minX)
        // The reveal animates alpha (0.15s); re-check after it in case anything
        // shifts the card asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.report(phase: "\(phase)-async", before: before, after: self.cardView.frame.minX)
        }
    }

    private func report(phase: String, before: CGFloat, after: CGFloat) {
        let moved = abs(after - before) > 0.5
        let bf = buttonStack.frame
        let cf = cardView.frame
        let layerFrame = cardView.layer?.frame ?? .zero
        let presentationFrame = cardView.layer?.presentation()?.frame ?? layerFrame
        let layerMoved = abs(presentationFrame.minX - cf.minX) > 0.5
        // Questions float buttons LEFT of the card; replies float them RIGHT.
        // Either way the button stack must not overlap the card.
        let overCard = (payload?.copySide == .leading)
            ? bf.maxX > cf.minX + 1
            : bf.minX < cf.maxX - 1
        guard moved || layerMoved || overCard || Self.hoverDebug else { return }
        let tag = moved ? "⚠️ MOVED" : (layerMoved ? "⚠️ LAYER-MOVED" : "stable")
        let line = "[\(phase)] \(tag) cardMinX \(Int(before))→\(Int(after)) "
            + "role=\(String(describing: payload?.role)) "
            + "hugged=\(payload?.isUserHugged ?? false) side=\(String(describing: payload?.copySide)) "
            + "bubbleW=\(Int(bounds.width)) cardW=\(Int(cardWidthC.constant)) leading=\(Int(cardLeadingC.constant)) "
            + "layerX=\(Int(layerFrame.minX)) presentationX=\(Int(presentationFrame.minX)) "
            + "card=[\(Int(cf.minX)),\(Int(cf.maxX))] buttons=[\(Int(bf.minX)),\(Int(bf.maxX))] "
            + (overCard ? "⚠️BUTTONS-OVER-CARD" : "buttons-in-gutter") + "\n"
        if moved || layerMoved {
            Self.hoverLog.error("YOU-BUBBLE-HOVER \(line, privacy: .public)")
        } else {
            Self.hoverLog.log("YOU-BUBBLE-HOVER \(line, privacy: .public)")
        }
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/agentdeck-hover-shift.txt")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Force the hover buttons visible (used by the offscreen preview harness).
    func previewRevealButtons() { buttonStack.alphaValue = 1 }

    private func setButtonsVisible(_ visible: Bool) {
        // Settle the stack's frame BEFORE animating opacity, so the first reveal
        // fades in place instead of sliding in from x=0 (the "jumps on hover" bug).
        settleLayoutImmediately()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = false
            buttonStack.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Teardown

    func prepareForReuseIfNeeded() {
        markdownAppliers.forEach { $0.cancel() }
    }
}

private extension NSFont {
    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
