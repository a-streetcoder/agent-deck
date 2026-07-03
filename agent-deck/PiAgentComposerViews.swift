import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentPasteAttachment: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let marker: String
    let text: String
}

enum PiAgentPasteMarkerCodec {
    static let largePasteLineThreshold = 10
    static let largePasteCharacterThreshold = 1000

    static func normalizedText(from rawText: String) -> String {
        rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
    }

    static func shouldCollapse(_ text: String) -> Bool {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lineCount > largePasteLineThreshold || text.count > largePasteCharacterThreshold
    }

    static func marker(id: Int, text: String) -> String {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if lineCount > largePasteLineThreshold {
            return "[paste #\(id) +\(lineCount) lines]"
        }
        return "[paste #\(id) \(text.count) chars]"
    }

    static func activeAttachments(in text: String, attachments: [PiAgentPasteAttachment]) -> [PiAgentPasteAttachment] {
        guard !attachments.isEmpty, text.contains("[paste #") else { return [] }
        return attachments.filter { text.contains($0.marker) }
    }

    static func expandMarkers(in text: String, attachments: [PiAgentPasteAttachment]) -> String {
        let activeAttachments = activeAttachments(in: text, attachments: attachments)
        guard !activeAttachments.isEmpty else { return text }
        var expanded = text
        for attachment in activeAttachments {
            expanded = expanded.replacingOccurrences(of: attachment.marker, with: attachment.text)
        }
        return expanded
    }
}

struct PiAgentComposerBox: View {
    private let maxImages = 8

    @Binding var text: String
    @Binding var pasteAttachments: [PiAgentPasteAttachment]
    @Binding var nextPasteID: Int
    @Binding var images: [PiAgentImageAttachment]
    @Binding var files: [PiAgentFileAttachment]
    @Binding var folders: [PiAgentFolderAttachment]
    @Binding var issueAttachment: PiAgentIssueAttachment?
    @Binding var attachmentError: String?
    @Binding var inputMode: PiAgentInputMode
    let isRunning: Bool
    let isDisabled: Bool
    let placeholder: String
    let canSend: Bool
    let canCreateSession: Bool
    let createSessionProjects: [DiscoveredProject]
    let onFiles: ([URL]) -> Void
    let onFolders: ([URL]) -> Void
    let viewModel: AppViewModel
    let footerSession: PiAgentSessionRecord?
    let supportedThinkingLevels: [String]
    let metricsSession: PiAgentSessionRecord?
    /// Picked `/`-suggestion (skill / prompt / command). Rendered as a glass
    /// capsule chip above the editor; included in the send payload by the
    /// caller, not by this view.
    var slashSelection: SlashItem? = nil
    var onRemoveSlashSelection: () -> Void = {}
    let onSend: () -> Void
    let onStop: () -> Void
    let onCreateSession: () -> Void
    let onCreateSessionForProject: (DiscoveredProject) -> Void
    let onClear: () -> Void
    var suggestionKeyBridge: ComposerSuggestionKeyBridge = ComposerSuggestionKeyBridge()
    @State private var isDropTargeted = false
    @State private var isIssuePickerPresented = false
    // Non-worktree sessions don't carry `branchName`; resolve the project's
    // current branch off the body hot path via `.task(id:)`.
    @State private var resolvedBranch: String?
    // Aggregate token/cost (orchestration + subagents) shown in the footer.
    // Recomputed off the body hot path in `.onChange`, never in `body` (summing
    // a few ints/doubles, but the subagent-run read must stay off the render path).
    @State private var costAggregate: PiAgentRuntimeCostAggregate?

    private var displayedBranch: String? {
        if let direct = metricsSession?.branchName, !direct.isEmpty { return direct }
        return resolvedBranch
    }

    /// Change signal for the footer cost aggregate: the parent's tokens/cost plus
    /// the store's de-noised subagent-runs revision. Read only by `.onChange`.
    private var costAggregateKey: String {
        guard let session = metricsSession else { return "" }
        return [
            session.id.uuidString,
            session.inputTokens.map { "in:\($0)" } ?? "in:-",
            session.outputTokens.map { "out:\($0)" } ?? "out:-",
            session.cacheReadTokens.map { "cr:\($0)" } ?? "cr:-",
            session.cacheWriteTokens.map { "cw:\($0)" } ?? "cw:-",
            session.totalTokens.map { "total:\($0)" } ?? "total:-",
            session.cost.map { "\($0)" } ?? "-",
            Self.costKey(session.costBreakdown),
            "\(viewModel.piAgentSessionStore.subagentRunsRevision)"
        ].joined(separator: "|")
    }

    private static func costKey(_ costBreakdown: PiAgentUsageCostBreakdown?) -> String {
        guard let costBreakdown else { return "costBreakdown:-" }
        let values: [Double?] = [costBreakdown.input, costBreakdown.output, costBreakdown.cacheRead, costBreakdown.cacheWrite, costBreakdown.total]
        return values
            .map { value in value.map { String($0) } ?? "-" }
            .joined(separator: ",")
    }

    private func recomputeCostAggregate() {
        guard let session = metricsSession else { costAggregate = nil; return }
        let runs = viewModel.piAgentSessionStore.subagentRuns(for: session.id)
        costAggregate = PiAgentRuntimeCostAggregate.build(session: session, runs: runs)
    }

