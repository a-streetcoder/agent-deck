import AppKit
import SwiftUI

// MARK: - External editors

struct ExternalCodeEditor: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String

    private static let preferredDefaultsKey = "piDeck.preferredExternalEditorBundleID"

    /// Known editors, VS Code first so it is the default preference when installed.
    private static let catalog: [(name: String, bundleIDs: [String])] = [
        // Short toolbar label — user expects "VS Code", not a truncated generic string.
        ("VS Code", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        ("Cursor", ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]),
        ("Windsurf", ["com.exafunction.windsurf"]),
        ("Zed", ["dev.zed.Zed"]),
        ("Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"]),
        ("Xcode", ["com.apple.dt.Xcode"]),
        ("TextEdit", ["com.apple.TextEdit"])
    ]

    /// Preferred installed editor for toolbar labels (VS Code when available).
    static func preferred() -> ExternalCodeEditor? {
        let list = installed()
        guard let id = preferredBundleID() else { return list.first }
        return list.first(where: { $0.bundleIdentifier == id }) ?? list.first
    }

    static func installed() -> [ExternalCodeEditor] {
        var result: [ExternalCodeEditor] = []
        var seen = Set<String>()
        for entry in catalog {
            for bundleID in entry.bundleIDs {
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
                   seen.insert(bundleID).inserted {
                    result.append(ExternalCodeEditor(id: bundleID, name: entry.name, bundleIdentifier: bundleID))
                    break
                }
            }
        }
        return result
    }

    static func preferredBundleID() -> String? {
        if let stored = UserDefaults.standard.string(forKey: preferredDefaultsKey),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: stored) != nil {
            return stored
        }
        // Default: VS Code when present, otherwise first installed known editor.
        let installed = installed()
        if let vscode = installed.first(where: { $0.bundleIdentifier.hasPrefix("com.microsoft.VSCode") }) {
            return vscode.bundleIdentifier
        }
        return installed.first?.bundleIdentifier
    }

    static func rememberPreferred(bundleID: String) {
        UserDefaults.standard.set(bundleID, forKey: preferredDefaultsKey)
    }
}

// MARK: - Animated trailing host (open/close + drag resize)

private struct TrailingReviewMainWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Permanently mounts the Review column and animates open/close.
/// Resize is un-animated (live pixel updates) so dragging does not spring/jitter.
struct TrailingReviewSplitHost<Main: View, Panel: View>: View {
    var isExpanded: Bool
    @Binding var panelWidth: CGFloat
    @ViewBuilder var main: () -> Main
    @ViewBuilder var panel: () -> Panel

    private let minWidth: CGFloat = 520
    private let maxWidth: CGFloat = 1100
    private let handleWidth: CGFloat = 6

