import AppKit

/// AppKit fonts for the native transcript rows, sized from the design-system
/// tokens (`AppTheme.Font.*Size`) so every card follows one source of truth.
/// SwiftUI's `.weight(.semibold)` is the SF semibold face — NOT NSFontManager's
/// `.boldFontMask` (heavier, `.bold`); use these for parity.
enum NativeTranscriptFont {
    static let bodySize = AppTheme.Font.bodySize
    static let calloutSize = AppTheme.Font.calloutSize
    static let footnoteSize = AppTheme.Font.footnoteSize
    static let captionSize = AppTheme.Font.captionSize
    static let caption2Size = AppTheme.Font.caption2Size

    static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: bodySize, weight: weight) }
    static func callout(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: calloutSize, weight: weight) }
    static func footnote(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: footnoteSize, weight: weight) }
    static func caption(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: captionSize, weight: weight) }
    static func caption2(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: caption2Size, weight: weight) }
    static func captionMono(_ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: captionSize, weight: weight) }

    // MARK: Shared card / bubble header

    /// The one header title used by EVERY transcript row — message bubbles and
    /// chrome cards alike: footnote-sized SF semibold, slightly width-expanded to
    /// match SwiftUI's `.weight(.semibold)` header. Keep all card titles on this
    /// so the transcript reads as a single scale rather than two competing ones.
    static let header: NSFont = {
        let semibold = NSFont.systemFont(ofSize: footnoteSize, weight: .semibold)
        let merged = semibold.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.width: 0.2]
        ])
        return NSFont(descriptor: merged, size: footnoteSize) ?? semibold
    }()

    /// Side length of the glyph box that sits beside `header` (matches the
    /// message bubbles' 16pt icon).
    static let headerIconSize: CGFloat = 16

    /// A header glyph rendered at its natural ~15pt size (never upscaled to fill
    /// the box) at the shared `AppTheme.cardSymbolScale`. Returned as a template
    /// image so the caller flat-tints it to match its container's color.
    static func headerIcon(_ name: String, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: headerIconSize - 1, weight: weight, scale: AppTheme.cardSymbolScale))
    }
}

// Native (pure AppKit) rendering for the non-bubble transcript rows — status,
// error, retry, tool groups, and the chrome cards. These share a card scaffold
// (`PiAgentNativeCardRowView`) that mirrors the SwiftUI `ThreadMessageRow`: a
// role-tinted rounded card placed in the reply column (or full width / hugged),
// with an optional hover-revealed glass copy button floating in the gutter and
// self-measuring height. Subclasses supply only the card's inner content.

// MARK: - Rounded card surface

/// A layer-backed rounded-rect surface (fill + 1pt stroke) that recolors itself
/// on light/dark changes. Mirrors `RoundedRectangle(cornerRadius:style:.continuous)`.
final class NativeCardSurface: NSView {
    var fillColor: NSColor = .clear { didSet { applyColors() } }
    var strokeColor: NSColor = .clear { didSet { applyColors() } }
    var cardCornerRadius: CGFloat = 16 {
        didSet { layer?.cornerRadius = cardCornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cardCornerRadius
        layer?.borderWidth = 1
        // Disable implicit layer animations so a recycled cell never paints the
        // previous occupant's geometry/color for a frame (the cell-reuse "snap").
        layer?.actions = [
            "bounds": NSNull(), "frame": NSNull(),
            "position": NSNull(), "transform": NSNull(),
            "backgroundColor": NSNull(), "borderColor": NSNull()
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
            layer?.borderColor = strokeColor.cgColor
        }
    }
}

// MARK: - Card row scaffold

/// Base for native transcript card rows. Owns the rounded card chrome, places it
/// in the reply column (or full width / right-hugged), floats an optional
/// hover-revealed glass copy button in the gutter, and self-measures. Subclasses
/// build their content inside `cardContent` and report its height via
/// `contentHeight(forInnerWidth:)`.
class PiAgentNativeCardRowView: NSView, PiAgentNativeRowContent {
    enum Placement { case leftAtCap, fullWidth }

