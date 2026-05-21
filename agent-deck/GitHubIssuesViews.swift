import AppKit
import SwiftUI

struct GitHubIssueListRow: View {
    let item: GitHubWorkItem
    let isSelected: Bool
    let onSelect: () -> Void
    /// Issue-screen actions. Omitted when the row is reused as a plain picker
    /// (e.g. the Pi composer's attach-issue popover), which collapses the
    /// context menu to the always-safe Open in Browser / Copy entries.
    var onOpenInPi: (() -> Void)? = nil
    var onToggleState: (() -> Void)? = nil

    @State private var isHovering = false

    private var isOpen: Bool { item.state.lowercased() == "open" }

    /// The issue's native type (if any) followed by its labels, rendered as one
    /// wrapping tag strip so the type reads as the leading, color-coded chip.
    private var tags: [IssueTag] {
        var result: [IssueTag] = []
        if let type = item.type, !type.isEmpty {
            result.append(.type(type))
        }
        result += item.labels.map(IssueTag.label)
        return result
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 11) {
                stateIndicator
                VStack(alignment: .leading, spacing: 8) {
                    titleRow
                    if !tags.isEmpty { tagRow }
                    metaRow
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            // Make the entire padded card — gaps included — a single hit target.
            // Applied inside the button label so it defines the button's tap area.
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
    }

    // MARK: - Pieces

    private var stateIndicator: some View {
        Image(systemName: isOpen ? "smallcircle.filled.circle" : "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isOpen ? Color.green : AppTheme.assistantAccent)
            .padding(.top, 1)
            .help(isOpen ? "Open" : "Closed")
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text("#\(item.number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private var tagRow: some View {
        IssueTagFlowLayout(spacing: 6) {
            ForEach(tags) { tag in
                switch tag {
                case let .type(value):
                    GitHubGlassChip(text: value, palette: GitHubChipPalette(accent: issueTypeColor(value)))
                case let .label(label):
                    GitHubLabelTag(label: label)
                }
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let author = item.author {
                GitHubAvatarView(url: GitHubAvatarResolver.url(login: author, host: item.url.host()), size: 16)
                Text(author)
                separator
            }
            Text(RelativeDateTimeFormatter().localizedString(for: item.updatedAt, relativeTo: Date()))
            if item.commentCount > 0 {
                separator
                Image(systemName: "bubble.left")
                Text("\(item.commentCount)")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(AppTheme.mutedText)
    }

    private var separator: some View {
        Text("·")
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let fill: Color = isSelected
            ? AppTheme.selectionFill
            : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        return shape
            .fill(fill)
            .overlay(shape.stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let onOpenInPi {
            Button(action: onOpenInPi) {
                Label("Open in Pi Session", image: "pi")
            }
        }
        Link(destination: item.url) {
            Label("Open in Browser", systemImage: "safari")
        }
        if let onToggleState {
            Divider()
            Button(action: onToggleState) {
                Label(
                    isOpen ? "Close Issue" : "Reopen Issue",
                    systemImage: isOpen ? "checkmark.circle" : "arrow.counterclockwise.circle"
                )
            }
        }
        Divider()
        Button {
            copyToPasteboard(item.url.absoluteString)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        Button {
            copyToPasteboard("#\(item.number)")
        } label: {
            Label("Copy Issue Number", systemImage: "number")
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// One chip in an issue card's tag strip — either the issue's native type
/// (rendered as a stroked accent chip) or a GitHub label (glass-tinted with
/// the label's own color).
private enum IssueTag: Identifiable {
    case type(String)
    case label(GitHubLabel)

    var id: String {
        switch self {
        case let .type(value): return "type:\(value)"
        case let .label(label): return "label:\(label.name)"
        }
    }
}

/// Wrapping flow layout for the issue-card tag strip — lays chips left to right
/// and wraps to a new line when a row runs out of width. Replaces a fixed
/// single-line `HStack` + `.clipped()`, which sheared the chip stroke borders.
private struct IssueTagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projectedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && projectedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            if !current.indices.isEmpty { current.width += spacing }
            current.indices.append(index)
            current.width += size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct GitHubIssueDetailView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if viewModel.githubIsLoadingIssueDetail && viewModel.githubIssueDetail == nil {
            loadingState
        } else if let detail = viewModel.githubIssueDetail {
            detailContent(detail)
        } else {
            ContentUnavailableView(
                "Issue Details Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Could not load this issue. Try refreshing.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingState: some View {
        VStack {
            AppRowCard {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading issue")
                            .font(.headline)
                        Text("Fetching the description and comments.")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: 460)
            Spacer()
        }
        .padding(AppTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func detailContent(_ detail: GitHubIssueDetail) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                titleRow(detail)
                metadataRow(detail)

                if !detail.labels.isEmpty {
                    labelsRow(detail.labels)
                }

                if detail.parent != nil || !detail.subIssues.isEmpty || !detail.blockedBy.isEmpty || !detail.blocking.isEmpty {
                    relationshipsSection(detail)
                }

                descriptionSection(detail)
                commentsSection(detail)
                addCommentSection(detail)
            }
            .padding(AppTheme.pagePadding)
        }
    }

    // MARK: - Sections

    private func titleRow(_ detail: GitHubIssueDetail) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.item.title)
                    .font(.title2.weight(.bold))
                    .fontWidth(.expanded)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    AppLabelTag(text: detail.state.capitalized, color: detail.state.lowercased() == "open" ? .green : .secondary)
                    if let issueType = detail.type, !issueType.isEmpty {
                        AppLabelTag(text: issueType, color: issueTypeColor(issueType))
                    }
                    Text("\(detail.item.repository) #\(detail.item.number)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            Spacer(minLength: 12)

            actionButtons(detail)
        }
    }

    private func actionButtons(_ detail: GitHubIssueDetail) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.startPiAgentForIssue(detail)
            } label: {
                HStack(spacing: 8) {
                    Image("pi")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text("Open")
                        .fontWeight(.semibold)
                }
            }
            .appPrimaryButton()
            .disabled(viewModel.selectedDiscoveredProject == nil)
            .opacity(viewModel.selectedDiscoveredProject == nil ? 0.45 : 1)
            .help(viewModel.selectedDiscoveredProject == nil ? "Select a project first." : "Open a Pi Agent session for this issue.")

            if detail.state.lowercased() == "open" {
                Button {
                    viewModel.closeSelectedIssue()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text(viewModel.githubIsClosingIssue ? "Closing…" : "Close")
                            .fontWeight(.semibold)
                    }
                }
                .appSecondaryButton()
                .disabled(viewModel.githubIsClosingIssue)
                .opacity(viewModel.githubIsClosingIssue ? 0.6 : 1)
                .help("Close this issue on GitHub.")
            }
        }
    }

    private func metadataRow(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let author = detail.author {
                    GitHubAvatarView(url: GitHubAvatarResolver.url(login: author, host: detail.item.url.host()), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author)
                            .fontWeight(.semibold)
                        Text("Author")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                } else {
                    Text("Author unavailable")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }

            AppKeyValueList(rows: [
                ("Type", detail.type ?? "—"),
                ("Assignees", detail.assignees.isEmpty ? "—" : detail.assignees.joined(separator: ", ")),
                ("Created", relativeDate(detail.createdAt)),
                ("Updated", relativeDate(detail.updatedAt)),
                ("Closed", detail.closedAt.map(relativeDate) ?? "—")
            ])
        }
    }

    private func labelsRow(_ labels: [GitHubLabel]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels) { label in
                    GitHubLabelTag(label: label)
                }
            }
        }
    }

