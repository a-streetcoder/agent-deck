import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// One selectable row in the composer's `/`-command / `@`-file autocomplete.
struct ComposerSuggestionItem: Identifiable, Equatable {
    enum Kind: Equatable { case command, skill, file }

    let id: String
    let kind: Kind
    let title: String
    /// Text that replaces the active composer token when this item is accepted.
    let insertion: String
    let isDirectory: Bool

    /// Builds the ordered, flat item list. Slash (`commands` + `skills`) and file
    /// triggers are mutually exclusive, so at most one group is ever non-empty.
    static func build(commands: [String], skills: [String], files: [PiAgentFileSuggestion]) -> [ComposerSuggestionItem] {
        if !files.isEmpty {
            return files.prefix(10).map { file in
                ComposerSuggestionItem(
                    id: "file:\(file.id)",
                    kind: .file,
                    title: file.relativePath,
                    insertion: "@\(file.relativePath)",
                    isDirectory: file.isDirectory
                )
            }
        }
        var items: [ComposerSuggestionItem] = []
        items += commands.map { command in
            ComposerSuggestionItem(id: "command:\(command)", kind: .command, title: command, insertion: command, isDirectory: false)
        }
        items += skills.map { skill in
            ComposerSuggestionItem(
                id: "skill:\(skill)",
                kind: .skill,
                title: skill.replacingOccurrences(of: "/skill:", with: ""),
                insertion: skill,
                isDirectory: false
            )
        }
        return items
    }
}

/// Bridges keyboard events from the composer's `NSTextView` to the suggestion
/// panel. The text view stays first responder; these closures move the
/// highlight, accept it, or dismiss the panel.
struct ComposerSuggestionKeyBridge {
    var isActive: Bool = false
    var onMove: (Int) -> Void = { _ in }
    var onAccept: () -> Bool = { false }
    var onDismiss: () -> Void = {}
}

nonisolated struct PiAgentFileSuggestion: Identifiable, Hashable {
    private static let maxScanResults = 40

    let id: String
    let relativePath: String
    let isDirectory: Bool

    static func scan(rootPath: String, query: String) -> [PiAgentFileSuggestion] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".swiftpm", ".venv"]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [PiAgentFileSuggestion] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            guard query.isEmpty || relative.lowercased().contains(query) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            results.append(.init(id: url.path, relativePath: relative, isDirectory: values?.isDirectory == true))
            if results.count >= maxScanResults { break }
        }
        return results
    }
}

/// Inline command-palette dropdown rendered as a sibling directly above the
/// composer — no popover, no arrow, no
/// overlay positioning. One flat scroll with a fixed, deterministic height.
struct PiAgentCommandSuggestions: View {
    let items: [ComposerSuggestionItem]
    let selectedIndex: Int
    /// Bumped only by keyboard navigation and typing — never by hover — so the
    /// highlight is scrolled into view only on keyboard interaction.
    let scrollTick: Int
    let onSelect: (ComposerSuggestionItem) -> Void
    let onHover: (Int) -> Void