    @State private var dragOriginWidth: CGFloat?
    @State private var isDragging = false
    @State private var mainColumnWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            main()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TrailingReviewMainWidthKey.self,
                            value: geo.size.width
                        )
                    }
                )

            // Resize handle sits between main and panel (only when open).
            resizeHandle
                .frame(width: isExpanded ? handleWidth : 0)
                .allowsHitTesting(isExpanded)
                // Handle width toggles with expand; never spring while dragging.
                .animation(isDragging ? nil : PanelTransition.move, value: isExpanded)

            panel()
                .frame(width: displayedWidth, alignment: .trailing)
                .frame(maxHeight: .infinity)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                // Open/close only — do NOT attach an animation to `panelWidth`.
                .animation(isDragging ? nil : PanelTransition.fade, value: isExpanded)
                .animation(isDragging ? nil : PanelTransition.move, value: isExpanded)
                // Explicitly freeze width-driven layout during drag (no spring chase).
                .transaction { txn in
                    if isDragging { txn.disablesAnimations = true }
                }
                .allowsHitTesting(isExpanded)
                .overlay(alignment: .leading) {
                    if isExpanded {
                        Rectangle()
                            .fill(AppTheme.hairlineStroke.opacity(0.7))
                            .frame(width: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        // Never animate the binding itself when the user is dragging.
        .animation(isDragging ? nil : PanelTransition.move, value: isExpanded)
        .onPreferenceChange(TrailingReviewMainWidthKey.self) { mainColumnWidth = $0 }
        .onChange(of: isExpanded) { _, expanded in
            // Fire *before* layout settles so transcript bubbles ease with the panel,
            // not half a beat after AppKit sees the final frame.
            postTranscriptWidthAnimation(expanding: expanded)
        }
    }

    private func postTranscriptWidthAnimation(expanding: Bool) {
        let measured = mainColumnWidth
        // Preference can lag one frame on first open — fall back to the key window.
        let currentMain = measured > 1
            ? measured
            : (NSApp.keyWindow?.contentView?.bounds.width ?? 900)
        let panel = clampedWidth
        // When expanding: main is still wide → target = current − panel − handle.
        // When collapsing: main is already narrow → target = current + panel + handle.
        let target: CGFloat
        if expanding {
            target = max(200, currentMain - panel - handleWidth)
        } else {
            target = max(200, currentMain + panel + handleWidth)
        }
        NotificationCenter.default.post(
            name: .transcriptColumnWillAnimateWidth,
            object: nil,
            userInfo: [
                "width": target,
                "duration": TranscriptLayoutAnimation.duration
            ]
        )
    }

    /// Collapsed → 0; expanded → clamped live width (no animation while dragging).
    private var displayedWidth: CGFloat {
        isExpanded ? clampedWidth : 0
    }

    private var clampedWidth: CGFloat {
        min(maxWidth, max(minWidth, panelWidth))
    }

    private var resizeHandle: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(AppTheme.hairlineStroke.opacity(isDragging ? 0.85 : 0.4))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            // set/arrow avoids push/pop stack thrash that can feel like cursor jitter.
            if hovering || isDragging {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOriginWidth == nil {
                        isDragging = true
                        dragOriginWidth = clampedWidth
                    }
                    let origin = dragOriginWidth ?? clampedWidth
                    // Handle left of panel: drag left → wider; right → narrower.
                    let next = origin - value.translation.width
                    let clamped = min(maxWidth, max(minWidth, next))
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        panelWidth = clamped
                    }
                }
                .onEnded { _ in
                    dragOriginWidth = nil
                    isDragging = false
                    NSCursor.arrow.set()
                }
        )
    }
}

// MARK: - Toolbar toggle (sits next to toolbar search)

struct PiAgentRepoReviewToolbarButton: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        Button {
            viewModel.toggleTrailingInspector()
        } label: {
            Label(languageStore.t("review.toolbar"), systemImage: "sidebar.trailing")
        }
        .accessibilityLabel(languageStore.t("review.toolbar"))
        .help(languageStore.t("review.toolbarHelp"))
        .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
    }
}

// MARK: - Codex-style full-file diff model

private enum FullFileDiffLineKind: Hashable {
    case context
    case added
    case removed
}

private struct FullFileDiffLine: Identifiable, Hashable {
    let id: Int
    let kind: FullFileDiffLineKind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

private enum FullFileDiffRow: Identifiable, Hashable {
    case line(FullFileDiffLine)
    case collapsed(id: Int, count: Int, range: Range<Int>)

    var id: Int {
        switch self {
        case let .line(line): return line.id
        case let .collapsed(id, _, _): return id
        }
    }
}

private enum FullFileDiffBuilder {
    /// Collapse runs of context longer than this (Codex-style).
    static let collapseThreshold = 10
    /// Keep this many context lines visible at each edge of a collapse.
    static let collapseEdgeKeep = 3

