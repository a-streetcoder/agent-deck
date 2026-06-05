import AppKit
import SwiftUI

// Native (pure AppKit) memory-activity card — replaces the hosted SwiftUI
// `PiAgentMemoryActivityCard` so scrolling never re-runs SwiftUI layout for the
// recall/store/edit chrome rows. A full-width card: an event glyph beside a
// title + summary, then either tappable injected-memory rows (each posting the
// open-memory notification directly) or a bare "N memories" caption.
//
// Like the other native rows, the view is a DUMB renderer driven by a plain
// payload computed up front in the items pass.

// MARK: - Payload

struct NativeMemoryCardPayload {
    /// SF Symbol for the event glyph (from the event kind).
    var iconSymbol: String
    /// Glyph tint — red for blocked, brand accent otherwise.
    var tint: NSColor
    var title: String
    var summary: String
    /// Tappable injected-memory rows (id + snapshot title), in display order.
    var memoryRows: [(id: String, title: String)]
    /// Shown only when there are no titled rows but IDs exist (e.g. "3 memories").
    var fallbackCount: String?
}

extension NativeMemoryCardPayload {
    /// Mirror of `PiAgentMemoryActivityCard`'s computed display values.
    @MainActor
    static func make(event: AgentMemoryTranscriptEvent) -> NativeMemoryCardPayload {
        let rows: [(id: String, title: String)]
        let fallback: String?
        if let titles = event.memoryTitles, !titles.isEmpty {
            // Titles snapshot taken at injection time; index-aligned with the IDs.
            rows = zip(event.memoryIDs, titles).map { (id: $0, title: $1) }
            fallback = nil
        } else if !event.memoryIDs.isEmpty {
            rows = []
            let n = event.memoryIDs.count
            fallback = "\(n) memor\(n == 1 ? "y" : "ies")"
        } else {
            rows = []
            fallback = nil
        }
        return NativeMemoryCardPayload(
            iconSymbol: event.event.systemImage,
            tint: event.event == .blocked ? .systemRed : AppTheme.ns(AppTheme.brandAccent),
            title: event.title,
            summary: event.summary,
            memoryRows: rows,
            fallbackCount: fallback
        )
    }
}

// MARK: - Tappable injected-memory row

/// One injected-memory line: title + trailing chevron, posts the open-memory
/// notification when clicked. No action closure needed from the parent.
private final class PiAgentNativeMemoryLinkRow: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var memoryID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NativeTranscriptFont.caption(.medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.caption2Size, weight: .semibold))
        chevron.contentTintColor = AppTheme.ns(AppTheme.mutedText)
        chevron.imageScaling = .scaleNone
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevron.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevron.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowTapped)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(id: String, title: String) {
        memoryID = id
        titleLabel.stringValue = title.isEmpty ? "Untitled Memory" : title
    }

    func measuredHeight() -> CGFloat {
        max(ceil(titleLabel.intrinsicContentSize.height), 14)
    }

    @objc private func rowTapped() {
        NotificationCenter.default.post(
            name: .agentDeckOpenMemoryRequested,
            object: nil,
            userInfo: ["id": memoryID]
        )
    }
}

// MARK: - Memory activity card

/// Full-width memory-activity card (rounded chrome): glyph + title/summary +
/// tappable memory rows or a fallback count caption. Self-measures precisely.
final class PiAgentNativeMemoryCardView: NSView, PiAgentNativeRowContent {
    private let surface = NativeCardSurface()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let fallbackLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()

    private var linkRows: [PiAgentNativeMemoryLinkRow] = []
    var onIntrinsicHeightChange: (() -> Void)?

    private let pad: CGFloat = 14
    private let iconSize: CGFloat = NativeTranscriptFont.headerIconSize
    private let iconGap: CGFloat = 8
    private let titleToSummary: CGFloat = 3
    private let summaryToRows: CGFloat = 6
    private let rowSpacing: CGFloat = 2

    private var surfaceWidthC: NSLayoutConstraint!