    private var branchRevealURL: URL? {
        guard let session = metricsSession else { return nil }
        return URL(fileURLWithPath: session.repositoryRoot, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if slashSelection != nil || !images.isEmpty || !files.isEmpty || !folders.isEmpty || issueAttachment != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let slashSelection {
                            PiAgentSlashSelectionChip(item: slashSelection, onRemove: onRemoveSlashSelection)
                        }
                        if let issueAttachment {
                            PiAgentIssueAttachmentChip(issue: issueAttachment) {
                                self.issueAttachment = nil
                            }
                        }
                        ForEach(images) { image in
                            PiAgentImageAttachmentThumbnail(image: image) {
                                images.removeAll { $0.id == image.id }
                            }
                        }
                        ForEach(files) { file in
                            PiAgentFileAttachmentChip(file: file) {
                                files.removeAll { $0.id == file.id }
                            }
                        }
                        ForEach(folders) { folder in
                            PiAgentFolderAttachmentChip(folder: folder) {
                                folders.removeAll { $0.id == folder.id }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(AppTheme.Font.body)
                        .foregroundStyle(AppTheme.mutedText.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                PiAgentDropSafeTextEditor(
                    text: $text,
                    pasteAttachments: $pasteAttachments,
                    nextPasteID: $nextPasteID,
                    onDropTargeted: { isDropTargeted = $0 },
                    onImages: addImages,
                    onFiles: onFiles,
                    onFolders: onFolders,
                    onUnsupportedDrop: { attachmentError = "Drop images, files, or folders." },
                    onSend: onSend,
                    onClear: onClear,
                    isDisabled: isDisabled,
                    suggestionKeyBridge: suggestionKeyBridge,
                    onDictationUnavailable: {
                        attachmentError = "Dictation is unavailable. Enable Dictation in System Settings > Keyboard, then try again."
                    }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(minHeight: 92, maxHeight: 132)
                .bottomEdgeFade(height: 18)
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                if let footerSession {
                    HStack(spacing: 10) {
                        PiAgentComposerFooterBar(
                            session: footerSession,
                            viewModel: viewModel,
                            supportedThinkingLevels: supportedThinkingLevels
                        )
                        composerActionControls

                        Spacer(minLength: 18)
                        PiAgentSendButton(isRunning: isRunning, canSend: canSend && !isDisabled, sendAction: onSend, stopAction: onStop)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                } else if canCreateSession {
                    HStack(spacing: 10) {
                        Spacer(minLength: 18)
                        PiAgentCreateSessionFromComposerButton(
                            projects: createSessionProjects,
                            action: onCreateSession,
                            onSelectProject: onCreateSessionForProject
                        )
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    if let branch = displayedBranch, let revealURL = branchRevealURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                        } label: {
                            HStack(spacing: 3) {
                                Image("branch")
                                    .font(AppTheme.Font.caption2.weight(.semibold))
                                Text(piAgentSessionDisplayBranchName(branch))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                        }
                        .buttonStyle(.plain)
                        .help("\(branch)\n\(revealURL.path)")
                    }

                    if let metricsSession {
                        PiAgentRuntimeFooter(
                            session: metricsSession,
                            aggregate: costAggregate,
                            openAIFastStatus: openAIFastStatus(for: metricsSession),
                            onToggleOpenAIFast: openAIFastToggleAction(for: metricsSession),
                            onSetAsDefault: setAsDefaultAction(for: metricsSession)
                        )
                        // Recompute the aggregate when the parent's tokens/cost or
                        // the subagent runs change (de-noised revision), off-body.
                        .onChange(of: costAggregateKey, initial: true) {
                            recomputeCostAggregate()
                        }
                    }

                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .appContentSurface(cornerRadius: AppTheme.Chat.composerCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous)
                .stroke(isDropTargeted ? AppTheme.brandAccent.opacity(0.7) : Color.clear, lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay {
            if isDropTargeted {
                    RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous)
                        .fill(AppTheme.brandAccent.opacity(0.10))
                        .allowsHitTesting(false)
            }
            if isDisabled {
                RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous)
                    .fill(AppTheme.contentFill.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 7)
        .onPasteCommand(of: [.png, .jpeg, .tiff, .gif, .webP, .fileURL]) { _ in
            addImages(PiAgentComposerImageLoader.imagesFromPasteboard())
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .tiff, .gif, .webP, .image], isTargeted: $isDropTargeted) { providers in
            // Defer NSItemProvider loading off the drop callback so AppKit can
            // finish the drag-IPC teardown (kDragIPCLeaveApplication) before
            // we trigger more drag IPC inside loadItem.
            DispatchQueue.main.async {
                PiAgentComposerImageLoader.loadDropItems(from: providers) { attachments, files in
                    let folderURLs = files.filter { PiAgentFolderAttachment(url: $0) != nil }
                    let fileURLs = files.filter { PiAgentFolderAttachment(url: $0) == nil }
                    if attachments.isEmpty && fileURLs.isEmpty && folderURLs.isEmpty {
                        attachmentError = "Drop images, files, or folders."
                    } else {
                        addImages(attachments)
                        onFiles(fileURLs)
                        onFolders(folderURLs)
                    }
                }
            }
            return true
        }
        .task(id: footerSession?.id) {
            viewModel.ensureComposerIssuesLoaded(for: footerSession)
        }
        .task(id: metricsSession?.id) {
            // For worktree-on sessions `branchName` is set at creation; for
            // worktree-off sessions resolve the project's current branch via git.
            // Runs off the body path; refreshed on session-id change.
            guard let session = metricsSession else {
                resolvedBranch = nil
                return
            }
            if let direct = session.branchName, !direct.isEmpty {
                resolvedBranch = nil
                return
            }
            guard let projectPath = session.projectPathForProjectFeatures else {
                resolvedBranch = nil
                return
            }
            let url = URL(fileURLWithPath: projectPath, isDirectory: true)
            let branch = try? await GitRepositoryService().currentBranch(in: url)
            guard !Task.isCancelled else { return }
            resolvedBranch = (branch?.isEmpty == false && branch != "HEAD") ? branch : nil
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Chat.composerCornerRadius, style: .continuous))
    }

    private var composerActionControls: some View {
        AppControlGroup(spacing: 6) {
            if viewModel.githubConnectionState.isConnected && viewModel.composerGitHubProject(for: footerSession)?.gitHubRemote != nil {
                Button {
                    isIssuePickerPresented.toggle()
                } label: {
                    Image("github")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .appGlassCircle()
                }
                .buttonStyle(.plain)
                .help("Attach GitHub issue or pull request")
                .accessibilityLabel("Attach GitHub issue or pull request")
                .popover(isPresented: $isIssuePickerPresented, arrowEdge: .bottom) {
                    PiAgentIssuePickerPopover(
                        viewModel: viewModel,
                        session: footerSession,
                        onSelect: { issue in
                            issueAttachment = issue
                            attachmentError = nil
                            isIssuePickerPresented = false
                        }
                    )
                }
            }

            Button(action: attachImagesFromOpenPanel) {
                Image(systemName: "paperclip")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 24, height: 24)
                    .appGlassCircle()
            }
            .buttonStyle(.plain)
            .help("Attach files")
            .accessibilityLabel("Attach files")
            .accessibilityHint("Attach images, text files, or local file paths")
        }
    }

    private func attachImagesFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let folderURLs = panel.urls.filter { PiAgentFolderAttachment(url: $0) != nil }
        let fileURLs = panel.urls.filter { PiAgentFolderAttachment(url: $0) == nil }
        let imageAttachments = fileURLs.compactMap { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) }
        let files = fileURLs.filter { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) == nil }
        addImages(imageAttachments)
        onFiles(files)
        onFolders(folderURLs)
    }

    private func openAIFastStatus(for session: PiAgentSessionRecord) -> Bool? {
        openAIFastModel(for: session).map { viewModel.appSettings.openAIFastModeModelIdentifiers.contains($0.identifier) }
    }

    private func openAIFastToggleAction(for session: PiAgentSessionRecord) -> (() -> Void)? {
        guard let model = openAIFastModel(for: session) else { return nil }
        return {
            viewModel.setOpenAIFastMode(model, isEnabled: !viewModel.isOpenAIFastModeEnabled(model))
        }
    }

    private func openAIFastModel(for session: PiAgentSessionRecord) -> AvailableModel? {
        let fallback = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let modelID = session.modelOverrideID ?? session.model ?? fallback?.model
        guard PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: provider, modelID: modelID) else { return nil }
        let baseModelID = modelID?.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let identifier = "\(provider ?? "")/\(baseModelID)"
        return viewModel.availableModels.first { $0.identifier == identifier }
            ?? viewModel.enabledAvailableModels.first { $0.identifier == identifier }
    }

    private func currentModel(for session: PiAgentSessionRecord) -> AvailableModel? {
        let fallback = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let modelID = session.modelOverrideID ?? session.model ?? fallback?.model
        // Strip thinking suffix (e.g. "gpt-5.2:high" → "gpt-5.2") before lookup
        let baseModelID = modelID?.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let identifier = "\(provider ?? "")/\(baseModelID)"
        return viewModel.availableModels.first { $0.identifier == identifier }
            ?? viewModel.enabledAvailableModels.first { $0.identifier == identifier }
    }

    private func setAsDefaultAction(for session: PiAgentSessionRecord) -> (() -> Void)? {
        let model = currentModel(for: session)
        let thinkingLevel = session.thinkingLevel
        let defaultModel = viewModel.defaultPiAgentModel()
        let defaultThinking = viewModel.piRuntimeDefaultThinkingLevel()
        let modelDiffers = model?.identifier != defaultModel?.identifier
        let resolvedThinking = thinkingLevel ?? defaultThinking
        let thinkingDiffers = resolvedThinking != defaultThinking
        guard modelDiffers || thinkingDiffers else { return nil }
        return { [weak viewModel] in
            if let model {
                viewModel?.setDefaultPiAgentModel(model)
            }
            if let level = thinkingLevel {
                viewModel?.setDefaultPiAgentThinkingLevel(level)
            }
        }
    }

    private func addImages(_ newImages: [PiAgentImageAttachment]) {
        guard !newImages.isEmpty else { return }
        attachmentError = nil
        var next = images
        for image in newImages {
            if next.count >= maxImages {
                attachmentError = "Pi supports up to \(maxImages) images per message."
                break
            }
            if !next.contains(where: { $0.data == image.data }) {
                next.append(image)
            }
        }
        images = next
    }
}

struct PiAgentDropSafeTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var pasteAttachments: [PiAgentPasteAttachment]
    @Binding var nextPasteID: Int
    var onDropTargeted: (Bool) -> Void
    var onImages: ([PiAgentImageAttachment]) -> Void
    var onFiles: ([URL]) -> Void
    var onFolders: ([URL]) -> Void
    var onUnsupportedDrop: () -> Void
    var onSend: () -> Void
    var onClear: () -> Void
    var isDisabled: Bool
    var suggestionKeyBridge: ComposerSuggestionKeyBridge
    var onDictationUnavailable: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = DropSafeNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = !isDisabled
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? DropSafeNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func startSystemDictation(in textView: NSTextView, onUnavailable: @escaping () -> Void) {
        textView.window?.makeFirstResponder(textView)
        DispatchQueue.main.async {
            guard NSApp.sendAction(Selector(("startDictation:")), to: nil, from: textView) else {
                onUnavailable()
                return
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, DropSafeNSTextViewDropHandler, DropSafeNSTextViewKeyHandler {
        var parent: PiAgentDropSafeTextEditor
        // Tracks the last value pushed to SwiftUI so draggingUpdated (which fires
        // on every mouse move during drag) doesn't write the same value over and
        // over. Each write re-renders the parent and re-registers its .onDrop,
        // which collides with AppKit's drag IPC → kDragIPCWithinWindow reentrancy.
        private var lastReportedDropTargeted: Bool = false

        init(parent: PiAgentDropSafeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func setDropTargeted(_ targeted: Bool) {
            guard lastReportedDropTargeted != targeted else { return }
            lastReportedDropTargeted = targeted
            // Defer to next runloop so AppKit finishes the drag-IPC message that
            // triggered us before SwiftUI mutates state and re-registers drops.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onDropTargeted(targeted)
            }
        }

        func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
            let images = PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard)
            let droppedURLs = PiAgentComposerImageLoader.fileURLs(from: pasteboard).filter { url in
                PiAgentFolderAttachment(url: url) != nil || PiAgentComposerImageLoader.imageAttachment(fromFileURL: url) == nil
            }
            let folders = droppedURLs.filter { PiAgentFolderAttachment(url: $0) != nil }
            let files = droppedURLs.filter { PiAgentFolderAttachment(url: $0) == nil }
            if images.isEmpty && files.isEmpty && folders.isEmpty {
                parent.onUnsupportedDrop()
                return false
            }
            parent.onImages(images)
            parent.onFiles(files)
            parent.onFolders(folders)
            return true
        }

        func handleTextPaste(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool {
            guard let rawText = pasteboard.string(forType: .string), !rawText.isEmpty else { return false }
            let normalizedText = PiAgentPasteMarkerCodec.normalizedText(from: rawText)
            guard PiAgentPasteMarkerCodec.shouldCollapse(normalizedText) else { return false }

            let pasteID = parent.nextPasteID
            parent.nextPasteID += 1
            let marker = PiAgentPasteMarkerCodec.marker(id: pasteID, text: normalizedText)
            parent.pasteAttachments.append(.init(id: pasteID, marker: marker, text: normalizedText))

            textView.insertText(marker, replacementRange: textView.selectedRange())
            parent.text = textView.string
            return true
        }

        func send() {
            guard !parent.isDisabled else { return }
            parent.onSend()
        }

        func clear() {
            guard !parent.isDisabled else { return }
            parent.onClear()
        }

        func suggestionsActive() -> Bool {
            parent.suggestionKeyBridge.isActive
        }

        func moveSuggestionHighlight(by delta: Int) {
            parent.suggestionKeyBridge.onMove(delta)
        }

        func acceptSuggestionHighlight() -> Bool {
            parent.suggestionKeyBridge.onAccept()
        }

        func dismissSuggestions() {
            parent.suggestionKeyBridge.onDismiss()
        }

        func startDictation(in textView: NSTextView) {
            guard !parent.isDisabled else { return }
            parent.startSystemDictation(in: textView, onUnavailable: parent.onDictationUnavailable)
        }
    }
}

@MainActor
protocol DropSafeNSTextViewDropHandler: AnyObject {
    func setDropTargeted(_ targeted: Bool)
    func handleDrop(_ pasteboard: NSPasteboard) -> Bool
    func handleTextPaste(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool
}

@MainActor
protocol DropSafeNSTextViewKeyHandler: AnyObject {
    func send()
    func clear()
    /// Whether the composer suggestion panel is currently shown. When true, the
    /// text view routes arrows/Tab/Return/Escape to the suggestion handlers below.
    func suggestionsActive() -> Bool
    func moveSuggestionHighlight(by delta: Int)
    /// Returns true if a highlighted suggestion was accepted (and the event consumed).
    func acceptSuggestionHighlight() -> Bool
    func dismissSuggestions()
    func startDictation(in textView: NSTextView)
}

@MainActor
final class DropSafeNSTextView: NSTextView {
    weak var dropHandler: DropSafeNSTextViewDropHandler?
    weak var keyHandler: DropSafeNSTextViewKeyHandler?
    private var lastEscapeAt: TimeInterval?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHandler?.setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHandler?.setDropTargeted(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        dropHandler?.setDropTargeted(false)
        return dropHandler?.handleDrop(sender.draggingPasteboard) ?? false
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        let isReturn = characters == "\r" || characters == "\n"
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])

        if characters.lowercased() == "d", modifiers == .option {
            keyHandler?.startDictation(in: self)
            return
        }

        // While the suggestion panel is open, navigation keys drive the panel
        // instead of the caret / send action.
        if keyHandler?.suggestionsActive() == true {
            switch event.keyCode {
            case 126: keyHandler?.moveSuggestionHighlight(by: -1); return  // up arrow
            case 125: keyHandler?.moveSuggestionHighlight(by: 1); return   // down arrow
            case 53: keyHandler?.dismissSuggestions(); return              // escape
            case 48: if keyHandler?.acceptSuggestionHighlight() == true { return }  // tab
            default: break
            }
            if isReturn && modifiers.isEmpty, keyHandler?.acceptSuggestionHighlight() == true {
                return
            }
        }

        if isReturn && modifiers.isEmpty {
            keyHandler?.send()
            return
        }
        if isReturn && (modifiers.contains(.shift) || modifiers.contains(.command) || modifiers.contains(.option)) {
            insertNewlineIgnoringFieldEditor(self)
            return
        }
        if event.keyCode == 53 {
            let now = event.timestamp
            if let lastEscapeAt, now - lastEscapeAt < 0.6 {
                keyHandler?.clear()
                self.lastEscapeAt = nil
                return
            }
            self.lastEscapeAt = now
            super.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if acceptsDrop(pasteboard), dropHandler?.handleDrop(pasteboard) == true {
            return
        }
        if dropHandler?.handleTextPaste(pasteboard, in: self) == true {
            return
        }
        super.paste(sender)
    }

    private func acceptsDrop(_ pasteboard: NSPasteboard) -> Bool {
        !PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard).isEmpty || !PiAgentComposerImageLoader.fileURLs(from: pasteboard).isEmpty
    }
}

struct PiAgentSubagentPopover: View {
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Deck agents", systemImage: "paperplane")
                    .font(AppTheme.Font.body.weight(.medium))
                Spacer(minLength: 24)
                Toggle("Deck agents", isOn: $isEnabled)
                    .appSwitch()
                    .labelsHidden()
            }
            Text(isEnabled ? "Parent Pi can delegate to Deck agents when useful." : "Deck agent tools are not exposed to this session.")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

struct PiAgentFileAttachmentChip: View {
    let file: PiAgentFileAttachment
    let onRemove: () -> Void