    let cardSurface = NativeCardSurface()
    /// Subclasses add their views here (inside the card padding).
    let cardContent = NSView()

    // Hover copy button — real Liquid Glass, matching the SwiftUI overlay.
    private let copyGlass = NSGlassEffectView()
    private let copyIcon = NSImageView()
    private var copiedResetWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var copyTextValue: String = ""
    private var showsCopy = false

    var hPad: CGFloat = 14
    var vPad: CGFloat = 11
    var placement: Placement = .leftAtCap
    var onIntrinsicHeightChange: (() -> Void)?

    /// Subclasses call this after a content change that alters height (e.g. an
    /// inline expand) so the owning cell re-measures and the table re-tiles.
    func notifyContentHeightChanged() {
        needsLayout = true
        onIntrinsicHeightChange?()
    }

    private var cardWidthC: NSLayoutConstraint!
    private var cardLeadingC: NSLayoutConstraint!
    private var contentTopC: NSLayoutConstraint!
    private var contentLeadingC: NSLayoutConstraint!
    private var contentTrailingC: NSLayoutConstraint!
    private var contentBottomC: NSLayoutConstraint!
    private let gutterGap: CGFloat = 10

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        cardSurface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardSurface)

        cardContent.translatesAutoresizingMaskIntoConstraints = false
        cardSurface.addSubview(cardContent)

        cardWidthC = cardSurface.widthAnchor.constraint(equalToConstant: 100)
        cardLeadingC = cardSurface.leadingAnchor.constraint(equalTo: leadingAnchor)
        contentTopC = cardContent.topAnchor.constraint(equalTo: cardSurface.topAnchor, constant: vPad)
        contentLeadingC = cardContent.leadingAnchor.constraint(equalTo: cardSurface.leadingAnchor, constant: hPad)
        contentTrailingC = cardContent.trailingAnchor.constraint(equalTo: cardSurface.trailingAnchor, constant: -hPad)
        contentBottomC = cardContent.bottomAnchor.constraint(equalTo: cardSurface.bottomAnchor, constant: -vPad)
        // Yield (just below required) so the cell's fixed height always wins over
        // the content's required height without a constraint-conflict storm.
        contentBottomC.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            cardSurface.topAnchor.constraint(equalTo: topAnchor),
            cardSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardWidthC, cardLeadingC,
            contentTopC, contentLeadingC, contentTrailingC, contentBottomC
        ])

        setupCopyButton()
        commonSetup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Subclass hook: build the content views inside `cardContent` once.
    func commonSetup() {}

    /// Subclass hook: height of the content for a given inner (card minus hPad*2)
    /// width. EXCLUDES the card's vertical padding.
    func contentHeight(forInnerWidth innerWidth: CGFloat) -> CGFloat { 0 }

    // MARK: Configure (call from subclass configure)

    /// Apply the card chrome colors, padding, placement, and copy text. Subclasses
    /// call this from their own `configure(...)` after populating content.
    func applyCard(
        fill: NSColor,
        stroke: NSColor,
        cornerRadius: CGFloat = 16,
        hPad: CGFloat = 14,
        vPad: CGFloat = 11,
        placement: Placement = .leftAtCap,
        copyText: String? = nil,
        width rowWidth: CGFloat
    ) {
        self.hPad = hPad
        self.vPad = vPad
        self.placement = placement
        cardSurface.cardCornerRadius = cornerRadius
        cardSurface.fillColor = fill
        cardSurface.strokeColor = stroke
        contentTopC.constant = vPad
        contentLeadingC.constant = hPad
        contentTrailingC.constant = -hPad
        contentBottomC.constant = -vPad

        let cardW = cardWidth(forRowWidth: rowWidth)
        cardWidthC.constant = cardW
        cardLeadingC.constant = 0  // both placements anchor at the leading edge

        showsCopy = (copyText?.isEmpty == false)
        copyTextValue = copyText ?? ""
        copyGlass.isHidden = !showsCopy
        needsLayout = true
    }

    private func cardWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        switch placement {
        case .fullWidth: return max(1, rowWidth)
        case .leftAtCap: return max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
        }
    }

    // MARK: Measure

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let cardW = cardWidth(forRowWidth: rowWidth)
        let inner = max(1, cardW - hPad * 2)
        return ceil(vPad + contentHeight(forInnerWidth: inner) + vPad)
    }

    // MARK: Settle (cell-reuse: paint at the final geometry on first draw)

    override func viewWillDraw() {
        settleLayoutImmediately()
        super.viewWillDraw()
    }

    func settleLayoutImmediately() {
        cardSurface.layer?.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSubtreeIfNeeded()
        cardSurface.layoutSubtreeIfNeeded()
        CATransaction.commit()
        cardSurface.layer?.removeAllAnimations()
    }

    // MARK: Hover copy button

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func setupCopyButton() {
        copyGlass.translatesAutoresizingMaskIntoConstraints = false
        copyGlass.cornerRadius = 14
        copyGlass.alphaValue = 0
        copyIcon.translatesAutoresizingMaskIntoConstraints = false
        copyIcon.image = Self.symbolImage("doc.on.doc")
        copyIcon.contentTintColor = .labelColor
        copyIcon.imageScaling = .scaleNone
        copyIcon.toolTip = "Copy message"
        copyGlass.contentView = copyIcon
        copyGlass.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(copyTapped)))
        copyGlass.isHidden = true
        addSubview(copyGlass)
        NSLayoutConstraint.activate([
            copyGlass.widthAnchor.constraint(equalToConstant: 28),
            copyGlass.heightAnchor.constraint(equalToConstant: 28),
            copyIcon.widthAnchor.constraint(equalToConstant: 28),
            copyIcon.heightAnchor.constraint(equalToConstant: 28),
            copyGlass.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Float to the RIGHT of the card (replies/status sit on the left).
            copyGlass.leadingAnchor.constraint(equalTo: cardSurface.trailingAnchor, constant: gutterGap)
        ])
    }

    @objc private func copyTapped() {
        guard !copyTextValue.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyTextValue, forType: .string)
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

    override func mouseEntered(with event: NSEvent) { setCopyVisible(true) }
    override func mouseExited(with event: NSEvent) { setCopyVisible(false) }

    private func setCopyVisible(_ visible: Bool) {
        guard showsCopy else { return }
        settleLayoutImmediately()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = false
            copyGlass.animator().alphaValue = visible ? 1 : 0
        }
    }

    func prepareForReuseIfNeeded() {
        copiedResetWork?.cancel()
        copyGlass.alphaValue = 0
    }
}

