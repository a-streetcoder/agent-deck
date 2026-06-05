import AppKit
import SwiftUI

// Native (pure AppKit) transcript "chrome" rows — the non-message cards that
// frame a session: keyboard-shortcut hints, fork origin, system-prompt audit,
// archive notices, and the loading/empty states. Hosted, each rebuilt a small
// SwiftUI tree inside an NSHostingView on every scroll vend; native, they are
// dumb renderers configured from a small payload, reusing one container.
//
// These are full-width chrome cards (NOT reply-capped). Rounded surfaces use
// `NativeCardSurface`; colors come from `AppTheme.ns(...)`; fonts come only from
// `NativeTranscriptFont`. Each view conforms to `PiAgentNativeRowContent` and
// self-measures precisely.

// MARK: - Shared layout constants

private enum ChromeLayout {
    static let hPad: CGFloat = 14
    static let vPad: CGFloat = 12
    static let cardCorner = AppTheme.Chat.cardCornerRadius
}

// MARK: - 1. Keyboard shortcuts strip

/// A horizontal strip of keyboard-shortcut hints (key caps + label). No card
/// surface — it reads as a light footer line, like the SwiftUI strip. No payload
/// needed; the hints are fixed.
final class PiAgentNativeShortcutsStripView: NSView, PiAgentNativeRowContent {
    var onIntrinsicHeightChange: (() -> Void)?

    private let stack = NSStackView()
    private static let hints: [(keys: [String], label: String)] = [
        (["↩"], "send / steer"),
        (["⇧", "↩"], "newline"),
        (["esc"], "stop running turn"),
        (["esc ×2"], "clear input"),
        (["/"], "commands"),
        (["@"], "file suggestions")
    ]

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        for hint in Self.hints {
            stack.addArrangedSubview(makeHint(keys: hint.keys, label: hint.label))
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private func makeHint(keys: [String], label: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY

        let caps = NSStackView()
        caps.orientation = .horizontal
        caps.spacing = 3
        caps.alignment = .centerY
        for key in keys { caps.addArrangedSubview(makeKeyCap(key)) }
        row.addArrangedSubview(caps)

        let text = NSTextField(labelWithString: label)
        text.font = NativeTranscriptFont.caption()
        text.textColor = AppTheme.ns(AppTheme.mutedText)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(text)
        return row
    }

    private func makeKeyCap(_ key: String) -> NSView {
        let multi = key.count > 1
        let surface = NativeCardSurface()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = 6
        surface.fillColor = AppTheme.ns(AppTheme.contentSubtleFill)
        surface.strokeColor = AppTheme.ns(AppTheme.contentStroke)

        let label = NSTextField(labelWithString: key)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: multi ? 10 : 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        surface.addSubview(label)

        let hInset: CGFloat = multi ? 5 : 0
        NSLayoutConstraint.activate([
            surface.heightAnchor.constraint(equalToConstant: 22),
            surface.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: hInset),
            label.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -hInset)
        ])
        return surface
    }

    func configure(width rowWidth: CGFloat) { /* fixed content */ }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        22 /* key cap */ + 4 /* outer .vertical 2 */
    }

    func prepareForReuseIfNeeded() {}
}

// MARK: - 2. Fork origin card

struct NativeForkOriginPayload {
    var parentTitle: String
    var parentSessionID: UUID?
    var transcriptSnapshot: String?
    var onSelectParent: ((UUID) -> Void)?

    @MainActor
    static func make(
        parentTitle: String,
        parentSessionID: UUID?,
        transcriptSnapshot: String?,
        onSelectParent: ((UUID) -> Void)?
    ) -> NativeForkOriginPayload {
        NativeForkOriginPayload(
            parentTitle: parentTitle,
            parentSessionID: parentSessionID,
            transcriptSnapshot: transcriptSnapshot,
            onSelectParent: onSelectParent
        )
    }
}

/// Pinned at the top of a forked session: glyph + "Forked from \"title\"" + a
/// token count of the captured snapshot, with "Open Parent" + "View" buttons.
/// "View" pops over the captured parent transcript.
final class PiAgentNativeForkOriginCardView: NSView, PiAgentNativeRowContent {
    var onIntrinsicHeightChange: (() -> Void)?

    private let surface = NativeCardSurface()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let openParentButton = NSButton()
    private let viewButton = NSButton()

