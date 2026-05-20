import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private extension View {
    func suggestionBottomFade(height: CGFloat = 24) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
            }
        }
    }
}

struct PiAgentFileSuggestion: Identifiable, Hashable {
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

struct PiAgentCommandSuggestions: View {
    let commands: [String]
    let skills: [String]
    let fileSuggestions: [PiAgentFileSuggestion]
    let onSelectFile: (PiAgentFileSuggestion) -> Void
    let onSelectCommand: (String) -> Void

    private let maxPopoverHeight: CGFloat = 340
    private let maxListHeight: CGFloat = 300
    private let compactListHeight: CGFloat = 132
    private let popoverWidth: CGFloat = 360

    var body: some View {
        Group {
            if !fileSuggestions.isEmpty {
                suggestionPanel(
                    title: fileSuggestions.count >= 10 ? "Files — showing top 10, keep typing to refine" : "Files",
                    icon: "paperclip",
                    maxHeight: maxListHeight,
                    showsOverflowHint: fileSuggestions.prefix(10).count >= 8
                ) {
                    ForEach(fileSuggestions.prefix(10)) { suggestion in
                        suggestionRow(action: { onSelectFile(suggestion) }) {
                            Image(systemName: suggestion.isDirectory ? "folder" : "doc.text")
                                .frame(width: 14)
                            Text(suggestion.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(width: popoverWidth, alignment: .leading)
            } else if !commands.isEmpty || !skills.isEmpty {
                slashSuggestionColumns
            }
        }
        .frame(maxHeight: maxPopoverHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var slashSuggestionColumns: some View {
        if !commands.isEmpty && !skills.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                suggestionPanel(title: "Commands", icon: "terminal", maxHeight: compactListHeight, showsOverflowHint: commands.count >= 4) {
                    commandRows(commands)
                }

                Divider()
                    .padding(.horizontal, 8)

                suggestionPanel(title: "Skills", icon: "sparkles", maxHeight: compactListHeight, showsOverflowHint: skills.count >= 4) {
                    skillRows(skills)
                }
            }
            .frame(width: popoverWidth, alignment: .topLeading)
        } else if !commands.isEmpty {
            suggestionPanel(title: "Commands", icon: "terminal", maxHeight: maxListHeight, showsOverflowHint: commands.count >= 8) {
                commandRows(commands)
            }
            .frame(width: popoverWidth, alignment: .topLeading)
        } else if !skills.isEmpty {
            suggestionPanel(title: "Skills", icon: "sparkles", maxHeight: maxListHeight, showsOverflowHint: skills.count >= 8) {
                skillRows(skills)
            }
            .frame(width: popoverWidth, alignment: .topLeading)
        }
    }

    private func commandRows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { command in
            suggestionRow(action: { onSelectCommand(command) }) {
                Text(command)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func skillRows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { command in
            suggestionRow(action: { onSelectCommand(command) }) {
                Text(command.replacingOccurrences(of: "/skill:", with: ""))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func suggestionSection(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.monospaced().italic())
            .fontWidth(.condensed)
            .foregroundStyle(AppTheme.brandAccent)
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 1)
    }

    private func suggestionRow<Content: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func suggestionPanel<Content: View>(title: String? = nil, icon: String? = nil, maxHeight: CGFloat, showsOverflowHint: Bool, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, let icon {
                suggestionSection(title: title, icon: icon)
            }
            suggestionScroll(maxHeight: maxHeight, showsOverflowHint: showsOverflowHint, content: content)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func suggestionScroll<Content: View>(maxHeight: CGFloat, showsOverflowHint: Bool, @ViewBuilder content: @escaping () -> Content) -> some View {
        let scrollView = ScrollView(showsIndicators: false) {
            suggestionRows(content: content)
        }
        .frame(maxHeight: maxHeight)

        if showsOverflowHint {
            scrollView.suggestionBottomFade()
        } else {
            scrollView
        }
    }

    private func suggestionRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
                .font(.caption)
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
                ScrollView {
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