// MARK: - Spacer row (bottom scroll anchor)

/// A fixed-height, empty native row (the transcript's bottom scroll anchor).
final class PiAgentNativeSpacerView: NSView, PiAgentNativeRowContent {
    var onIntrinsicHeightChange: (() -> Void)?
    var spacerHeight: CGFloat = 1
    required init() { super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat { spacerHeight }
}

// MARK: - Status / error row (compact)

/// Compact status / error row: icon + title + detail + timestamp, optional copy
/// of a tool error, and prompt-audit buttons. Tapping an error row pops over its
/// detail text. Mirrors `PiAgentStatusTranscriptRow`'s `compactStatusRow`.
final class PiAgentNativeStatusRowView: PiAgentNativeCardRowView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let auditStack = NSStackView()

    private var errorPopoverText: String?
    private var errorPopoverTitle: String = ""
    private var auditActions: [NativeStatusPayload.AuditAction] = []

    override func commonSetup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NativeTranscriptFont.caption(.semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NativeTranscriptFont.caption()
        detailLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NativeTranscriptFont.caption2()
        timeLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        auditStack.translatesAutoresizingMaskIntoConstraints = false
        auditStack.orientation = .horizontal
        auditStack.spacing = 2
        auditStack.setContentHuggingPriority(.required, for: .horizontal)
        auditStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        cardContent.addSubview(iconView)
        cardContent.addSubview(titleLabel)
        cardContent.addSubview(detailLabel)
        cardContent.addSubview(timeLabel)
        cardContent.addSubview(auditStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            iconView.topAnchor.constraint(greaterThanOrEqualTo: cardContent.topAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor),

            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor),

            auditStack.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 6),
            auditStack.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            auditStack.centerYAnchor.constraint(equalTo: cardContent.centerYAnchor),