    var body: some View {
        PiAgentPathAttachmentChip(
            title: file.url.lastPathComponent.isEmpty ? file.url.path : file.url.lastPathComponent,
            path: file.url.path,
            systemImage: "doc.text",
            onRemove: onRemove
        )
    }
}

struct PiAgentFolderAttachmentChip: View {
    let folder: PiAgentFolderAttachment
    let onRemove: () -> Void

    var body: some View {
        PiAgentPathAttachmentChip(
            title: folder.url.lastPathComponent.isEmpty ? folder.url.path : folder.url.lastPathComponent,
            path: folder.url.path,
            systemImage: "folder",
            onRemove: onRemove
        )
    }
}

struct PiAgentIssueAttachmentChip: View {
    let issue: PiAgentIssueAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image("github")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(AppTheme.mutedText)
            Text("\(issue.kindShortTitle) #\(issue.number) \(issue.title)")
                .lineLimit(1)
                .truncationMode(.head)
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
        .help(issue.repository)
    }
}

private struct PiAgentIssuePickerPopover: View {
    var viewModel: AppViewModel
    let session: PiAgentSessionRecord?
    let onSelect: (PiAgentIssueAttachment) -> Void

    @State private var query = ""
    @State private var isLoading = false
    @State private var loadingIssueID: String?
    @State private var errorText: String?

    private var items: [GitHubWorkItem] {
        let source = viewModel.githubComposerIssueItems(for: session)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return source }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source.filter { item in
            item.searchableHaystack.contains(needle)
            || "#\(item.number)".contains(needle)
            || item.kindTitle.lowercased().contains(needle)
            || item.kindShortTitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attach GitHub Issue or Pull Request")
                .font(AppTheme.Font.headline)

            AppTextField(text: $query, placeholder: "Search visible issues and pull requests")

            if let errorText {
                Text(errorText)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.orange)
            }

            if items.isEmpty {
                Text(emptyStateText)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 400, alignment: .leading)
            } else {
                let visibleItems = items.prefix(20)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleItems) { item in
                            ZStack(alignment: .topTrailing) {
                                GitHubIssueListRow(
                                    item: item,
                                    isSelected: false,
                                    onSelect: { attach(item) },
                                    showsKindBadge: true
                                )
                                if loadingIssueID == item.id && isLoading {
                                    AppSpinner()
                                        .controlSize(.small)
                                        .padding(12)
                                }
                            }
                            .disabled(isLoading)
                        }
                    }
                }
                .defaultScrollAnchor(.top)
                .frame(width: 420, height: 320)
            }
        }
        .padding(12)
        .onAppear {
            viewModel.ensureComposerIssuesLoaded(for: session, force: true)
        }
    }

    private var emptyStateText: String {
        if !viewModel.githubConnectionState.isConnected {
            return "Connect GitHub first to attach an issue or pull request."
        }
        if viewModel.composerGitHubProject(for: session)?.gitHubRemote != nil {
            return viewModel.githubIsLoadingComposerBoard
                ? "Loading issues and pull requests for the selected repository…"
                : "No issues or pull requests loaded for the selected repository yet."
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching issues or pull requests."
        }
        return "Select a GitHub project to attach one of its issues or pull requests."
    }

    private func attach(_ item: GitHubWorkItem) {
        isLoading = true
        loadingIssueID = item.id
        errorText = nil
        viewModel.fetchPiAgentIssueAttachment(for: item) { result in
            isLoading = false
            loadingIssueID = nil
            switch result {
            case .success(let issue):
                onSelect(issue)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}

private struct PiAgentPathAttachmentChip: View {
    let title: String
    let path: String
    let systemImage: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.brandAccent)
            Text(title)
                .lineLimit(1)
                .truncationMode(.head)
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
        .help(path)
    }
}

