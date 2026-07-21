import AppKit

/// AppKit fonts for the native transcript rows, sized from the design-system
/// tokens (`AppTheme.Font.*Size`) so every card follows one source of truth.
/// SwiftUI's `.weight(.semibold)` is the SF semibold face — NOT NSFontManager's
/// `.boldFontMask` (heavier, `.bold`); use these for parity.
enum NativeTranscriptFont {
    static var bodySize: CGFloat { AppTheme.Font.bodySize }
    static var calloutSize: CGFloat { AppTheme.Font.calloutSize }
    static var footnoteSize: CGFloat { AppTheme.Font.footnoteSize }
    static var captionSize: CGFloat { AppTheme.Font.captionSize }
    static var caption2Size: CGFloat { AppTheme.Font.caption2Size }

    static func body(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: bodySize, weight: weight) }
    static func callout(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: calloutSize, weight: weight) }
    static func footnote(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: footnoteSize, weight: weight) }
    static func caption(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: captionSize, weight: weight) }
    static func caption2(_ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: caption2Size, weight: weight) }
    static func captionMono(_ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: captionSize, weight: weight) }

    /// AppKit semantic fonts do not inherit SwiftUI's Dynamic Type environment.
    /// Preserve each native text style while applying the app's persisted scale.
    static func preferred(_ textStyle: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: textStyle)
        let size = base.pointSize * ThemeManager.shared.textSize.fontScale
        return NSFont(descriptor: base.fontDescriptor, size: size) ?? base
    }

    // MARK: Shared card / bubble header

    /// The one header title used by EVERY transcript row — message bubbles and
    /// chrome cards alike: footnote-sized SF semibold, slightly width-expanded to
    /// match SwiftUI's `.weight(.semibold)` header. Keep all card titles on this
    /// so the transcript reads as a single scale rather than two competing ones.
    static var header: NSFont {
        let semibold = NSFont.systemFont(ofSize: footnoteSize, weight: .semibold)
        let merged = semibold.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.width: 0.2]
        ])
        return NSFont(descriptor: merged, size: footnoteSize) ?? semibold
    }

    /// Side length of the glyph box that sits beside `header` (matches the
    /// message bubbles' 16pt icon).
    static let headerIconSize: CGFloat = 16

    /// Applies the shared title geometry used beside transcript header icons.
    /// A deterministic height keeps AppKit from giving a fresh label an over-tall
    /// first-layout frame, which paints the text above the centered glyph.
    static func configureHeaderLabel(_ label: NSTextField) {
        label.font = header
        label.maximumNumberOfLines = 1
        label.heightAnchor.constraint(equalToConstant: max(headerIconSize, ceil(header.ascender - header.descender))).isActive = true
    }

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
    /// Pill height: the ~16pt caption label plus ~6pt breathing room top & bottom.
    /// Corner radius is half this so it stays a full capsule.
    private static let capsuleHeight: CGFloat = 28
    private let leftRule = NSView()
    private let rightRule = NSView()
    private let capsule = NSGlassEffectView()
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let labelField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let capsuleStack = NSStackView()
    /// `NSGlassEffectView` hugs its content view's height, so the stack's vertical
    /// `edgeInsets` never widen the pill — the label ends up touching the stroke.
    /// We drive the capsule height explicitly instead (set in `configure`).
    private var capsuleHeightC: NSLayoutConstraint!
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
        // Vertical breathing room comes from the explicit capsule height below;
        // the stack only carries horizontal insets.
        capsuleStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        capsuleStack.addArrangedSubview(iconView)
        capsuleStack.addArrangedSubview(spinner)
        capsuleStack.addArrangedSubview(labelField)
        capsuleStack.addArrangedSubview(timeField)

        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.cornerRadius = Self.capsuleHeight / 2
        capsule.contentView = capsuleStack
        addSubview(capsule)

        capsuleHeightC = capsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight)
        NSLayoutConstraint.activate([
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsuleHeightC,
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
        // Explicit capsule height plus the 4pt outer padding the SwiftUI divider
        // carries above and below.
        Self.capsuleHeight + 8
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

        NativeTranscriptFont.configureHeaderLabel(headlineLabel)
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
            iconView.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            textStack.topAnchor.constraint(equalTo: cardContent.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),

            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 10),
            timeLabel.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            timeLabel.topAnchor.constraint(equalTo: cardContent.topAnchor)
        ])
    }

    func configure(payload: NativeRetryPayload, width rowWidth: CGFloat) {
        accentColor = payload.accent
        iconView.image = NativeTranscriptFont.headerIcon(payload.icon)
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
        // 16pt icon + 7pt gap and the trailing timestamp column (~48pt).
        let textWidth = max(40, innerWidth - NativeTranscriptFont.headerIconSize - 7 - 52)
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

// MARK: - Model/provider error row

/// A fatal model/provider error (`PiAgentTranscriptEntry.isModelError`). Shows
/// a fixed "Error" headline (shared bubble header font) with the full error
/// message below it as the detail body. Mirrors the retry card's chrome.
final class PiAgentNativeErrorRowView: PiAgentNativeCardRowView {
    private let iconView = NSImageView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let headerRight = NSStackView()

    override func commonSetup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.image = NativeTranscriptFont.headerIcon("exclamationmark.triangle.fill")

        NativeTranscriptFont.configureHeaderLabel(headlineLabel)
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.textColor = .labelColor

        detailLabel.font = NativeTranscriptFont.caption()
        detailLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0

        timeLabel.font = NativeTranscriptFont.caption2()
        timeLabel.textColor = AppTheme.ns(AppTheme.mutedText)

        headerRight.translatesAutoresizingMaskIntoConstraints = false
        headerRight.orientation = .horizontal
        headerRight.alignment = .centerY
        headerRight.spacing = 6
        headerRight.setContentHuggingPriority(.required, for: .horizontal)
        headerRight.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerRight.addArrangedSubview(timeLabel)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.addArrangedSubview(headlineLabel)
        textStack.addArrangedSubview(detailLabel)

        cardContent.addSubview(iconView)
        cardContent.addSubview(textStack)
        cardContent.addSubview(headerRight)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: cardContent.topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            textStack.topAnchor.constraint(equalTo: cardContent.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),

            headerRight.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 10),
            headerRight.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            headerRight.topAnchor.constraint(equalTo: cardContent.topAnchor)
        ])
    }

    func configure(payload: NativeErrorPayload, width rowWidth: CGFloat) {
        iconView.contentTintColor = payload.accent
        headlineLabel.stringValue = payload.headline
        detailLabel.stringValue = payload.details
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
        // Reserve the 16pt icon + 7pt gap and the trailing timestamp column (~48).
        let textWidth = max(40, innerWidth - NativeTranscriptFont.headerIconSize - 7 - 48)
        headlineLabel.preferredMaxLayoutWidth = textWidth
        var h = ceil(headlineLabel.intrinsicContentSize.height)
        detailLabel.preferredMaxLayoutWidth = textWidth
        h += 5 + ceil(detailLabel.intrinsicContentSize.height)
        return max(NativeTranscriptFont.headerIconSize, h)
    }
}