    required init() {
        super.init(frame: .zero)
        wantsLayer = true

        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.cardCornerRadius = AppTheme.Chat.cardCornerRadius
        addSubview(surface)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NativeTranscriptFont.header
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NativeTranscriptFont.footnote()
        summaryLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = NativeTranscriptFont.caption(.medium)
        fallbackLabel.textColor = AppTheme.ns(AppTheme.mutedText)
        fallbackLabel.isHidden = true

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = rowSpacing

        let textStack = NSStackView(views: [titleLabel, summaryLabel, fallbackLabel, rowStack])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.setCustomSpacing(titleToSummary, after: titleLabel)
        textStack.setCustomSpacing(summaryToRows, after: summaryLabel)
        textStack.setCustomSpacing(summaryToRows, after: fallbackLabel)

        surface.addSubview(iconView)
        surface.addSubview(textStack)

        let textBottom = textStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -pad)
        textBottom.priority = NSLayoutConstraint.Priority(999)
        surfaceWidthC = surface.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceWidthC,

            // Centered on the title line (like the message bubbles) rather than
            // top-pinned, so the small glyph reads as part of the header row.
            iconView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: pad),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            textStack.topAnchor.constraint(equalTo: surface.topAnchor, constant: pad),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: iconGap),
            textStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -pad),
            textBottom,
            rowStack.widthAnchor.constraint(equalTo: textStack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    // Full-width chrome card (not reply-capped).
    private func cardWidth(_ rowWidth: CGFloat) -> CGFloat { max(1, rowWidth) }

    /// Inner width available to the text column (card minus padding, icon, gap).
    private func textWidth(_ rowWidth: CGFloat) -> CGFloat {
        max(1, cardWidth(rowWidth) - pad * 2 - iconSize - iconGap)
    }

    func configure(payload: NativeMemoryCardPayload, width rowWidth: CGFloat) {
        surface.fillColor = AppTheme.ns(AppTheme.Chat.cardFill)
        surface.strokeColor = AppTheme.ns(AppTheme.Chat.cardStroke)
        surfaceWidthC.constant = cardWidth(rowWidth)

        iconView.image = NativeTranscriptFont.headerIcon(payload.iconSymbol)
        iconView.contentTintColor = payload.tint

        titleLabel.stringValue = payload.title
        summaryLabel.stringValue = payload.summary

        rebuildRows(payload.memoryRows)
        if let fallback = payload.fallbackCount, payload.memoryRows.isEmpty {
            fallbackLabel.stringValue = fallback
            fallbackLabel.isHidden = false
        } else {
            fallbackLabel.isHidden = true
        }

        needsLayout = true
    }

    private func rebuildRows(_ rows: [(id: String, title: String)]) {
        if linkRows.count != rows.count {
            rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            linkRows.removeAll()
            for _ in rows {
                let r = PiAgentNativeMemoryLinkRow()
                r.translatesAutoresizingMaskIntoConstraints = false
                rowStack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
                linkRows.append(r)
            }
        }
        rowStack.isHidden = rows.isEmpty
        for (i, row) in rows.enumerated() {
            linkRows[i].configure(id: row.id, title: row.title)
        }
    }

    func measuredHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let inner = textWidth(rowWidth)
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        summaryLabel.preferredMaxLayoutWidth = inner
        let summaryH = ceil(summaryLabel.intrinsicContentSize.height)

        var textColumnH = titleH + titleToSummary + summaryH
        if !linkRows.isEmpty {
            textColumnH += summaryToRows
            for (i, row) in linkRows.enumerated() {
                if i > 0 { textColumnH += rowSpacing }
                textColumnH += row.measuredHeight()
            }
        } else if !fallbackLabel.isHidden {
            textColumnH += summaryToRows + ceil(fallbackLabel.intrinsicContentSize.height)
        }

        // The card hugs the taller of the icon and the text column.
        let contentH = max(iconSize, textColumnH)
        return ceil(pad + contentH + pad)
    }

    func prepareForReuseIfNeeded() {}
}