struct PiAgentImageAttachmentThumbnail: View {
    let image: PiAgentImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = PiAgentComposerImageLoader.previewImage(for: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.thumbnailCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Chat.thumbnailCornerRadius, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image attachment")
            .offset(x: 6, y: -6)
        }
        .help("\(image.name) · \(ByteCountFormatter.string(fromByteCount: Int64(image.sizeBytes), countStyle: .file))")
    }
}

enum PiAgentComposerImageLoader {
    nonisolated private static let maxDimension: CGFloat = 2_000
    nonisolated private static let maxEncodedBytes = Int(4.5 * 1024 * 1024)

    nonisolated static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [PiAgentImageAttachment] {
        var attachments: [PiAgentImageAttachment] = []
        let urls = fileURLs(from: pasteboard)
        attachments.append(contentsOf: urls.compactMap(imageAttachment(fromFileURL:)))
        if let data = pasteboard.data(forType: .png), let attachment = imageAttachment(data: data, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        } else if let data = pasteboard.data(forType: .tiff), let pngData = pngData(fromImageData: data), let attachment = imageAttachment(data: pngData, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        }
        return attachments
    }

    nonisolated static func loadImages(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment]) -> Void) {
        loadDropItems(from: providers) { attachments, _ in completion(attachments) }
    }

    nonisolated static func loadDropItems(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment], [URL]) -> Void) {
        let group = DispatchGroup()
        let accumulator = DropItemAccumulator()

        for provider in providers {
            var didScheduleFile = false
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didScheduleFile = true
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url = fileURL(fromProviderItem: item)
                    if let url, let image = imageAttachment(fromFileURL: url) {
                        accumulator.appendImage(image)
                    } else {
                        accumulator.appendFile(url)
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !didScheduleFile {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let png = pngData(fromImageData: data) ?? data
                    accumulator.appendImage(imageAttachment(data: png, name: "dropped-image.png", mimeType: "image/png", fileReference: "dropped-image.png"))
                }
            }
        }

        group.notify(queue: .main) {
            let result = accumulator.result()
            completion(result.attachments, result.files)
        }
    }

    private final class DropItemAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var attachments: [PiAgentImageAttachment] = []
        nonisolated(unsafe) private var files: [URL] = []

        nonisolated init() {}

        nonisolated func appendImage(_ attachment: PiAgentImageAttachment?) {
            guard let attachment else { return }
            lock.lock()
            attachments.append(attachment)
            lock.unlock()
        }

        nonisolated func appendFile(_ url: URL?) {
            guard let url else { return }
            lock.lock()
            files.append(url)
            lock.unlock()
        }

        nonisolated func result() -> (attachments: [PiAgentImageAttachment], files: [URL]) {
            lock.lock()
            let attachments = attachments
            let files = files
            lock.unlock()

            var seen = Set<String>()
            return (attachments, files.filter { seen.insert($0.path).inserted })
        }
    }

    nonisolated private static func fileURL(fromProviderItem item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let value = item as? String {
            return value.hasPrefix("file:") ? URL(string: value) : URL(fileURLWithPath: value)
        }
        if let value = item as? NSString {
            let string = value as String
            return string.hasPrefix("file:") ? URL(string: string) : URL(fileURLWithPath: string)
        }
        return nil
    }

    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: read)
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            urls.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL), let url = URL(string: value) {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    nonisolated static func imageAttachment(fromFileURL url: URL) -> PiAgentImageAttachment? {
        guard let mimeType = mimeType(for: url), let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return imageAttachment(data: data, name: url.lastPathComponent, mimeType: mimeType, fileReference: url.path)
    }

    nonisolated static func imageAttachment(data: Data, name: String, mimeType: String, fileReference: String? = nil) -> PiAgentImageAttachment? {
        guard let processed = processLikePiCLI(data: data, mimeType: mimeType) else { return nil }
        return PiAgentImageAttachment(
            name: name,
            mimeType: processed.mimeType,
            data: processed.data.base64EncodedString(),
            sizeBytes: processed.data.count,
            fileReference: fileReference ?? name,
            dimensionNote: processed.dimensionNote
        )
    }

    @MainActor
    static func previewImage(for attachment: PiAgentImageAttachment) -> NSImage? {
        let key = previewCacheKey(for: attachment)
        if let cached = previewImageCache.object(forKey: key) {
            return cached
        }
        guard let data = Data(base64Encoded: attachment.data), let image = NSImage(data: data) else { return nil }
        previewImageCache.setObject(image, forKey: key)
        return image
    }

    @MainActor private static let previewImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    @MainActor private static func previewCacheKey(for attachment: PiAgentImageAttachment) -> NSString {
        var hasher = Hasher()
        hasher.combine(attachment.data)
        return "\(attachment.id.uuidString):\(attachment.data.count):\(hasher.finalize())" as NSString
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    nonisolated private static func processLikePiCLI(data: Data, mimeType: String) -> (data: Data, mimeType: String, dimensionNote: String?)? {
        let encodedSize = data.base64EncodedString().utf8.count
        guard let image = NSImage(data: data) else { return nil }
        let originalSize = image.pixelSize
        if originalSize.width <= maxDimension,
           originalSize.height <= maxDimension,
           encodedSize < maxEncodedBytes,
           ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType) {
            return (data, mimeType, nil)
        }

        let scale = min(maxDimension / max(originalSize.width, 1), maxDimension / max(originalSize.height, 1), 1)
        var targetSize = CGSize(width: max(1, floor(originalSize.width * scale)), height: max(1, floor(originalSize.height * scale)))
        while targetSize.width >= 1 && targetSize.height >= 1 {
            if let resized = resizedBitmap(from: image, targetSize: targetSize) {
                let candidates = encodedCandidates(from: resized)
                if let candidate = candidates.first(where: { $0.data.base64EncodedString().utf8.count < maxEncodedBytes }) {
                    let dimensionNote = formatDimensionNote(original: originalSize, displayed: targetSize)
                    return (candidate.data, candidate.mimeType, dimensionNote)
                }
            }
            if targetSize.width == 1 && targetSize.height == 1 { break }
            targetSize = CGSize(width: max(1, floor(targetSize.width * 0.75)), height: max(1, floor(targetSize.height * 0.75)))
        }
        return nil
    }

    nonisolated private static func encodedCandidates(from rep: NSBitmapImageRep) -> [(data: Data, mimeType: String)] {
        var candidates: [(Data, String)] = []
        if let png = rep.representation(using: .png, properties: [:]) { candidates.append((png, "image/png")) }
        for quality in [0.80, 0.85, 0.70, 0.55, 0.40] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                candidates.append((jpeg, "image/jpeg"))
            }
        }
        return candidates.sorted(by: { (lhs: (data: Data, mimeType: String), rhs: (data: Data, mimeType: String)) in
            lhs.data.count < rhs.data.count
        })
    }

    nonisolated private static func resizedBitmap(from image: NSImage, targetSize: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: targetSize), from: CGRect(origin: .zero, size: image.size), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    nonisolated private static func formatDimensionNote(original: CGSize, displayed: CGSize) -> String? {
        guard original != displayed else { return nil }
        let scale = original.width / max(displayed.width, 1)
        return "[Image: original \(Int(original.width))x\(Int(original.height)), displayed at \(Int(displayed.width))x\(Int(displayed.height)). Multiply coordinates by \(String(format: "%.2f", scale)) to map to original image.]"
    }

    nonisolated private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private extension NSImage {
    nonisolated var pixelSize: CGSize {
        if let rep = representations.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}

struct PiAgentCreateSessionFromComposerButton: View {
    let projects: [DiscoveredProject]
    let action: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isProjectPickerPresented = false

    var body: some View {
        AppCircleIconButton(
            style: .soft,
            tint: isEnabled ? AppTheme.brandAccent : AppTheme.mutedText,
            size: 30,
            help: projects.isEmpty ? "Start new Pi Agent session" : "Choose a project for the new Pi Agent session",
            action: buttonAction
        ) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(projects.isEmpty ? "Start new Pi Agent session" : "Choose project for new Pi Agent session")
        .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
            PiAgentComposerProjectPickerPopover(
                projects: projects,
                onSelectProject: { project in
                    isProjectPickerPresented = false
                    onSelectProject(project)
                }
            )
        }
    }

    private func buttonAction() {
        if projects.isEmpty {
            action()
        } else {
            isProjectPickerPresented.toggle()
        }
    }
}