/// Typed payload for the model/provider error row. The headline is a fixed
/// "Error" role label; `details` holds the full error message shown as the body.
struct NativeErrorPayload {
    var headline: String
    var details: String
    var timeText: String
    var copyText: String
    var accent: NSColor

    static func make(for entry: PiAgentTranscriptEntry) -> NativeErrorPayload {
        let full = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeErrorPayload(
            headline: "Error",
            details: full.isEmpty ? "The model provider returned an error." : full,
            timeText: entry.timestamp.formatted(date: .omitted, time: .shortened),
            copyText: full,
            accent: AppTheme.ns(AppTheme.roleError)
        )
    }
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
        titleLabel.font = NativeTranscriptFont.preferred(.headline)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NativeTranscriptFont.preferred(.callout).pointSize, weight: .regular)
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
        let icon = entry.title == LoopIterationSeparatorCodec.title ? "infinity" : (PiAgentGitEventKind.from(title: entry.title)?.icon ?? "arrow.triangle.2.circlepath")
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

// MARK: - Loop recap card

struct NativeLoopRecapPayload {
    var title: String
    var label: String
    var outcomeText: String
    var summaryText: String
    var detailsText: String
    var timeText: String
    var icon: String
    var accent: NSColor
    var copyText: String

    static func make(entry: PiAgentTranscriptEntry, marker: LoopRunRecapMarker) -> NativeLoopRecapPayload {
        let lines = entry.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let bodyLines = Array(lines.dropFirst())
        let metadataPrefixes = ["Checker:", "Validation:", "Goal evaluator:", "Goal evaluator rationale:", "Latest goal evaluator:", "Latest goal evaluator rationale:", "Evaluator child run:", "Artifacts:", "Changed files:", "Structure:", "Iterations:", "Stop reason:", "Outcome:", "Final checker result:", "Latest validation:", "Shared progress artifact:"]
        let firstSummaryIndex = bodyLines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return !metadataPrefixes.contains { trimmed.hasPrefix($0) }
        }
        let summary: String
        let details: [String]
        if let firstSummaryIndex {
            summary = bodyLines[firstSummaryIndex]
            details = bodyLines.enumerated().compactMap { index, line in index == firstSummaryIndex ? nil : line }
        } else {
            summary = marker.kind == .final ? "Loop finished with the recorded status below." : "Iteration finished with the recorded status below."
            details = bodyLines
        }
        let outcome = outcomeText(lines: bodyLines, marker: marker, headline: lines.first)
        let label: String = {
            switch marker.kind {
            case .iteration: return marker.iterationIndex.map { "Iteration \($0)" } ?? "Iteration recap"
            case .final: return "Final recap"
            }
        }()
        return NativeLoopRecapPayload(
            title: headlineTitle(lines: bodyLines, marker: marker),
            label: label,
            outcomeText: outcome,
            summaryText: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            detailsText: details.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            timeText: entry.timestamp.formatted(date: .omitted, time: .shortened),
            icon: marker.kind == .final ? "checkmark.seal.fill" : "arrow.triangle.2.circlepath.circle.fill",
            accent: marker.kind == .final ? AppTheme.ns(AppTheme.brandAccent) : AppTheme.ns(AppTheme.roleStatus),
            copyText: entry.text
        )
    }

    private static func outcomeText(lines: [String], marker: LoopRunRecapMarker, headline: String?) -> String {
        if marker.kind == .final {
            if let evaluation = lines.first(where: { $0.hasPrefix("Latest goal evaluator:") }) { return evaluation }
            if let evaluation = lines.first(where: { $0.hasPrefix("Goal evaluator:") }) { return evaluation }
            if let outcome = lines.first(where: { $0.hasPrefix("Outcome:") }) { return outcome }
            if let stopReason = lines.first(where: { $0.hasPrefix("Stop reason:") }) { return stopReason }
            if let headline, let status = headline.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty { return "Status: \(status)" }
            return "Status: Final"
        }
        if let evaluation = lines.first(where: { $0.hasPrefix("Goal evaluator:") }) { return evaluation }
        if let validation = lines.first(where: { $0.hasPrefix("Validation:") }) { return validation }
        if let checker = lines.first(where: { $0.hasPrefix("Checker:") }) { return checker }
        return "Status: Iteration complete"
    }

    private static func headlineTitle(lines: [String], marker: LoopRunRecapMarker) -> String {
        let prefixes = marker.kind == .final ? ["Latest goal evaluator:", "Goal evaluator:"] : ["Goal evaluator:"]
        for prefix in prefixes {
            if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
                let decision = line.replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !decision.isEmpty { return "Goal evaluator: \(decision)" }
            }
        }
        return marker.kind == .final ? "Final loop recap" : "Loop iteration recap"
    }
}