    private let rowHeight: CGFloat = 32
    private let headerHeight: CGFloat = 24
    private let maxListHeight: CGFloat = 256

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].kind != item.kind {
                            sectionHeader(for: item.kind)
                        }
                        row(item, index: index)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: listHeight)
            .onChange(of: scrollTick) { _, _ in
                guard items.indices.contains(selectedIndex) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    // No anchor: scroll the minimum amount to reveal the row.
                    // Already-visible rows don't move, so the list doesn't slide
                    // under the pointer on every keypress.
                    proxy.scrollTo(items[selectedIndex].id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clip row backgrounds to the panel's rounded shape so the highlight
        // doesn't bleed past the corners.
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
        // Untinted native glass to match the toolbar popovers (Session resources,
        // etc.). The brand-tinted appGlassPanel read as a saturated blue slab here.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.contentStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    /// Deterministic height — fixed row + header sizes, capped. No measurement,
    /// no nested scrolls, so the content can never clip.
    private var listHeight: CGFloat {
        var sectionCount = 0
        for (index, item) in items.enumerated() where index == 0 || items[index - 1].kind != item.kind {
            sectionCount += 1
        }
        let content = CGFloat(items.count) * rowHeight + CGFloat(sectionCount) * headerHeight + 8
        return min(content, maxListHeight)
    }

    private func sectionHeader(for kind: ComposerSuggestionItem.Kind) -> some View {
        HStack(spacing: 4) {
            Image(systemName: sectionIcon(kind))
                .font(AppTheme.Font.caption2.weight(.semibold))
            Text(sectionTitle(kind))
                .font(AppTheme.Font.caption2.weight(.semibold))
            // File scans are capped at 10 results — surface the cap on the same
            // row so the user knows to keep typing to narrow things down.
            if kind == .file && items.count >= 10 {
                Spacer(minLength: 8)
                Text("showing top 10 — keep typing to refine")
                    .font(AppTheme.Font.caption2.italic())
            }
        }
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .leading)
    }

    private func row(_ item: ComposerSuggestionItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 16)
                Text(item.title)
                    .font(AppTheme.Font.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.brandAccent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { onHover(index) }
        }
    }

    private func icon(for item: ComposerSuggestionItem) -> String {
        switch item.kind {
        case .command: return "terminal"
        case .skill: return "sparkles"
        case .file: return item.isDirectory ? "folder" : "doc.text"
        }
    }

    private func sectionTitle(_ kind: ComposerSuggestionItem.Kind) -> String {
        switch kind {
        case .command: return "Commands"
        case .skill: return "Skills"
        case .file: return "Files"
        }
    }

    private func sectionIcon(_ kind: ComposerSuggestionItem.Kind) -> String {
        switch kind {
        case .command: return "terminal"
        case .skill: return "sparkles"
        case .file: return "paperclip"
        }
    }
}

/// Two-screen `/` browser. Screen 1 is a category picker (Commands / Prompts /
/// Skills); typing on screen 1 flips to global search across all three.
/// Screen 2 drills into a single category with active-first / available-below
/// grouping. The view is presentational — all row computation and state lives
/// in the parent (see `SlashSuggestionRowBuilder`).
struct PiAgentSlashSuggestions: View {
    let rows: [SlashSuggestionRow]
    let highlightedSelectableIndex: Int
    let scrollTick: Int
    let title: String?
    let onSelect: (SlashSuggestionRow) -> Void
    let onHoverSelectable: (Int) -> Void
    let onBack: (() -> Void)?

    private let rowHeight: CGFloat = 32
    private let headerHeight: CGFloat = 24
    private let titleBarHeight: CGFloat = 28
    private let maxListHeight: CGFloat = 280
    private let listOuterVerticalPadding: CGFloat = 0

