import AppKit
import SwiftUI

struct PiAgentInspectorPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerAttachmentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.selectedSession?.displayTitle ?? "No active session")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    viewModel.isPiAgentInspectorPresented = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
            }

            if let session = store.selectedSession {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.status.rawValue, color: session.status.isActive ? .green : .blue)
                    if let issue = session.issueNumber {
                        AppLabelTag(text: "#\(issue)", color: AppTheme.assistantAccent)
                    }
                    Spacer()
                    Button("Open Full") {
                        viewModel.openPiAgentScreen()
                    }
                    Button("Stop") {
                        viewModel.stopSelectedPiAgentSession()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!viewModel.isPiAgentSessionRunning(session.id))
                }

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(store.selectedTranscript.filter(isCompactTranscriptEntry).suffix(80)) { entry in
                                PiAgentCompactTranscriptCard(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: store.selectedTranscript.count) { _, _ in
                        Task { @MainActor in
                            await Task.yield()
                            if let last = store.selectedTranscript.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                let isRunning = viewModel.isPiAgentSessionRunning(session.id)
                let isCompacting = session.isCompacting
                PiAgentComposerBox(
                    text: $composerText,
                    pasteAttachments: $composerPasteAttachments,
                    nextPasteID: $nextComposerPasteID,
                    images: $composerImages,
                    files: $composerFiles,
                    folders: $composerFolders,
                    attachmentError: $composerAttachmentError,
                    inputMode: $inputMode,
                    isRunning: isRunning,
                    isDisabled: isCompacting,
                    placeholder: isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Message Pi…"),
                    canSend: !isCompacting && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty),
                    canCreateSession: false,
                    createSessionProjects: [],
                    path: session.worktreePath ?? session.projectPath,
                    onFiles: { urls in
                        let attachments = urls.compactMap { PiAgentFileAttachment(url: $0) }
                        for attachment in attachments where !composerFiles.contains(where: { $0.url == attachment.url }) {
                            composerFiles.append(attachment)
                        }
                    },
                    onFolders: { urls in
                        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
                        for attachment in attachments where !composerFolders.contains(where: { $0.url == attachment.url }) {
                            composerFolders.append(attachment)
                        }
                    },
                    viewModel: viewModel,
                    footerSession: session,
                    transcript: store.selectedTranscript,
                    supportedThinkingLevels: supportedThinkingLevels(for: session),
                    metricsSession: session,
                    onSend: {
                        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: composerText, attachments: composerPasteAttachments)
                        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: activePasteAttachments)
                        let message = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let transcriptMessage = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty else { return }
                        guard !isCompacting else { return }
                        let filePayload = composerFiles.map { file -> String in
                            "<file name=\"\(file.url.path)\"></file>"
                        }
                        let folderPayload = composerFolders.map { folder -> String in
                            "folder: `\(folder.url.path)`"
                        }
                        let payload = (filePayload + folderPayload).joined(separator: "\n")
                        let combined = [message, payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        let transcriptCombined = [transcriptMessage, payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, images: composerImages, pasteAttachments: activePasteAttachments)
                        composerText = ""
                        composerPasteAttachments = []
                        nextComposerPasteID = 1
                        composerImages = []
                        composerFiles = []
                        composerFolders = []
                        composerAttachmentError = nil
                    },
                    onStop: { viewModel.stopSelectedPiAgentSession() },
                    onCreateSession: {},
                    onCreateSessionForProject: { _ in },
                    onClear: {
                        composerText = ""
                        composerPasteAttachments = []
                        nextComposerPasteID = 1
                        composerImages = []
                        composerFiles = []
                        composerFolders = []
                        composerAttachmentError = nil
                    }
                )
            } else {
                Text("Start a project session from the sidebar project card, the Agent screen, or a GitHub issue.")
                    .foregroundStyle(AppTheme.mutedText)
                Button("Open Agent Screen") {
                    viewModel.openPiAgentScreen()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: store.selectedSession?.id) { _, _ in
            clearComposerInput()
        }
    }

    private func clearComposerInput() {
        composerText = ""
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = []
        composerFiles = []
        composerFolders = []
        composerAttachmentError = nil
    }

    private func supportedThinkingLevels(for session: PiAgentSessionRecord) -> [String] {
        let defaultModel = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? defaultModel?.provider
        let modelID = session.modelOverrideID ?? session.model ?? defaultModel?.model
        if let provider, let modelID {
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? [] : ["off"]) : cached.supportedThinkingLevels
            }
        }
        return []
    }

    private func isCompactTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        switch entry.role {
        case .raw:
            return false
        case .status:
            return entry.title == "Compaction" || entry.title == "Retry" || entry.title == "Stopped"
        case .tool:
            return !(entry.title == "Tool Call" && entry.text.localizedCaseInsensitiveContains("preparing tool call"))
        case .stderr:
            return !entry.text.localizedCaseInsensitiveContains("ready for input") && !entry.text.contains(";notify;Pi;")
        default:
            return true
        }
    }
}


struct PiAgentCompactTranscriptCard: View {
    let entry: PiAgentTranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                headerIcon
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                Spacer()
            }
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? .caption.monospaced() : .callout)
                .foregroundStyle(entry.role == .thinking ? AppTheme.mutedText : .primary)
                .lineLimit(entry.role == .assistant ? 8 : 5)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var headerIcon: some View {
        if entry.role == .assistant {
            Image("pi")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(AppTheme.brandAccent.gradient)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        switch entry.role {
        case .user: return "person.crop.circle"
        case .assistant: return "pi"
        case .thinking: return "brain.head.profile"
        case .tool: return "hammer"
        case .status: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .stderr: return "terminal"
        case .raw: return "curlybraces"
        }
    }

    private var color: Color {
        switch entry.role {
        case .user: return .blue
        case .assistant: return .purple
        case .thinking: return .indigo
        case .tool: return .orange
        case .status: return .secondary
        case .error: return .red
        case .stderr: return .pink
        case .raw: return .secondary
        }
    }
}