final class PiAgentNativeLoopRecapCardView: PiAgentNativeCardRowView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let labelField = NSTextField(labelWithString: "")
    private let outcomeField = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let summaryMarkdown = NativeMarkdownTextContainer()
    private let detailsMarkdown = NativeMarkdownTextContainer()
    private let summaryApplier = MarkdownSourceApplier()
    private let detailsApplier = MarkdownSourceApplier()
    private let headerRight = NSStackView()
    private let textStack = NSStackView()

    override func commonSetup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        NativeTranscriptFont.configureHeaderLabel(titleLabel)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        labelField.font = NativeTranscriptFont.caption(.semibold)
        labelField.textColor = AppTheme.ns(AppTheme.mutedText)
        outcomeField.font = NativeTranscriptFont.caption(.medium)
        outcomeField.textColor = AppTheme.ns(AppTheme.mutedText)
        timeLabel.font = NativeTranscriptFont.caption2()
        timeLabel.textColor = AppTheme.ns(AppTheme.mutedText)

        for markdown in [summaryMarkdown, detailsMarkdown] {
            markdown.translatesAutoresizingMaskIntoConstraints = false
            markdown.setContentHuggingPriority(.defaultLow, for: .horizontal)
            markdown.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            markdown.onHeightChange = { [weak self] _ in
                self?.notifyContentHeightChanged()
            }
        }
        detailsMarkdown.alphaValue = 0.72

        headerRight.translatesAutoresizingMaskIntoConstraints = false
        headerRight.orientation = .horizontal
        headerRight.alignment = .centerY
        headerRight.spacing = 6
        headerRight.setContentHuggingPriority(.required, for: .horizontal)
        headerRight.addArrangedSubview(labelField)
        headerRight.addArrangedSubview(timeLabel)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(outcomeField)
        textStack.addArrangedSubview(summaryMarkdown)
        textStack.addArrangedSubview(detailsMarkdown)

        cardContent.addSubview(iconView)
        cardContent.addSubview(textStack)
        cardContent.addSubview(headerRight)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: cardContent.topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.topAnchor.constraint(equalTo: cardContent.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),

            headerRight.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 10),
            headerRight.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            headerRight.topAnchor.constraint(equalTo: cardContent.topAnchor)
        ])
    }

    func configure(payload: NativeLoopRecapPayload, width rowWidth: CGFloat) {
        iconView.image = NativeTranscriptFont.headerIcon(payload.icon)
        iconView.contentTintColor = payload.accent
        titleLabel.stringValue = payload.title
        labelField.stringValue = payload.label
        outcomeField.stringValue = payload.outcomeText
        timeLabel.stringValue = payload.timeText
        summaryApplier.apply(source: payload.summaryText, to: summaryMarkdown)
        detailsApplier.apply(source: payload.detailsText, to: detailsMarkdown)
        detailsMarkdown.isHidden = payload.detailsText.isEmpty
        applyCard(
            fill: payload.accent.withAlphaComponent(AppTheme.roleFillStrongOpacity),
            stroke: payload.accent.withAlphaComponent(AppTheme.roleStrokeOpacity),
            cornerRadius: AppTheme.Chat.bubbleCornerRadius,
            hPad: AppTheme.Chat.bubbleHPadding,
            vPad: AppTheme.Chat.bubbleVPadding,
            placement: .leftAtCap,
            copyText: payload.copyText,
            width: rowWidth
        )
    }

    override func prepareForReuseIfNeeded() {
        super.prepareForReuseIfNeeded()
        summaryApplier.cancel()
        detailsApplier.cancel()
    }

    override func contentHeight(forInnerWidth innerWidth: CGFloat) -> CGFloat {
        let textWidth = max(40, innerWidth - NativeTranscriptFont.headerIconSize - 8 - 90)
        titleLabel.preferredMaxLayoutWidth = textWidth
        outcomeField.preferredMaxLayoutWidth = textWidth
        var height = ceil(titleLabel.intrinsicContentSize.height)
        height += 6 + ceil(outcomeField.intrinsicContentSize.height)
        height += 6 + summaryMarkdown.measureHeight(forWidth: textWidth)
        if !detailsMarkdown.isHidden {
            height += 6 + detailsMarkdown.measureHeight(forWidth: textWidth)
        }
        return max(NativeTranscriptFont.headerIconSize, ceil(height))
    }
}