private struct PiAgentComposerProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let onSelectProject: (DiscoveredProject) -> Void

    var body: some View {
        AppPopoverContainer(title: "New Session", subtitle: "Choose a project for Pi Agent.") {
            AppProjectPickerPopoverList {
                ForEach(projects) { project in
                    AppPopoverProjectRow(
                        imageURL: project.iconFileURL,
                        symbolName: project.fallbackSymbolName,
                        assetName: project.projectType.assetName,
                        title: project.repositoryDisplayName,
                        path: project.path
                    ) {
                        onSelectProject(project)
                    }
                }
            }
        }
    }
}

struct PiAgentSendButton: View {
    let isRunning: Bool
    let canSend: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        Button(action: isRunning ? stopAction : sendAction) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(AppTheme.Font.body.weight(.bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
        }
        .appPrimaryCircleButton(tint: tintColor, controlSize: .large)
        .disabled(!isRunning && !canSend)
        .help(isRunning ? "Stop Pi Agent" : "Send message")
        .accessibilityLabel(isRunning ? "Stop Pi Agent" : "Send message")
        .background {
            Button("Stop Pi Agent", action: stopAction)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!isRunning)
                .hidden()
        }
        .animation(.snappy(duration: 0.22), value: isRunning)
    }

    private var tintColor: Color {
        if isRunning { return Color.red }
        if canSend { return AppTheme.brandAccent }
        return AppTheme.mutedText.opacity(0.35)
    }
}

struct PiAgentModelSelection {
    let provider: String
    let modelID: String
}

struct PiAgentComposerFooterBar: View {
    let session: PiAgentSessionRecord
    var viewModel: AppViewModel
    let supportedThinkingLevels: [String]

    var body: some View {
        HStack(spacing: 10) {
            PiAgentContextUsageMeter(
                session: session,
                showsSmartZoneHint: viewModel.appSettings.showContextSmartZoneHint,
                onCompact: { viewModel.compactSelectedPiAgentSession() }
            )
            PiAgentModelPicker(
                session: session,
                fallbackModels: viewModel.enabledAvailableModels,
                disabledModelIdentifiers: viewModel.appSettings.disabledModelIdentifiers,
                defaultModel: viewModel.defaultPiAgentModel(),
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onRefresh: { viewModel.refreshPiAgentControlsForSelectedSession() },
                onCycle: { viewModel.cyclePiAgentModelForSelectedSession() },
                onSelect: { selection in
                    if let selection {
                        viewModel.setPiAgentModelForSelectedSession(provider: selection.provider, modelID: selection.modelID)
                    } else {
                        viewModel.setPiAgentModelForSelectedSession(provider: nil, modelID: nil)
                    }
                }
            )
            PiAgentThinkingPicker(
                level: session.thinkingLevel,
                supportedLevels: supportedThinkingLevels,
                defaultLevel: viewModel.defaultPiAgentThinkingLevel(for: supportedThinkingLevels),
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onCycle: { viewModel.cyclePiAgentThinkingLevelForSelectedSession() },
                onSelect: { viewModel.setPiAgentThinkingLevelForSelectedSession($0) }
            )
        }
    }

}

struct PiAgentContextUsageMeter: View {
    let session: PiAgentSessionRecord
    let showsSmartZoneHint: Bool
    let onCompact: () -> Void
    @State private var isConfirmingCompaction = false