    var body: some View {
        // Compute once per render. Both row highlight and hover handlers need
        // this; computing it per-row would be O(N²) on every redraw.
        let selectableIndices = rows.enumerated().compactMap { $0.element.isSelectable ? $0.offset : nil }
        let highlightedAbsoluteIndex: Int? = selectableIndices.indices.contains(highlightedSelectableIndex)
            ? selectableIndices[highlightedSelectableIndex]
            : nil

        return VStack(spacing: 0) {
            if let title { titleBar(title: title) }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { absoluteIndex, row in
                            renderRow(
                                row,
                                absoluteIndex: absoluteIndex,
                                highlightedAbsoluteIndex: highlightedAbsoluteIndex,
                                selectableIndices: selectableIndices
                            )
                            .id(row.id)
                        }
                    }
                    .padding(.vertical, listOuterVerticalPadding)
                }
                .contentMargins(.vertical, 0, for: .scrollContent)
                .frame(height: listHeight)
                .onChange(of: scrollTick) { _, _ in
                    guard let absolute = highlightedAbsoluteIndex else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(rows[absolute].id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clip row backgrounds to the panel's rounded shape so the highlight
        // doesn't bleed past the corners.
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
        // Untinted native glass to match the toolbar popovers (Session resources,
        // etc.). The brand-tinted appGlassPanel read as a saturated blue slab here.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.contentStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private var listHeight: CGFloat {
        var content: CGFloat = listOuterVerticalPadding * 2
        for row in rows {
            content += row.isSelectable ? rowHeight : headerHeight
        }
        return min(content, maxListHeight)
    }

    @ViewBuilder
    private func titleBar(title: String) -> some View {
        HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            Text(title)
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: titleBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.5))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func renderRow(
        _ row: SlashSuggestionRow,
        absoluteIndex: Int,
        highlightedAbsoluteIndex: Int?,
        selectableIndices: [Int]
    ) -> some View {
        switch row.kind {
        case .header(let label):
            Text(label)
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .leading)
        case .category(let kind):
            categoryRow(
                kind: kind,
                row: row,
                highlighted: highlightedAbsoluteIndex == absoluteIndex,
                selectableIndex: selectableIndices.firstIndex(of: absoluteIndex)
            )
        case .item(let item):
            itemRow(
                item: item,
                row: row,
                highlighted: highlightedAbsoluteIndex == absoluteIndex,
                selectableIndex: selectableIndices.firstIndex(of: absoluteIndex)
            )
        }
    }

    private func categoryRow(kind: SlashItemKind, row: SlashSuggestionRow, highlighted: Bool, selectableIndex: Int?) -> some View {
        Button { onSelect(row) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: kind))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(highlighted ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 16)
                Text(label(for: kind))
                    .font(AppTheme.Font.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? AppTheme.brandAccent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering, let index = selectableIndex else { return }
            onHoverSelectable(index)
        }
    }

    private func itemRow(item: SlashItem, row: SlashSuggestionRow, highlighted: Bool, selectableIndex: Int?) -> some View {
        Button { onSelect(row) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item.kind))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(highlighted ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 16)
                Text(item.displayName)
                    .font(AppTheme.Font.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let description = item.description {
                    Text(description)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let scope = item.scopeLabel {
                    Text(scope)
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.contentSubtleFill))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? AppTheme.brandAccent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .opacity(item.isActive ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering, let index = selectableIndex else { return }
            onHoverSelectable(index)
        }
    }

    private func icon(for kind: SlashItemKind) -> String {
        switch kind {
        case .command: return "terminal"
        case .prompt: return AppSymbols.promptTemplate
        case .skill: return "sparkles"
        }
    }

    private func label(for kind: SlashItemKind) -> String {
        switch kind {
        case .command: return "Commands"
        case .prompt: return "Prompts"
        case .skill: return "Skills"
        }
    }
}

/// Glass-capsule pill rendered above the composer once the user has accepted a
/// `/`-suggestion. Mirrors the file-attachment chip style so the composer reads
/// as "this is a structured invocation" rather than free text.
struct PiAgentSlashSelectionChip: View {
    let item: SlashItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.brandAccent)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .font(AppTheme.Font.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .appGlassCapsule()
        .help(item.description ?? item.displayName)
    }

    private var icon: String {
        switch item.kind {
        case .command: return "terminal"
        case .prompt: return AppSymbols.promptTemplate
        case .skill: return "sparkles"
        }
    }

    private var label: String {
        switch item.payload {
        case .command(let slashName, _):
            return slashName.hasPrefix("/") ? String(slashName.dropFirst()) : slashName
        case .prompt(let name, _):
            return name
        case .skill(let name, _):
            return name
        }
    }
}

struct ShortcutComboHint: View {
    let symbols: [String]
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(symbols.indices, id: \.self) { index in
                if index > 0 {
                    Image(systemName: "plus")
                        .font(AppTheme.Font.smallLabel)
                }
                Image(systemName: symbols[index])
                    .font(AppTheme.Font.caption2.weight(.semibold))
            }
            Text(text)
                .font(AppTheme.Font.caption.weight(.medium))
                .fontWidth(.condensed)
        }
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .appGlassCapsule()
    }
}

