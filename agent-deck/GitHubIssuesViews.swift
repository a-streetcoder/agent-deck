import AppKit
import SwiftUI

/// Bordered "card" wrapper around `GitHubIssueRowContent`, used where an issue
/// row stands alone with its own selection chrome — currently the Pi composer's
/// attach-issue popover. The Issues screen itself renders the content inside an
/// `AppList` row, which supplies the selection chrome there.
struct GitHubIssueListRow: View {
    let item: GitHubWorkItem
    let isSelected: Bool
    let onSelect: () -> Void
    /// Issue-screen actions. Omitted when the row is reused as a plain picker
    /// (e.g. the Pi composer's attach-issue popover), which collapses the
    /// context menu to the always-safe Open in Browser / Copy entries.
    var onOpenInPi: (() -> Void)? = nil
    var onClose: ((GitHubIssueCloseReason) -> Void)? = nil
    var onReopen: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            GitHubIssueRowContent(
                item: item,
                onOpenInPi: onOpenInPi,
                onClose: onClose,
                onReopen: onReopen
            )
            .padding(14)
            // Make the entire padded card — gaps included — a single hit target.
            // Applied inside the button label so it defines the button's tap area.
            .background(surface)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
}

/// The inner content of an issue row — state dot, title, and meta line — plus
/// its context menu. Mirrors the Agents row shape (single-line title + one
/// secondary line) so every row is the same height. Carries no selection chrome,
/// padding, or background of its own, so it drops cleanly into either the
/// bordered card (`GitHubIssueListRow`, used by the attach-issue popover) or an
/// `AppList` row on the Issues screen.
struct GitHubIssueRowContent: View {
    let item: GitHubWorkItem
    var onOpenInPi: (() -> Void)? = nil
    var onClose: ((GitHubIssueCloseReason) -> Void)? = nil
    var onReopen: (() -> Void)? = nil

    // isOpen / closedReason come from the cached fields on GitHubWorkItem,
    // computed once at snapshot time.
    private var isOpen: Bool { item.isOpen }
    private var closedReason: GitHubIssueCloseReason? { item.closedReason }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stateIndicator
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                metaRow
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { contextMenu }
    }

    // MARK: - Pieces

    private var stateIndicator: some View {
        Image(systemName: stateIndicatorSymbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(stateIndicatorColor)
            // Nudge down so the dot lines up with the title's first line.
            .padding(.top, 1)
            .help(stateIndicatorTooltip)
    }

    private var stateIndicatorSymbol: String {
        if isOpen { return "smallcircle.filled.circle" }
        switch closedReason {
        case .notPlanned: return "slash.circle.fill"
        case .duplicate: return "doc.on.doc.fill"
        case .completed, nil: return "checkmark.circle.fill"
        }
    }

    private var stateIndicatorColor: Color {
        if isOpen { return .green }
        switch closedReason {
        case .notPlanned, .duplicate: return AppTheme.mutedText
        case .completed, nil: return AppTheme.assistantAccent
        }
    }

    private var stateIndicatorTooltip: String {
        if isOpen { return "Open" }
        switch closedReason {
        case .notPlanned: return "Closed · Not Planned"
        case .duplicate: return "Closed · Duplicate"
        case .completed, nil: return "Closed"
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Always reserve two lines so every row is the same height and the
            // meta line below always lands in the same place; titles longer than
            // two lines truncate with an ellipsis.
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 4)
            Text("#\(item.number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private static let relativeDateFormatter = RelativeDateTimeFormatter()

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let author = item.author {
                GitHubAvatarView(url: GitHubAvatarResolver.url(login: author, host: item.url.host()), size: 16)
                Text(author)
                separator
            }
            Text(Self.relativeDateFormatter.localizedString(for: item.updatedAt, relativeTo: Date()))
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
        if isOpen, let onClose {
            Divider()
            Menu {
                ForEach(GitHubIssueCloseReason.allCases) { reason in
                    Button {
                        onClose(reason)
                    } label: {
                        Label(reason.title, systemImage: reason.systemImage)
                    }
                }
            } label: {
                Label("Close Issue", systemImage: "checkmark.circle")
            }
        } else if !isOpen, let onReopen {
            Divider()
            Button(action: onReopen) {
                Label("Reopen Issue", systemImage: "arrow.counterclockwise.circle")
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

struct GitHubIssueDetailView: View {
    @Bindable var viewModel: AppViewModel

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
                    AppSpinner()
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
            // Smaller top inset so the first row lines up with the list pane.
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.bottom, AppTheme.pagePadding)
            .padding(.top, AppTheme.Split.contentTopInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private func titleRow(_ detail: GitHubIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.item.title)
                .font(.title2.weight(.bold))
                .fontWidth(.expanded)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    titleMetadata(detail)
                    Spacer(minLength: 12)
                    actionButtons(detail)
                }
                VStack(alignment: .leading, spacing: 10) {
                    titleMetadata(detail)
                    actionButtons(detail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func titleMetadata(_ detail: GitHubIssueDetail) -> some View {
        HStack(spacing: 8) {
            AppLabelTag(text: detail.state.capitalized, color: detail.state.lowercased() == "open" ? .green : .secondary)
            if detail.state.lowercased() != "open",
               let raw = detail.stateReason,
               let reason = GitHubIssueCloseReason(rawValue: raw),
               reason != .completed {
                AppLabelTag(text: reason.title, color: .secondary)
            }
            if let issueType = detail.type, !issueType.isEmpty {
                AppLabelTag(text: issueType, color: issueTypeColor(issueType))
            }
            Text("\(detail.item.repository) #\(detail.item.number)")
                .font(.footnote.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func actionButtons(_ detail: GitHubIssueDetail) -> some View {
        AppControlGroup(spacing: 8) {
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
                closeSplitButton
            }
        }
    }

    /// Close + reason-picker rendered as a single glass capsule (split button).
    /// SwiftUI's `Menu` does not pick up `.buttonStyle(.glass)` outside a
    /// toolbar, so the glass surface is applied to the HStack and the two tap
    /// zones (primary close, dropdown) live inside it with a thin divider.
    private var closeSplitButton: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.closeSelectedIssue(reason: .completed)
            } label: {
                Text(viewModel.githubIsClosingIssue ? "Closing…" : "Close")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close this issue as completed.")

            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 18)

            Menu {
                ForEach(GitHubIssueCloseReason.allCases.filter { $0 != .completed }) { reason in
                    Button(reason.title) {
                        viewModel.closeSelectedIssue(reason: reason)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("Close with a different reason (Not Planned, Duplicate).")
        }
        .fixedSize()
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .disabled(viewModel.githubIsClosingIssue)
        .opacity(viewModel.githubIsClosingIssue ? 0.6 : 1)
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
                                .appBrandTint()
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
                            AppSpinner()
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

    private static let relativeDateFormatter = RelativeDateTimeFormatter()

    private func relativeDate(_ date: Date) -> String {
        Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
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
                                    .lineLimit(1)
                                    .truncationMode(.middle)
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
                                .appBrandTint()
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