    var body: some View {
        if session.isCompacting {
            HStack(spacing: 7) {
                AppSpinner()
                    .controlSize(.small)
                Text("Compacting context")
                    .font(AppTheme.Font.caption.weight(.semibold))
                if let tokens = session.contextTokens {
                    Text("\(compact(tokens)) tokens")
                        .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .appGlassCapsule()
            .fixedSize(horizontal: true, vertical: false)
            .help("Pi is compacting this conversation. Input is disabled until compaction finishes.")
        } else if let percent = session.contextPercent, let tokens = session.contextTokens, let window = session.contextWindow {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 7) {
                        Text("Context")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                        PiAgentSmartZoneContextBar(
                            percent: percent,
                            showsSmartZoneHint: showsSmartZoneHint,
                            width: 92,
                            height: 10
                        )
                        Text("\(Int(percent))%")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.bold))
                            .lineLimit(1)
                        Text("\(compact(tokens))/\(compact(window))")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .appGlassCapsule()
                    .fixedSize(horizontal: true, vertical: false)
                    .help(showsSmartZoneHint ? "Context usage. Smart zone hint is enabled in Settings." : "Context usage")

                    Button {
                        isConfirmingCompaction = true
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(width: 24, height: 24)
                            .appGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .help("Compact context")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .alert("Compact context?", isPresented: $isConfirmingCompaction) {
                Button("Cancel", role: .cancel) {}
                Button("Compact") { onCompact() }
            } message: {
                Text("Pi will summarize older conversation history to free context. This keeps the session usable for longer prompts.")
            }
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

private struct PiAgentSmartZoneContextBar: View {
    let percent: Double
    let showsSmartZoneHint: Bool
    let width: CGFloat
    let height: CGFloat

    private var clampedPercent: Double {
        min(max(percent, 0), 100)
    }

    private var warningThreshold: Double {
        showsSmartZoneHint ? 40 : 70
    }

    private var usageFill: AnyShapeStyle {
        if clampedPercent >= 90 {
            return AnyShapeStyle(Color.red.gradient)
        }
        if clampedPercent >= warningThreshold {
            return AnyShapeStyle(Color.orange.gradient)
        }
        return AnyShapeStyle(AppTheme.brandAccent.gradient)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(AppTheme.contentFill.opacity(0.75))

            Capsule(style: .continuous)
                .fill(usageFill)
                .frame(width: width * clampedPercent / 100)

            if showsSmartZoneHint {
                PiAgentSmartZoneDottedMarker()
                    .stroke(Color.primary.opacity(0.72), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3]))
                    .frame(width: 1.5, height: height)
                    .position(x: width * 0.4, y: height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule(style: .continuous))
        .accessibilityLabel(showsSmartZoneHint ? "Context usage with smart zone marker" : "Context usage")
        .accessibilityValue("\(Int(clampedPercent)) percent")
    }
}

private struct PiAgentSmartZoneDottedMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct PiAgentModelStatus: View {
    let session: PiAgentSessionRecord

    var body: some View {
        HStack(spacing: 6) {
            modelIcon
            Text(modelLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(AppTheme.Font.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .appGlassCapsule()
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           ProviderLogo.assetName(for: provider) != nil {
            ProviderLogoImage(provider: provider, size: 16)
        } else {
            Image(systemName: "cpu")
        }
    }

    private var modelLabel: String {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           let model = session.modelOverrideID ?? session.model {
            return "\(provider)/\(model)"
        }
        return "Pi default model"
    }
}

struct PiAgentThinkingStatus: View {
    let level: String?

    var body: some View {
        Label("Thinking: \(displayLevel)", systemImage: "brain.head.profile")
            .font(AppTheme.Font.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .appGlassCapsule()
    }

    private var displayLevel: String {
        guard let level, !level.isEmpty else { return "default" }
        return (level == "none" ? "off" : level).capitalized
    }
}

struct PiAgentShortcutChip: View {
    let symbol: String
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(key)
                .font(AppTheme.Font.caption2.monospaced().weight(.bold))
            Text(label)
                .fontWidth(.condensed)
        }
        .font(AppTheme.Font.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .appGlassCapsule()
    }
}

/// Aggregate token/cost across the orchestration session and its subagents.
/// Tokens always sum (counts exist for every source); cost sums only the known
/// values — a subagent whose runtime never reported cost contributes nothing and
/// shows as `—` in the breakdown rather than skewing the total. Built off the
/// body hot path in `PiAgentComposerBox` (see `recomputeCostAggregate`).
struct PiAgentRuntimeCostAggregate: Equatable {
    struct Source: Equatable, Identifiable {
        let id: UUID
        let label: String
        let model: String?
        let totalTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheTokens: Int?
        let inputCost: Double?
        let outputCost: Double?
        let cacheCost: Double?
        let cost: Double?
        let isOrchestration: Bool

        var hasTokenBreakdown: Bool {
            inputTokens != nil || outputTokens != nil || cacheTokens != nil
        }

        var hasCompleteTokenBreakdown: Bool {
            inputTokens != nil && outputTokens != nil
        }
    }

    var totalTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheTokens: Int?
    var inputCost: Double?
    var outputCost: Double?
    var cacheCost: Double?
    var totalCost: Double?
    var sources: [Source]
    var hasSubagents: Bool

    static func build(session: PiAgentSessionRecord, runs: [PiSubagentRunRecord]) -> PiAgentRuntimeCostAggregate {
        var sources: [Source] = []
        var inputCost: Double?
        var outputCost: Double?
        var cacheCost: Double?
        var totalCost: Double?
        func addKnown(_ value: Double?, to total: inout Double?) { if let value { total = (total ?? 0) + value } }
        func addCosts(_ breakdown: PiAgentUsageCostBreakdown?, total: Double?) {
            addKnown(breakdown?.input, to: &inputCost)
            addKnown(breakdown?.output, to: &outputCost)
            addKnown(breakdown?.cache, to: &cacheCost)
            addKnown(total ?? breakdown?.resolvedTotal, to: &totalCost)
        }

        let parentCacheTokens = Self.cacheTokenTotal(read: session.cacheReadTokens, write: session.cacheWriteTokens)
        let parentSource = Source(
            id: session.id,
            label: "main chat",
            model: session.model,
            totalTokens: Self.totalTokens(reported: session.totalTokens, input: session.inputTokens, output: session.outputTokens, cache: parentCacheTokens),
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            cacheTokens: parentCacheTokens,
            inputCost: session.costBreakdown?.input,
            outputCost: session.costBreakdown?.output,
            cacheCost: session.costBreakdown?.cache,
            cost: session.cost ?? session.costBreakdown?.resolvedTotal,
            isOrchestration: true
        )
        sources.append(parentSource)
        addCosts(session.costBreakdown, total: session.cost)

        var subagentCount = 0
        for run in runs {
            let children: [PiSubagentChildRecord] = run.children ?? run.child.map { [$0] } ?? []
            for child in children {
                let childCacheTokens = Self.cacheTokenTotal(read: child.cacheReadTokens, write: child.cacheWriteTokens)
                let childSource = Source(
                    id: child.id,
                    label: child.agentName,
                    model: child.model,
                    totalTokens: Self.totalTokens(reported: child.totalTokens, input: child.inputTokens, output: child.outputTokens, cache: childCacheTokens),
                    inputTokens: child.inputTokens,
                    outputTokens: child.outputTokens,
                    cacheTokens: childCacheTokens,
                    inputCost: child.costBreakdown?.input,
                    outputCost: child.costBreakdown?.output,
                    cacheCost: child.costBreakdown?.cache,
                    cost: child.cost ?? child.costBreakdown?.resolvedTotal,
                    isOrchestration: false
                )
                sources.append(childSource)
                addCosts(child.costBreakdown, total: child.cost)
                subagentCount += 1
            }
        }
        let aggregateComponents = Self.aggregateComponentsIfComplete(sources)
        return .init(
            totalTokens: Self.aggregateTotalIfComplete(sources),
            inputTokens: aggregateComponents?.input,
            outputTokens: aggregateComponents?.output,
            cacheTokens: aggregateComponents?.cache,
            inputCost: inputCost,
            outputCost: outputCost,
            cacheCost: cacheCost,
            totalCost: totalCost,
            sources: sources,
            hasSubagents: subagentCount > 0
        )
    }

    private static func cacheTokenTotal(read: Int?, write: Int?) -> Int? {
        guard read != nil || write != nil else { return nil }
        return (read ?? 0) + (write ?? 0)
    }

    private static func totalTokens(reported: Int?, input: Int?, output: Int?, cache: Int?) -> Int? {
        if let reported { return reported }
        guard let input, let output else { return nil }
        return input + output + (cache ?? 0)
    }

    private static func aggregateTotalIfComplete(_ sources: [Source]) -> Int? {
        guard sources.allSatisfy({ $0.totalTokens != nil }) else { return nil }
        return sources.reduce(0) { $0 + ($1.totalTokens ?? 0) }
    }

    private static func aggregateComponentsIfComplete(_ sources: [Source]) -> (input: Int, output: Int, cache: Int?)? {
        guard sources.allSatisfy(\.hasCompleteTokenBreakdown) else { return nil }
        let hasAnyCache = sources.contains { $0.cacheTokens != nil }
        guard !hasAnyCache || sources.allSatisfy({ $0.cacheTokens != nil }) else { return nil }
        return (
            input: sources.reduce(0) { $0 + ($1.inputTokens ?? 0) },
            output: sources.reduce(0) { $0 + ($1.outputTokens ?? 0) },
            cache: hasAnyCache ? sources.reduce(0) { $0 + ($1.cacheTokens ?? 0) } : nil
        )
    }
}

struct PiAgentRuntimeFooter: View {
    let session: PiAgentSessionRecord
    var aggregate: PiAgentRuntimeCostAggregate? = nil
    let openAIFastStatus: Bool?
    let onToggleOpenAIFast: (() -> Void)?
    let onSetAsDefault: (() -> Void)?
    @State private var isCostBreakdownPresented = false

    var body: some View {
        HStack(spacing: 7) {
            aggregateChips
            if let openAIFastStatus {
                metricButton(
                    "fast: \(openAIFastStatus ? "on" : "off")",
                    icon: openAIFastStatus ? "bolt.fill" : "bolt.slash",
                    action: { onToggleOpenAIFast?() }
                )
                .disabled(onToggleOpenAIFast == nil)
            }
            if let onSetAsDefault {
                metricButton(
                    "Set as default",
                    icon: "pin",
                    action: onSetAsDefault
                )
            }
        }
        .font(AppTheme.Font.caption)
        .foregroundStyle(AppTheme.mutedText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.18), value: openAIFastStatus)
    }

    /// Token + cost metrics showing the aggregate (orchestration + subagents).
    /// The pair is always tappable once there's something to show, opening the
    /// per-source breakdown — with no subagents that's just the main-chat line.
    @ViewBuilder
    private var aggregateChips: some View {
        let display = footerTokenDisplay
        let hasDisplayedTokens = display.input != nil || display.output != nil || display.cache != nil || display.total != nil
        let cost = aggregate?.totalCost ?? session.cost ?? session.costBreakdown?.resolvedTotal
        let tappable = aggregate != nil && (hasDisplayedTokens || cost != nil)
        let chips = HStack(spacing: 7) {
            if let inputTokens = display.input {
                metric("\(compact(inputTokens)) in", icon: "arrow.up.circle")
            }
            if let outputTokens = display.output {
                metric("\(compact(outputTokens)) out", icon: "arrow.down.circle")
            }
            if let cacheTokens = display.cache {
                metric("\(compact(cacheTokens)) cache", icon: "externaldrive")
            }
            if let totalTokens = display.total {
                metric("\(compact(totalTokens)) tokens", icon: "tugriksign.circle")
            }
            if let cost {
                metric(String(format: "$%.2f", cost), icon: "dollarsign.circle")
            }
        }
        if tappable, let aggregate {
            chips
                .contentShape(Rectangle())
                .onTapGesture { isCostBreakdownPresented.toggle() }
                .popover(isPresented: $isCostBreakdownPresented, arrowEdge: .bottom) {
                    PiAgentCostBreakdownPopover(aggregate: aggregate)
                }
                .help("Show token & cost breakdown")
        } else {
            chips
        }
    }

    private var footerTokenDisplay: (input: Int?, output: Int?, cache: Int?, total: Int?) {
        if let aggregate {
            if aggregate.inputTokens != nil && aggregate.outputTokens != nil {
                return (aggregate.inputTokens, aggregate.outputTokens, aggregate.cacheTokens, nil)
            }
            return (nil, nil, nil, aggregate.totalTokens)
        }

        let cacheTokens = Self.cacheTokenTotal(read: session.cacheReadTokens, write: session.cacheWriteTokens)
        if session.inputTokens != nil && session.outputTokens != nil {
            return (session.inputTokens, session.outputTokens, cacheTokens, nil)
        }
        if let totalTokens = session.totalTokens {
            return (nil, nil, nil, totalTokens)
        }
        return (session.inputTokens, session.outputTokens, cacheTokens, nil)
    }

    private func metric(_ text: String, icon: String) -> some View {
        // Icon and text must share the same font size: the row inherits
        // `AppTheme.Font.caption`, so a smaller `caption2` icon centered against
        // caption text leaves the baseline-positioned glyph sitting high. Matching
        // the size makes center alignment exact (no manual offsets).
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(AppTheme.Font.caption.weight(.semibold))
                .contentTransition(.opacity)
            Text(text)
                .contentTransition(.opacity)
        }
        .lineLimit(1)
    }

    private func metricButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            metric(text, icon: icon)
                .foregroundStyle(AppTheme.brandAccent)
        }
        .buttonStyle(.plain)
        .help("Toggle \(text.split(separator: ":").first.map(String.init) ?? text)")
    }

    private static func cacheTokenTotal(read: Int?, write: Int?) -> Int? {
        guard read != nil || write != nil else { return nil }
        return (read ?? 0) + (write ?? 0)
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

/// Per-source token & cost breakdown opened from the footer's aggregate chips.
/// Uses the shared popover chrome (header + rows + total). With no subagents it
/// shows just the main-chat line. Sources whose cost wasn't reported show `—`
/// and are excluded from the total.
struct PiAgentCostBreakdownPopover: View {
    private struct CategoryMetric: Hashable {
        let title: String
        let tokens: Int?
        let cost: Double?
    }

    private struct DisplaySource: Identifiable {
        let id: String
        let label: String
        let model: String?
        let totalTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheTokens: Int?
        let inputCost: Double?
        let outputCost: Double?
        let cacheCost: Double?
        let cost: Double?

        var hasTokenBreakdown: Bool {
            inputTokens != nil || outputTokens != nil || cacheTokens != nil
        }
    }

    let aggregate: PiAgentRuntimeCostAggregate

    private static let tokenColumnWidth: CGFloat = 132
    private static let costColumnWidth: CGFloat = 78
    private static let columnSpacing: CGFloat = 10

    private var displaySources: [DisplaySource] {
        var rows: [DisplaySource] = []
        rows.append(contentsOf: aggregate.sources.filter(\.isOrchestration).map(displaySource))

        var groupedSubagents: [String: [PiAgentRuntimeCostAggregate.Source]] = [:]
        var orderedSubagentKeys: [String] = []
        for source in aggregate.sources where !source.isOrchestration {
            let key = "\(source.label)\u{1F}\(source.model ?? "")"
            if groupedSubagents[key] == nil { orderedSubagentKeys.append(key) }
            groupedSubagents[key, default: []].append(source)
        }
        rows.append(contentsOf: orderedSubagentKeys.compactMap { key in
            groupedSubagents[key].map(mergedDisplaySource)
        })
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            costPopoverHeader
            Divider()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(displaySources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Divider().opacity(0.55) }
                        row(for: source)
                    }
                }
                .padding(.horizontal, AppTheme.Popover.footerHInset)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)

            // A single main-chat source makes the total redundant with its row.
            if displaySources.count > 1 {
                AppPopoverFooter {
                    HStack(spacing: Self.columnSpacing) {
                        Text("Total")
                            .font(AppTheme.Font.caption.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        rowTotalTokensText(aggregate.totalTokens)
                        rowTotalCostText(aggregate.totalCost)
                    }
                }
            }
        }
        .frame(width: AppTheme.Popover.wideWidth)
        .foregroundStyle(.primary)
    }

    private func displaySource(_ source: PiAgentRuntimeCostAggregate.Source) -> DisplaySource {
        DisplaySource(
            id: source.id.uuidString,
            label: source.label,
            model: source.model,
            totalTokens: source.totalTokens,
            inputTokens: source.inputTokens,
            outputTokens: source.outputTokens,
            cacheTokens: source.cacheTokens,
            inputCost: source.inputCost,
            outputCost: source.outputCost,
            cacheCost: source.cacheCost,
            cost: source.cost
        )
    }

    private func mergedDisplaySource(_ sources: [PiAgentRuntimeCostAggregate.Source]) -> DisplaySource {
        let first = sources[0]
        return DisplaySource(
            id: "subagent:\(first.label):\(first.model ?? "")",
            label: first.label,
            model: first.model,
            totalTokens: sumKnown(sources.map(\.totalTokens)),
            inputTokens: sumKnown(sources.map(\.inputTokens)),
            outputTokens: sumKnown(sources.map(\.outputTokens)),
            cacheTokens: sumKnown(sources.map(\.cacheTokens)),
            inputCost: sumKnown(sources.map(\.inputCost)),
            outputCost: sumKnown(sources.map(\.outputCost)),
            cacheCost: sumKnown(sources.map(\.cacheCost)),
            cost: sumKnown(sources.map(\.cost))
        )
    }

    private func sumKnown(_ values: [Int?]) -> Int? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }

