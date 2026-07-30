import AppKit
import SwiftUI

// Native (pure AppKit) tool-group row. Mirrors `PiAgentTranscriptThreadCard`'s
// `toolGroupView`: a reply-column container (no outer card chrome, hover copy in
// the gutter) stacking up to two subtle-filled sub-cards — web activity and a
// file-changes/diff summary. (Per-tool call counts are not shown inline; they are
// recapped in the Session resources popover via `toolCallRecap`.) The display
// models are computed in the items pass (see `NativeToolGroupModel.make`) so this
// view is a dumb renderer.

// MARK: - Display models

struct NativeToolGroupModel {
    var web: Web? = nil
    var diff: Diff? = nil
    var mcp: MCP? = nil
    var images: Images? = nil

    /// Dedicated MCP card: every assigned-server tool call in this group, grouped
    /// under a single "MCP" header (mirrors the web/diff sub-cards). Built from the
    /// `mcp` proxy activity's per-call breakdown.
    struct MCP {
        var callCount: String
        var hasErrors: Bool
        var rows: [Row]
        var hiddenCount: Int
        struct Row {
            var id: UUID
            var server: String
            var tool: String
            /// The full response text, shown in the "View" modal (never inline).
            var resultPreview: String?
            var imageReferences: [PiAgentTranscriptImageReference] = []
            var resultBlocks: [PiAgentMCPResultBlock]? = nil
            var isError: Bool
            /// A concise one-line error message (the text before any JSON body), shown
            /// inline on error rows so the failure reads at a glance without opening View.
            var errorSummary: String?
        }
    }

    struct Images {
        var references: [PiAgentTranscriptImageReference]
        var hiddenCount: Int
    }

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
        struct Link { var title: String; var url: String; var domain: String }
    }

    struct Diff {
        var fileCount: Int
        var rows: [PiAgentThreadDiffSummaryView.Row]
    }
}

/// One compact, displayed line of a diff preview. Kept separate from the view so
/// line extraction remains pure and the renderer has no transcript-state cache.
struct NativeDiffPreviewLine {
    var gutter: String
    var content: String
    var color: NSColor
    var background: NSColor
}

/// Lightweight drawing surface for a compact diff preview.
///
/// A preview can contain dozens of lines. Drawing its fixed-height rows avoids a
/// per-line `NSStackView`, two labels, and constraint system while retaining the
/// existing colors, gutter, truncation, and VoiceOver-readable line text.
final class NativeDiffPreviewView: NSView {
    private static let gutterWidth: CGFloat = 40
    private static let gutterGap: CGFloat = 9
    private static let verticalInset: CGFloat = 1

    private var lines: [NativeDiffPreviewLine] = []
    private var lineAccessibilityElements: [NSAccessibilityElement] = []

    var renderedLineCount: Int { lines.count }

    init(lines: [NativeDiffPreviewLine] = []) {
        self.lines = lines
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AppTheme.Chat.codeCornerRadius
        layer?.masksToBounds = true
        rebuildAccessibilityElements()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(lines: [NativeDiffPreviewLine]) {
        self.lines = lines
        rebuildAccessibilityElements()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lineHeight * CGFloat(lines.count))
    }

