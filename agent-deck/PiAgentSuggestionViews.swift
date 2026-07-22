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
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
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
        .perfScene("pi-command-suggestions")
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
            guard hovering, !isSelected else { return }
            onHover(index)
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
        let selectableIndexByAbsoluteIndex = Dictionary(uniqueKeysWithValues: selectableIndices.enumerated().map { ($0.element, $0.offset) })
        let highlightedAbsoluteIndex: Int? = selectableIndices.indices.contains(highlightedSelectableIndex)
            ? selectableIndices[highlightedSelectableIndex]
            : nil

        return VStack(spacing: 0) {
            if let title { titleBar(title: title) }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.indices, id: \.self) { absoluteIndex in
                            let row = rows[absoluteIndex]
                            renderRow(
                                row,
                                absoluteIndex: absoluteIndex,
                                highlightedAbsoluteIndex: highlightedAbsoluteIndex,
                                selectableIndexByAbsoluteIndex: selectableIndexByAbsoluteIndex
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
        .perfScene("pi-slash-suggestions")
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
                        .appActionTarget()
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
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
        selectableIndexByAbsoluteIndex: [Int: Int]
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
                selectableIndex: selectableIndexByAbsoluteIndex[absoluteIndex]
            )
        case .item(let item):
            itemRow(
                item: item,
                row: row,
                highlighted: highlightedAbsoluteIndex == absoluteIndex,
                selectableIndex: selectableIndexByAbsoluteIndex[absoluteIndex]
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
            guard hovering, !highlighted, let index = selectableIndex else { return }
            onHoverSelectable(index)
        }
    }

    private func itemRow(item: SlashSuggestionItemRow, row: SlashSuggestionRow, highlighted: Bool, selectableIndex: Int?) -> some View {
        Button { onSelect(row) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item.kind))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(highlighted ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 16)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            guard hovering, !highlighted, let index = selectableIndex else { return }
            onHoverSelectable(index)
        }
    }

    private func icon(for kind: SlashItemKind) -> String {
        switch kind {
        case .command: return "terminal"
        case .prompt: return AppSymbols.promptTemplate
        case .skill: return "sparkles"
        case .loop: return "infinity"
        }
    }

    private func label(for kind: SlashItemKind) -> String {
        switch kind {
        case .command: return "Commands"
        case .prompt: return "Prompts"
        case .skill: return "Skills"
        case .loop: return "Loops"
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
        case .loop: return "infinity"
        }
    }

    private var label: String {
        switch item.payload {
        case .command(let slashName, _):
            return slashName.hasPrefix("/") ? String(slashName.dropFirst()) : slashName
        case .prompt(let name, _, _, _):
            return name
        case .skill(let name, _, _, _):
            return name
        case .skillCollection(_, let name, _):
            return name
        case .loopCreateNew:
            return "Create New Loop"
        case .loopDefinition(let definition):
            return definition.name
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
                .appSecondaryButton()
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
    private let freeformSentinel = "✏️ Type custom response..."
    private let sheetWidth: CGFloat = 820
    private let sheetHeight: CGFloat = 600

    let request: PiAgentUIRequest
    let onSubmitValue: (String) -> Void
    let onSubmitFreeform: (String, String) -> Void
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void
    var initiallyComposingFreeform = false

    @State private var draft = ""
    @State private var isComposingFreeform: Bool
    @State private var selectedOptions: Set<String> = []

    init(
        request: PiAgentUIRequest,
        onSubmitValue: @escaping (String) -> Void,
        onSubmitFreeform: @escaping (String, String) -> Void,
        onConfirm: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void,
        initiallyComposingFreeform: Bool = false
    ) {
        self.request = request
        self.onSubmitValue = onSubmitValue
        self.onSubmitFreeform = onSubmitFreeform
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.initiallyComposingFreeform = initiallyComposingFreeform
        _isComposingFreeform = State(initialValue: initiallyComposingFreeform)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: sheetWidth, height: sheetHeight, alignment: .topLeading)
        .presentationSizing(.fitted)
        .onAppear {
            if draft.isEmpty, let prefill = request.prefill {
                draft = prefill
            }
        }
        .onChange(of: request.id) { _, _ in
            draft = request.prefill ?? ""
            isComposingFreeform = initiallyComposingFreeform
            selectedOptions = []
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "questionmark.bubble.fill")
                .font(AppTheme.Font.headline)
                .foregroundStyle(AppTheme.brandAccent)
                .frame(width: 22, alignment: .center)

            Text("Ask User")
                .font(AppTheme.Font.headline)
                .fontWidth(.expanded)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if isComposingFreeform {
            VStack(alignment: .leading, spacing: 16) {
                promptBlock
                freeformEditor
                    .layoutPriority(1)
            }
            .padding(22)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    promptBlock
                    switch request.method {
                    case .select:
                        selectOptions
                    case .multiSelect:
                        multiSelectOptions
                    case .confirm:
                        confirmBody
                    case .input, .editor:
                        textInput
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(22)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var promptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title)
                .font(AppTheme.Font.title.weight(.semibold))
                .fontWidth(.expanded)
                .fixedSize(horizontal: false, vertical: true)
            if let message = request.message, !message.isEmpty, message != request.title {
                Text(message)
                    .font(AppTheme.Font.subheadline)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmBody: some View {
        Text("Choose whether Pi should continue with this request.")
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var selectOptions: some View {
        if request.options.isEmpty {
            emptyOptions
        } else {
            optionRows(allowsMultiple: false)
        }
    }

    @ViewBuilder
    private var multiSelectOptions: some View {
        if request.options.isEmpty {
            emptyOptions
        } else {
            optionRows(allowsMultiple: true)
        }
    }

    private func optionRows(allowsMultiple: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.options, id: \.self) { option in
                if option == freeformSentinel {
                    freeformOptionRow(label: option)
                } else {
                    optionRow(option, allowsMultiple: allowsMultiple)
                }
            }

            if request.responseFormat == .nativeAsk, request.allowsFreeform {
                freeformOptionRow(label: "Type custom response")
            }
        }
    }

    private func optionRow(_ option: String, allowsMultiple: Bool) -> some View {
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
            draft = ""
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectionIcon(for: option, allowsMultiple: allowsMultiple))
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(selectedOptions.contains(option) ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 18, height: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = request.optionDescriptions[option], !description.isEmpty {
                        Text(description)
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                    .strokeBorder(selectedOptions.contains(option) ? AppTheme.brandAccent.opacity(0.55) : AppTheme.contentStroke, lineWidth: selectedOptions.contains(option) ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func freeformOptionRow(label: String) -> some View {
        Button {
            selectedOptions = []
            isComposingFreeform = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.contentStroke, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var textInput: some View {
        AppTextField(
            text: $draft,
            placeholder: request.placeholder ?? "Response",
            axis: request.method == .editor ? .vertical : .horizontal,
            onSubmit: { if canSubmit { submitCurrent() } }
        )
        .lineLimit(request.method == .editor ? 4...10 : 1...3)
    }

    private var freeformEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never, axes: .vertical)
                .padding(14)
            if draft.isEmpty {
                Text("Type your custom response…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AppTheme.mutedText.opacity(0.6))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.contentStroke, lineWidth: 0.5)
        )
    }

    private var emptyOptions: some View {
        Text("Pi requested a selection, but no options were provided.")
            .foregroundStyle(AppTheme.mutedText)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isComposingFreeform {
                Button("Back") { isComposingFreeform = false }
                    .appSecondaryButton()
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .appSecondaryButton()
                Button("Submit") { submitFreeform() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmitFreeform)
            } else if request.method == .confirm {
                Spacer(minLength: 0)
                Button("No") { onConfirm(false) }
                    .appSecondaryButton()
                Button("Yes") { onConfirm(true) }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .appSecondaryButton()
            } else {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .appSecondaryButton()
                Button("Submit") { submitCurrent() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var canSubmit: Bool {
        switch request.method {
        case .select, .multiSelect:
            return !selectedOptions.isEmpty
        case .input, .editor:
            let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmedDraft.isEmpty || request.allowsEmptyInputResponse
        case .confirm:
            return true
        }
    }

    private var canSubmitFreeform: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectionIcon(for option: String, allowsMultiple: Bool) -> String {
        if allowsMultiple {
            return selectedOptions.contains(option) ? "checkmark.square.fill" : "square"
        }
        return selectedOptions.contains(option) ? "largecircle.fill.circle" : "circle"
    }

    private func submitCurrent() {
        switch request.method {
        case .select, .multiSelect:
            if request.responseFormat == .nativeAsk {
                submitNativeAskSelection()
            } else {
                let orderedSelections = request.options.filter { selectedOptions.contains($0) }
                onSubmitValue(orderedSelections.joined(separator: ", "))
            }
        case .input, .editor:
            submitTextInput()
        case .confirm:
            break
        }
    }

    private func submitFreeform() {
        guard canSubmitFreeform else { return }
        if request.responseFormat == .nativeAsk {
            onSubmitValue(request.nativeAskFreeformResponseValue(draft))
        } else {
            onSubmitFreeform(freeformSentinel, draft)
        }
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

#if DEBUG
#Preview("Ask User · Transcript Answer") {
    let answer = PiAgentTranscriptEntry(
        sessionID: UUID(),
        role: .user,
        title: "Ask User Response",
        text: "Keep it right aligned, but use the Ask User symbol and call it Answer."
    )

    HStack(spacing: 0) {
        Spacer(minLength: 72)
        PiAgentTranscriptCard(entry: answer, style: .question)
            .frame(maxWidth: 560, alignment: .trailing)
    }
    .frame(width: 720, height: 120, alignment: .trailing)
    .padding(24)
    .background(AppTheme.windowBackground)
    .environment(\.transcriptContentWidth, 720)
}
#endif