    private func sumKnown(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }

    private func row(for source: DisplaySource) -> some View {
        let metrics = categoryMetrics(for: source)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: Self.columnSpacing) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.label)
                        .font(AppTheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let model = source.model, !model.isEmpty {
                        Text(model)
                            .font(AppTheme.Font.caption2.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                rowTotalTokensText(source.totalTokens)
                rowTotalCostText(source.cost)
            }

            if !metrics.isEmpty {
                metricTable(metrics)
            }
        }
        .padding(.vertical, 8)
    }

    private var costPopoverHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
            Text("Token cost")
                .font(AppTheme.Popover.titleFont)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Tokens")
                .frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text("Cost")
                .frame(width: Self.costColumnWidth, alignment: .trailing)
        }
        .font(AppTheme.Font.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, AppTheme.Popover.headerHInset)
        .padding(.top, AppTheme.Popover.headerTopInset)
        .padding(.bottom, AppTheme.Popover.headerBottomInset)
    }

    private func metricTable(_ metrics: [CategoryMetric]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element) { index, metric in
                metricLine(metric)
                if index < metrics.count - 1 { Divider().opacity(0.35) }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous)
                .fill(AppTheme.contentSubtleFill.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous)
                .stroke(AppTheme.hairlineStroke.opacity(0.8), lineWidth: 1)
        )
    }

    private func metricLine(_ metric: CategoryMetric) -> some View {
        HStack(spacing: Self.columnSpacing) {
            Text(metric.title)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            Text(tokenString(metric.tokens))
                .font(AppTheme.Font.caption.monospacedDigit())
                .foregroundStyle(metric.tokens == nil ? AppTheme.mutedText : .primary)
                .frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text(categoryCostString(metric.cost))
                .font(AppTheme.Font.caption.monospacedDigit())
                .foregroundStyle(metric.cost == nil ? AppTheme.mutedText : .primary)
                .frame(width: Self.costColumnWidth, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.vertical, 6)
    }

    private func categoryMetrics(for source: DisplaySource) -> [CategoryMetric] {
        let hasCategoryData = source.hasTokenBreakdown || source.inputCost != nil || source.outputCost != nil || source.cacheCost != nil
        if hasCategoryData {
            var metrics = [
                CategoryMetric(title: "Input", tokens: source.inputTokens, cost: source.inputCost),
                CategoryMetric(title: "Output", tokens: source.outputTokens, cost: source.outputCost)
            ]
            if source.cacheTokens != nil || source.cacheCost != nil {
                metrics.append(CategoryMetric(title: "Cache", tokens: source.cacheTokens, cost: source.cacheCost))
            }
            return metrics
        }

        if source.totalTokens != nil || source.cost != nil {
            return [CategoryMetric(title: "Tokens", tokens: source.totalTokens, cost: source.cost)]
        }
        return []
    }

    private func rowTotalTokensText(_ tokens: Int?) -> some View {
        Text(tokens.map { "\(compactTokenCount($0)) tokens" } ?? "— tokens")
            .font(AppTheme.Font.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(tokens == nil ? AppTheme.mutedText : .primary)
            .frame(width: Self.tokenColumnWidth, alignment: .trailing)
    }

    private func rowTotalCostText(_ cost: Double?) -> some View {
        Text(cost.map { String(format: "$%.2f", $0) } ?? "—")
            .font(AppTheme.Font.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(cost == nil ? AppTheme.mutedText : .primary)
            .frame(width: Self.costColumnWidth, alignment: .trailing)
    }


    private func tokenString(_ tokens: Int?) -> String {
        tokens.map(compactTokenCount) ?? "—"
    }

    private func compactTokenCount(_ value: Int) -> String {
        let absoluteValue = abs(value)
        let sign = value < 0 ? "-" : ""
        let units: [(threshold: Int, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1_000, 1_000, "k")
        ]
        guard let unit = units.first(where: { absoluteValue >= $0.threshold }) else {
            return value.formatted()
        }

        let scaled = Double(absoluteValue) / unit.divisor
        let roundedToTenth = (scaled * 10).rounded() / 10
        if roundedToTenth.rounded() == roundedToTenth {
            return "\(sign)\(Int(roundedToTenth))\(unit.suffix)"
        }
        return "\(sign)\(String(format: "%.1f", roundedToTenth))\(unit.suffix)"
    }

    private func categoryCostString(_ cost: Double?) -> String {
        cost.map { String(format: "$%.2f", $0) } ?? "—"
    }
}

struct PiAgentModelPicker: View {
    let session: PiAgentSessionRecord
    let fallbackModels: [AvailableModel]
    let disabledModelIdentifiers: Set<String>
    let defaultModel: AvailableModel?
    let isRunning: Bool
    let onRefresh: () -> Void
    let onCycle: () -> Void
    let onSelect: (PiAgentModelSelection?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                modelIcon
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
            .appGlassCapsule()
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // .top so the popover deterministically opens above the composer chip
        // (the composer sits at the window bottom; .bottom only looked right
        // when AppKit happened to flip it).
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                AppPopoverHeader(title: "Model") {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                }

                Divider()

                ScrollView(showsIndicators: false) {
                    let groups = groupedModelOptions
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groups, id: \.provider) { group in
                            // Provider sections use the resources-popover header
                            // treatment: label over a hairline, clear air between
                            // groups so the list doesn't read as one long run.
                            VStack(alignment: .leading, spacing: 6) {
                                ProviderLabel(provider: group.provider, logoSize: 14, spacing: 5)
                                    .font(AppTheme.Font.caption.weight(.bold))
                                    .fontWidth(.expanded)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, AppTheme.Popover.rowHInset)

                                // Inset to the row content width so it reads as
                                // part of the section, not an edge-to-edge rule.
                                Divider()
                                    .padding(.horizontal, AppTheme.Popover.rowHInset)

                                VStack(spacing: 2) {
                                    ForEach(group.models) { model in
                                        PiAgentModelOptionRow(
                                            model: model,
                                            isSelected: model.provider == resolvedProvider && model.id == resolvedModelID,
                                            subtitle: modelMetadataSubtitle(model)
                                        ) {
                                            onSelect(.init(provider: model.provider, modelID: model.id))
                                            isPresented = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppTheme.Popover.listInset)
                    .padding(.vertical, AppTheme.Popover.listInset)
                }
                .frame(maxHeight: AppTheme.Popover.listMaxHeight)
            }
            .frame(width: AppTheme.Popover.standardWidth)
            .foregroundStyle(.primary)
        }
        .help(isRunning ? "Change this Pi session's model" : "Choose a model for this session before launch")
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let provider = resolvedProvider,
           ProviderLogo.assetName(for: provider) != nil {
            ProviderLogoImage(provider: provider, size: 16)
        } else {
            Image(systemName: "cpu")
        }
    }

    private var modelOptions: [PiAgentModelOption] {
        return fallbackModels.map { model in
            PiAgentModelOption(
                provider: model.provider,
                id: model.model,
                name: nil,
                contextWindow: PiAgentContextEstimateBuilder.parseTokenCount(model.contextWindow),
                maxOutput: model.maxOutput.flatMap { PiAgentContextEstimateBuilder.parseTokenCount($0) },
                supportsThinking: model.supportsThinking,
                supportedThinkingLevels: model.supportedThinkingLevels,
                supportsImages: model.supportsImages
            )
        }
    }

    private var groupedModelOptions: [(provider: String, models: [PiAgentModelOption])] {
        Dictionary(grouping: modelOptions, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private func modelMetadataSubtitle(_ model: PiAgentModelOption) -> String {
        var parts: [String] = []
        if let contextWindow = model.contextWindow { parts.append("\(compactModelNumber(contextWindow)) context") }
        // Dash (not omission) for unknown max output, matching the catalog UI.
        let outputPart = model.maxOutput.map { compactModelNumber($0) } ?? "—"
        parts.append("\(outputPart) output")
        return parts.joined(separator: ", ")
    }

    private func compactModelNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }

    private var isUsingPiDefault: Bool { session.modelOverrideProvider == nil && session.modelOverrideID == nil }
    private var effectiveProvider: String? { session.modelOverrideProvider ?? session.modelProvider }
    private var effectiveModelID: String? { session.modelOverrideID ?? session.model }
    private var resolvedProvider: String? { effectiveProvider ?? defaultModel?.provider }
    private var resolvedModelID: String? { effectiveModelID ?? defaultModel?.model }

    private var modelLabel: String {
        if let provider = resolvedProvider, let model = resolvedModelID {
            return "\(provider)/\(model)"
        }
        return "Model"
    }
}

struct PiAgentThinkingPicker: View {
    let level: String?
    let supportedLevels: [String]
    let defaultLevel: String
    let isRunning: Bool
    let onCycle: () -> Void
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var optimisticLevel: String?

    private var isLoadingLevels: Bool { supportedLevels.isEmpty }
    private var levels: [String] { supportedLevels }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text("Thinking: \(displayLevel.capitalized)")
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .appGlassCapsule()
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // .top so it opens above the composer like the model picker does.
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AppPopoverContainer(width: AppTheme.Popover.compactWidth, title: "Thinking") {
                if isLoadingLevels {
                    HStack(spacing: 10) {
                        AppSpinner()
                            .controlSize(.small)
                        Text("Loading")
                            .font(AppTheme.Popover.emptyBodyFont)
                            .foregroundStyle(AppTheme.mutedText)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, AppTheme.Popover.headerHInset)
                    .padding(.vertical, 10)
                } else {
                    AppPopoverScrollList {
                        ForEach(levels, id: \.self) { candidate in
                            PiAgentThinkingLevelRow(
                                level: candidate,
                                isSelected: candidate == resolvedLevel
                            ) {
                                optimisticLevel = candidate
                                onSelect(candidate)
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
        .help(isRunning ? "Change thinking level" : "Choose thinking level for this session before launch")
        .onChange(of: normalizedLevel) { _, _ in
            optimisticLevel = nil
        }
        .onChange(of: defaultLevel) { _, _ in
            optimisticLevel = nil
        }
        .onChange(of: supportedLevels) { _, _ in
            optimisticLevel = nil
        }
    }


    private var normalizedLevel: String? {
        guard let level else { return nil }
        return level == "none" ? "off" : level
    }

    private var resolvedLevel: String {
        optimisticLevel ?? normalizedLevel ?? defaultLevel
    }

    private var displayLevel: String {
        if isLoadingLevels {
            return resolvedLevel.isEmpty ? "loading" : resolvedLevel
        }
        return levels.contains(resolvedLevel) ? resolvedLevel : "\(resolvedLevel) unavailable"
    }
}

/// Model picker row: id + "272K context, 128K output" subtitle, capability
/// glyphs at the trailing edge (brain.head.profile = thinking, photo = image
/// input — plain `brain` is the Memory symbol, don't reuse it here), and the
/// standard accent checkmark for the active model. Mirrors `AppPopoverTextRow`
/// chrome; exists only to host the trailing glyph slot.
private struct PiAgentModelOptionRow: View {
    let model: PiAgentModelOption
    let isSelected: Bool
    let subtitle: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.id)
                            .font(AppTheme.Popover.itemTitleFont)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isSelected {
                            AppPopoverSelectionMark()
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AppTheme.Popover.itemSubtitleFont)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if model.supportsThinking != false {
                        Image(systemName: "brain.head.profile")
                            .help("Supports thinking")
                            .accessibilityLabel("Supports thinking")
                    }
                    if model.supportsImages == true {
                        Image(systemName: "photo")
                            .help("Supports image input")
                            .accessibilityLabel("Supports image input")
                    }
                }
                .imageScale(.small)
                .foregroundStyle(AppTheme.mutedText)
            }
            // The active model keeps full strength; the alternatives recede
            // until hovered, so the list scans as "current + options".
            .opacity(isSelected || isHovering ? 1 : 0.55)
            .contentShape(Rectangle())
            .padding(.horizontal, AppTheme.Popover.rowHInset)
            .padding(.vertical, AppTheme.Popover.rowVInset)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous)
                    .fill(isSelected ? AppTheme.selectionFill : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Thinking level row: level name + a five-dot intensity gauge (filled dots =
/// how hard the model thinks) + the standard accent checkmark. The checkmark
/// slot is always reserved so the dot gauges align in a scannable column.
private struct PiAgentThinkingLevelRow: View {
    let level: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private static let intensityByLevel: [String: Int] = [
        "off": 0, "minimal": 1, "low": 2, "medium": 3, "high": 4, "xhigh": 5
    ]
    private static let maxIntensity = 5

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(level.capitalized)
                        .font(AppTheme.Popover.itemTitleFont)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if isSelected {
                        AppPopoverSelectionMark()
                    }
                }
                Spacer(minLength: 8)
                if let intensity = Self.intensityByLevel[level] {
                    HStack(spacing: 3) {
                        ForEach(0..<Self.maxIntensity, id: \.self) { index in
                            Circle()
                                .fill(index < intensity ? AnyShapeStyle(AppTheme.brandAccent) : AnyShapeStyle(AppTheme.mutedText.opacity(0.28)))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            // Same treatment as the model rows: current choice full strength,
            // alternatives recede until hovered.
            .opacity(isSelected || isHovering ? 1 : 0.55)
            .contentShape(Rectangle())
            .padding(.horizontal, AppTheme.Popover.rowHInset)
            .padding(.vertical, AppTheme.Popover.rowVInset)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous)
                    .fill(isSelected ? AppTheme.selectionFill : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
