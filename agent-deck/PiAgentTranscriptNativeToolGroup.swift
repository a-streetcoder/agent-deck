import AppKit
import SwiftUI

// Native (pure AppKit) tool-group row. Mirrors `PiAgentTranscriptThreadCard`'s
// `toolGroupView`: a reply-column container (no outer card chrome, hover copy in
// the gutter) stacking up to three subtle-filled sub-cards — web activity, tool
// chips, and a file-changes/diff summary. The display models are computed in the
// items pass (see `NativeToolGroupModel.make`) so this view is a dumb renderer.

// MARK: - Display models

struct NativeToolGroupModel {
    var web: Web?
    var chips: Chips?
    var diff: Diff?

    struct Web {
        var title: String
        var callCount: String
        var hasErrors: Bool
        var rows: [Row]
        var hiddenCount: Int
        struct Row {
            var id: UUID
            var icon: String
            var title: String
            var detail: String?
            var isError: Bool
            var links: [Link]
        }
        struct Link { var title: String; var domain: String }
    }

    struct Chips {
        var callCount: String
        var hasErrors: Bool
        var items: [Chip]
        struct Chip { var icon: String; var name: String; var count: Int; var isError: Bool }
    }

    struct Diff {
        var fileCount: Int
        var rows: [PiAgentThreadDiffSummaryView.Row]
    }
}

// MARK: - Factory (pure mapping, single-sourced with the SwiftUI views)

extension NativeToolGroupModel {
    @MainActor
    static func make(
        group: PiAgentThreadToolGroup,
        visibility: PiAgentTranscriptVisibilitySettings,
        projectPath: String?
    ) -> NativeToolGroupModel? {
        let webActivities = group.activities.filter(\.isWebActivity)
        let toolActivities = group.activities.filter { !$0.isWebActivity }

        var web: Web?
        if visibility.showWebActivity, !webActivities.isEmpty {
            let display = Array(webActivities.prefix(4))
            web = Web(
                title: webTitle(for: webActivities),
                callCount: callCountText(webActivities),
                hasErrors: webActivities.contains(where: \.isError),
                rows: display.map { activity in
                    Web.Row(
                        id: activity.id,
                        icon: webIcon(for: activity.name),
                        title: webRowTitle(for: activity.name),
                        detail: activity.compactDetail,
                        isError: activity.isError,
                        links: activity.webLinks.map { Web.Link(title: $0.title, domain: $0.domain) }
                    )
                },
                hiddenCount: max(0, webActivities.count - display.count)
            )
        }

        var chips: Chips?
        if visibility.showToolCalls, !toolActivities.isEmpty {
            chips = Chips(
                callCount: callCountText(toolActivities),
                hasErrors: toolActivities.contains(where: \.isError),
                items: toolActivities.map { activity in
                    Chips.Chip(
                        icon: toolIcon(for: activity.name),
                        name: toolDisplayName(for: activity.name, count: activity.count),
                        count: activity.count,
                        isError: activity.isError
                    )
                }
            )
        }

        var diff: Diff?
        if visibility.showDiffs {
            let rows = PiAgentThreadDiffSummaryView.diffRows(from: toolActivities)
            let fileCount = PiAgentThreadDiffSummaryView.changedPaths(from: toolActivities).count
            if !rows.isEmpty {
                diff = Diff(fileCount: fileCount, rows: Array(rows.prefix(4)))
            }
        }

        guard web != nil || chips != nil || diff != nil else { return nil }
        return NativeToolGroupModel(web: web, chips: chips, diff: diff)
    }

    private static func callCountText(_ activities: [PiAgentTranscriptActivity]) -> String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private static func webTitle(for activities: [PiAgentTranscriptActivity]) -> String {
        let names = Set(activities.map { $0.name.lowercased() })
        if names.count == 1, let name = names.first {
            switch name {
            case "web_search": return "Web search"
            case "fetch_content": return "Fetch content"
            case "get_search_content": return "Read web content"
            case "web_fetch": return "URL fetch"
            default: break
            }
        }
        return "Web"
    }