    private var payload: NativeForkOriginPayload?
    private var surfaceWidthC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = ChromeLayout.cardCorner
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        addSubview(surface)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NativeTranscriptFont.headerIcon("arrow.trianglehead.branch")
        glyph.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = NativeTranscriptFont.header
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = NativeTranscriptFont.caption()
        subtitleLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        configureSmallButton(openParentButton, title: "Open Parent", action: #selector(openParentTapped))
        configureSmallButton(viewButton, title: "View", action: #selector(viewTapped))

        let buttonStack = NSStackView(views: [openParentButton, viewButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY
        buttonStack.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [glyph, textStack, NSView(), buttonStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        surface.addSubview(row)

        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        let rowBottom = row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -ChromeLayout.vPad)
        rowBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,
            glyph.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            glyph.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            row.topAnchor.constraint(equalTo: surface.topAnchor, constant: ChromeLayout.vPad),
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: ChromeLayout.hPad),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -ChromeLayout.hPad),
            rowBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private func configureSmallButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NativeTranscriptFont.caption(.semibold)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(payload: NativeForkOriginPayload, width rowWidth: CGFloat) {
        self.payload = payload
        titleLabel.stringValue = "Forked from \u{201C}\(payload.parentTitle)\u{201D}"
        let snapshot = payload.transcriptSnapshot
        if let snapshot, !snapshot.isEmpty {
            subtitleLabel.stringValue = "~\(formatPromptTokens(estimatedPromptTokens(snapshot))) of parent transcript captured"
        } else {
            subtitleLabel.stringValue = "Parent transcript not captured"
        }
        openParentButton.isHidden = !(payload.parentSessionID != nil && payload.onSelectParent != nil)
        viewButton.isHidden = !(snapshot?.isEmpty == false)
        surfaceWidthC.constant = max(1, rowWidth)
        needsLayout = true
    }

    @objc private func openParentTapped() {
        guard let payload, let id = payload.parentSessionID else { return }
        payload.onSelectParent?(id)
    }

    @objc private func viewTapped() {
        guard let snapshot = payload?.transcriptSnapshot, !snapshot.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PiAgentNativeTextPopoverController(
            title: "Forked from \u{201C}\(payload?.parentTitle ?? "")\u{201D}",
            text: snapshot
        )
        popover.show(relativeTo: viewButton.bounds, of: viewButton, preferredEdge: .maxY)
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let subH = ceil(subtitleLabel.intrinsicContentSize.height)
        let textH = titleH + 3 + subH
        let content = max(30, textH)
        return ceil(ChromeLayout.vPad + content + ChromeLayout.vPad)
    }

    func prepareForReuseIfNeeded() {}
}

// MARK: - 4. Archive notice row

struct NativeArchiveNoticePayload {
    var icon: String
    var title: String
    var detail: String
    /// Optional trailing borderless button (title + action).
    var actionTitle: String?
    var action: (() -> Void)?
    /// When true, title + detail stack vertically (recent-window notice); when
    /// false they sit inline on one line (pre-compaction notice).
    var stacked: Bool
}

/// A light notice row: glyph + "N items hidden…" text + an optional borderless
/// action button. Used for the pre-compaction and recent-window archive notices.
final class PiAgentNativeArchiveNoticeView: NSView, PiAgentNativeRowContent {
    var onIntrinsicHeightChange: (() -> Void)?

    private let surface = NativeCardSurface()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()

    private var payload: NativeArchiveNoticePayload?
    private var surfaceWidthC: NSLayoutConstraint!
    private var textStack: NSStackView!
    private var row: NSStackView!

    private let hPad: CGFloat = 12
    private let vPad: CGFloat = 8

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = ChromeLayout.cardCorner
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        addSubview(surface)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = AppTheme.ns(AppTheme.mutedText)
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = NativeTranscriptFont.caption(.semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        detailLabel.font = NativeTranscriptFont.caption()
        detailLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0

        textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        actionButton.bezelStyle = .inline
        actionButton.isBordered = false
        actionButton.font = NativeTranscriptFont.caption(.semibold)
        actionButton.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        row = NSStackView(views: [glyph, textStack, NSView(), actionButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        surface.addSubview(row)

        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        let rowBottom = row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -vPad)
        rowBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,
            row.topAnchor.constraint(equalTo: surface.topAnchor, constant: vPad),
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: hPad),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -hPad),
            rowBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeArchiveNoticePayload, width rowWidth: CGFloat) {
        self.payload = payload
        glyph.image = NSImage(systemSymbolName: payload.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .semibold))
        titleLabel.stringValue = payload.title
        detailLabel.stringValue = payload.detail
        textStack.orientation = payload.stacked ? .vertical : .horizontal
        textStack.alignment = payload.stacked ? .leading : .centerY
        textStack.spacing = payload.stacked ? 2 : 8
        // Inline notices keep detail on one line; stacked ones wrap.
        detailLabel.maximumNumberOfLines = payload.stacked ? 0 : 1
        detailLabel.lineBreakMode = payload.stacked ? .byWordWrapping : .byTruncatingTail
        if let actionTitle = payload.actionTitle, payload.action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        surfaceWidthC.constant = max(1, rowWidth)
        needsLayout = true
    }