    static func parseLines(_ text: String) -> [FullFileDiffLine] {
        var result: [FullFileDiffLine] = []
        var oldLine = 0
        var newLine = 0
        var nextID = 0
        var inHunk = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("diff ") || raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                continue
            }
            if raw.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                if let parsed = parseHunkHeader(raw) {
                    oldLine = parsed.oldStart
                    newLine = parsed.newStart
                    inHunk = true
                }
                continue
            }
            guard inHunk, let first = raw.first else { continue }
            let body = String(raw.dropFirst())
            switch first {
            case " ":
                result.append(FullFileDiffLine(
                    id: nextID, kind: .context,
                    oldNumber: oldLine, newNumber: newLine, text: body
                ))
                nextID += 1
                oldLine += 1
                newLine += 1
            case "+":
                result.append(FullFileDiffLine(
                    id: nextID, kind: .added,
                    oldNumber: nil, newNumber: newLine, text: body
                ))
                nextID += 1
                newLine += 1
            case "-":
                result.append(FullFileDiffLine(
                    id: nextID, kind: .removed,
                    oldNumber: oldLine, newNumber: nil, text: body
                ))
                nextID += 1
                oldLine += 1
            case "\\":
                // "\ No newline at end of file"
                continue
            default:
                continue
            }
        }
        return result
    }

    static func rows(from lines: [FullFileDiffLine]) -> [FullFileDiffRow] {
        guard !lines.isEmpty else { return [] }
        return collapseContext(lines)
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        // @@ -12,3 +14,8 @@ optional
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 3,
              let oldR = Range(match.range(at: 1), in: line),
              let newR = Range(match.range(at: 2), in: line),
              let old = Int(line[oldR]),
              let new = Int(line[newR]) else { return nil }
        return (old, new)
    }

    private static func collapseContext(_ lines: [FullFileDiffLine]) -> [FullFileDiffRow] {
        var rows: [FullFileDiffRow] = []
        var index = 0
        var collapseIDSeed = 1_000_000_000
        while index < lines.count {
            let line = lines[index]
            if line.kind != .context {
                rows.append(.line(line))
                index += 1
                continue
            }
            // Measure consecutive context run
            var end = index
            while end < lines.count, lines[end].kind == .context {
                end += 1
            }
            let run = end - index
            if run <= collapseThreshold {
                for i in index..<end {
                    rows.append(.line(lines[i]))
                }
            } else {
                let keep = collapseEdgeKeep
                for i in index..<(index + keep) {
                    rows.append(.line(lines[i]))
                }
                let collapseStart = index + keep
                let collapseEnd = end - keep
                if collapseStart < collapseEnd {
                    rows.append(.collapsed(
                        id: collapseIDSeed,
                        count: collapseEnd - collapseStart,
                        range: collapseStart..<collapseEnd
                    ))
                    collapseIDSeed += 1
                }
                for i in (end - keep)..<end {
                    rows.append(.line(lines[i]))
                }
            }
            index = end
        }
        return rows
    }
}

/// Full-file unified diff with collapsible unmodified spans (Codex-style).
private struct FullFileDiffView: View {
    let diffText: String
    @State private var baseRows: [FullFileDiffRow] = []
    @State private var sourceLines: [FullFileDiffLine] = []

    private let gutterWidth: CGFloat = 48
    private let markerWidth: CGFloat = 14
    private let lineMinHeight: CGFloat = 20