// MARK: - Loop run card

private func loopTimelineStepDisplayName(_ step: LoopTimelineStepKind) -> String {
    switch step {
    case .makerAct: return "Maker"
    case .checkerReview: return "Checker"
    case .pipelineStage: return "Pipeline stage"
    case .parallelBranch: return "Parallel branch"
    case .discoveryTriage: return "Discovery / triage"
    case .humanApprovalCheckpoint: return "Human approval"
    }
}

private func loopRunDetailsText(for run: LoopRun) -> String {
    var sections: [String] = []
    var overview: [String] = [
        "Status: \(run.displayStatusName)",
        "Structure: \(run.structure.displayName)",
        "Write target: \(run.writeTarget.displayName)",
        "Goal: \(run.goal)",
        "Progress: \(run.iterationProgressText)"
    ]
    if let stopReason = run.stopReason { overview.append("Stop reason: \(stopReason.displayName)") }
    if !run.validationCommand.isEmpty { overview.append("Validation command: \(run.validationCommand)") }
    if let directoryPath = run.artifactDirectoryPath { overview.append("Artifact directory: \(directoryPath)") }
    sections.append((["Overview"] + overview.map { "• \($0)" }).joined(separator: "\n"))

    if let launchContext = run.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines), !launchContext.isEmpty {
        sections.append([
            "Launch Context",
            "• Scope: \(run.launchContextScope.displayName)",
            "",
            launchContext
        ].joined(separator: "\n"))
    }

    if run.iterations.isEmpty {
        sections.append("Iterations\n• No iterations recorded yet.")
    } else {
        for iteration in run.iterations {
            var lines: [String] = ["Iteration \(iteration.index)"]
            lines.append("• Started: \(iteration.startedAt.formatted(date: .abbreviated, time: .standard))")
            if let ended = iteration.endedAt { lines.append("• Ended: \(ended.formatted(date: .abbreviated, time: .standard))") }
            if !iteration.summary.isEmpty { lines.append("• Summary: \(iteration.summary)") }
            if !iteration.changedFiles.isEmpty {
                lines.append("• Changed files:")
                lines.append(contentsOf: iteration.changedFiles.map { "  - \($0)" })
            }
            if let evaluation = iteration.goalEvaluation {
                lines.append("• Goal evaluator: \(evaluation.result.displayName)")
                if !evaluation.rationale.isEmpty {
                    lines.append("  - Rationale: \(evaluation.rationale)")
                }
                if let childRunReference = evaluation.childRunReferenceText {
                    lines.append("  - \(childRunReference)")
                }
            }
            if !iteration.artifacts.isEmpty {
                lines.append("• Artifacts:")
                lines.append(contentsOf: iteration.artifacts.map { artifact in
                    let pathSuffix = artifact.filePath.map { " — \($0)" } ?? ""
                    return "  - \(artifact.filename)\(pathSuffix)"
                })
            }
            if !iteration.timeline.isEmpty {
                lines.append("• Timeline:")
                lines.append(contentsOf: iteration.timeline.map { event in
                    var text = "  - \(loopTimelineStepDisplayName(event.step)): \(event.roleName)"
                    if !event.note.isEmpty { text += " — \(event.note)" }
                    return text
                })
            }
            if let validation = iteration.validationResult {
                lines.append("• Validation:")
                lines.append("  - Exit code: \(validation.exitCode.map(String.init) ?? "unavailable")")
                lines.append("  - Duration: \(String(format: "%.2fs", validation.duration))")
                if let stdoutPath = validation.stdoutPath { lines.append("  - Stdout artifact: \(stdoutPath)") }
                if let stderrPath = validation.stderrPath { lines.append("  - Stderr artifact: \(stderrPath)") }
                if !validation.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("  - Stdout:\n\(validation.stdout)")
                }
                if !validation.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("  - Stderr:\n\(validation.stderr)")
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
    }
    return sections.joined(separator: "\n\n")
}