            cardContent.topAnchor.constraint(equalTo: iconView.topAnchor).withPriority(250)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowTapped)))
    }

    func configure(payload: NativeStatusPayload, width rowWidth: CGFloat) {
        iconView.image = NSImage(systemSymbolName: payload.icon, accessibilityDescription: nil)
        iconView.contentTintColor = payload.iconColor
        titleLabel.stringValue = payload.title
        titleLabel.textColor = .labelColor
        detailLabel.stringValue = payload.detail
        timeLabel.stringValue = payload.timeText
        errorPopoverText = payload.errorPopoverText
        errorPopoverTitle = payload.title

        auditActions = payload.auditActions
        auditStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, action) in auditActions.enumerated() {
            let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.help)?
                .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .semibold))
            let btn = NSButton(image: image ?? NSImage(), target: self, action: #selector(auditTapped(_:)))
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.tag = i
            btn.contentTintColor = AppTheme.ns(AppTheme.mutedText)
            btn.toolTip = action.help
            btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 20).isActive = true
            auditStack.addArrangedSubview(btn)
        }

        let neutral = payload.color
        applyCard(
            fill: neutral.withAlphaComponent(0.08),
            stroke: neutral.withAlphaComponent(0.16),
            cornerRadius: 11,
            hPad: 10, vPad: 7,
            placement: .leftAtCap,
            copyText: payload.copyText,
            width: rowWidth
        )
    }

    override func contentHeight(forInnerWidth innerWidth: CGFloat) -> CGFloat {
        // Single-line row; height is the tallest of the caption labels.
        max(14, ceil(titleLabel.intrinsicContentSize.height))
    }

    @objc private func rowTapped() {
        guard let text = errorPopoverText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PiAgentNativeTextPopoverController(title: errorPopoverTitle, text: text)
        popover.show(relativeTo: cardSurface.bounds, of: cardSurface, preferredEdge: .maxY)
    }

    @objc private func auditTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < auditActions.count else { return }
        let action = auditActions[sender.tag]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PiAgentNativeTextPopoverController(title: action.title, text: action.text())
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

/// Typed payload for a compact status / error row.
struct NativeStatusPayload {
    var icon: String
    var iconColor: NSColor
    var color: NSColor
    var title: String
    var detail: String
    var timeText: String
    var copyText: String?
    var errorPopoverText: String?
    /// Prompt-audit affordances (e.g. "System Prompt Captured" / "Subagent
    /// Started") — trailing icon buttons that pop over their text.
    var auditActions: [AuditAction] = []

    struct AuditAction {
        var symbol: String
        var help: String
        var title: String
        var text: () -> String
    }
}

// MARK: - Status divider row (compaction / git events)

/// Full-width divider row: a line — capsule(icon + label + time) — line. Mirrors
/// `PiAgentStatusTranscriptRow.compactionDivider`.
final class PiAgentNativeStatusDividerView: NSView, PiAgentNativeRowContent {
    private let leftRule = NSView()
    private let rightRule = NSView()
    private let capsule = NSGlassEffectView()
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let labelField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let capsuleStack = NSStackView()
    var onIntrinsicHeightChange: (() -> Void)?

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        for rule in [leftRule, rightRule] {
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.wantsLayer = true
            rule.layer?.backgroundColor = AppTheme.ns(AppTheme.contentStroke).withAlphaComponent(0.9).cgColor
            addSubview(rule)
        }

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = AppTheme.ns(AppTheme.mutedText)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        labelField.font = NativeTranscriptFont.caption(.semibold)
        labelField.textColor = AppTheme.ns(AppTheme.mutedText)
        labelField.lineBreakMode = .byTruncatingTail
        timeField.font = NativeTranscriptFont.caption2()
        timeField.textColor = AppTheme.ns(AppTheme.mutedText)