struct PiAgentUIRequestInlineNotice: View {
    let request: PiAgentUIRequest
    let onRespond: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(AppTheme.brandAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pi is waiting for your response")
                    .font(AppTheme.Font.callout.weight(.semibold))
                Text(request.title)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
            Button("Respond…", action: onRespond)
                .appPrimaryButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

struct PiAgentUIRequestSheet: View {
    let request: PiAgentUIRequest
    let onSubmitValue: (String) -> Void
    let onSubmitFreeform: (String, String) -> Void
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        PiAgentUIRequestCard(
            request: request,
            onSubmitValue: onSubmitValue,
            onSubmitFreeform: onSubmitFreeform,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        .padding(22)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 760, alignment: .topLeading)
        .appGlassPanel(cornerRadius: AppTheme.Chat.glassPanelCornerRadius)
        .presentationSizing(.fitted)
        .presentationBackground(.clear)
    }
}

struct PiAgentUIRequestCard: View {
    private let freeformSentinel = "✏️ Type custom response..."

    let request: PiAgentUIRequest
    let onSubmitValue: (String) -> Void
    let onSubmitFreeform: (String, String) -> Void
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var isComposingFreeform = false
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch request.method {
            case .select:
                selectOptions
            case .multiSelect:
                multiSelectOptions
            case .confirm:
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button("No") { onConfirm(false) }
                    Button("Yes") { onConfirm(true) }
                        .appPrimaryButton()
                }
            case .input, .editor:
                textInput(submitTitle: "Submit", cancelTitle: "Cancel", cancelAction: onCancel) { submitTextInput() }
            }
        }
        .onAppear {
            if draft.isEmpty, let prefill = request.prefill {
                draft = prefill
            }
        }
        .onChange(of: request.id) { _, _ in
            draft = request.prefill ?? ""
            isComposingFreeform = false
            selectedOptions = []
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(AppTheme.brandAccent)
                .font(AppTheme.Font.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(AppTheme.Font.headline)
                    .fontWidth(.expanded)
                if let message = request.message, !message.isEmpty, message != request.title {
                    Text(message)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var selectOptions: some View {
        Group {
            if request.options.isEmpty {
                emptyOptions
            } else if request.responseFormat == .nativeAsk {
                nativeAskChoiceOptions(allowsMultiple: false)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.options, id: \.self) { option in
                        if option == freeformSentinel {
                            freeformPill(label: option)
                        } else {
                            Button {
                                onSubmitValue(option)
                            } label: {
                                HStack {
                                    Text(option)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(AppTheme.brandAccent)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 10) {
                        Spacer()
                        Button("Cancel", action: onCancel)
                        if isComposingFreeform {
                            Button("Submit") { onSubmitFreeform(freeformSentinel, draft) }
                                .appPrimaryButton()
                                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func freeformPill(label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isComposingFreeform.toggle()
                if !isComposingFreeform { draft = "" }
            } label: {
                HStack {
                    Text(label)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: isComposingFreeform ? "checkmark.circle.fill" : "square.and.pencil")
                        .foregroundStyle(AppTheme.brandAccent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isComposingFreeform {
                Divider()
                    .padding(.horizontal, 12)
                TextField("Custom response", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .onSubmit {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onSubmitFreeform(freeformSentinel, draft)
                        }
                    }
            }
        }
        .background(
            isComposingFreeform ? AppTheme.brandAccent.opacity(0.12) : AppTheme.contentSubtleFill,
            in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
        )
    }

    private var multiSelectOptions: some View {
        Group {
            if request.responseFormat == .nativeAsk {
                nativeAskChoiceOptions(allowsMultiple: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.options, id: \.self) { option in
                        Button {
                            if selectedOptions.contains(option) {
                                selectedOptions.remove(option)
                            } else {
                                selectedOptions.insert(option)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedOptions.contains(option) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedOptions.contains(option) ? AppTheme.brandAccent : AppTheme.mutedText)
                                Text(option)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        Spacer()
                        Button("Cancel", action: onCancel)
                        Button("Submit") { onSubmitValue(request.options.filter { selectedOptions.contains($0) }.joined(separator: ", ")) }
                            .appPrimaryButton()
                            .disabled(selectedOptions.isEmpty)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func nativeAskChoiceOptions(allowsMultiple: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.options, id: \.self) { option in
                Button {
                    if allowsMultiple {
                        if selectedOptions.contains(option) {
                            selectedOptions.remove(option)
                        } else {
                            selectedOptions.insert(option)
                        }
                    } else {
                        selectedOptions = [option]
                    }
                    isComposingFreeform = false
                    draft = ""
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectionIcon(for: option, allowsMultiple: allowsMultiple))
                            .foregroundStyle(selectedOptions.contains(option) ? AppTheme.brandAccent : AppTheme.mutedText)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option)
                                .fontWeight(.semibold)
                            if let description = request.optionDescriptions[option], !description.isEmpty {
                                Text(description)
                                    .font(AppTheme.Font.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if request.allowsFreeform {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selectedOptions = []
                        isComposingFreeform.toggle()
                        if !isComposingFreeform { draft = "" }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isComposingFreeform ? "checkmark.circle.fill" : "square.and.pencil")
                                .foregroundStyle(isComposingFreeform ? AppTheme.brandAccent : AppTheme.mutedText)
                                .frame(width: 18)
                            Text("Type custom response")
                                .fontWeight(.semibold)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isComposingFreeform {
                        Divider()
                            .padding(.horizontal, 12)
                        TextField("Custom response", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .onSubmit {
                                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    onSubmitValue(request.nativeAskFreeformResponseValue(trimmed))
                                }
                            }
                    }
                }
                .background(
                    isComposingFreeform ? AppTheme.brandAccent.opacity(0.12) : AppTheme.contentSubtleFill,
                    in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                )
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Submit") {
                    if isComposingFreeform {
                        onSubmitValue(request.nativeAskFreeformResponseValue(draft))
                    } else {
                        submitNativeAskSelection()
                    }
                }
                .appPrimaryButton()
                .disabled(nativeAskSubmitDisabled)
            }
            .padding(.top, 4)
        }
    }

    private func textInput(submitTitle: String, cancelTitle: String, cancelAction: @escaping () -> Void, submitAction: @escaping () -> Void) -> some View {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSubmit = !trimmedDraft.isEmpty || request.allowsEmptyInputResponse

        return VStack(alignment: .leading, spacing: 8) {
            AppTextField(
                text: $draft,
                placeholder: request.placeholder ?? "Response",
                axis: request.method == .editor ? .vertical : .horizontal,
                onSubmit: { if canSubmit { submitAction() } }
            )
            .lineLimit(request.method == .editor ? 4...10 : 1...3)
            HStack(spacing: 10) {
                Spacer()
                Button(cancelTitle, action: cancelAction)
                Button(submitTitle, action: submitAction)
                    .appPrimaryButton()
                    .disabled(!canSubmit)
            }
            .padding(.top, 4)
        }
    }

    private var emptyOptions: some View {
        Text("Pi requested a selection, but no options were provided.")
            .foregroundStyle(AppTheme.mutedText)
    }

    private func selectionIcon(for option: String, allowsMultiple: Bool) -> String {
        if allowsMultiple {
            return selectedOptions.contains(option) ? "checkmark.square.fill" : "square"
        }
        return selectedOptions.contains(option) ? "largecircle.fill.circle" : "circle"
    }

    private var nativeAskSubmitDisabled: Bool {
        if isComposingFreeform {
            return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return selectedOptions.isEmpty
    }

    private func submitTextInput() {
        if request.responseFormat == .nativeAsk {
            onSubmitValue(request.nativeAskFreeformResponseValue(draft))
        } else {
            onSubmitValue(draft)
        }
    }

    private func submitNativeAskSelection() {
        let orderedSelections = request.options.filter { selectedOptions.contains($0) }
        onSubmitValue(request.nativeAskSelectionResponseValue(selections: orderedSelections, comment: ""))
    }
}

private extension PiAgentUIRequest {
    var allowsEmptyInputResponse: Bool {
        guard method == .input else { return false }
        let prompt = (placeholder ?? "").lowercased()
        return prompt.contains("press enter to skip") || prompt.contains("optional")
    }
}
