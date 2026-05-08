import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        if !fileSuggestions.isEmpty {
            suggestionPanel(title: fileSuggestions.count >= 10 ? "Files — showing top 10, keep typing to refine" : "Files", icon: "paperclip", scrollable: true) {
                ForEach(fileSuggestions.prefix(10)) { suggestion in
                    Button { onSelectFile(suggestion) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestion.isDirectory ? "folder" : "doc.text")
                                .frame(width: 14)
                            Text(suggestion.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if !commands.isEmpty || !skills.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !commands.isEmpty {
                        suggestionPanel(title: "Slash commands", icon: "terminal") {
                            commandRows(commands)
                        }
                    }
                    if !skills.isEmpty {
                        suggestionPanel(title: "Skills", icon: "sparkles") {
                            skillRows(skills)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 220)
        }
    }

    private func commandRows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { command in
            Button { onSelectCommand(command) } label: {
                Text(command)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func skillRows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { command in
            Button { onSelectCommand(command) } label: {
                Text(command.replacingOccurrences(of: "/skill:", with: ""))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func suggestionPanel<Content: View>(title: String, icon: String, scrollable: Bool = false, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            if scrollable {
                ScrollView {
                    suggestionRows(content: content)
                }
                .frame(maxHeight: 180)
            } else {
                suggestionRows(content: content)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    private func suggestionRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.contentSubtleFill))
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
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
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
                .buttonStyle(.borderedProminent)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.brandAccent)
                Text("Response needed")
                    .font(.headline)
                    .fontWidth(.expanded)
                Spacer()
            }

            PiAgentUIRequestCard(
                request: request,
                onSubmitValue: onSubmitValue,
                onSubmitFreeform: onSubmitFreeform,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: 760, minHeight: 260)
        .presentationSizing(.fitted)
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
    @State private var commentDraft = ""
    @State private var isComposingFreeform = false
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                switch request.method {
                case .select:
                    if isComposingFreeform {
                        freeformComposer
                    } else {
                        selectOptions
                    }
                case .multiSelect:
                    multiSelectOptions
                case .confirm:
                    HStack(spacing: 10) {
                        Button("No") { onConfirm(false) }
                        Button("Yes") { onConfirm(true) }
                            .buttonStyle(.borderedProminent)
                    }
                case .input, .editor:
                    textInput(submitTitle: "Submit", cancelTitle: "Cancel", cancelAction: onCancel) { submitTextInput() }
                }
            }
        }
        .onAppear {
            if draft.isEmpty, let prefill = request.prefill {
                draft = prefill
            }
        }
        .onChange(of: request.id) { _, _ in
            draft = request.prefill ?? ""
            commentDraft = ""
            isComposingFreeform = false
            selectedOptions = []
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(AppTheme.brandAccent)
                .font(.title3)
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
            Spacer()
            if request.method != .input && request.method != .editor && !isComposingFreeform && request.responseFormat != .nativeAsk {
                Button("Cancel", action: onCancel)
            }
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
                        Button {
                            if option == freeformSentinel {
                                isComposingFreeform = true
                            } else {
                                onSubmitValue(option)
                            }
                        } label: {
                            HStack {
                                Text(option)
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: option == freeformSentinel ? "square.and.pencil" : "arrow.right.circle.fill")
                                    .foregroundStyle(AppTheme.brandAccent)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var freeformComposer: some View {
        textInput(submitTitle: "Submit", cancelTitle: "Back", cancelAction: {
            draft = ""
            isComposingFreeform = false
        }) {
            if request.responseFormat == .nativeAsk {
                onSubmitValue(request.nativeAskFreeformResponseValue(draft))
            } else {
                onSubmitFreeform(freeformSentinel, draft)
            }
        }
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
                        Button("Submit") { onSubmitValue(request.options.filter { selectedOptions.contains($0) }.joined(separator: ", ")) }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedOptions.isEmpty)
                    }
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
                Button {
                    selectedOptions = []
                    isComposingFreeform = true
                    draft = ""
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
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if isComposingFreeform {
                TextField("Custom response", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onSubmitValue(request.nativeAskFreeformResponseValue(trimmed))
                        }
                    }
            } else if request.allowsComment {
                TextField("Optional comment", text: $commentDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
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
                .buttonStyle(.borderedProminent)
                .disabled(nativeAskSubmitDisabled)
            }
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
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
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
        onSubmitValue(request.nativeAskSelectionResponseValue(selections: orderedSelections, comment: commentDraft))
    }
}

private extension PiAgentUIRequest {
    var allowsEmptyInputResponse: Bool {
        guard method == .input else { return false }
        let prompt = (placeholder ?? "").lowercased()
        return prompt.contains("press enter to skip") || prompt.contains("optional")
    }
}
