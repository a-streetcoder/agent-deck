import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .prompt
    @State private var sessionSearchText = ""
    @State private var selectedSessionTitleDraft = ""
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerAttachmentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, AppTheme.pagePadding)
                .padding(.bottom, 16)

            Divider()

            HStack(spacing: 0) {
                sessionsColumn
                    .frame(width: 360)

                Divider()

                activeSessionColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: syncSelectedSessionTitleDraft)
        .onChange(of: store.selectedSession?.id) { _ in syncSelectedSessionTitleDraft() }
        .onChange(of: store.selectedSession?.title) { _ in syncSelectedSessionTitleDraft() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pi Agent")
                    .font(.system(size: 34, weight: .bold, design: .default))
                    .fontWidth(.expanded)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var subtitle: String {
        if let session = store.selectedSession {
            return "\(session.displayTitle) · \(session.projectName)"
        }
        return "Choose a project or issue session, then send a message to launch or resume Pi."
    }

    private var visibleSessions: [PiAgentSessionRecord] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(store.sessions.prefix(10)) }
        return store.sessions.filter { sessionMatchesSearch($0, query: query) }
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sessions")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("\(store.sessions.count) saved · \(runningCount) active")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                PiAgentAddSessionButton {
                    viewModel.createPiAgentDraftForSelectedProject()
                }
                .disabled(viewModel.selectedDiscoveredProject == nil)
                .help(viewModel.selectedDiscoveredProject == nil ? "Select a project first" : "New Pi Agent session")
            }
            .padding(18)

            if store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedText)
                    Text("No sessions yet")
                        .font(.headline)
                    Text("Use + to create a draft, or Open from a GitHub issue.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .padding(18)
                Spacer()
            } else {
                VStack(spacing: 10) {
                    PiAgentSessionSearchField(text: $sessionSearchText)
                        .padding(.horizontal, 14)

                    if visibleSessions.isEmpty {
                        ContentUnavailableView("No sessions found", systemImage: "magnifyingglass", description: Text("Try another search."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleSessions) { session in
                                    PiAgentSessionRow(
                                        session: session,
                                        project: viewModel.discoveredProjects.first(where: { $0.path == session.projectPath }),
                                        isSelected: store.selectedSession?.id == session.id,
                                        isRunning: viewModel.isPiAgentSessionRunning(session.id),
                                        onRename: { viewModel.renamePiAgentSession(session.id, title: $0) },
                                        onDelete: { viewModel.deletePiAgentSession(session.id) }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.selectPiAgentSession(session.id)
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            viewModel.deletePiAgentSession(session.id)
                                        } label: {
                                            Label("Delete Session", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 18)
                        }
                    }
                }
            }
        }
        .background(AppTheme.subtleFill)
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            sessionHeader
                .padding(18)

            Divider()

            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)

            Divider()

            composer
                .padding(18)
        }
    }

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            AppLabelTag(text: session.kind.rawValue, color: session.kind == .issue ? .purple : .blue)
                            AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                            if let repository = session.repository {
                                AppLabelTag(text: repository, color: .secondary)
                            }
                        }
                        TextField("Session name", text: $selectedSessionTitleDraft)
                            .textFieldStyle(.plain)
                            .font(.title2.bold())
                            .fontWidth(.expanded)
                            .lineLimit(2)
                            .onSubmit(commitSelectedSessionRename)
                            .onDisappear(perform: commitSelectedSessionRename)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button("Resume") { viewModel.resumeSelectedPiAgentSession() }
                            .disabled(viewModel.isPiAgentSessionRunning(session.id))
                        Button("Stop") { viewModel.stopSelectedPiAgentSession() }
                            .keyboardShortcut(.escape, modifiers: [])
                            .disabled(!viewModel.isPiAgentSessionRunning(session.id))
                        Button("Repo Changes") { viewModel.openRepoChangesForSelectedPiAgentSession() }
                    }
                }

                HStack(spacing: 10) {
                    PiAgentModelPicker(
                        session: session,
                        fallbackModels: viewModel.availableModels,
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
                        isRunning: viewModel.isPiAgentSessionRunning(session.id),
                        onCycle: { viewModel.cyclePiAgentThinkingLevelForSelectedSession() },
                        onSelect: { viewModel.setPiAgentThinkingLevelForSelectedSession($0) }
                    )
                    Spacer()
                }

                HStack(spacing: 16) {
                    Label(session.projectPath, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.piSessionFile == nil ? "Draft · not launched" : "Pi session saved")
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(AppTheme.mutedText)
                }
                .font(.footnote)

                if let error = session.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: "No Session Selected") {
                Text("Select a session from the left, or create a new draft for the selected project.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var transcript: some View {
        Group {
            if store.selectedTranscript.isEmpty {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let session = store.selectedSession {
                            PiAgentStartupResourcesCard(viewModel: viewModel, session: session)
                        }
                        AppRowCard {
                            HStack(spacing: 12) {
                                Image(systemName: "text.bubble")
                                    .font(.title2)
                                    .foregroundStyle(AppTheme.mutedText)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("No transcript yet")
                                        .font(.headline)
                                    Text("Send a message below to launch Pi Agent for this session.")
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let session = store.selectedSession {
                                PiAgentStartupResourcesCard(viewModel: viewModel, session: session)
                            }
                            ForEach(visibleTranscriptEntries) { entry in
                                PiAgentTranscriptCard(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: store.selectedTranscript.count) { _ in
                        if let last = store.selectedTranscript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = store.selectedSession, !viewModel.isPiAgentSessionRunning(session.id) {
                Text(session.piSessionFile == nil ? "Send launches this draft." : "Send resumes this session.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedText)
            }

            PiAgentComposerBox(
                text: $composerText,
                images: $composerImages,
                attachmentError: $composerAttachmentError,
                placeholder: "Ask Pi to implement, inspect, explain, or fix…",
                canSend: store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty),
                onSend: sendComposerMessage
            )
        }
    }

    private func sendComposerMessage() {
        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !composerImages.isEmpty else { return }
        viewModel.sendPiAgentMessage(message, mode: .prompt, images: composerImages)
        composerText = ""
        composerImages = []
        composerAttachmentError = nil
    }

    private var visibleTranscriptEntries: [PiAgentTranscriptEntry] {
        store.selectedTranscript.filter { entry in
            switch entry.role {
            case .raw: return false
            case .status: return false
            default: return true
            }
        }
    }

    private var runningCount: Int {
        store.sessions.filter { viewModel.isPiAgentSessionRunning($0.id) }.count
    }

    private func syncSelectedSessionTitleDraft() {
        selectedSessionTitleDraft = store.selectedSession?.displayTitle ?? ""
    }

    private func commitSelectedSessionRename() {
        guard let session = store.selectedSession else { return }
        let trimmedTitle = selectedSessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            selectedSessionTitleDraft = session.displayTitle
        } else if trimmedTitle != session.title {
            viewModel.renamePiAgentSession(session.id, title: trimmedTitle)
        }
    }

    private func sessionMatchesSearch(_ session: PiAgentSessionRecord, query: String) -> Bool {
        let haystack = [
            session.title,
            session.projectName,
            session.projectPath,
            session.repository ?? "",
            session.issueNumber.map(String.init) ?? "",
            session.lastSummary ?? "",
            (store.transcriptsBySessionID[session.id] ?? []).map { "\($0.title) \($0.text)" }.joined(separator: " ")
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func effectiveStatus(for session: PiAgentSessionRecord) -> String {
        viewModel.isPiAgentSessionRunning(session.id) ? "Active" : session.status.rawValue
    }

    private func effectiveStatusColor(for session: PiAgentSessionRecord) -> Color {
        if viewModel.isPiAgentSessionRunning(session.id) { return .green }
        switch session.status {
        case .running, .starting: return .orange
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}

private struct PiAgentStartupResourcesCard: View {
    @ObservedObject var viewModel: AppViewModel
    let session: PiAgentSessionRecord

    private let chipColumns = [GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading)]

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 16) {
                header

                Text("Loaded for this Pi session. You can reference these directly in your prompt, just like the terminal startup view.")
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedText)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        resourceSection("Context", count: contextItems.count, icon: "doc.text", color: .blue, items: contextItems)
                        resourceSection("Environment", count: envItems.count, icon: "key", color: .green, items: envItems)
                    }
                    resourceSection("Skills", count: skillItems.count, icon: "wand.and.stars", color: .purple, items: skillItems)
                    resourceSection("Prompts", count: promptItems.count, icon: "text.badge.star", color: .indigo, items: promptItems)
                    resourceSection("Extensions", count: extensionItems.count, icon: "puzzlepiece.extension", color: .orange, items: extensionItems)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("pi")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(Color.accentColor)
                .padding(9)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Pi startup resources")
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                HStack(spacing: 6) {
                    hintChip("Esc", "interrupt")
                    hintChip("⌘↩", "send")
                    hintChip("/", "commands")
                    hintChip("!", "bash")
                }
            }
            Spacer()
        }
    }

    private var contextItems: [String] {
        var items: [String] = []
        let agents = URL(fileURLWithPath: session.projectPath).appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: agents.path) { items.append("AGENTS.md") }
        return items.isEmpty ? ["No AGENTS.md detected"] : items
    }

    private var skillItems: [String] {
        viewModel.snapshot.skills.map(\.name).sorted()
    }

    private var promptItems: [String] {
        let commands = viewModel.snapshot.commands.map(\.invocation)
        let prompts = viewModel.snapshot.promptTemplates.map(\.invocation)
        return Array(Set(commands + prompts)).sorted()
    }

    private var extensionItems: [String] {
        Array(Set(viewModel.snapshot.settings.flatMap(\.packages))).sorted().map(shortExtensionName)
    }

    private var envItems: [String] {
        viewModel.snapshot.envKeys.map { env in
            let scope = env.source.kind.rawValue.lowercased()
            if let value = env.value, !value.isEmpty {
                return "\(env.key) = \(masked(value)) · \(scope)"
            }
            return "\(env.key) · \(scope)"
        }
    }

    private func resourceSection(_ title: String, count: Int, icon: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
            }

            LazyVGrid(columns: chipColumns, alignment: .leading, spacing: 7) {
                ForEach(items, id: \.self) { item in
                    resourceChip(item)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.subtleFill.opacity(0.65))
                .stroke(AppTheme.cardStroke.opacity(0.8), lineWidth: 1)
        )
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(AppTheme.subtleFill))
    }

    private func resourceChip(_ text: String, isOverflow: Bool = false) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(isOverflow ? Color.accentColor : AppTheme.mutedText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOverflow ? Color.accentColor.opacity(0.10) : AppTheme.cardFill.opacity(0.75))
            )
            .textSelection(.enabled)
    }

    private func shortExtensionName(_ value: String) -> String {
        if value.hasPrefix("npm:") { return String(value.dropFirst(4)) }
        if value.contains("/") { return URL(fileURLWithPath: value).lastPathComponent }
        return value
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else { return "••••" }
        return String(value.prefix(4)) + "••••"
    }
}