struct NativeLoopRunPayload {
    var title: String
    var statusText: String
    var detailText: String
    var isActive: Bool
    var canRevealArtifacts: Bool
    var canRevealWorktree: Bool
    var canApplyWorktree: Bool
    var canDiscardWorktree: Bool
    var canApproveHumanApproval: Bool
    var canRejectHumanApproval: Bool
    var canRetry: Bool
    var canSave: Bool
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onSave: (() -> Void)?
    var onRevealArtifacts: (() -> Void)?
    var onRevealWorktree: (() -> Void)?
    var onApplyWorktree: (() -> Void)?
    var onDiscardWorktree: (() -> Void)?
    var onApproveHumanApproval: (() -> Void)?
    var onRejectHumanApproval: (() -> Void)?

    static func make(run: LoopRun, onStop: (() -> Void)?, onRetry: (() -> Void)?, onSave: (() -> Void)?, onRevealArtifacts: (() -> Void)?, onRevealWorktree: (() -> Void)?, onApplyWorktree: (() -> Void)? = nil, onDiscardWorktree: (() -> Void)? = nil, onApproveHumanApproval: (() -> Void)? = nil, onRejectHumanApproval: (() -> Void)? = nil) -> NativeLoopRunPayload {
        let details = loopRunDetailsText(for: run)
        let statusText = visibleStatusText(for: run)
        let worktreeURL = run.artifactDirectoryPath.map { URL(fileURLWithPath: $0).appendingPathComponent("worktree", isDirectory: true) }
        let hasWorktree = worktreeURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hasAppliedMarker = run.artifactDirectoryPath.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("worktree.applied").path) } ?? false
        let hasDiscardedMarker = run.artifactDirectoryPath.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("worktree.discarded").path) } ?? false
        let worktreeAlreadyHandled = run.worktreeState == .applied || run.worktreeState == .discarded || hasAppliedMarker || hasDiscardedMarker
        let canRevealWorktree = run.writeTarget == .newWorktree && hasWorktree && !worktreeAlreadyHandled
        let canOperateOnWorktree = run.writeTarget == .newWorktree && !run.isActive && hasWorktree && !worktreeAlreadyHandled
        let canResolveHumanApproval = run.structure == .humanApproval && run.status == .stopped && run.stopReason == .humanInputRequired
        return NativeLoopRunPayload(
            title: run.presentsGoalNotMetOutcome ? "Loop not achieved" : (run.status == .completed ? "Loop completed" : "Loop: \(run.structure.displayName)"),
            statusText: statusText,
            detailText: details,
            isActive: run.isActive,
            canRevealArtifacts: run.artifactDirectoryPath != nil && !canRevealWorktree,
            canRevealWorktree: canRevealWorktree,
            canApplyWorktree: canOperateOnWorktree,
            canDiscardWorktree: canOperateOnWorktree,
            canApproveHumanApproval: canResolveHumanApproval,
            canRejectHumanApproval: canResolveHumanApproval,
            canRetry: !run.isActive && (run.status == .failed || run.presentsGoalNotMetOutcome || run.stopReason == .humanInputRequired || run.stopReason == .humanApproved),
            canSave: !run.isActive,
            onStop: onStop,
            onRetry: onRetry,
            onSave: onSave,
            onRevealArtifacts: onRevealArtifacts,
            onRevealWorktree: onRevealWorktree,
            onApplyWorktree: onApplyWorktree,
            onDiscardWorktree: onDiscardWorktree,
            onApproveHumanApproval: onApproveHumanApproval,
            onRejectHumanApproval: onRejectHumanApproval
        )
    }

    private static func visibleStatusText(for run: LoopRun) -> String {
        var lines = ["Status: \(run.displayStatusName)"]
        if !run.isActive, let stopReason = run.stopReason {
            lines.append("Stop reason: \(stopReason.displayName)")
        }
        if run.structure == .makerChecker,
           run.presentsGoalNotMetOutcome,
           run.iterations.last?.checkerResult == .reject {
            lines.append("Last checker: Reject")
        }
        return lines.joined(separator: "\n")
    }
}