    var body: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            // Width follows the longest source line — no forced soft-wrap.
            // Horizontal scroll handles long lines; vertical scroll follows file breaks.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(baseRows) { row in
                    switch row {
                    case let .line(line):
                        lineRow(line)
                    case let .collapsed(_, count, range):
                        collapseRow(count: count, range: range)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 560, alignment: .topLeading)
            .padding(.vertical, 6)
        }
        // Flush code surface — parent column owns chrome; avoid nested “card in card”.
        .background(AppTheme.textContentFill)
        .task(id: diffText) {
            let lines = FullFileDiffBuilder.parseLines(diffText)
            sourceLines = lines
            baseRows = FullFileDiffBuilder.rows(from: lines)
        }
    }

    private func collapseRow(count: Int, range: Range<Int>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandCollapsed(range: range)
            }
        } label: {
            HStack(spacing: 0) {
                // Align under the line-number gutter.
                Color.clear.frame(width: gutterWidth + 1)
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(LanguageStore.shared.t("review.unmodifiedLines", count))
                        .font(AppTheme.Font.caption.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AppTheme.mutedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(AppTheme.contentSubtleFill.opacity(0.85))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(AppTheme.hairlineStroke.opacity(0.55), lineWidth: 1)
                        )
                )
                .padding(.vertical, 6)
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LanguageStore.shared.t("review.expandUnmodified"))
    }

    private func expandCollapsed(range: Range<Int>) {
        var next: [FullFileDiffRow] = []
        for row in baseRows {
            if case let .collapsed(_, _, r) = row, r == range {
                for i in range where i < sourceLines.count {
                    next.append(.line(sourceLines[i]))
                }
            } else {
                next.append(row)
            }
        }
        baseRows = next
    }

    private func lineRow(_ line: FullFileDiffLine) -> some View {
        // Single gutter: prefer new-file line number; removed lines fall back to old.
        let gutter = line.newNumber ?? line.oldNumber
        let display = line.text.replacingOccurrences(of: "\t", with: "    ")
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Accent rail (Codex-style edge tint on changed lines)
            Rectangle()
                .fill(railColor(line.kind))
                .frame(width: 3)

            Text(gutter.map(String.init) ?? "")
                .font(AppTheme.Font.code)
                .monospacedDigit()
                .foregroundStyle(gutterColor(line.kind))
                .frame(width: gutterWidth - 3, alignment: .trailing)
                .padding(.trailing, 6)

            // Subtle gutter divider
            Rectangle()
                .fill(AppTheme.hairlineStroke.opacity(0.45))
                .frame(width: 1)
                .padding(.vertical, 1)

            Text(linePrefix(line.kind))
                .font(AppTheme.Font.code.weight(.semibold))
                .foregroundStyle(markerColor(line.kind))
                .frame(width: markerWidth, alignment: .center)

            Text(display.isEmpty ? " " : display)
                .font(AppTheme.Font.code)
                .foregroundStyle(lineTextColor(line.kind))
                .textSelection(.enabled)
                // One visual line == one source line; never soft-wrap in the gutter row.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: lineMinHeight, alignment: .center)
        .padding(.trailing, 14)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(line.kind))
    }

    private func linePrefix(_ kind: FullFileDiffLineKind) -> String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func railColor(_ kind: FullFileDiffLineKind) -> Color {
        switch kind {
        case .context: return .clear
        case .added: return AppTheme.diffAdded.opacity(0.95)
        case .removed: return AppTheme.diffRemoved.opacity(0.95)
        }
    }

    private func markerColor(_ kind: FullFileDiffLineKind) -> Color {
        switch kind {
        case .context: return AppTheme.mutedText.opacity(0.35)
        case .added: return AppTheme.diffAdded
        case .removed: return AppTheme.diffRemoved
        }
    }

    private func gutterColor(_ kind: FullFileDiffLineKind) -> Color {
        switch kind {
        case .context: return AppTheme.mutedText.opacity(0.55)
        case .added: return AppTheme.diffAdded.opacity(0.85)
        case .removed: return AppTheme.diffRemoved.opacity(0.85)
        }
    }

    private func lineTextColor(_ kind: FullFileDiffLineKind) -> Color {
        switch kind {
        case .context: return .primary.opacity(0.86)
        case .added: return .primary
        case .removed: return .primary.opacity(0.92)
        }
    }

    private func lineBackground(_ kind: FullFileDiffLineKind) -> Color {
        switch kind {
        case .context: return .clear
        case .added: return AppTheme.diffAdded.opacity(0.12)
        case .removed: return AppTheme.diffRemoved.opacity(0.12)
        }
    }
}