    private static func webRowTitle(for name: String) -> String {
        switch name.lowercased() {
        case "web_search": return "Search"
        case "fetch_content": return "Fetched"
        case "get_search_content": return "Read content"
        case "web_fetch": return "Fetched"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func webIcon(for name: String) -> String {
        switch name.lowercased() {
        case "web_search": return "magnifyingglass"
        case "fetch_content", "get_search_content", "web_fetch": return "doc.text.magnifyingglass"
        default: return "globe"
        }
    }

    private static func toolDisplayName(for name: String, count: Int) -> String {
        switch name.lowercased() {
        case "bash": return "Shell"
        case "read": return "File read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "set_session_plan": return "Plan"
        case "update_session_plan": return "Plan update"
        case "subagent": return count == 1 ? "Deck agent" : "Deck agents"
        case "web_search": return "Web search"
        case "fetch_content", "get_search_content", "web_fetch": return "Web content"
        default:
            return name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func toolIcon(for name: String) -> String {
        switch name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "set_session_plan", "update_session_plan": return "checklist"
        case "subagent": return "person.2.wave.2"
        case "web_search", "fetch_content", "get_search_content", "web_fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Tool-group view

final class PiAgentNativeToolGroupView: PiAgentNativeCardRowView {
    private let sections = NSStackView()
    private var sectionsWidthC: NSLayoutConstraint!
    private var model: NativeToolGroupModel?
    /// Web rows whose link list is expanded (by row id).
    private var expandedWebRows: Set<UUID> = []
    /// Diff rows whose preview is expanded past 10 lines (by path).
    private var expandedDiffRows: Set<String> = []

    private static let inlineLinkLimit = 5
    // Quiet hairline transcript-card surface — see `AppTheme.Chat.cardFill`.
    // Computed (not `static let`) so each sub-card build re-resolves against the
    // active theme rather than snapshotting the launch theme.
    private static var subtleFill: NSColor { AppTheme.ns(AppTheme.Chat.cardFill) }
    private static var subtleStroke: NSColor { AppTheme.ns(AppTheme.Chat.cardStroke) }
    private static let muted = AppTheme.ns(AppTheme.mutedText)

    override func commonSetup() {
        sections.translatesAutoresizingMaskIntoConstraints = false
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 8
        cardContent.addSubview(sections)
        sectionsWidthC = sections.widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            sections.topAnchor.constraint(equalTo: cardContent.topAnchor),
            sections.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            sections.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),
            sectionsWidthC
        ])
    }

    func configure(model: NativeToolGroupModel, width rowWidth: CGFloat) {
        self.model = model
        // Transparent outer (sub-cards carry their own chrome); reply-column width.
        applyCard(
            fill: .clear, stroke: .clear, cornerRadius: 0,
            hPad: 0, vPad: 0, placement: .leftAtCap,
            copyText: nil, width: rowWidth
        )
        sectionsWidthC.constant = innerCardWidth(forRowWidth: rowWidth)
        rebuildSections()
    }

    private func innerCardWidth(forRowWidth rowWidth: CGFloat) -> CGFloat {
        max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
    }

    override func contentHeight(forInnerWidth innerWidth: CGFloat) -> CGFloat {
        sectionsWidthC.constant = innerWidth
        sections.layoutSubtreeIfNeeded()
        return ceil(sections.fittingSize.height)
    }

    private func rebuildSections() {
        sections.arrangedSubviews.forEach { $0.removeFromSuperview() }
        diffByPath.removeAll()
        guard let model else { return }
        if let web = model.web { sections.addArrangedSubview(buildWebCard(web)) }
        if let chips = model.chips { sections.addArrangedSubview(buildChipsCard(chips)) }
        if let diff = model.diff { sections.addArrangedSubview(buildDiffCard(diff)) }
        for view in sections.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
    }

    // MARK: Sub-card chrome

    private func makeSubCard(cornerRadius: CGFloat = AppTheme.Chat.cardCornerRadius, fill: NSColor = subtleFill, stroke: NSColor = subtleStroke) -> NativeCardSurface {
        let card = NativeCardSurface()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cardCornerRadius = cornerRadius
        card.fillColor = fill
        card.strokeColor = stroke
        return card
    }

    private static func captionBold() -> NSFont { NativeTranscriptFont.caption(.semibold) }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let f = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.font = font
        f.textColor = color
        f.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return f
    }

    // MARK: Web card

    private func buildWebCard(_ web: NativeToolGroupModel.Web) -> NSView {
        let card = makeSubCard()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        // Header
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        let globe = NSImageView()
        globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        globe.contentTintColor = web.hasErrors ? AppTheme.ns(AppTheme.roleError) : Self.muted
        header.addArrangedSubview(globe)
        header.addArrangedSubview(Self.label(web.title, font: Self.captionBold()))
        header.addArrangedSubview(Self.label(web.callCount, font: NativeTranscriptFont.caption(), color: Self.muted))
        stack.addArrangedSubview(header)

        for row in web.rows {
            stack.addArrangedSubview(buildWebRow(row, cardWidth: card))
        }
        if web.hiddenCount > 0 {
            let suffix = web.hiddenCount == 1 ? "" : "s"
            stack.addArrangedSubview(Self.label("\(web.hiddenCount) older web update\(suffix) hidden",
                                                font: NativeTranscriptFont.caption2(), color: Self.muted))
        }

        embed(stack, in: card, hInset: 10, vInset: 8)
        return card
    }

    private func buildWebRow(_ row: NativeToolGroupModel.Web.Row, cardWidth: NSView) -> NSView {
        let rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 5

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 7
        titleRow.alignment = .firstBaseline
        // Fixed 14pt icon column so the title starts at a consistent x and the
        // bullet-link list (indented 21 = 14 icon + 7 gap) lines up under it.
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: row.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.caption2Size, weight: .semibold))
        icon.contentTintColor = row.isError ? AppTheme.ns(AppTheme.roleError) : Self.muted
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        titleRow.addArrangedSubview(icon)
        titleRow.addArrangedSubview(Self.label(row.title, font: Self.captionBold()))
        if let detail = row.detail {
            let d = Self.label(detail, font: NativeTranscriptFont.caption(), color: Self.muted)
            d.lineBreakMode = .byTruncatingMiddle
            titleRow.addArrangedSubview(d)
        }
        rowStack.addArrangedSubview(titleRow)

        if !row.links.isEmpty {
            let expanded = expandedWebRows.contains(row.id)
            let shown = expanded ? row.links : Array(row.links.prefix(Self.inlineLinkLimit))
            let linksStack = NSStackView()
            linksStack.orientation = .vertical
            linksStack.alignment = .leading
            linksStack.spacing = 3
            linksStack.edgeInsets = NSEdgeInsets(top: 0, left: 21, bottom: 0, right: 0)
            for link in shown {
                let linkRow = NSStackView()
                linkRow.orientation = .horizontal
                linkRow.spacing = 6
                linkRow.alignment = .firstBaseline
                linkRow.addArrangedSubview(Self.label("•", font: NativeTranscriptFont.caption2(), color: Self.muted))
                let linkTitle = Self.label(link.title, font: NativeTranscriptFont.caption2(.semibold))
                linkTitle.lineBreakMode = .byTruncatingTail
                linkRow.addArrangedSubview(linkTitle)
                let domain = Self.label(link.domain, font: NativeTranscriptFont.caption2(), color: Self.muted)
                domain.lineBreakMode = .byTruncatingMiddle
                linkRow.addArrangedSubview(domain)
                linksStack.addArrangedSubview(linkRow)
            }
            if row.links.count > Self.inlineLinkLimit {
                let more = NSButton(title: expanded ? "Show fewer results" : "+\(row.links.count - Self.inlineLinkLimit) more results",
                                    target: self, action: #selector(toggleWebRow(_:)))
                more.isBordered = false
                more.bezelStyle = .inline
                more.font = NativeTranscriptFont.caption2(.semibold)
                more.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
                more.identifier = NSUserInterfaceItemIdentifier(row.id.uuidString)
                linksStack.addArrangedSubview(more)
            }
            rowStack.addArrangedSubview(linksStack)
        }
        return rowStack
    }

    @objc private func toggleWebRow(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if expandedWebRows.contains(id) { expandedWebRows.remove(id) } else { expandedWebRows.insert(id) }
        rebuildSections()
        notifyContentHeightChanged()
    }

    // MARK: Chips card

    private func buildChipsCard(_ chips: NativeToolGroupModel.Chips) -> NSView {
        // No card background, no per-tool icons — one leading wrench glyph + a
        // single-line inline summary that truncates.
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .firstBaseline

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: chips.hasErrors ? "exclamationmark.triangle" : "wrench.and.screwdriver", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .semibold))
        icon.contentTintColor = chips.hasErrors ? AppTheme.ns(AppTheme.roleError) : Self.muted
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(icon)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.attributedStringValue = chipsLine(chips)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        return row
    }

    /// "Tools  ·  3 calls  ·  Shell ×2  ·  File read  ·  Edit" — one line.
    private func chipsLine(_ chips: NativeToolGroupModel.Chips) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "Tools", attributes: [.font: Self.captionBold(), .foregroundColor: NSColor.labelColor]))
        result.append(NSAttributedString(string: "  ·  \(chips.callCount)", attributes: [.font: NativeTranscriptFont.caption(), .foregroundColor: Self.muted]))
        for chip in chips.items {
            let name = chip.count > 1 ? "\(chip.name) ×\(chip.count)" : chip.name
            let color = chip.isError ? AppTheme.ns(AppTheme.roleError) : Self.muted
            result.append(NSAttributedString(string: "  ·  ", attributes: [.font: NativeTranscriptFont.caption(), .foregroundColor: Self.muted]))
            result.append(NSAttributedString(string: name, attributes: [.font: NativeTranscriptFont.caption(), .foregroundColor: color]))
        }
        return result
    }

    // MARK: Diff card

    private func buildDiffCard(_ diff: NativeToolGroupModel.Diff) -> NSView {
        let card = makeSubCard()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = Self.muted
        header.addArrangedSubview(icon)
        header.addArrangedSubview(Self.label("Changes", font: Self.captionBold()))
        header.addArrangedSubview(Self.label(diff.fileCount == 1 ? "1 file" : "\(diff.fileCount) files",
                                             font: NativeTranscriptFont.caption(), color: Self.muted))
        stack.addArrangedSubview(header)

        for row in diff.rows { stack.addArrangedSubview(buildDiffRow(row)) }
        let hidden = diff.rows.count > 4 ? diff.rows.count - 4 : 0
        if hidden > 0 {
            stack.addArrangedSubview(Self.label("\(hidden) more changed file\(hidden == 1 ? "" : "s") hidden",
                                                font: NativeTranscriptFont.caption2(), color: Self.muted))
        }

        embed(stack, in: card, hInset: 10, vInset: 8)
        return card
    }

    private func buildDiffRow(_ row: PiAgentThreadDiffSummaryView.Row) -> NSView {
        let inner = makeSubCard(cornerRadius: AppTheme.Chat.subCardCornerRadius, fill: AppTheme.ns(AppTheme.textContentFill.opacity(0.75)), stroke: .clear)
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .firstBaseline
        let pathLabel = Self.label(row.path.truncatedMiddle(max: 54), font: Self.captionBold())
        pathLabel.lineBreakMode = .byTruncatingMiddle
        head.addArrangedSubview(pathLabel)
        head.addArrangedSubview(Self.label(row.changeCountText,
                                           font: .monospacedDigitSystemFont(ofSize: NativeTranscriptFont.caption2Size, weight: .semibold),
                                           color: Self.muted))
        head.addArrangedSubview(NSView())  // spacer
        let openBtn = NSButton(title: "Open", target: self, action: #selector(openDiff(_:)))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .small
        openBtn.font = NativeTranscriptFont.caption2(.semibold)
        openBtn.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        openBtn.imagePosition = .imageLeading
        openBtn.identifier = NSUserInterfaceItemIdentifier(row.path)
        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyDiff(_:)))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        copyBtn.font = NativeTranscriptFont.caption2(.semibold)
        copyBtn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyBtn.imagePosition = .imageLeading
        copyBtn.identifier = NSUserInterfaceItemIdentifier(row.path)
        diffByPath[row.path] = row
        head.addArrangedSubview(openBtn)
        head.addArrangedSubview(copyBtn)
        stack.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(buildDiffPreview(for: row))

        embed(stack, in: inner, hInset: 8, vInset: 8)
        return inner
    }

    private var diffByPath: [String: PiAgentThreadDiffSummaryView.Row] = [:]

    /// Compact colored diff preview — faithful to `PiAgentCompactDiffPreview`:
    /// filtered "meaningful" lines, a right-aligned gutter (prefix + line number)
    /// and content column with per-line tint, capped at 10 lines with an inline
    /// "Show N more lines" expander.
    private func buildDiffPreview(for row: PiAgentThreadDiffSummaryView.Row) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0

        let lines = Self.meaningfulDiffLines(row.diff)
        let expanded = expandedDiffRows.contains(row.path)
        let visible = expanded ? lines : Array(lines.prefix(10))

        let linesStack = NSStackView()
        linesStack.translatesAutoresizingMaskIntoConstraints = false
        linesStack.orientation = .vertical
        linesStack.alignment = .leading
        linesStack.spacing = 0
        linesStack.wantsLayer = true
        linesStack.layer?.cornerRadius = AppTheme.Chat.codeCornerRadius
        linesStack.layer?.masksToBounds = true
        for line in visible { linesStack.addArrangedSubview(buildDiffLineRow(line)) }
        container.addArrangedSubview(linesStack)
        linesStack.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        for lineRow in linesStack.arrangedSubviews {
            lineRow.widthAnchor.constraint(equalTo: linesStack.widthAnchor).isActive = true
        }

        if lines.count > 10 {
            let title = expanded ? "Show fewer lines" : "Show \(lines.count - 10) more lines"
            let symbol = expanded ? "chevron.up" : "chevron.down"
            let more = NSButton(title: " " + title, target: self, action: #selector(toggleDiffRow(_:)))
            more.isBordered = false
            more.bezelStyle = .inline
            more.font = NativeTranscriptFont.caption2()
            more.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            more.imagePosition = .imageLeading
            more.contentTintColor = Self.muted
            more.identifier = NSUserInterfaceItemIdentifier(row.path)
            let wrap = NSStackView(views: [more])
            wrap.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 0, right: 0)
            container.addArrangedSubview(wrap)
        }
        return container
    }

    private func buildDiffLineRow(_ line: DiffLine) -> NSView {
        let bg = NSView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        bg.wantsLayer = true
        bg.layer?.backgroundColor = line.background.cgColor

        let mono = NSFont.monospacedSystemFont(ofSize: NativeTranscriptFont.captionSize, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: NativeTranscriptFont.captionSize, weight: .semibold)

        let gutter = Self.label(line.gutter, font: monoBold, color: line.color)
        gutter.alignment = .right
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let content = Self.label(line.content.isEmpty ? " " : line.content, font: mono, color: line.color)
        content.lineBreakMode = .byTruncatingTail
        content.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(gutter)
        bg.addSubview(content)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 40),
            gutter.topAnchor.constraint(equalTo: bg.topAnchor, constant: 1),
            gutter.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -1),
            content.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 9),
            content.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: gutter.centerYAnchor)
        ])
        return bg
    }

    struct DiffLine {
        var gutter: String
        var content: String
        var color: NSColor
        var background: NSColor
    }

    private static func meaningfulDiffLines(_ diff: String) -> [DiffLine] {
        let added = AppTheme.ns(AppTheme.diffAdded)
        let removed = AppTheme.ns(AppTheme.diffRemoved)
        let addedBg = AppTheme.ns(AppTheme.diffAdded.opacity(AppTheme.roleFillStrongOpacity))
        let removedBg = AppTheme.ns(AppTheme.diffRemoved.opacity(AppTheme.roleFillStrongOpacity))
        return diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            guard !line.hasPrefix("diff --git"), !line.hasPrefix("index "), !line.hasPrefix("---"), !line.hasPrefix("+++") else { return false }
            return line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@")
        }.map { raw in
            if raw.hasPrefix("@@") {
                return DiffLine(gutter: "…", content: raw, color: Self.muted, background: .clear)
            }
            guard let first = raw.first, first == "+" || first == "-" || first == " " else {
                return DiffLine(gutter: " ", content: raw.trimmingCharacters(in: .whitespaces), color: Self.muted, background: .clear)
            }
            let prefix = String(first)
            let trimmedLeading = raw.dropFirst().drop(while: { $0 == " " })
            let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
            let content = String(trimmedLeading.dropFirst(numberPart.count).drop(while: { $0 == " " }))
            let gutter = numberPart.isEmpty ? prefix : "\(prefix) \(numberPart)"
            let color: NSColor = first == "+" ? added : (first == "-" ? removed : Self.muted)
            let bg: NSColor = first == "+" ? addedBg : (first == "-" ? removedBg : .clear)
            return DiffLine(gutter: gutter, content: content, color: color, background: bg)
        }
    }

    @objc private func toggleDiffRow(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if expandedDiffRows.contains(path) { expandedDiffRows.remove(path) } else { expandedDiffRows.insert(path) }
        rebuildSections()
        notifyContentHeightChanged()
    }

    @objc private func copyDiff(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let row = diffByPath[path] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.diff, forType: .string)
        if let checkmark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
            sender.image = checkmark
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                sender.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            }
        }
    }

    /// Present the full diff in a modal sheet (hosting the SwiftUI diff view — a
    /// modal is not a scroll hot path, so it's pixel-identical to the original).
    @objc private func openDiff(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let row = diffByPath[path],
              let host = window?.contentViewController else { return }
        var hosting: NSViewController?
        let sheet = PiAgentNativeFullDiffSheet(row: row) { [weak host] in
            if let hosting { host?.dismiss(hosting) }
        }
        let controller = NSHostingController(rootView: sheet)
        hosting = controller
        host.presentAsSheet(controller)
    }

    // MARK: Helpers

    private func embed(_ view: NSView, in container: NSView, hInset: CGFloat, vInset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -hInset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: vInset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vInset)
        ])
    }

    override func prepareForReuseIfNeeded() {
        super.prepareForReuseIfNeeded()
        expandedWebRows.removeAll()
        expandedDiffRows.removeAll()
        diffByPath.removeAll()
    }
}