private struct PiAgentComposerBox: View {
    private let maxImages = 8
    private let maxImageBytes = 10 * 1024 * 1024

    @Binding var text: String
    @Binding var images: [PiAgentImageAttachment]
    @Binding var attachmentError: String?
    let placeholder: String
    let canSend: Bool
    let onSend: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images) { image in
                            PiAgentImageAttachmentThumbnail(image: image) {
                                images.removeAll { $0.id == image.id }
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
                        .font(.body)
                        .foregroundStyle(AppTheme.mutedText.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .textEditorStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(minHeight: 92, maxHeight: 132)
                    .background(Color.clear)
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                Button(action: attachImagesFromOpenPanel) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(AppTheme.subtleFill))
                }
                .buttonStyle(.plain)
                .help("Attach images")

                Text("Paste or drop images · ⌘↩ send · Esc stop")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                Spacer()
                PiAgentSendButton(canSend: canSend, action: onSend)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.cardFill)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.7) : AppTheme.cardStroke, lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 7)
        .onPasteCommand(of: [.png, .jpeg, .tiff, .gif, .webP, .fileURL]) { _ in
            addImages(PiAgentComposerImageLoader.imagesFromPasteboard())
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isDropTargeted) { providers in
            PiAgentComposerImageLoader.loadImages(from: providers) { loaded in
                addImages(loaded)
            }
            return true
        }
    }

    private func attachImagesFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        addImages(panel.urls.compactMap { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) })
    }

    private func addImages(_ newImages: [PiAgentImageAttachment]) {
        guard !newImages.isEmpty else { return }
        attachmentError = nil
        var next = images
        for image in newImages {
            if image.sizeBytes > maxImageBytes {
                attachmentError = "\(image.name) is larger than 10 MB."
                continue
            }
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

private struct PiAgentImageAttachmentThumbnail: View {
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .help("\(image.name) · \(ByteCountFormatter.string(fromByteCount: Int64(image.sizeBytes), countStyle: .file))")
    }
}

private enum PiAgentComposerImageLoader {
    nonisolated static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [PiAgentImageAttachment] {
        var attachments: [PiAgentImageAttachment] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            attachments.append(contentsOf: urls.compactMap(imageAttachment(fromFileURL:)))
        }
        if let data = pasteboard.data(forType: .png), let attachment = imageAttachment(data: data, name: "pasted-image.png", mimeType: "image/png") {
            attachments.append(attachment)
        } else if let data = pasteboard.data(forType: .tiff), let pngData = pngData(fromImageData: data), let attachment = imageAttachment(data: pngData, name: "pasted-image.png", mimeType: "image/png") {
            attachments.append(attachment)
        }
        return attachments
    }

    nonisolated static func loadImages(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var attachments: [PiAgentImageAttachment] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url, let attachment = imageAttachment(fromFileURL: url) {
                        lock.lock(); attachments.append(attachment); lock.unlock()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let png = pngData(fromImageData: data) ?? data
                    if let attachment = imageAttachment(data: png, name: "dropped-image.png", mimeType: "image/png") {
                        lock.lock(); attachments.append(attachment); lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            completion(attachments)
        }
    }

    nonisolated static func imageAttachment(fromFileURL url: URL) -> PiAgentImageAttachment? {
        guard let mimeType = mimeType(for: url), let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return imageAttachment(data: data, name: url.lastPathComponent, mimeType: mimeType)
    }

    nonisolated static func imageAttachment(data: Data, name: String, mimeType: String) -> PiAgentImageAttachment? {
        PiAgentImageAttachment(name: name, mimeType: mimeType, data: data.base64EncodedString(), sizeBytes: data.count)
    }

    nonisolated static func previewImage(for attachment: PiAgentImageAttachment) -> NSImage? {
        guard let data = Data(base64Encoded: attachment.data) else { return nil }
        return NSImage(data: data)
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }

    nonisolated private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct PiAgentSendButton: View {
    let canSend: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(canSend ? Color.accentColor : AppTheme.mutedText.opacity(0.28))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help("Send message")
    }
}

private struct PiAgentModelSelection {
    let provider: String
    let modelID: String
}

private struct PiAgentModelPicker: View {
    let session: PiAgentSessionRecord
    let fallbackModels: [AvailableModel]
    let isRunning: Bool
    let onRefresh: () -> Void
    let onCycle: () -> Void
    let onSelect: (PiAgentModelSelection?) -> Void

    var body: some View {
        Menu {
            Button("Pi Default") { onSelect(nil) }
            if !modelOptions.isEmpty {
                Divider()
                ForEach(modelOptions) { model in
                    Button {
                        onSelect(.init(provider: model.provider, modelID: model.id))
                    } label: {
                        HStack {
                            Text("\(model.displayName) · \(model.provider)")
                            if model.provider == effectiveProvider && model.id == effectiveModelID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Cycle Model") { onCycle() }
            Button("Refresh Models") { onRefresh() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(modelLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(AppTheme.subtleFill).stroke(AppTheme.cardStroke, lineWidth: 1))
        }
        .menuStyle(.button)
        .help(isRunning ? "Change this Pi session's model" : "Choose a model override for this session before launch")
    }

    private var modelOptions: [PiAgentModelOption] {
        if let models = session.availableModels, !models.isEmpty { return models }
        return fallbackModels.map { model in
            PiAgentModelOption(provider: model.provider, id: model.model, name: nil, contextWindow: Int(model.contextWindow))
        }
    }

    private var effectiveProvider: String? { session.modelOverrideProvider ?? session.modelProvider }
    private var effectiveModelID: String? { session.modelOverrideID ?? session.model }

    private var modelLabel: String {
        if let override = session.modelOverrideID {
            return override
        }
        if let model = session.model {
            return model
        }
        return "Pi Default"
    }
}

private struct PiAgentThinkingPicker: View {
    let level: String?
    let isRunning: Bool
    let onCycle: () -> Void
    let onSelect: (String) -> Void

    private let levels = ["off", "minimal", "low", "medium", "high", "xhigh"]

    var body: some View {
        Menu {
            ForEach(levels, id: \.self) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    HStack {
                        Text(candidate.capitalized)
                        if candidate == normalizedLevel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Cycle Thinking") { onCycle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text("Thinking: \((level ?? "default").capitalized)")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(AppTheme.subtleFill).stroke(AppTheme.cardStroke, lineWidth: 1))
        }
        .menuStyle(.button)
        .help(isRunning ? "Change thinking level" : "Choose thinking level for this session before launch")
    }

    private var normalizedLevel: String? {
        guard let level else { return nil }
        return level == "none" ? "off" : level
    }
}

private struct PiAgentSessionSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField("Search all sessions", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.cardFill)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

private struct PiAgentAddSessionButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isEnabled ? .white : AppTheme.mutedText.opacity(0.55))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isEnabled ? Color.accentColor : AppTheme.cardStroke.opacity(0.45))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct PiAgentSessionRow: View {
    let session: PiAgentSessionRecord
    let project: DiscoveredProject?
    let isSelected: Bool
    let isRunning: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var draftTitle = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PiAgentProjectIcon(project: project, session: session)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(isRunning ? .green : statusColor)
                        .frame(width: 8, height: 8)
                    TextField("Session name", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .lineLimit(2)
                        .onSubmit(commitRename)
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Delete session")
                }

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)

                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : AppTheme.cardFill)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : AppTheme.cardStroke, lineWidth: 1)
        )
        .help(statusHelp)
        .onAppear { draftTitle = sessionTitle }
        .onChange(of: session.id) { _ in draftTitle = sessionTitle }
        .onChange(of: session.title) { _ in draftTitle = sessionTitle }
        .onDisappear(perform: commitRename)
    }

    private func commitRename() {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            draftTitle = sessionTitle
        } else if trimmedTitle != session.title {
            onRename(trimmedTitle)
        }
    }

    private var sessionTitle: String {
        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.issueNumber.map { "#\($0)" } ?? "Project agent"
        }
        return session.displayTitle
    }

    private var subtitle: String {
        if let repository = session.repository, let issueNumber = session.issueNumber {
            return "\(repository) #\(issueNumber) · \(session.projectName)"
        }
        if let repository = session.repository {
            return "\(repository) · \(session.projectName)"
        }
        return session.projectName
    }

    private var statusHelp: String {
        if isRunning { return "Active" }
        return session.status.rawValue
    }

    private var statusColor: Color {
        switch session.status {
        case .running, .starting: return .green
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}

private struct PiAgentProjectIcon: View {
    let project: DiscoveredProject?
    let session: PiAgentSessionRecord

    var body: some View {
        Group {
            if let url = project?.iconFileURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .overlay {
                Image(session.kind == .issue ? "github" : "pi")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(Color.accentColor)
            }
    }
}

private struct PiAgentTranscriptCard: View {
    let entry: PiAgentTranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(headerTitle)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(headerColor)
                Spacer(minLength: 8)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }

            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(entry.role == .assistant ? 0.35 : 0.55))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let subagentSummary = PiAgentSubagentSummary(entry: entry) {
            PiAgentSubagentTranscriptView(summary: subagentSummary)
        } else if entry.role == .thinking {
            DisclosureGroup("Reasoning", isExpanded: .constant(false)) {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if entry.role == .assistant || entry.role == .user || entry.role == .status {
            MarkdownTextView(source: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerTitle: String {
        switch entry.role {
        case .user: return "You"
        case .assistant: return "Pi"
        default: return entry.title
        }
    }

    private var headerColor: Color {
        entry.role == .user ? Color.accentColor : .primary
    }

    private var backgroundColor: Color {
        switch entry.role {
        case .user: return Color.accentColor.opacity(0.08)
        case .assistant: return AppTheme.cardFill
        case .thinking: return Color.indigo.opacity(0.07)
        case .tool: return Color.orange.opacity(0.08)
        case .status: return AppTheme.subtleFill.opacity(0.7)
        case .error: return Color.red.opacity(0.08)
        case .stderr: return Color.pink.opacity(0.08)
        case .raw: return AppTheme.subtleFill
        }
    }

    private var strokeColor: Color {
        switch entry.role {
        case .user: return Color.accentColor.opacity(0.2)
        case .assistant: return AppTheme.cardStroke
        case .thinking: return Color.indigo.opacity(0.18)
        case .tool: return Color.orange.opacity(0.2)
        case .error: return Color.red.opacity(0.22)
        case .stderr: return Color.pink.opacity(0.2)
        case .status, .raw: return AppTheme.cardStroke
        }
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

struct PiAgentInspectorPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .prompt
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerAttachmentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi Agent")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text(store.selectedSession?.displayTitle ?? "No active session")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)
                }
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
                        viewModel.selectedSidebarItem = .agent
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
                            ForEach(store.selectedTranscript.suffix(80)) { entry in
                                PiAgentCompactTranscriptCard(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: store.selectedTranscript.count) { _ in
                        if let last = store.selectedTranscript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                PiAgentComposerBox(
                    text: $composerText,
                    images: $composerImages,
                    attachmentError: $composerAttachmentError,
                    placeholder: "Message Pi…",
                    canSend: !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty,
                    onSend: {
                        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !message.isEmpty || !composerImages.isEmpty else { return }
                        viewModel.sendPiAgentMessage(message, mode: .prompt, images: composerImages)
                        composerText = ""
                        composerImages = []
                        composerAttachmentError = nil
                    }
                )
            } else {
                Text("Start a project session from the sidebar project card, the Agent screen, or a GitHub issue.")
                    .foregroundStyle(AppTheme.mutedText)
                Button("Open Agent Screen") {
                    viewModel.selectedSidebarItem = .agent
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PiAgentSubagentSummary: Hashable {
    struct Agent: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var status: String
        var task: String?
        var toolCount: Int?
        var tokens: Int?
        var durationMs: Int?
        var outputPath: String?
        var sessionFile: String?
        var exitCode: Int?
    }

    var mode: String
    var total: Int
    var completed: Int
    var running: Int
    var failed: Int
    var agents: [Agent]

    init?(entry: PiAgentTranscriptEntry) {
        guard entry.role == .tool,
              entry.title.localizedCaseInsensitiveContains("subagent") || entry.text.localizedCaseInsensitiveContains("subagent")
        else { return nil }

        var root: [String: Any] = [:]
        if let raw = entry.rawJSON,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = object
        }
        let result = root["result"] as? [String: Any]
        let partial = root["partialResult"] as? [String: Any]
        let details = (result?["details"] as? [String: Any]) ?? (partial?["details"] as? [String: Any]) ?? [:]
        let results = details["results"] as? [[String: Any]] ?? []
        let progress = details["progress"] as? [[String: Any]] ?? []

        mode = (details["mode"] as? String) ?? "subagent"
        let parsedAgents = Self.parseAgents(results: results, progress: progress)
        agents = parsedAgents
        total = max(parsedAgents.count, details["total"] as? Int ?? 0)
        completed = parsedAgents.filter { $0.status == "completed" || $0.status == "ok" }.count
        running = parsedAgents.filter { $0.status == "running" || $0.status == "active" || $0.status == "starting" }.count
        failed = parsedAgents.filter { $0.status == "failed" || (($0.exitCode ?? 0) != 0 && $0.status != "running") }.count

        if root.isEmpty && parsedAgents.isEmpty {
            agents = [Agent(name: "subagent", status: "running", task: entry.text, toolCount: nil, tokens: nil, durationMs: nil, outputPath: nil, sessionFile: nil, exitCode: nil)]
            total = 1
            completed = 0
            running = 1
            failed = 0
        }
    }

    private static func parseAgents(results: [[String: Any]], progress: [[String: Any]]) -> [Agent] {
        let resultAgents = results.enumerated().map { index, result in
            makeAgent(index: index, result: result, progress: result["progress"] as? [String: Any] ?? result["progressSummary"] as? [String: Any])
        }
        if !resultAgents.isEmpty { return resultAgents }
        return progress.enumerated().map { index, progress in
            makeAgent(index: index, result: [:], progress: progress)
        }
    }

    private static func makeAgent(index: Int, result: [String: Any], progress: [String: Any]?) -> Agent {
        let status = (progress?["status"] as? String)
            ?? ((result["exitCode"] as? Int) == 0 ? "completed" : result["exitCode"] == nil ? "running" : "failed")
        let artifacts = result["artifactPaths"] as? [String: Any]
        return Agent(
            name: result["agent"] as? String ?? progress?["agent"] as? String ?? "Agent \(index + 1)",
            status: status,
            task: result["task"] as? String ?? progress?["task"] as? String,
            toolCount: progress?["toolCount"] as? Int ?? result["toolCount"] as? Int,
            tokens: progress?["tokens"] as? Int ?? result["tokens"] as? Int,
            durationMs: progress?["durationMs"] as? Int ?? result["durationMs"] as? Int,
            outputPath: artifacts?["outputPath"] as? String ?? result["output"] as? String ?? progress?["outputPath"] as? String,
            sessionFile: result["sessionFile"] as? String ?? progress?["sessionFile"] as? String,
            exitCode: result["exitCode"] as? Int
        )
    }
}

private struct PiAgentSubagentTranscriptView: View {
    let summary: PiAgentSubagentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("subagent", systemImage: "person.2.wave.2")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.headline.weight(.semibold))
                Spacer()
                if summary.running > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                metric("\(summary.completed)/\(summary.total) done", color: .green)
                if summary.running > 0 { metric("\(summary.running) running", color: .orange) }
                if summary.failed > 0 { metric("\(summary.failed) failed", color: .red) }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.agents) { agent in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: agent.status))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(color(for: agent.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                    .font(.callout.weight(.semibold))
                                Text(agentMeta(agent))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                            if let output = agent.outputPath ?? agent.sessionFile {
                                Text(output)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            } else if let task = agent.task, !task.isEmpty {
                                Text(task)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.subtleFill.opacity(0.65)))
                }
            }
        }
    }

    private var title: String {
        let count = summary.total > 0 ? " (\(summary.total))" : ""
        return "\(summary.mode)\(count)"
    }

    private func metric(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func agentMeta(_ agent: PiAgentSubagentSummary.Agent) -> String {
        [
            agent.toolCount.map { "\($0) tools" },
            agent.tokens.map { "\(formatTokens($0)) token" },
            agent.durationMs.map { formatDuration($0) }
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed", "ok": return "checkmark"
        case "failed": return "xmark"
        case "paused", "needs_attention": return "exclamationmark"
        default: return "ellipsis"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed", "ok": return .green
        case "failed": return .red
        case "paused", "needs_attention": return .orange
        default: return .cyan
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds >= 60 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds)s"
    }
}

private struct PiAgentCompactTranscriptCard: View {
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
                .fill(AppTheme.cardFill)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
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
