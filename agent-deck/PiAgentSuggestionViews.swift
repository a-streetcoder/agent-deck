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
/// composer (osaurus's `SlashCommandPopup` pattern) — no popover, no arrow, no
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
        .appGlassPanel(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                .font(.system(size: 9, weight: .semibold))
            Text(sectionTitle(kind))
                .font(.caption2.weight(.semibold))
            // File scans are capped at 10 results — surface the cap on the same
            // row so the user knows to keep typing to narrow things down.
            if kind == .file && items.count >= 10 {
                Spacer(minLength: 8)
                Text("showing top 10 — keep typing to refine")
                    .font(.caption2.italic())
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
                    .font(.caption)
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 16)
                Text(item.title)
                    .font(.callout.monospaced())
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

struct PiAgentSkillUsePill: View {
    let skill: SkillRecord?
    let invocation: String
    @State private var isPreviewPresented = false

    var body: some View {
        Button {
            isPreviewPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(AppTheme.assistantAccent)
                Text(skill?.name ?? invocation)
                    .font(.callout.weight(.semibold))
                Text("skill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.contentSubtleFill))
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.assistantAccent.opacity(0.08)).stroke(AppTheme.assistantAccent.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPreviewPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(skill?.name ?? invocation)
                    .font(.headline)
                if let description = skill?.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ScrollView(showsIndicators: false) {
                    Text(skill?.body.isEmpty == false ? skill!.body : (skill?.filePath ?? "Skill details are not available in \(AppBrand.displayName)'s current scan snapshot."))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            .padding(14)
            .frame(width: 520, alignment: .leading)
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
                        .font(.system(size: 7, weight: .bold))
                }
                Image(systemName: symbols[index])
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption.weight(.medium))
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
                    .font(.callout.weight(.semibold))
                Text(request.title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
            Button("Respond…", action: onRespond)
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .appGlassPanel(cornerRadius: 22)
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
                        .buttonStyle(.glassProminent)
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
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(.headline)
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
                                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 10) {
                        Spacer()
                        Button("Cancel", action: onCancel)
                        if isComposingFreeform {
                            Button("Submit") { onSubmitFreeform(freeformSentinel, draft) }
                                .buttonStyle(.glassProminent)
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
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 10) {
                        Spacer()
                        Button("Cancel", action: onCancel)
                        Button("Submit") { onSubmitValue(request.options.filter { selectedOptions.contains($0) }.joined(separator: ", ")) }
                            .buttonStyle(.glassProminent)
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
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                .buttonStyle(.glassProminent)
                .disabled(nativeAskSubmitDisabled)
            }
            .padding(.top, 4)
        }
    }

    private func textInput(submitTitle: String, cancelTitle: String, cancelAction: @escaping () -> Void, submitAction: @escaping () -> Void) -> some View {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSubmit = !trimmedDraft.isEmpty || request.allowsEmptyInputResponse

        return VStack(alignment: .leading, spacing: 8) {
            TextField(request.placeholder ?? "Response", text: $draft, axis: request.method == .editor ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .lineLimit(request.method == .editor ? 4...10 : 1...3)
                .onSubmit {
                    if canSubmit {
                        submitAction()
                    }
                }
            HStack(spacing: 10) {
                Spacer()
                Button(cancelTitle, action: cancelAction)
                Button(submitTitle, action: submitAction)
                    .buttonStyle(.glassProminent)
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
