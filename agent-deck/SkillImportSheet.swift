import AppKit
import SwiftUI

/// The "Import Skills" sheet.
///
/// Two source modes feed one shared candidate list:
/// - **Local Folder** — recursively scans a chosen folder for `SKILL.md` roots
///   and registers the selected roots in place (files are not moved).
/// - **Git / skills.sh** — resolves a GitHub / skills.sh URL, clones the repo
///   blobless + sparse into app-managed storage, and sparse-checks-out only the
///   selected skills (and the reference files nested inside them).
struct SkillImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case localFolder
        case gitRepository

        var id: String { rawValue }

        var label: String {
            switch self {
            case .localFolder: return "Local Folder"
            case .gitRepository: return "Git / skills.sh"
            }
        }
    }

    var viewModel: AppViewModel
    @Binding var isPresented: Bool
    var onImported: (SkillImportResult) -> Void

    @State private var mode: Mode = .localFolder

    // Shared candidate list state.
    @State private var searchText = ""
    @State private var selectedIDs: Set<String> = []
    @State private var importErrorMessage: String?
    @State private var isImporting = false
    /// SKILL.md paths already in the catalog, captured once on appear so the
    /// per-render hide check stays a pure Set lookup. See `displayCandidates`.
    @State private var catalogedSkillFilePaths: Set<String> = []
    /// Per-row AI-summary state. Keyed by `DisplayCandidate.id` so it survives
    /// search/filter changes but resets when the source mode changes.
    @State private var summariesByID: [String: SummaryState] = [:]
    @State private var hoveredCandidateID: String?

    enum SummaryState: Equatable {
        case loading
        case ready(String)
        case failed(String)
    }

    // Local folder mode.
    @State private var localSourceURL: URL?
    @State private var localCandidates: [ExternalSkillCandidate] = []
    @State private var isScanningLocal = false
    @State private var localScanProgress: ExternalSkillDiscovery.Progress?
    @State private var localScanTask: Task<Void, Never>?

    // Git repository mode.
    @State private var gitURLInput = ""
    @State private var isFetchingRemote = false
    @State private var remoteFetchPhase = ""
    @State private var remoteContext: RemoteSkillImportContext?
    @State private var remoteFetchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 740)
        .task { catalogedSkillFilePaths = viewModel.catalogedSkillFilePaths }
        .onChange(of: mode) { _, _ in
            importErrorMessage = nil
            searchText = ""
            selectedIDs = []
            summariesByID = [:]
            hoveredCandidateID = nil
        }
        .onDisappear {
            localScanTask?.cancel()
            remoteFetchTask?.cancel()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Skills")
                .font(.headline)
                .fontWidth(.expanded)
            Text("Add skills from a local folder or a GitHub / skills.sh repository.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(18)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Source", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .appSegmentedPicker()
            .labelsHidden()

            AppCard(title: mode == .localFolder ? "Source Folder" : "Repository") {
                switch mode {
                case .localFolder: localSourceCard
                case .gitRepository: gitSourceCard
                }
            }

            AppCard(title: "Skills") {
                VStack(alignment: .leading, spacing: 12) {
                    skillsCardHeader
                    skillsCardBody
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            if let importErrorMessage {
                Label(importErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { cancelAndDismiss() }
                .appSecondaryButton()
                .keyboardShortcut(.cancelAction)
            Button {
                performImport()
            } label: {
                if isImporting {
                    AppSpinner().controlSize(.small)
                } else {
                    Text("Import")
                }
            }
            .appPrimaryButton()
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
        .padding(16)
    }

    // MARK: - Local source card

    private var localSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localSourceURL?.path ?? "No folder selected")
                .textSelection(.enabled)
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.mutedText)
            Button(localSourceURL == nil ? "Choose Folder" : "Choose Different Folder") {
                DispatchQueue.main.async { chooseLocalFolder() }
            }
        }
    }

    // MARK: - Git source card

    private var gitSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(AppTheme.mutedText)
                    TextField("Paste a GitHub or skills.sh URL", text: $gitURLInput)
                        .textFieldStyle(.plain)
                        .onSubmit { fetchRemoteSkills() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.contentStroke.opacity(0.8), lineWidth: 1)
                )

                Button("Fetch Skills") { fetchRemoteSkills() }
                    .appPrimaryButton()
                    .disabled(gitURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetchingRemote)
            }

            if let remoteContext, !isFetchingRemote {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("\(remoteContext.source.displayName) · \(remoteContext.resolvedRef) · \(remoteContext.candidates.count) skill\(remoteContext.candidates.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    if remoteContext.existingRepository != nil {
                        Text("Already synced — adds to it")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }

            Text("Examples: github.com/owner/repo · owner/repo · skills.sh/owner/repo/skill")
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    // MARK: - Skills card

    private var skillsCardHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(skillsCardHint)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer()
            Button(selectionButtonTitle) {
                if allVisibleImportableSelected {
                    selectedIDs.subtract(visibleImportableIDs)
                } else {
                    selectedIDs.formUnion(visibleImportableIDs)
                }
            }
            .appSecondaryButton()
            .disabled(isBusy || visibleImportableIDs.isEmpty)

            Button("Clear") { selectedIDs.removeAll() }
                .appSecondaryButton()
                .disabled(isBusy || selectedIDs.isEmpty)
        }
    }

    private var skillsCardHint: String {
        switch mode {
        case .localFolder:
            return "Select skill roots to add to the catalog. Files stay in place and are passed to Pi by path."
        case .gitRepository:
            return "Select skills to sparse-check-out. Reference files inside each skill folder are synced with it."
        }
    }

    @ViewBuilder
    private var skillsCardBody: some View {
        switch mode {
        case .localFolder:
            if isScanningLocal {
                localScanningView
            } else if localSourceURL == nil {
                localPlaceholderView
            } else {
                candidateListView
            }
        case .gitRepository:
            if isFetchingRemote {
                remoteFetchingView
            } else if remoteContext == nil {
                remotePlaceholderView
            } else {
                candidateListView
            }
        }
    }

    private var localScanningView: some View {
        VStack(spacing: 12) {
            AppSpinner().controlSize(.regular)
            VStack(spacing: 4) {
                Text("Scanning \(localSourceURL?.lastPathComponent ?? "folder") for skills…")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if let progress = localScanProgress {
                    Text("\(progress.directoriesScanned) folder\(progress.directoriesScanned == 1 ? "" : "s") scanned • \(progress.skillsFound) skill\(progress.skillsFound == 1 ? "" : "s") found")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var remoteFetchingView: some View {
        VStack(spacing: 12) {
            AppSpinner().controlSize(.regular)
            Text(remoteFetchPhase.isEmpty ? "Fetching repository…" : remoteFetchPhase)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var remotePlaceholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30))
                .foregroundStyle(AppTheme.mutedText)
            Text("Paste a repository URL above and choose Fetch Skills.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var localPlaceholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 30))
                .foregroundStyle(AppTheme.mutedText)
            Text("Choose a folder above to scan it for skills.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    @ViewBuilder
    private var candidateListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.mutedText)
                TextField("Search skills by name, description, or path", text: $searchText)
                    .textFieldStyle(.plain)
                    .appBrandTint()
                if isSearchActive {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear skill search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.contentStroke.opacity(0.8), lineWidth: 1)
            )

            Text(candidateCountSummary)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredCandidates.isEmpty {
                        Text(isSearchActive
                             ? "No importable skills match your search."
                             : "No new importable skills were found. Skills already in your catalog are hidden.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(filteredCandidates) { candidate in
                        candidateRow(candidate)
                        if candidate.id != filteredCandidates.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: DisplayCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(
                get: { selectedIDs.contains(candidate.id) },
                set: { isSelected in
                    if isSelected { selectedIDs.insert(candidate.id) }
                    else { selectedIDs.remove(candidate.id) }
                }
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(candidate.name)
                            .font(.body.weight(.semibold))
                        if let badge = candidate.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    if let description = candidate.description {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Description")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                    }

                    summaryBlock(for: candidate)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.detailLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppTheme.mutedText)
                        Text(candidate.detailValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 10)
            }
            .appCheckbox()

            if viewModel.skillDescriptionGenerationModel() != nil {
                magicButton(for: candidate)
                    .padding(.top, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCandidateID = hovering ? candidate.id : nil
        }
    }

    @ViewBuilder
    private func summaryBlock(for candidate: DisplayCandidate) -> some View {
        if let state = summariesByID[candidate.id] {
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Summarising with AI…")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            case let .ready(text):
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(AppTheme.brandAccent)
                        Text("AI summary")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .font(.caption2.weight(.semibold))
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func magicButton(for candidate: DisplayCandidate) -> some View {
        let state = summariesByID[candidate.id]
        let isVisible = hoveredCandidateID == candidate.id || state != nil
        AppCircleIconButton(
            style: .soft,
            tint: AppTheme.brandAccent,
            size: 28,
            imageScale: .medium,
            help: magicButtonHelpText(for: state),
            action: { Task { await requestSummary(for: candidate) } }
        ) {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "arrow.clockwise")
            default:
                Image(systemName: "sparkles")
            }
        }
        .disabled(state == .loading)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
    }

    private func magicButtonHelpText(for state: SummaryState?) -> String {
        switch state {
        case .loading: return "Generating summary…"
        case .failed: return "Retry AI summary"
        case .ready: return "Regenerate AI summary"
        case .none: return "Summarise this skill with AI"
        }
    }

    private func requestSummary(for candidate: DisplayCandidate) async {
        summariesByID[candidate.id] = .loading
        do {
            let content = try await readSkillContent(for: candidate)
            let summary = try await viewModel.generateSkillDescription(skillContent: content)
            summariesByID[candidate.id] = .ready(summary)
        } catch {
            summariesByID[candidate.id] = .failed(error.localizedDescription)
        }
    }

    private func readSkillContent(for candidate: DisplayCandidate) async throws -> String {
        switch mode {
        case .localFolder:
            guard let match = localCandidates.first(where: { $0.sourceRootPath == candidate.id }) else {
                throw SkillSummaryError.skillNotFound
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: match.skillFilePath))
            return String(decoding: data, as: UTF8.self)
        case .gitRepository:
            guard let remoteContext,
                  let match = remoteContext.candidates.first(where: { $0.id == candidate.id }) else {
                throw SkillSummaryError.skillNotFound
            }
            return try await viewModel.readRemoteSkillFile(directory: match.repoRelativeDirectory, inCloneAt: remoteContext.clonePath)
        }
    }

    private enum SkillSummaryError: LocalizedError {
        case skillNotFound

        var errorDescription: String? {
            switch self {
            case .skillNotFound: return "Could not locate the SKILL.md for this candidate."
            }
        }
    }

    // MARK: - Candidate model

    private struct DisplayCandidate: Identifiable, Hashable {
        let id: String
        let name: String
        let description: String?
        let detailLabel: String
        let detailValue: String
        let badge: String?
        let alreadyImported: Bool
    }

    private var displayCandidates: [DisplayCandidate] {
        switch mode {
        case .localFolder:
            return localCandidates.map { candidate in
                let skillPath = URL(fileURLWithPath: candidate.skillFilePath).standardizedFileURL.path
                return DisplayCandidate(
                    id: candidate.sourceRootPath,
                    name: candidate.name,
                    description: candidate.description,
                    detailLabel: "Path",
                    detailValue: candidate.sourceRootPath,
                    badge: nil,
                    alreadyImported: catalogedSkillFilePaths.contains(skillPath)
                )
            }
        case .gitRepository:
            guard let remoteContext else { return [] }
            return remoteContext.candidates.map { candidate in
                DisplayCandidate(
                    id: candidate.id,
                    name: candidate.name,
                    description: candidate.description,
                    detailLabel: candidate.isWholeRepository ? "Location" : "Folder",
                    detailValue: candidate.isWholeRepository ? "Repository root" : candidate.repoRelativeDirectory,
                    badge: candidate.referenceFileCount > 0
                        ? "\(candidate.referenceFileCount) reference file\(candidate.referenceFileCount == 1 ? "" : "s")"
                        : nil,
                    alreadyImported: remoteContext.alreadySyncedDirectories.contains(candidate.repoRelativeDirectory)
                )
            }
        }
    }

    private var importableCandidates: [DisplayCandidate] {
        displayCandidates.filter { !$0.alreadyImported }
    }

    private var hiddenAlreadyImportedCount: Int {
        displayCandidates.count - importableCandidates.count
    }

    private var filteredCandidates: [DisplayCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return importableCandidates }
        return importableCandidates
            .compactMap { candidate -> (DisplayCandidate, Int)? in
                guard let score = searchScore(candidate, query: query) else { return nil }
                return (candidate, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    private var visibleImportableIDs: Set<String> {
        Set(filteredCandidates.map(\.id))
    }

    private var allVisibleImportableSelected: Bool {
        !visibleImportableIDs.isEmpty && visibleImportableIDs.isSubset(of: selectedIDs)
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectionButtonTitle: String {
        if isSearchActive {
            return allVisibleImportableSelected ? "Deselect Visible" : "Select Visible"
        }
        return allVisibleImportableSelected ? "Deselect All" : "Select All"
    }

    private var candidateCountSummary: String {
        var parts = ["Showing \(filteredCandidates.count) of \(importableCandidates.count) importable skill\(importableCandidates.count == 1 ? "" : "s")"]
        if hiddenAlreadyImportedCount > 0 {
            parts.append("\(hiddenAlreadyImportedCount) already in catalog hidden")
        }
        if !selectedIDs.isEmpty {
            parts.append("\(selectedIDs.count) selected")
        }
        return parts.joined(separator: " • ")
    }

    private var isBusy: Bool {
        isScanningLocal || isFetchingRemote || isImporting
    }

    private var canImport: Bool {
        guard !isBusy else { return false }
        return !selectedIDs.isEmpty
    }

    // MARK: - Local folder actions

    private func chooseLocalFolder() {
        viewModel.chooseExternalSkillsDirectory(startingAt: localSourceURL) { url in
            guard let url else { return }
            startLocalScan(at: url)
        }
    }

    private func startLocalScan(at url: URL) {
        localScanTask?.cancel()
        importErrorMessage = nil
        searchText = ""
        localSourceURL = url
        localCandidates = []
        selectedIDs = []
        localScanProgress = nil
        isScanningLocal = true

        localScanTask = Task {
            for await event in ExternalSkillDiscovery.scan(root: url) {
                if Task.isCancelled { break }
                switch event {
                case let .progress(progress):
                    localScanProgress = progress
                case let .finished(candidates):
                    applyLocalCandidates(candidates)
                }
            }
        }
    }

    private func applyLocalCandidates(_ candidates: [ExternalSkillCandidate]) {
        isScanningLocal = false
        localScanProgress = nil
        localCandidates = candidates

        guard !candidates.isEmpty else {
            selectedIDs = []
            importErrorMessage = "No importable skill folders were found. Choose a skill root containing SKILL.md, or a folder that contains skill roots below it."
            return
        }
        // Pre-select only skills that are not already in the catalog.
        selectedIDs = Set(importableCandidates.map(\.id))
    }

    // MARK: - Git repository actions

    private func fetchRemoteSkills() {
        let input = gitURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isFetchingRemote else { return }

        remoteFetchTask?.cancel()
        importErrorMessage = nil
        if let previous = remoteContext {
            viewModel.discardDiscoveryClone(previous)
        }
        remoteContext = nil
        selectedIDs = []
        searchText = ""
        isFetchingRemote = true
        remoteFetchPhase = "Cloning repository…"

        remoteFetchTask = Task {
            do {
                let context = try await viewModel.prepareRemoteSkillImport(from: input) { completed, total in
                    Task { @MainActor in
                        guard isFetchingRemote else { return }
                        remoteFetchPhase = total > 0 ? "Reading skills… \(completed)/\(total)" : "Reading skills…"
                    }
                }
                if Task.isCancelled {
                    viewModel.discardDiscoveryClone(context)
                    return
                }
                isFetchingRemote = false
                remoteContext = context
                if context.candidates.isEmpty {
                    importErrorMessage = "No skills with a SKILL.md were found in \(context.source.displayName)."
                } else {
                    applyRemoteSelection(context)
                }
            } catch {
                if Task.isCancelled { return }
                isFetchingRemote = false
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyRemoteSelection(_ context: RemoteSkillImportContext) {
        let importable = context.candidates.filter {
            !context.alreadySyncedDirectories.contains($0.repoRelativeDirectory)
        }
        if let slug = context.source.preselectedSkillSlug,
           let match = importable.first(where: { matches($0, slug: slug) }) {
            selectedIDs = [match.id]
        } else {
            selectedIDs = Set(importable.map(\.id))
        }
    }

    private func matches(_ candidate: RemoteSkillCandidate, slug: String) -> Bool {
        let directory = candidate.repoRelativeDirectory
        let lastComponent = (directory as NSString).lastPathComponent
        return directory.caseInsensitiveCompare(slug) == .orderedSame
            || lastComponent.caseInsensitiveCompare(slug) == .orderedSame
            || candidate.name.caseInsensitiveCompare(slug) == .orderedSame
    }

    // MARK: - Import

    private func performImport() {
        guard !selectedIDs.isEmpty else { return }
        importErrorMessage = nil

        switch mode {
        case .localFolder:
            let selected = localCandidates.filter { selectedIDs.contains($0.sourceRootPath) }
            guard !selected.isEmpty else { return }
            do {
                let result = try viewModel.importExternalSkills(selected)
                finish(result)
            } catch {
                importErrorMessage = error.localizedDescription
            }

        case .gitRepository:
            guard let context = remoteContext else { return }
            let selected = context.candidates.filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            isImporting = true
            Task {
                do {
                    let result = try await viewModel.importRemoteSkills(context: context, selectedCandidates: selected)
                    isImporting = false
                    finish(result)
                } catch {
                    isImporting = false
                    importErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func finish(_ result: SkillImportResult) {
        // Discard a fetched-but-unused discovery clone — e.g. the user fetched
        // a repo, then imported from a local folder instead. Safe for a clone
        // that was actually imported from: it is now a referenced repository.
        if let remoteContext {
            viewModel.discardDiscoveryClone(remoteContext)
        }
        isPresented = false
        onImported(result)
    }

    private func cancelAndDismiss() {
        localScanTask?.cancel()
        remoteFetchTask?.cancel()
        if let remoteContext {
            viewModel.discardDiscoveryClone(remoteContext)
        }
        isPresented = false
    }

    // MARK: - Search scoring

    private func searchScore(_ candidate: DisplayCandidate, query: String) -> Int? {
        let queryTokens = searchTokens(query)
        guard !queryTokens.isEmpty else { return 0 }

        let name = normalizedSearchText(candidate.name)
        let description = normalizedSearchText(candidate.description ?? "")
        let detail = normalizedSearchText(candidate.detailValue)
        let compactName = compactSearchText(candidate.name)
        let compactQuery = compactSearchText(query)
        let searchable = [name, description, detail].joined(separator: " ")

        guard queryTokens.allSatisfy({ token in
            searchable.contains(token) || compactName.contains(token) || compactName.contains(compactSearchText(token))
        }) else {
            return nil
        }

        var score = 0
        if name == normalizedSearchText(query) { score += 120 }
        if compactName == compactQuery { score += 110 }
        if name.hasPrefix(normalizedSearchText(query)) || compactName.hasPrefix(compactQuery) { score += 80 }

        for token in queryTokens {
            if name.split(separator: " ").contains(Substring(token)) { score += 30 }
            else if name.contains(token) || compactName.contains(token) { score += 20 }
            else if description.contains(token) { score += 10 }
            else if detail.contains(token) { score += 4 }
        }
        return score
    }

    private func searchTokens(_ text: String) -> [String] {
        normalizedSearchText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !["skill", "skills", "native", "claude", "code"].contains($0) }
    }

    private func normalizedSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactSearchText(_ text: String) -> String {
        normalizedSearchText(text).replacingOccurrences(of: " ", with: "")
    }
}