    override func layout() {
        super.layout()
        updateAccessibilityFrames()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let mono = Self.monospaceFont(weight: .regular)
        let monoBold = Self.monospaceFont(weight: .semibold)
        let textHeight = lineHeight - Self.verticalInset * 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail

        for (index, line) in lines.enumerated() {
            let y = CGFloat(index) * lineHeight
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: lineHeight)
            guard rowRect.intersects(dirtyRect) else { continue }
            line.background.setFill()
            rowRect.fill()

            let textRect = rowRect.insetBy(dx: 0, dy: Self.verticalInset)
            let gutterRect = NSRect(x: 0, y: textRect.minY, width: Self.gutterWidth, height: textHeight)
            let contentRect = NSRect(
                x: Self.gutterWidth + Self.gutterGap,
                y: textRect.minY,
                width: max(0, bounds.width - Self.gutterWidth - Self.gutterGap),
                height: textHeight
            )
            NSAttributedString(string: line.gutter, attributes: [
                .font: monoBold, .foregroundColor: line.color, .paragraphStyle: paragraph
            ]).draw(with: gutterRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSAttributedString(string: line.content.isEmpty ? " " : line.content, attributes: [
                .font: mono, .foregroundColor: line.color
            ]).draw(with: contentRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func accessibilityChildren() -> [Any]? { lineAccessibilityElements }

    private static func monospaceFont(weight: NSFont.Weight) -> NSFont {
        NativeTranscriptFont.code(weight)
    }

    private var lineHeight: CGFloat {
        let font = Self.monospaceFont(weight: .regular)
        return ceil(font.ascender - font.descender + font.leading) + Self.verticalInset * 2
    }

    private func rebuildAccessibilityElements() {
        lineAccessibilityElements = lines.map { line in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel("\(line.gutter) \(line.content)")
            return element
        }
        updateAccessibilityFrames()
    }

    private func updateAccessibilityFrames() {
        for (index, element) in lineAccessibilityElements.enumerated() {
            element.setAccessibilityFrameInParentSpace(
                NSRect(x: 0, y: CGFloat(index) * lineHeight, width: bounds.width, height: lineHeight)
            )
        }
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
        let mcpActivities = group.activities.filter(\.isMCPActivity)
        // Diff/recap look only at code tools, so keep web AND mcp out of them.
        let toolActivities = group.activities.filter { !$0.isWebActivity && !$0.isMCPActivity }

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
                        links: activity.webLinks.map { Web.Link(title: $0.title, url: $0.url, domain: $0.domain) }
                    )
                },
                hiddenCount: max(0, webActivities.count - display.count)
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

        var mcp: MCP?
        if visibility.showMCPCards, !mcpActivities.isEmpty {
            let calls = mcpActivities.flatMap { $0.mcpCalls() }
            if !calls.isEmpty {
                let display = Array(calls.prefix(6))
                mcp = MCP(
                    callCount: calls.count == 1 ? "1 call" : "\(calls.count) calls",
                    hasErrors: calls.contains { $0.isError },
                    rows: display.map { call in
                        MCP.Row(
                            id: call.id,
                            server: call.server,
                            tool: call.tool,
                            resultPreview: call.resultPreview,
                            imageReferences: visibility.showImages ? call.imageReferences : [],
                            resultBlocks: visibility.showImages ? call.resultBlocks : nil,
                            isError: call.isError,
                            errorSummary: call.isError ? mcpErrorSummary(call.resultPreview) : nil
                        )
                    },
                    hiddenCount: max(0, calls.count - display.count)
                )
            }
        }

        let allImageReferences = visibility.showImages ? toolActivities.flatMap(\.entries).flatMap(\.imageReferences) : []
        let images = allImageReferences.isEmpty ? nil : Images(
            references: Array(allImageReferences.prefix(8)),
            hiddenCount: max(0, allImageReferences.count - 8)
        )

        guard web != nil || diff != nil || mcp != nil || images != nil else { return nil }
        return NativeToolGroupModel(web: web, diff: diff, mcp: mcp, images: images)
    }

    /// Fast, pure estimate for the native tool-group card before AppKit has built
    /// and measured the real row. Keep this model-based: `heightOfRow` can call it
    /// on the scroll path, so it must not instantiate views or force layout.
    func estimatedContentHeight(forWidth rowWidth: CGFloat) -> CGFloat {
        let sectionWidth = max(1, min(rowWidth, PiAgentBubbleWidth.replyCap(for: rowWidth)))
        let sections: [CGFloat] = [
            mcp.map { Self.estimatedMCPHeight($0, width: sectionWidth) },
            web.map { Self.estimatedWebHeight($0, width: sectionWidth) },
            images.map { Self.estimatedImagesHeight($0, width: sectionWidth) },
            diff.map { Self.estimatedDiffHeight($0, width: sectionWidth) }
        ].compactMap { $0 }
        guard !sections.isEmpty else { return 1 }
        return sections.reduce(0, +) + CGFloat(sections.count - 1) * Self.estimateSectionSpacing
    }

    private static let estimateSectionSpacing: CGFloat = 8
    private static let estimateHeaderHeight: CGFloat = 18
    private static let estimateTitleRowHeight: CGFloat = 26
    private static let estimateLineHeight: CGFloat = 18
    private static let estimateSmallLineHeight: CGFloat = 16
    private static let estimateMCPImageTileWidth: CGFloat = 104
    private static let estimateMCPImageTileHeight: CGFloat = 104
    private static let estimateMCPImageSpacing: CGFloat = 8
    private static let estimateInlineLinkLimit = 5

    private static func estimatedMCPHeight(_ mcp: MCP, width: CGFloat) -> CGFloat {
        var items = [estimateHeaderHeight]
        items.append(contentsOf: mcp.rows.map { estimatedMCPRowHeight($0, width: width - AppTheme.Chat.cardHPadding * 2) })
        if mcp.hiddenCount > 0 { items.append(estimateLineHeight) }
        return estimatedSubcardHeight(items: items, spacing: 10, vInset: AppTheme.Chat.cardVPadding)
    }

    private static func estimatedMCPRowHeight(_ row: MCP.Row, width: CGFloat) -> CGFloat {
        var height = estimateTitleRowHeight
        if !row.imageReferences.isEmpty {
            height += 6 + estimatedImageStripHeight(count: min(row.imageReferences.count, 6), width: max(1, width - 23))
            if row.imageReferences.count > 6 { height += 5 + estimateSmallLineHeight }
        }
        if let summary = row.errorSummary, !summary.isEmpty {
            height += 6 + estimatedWrappedTextHeight(summary, width: max(1, width - 23), maxLines: 2)
        }
        return height
    }

    private static func estimatedWebHeight(_ web: Web, width: CGFloat) -> CGFloat {
        var items = [estimateHeaderHeight]
        items.append(contentsOf: web.rows.map { estimatedWebRowHeight($0) })
        if web.hiddenCount > 0 { items.append(estimateLineHeight) }
        return estimatedSubcardHeight(items: items, spacing: 10, vInset: AppTheme.Chat.cardVPadding)
    }

    private static func estimatedWebRowHeight(_ row: Web.Row) -> CGFloat {
        guard !row.links.isEmpty else { return estimateTitleRowHeight }
        let shownLinks = min(row.links.count, estimateInlineLinkLimit)
        let moreHeight: CGFloat = row.links.count > estimateInlineLinkLimit ? 24 : 0
        return estimateTitleRowHeight + 6 + CGFloat(shownLinks) * 22 + moreHeight
    }

    private static func estimatedImagesHeight(_ images: Images, width: CGFloat) -> CGFloat {
        let innerWidth = max(1, width - 24)
        let strip = estimatedImageStripHeight(count: min(images.references.count, 6), width: innerWidth)
        let hidden: CGFloat = images.references.count > 6 ? 5 + estimateSmallLineHeight : 0
        return estimatedSubcardHeight(items: [estimateHeaderHeight, strip + hidden], spacing: 8, vInset: 10)
    }

    private static func estimatedDiffHeight(_ diff: Diff, width: CGFloat) -> CGFloat {
        var items = [estimateHeaderHeight]
        items.append(contentsOf: diff.rows.map { estimatedDiffRowHeight($0, width: width - AppTheme.Chat.cardHPadding * 2) })
        return estimatedSubcardHeight(items: items, spacing: 7, vInset: AppTheme.Chat.cardVPadding)
    }

    private static func estimatedDiffRowHeight(_ row: PiAgentThreadDiffSummaryView.Row, width: CGFloat) -> CGFloat {
        let meaningfulLineCount = estimatedMeaningfulDiffLineCount(row.diff)
        let visibleLines = min(meaningfulLineCount, 10)
        let expander: CGFloat = meaningfulLineCount > 10 ? 27 : 0
        return estimateTitleRowHeight + 4 + CGFloat(visibleLines) * 22 + expander
    }

    private static func estimatedSubcardHeight(items: [CGFloat], spacing: CGFloat, vInset: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return vInset * 2 + items.reduce(0, +) + CGFloat(items.count - 1) * spacing
    }

    private static func estimatedImageStripHeight(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let perRow = max(1, Int((width + estimateMCPImageSpacing) / (estimateMCPImageTileWidth + estimateMCPImageSpacing)))
        let rows = (count + perRow - 1) / perRow
        return CGFloat(rows) * estimateMCPImageTileHeight + CGFloat(max(0, rows - 1)) * estimateMCPImageSpacing
    }

    private static func estimatedWrappedTextHeight(_ text: String, width: CGFloat, maxLines: Int) -> CGFloat {
        let charsPerLine = max(Int(width / 7), 18)
        let lines = min(maxLines, max(1, (text.count + charsPerLine - 1) / charsPerLine))
        return CGFloat(lines) * estimateLineHeight
    }

    private static func estimatedMeaningfulDiffLineCount(_ diff: String) -> Int {
        diff.split(separator: "\n", omittingEmptySubsequences: false).filter { raw in
            guard !raw.hasPrefix("diff --git"), !raw.hasPrefix("index "), !raw.hasPrefix("---"), !raw.hasPrefix("+++") else { return false }
            return raw.hasPrefix("+") || raw.hasPrefix("-") || raw.hasPrefix("@@")
        }.count
    }

    private static func callCountText(_ activities: [PiAgentTranscriptActivity]) -> String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    /// A short, single-line error message for an error row: the human-readable text
    /// before any JSON body (the full detail lives behind "View"). Trims a trailing
    /// colon and collapses whitespace so it reads as one clean line.
    private static func mcpErrorSummary(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let head: Substring
        if let jsonStart = text.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            head = text[..<jsonStart]
        } else {
            head = text[...]
        }
        let collapsed = head
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let cleaned = collapsed.hasSuffix(":") ? String(collapsed.dropLast()).trimmingCharacters(in: .whitespaces) : collapsed
        return cleaned.isEmpty ? nil : cleaned
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

    private static func toolVerb(for name: String) -> String {
        switch name.lowercased() {
        case "bash": return "Shell"
        case "read": return "Read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "set_session_plan", "update_session_plan": return "Plan"
        case "subagent": return "Agent"
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

    /// Session-wide per-tool recap (non-web tool calls only), surfaced in the
    /// Session resources popover rather than inline in the transcript. Groups every
    /// tool/error entry by display verb, summing successes and errors across the
    /// whole conversation. Tool errors carry a `Tool: ` title prefix, so model
    /// errors (and other `.error` rows) are excluded.
    @MainActor
    static func toolCallRecap(from entries: [PiAgentTranscriptEntry]) -> [PiAgentToolCallRecapItem] {
        let relevant = entries.filter { $0.role == .tool || ($0.role == .error && $0.title.hasPrefix("Tool: ")) }
        var order: [String] = []
        var byVerb: [String: PiAgentToolCallRecapItem] = [:]
        // MCP gets its own recap section (`mcpUsageRecap`); never fold it in here.
        for activity in PiAgentTranscriptActivity.make(from: relevant) where !activity.isWebActivity && !activity.isMCPActivity {
            let verb = toolVerb(for: activity.name)
            let errors = activity.entries.filter { $0.role == .error }.count
            let success = max(0, activity.count - errors)
            if var existing = byVerb[verb] {
                existing.successCount += success
                existing.errorCount += errors
                byVerb[verb] = existing
            } else {
                order.append(verb)
                byVerb[verb] = PiAgentToolCallRecapItem(
                    icon: toolIcon(for: activity.name),
                    name: verb,
                    successCount: success,
                    errorCount: errors
                )
            }
        }
        return order.compactMap { byVerb[$0] }
    }

    /// Session-wide MCP usage recap for the Session resources popover: every MCP tool
    /// actually called, grouped by server then tool, with per-tool call counts. Built
    /// from the `mcp` proxy entries (action == call) across the whole conversation.
    @MainActor
    static func mcpUsageRecap(from entries: [PiAgentTranscriptEntry]) -> [PiAgentMCPUsageRecapServer] {
        let relevant = entries.filter { $0.role == .tool || ($0.role == .error && $0.title.hasPrefix("Tool: ")) }
        let calls = PiAgentTranscriptActivity.make(from: relevant)
            .filter(\.isMCPActivity)
            .flatMap { $0.mcpCalls() }
        guard !calls.isEmpty else { return [] }

        var serverOrder: [String] = []
        var toolOrderByServer: [String: [String]] = [:]
        var counts: [String: [String: (calls: Int, errors: Int)]] = [:]
        for call in calls {
            if counts[call.server] == nil { serverOrder.append(call.server) }
            if counts[call.server]?[call.tool] == nil {
                toolOrderByServer[call.server, default: []].append(call.tool)
            }
            var tally = counts[call.server]?[call.tool] ?? (0, 0)
            tally.calls += 1
            if call.isError { tally.errors += 1 }
            counts[call.server, default: [:]][call.tool] = tally
        }

        return serverOrder.map { server in
            let tools = (toolOrderByServer[server] ?? []).map { tool -> PiAgentMCPUsageRecapTool in
                let tally = counts[server]?[tool] ?? (0, 0)
                return PiAgentMCPUsageRecapTool(name: tool, callCount: tally.calls, errorCount: tally.errors)
            }
            return PiAgentMCPUsageRecapServer(server: server, tools: tools)
        }
    }
}

/// One MCP server's usage in the Session resources recap: the server name and the
/// tools it was called through, each with its call/error counts.
struct PiAgentMCPUsageRecapServer: Identifiable {
    var id: String { server }
    var server: String
    var tools: [PiAgentMCPUsageRecapTool]
}

struct PiAgentMCPUsageRecapTool: Identifiable {
    var id: String { name }
    var name: String
    var callCount: Int
    var errorCount: Int
}

/// One MCP server in the Session resources popover: recorded in scope at launch
/// (with the count of tools it advertised) plus the tools actually called this
/// session. Mirrors the Skills section's "recorded at startup" listing, then adds
/// the live usage breakdown.
struct PiAgentMCPSessionRecap: Identifiable {
    var id: String { server }
    var server: String
    var advertisedToolCount: Int
    var calledTools: [PiAgentMCPUsageRecapTool]
}

/// One row in the Session resources "Tool calls" recap: a tool's display verb,
/// its icon, and aggregate success/error counts across the session.
struct PiAgentToolCallRecapItem: Identifiable {
    var id: String { name }
    var icon: String
    var name: String
    var successCount: Int
    var errorCount: Int
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
    private static let imagesCardIdentifier = NSUserInterfaceItemIdentifier("PiAgentNativeToolGroupImagesCard")
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
        mcpResultByRowID.removeAll()
        guard let model else { return }
        if let mcp = model.mcp { sections.addArrangedSubview(buildMCPCard(mcp)) }
        if let web = model.web { sections.addArrangedSubview(buildWebCard(web)) }
        if let images = model.images { sections.addArrangedSubview(buildImagesCard(images)) }
        if let diff = model.diff { sections.addArrangedSubview(buildDiffCard(diff)) }
        for view in sections.arrangedSubviews where view.identifier != Self.imagesCardIdentifier {
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

    /// The "+N −M" change count with the additions tinted green and deletions red
    /// (design-system diff colors); "modified" stays muted.
    private static func diffCountLabel(_ text: String) -> NSTextField {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NativeTranscriptFont.calloutSize, weight: .semibold)
        guard text.hasPrefix("+") || text.hasPrefix("−") else {
            return label(text, font: font, color: muted)
        }
        let added = AppTheme.ns(AppTheme.diffAdded)
        let removed = AppTheme.ns(AppTheme.diffRemoved)
        let attr = NSMutableAttributedString()
        for (i, part) in text.split(separator: " ").enumerated() {
            if i > 0 { attr.append(NSAttributedString(string: "  ")) }
            let color = part.hasPrefix("+") ? added : removed
            attr.append(NSAttributedString(string: String(part), attributes: [.font: font, .foregroundColor: color]))
        }
        let field = NSTextField(labelWithAttributedString: attr)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A sub-card header glyph on the shared transcript header scale (16pt box,
    /// `headerIcon`), so "Web"/"Changes" titles read at the same size as the
    /// memory / status / bubble cards rather than a smaller competing scale.
    private static func headerGlyph(_ name: String, isAsset: Bool = false, tint: NSColor) -> NSImageView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.image = isAsset ? NSImage(named: name) : NativeTranscriptFont.headerIcon(name)
        view.contentTintColor = tint
        view.imageScaling = .scaleProportionallyDown
        view.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize),
            view.heightAnchor.constraint(equalToConstant: NativeTranscriptFont.headerIconSize)
        ])
        return view
    }

    private static func label(_ text: String, font: NSFont, color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let f = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.font = font
        f.textColor = color
        f.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return f
    }

    private static func headerLabel(_ text: String) -> NSTextField {
        let field = label(text, font: NativeTranscriptFont.header)
        NativeTranscriptFont.configureHeaderLabel(field)
        return field
    }

    // MARK: MCP card

    private func buildMCPCard(_ mcp: NativeToolGroupModel.MCP) -> NSView {
        let card = makeSubCard()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        // Header: MCP glyph + "MCP" only — no call count (the Changes card
        // carries no count either; the rows speak for themselves).
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.addArrangedSubview(Self.headerGlyph(AppSymbols.mcp, isAsset: true, tint: mcp.hasErrors ? AppTheme.ns(AppTheme.roleError) : Self.muted))
        header.addArrangedSubview(Self.headerLabel(LanguageStore.shared.t("tool.mcp")))
        stack.addArrangedSubview(header)

        for row in mcp.rows {
            let rowView = buildMCPRow(row)
            stack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if mcp.hiddenCount > 0 {
            stack.addArrangedSubview(Self.label("\(mcp.hiddenCount) more MCP call\(mcp.hiddenCount == 1 ? "" : "s") hidden",
                                                font: NativeTranscriptFont.callout(), color: Self.muted))
        }

        embed(stack, in: card, hInset: AppTheme.Chat.cardHPadding, vInset: AppTheme.Chat.cardVPadding)
        return card
    }

    /// One MCP call: a `server/tool` headline (tool emphasized) with a trailing "View"
    /// button that opens the full response in a modal (mirroring the Changes card's
    /// "Open"; Copy lives inside that modal). The raw response is never dumped inline,
    /// and the args are not shown — the headline is the call, the modal is the detail.
    private func buildMCPRow(_ row: NativeToolGroupModel.MCP.Row) -> NSView {
        let titleRow = NSStackView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.orientation = .horizontal
        titleRow.spacing = 7
        titleRow.alignment = .centerY

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: row.isError ? "exclamationmark.triangle" : "bolt.horizontal",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .semibold))
        icon.contentTintColor = row.isError ? AppTheme.ns(AppTheme.roleError) : Self.muted
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        titleRow.addArrangedSubview(icon)

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "\(row.server)/", attributes: [
            .font: NativeTranscriptFont.callout(), .foregroundColor: Self.muted
        ]))
        title.append(NSAttributedString(string: row.tool, attributes: [
            .font: NativeTranscriptFont.callout(.semibold), .foregroundColor: NSColor.labelColor
        ]))
        let titleField = NSTextField(labelWithAttributedString: title)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(titleField)

        titleRow.addArrangedSubview(NSView())  // spacer pushes the buttons to the trailing edge

        // Both success and error responses get a View button — an error IS the
        // response, and the user must be able to read it (Copy is inside the modal).
        if let result = row.resultPreview, !result.isEmpty {
            mcpResultByRowID[row.id.uuidString] = (server: row.server, tool: row.tool, result: result, blocks: row.resultBlocks)
            let viewBtn = NSButton(title: LanguageStore.shared.t("tool.view"), target: self, action: #selector(openMCPResult(_:)))
            viewBtn.bezelStyle = .rounded
            viewBtn.controlSize = .small
            viewBtn.font = NativeTranscriptFont.caption2(.semibold)
            viewBtn.identifier = NSUserInterfaceItemIdentifier(row.id.uuidString)
            titleRow.addArrangedSubview(viewBtn)
        }

        let thumbnails = mcpImageStrip(row.imageReferences)
        guard (row.errorSummary?.isEmpty == false) || thumbnails != nil else { return titleRow }
        let rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 6
        rowStack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true

        if let thumbnails {
            let imageIndent = NSStackView(views: [thumbnails])
            imageIndent.translatesAutoresizingMaskIntoConstraints = false
            imageIndent.orientation = .horizontal
            imageIndent.edgeInsets = NSEdgeInsets(top: 0, left: 23, bottom: 0, right: 0)
            rowStack.addArrangedSubview(imageIndent)
        }

        guard let summary = row.errorSummary, !summary.isEmpty else { return rowStack }
        let errorLabel = Self.label(summary, font: NativeTranscriptFont.callout(), color: AppTheme.ns(AppTheme.roleError), wraps: true)
        errorLabel.maximumNumberOfLines = 2
        // Align under the headline text (16pt icon + 7pt gap), matching the title inset.
        let indent = NSStackView(views: [errorLabel])
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 23, bottom: 0, right: 0)
        rowStack.addArrangedSubview(indent)
        indent.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        return rowStack
    }

    private func mcpImageStrip(_ references: [PiAgentTranscriptImageReference]) -> NSView? {
        guard !references.isEmpty else { return nil }
        let wrap = NSStackView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = 5

        let flow = NativeFlowLayoutView()
        flow.hSpacing = 8
        flow.vSpacing = 8
        let tiles = references.prefix(6).map { reference in
            let image = PiAgentNativeTranscriptImageAttachmentView()
            image.configure(reference: reference, caption: reference.name, width: 104, style: .tile)
            return image
        }
        flow.setItems(tiles)
        wrap.addArrangedSubview(flow)
        flow.widthAnchor.constraint(equalTo: wrap.widthAnchor).isActive = true

        let hidden = references.count - tiles.count
        if hidden > 0 {
            wrap.addArrangedSubview(Self.label("+\(hidden) more", font: NativeTranscriptFont.caption2(), color: .tertiaryLabelColor, wraps: false))
        }
        return wrap
    }

    private func buildImagesCard(_ images: NativeToolGroupModel.Images) -> NSView {
        let card = makeSubCard()
        card.identifier = Self.imagesCardIdentifier
        card.setContentHuggingPriority(.required, for: .horizontal)
        card.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.addArrangedSubview(Self.headerGlyph("photo", tint: Self.muted))
        header.addArrangedSubview(Self.headerLabel(LanguageStore.shared.t("tool.images")))
        header.addArrangedSubview(Self.label(images.references.count == 1 ? "1 image" : "\(images.references.count) images", font: NativeTranscriptFont.caption2(), color: .secondaryLabelColor, wraps: false))
        if images.hiddenCount > 0 {
            header.addArrangedSubview(Self.label("+\(images.hiddenCount) more", font: NativeTranscriptFont.caption2(), color: .tertiaryLabelColor, wraps: false))
        }
        stack.addArrangedSubview(header)

        let thumbnails = mcpImageStrip(images.references) ?? NSView()
        stack.addArrangedSubview(thumbnails)
        thumbnails.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        thumbnails.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor).isActive = true
        thumbnails.widthAnchor.constraint(equalToConstant: imageStripWidth(for: images.references)).isActive = true

        embed(stack, in: card, hInset: 12, vInset: 10)
        return card
    }

    private func imageStripWidth(for references: [PiAgentTranscriptImageReference]) -> CGFloat {
        let shownCount = min(references.count, 6)
        guard shownCount > 0 else { return 0 }
        let tileWidth: CGFloat = 104
        let spacing: CGFloat = 8
        let naturalWidth = CGFloat(shownCount) * tileWidth + CGFloat(max(0, shownCount - 1)) * spacing
        // Keep the card content-hugged for short image summaries, but cap it to the
        // reply column so larger sets wrap instead of overflowing the transcript row.
        let availableWidth = max(tileWidth, sectionsWidthC.constant - 12 * 2)
        return min(naturalWidth, availableWidth)
    }

    private var mcpResultByRowID: [String: (server: String, tool: String, result: String, blocks: [PiAgentMCPResultBlock]?)] = [:]

    /// Present the full MCP response in a modal (hosting the SwiftUI sheet — a modal
    /// is not a scroll hot path), mirroring how the diff "Open" button works.
    @objc private func openMCPResult(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let call = mcpResultByRowID[raw],
              let host = window?.contentViewController else { return }
        var hosting: NSViewController?
        let sheet = PiAgentNativeMCPResultSheet(server: call.server, tool: call.tool, text: call.result, blocks: call.blocks) { [weak host] in
            if let hosting { host?.dismiss(hosting) }
        }
        let controller = NSHostingController(rootView: sheet)
        hosting = controller
        host.presentAsSheet(controller)
    }

    // MARK: Web card

    private func buildWebCard(_ web: NativeToolGroupModel.Web) -> NSView {
        let card = makeSubCard()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        // Header: globe + title on the left, call count pinned to the right edge.
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        let globe = Self.headerGlyph("globe", tint: web.hasErrors ? AppTheme.ns(AppTheme.roleError) : Self.muted)
        header.addArrangedSubview(globe)
        header.addArrangedSubview(Self.headerLabel(web.title))
        stack.addArrangedSubview(header)

        for row in web.rows {
            let rowView = buildWebRow(row)
            stack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if web.hiddenCount > 0 {
            let suffix = web.hiddenCount == 1 ? "" : "s"
            stack.addArrangedSubview(Self.label("\(web.hiddenCount) older web update\(suffix) hidden",
                                                font: NativeTranscriptFont.callout(), color: Self.muted))
        }

        embed(stack, in: card, hInset: AppTheme.Chat.cardHPadding, vInset: AppTheme.Chat.cardVPadding)
        return card
    }

    /// 14pt icon column + 7pt gap, so the indented source rows (which carry the
    /// same 21pt leading inset) line up under the query title.
    private static let webRowIndent: CGFloat = 23

    private func buildWebRow(_ row: NativeToolGroupModel.Web.Row) -> NSView {
        let rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 6

        let hasLinks = !row.links.isEmpty

        // Primary line: icon + headline. For searches the query itself is the
        // headline (the source rows give it context); other calls show the verb
        // (bold) followed by their detail (muted), separated by weight not a glyph.
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 7
        titleRow.alignment = .centerY
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: row.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.captionSize, weight: .semibold))
        icon.contentTintColor = row.isError ? AppTheme.ns(AppTheme.roleError) : Self.muted
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        titleRow.addArrangedSubview(icon)
        if hasLinks {
            let query = (row.detail?.isEmpty == false) ? row.detail! : row.title
            let p = Self.label(query, font: NativeTranscriptFont.callout(.semibold))
            p.lineBreakMode = .byTruncatingTail
            titleRow.addArrangedSubview(p)
        } else {
            titleRow.addArrangedSubview(Self.label(row.title, font: NativeTranscriptFont.callout(.semibold)))
            if let detail = row.detail, !detail.isEmpty {
                let d = Self.label(detail, font: NativeTranscriptFont.callout(), color: Self.muted)
                d.lineBreakMode = .byTruncatingMiddle
                titleRow.addArrangedSubview(d)
            }
        }
        rowStack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true

        // Source rows: tappable, open the URL, indented under the query.
        if hasLinks {
            let expanded = expandedWebRows.contains(row.id)
            let shown = expanded ? row.links : Array(row.links.prefix(Self.inlineLinkLimit))
            let sources = NSStackView()
            sources.translatesAutoresizingMaskIntoConstraints = false
            sources.orientation = .vertical
            sources.alignment = .leading
            sources.spacing = 1
            for link in shown {
                let sourceRow = PiAgentNativeWebSourceRow(leadingInset: Self.webRowIndent)
                sourceRow.configure(title: link.title, domain: link.domain, url: link.url)
                sources.addArrangedSubview(sourceRow)
                sourceRow.widthAnchor.constraint(equalTo: sources.widthAnchor).isActive = true
            }
            if row.links.count > Self.inlineLinkLimit {
                let more = NSButton(title: expanded ? LanguageStore.shared.t("tool.showFewer") : LanguageStore.shared.t("tool.moreResults", row.links.count - Self.inlineLinkLimit),
                                    target: self, action: #selector(toggleWebRow(_:)))
                more.isBordered = false
                more.bezelStyle = .inline
                more.font = NativeTranscriptFont.callout(.semibold)
                more.contentTintColor = AppTheme.ns(AppTheme.brandAccent)
                more.identifier = NSUserInterfaceItemIdentifier(row.id.uuidString)
                let wrap = NSStackView(views: [more])
                wrap.edgeInsets = NSEdgeInsets(top: 2, left: Self.webRowIndent, bottom: 0, right: 0)
                sources.addArrangedSubview(wrap)
            }
            rowStack.addArrangedSubview(sources)
            sources.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        return rowStack
    }

    @objc private func toggleWebRow(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        if expandedWebRows.contains(id) { expandedWebRows.remove(id) } else { expandedWebRows.insert(id) }
        rebuildSections()
        notifyContentHeightChanged()
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
        header.alignment = .centerY
        header.addArrangedSubview(Self.headerGlyph("plusminus", tint: Self.muted))
        header.addArrangedSubview(Self.headerLabel(LanguageStore.shared.t("tool.changes")))
        stack.addArrangedSubview(header)

        for row in diff.rows {
            let rowView = buildDiffRow(row)
            stack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let hidden = diff.rows.count > 4 ? diff.rows.count - 4 : 0
        if hidden > 0 {
            stack.addArrangedSubview(Self.label("\(hidden) more changed file\(hidden == 1 ? "" : "s") hidden",
                                                font: NativeTranscriptFont.callout(), color: Self.muted))
        }

        embed(stack, in: card, hInset: AppTheme.Chat.cardHPadding, vInset: AppTheme.Chat.cardVPadding)
        return card
    }

    private func buildDiffRow(_ row: PiAgentThreadDiffSummaryView.Row) -> NSView {
        // No per-file inner card surface: the outer card + the +/- line
        // backgrounds already carry the row, and stacking surfaces makes the
        // Changes card read as "card-in-card" heavy.
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 8
        head.alignment = .centerY
        let pathLabel = Self.label(row.path.truncatedMiddle(max: 54), font: NativeTranscriptFont.callout(.semibold))
        pathLabel.lineBreakMode = .byTruncatingMiddle
        head.addArrangedSubview(pathLabel)
        head.addArrangedSubview(Self.diffCountLabel(row.changeCountText))
        head.addArrangedSubview(NSView())  // spacer
        let openBtn = NSButton(title: LanguageStore.shared.t("tool.open"), target: self, action: #selector(openDiff(_:)))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .small
        openBtn.font = NativeTranscriptFont.caption2(.semibold)
        openBtn.identifier = NSUserInterfaceItemIdentifier(row.path)
        let copyBtn = NSButton(title: LanguageStore.shared.t("tool.copy"), target: self, action: #selector(copyDiff(_:)))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        copyBtn.font = NativeTranscriptFont.caption2(.semibold)
        copyBtn.identifier = NSUserInterfaceItemIdentifier(row.path)
        diffByPath[row.path] = row
        head.addArrangedSubview(openBtn)
        head.addArrangedSubview(copyBtn)
        stack.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let preview = buildDiffPreview(for: row)
        stack.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
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

        let preview = NativeDiffPreviewView(lines: visible)
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        if lines.count > 10 {
            let title = expanded ? "Show fewer lines" : "Show \(lines.count - 10) more lines"
            let symbol = expanded ? "chevron.up" : "chevron.down"
            let more = NSButton(title: " " + title, target: self, action: #selector(toggleDiffRow(_:)))
            more.isBordered = false
            more.bezelStyle = .inline
            more.font = NativeTranscriptFont.callout()
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

    private static func meaningfulDiffLines(_ diff: String) -> [NativeDiffPreviewLine] {
        let added = AppTheme.ns(AppTheme.diffAdded)
        let removed = AppTheme.ns(AppTheme.diffRemoved)
        let addedBg = AppTheme.ns(AppTheme.diffAdded.opacity(AppTheme.roleFillStrongOpacity))
        let removedBg = AppTheme.ns(AppTheme.diffRemoved.opacity(AppTheme.roleFillStrongOpacity))
        return diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            guard !line.hasPrefix("diff --git"), !line.hasPrefix("index "), !line.hasPrefix("---"), !line.hasPrefix("+++") else { return false }
            return line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@")
        }.map { raw in
            if raw.hasPrefix("@@") {
                return NativeDiffPreviewLine(gutter: "…", content: raw, color: Self.muted, background: .clear)
            }
            guard let first = raw.first, first == "+" || first == "-" || first == " " else {
                return NativeDiffPreviewLine(gutter: " ", content: raw.trimmingCharacters(in: .whitespaces), color: Self.muted, background: .clear)
            }
            let prefix = String(first)
            let trimmedLeading = raw.dropFirst().drop(while: { $0 == " " })
            let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
            let content = String(trimmedLeading.dropFirst(numberPart.count).drop(while: { $0 == " " }))
            let gutter = numberPart.isEmpty ? prefix : "\(prefix) \(numberPart)"
            let color: NSColor = first == "+" ? added : (first == "-" ? removed : Self.muted)
            let bg: NSColor = first == "+" ? addedBg : (first == "-" ? removedBg : .clear)
            return NativeDiffPreviewLine(gutter: gutter, content: content, color: color, background: bg)
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
        // Text-only button: confirm by swapping the title briefly.
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { sender.title = "Copy" }
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
        mcpResultByRowID.removeAll()
    }
}

// MARK: - Web source row

/// One tappable web source: the page title, its domain (muted), and a trailing
/// chevron. Highlights on hover; opens the URL on click. Carries its own leading
/// inset so it aligns under the query title without a bullet marker.
private final class PiAgentNativeWebSourceRow: NativeAccessiblePressableView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let domainLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var url: String = ""
    private var trackingArea: NSTrackingArea?

    private let vPad: CGFloat = 3
    private static let muted = AppTheme.ns(AppTheme.mutedText)
    private static let accent = AppTheme.ns(AppTheme.brandAccent)
    // Shared row-hover highlight from the design system (selection fill).
    private static let hoverFill = AppTheme.ns(AppTheme.selectionFill)

    init(leadingInset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.Chat.chipCornerRadius
        layer?.cornerCurve = .continuous
        layer?.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Callout (13) — card content reads at the message scale, matching the Pi
        // response body rather than a smaller competing size.
        titleLabel.font = NativeTranscriptFont.callout()
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        domainLabel.translatesAutoresizingMaskIntoConstraints = false
        domainLabel.font = NativeTranscriptFont.callout()
        domainLabel.textColor = Self.muted
        domainLabel.lineBreakMode = .byTruncatingMiddle
        domainLabel.maximumNumberOfLines = 1
        domainLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(domainLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NativeTranscriptFont.calloutSize, weight: .semibold))
        chevron.contentTintColor = Self.muted
        chevron.imageScaling = .scaleNone
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: vPad),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vPad),

            domainLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
            domainLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            domainLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])

        pressAction = { [weak self] in self?.openSource() }
        setAccessibilityHelp("Press Return or Space to open this web source.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func configure(title: String, domain: String, url: String) {
        self.url = url
        let displayTitle = title.isEmpty ? domain : title
        titleLabel.stringValue = displayTitle
        // Skip the domain when the title already is the domain (no redundancy).
        domainLabel.stringValue = (displayTitle == domain) ? "" : domain
        domainLabel.isHidden = domainLabel.stringValue.isEmpty
        toolTip = url
        setAccessibilityLabel(LanguageStore.shared.t("tool.openWebSource", displayTitle))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = on ? Self.hoverFill.cgColor : NSColor.clear.cgColor
        }
        chevron.contentTintColor = on ? Self.accent : Self.muted
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func openSource() {
        guard let link = URL(string: url) else { return }
        NSWorkspace.shared.open(link)
    }
}

// MARK: - Flow layout

/// A minimal flow (wrapping) layout container: arranges its item views left to
/// right, wrapping to the next line when the next item would overflow the
/// available width. Items are framed manually; the view drives its own height
/// via a constraint so it measures correctly inside the auto-laid-out tool-group
/// sections stack. Used for the horizontal tool-call list, which wraps to a
/// second line only when many distinct tools don't fit one line.
final class NativeFlowLayoutView: NSView {
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 6
    private var items: [NSView] = []
    private var heightC: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightC = heightAnchor.constraint(equalToConstant: 0)
        heightC.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setItems(_ views: [NSView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        for view in views {
            // We position items by frame, so opt them out of Auto Layout here
            // (their own internal subviews still lay out automatically). Seed the
            // frame to the item's content fitting size *before* flipping
            // `translatesAutoresizingMaskIntoConstraints`: flipping it while the
            // frame is still `.zero` generates `width == 0` / `height == 0`
            // autoresizing constraints that conflict with the item's own content
            // min-width (icon + labels), which AppKit logs-and-breaks on every
            // layout pass — the scroll-time constraint storm. A content-sized seed
            // makes the autoresizing constraints agree with the content.
            view.translatesAutoresizingMaskIntoConstraints = false
            view.frame = CGRect(origin: .zero, size: view.fittingSize)
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let maxWidth = bounds.width
        guard maxWidth > 0 else { return }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in items {
            let size = view.fittingSize
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = ceil(y + rowHeight)
        if abs(heightC.constant - total) > 0.5 { heightC.constant = total }
    }
}