    @objc private func actionTapped() { payload?.action?() }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let stacked = payload?.stacked ?? false
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        if stacked {
            // Width available to the wrapping detail: row minus glyph (~16+10 gap),
            // the trailing button column, and the card padding.
            let buttonW = actionButton.isHidden ? 0 : ceil(actionButton.intrinsicContentSize.width) + 10
            let textWidth = max(60, max(1, rowWidth) - hPad * 2 - 16 - 10 - buttonW)
            detailLabel.preferredMaxLayoutWidth = textWidth
            let detailH = ceil(detailLabel.intrinsicContentSize.height)
            let content = max(16, titleH + 2 + detailH)
            return ceil(vPad + content + vPad)
        } else {
            return ceil(vPad + max(16, titleH) + vPad)
        }
    }

    func prepareForReuseIfNeeded() {}
}

extension NativeArchiveNoticePayload {
    /// Pre-compaction archive notice: inline title + count, toggling load/hide.
    @MainActor
    static func preCompaction(
        hiddenCount: Int,
        compactedAt: Date,
        isShowing: Bool,
        onToggle: @escaping () -> Void
    ) -> NativeArchiveNoticePayload {
        let plural = hiddenCount == 1 ? "" : "s"
        let time = compactedAt.formatted(date: .omitted, time: .shortened)
        return NativeArchiveNoticePayload(
            icon: isShowing ? "tray.and.arrow.up" : "archivebox",
            title: isShowing ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden",
            detail: "\(hiddenCount) earlier item\(plural) before \(time)",
            actionTitle: isShowing ? "Hide" : "Load Earlier",
            action: onToggle,
            stacked: false
        )
    }

    /// Recent-window archive notice: stacked title + wrapping explainer.
    @MainActor
    static func recentWindow(
        hiddenCount: Int,
        limit: Int,
        onOpen: @escaping () -> Void
    ) -> NativeArchiveNoticePayload {
        let plural = hiddenCount == 1 ? "" : "s"
        return NativeArchiveNoticePayload(
            icon: "clock.arrow.circlepath",
            title: "Earlier transcript hidden",
            detail: "Showing the latest \(limit) items to keep this chat responsive. \(hiddenCount) earlier item\(plural) are available.",
            actionTitle: "Open Earlier Transcript",
            action: onOpen,
            stacked: true
        )
    }
}

// MARK: - 5. State card (loading / empty)

struct NativeStateCardPayload {
    var isLoading: Bool
    var title: String
    var subtitle: String
    /// SF Symbol for the empty (non-loading) state. Loading shows a spinner.
    var icon: String

    static func loading() -> NativeStateCardPayload {
        NativeStateCardPayload(
            isLoading: true,
            title: "Loading transcript",
            subtitle: "Restoring the selected chat from disk.",
            icon: "text.bubble"
        )
    }

    static func empty() -> NativeStateCardPayload {
        NativeStateCardPayload(
            isLoading: false,
            title: "No transcript yet",
            subtitle: "Send a message below to launch Pi Agent for this session.",
            icon: "text.bubble"
        )
    }
}

/// A simple state card: spinner (loading) or glyph (empty) + title + subtitle.
final class PiAgentNativeStateCardView: NSView, PiAgentNativeRowContent {
    var onIntrinsicHeightChange: (() -> Void)?

    private let surface = NativeCardSurface()
    private let spinner = NSProgressIndicator()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    private var surfaceWidthC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = ChromeLayout.cardCorner
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        addSubview(surface)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = AppTheme.ns(AppTheme.mutedText)
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = NativeTranscriptFont.header
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = NativeTranscriptFont.footnote()
        subtitleLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let leading = NSStackView(views: [spinner, glyph])
        leading.orientation = .horizontal
        leading.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [leading, textStack, NSView()])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        surface.addSubview(row)

        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        let rowBottom = row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -ChromeLayout.vPad)
        rowBottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,
            glyph.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            glyph.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            row.topAnchor.constraint(equalTo: surface.topAnchor, constant: ChromeLayout.vPad),
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: ChromeLayout.hPad),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -ChromeLayout.hPad),
            rowBottom
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(payload: NativeStateCardPayload, width rowWidth: CGFloat) {
        if payload.isLoading {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            glyph.isHidden = true
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            glyph.isHidden = false
            glyph.image = NativeTranscriptFont.headerIcon(payload.icon, weight: .regular)
        }
        titleLabel.stringValue = payload.title
        subtitleLabel.stringValue = payload.subtitle
        surfaceWidthC.constant = max(1, rowWidth)
        needsLayout = true
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let subH = ceil(subtitleLabel.intrinsicContentSize.height)
        let content = max(22, titleH + 4 + subH)
        return ceil(ChromeLayout.vPad + content + ChromeLayout.vPad)
    }

    func prepareForReuseIfNeeded() { spinner.stopAnimation(nil) }
}