final class PiAgentNativeLoopRunCardView: NSView, PiAgentNativeRowContent {
    private let card = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var cardWidthC: NSLayoutConstraint!
    private let detailsButton = NSButton(title: "Open Details", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let retryButton = NSButton(title: "Start New Attempt", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Loop", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal Artifacts", target: nil, action: nil)
    private let revealWorktreeButton = NSButton(title: "Reveal Worktree", target: nil, action: nil)
    private let applyWorktreeButton = NSButton(title: "Apply Worktree", target: nil, action: nil)
    private let discardWorktreeButton = NSButton(title: "Discard Worktree", target: nil, action: nil)
    private let approveHumanApprovalButton = NSButton(title: "Record Approval", target: nil, action: nil)
    private let rejectHumanApprovalButton = NSButton(title: "Reject", target: nil, action: nil)
    private let actionRows = NSStackView()
    private var payload: NativeLoopRunPayload?
    var onIntrinsicHeightChange: (() -> Void)?

    required init() {
        super.init(frame: .zero)
        wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = AppTheme.Chat.bubbleCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = AppTheme.ns(AppTheme.contentStroke).cgColor
        card.layer?.backgroundColor = AppTheme.ns(AppTheme.roleStatus).withAlphaComponent(0.10).cgColor
        addSubview(card)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "infinity", accessibilityDescription: nil)
        iconView.contentTintColor = AppTheme.ns(AppTheme.brandAccent)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        NativeTranscriptFont.configureHeaderLabel(titleField)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.font = NativeTranscriptFont.caption(.semibold)
        statusField.textColor = AppTheme.ns(AppTheme.mutedText)
        statusField.maximumNumberOfLines = 0
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = NativeTranscriptFont.caption()
        detailField.textColor = AppTheme.ns(AppTheme.mutedText)
        detailField.maximumNumberOfLines = 0
        detailField.isHidden = true

        for button in actionButtons {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        detailsButton.target = self
        detailsButton.action = #selector(openDetails)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        revealWorktreeButton.target = self
        revealWorktreeButton.action = #selector(revealWorktreeTapped)
        applyWorktreeButton.target = self
        applyWorktreeButton.action = #selector(applyWorktreeTapped)
        discardWorktreeButton.target = self
        discardWorktreeButton.action = #selector(discardWorktreeTapped)
        approveHumanApprovalButton.target = self
        approveHumanApprovalButton.action = #selector(approveHumanApprovalTapped)
        rejectHumanApprovalButton.target = self
        rejectHumanApprovalButton.action = #selector(rejectHumanApprovalTapped)

        let header = NSStackView(views: [iconView, titleField])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        actionRows.translatesAutoresizingMaskIntoConstraints = false
        actionRows.orientation = .vertical
        actionRows.alignment = .leading
        actionRows.spacing = 6

        card.addSubview(header)
        card.addSubview(statusField)
        card.addSubview(detailField)
        card.addSubview(actionRows)

        cardWidthC = card.widthAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            cardWidthC,
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: AppTheme.Chat.bubbleHPadding),
            header.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -AppTheme.Chat.bubbleHPadding),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: AppTheme.Chat.bubbleVPadding),
            statusField.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -AppTheme.Chat.bubbleHPadding),
            statusField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            detailField.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: statusField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 8),
            actionRows.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actionRows.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -AppTheme.Chat.bubbleHPadding),
            actionRows.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 10),
            actionRows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -AppTheme.Chat.bubbleVPadding)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeLoopRunPayload, width rowWidth: CGFloat) {
        self.payload = payload
        cardWidthC.constant = Self.cardWidth(for: rowWidth)
        titleField.stringValue = payload.title
        statusField.stringValue = payload.statusText
        detailField.stringValue = payload.detailText
        detailField.isHidden = true
        detailsButton.title = "Open Details"
        stopButton.isHidden = !payload.isActive
        stopButton.isEnabled = payload.isActive && payload.onStop != nil
        retryButton.isHidden = !payload.canRetry
        retryButton.isEnabled = payload.canRetry && payload.onRetry != nil
        saveButton.isHidden = !payload.canSave
        saveButton.isEnabled = payload.canSave && payload.onSave != nil
        revealButton.isHidden = !payload.canRevealArtifacts
        revealButton.isEnabled = payload.canRevealArtifacts && payload.onRevealArtifacts != nil
        revealWorktreeButton.isHidden = !payload.canRevealWorktree
        revealWorktreeButton.isEnabled = payload.canRevealWorktree && payload.onRevealWorktree != nil
        applyWorktreeButton.isHidden = !payload.canApplyWorktree
        applyWorktreeButton.isEnabled = payload.canApplyWorktree && payload.onApplyWorktree != nil
        discardWorktreeButton.isHidden = !payload.canDiscardWorktree
        discardWorktreeButton.isEnabled = payload.canDiscardWorktree && payload.onDiscardWorktree != nil
        approveHumanApprovalButton.isHidden = !payload.canApproveHumanApproval
        approveHumanApprovalButton.isEnabled = payload.canApproveHumanApproval && payload.onApproveHumanApproval != nil
        rejectHumanApprovalButton.isHidden = !payload.canRejectHumanApproval
        rejectHumanApprovalButton.isEnabled = payload.canRejectHumanApproval && payload.onRejectHumanApproval != nil
        rebuildActionRows(forCardWidth: cardWidthC.constant)
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let cardWidth = Self.cardWidth(for: rowWidth)
        let rowCount = packedActionRows(forCardWidth: cardWidth, visibleButtons: visibleActionButtons).count
        let statusLineCount = CGFloat(max(1, payload?.statusText.split(separator: "\n", omittingEmptySubsequences: false).count ?? 1))
        return AppTheme.Chat.bubbleVPadding * 2 + 18 + 6 + statusLineCount * 16 + 10 + CGFloat(max(1, rowCount)) * 26 + CGFloat(max(0, rowCount - 1)) * 6
    }

    private var actionButtons: [NSButton] {
        [detailsButton, stopButton, retryButton, saveButton, revealButton, revealWorktreeButton, applyWorktreeButton, discardWorktreeButton, approveHumanApprovalButton, rejectHumanApprovalButton]
    }

    private var visibleActionButtons: [NSButton] { actionButtons.filter { !$0.isHidden } }

    private func rebuildActionRows(forCardWidth cardWidth: CGFloat) {
        for view in actionRows.arrangedSubviews {
            actionRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for rowButtons in packedActionRows(forCardWidth: cardWidth, visibleButtons: visibleActionButtons) {
            let row = NSStackView(views: rowButtons)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            actionRows.addArrangedSubview(row)
        }
    }

    private func packedActionRows(forCardWidth cardWidth: CGFloat, visibleButtons: [NSButton]) -> [[NSButton]] {
        guard !visibleButtons.isEmpty else { return [] }
        let availableWidth = max(120, cardWidth - AppTheme.Chat.bubbleHPadding * 2)
        var rows: [[NSButton]] = [[]]
        var currentWidth: CGFloat = 0
        for button in visibleButtons {
            let width = max(44, button.fittingSize.width)
            let nextWidth = rows[rows.count - 1].isEmpty ? width : currentWidth + 8 + width
            if nextWidth > availableWidth, !rows[rows.count - 1].isEmpty {
                rows.append([button])
                currentWidth = width
            } else {
                rows[rows.count - 1].append(button)
                currentWidth = nextWidth
            }
        }
        return rows
    }

    private static func cardWidth(for rowWidth: CGFloat) -> CGFloat {
        max(1, rowWidth)
    }

    @objc private func openDetails() {
        guard let payload else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 560, height: 520)
        popover.contentViewController = PiAgentNativeTextPopoverController(title: payload.title, text: payload.detailText)
        popover.show(relativeTo: detailsButton.bounds, of: detailsButton, preferredEdge: .maxY)
    }

    @objc private func stopTapped() { payload?.onStop?() }
    @objc private func retryTapped() { payload?.onRetry?() }
    @objc private func saveTapped() { payload?.onSave?() }
    @objc private func revealTapped() { payload?.onRevealArtifacts?() }
    @objc private func revealWorktreeTapped() { payload?.onRevealWorktree?() }
    @objc private func applyWorktreeTapped() { payload?.onApplyWorktree?() }
    @objc private func discardWorktreeTapped() { payload?.onDiscardWorktree?() }
    @objc private func approveHumanApprovalTapped() { payload?.onApproveHumanApproval?() }
    @objc private func rejectHumanApprovalTapped() { payload?.onRejectHumanApproval?() }
}
