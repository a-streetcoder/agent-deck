import AppKit
import SwiftUI

struct PiAgentInspectorPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var isNativeSubagentRunSheetPresented = false
    @State private var nativeSubagentAgentName = ""
    @State private var nativeSubagentTask = ""
    @State private var nativeSubagentUseWorktreeIsolation = false
    @State private var nativeSubagentAllowDirectProjectWrites = false
    @State private var nativeSubagentExpectedOutcome: PiSubagentExpectedOutcome = .reportOnly
    @State private var nativeSubagentRequestedOutputPath = ""
    @State private var nativeSubagentAllowOverwrite = false
    @State private var nativeSubagentReadFirstPaths = ""

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
                        AppLabelTag(text: "#\(issue)", color: .purple)
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
                        if let last = store.selectedTranscript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                let isRunning = viewModel.isPiAgentSessionRunning(session.id)
                let isCompacting = session.isCompacting
                PiAgentComposerBox(
                    text: $composerText,
                    images: $composerImages,
                    files: $composerFiles,
                    attachmentError: $composerAttachmentError,
                    inputMode: $inputMode,
                    isRunning: isRunning,
                    isDisabled: isCompacting,
                    placeholder: isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Message Pi…"),
                    canSend: !isCompacting && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty),
                    path: session.worktreePath ?? session.projectPath,
                    onFiles: { urls in
                        let attachments = urls.compactMap { PiAgentFileAttachment(url: $0) }
                        for attachment in attachments where !composerFiles.contains(where: { $0.url == attachment.url }) {
                            composerFiles.append(attachment)
                        }
                    },
                    subagentNames: runnableSubagentNames(for: session),
                    subagentsEnabled: session.subagentsEnabled,
                    subagentsEnabledForNewSessions: viewModel.areSubagentsEnabledForNewSessions,
                    onSetSessionSubagentsEnabled: viewModel.setSubagentsEnabledForSelectedSession,
                    onSetNewSessionSubagentsEnabled: viewModel.setSubagentsEnabledForNewSessions,
                    onSelectSubagent: presentNativeSubagentRun,
                    viewModel: viewModel,
                    footerSession: session,
                    transcript: store.selectedTranscript,
                    supportedThinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh"],
                    metricsSession: session,
                    onSend: {
                        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty else { return }
                        guard !isCompacting else { return }
                        let filePayload = composerFiles.compactMap { file -> String? in
                            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { return nil }
                            return "<file name=\"\(file.url.path)\">\n\(content)\n</file>"
                        }.joined(separator: "\n")
                        if !composerFiles.isEmpty && filePayload.isEmpty {
                            composerAttachmentError = "Only images and UTF-8 text files are supported."
                            return
                        }
                        let combined = [message, filePayload].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, images: composerImages)
                        composerText = ""
                        composerImages = []
                        composerFiles = []
                        composerAttachmentError = nil
                    },
                    onStop: { viewModel.stopSelectedPiAgentSession() },
                    onClear: {
                        composerText = ""
                        composerImages = []
                        composerFiles = []
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
        .sheet(isPresented: $isNativeSubagentRunSheetPresented) {
            PiNativeSubagentRunSheet(
                agentNames: store.selectedSession.map { runnableSubagentNames(for: $0) } ?? [],
                agentInfos: nativeSubagentSheetInfos,
                selectedAgentName: $nativeSubagentAgentName,
                task: $nativeSubagentTask,
                useWorktreeIsolation: $nativeSubagentUseWorktreeIsolation,
                allowDirectProjectWrites: $nativeSubagentAllowDirectProjectWrites,
                expectedOutcome: $nativeSubagentExpectedOutcome,
                requestedOutputPath: $nativeSubagentRequestedOutputPath,
                allowOverwrite: $nativeSubagentAllowOverwrite,
                readFirstPathsText: $nativeSubagentReadFirstPaths,
                projectRootPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                onCancel: { isNativeSubagentRunSheetPresented = false },
                onRun: { agentName, task, useWorktreeIsolation, allowDirectProjectWrites, expectedOutcome, requestedOutputPath, allowOverwrite, readFirstPaths in
                    viewModel.runNativeSubagent(agentName: agentName, task: task, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths)
                    if composerText.trimmingCharacters(in: .whitespacesAndNewlines) == task.trimmingCharacters(in: .whitespacesAndNewlines) {
                        composerText = ""
                    }
                    isNativeSubagentRunSheetPresented = false
                }
            )
        }
    }

    private func runnableSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        guard session.subagentsEnabled else { return [] }
        let snapshot = viewModel.startupSnapshot(forProjectPath: session.projectPath)
        return snapshot.effectiveAgents
            .filter { $0.resolved.disabled != true }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var nativeSubagentSheetInfos: [String: PiNativeSubagentRunSheet.AgentInfo] {
        guard let session = store.selectedSession else { return [:] }
        let snapshot = viewModel.startupSnapshot(forProjectPath: session.projectPath)
        return Dictionary(uniqueKeysWithValues: snapshot.effectiveAgents.map { agent in
            (agent.name, PiNativeSubagentRunSheet.AgentInfo(agent: agent))
        })
    }

    private func presentNativeSubagentRun(for agentName: String) {
        nativeSubagentAgentName = agentName
        nativeSubagentTask = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        isNativeSubagentRunSheetPresented = true
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
                Image(systemName: icon)
                    .foregroundStyle(color)
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

    private var icon: String {
        switch entry.role {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
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