// MARK: - Inspector panel (true trailing column via `.inspector`)

/// Session-scoped Review workbench for the trailing column.
/// Layout (Codex-like product chrome):
///   ┌ chrome ─────────────────────────────────────────┐
///   │  [full-file diff]              │ [file list]    │
///   └─────────────────────────────────────────────────┘
struct PiAgentRepoReviewPanel: View {
    @Bindable var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var fileFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            Divider().opacity(0.55)
            if viewModel.piAgentSessionStore.selectedSession == nil {
                AppEmptyState(
                    languageStore.t("review.noSession"),
                    systemImage: "tray",
                    description: languageStore.t("review.noSessionBody"),
                    layout: .fill
                )
            } else {
                HSplitView {
                    previewColumn
                        .frame(minWidth: 300)
                        .layoutPriority(1)
                    fileListColumn
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                }
            }
        }
        .background(AppTheme.windowBackground)
        .onAppear {
            viewModel.prepareRepoChangesForSelectedPiAgentSession(force: true)
        }
        .onChange(of: viewModel.piAgentSessionStore.selectedSession?.id) { _, _ in
            viewModel.prepareRepoChangesForSelectedPiAgentSession(force: true)
        }
    }

    // MARK: Chrome

    private var chromeBar: some View {
        HStack(spacing: 10) {
            // Active tab chip (room for future inspector tabs).
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                Text(languageStore.t("review.title"))
                    .font(AppTheme.Font.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.contentSubtleFill.opacity(0.9))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(AppTheme.hairlineStroke.opacity(0.6), lineWidth: 1)
                    )
            )

            if let snapshot = viewModel.githubRepositoryChanges {
                branchChip(snapshot)
                if additionHint > 0 || deletionHint > 0 {
                    HStack(spacing: 6) {
                        if additionHint > 0 {
                            Text("+\(additionHint)")
                                .foregroundStyle(AppTheme.diffAdded)
                        }
                        if deletionHint > 0 {
                            Text("-\(deletionHint)")
                                .foregroundStyle(AppTheme.diffRemoved)
                        }
                    }
                    .font(AppTheme.Font.caption2.weight(.semibold).monospacedDigit())
                }
            }

            Spacer(minLength: 8)

            if viewModel.githubIsLoadingRepositoryChanges {
                AppSpinner().controlSize(.mini)
            }

            chromeIconButton(
                systemName: "arrow.clockwise",
                help: languageStore.t("common.refresh"),
                disabled: viewModel.githubIsLoadingRepositoryChanges
            ) {
                viewModel.prepareRepoChangesForSelectedPiAgentSession(force: true)
            }

            chromeIconButton(
                systemName: "sidebar.trailing",
                help: languageStore.t("review.collapse")
            ) {
                viewModel.collapseTrailingInspector()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func branchChip(_ snapshot: RepositoryChangesSnapshot) -> some View {
        HStack(spacing: 5) {
            Image("branch")
                .font(.system(size: 10, weight: .semibold))
            Text(snapshot.branchName)
                .lineLimit(1)
            if let upstream = snapshot.upstreamBranch, !upstream.isEmpty {
                Text("→")
                    .foregroundStyle(AppTheme.mutedText)
                Text(upstream)
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .font(AppTheme.Font.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .strokeBorder(AppTheme.hairlineStroke.opacity(0.55), lineWidth: 1)
        )
    }

    private func chromeIconButton(
        systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? AppTheme.mutedText.opacity(0.45) : .primary)
        .disabled(disabled)
        .help(help)
    }

    private var additionHint: Int {
        guard let text = viewModel.githubSelectedDiffText else { return 0 }
        return text.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
    }

    private var deletionHint: Int {
        guard let text = viewModel.githubSelectedDiffText else { return 0 }
        return text.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
    }

    // MARK: File list

    private var fileListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.mutedText)
                TextField(languageStore.t("review.filterFiles"), text: $fileFilter)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Font.caption)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.contentSubtleFill.opacity(0.55))
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Group {
                if viewModel.githubIsLoadingRepositoryChanges && viewModel.githubRepositoryChanges == nil {
                    loadingBlock(languageStore.t("review.loading"))
                } else if let error = viewModel.githubLastError, viewModel.githubRepositoryChanges == nil {
                    Text(error)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let snapshot = viewModel.githubRepositoryChanges {
                    if snapshot.totalChangeCount == 0 {
                        Text(languageStore.t("review.clean"))
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                fileGroup(
                                    languageStore.t("review.section.conflicted", snapshot.conflicted.count),
                                    snapshot.conflicted,
                                    .conflicted
                                )
                                fileGroup(
                                    languageStore.t("review.section.staged", snapshot.staged.count),
                                    snapshot.staged,
                                    .staged
                                )
                                fileGroup(
                                    languageStore.t("review.section.unstaged", snapshot.unstaged.count),
                                    snapshot.unstaged,
                                    .unstaged
                                )
                                fileGroup(
                                    languageStore.t("review.section.untracked", snapshot.untracked.count),
                                    snapshot.untracked,
                                    .untracked
                                )
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                        }
                    }
                } else {
                    loadingBlock(languageStore.t("review.loading"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Button(languageStore.t("review.stageAll")) { viewModel.stageAllChanges() }
                    .disabled(!(viewModel.githubRepositoryChanges?.canStageAll ?? false))
                Button(languageStore.t("review.unstageAll")) { viewModel.unstageAllChanges() }
                    .disabled(!(viewModel.githubRepositoryChanges?.canUnstageAll ?? false))
                Spacer(minLength: 0)
            }
            .font(AppTheme.Font.caption2.weight(.medium))
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AppTheme.contentSubtleFill.opacity(0.18))
    }

    @ViewBuilder
    private func fileGroup(_ title: String, _ changes: [RepositoryFileChange], _ kind: GitDiffKind) -> some View {
        let filtered = filterChanges(changes)
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)

                ForEach(filtered) { change in
                    fileRow(change, kind: kind)
                }
            }
        }
    }

    private func fileRow(_ change: RepositoryFileChange, kind: GitDiffKind) -> some View {
        let selected = viewModel.githubSelectedDiffFilePath == change.path
        let name = (change.path as NSString).lastPathComponent
        let folder = (change.path as NSString).deletingLastPathComponent
        return Button {
            viewModel.loadDiff(for: change.path, kind: kind)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(dotColor(kind))
                    .frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(AppTheme.Font.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !folder.isEmpty && folder != "." {
                        Text(folder)
                            .font(AppTheme.Font.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                Text(change.statusSummary.trimmingCharacters(in: .whitespaces))
                    .font(AppTheme.Font.code.weight(.semibold))
                    .foregroundStyle(dotColor(kind).opacity(0.9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AppTheme.brandAccent.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if kind != .staged {
                Button(languageStore.t("review.stage")) { viewModel.stage(change.path) }
            }
            if kind == .staged {
                Button(languageStore.t("review.unstage")) { viewModel.unstage(change.path) }
            }
            Divider()
            openEditorControl(for: change.path)
            Button(languageStore.t("review.revealFinder")) {
                viewModel.revealRepositoryFileInFinder(change.path)
            }
        }
        .help(change.path)
    }

    private func filterChanges(_ changes: [RepositoryFileChange]) -> [RepositoryFileChange] {
        let q = fileFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return changes }
        return changes.filter { $0.path.lowercased().contains(q) }
    }

    private func dotColor(_ kind: GitDiffKind) -> Color {
        switch kind {
        case .conflicted: return .orange
        case .staged: return AppTheme.diffAdded
        case .unstaged: return AppTheme.brandAccent
        case .untracked: return AppTheme.mutedText
        }
    }

    private func loadingBlock(_ text: String) -> some View {
        HStack(spacing: 8) {
            AppSpinner().controlSize(.small)
            Text(text)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortKindLabel(_ kind: GitDiffKind) -> String {
        switch kind {
        case .staged: return languageStore.t("review.kind.staged")
        case .unstaged: return languageStore.t("review.kind.unstaged")
        case .untracked: return languageStore.t("review.kind.untracked")
        case .conflicted: return languageStore.t("review.kind.conflicted")
        }
    }

    /// Shows **VS Code** (or preferred editor) as the label — never the long
    /// “在编辑器中打开” string that truncates to “在编…”.
    @ViewBuilder
    private func openEditorControl(for path: String) -> some View {
        let editors = ExternalCodeEditor.installed()
        let preferred = ExternalCodeEditor.preferred()
        let preferredID = preferred?.bundleIdentifier
        let title = preferred?.name ?? "VS Code"

        HStack(spacing: 2) {
            Button(title) {
                if let preferred {
                    viewModel.openRepositoryFile(path, withEditorBundleID: preferred.bundleIdentifier)
                } else if let first = editors.first {
                    viewModel.openRepositoryFile(path, withEditorBundleID: first.bundleIdentifier)
                } else if let url = viewModel.absoluteURLForRepositoryRelativePath(path) {
                    NSWorkspace.shared.open(url)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .help(languageStore.t("review.openIn", title))

            Menu {
                ForEach(editors) { editor in
                    Button {
                        viewModel.openRepositoryFile(path, withEditorBundleID: editor.bundleIdentifier)
                    } label: {
                        if editor.bundleIdentifier == preferredID {
                            Label(editor.name, systemImage: "checkmark")
                        } else {
                            Text(editor.name)
                        }
                    }
                }
                if !editors.isEmpty { Divider() }
                Button(languageStore.t("review.openSystemDefault")) {
                    if let url = viewModel.absoluteURLForRepositoryRelativePath(path) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(languageStore.t("review.chooseEditor"))
        }
        .fixedSize()
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = viewModel.githubSelectedDiffFilePath {
                filePathBar(path)
                Divider().opacity(0.45)
            }

            Group {
                if viewModel.githubSelectedDiffFilePath == nil {
                    AppEmptyState(
                        languageStore.t("review.selectFile"),
                        systemImage: "doc.text.magnifyingglass",
                        description: languageStore.t("review.selectFileBody"),
                        layout: .fill
                    )
                } else if let text = viewModel.githubSelectedDiffText {
                    // Edge-to-edge code surface (no nested card padding).
                    FullFileDiffView(diffText: text)
                        .clipShape(Rectangle())
                } else if let error = viewModel.githubLastError {
                    Text(error)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    loadingBlock(languageStore.t("activity.preparingDiff"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filePathBar(_ path: String) -> some View {
        let fileName = (path as NSString).lastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.mutedText)

            Text(fileName)
                .font(AppTheme.Font.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(path)

            if let kind = viewModel.githubSelectedDiffKind {
                Text(shortKindLabel(kind))
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.contentSubtleFill.opacity(0.75))
                    )
                    .fixedSize()
            }

            Spacer(minLength: 8)

            // Actions stay on one line — never wrap or truncate mid-label.
            HStack(spacing: 10) {
                if viewModel.githubSelectedDiffKind != .staged {
                    Button(languageStore.t("review.stage")) { viewModel.stage(path) }
                }
                if viewModel.githubSelectedDiffKind == .staged {
                    Button(languageStore.t("review.unstage")) { viewModel.unstage(path) }
                }
                openEditorControl(for: path)
                Button(languageStore.t("review.revealFinder")) {
                    viewModel.revealRepositoryFileInFinder(path)
                }
            }
            .font(AppTheme.Font.caption2.weight(.medium))
            .buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