        capsuleStack.translatesAutoresizingMaskIntoConstraints = false
        capsuleStack.orientation = .horizontal
        capsuleStack.spacing = 7
        capsuleStack.alignment = .centerY
        capsuleStack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        capsuleStack.addArrangedSubview(iconView)
        capsuleStack.addArrangedSubview(spinner)
        capsuleStack.addArrangedSubview(labelField)
        capsuleStack.addArrangedSubview(timeField)

        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.cornerRadius = 13
        capsule.contentView = capsuleStack
        addSubview(capsule)

        NSLayoutConstraint.activate([
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftRule.trailingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: -10),
            leftRule.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftRule.heightAnchor.constraint(equalToConstant: 1),
            rightRule.leadingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: 10),
            rightRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightRule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightRule.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeDividerPayload, width rowWidth: CGFloat) {
        if payload.isSpinning {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = NSImage(systemSymbolName: payload.icon, accessibilityDescription: nil)
        }
        labelField.stringValue = payload.detail
        timeField.stringValue = payload.timeText
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        // Capsule height (icon/label + vertical insets) plus the 4pt outer padding
        // the SwiftUI divider carries above and below.
        let labelH = max(16, ceil(labelField.intrinsicContentSize.height))
        return ceil(labelH + 10 /* capsule v-insets */ + 8 /* outer .vertical 4 */)
    }
}

struct NativeDividerPayload {
    var icon: String
    var detail: String
    var timeText: String
    var isSpinning: Bool
}

// MARK: - Retry row

/// Auto-retry burst row. Mirrors `PiAgentRetryCard`.
final class PiAgentNativeRetryRowView: PiAgentNativeCardRowView {
    private let iconView = NSImageView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private var accentColor: NSColor = .labelColor

    override func commonSetup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        headlineLabel.font = NativeTranscriptFont.callout(.semibold)
        headlineLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = NativeTranscriptFont.caption()
        detailLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0

        resetLabel.font = NativeTranscriptFont.caption(.medium)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NativeTranscriptFont.caption2()
        timeLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.addArrangedSubview(headlineLabel)
        textStack.addArrangedSubview(detailLabel)
        textStack.addArrangedSubview(resetLabel)

        cardContent.addSubview(iconView)
        cardContent.addSubview(textStack)
        cardContent.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: cardContent.topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: cardContent.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),

            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 10),
            timeLabel.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            timeLabel.topAnchor.constraint(equalTo: cardContent.topAnchor)
        ])
    }

    func configure(payload: NativeRetryPayload, width rowWidth: CGFloat) {
        accentColor = payload.accent
        iconView.image = NSImage(systemSymbolName: payload.icon, accessibilityDescription: nil)
        iconView.contentTintColor = payload.accent
        headlineLabel.stringValue = payload.headline
        headlineLabel.textColor = .labelColor
        detailLabel.stringValue = payload.detail
        if let reset = payload.resetLine, !reset.isEmpty {
            resetLabel.stringValue = reset
            resetLabel.textColor = payload.accent
            resetLabel.isHidden = false
        } else {
            resetLabel.isHidden = true
        }
        timeLabel.stringValue = payload.timeText

        applyCard(
            fill: payload.accent.withAlphaComponent(AppTheme.roleFillOpacity),
            stroke: payload.accent.withAlphaComponent(AppTheme.roleStrokeOpacity),
            cornerRadius: 12,
            hPad: 12, vPad: 10,
            placement: .leftAtCap,
            copyText: payload.copyText,
            width: rowWidth
        )
    }

    override func contentHeight(forInnerWidth innerWidth: CGFloat) -> CGFloat {
        // The text stack wraps the detail; measure it at the width left after the
        // 18pt icon + 10pt gap and the trailing timestamp column (~48pt).
        let textWidth = max(40, innerWidth - 18 - 10 - 52)
        var h = ceil(headlineLabel.intrinsicContentSize.height)
        detailLabel.preferredMaxLayoutWidth = textWidth
        h += 3 + ceil(detailLabel.intrinsicContentSize.height)
        if !resetLabel.isHidden {
            h += 3 + ceil(resetLabel.intrinsicContentSize.height)
        }
        return max(18, h)
    }
}