    private func relationshipsSection(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Relationships")
                .font(.headline)
                .fontWidth(.expanded)

            if let parent = detail.parent {
                GitHubRelationshipGroup(title: "Parent", items: [parent], accent: AppTheme.assistantAccent) { reference in
                    viewModel.selectIssueReference(reference)
                }
            }
            if !detail.subIssues.isEmpty {
                GitHubRelationshipGroup(title: "Sub-issues", items: detail.subIssues, accent: AppTheme.assistantAccent) { reference in
                    viewModel.selectIssueReference(reference)
                }
            }
            if !detail.blockedBy.isEmpty {
                GitHubRelationshipGroup(title: "Blocked by", items: detail.blockedBy, accent: .orange) { reference in
                    viewModel.selectIssueReference(reference)
                }
            }
            if !detail.blocking.isEmpty {
                GitHubRelationshipGroup(title: "Blocking", items: detail.blocking, accent: .blue) { reference in
                    viewModel.selectIssueReference(reference)
                }
            }
        }
    }

    private func descriptionSection(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
                .fontWidth(.expanded)
            if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description provided.")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                MarkdownDocumentView(source: detail.body, minimumHeight: 80)
            }
        }
    }

    private func commentsSection(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments")
                .font(.headline)
                .fontWidth(.expanded)

            if detail.comments.isEmpty {
                Text("No comments yet.")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                ForEach(detail.comments) { comment in
                    AppRowCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 10) {
                                GitHubAvatarView(url: GitHubAvatarResolver.url(login: comment.author, host: detail.item.url.host()), size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(comment.author)
                                        .fontWeight(.semibold)
                                    Text(relativeDate(comment.updatedAt))
                                        .font(.footnote)
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                                Spacer()
                                Link(destination: comment.url) {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.plain)
                            }

                            MarkdownTextView(source: comment.cleanedBody)
                        }
                    }
                }
            }
        }
    }

    private func addCommentSection(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Comment")
                .font(.headline)
                .fontWidth(.expanded)
            TextEditor(text: $viewModel.githubCommentDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(8)
                .appContentSurface(cornerRadius: 10)

            HStack {
                Spacer()
                Button {
                    viewModel.submitComment()
                } label: {
                    if viewModel.githubIsSubmittingComment {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Posting…")
                        }
                    } else {
                        Text("Post Comment")
                    }
                }
                .appPrimaryButton()
                .disabled(viewModel.githubIsSubmittingComment || commentDraftIsEmpty)
            }
        }
    }

    private var commentDraftIsEmpty: Bool {
        viewModel.githubCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

private struct GitHubRelationshipGroup: View {
    let title: String
    let items: [GitHubIssueReference]
    let accent: Color
    let onSelect: (GitHubIssueReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)

            ForEach(items) { item in
                AppRowCard {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                AppLabelTag(
                                    text: item.state.capitalized,
                                    color: item.state.lowercased() == "open" ? .green : .secondary
                                )
                                if let type = item.type, !type.isEmpty {
                                    AppLabelTag(text: type, color: issueTypeColor(type))
                                }
                                Text("\(item.repository) #\(item.number)")
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            Button {
                                onSelect(item)
                            } label: {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 12) {
                                Button {
                                    onSelect(item)
                                } label: {
                                    Label("Open in App", systemImage: "sidebar.right")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain)

                                Link(destination: item.url) {
                                    Label("Open in GitHub", systemImage: "arrow.up.forward.square")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer()
                    }
                }
            }
        }
    }
}