struct NativeRetryPayload {
    var icon: String
    var accent: NSColor
    var headline: String
    var detail: String
    var resetLine: String?
    var timeText: String
    var copyText: String?
}

// MARK: - Shared text popover

/// A simple scrollable text popover used for error / prompt-audit detail.
final class PiAgentNativeTextPopoverController: NSViewController {
    private let titleText: String
    private let bodyText: String

    init(title: String, text: String) {
        self.titleText = title
        self.bodyText = text
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = NSFont.preferredFont(forTextStyle: .headline)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        textView.string = bodyText
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = textView

        container.addSubview(titleLabel)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        view = container
    }
}

// MARK: - Payload factories (mirror the SwiftUI computed vars)

extension NativeStatusPayload {
    /// Build a compact status/error payload from an entry. Mirrors
    /// `PiAgentStatusTranscriptRow`'s title/detail/icon/color computed vars.
    static func make(for entry: PiAgentTranscriptEntry) -> NativeStatusPayload {
        let isError = entry.role == .error
        let title: String = {
            if entry.title == "Compaction" { return "Context" }
            if entry.title.hasPrefix("Tool: ") { return "Tool failed" }
            return entry.title
        }()
        let normalized = entry.text
            .replacingOccurrences(of: "Context compacted.", with: "compacted")
            .replacingOccurrences(of: "Context compacted", with: "compacted")
            .replacingOccurrences(of: "Compacting conversation context (context)…", with: "compacting…")
            .replacingOccurrences(of: "Compacting context…", with: "compacting…")
            .replacingOccurrences(of: "\n", with: " ")
        let detail: String = {
            if entry.title.hasPrefix("Tool: ") {
                let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
                return "\(toolName): \(normalized)"
            }
            return normalized
        }()
        let icon: String = {
            if entry.title == "Compaction" { return "arrow.triangle.2.circlepath" }
            if isError { return "exclamationmark.triangle" }
            return "info.circle"
        }()
        let color: NSColor = isError ? AppTheme.ns(AppTheme.roleError) : AppTheme.ns(AppTheme.mutedText)
        let showsErrorPopover = isError && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return NativeStatusPayload(
            icon: icon,
            iconColor: color,
            color: color,
            title: title,
            detail: detail,
            timeText: entry.timestamp.formatted(date: .omitted, time: .shortened),
            copyText: entry.text,
            errorPopoverText: showsErrorPopover ? entry.text : nil,
            auditActions: promptAuditActions(for: entry)
        )
    }

    /// Prompt-audit buttons for "System Prompt Captured" / "Subagent Started"
    /// status entries (mirrors `PiAgentStatusTranscriptRow.promptActions`).
    private static func promptAuditActions(for entry: PiAgentTranscriptEntry) -> [AuditAction] {
        if entry.title == "System Prompt Captured", let prompt = capturedSystemPrompt(entry) {
            return [AuditAction(symbol: "doc.text.magnifyingglass", help: "Show final system prompt captured from Pi runtime",
                                title: "Final System Prompt", text: { prompt })]
        }
        if entry.title == "Subagent Started", let meta = subagentPromptMetadata(entry) {
            let authored = meta.authored, final = meta.final
            return [
                AuditAction(symbol: "doc.text", help: "Show system prompt \(AppBrand.displayName) passed to the child",
                            title: "\(AppBrand.displayName) Authored System Prompt", text: { promptFileText(path: authored) }),
                AuditAction(symbol: "doc.text.magnifyingglass", help: "Show system prompt captured from the child Pi runtime",
                            title: "Final Runtime System Prompt", text: { promptFileText(path: final) })
            ]
        }
        return []
    }