private func issueTypeColor(_ issueType: String) -> Color {
    switch issueType.lowercased() {
    case "bug":
        return .red
    case "feature", "enhancement":
        return .blue
    case "task", "chore":
        return .purple
    case "epic", "initiative":
        return .orange
    default:
        return .secondary
    }
}

// MARK: - GitHub chips

/// A Liquid Glass capsule chip — the shared chrome for an issue's type chip and
/// its GitHub label chips. Keeping both chip kinds on the same material lets a
/// card's tag strip read as one family rather than mismatched styles.
struct GitHubGlassChip: View {
    let text: String
    let palette: GitHubChipPalette

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .lineLimit(1)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint(palette.tint), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(palette.stroke, lineWidth: 1)
            )
    }
}

/// A GitHub issue label rendered as a glass chip tinted with the label's own
/// color (as reported by the GitHub API). Mirrors how GitHub's web UI
/// color-codes labels, adapted to the app's dark glass chrome.
struct GitHubLabelTag: View {
    let label: GitHubLabel

    var body: some View {
        GitHubGlassChip(text: label.name, palette: GitHubChipPalette(labelHex: label.color))
    }
}

/// The three tones a glass chip needs — a translucent fill tint, a legible
/// foreground, and a hairline stroke — derived either from a fixed semantic
/// accent (issue type / state) or from a GitHub label's hex color.
struct GitHubChipPalette {
    let tint: Color
    let text: Color
    let stroke: Color

    /// Palette for a fixed semantic accent — issue type and state chips.
    init(accent color: Color) {
        self.tint = color.opacity(0.28)
        self.text = color
        self.stroke = color.opacity(0.5)
    }

    /// Palette derived from a GitHub label's hex color. Dark labels get their
    /// text lifted toward white so they stay readable on the app's dark
    /// surfaces; an absent or malformed color falls back to a neutral tint.
    init(labelHex hex: String?) {
        guard let rgb = GitHubChipPalette.rgb(from: hex) else {
            self.tint = Color.secondary.opacity(0.16)
            self.text = Color.secondary
            self.stroke = Color.secondary.opacity(0.4)
            return
        }

        let base = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        // Relative luminance (Rec. 709). Dark labels would render as unreadable
        // text on the dark chrome, so blend them toward white.
        let luminance = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
        if luminance < 0.5 {
            let lift = min(0.7, 0.62 - luminance)
            self.text = Color(
                red: rgb.r + (1 - rgb.r) * lift,
                green: rgb.g + (1 - rgb.g) * lift,
                blue: rgb.b + (1 - rgb.b) * lift
            )
        } else {
            self.text = base
        }
        self.tint = base.opacity(0.28)
        self.stroke = base.opacity(0.5)
    }

    /// Parses a GitHub label color (`"d73a4a"`, optionally `#`-prefixed) into
    /// normalized RGB components, or `nil` when absent or malformed.
    private static func rgb(from hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return (
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }
}

private extension GitHubIssueComment {
    var cleanedBody: String {
        var result = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trailingPatterns = [
            #"\n{2,}On .+ wrote:\n[\s\S]*$"#,
            #"\n{2,}> .*$"#,
            #"\n{2,}Reply to this email directly[\s\S]*$"#,
            #"\n{2,}You are receiving this because[\s\S]*$"#
        ]

        for pattern in trailingPatterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result = String(result[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result.isEmpty ? body : result
    }
}