    private static func capturedSystemPrompt(_ entry: PiAgentTranscriptEntry) -> String? {
        guard let raw = entry.rawJSON, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let prefill = object["prefill"] as? String,
           let payload = try? JSONSerialization.jsonObject(with: Data(prefill.utf8)) as? [String: Any],
           let prompt = payload["systemPrompt"] as? String { return prompt }
        if let dataObject = object["data"] as? [String: Any],
           let prefill = dataObject["prefill"] as? String,
           let payload = try? JSONSerialization.jsonObject(with: Data(prefill.utf8)) as? [String: Any],
           let prompt = payload["systemPrompt"] as? String { return prompt }
        return object["systemPrompt"] as? String
    }

    private static func subagentPromptMetadata(_ entry: PiAgentTranscriptEntry) -> (authored: String, final: String)? {
        guard let raw = entry.rawJSON, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["agent_deck_subagent_started", "agent_deck_subagent_card"].contains(object["type"] as? String),
              let authored = object["authoredSystemPromptPath"] as? String,
              let final = object["finalSystemPromptPath"] as? String else { return nil }
        return (authored, final)
    }

    private static func promptFileText(path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Prompt unavailable."
    }
}

extension NativeDividerPayload {
    /// Build a divider payload (compaction / git event). Mirrors
    /// `PiAgentStatusTranscriptRow.compactionDivider`.
    static func make(for entry: PiAgentTranscriptEntry) -> NativeDividerPayload {
        let normalized = entry.text
            .replacingOccurrences(of: "Context compacted.", with: "compacted")
            .replacingOccurrences(of: "Context compacted", with: "compacted")
            .replacingOccurrences(of: "Compacting conversation context (context)…", with: "compacting…")
            .replacingOccurrences(of: "Compacting context…", with: "compacting…")
            .replacingOccurrences(of: "\n", with: " ")
        let isCompacting = normalized.localizedCaseInsensitiveContains("compacting")
            && !normalized.localizedCaseInsensitiveContains("compacted")
        let icon = PiAgentGitEventKind.from(title: entry.title)?.icon ?? "arrow.triangle.2.circlepath"
        return NativeDividerPayload(
            icon: icon,
            detail: normalized,
            timeText: entry.timestamp.formatted(date: .omitted, time: .shortened),
            isSpinning: isCompacting
        )
    }
}

extension NativeRetryPayload {
    /// Build a retry payload. Mirrors `PiAgentRetryCard`.
    static func make(info: ProviderRetryInfo, timestamp: Date) -> NativeRetryPayload {
        let accent: NSColor = {
            if info.isQuotaLimit { return AppTheme.ns(AppTheme.roleTool) }
            return info.gaveUp ? AppTheme.ns(AppTheme.roleError) : AppTheme.ns(AppTheme.roleTool)
        }()
        let icon: String = {
            if info.isQuotaLimit { return "hourglass" }
            return info.gaveUp ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
        }()
        let headline: String = {
            if info.isQuotaLimit { return "Usage limit reached" }
            if info.gaveUp { return "Model provider stopped retrying" }
            return "Retrying request…"
        }()
        var detail = info.message.isEmpty ? "The model provider returned an error." : info.message
        if let plan = info.planType, !plan.isEmpty {
            detail += " (\(plan.capitalized) plan)"
        }
        let resetLine: String? = {
            guard let resetsAt = info.resetsAt else { return nil }
            let absolute = resetsAt.formatted(date: .omitted, time: .shortened)
            if let relative = relativeReset(to: resetsAt) {
                return "Resets at \(absolute) · in \(relative)"
            }
            return "Resets at \(absolute)"
        }()
        return NativeRetryPayload(
            icon: icon,
            accent: accent,
            headline: headline,
            detail: detail,
            resetLine: resetLine,
            timeText: timestamp.formatted(date: .omitted, time: .shortened),
            copyText: nil
        )
    }

    private static func relativeReset(to date: Date) -> String? {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "~\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "~\(hours) hr" : "~\(hours) hr \(remainder) min"
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: Float) -> NSLayoutConstraint {
        self.priority = NSLayoutConstraint.Priority(priority)
        return self
    }
}
