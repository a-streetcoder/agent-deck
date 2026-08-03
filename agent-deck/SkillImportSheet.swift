import AppKit
import SwiftUI

/// The "Import Skills" sheet.
///
/// Three source modes feed one shared candidate list:
/// - **Local Folder** — recursively scans a chosen folder for `SKILL.md` roots
///   and registers the selected roots in place (files are not moved).
/// - **Claude / Codex** — scans well-known Claude and Codex skill folders
///   globally and under known projects, then registers selected
///   roots in place (files are not moved).
/// - **Git / skills.sh** — resolves a GitHub / skills.sh URL, clones the repo
///   blobless + sparse into app-managed storage, and sparse-checks-out only the
///   selected skills (and the reference files nested inside them).
struct SkillImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case localFolder
        case claudeCodex
        case gitRepository

        var id: String { rawValue }

        var label: String {
            let t = LanguageStore.shared.t
            switch self {
            case .localFolder: return t("skillImport.mode.local")
            case .claudeCodex: return t("skillImport.mode.claudeCodex")
            case .gitRepository: return t("skillImport.mode.git")
            }
        }
    }

    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @Binding var isPresented: Bool
    var onImported: (SkillImportResult) -> Void

    @State private var mode: Mode = .localFolder

    // Shared candidate list state.
    @State private var searchText = ""
    /// Cached candidate projections so scrolling/body evaluation does not
    /// rebuild display/importable lists or selection ID sets.
    @State private var displayCandidates: [DisplayCandidate] = []
    @State private var importableCandidates: [DisplayCandidate] = []
    @State private var importableCandidateIDs: Set<String> = []
    @State private var hiddenAlreadyImportedCount = 0
    /// Debounced, cached filter results so heavy search scoring does not run
    /// on every body evaluation.
    @State private var filteredCandidates: [DisplayCandidate] = []
    @State private var visibleImportableIDs: Set<String> = []
    @State private var selectedIDs: Set<String> = []
    @State private var importErrorMessage: String?
    @State private var isImporting = false
    /// SKILL.md paths already in the catalog, captured once on appear so the
    /// per-render hide check stays a pure Set lookup. See `displayCandidates`.
    @State private var catalogedSkillFilePaths: Set<String> = []
    @State private var catalogedSkillNames: Set<String> = []
    /// Per-row AI-summary state. Keyed by `DisplayCandidate.id` so it survives
    /// search/filter changes but resets when the source mode changes.
    @State private var summariesByID: [String: SummaryState] = [:]
    @State private var importAsCollection = false
    @State private var collectionName = ""
    @State private var didManuallySetImportAsCollection = false
    @State private var didEditCollectionName = false
    /// Cancellation handle for the search debounce task.
    @State private var searchDebounceTask: Task<Void, Never>?

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

    // Claude / Codex mode.
    @State private var claudeCodexCandidates: [KnownSkillCandidate] = []
    @State private var isScanningClaudeCodex = false
    @State private var claudeCodexScanProgress = ""
    @State private var claudeCodexScanTask: Task<Void, Never>?

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
        .task {
            catalogedSkillFilePaths = viewModel.catalogedSkillFilePaths
            catalogedSkillNames = Set(viewModel.allVisibleSkillRecords.map { Self.normalizedSkillName($0.name) })
            let importable = updateCandidateCaches()
            scheduleFilterUpdate(immediate: true, candidates: importable)
        }
        .onChange(of: mode) { _, _ in
            importErrorMessage = nil
            searchText = ""
            filteredCandidates = []
            visibleImportableIDs = []
            selectedIDs = []
            resetCollectionOptions()
            summariesByID = [:]
            let importable = updateCandidateCaches()
            scheduleFilterUpdate(immediate: true, candidates: importable)
            if mode == .claudeCodex, claudeCodexCandidates.isEmpty {
                startClaudeCodexScan()
            }
        }
        .onChange(of: searchText) { _, _ in scheduleFilterUpdate() }
        .onChange(of: selectedIDs) { _, _ in updateCollectionDefaultsForCurrentSelection() }
        .onChange(of: localCandidates) { _, _ in
            let importable = updateCandidateCaches()
            scheduleFilterUpdate(immediate: true, candidates: importable)
        }
        .onChange(of: claudeCodexCandidates) { _, _ in
            let importable = updateCandidateCaches()
            scheduleFilterUpdate(immediate: true, candidates: importable)
        }
        .onChange(of: remoteContext) { _, _ in
            let importable = updateCandidateCaches()
            scheduleFilterUpdate(immediate: true, candidates: importable)
        }
        .onAppear {
            let importable = updateCandidateCaches()
            scheduleFilterUpdate(immediate: true, candidates: importable)
        }
        .onDisappear {
            localScanTask?.cancel()
            claudeCodexScanTask?.cancel()
            remoteFetchTask?.cancel()
            searchDebounceTask?.cancel()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(languageStore.t("skillImport.title"))
                .font(.headline)
                .fontWidth(.expanded)
            Text(languageStore.t("skillImport.subtitle"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(18)
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Picker(languageStore.t("skillImport.source"), selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .appSegmentedPicker()
                .labelsHidden()

                AppCard(title: sourceCardTitle) {
                    switch mode {
                    case .localFolder: localSourceCard
                    case .claudeCodex: claudeCodexSourceCard
                    case .gitRepository: gitSourceCard
                    }
                }

                AppCard(title: languageStore.t("skillImport.skills")) {
                    VStack(alignment: .leading, spacing: 12) {
                        skillsCardHeader
                        skillsCardBody
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
            Button(languageStore.t("common.cancel")) { cancelAndDismiss() }
                .appSecondaryButton()
                .keyboardShortcut(.cancelAction)
            Button {
                performImport()
            } label: {
                if isImporting {
                    AppSpinner().controlSize(.small)
                } else {
                    Text(languageStore.t("skillImport.import"))
                }
            }
            .appPrimaryButton()
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
        .padding(16)
    }

    private var sourceCardTitle: String {
        switch mode {
        case .localFolder: return languageStore.t("skillImport.sourceFolder")
        case .claudeCodex: return languageStore.t("skillImport.knownFolders")
        case .gitRepository: return languageStore.t("skillImport.repository")
        }
    }

    // MARK: - Local source card

    private var localSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localSourceURL?.path ?? languageStore.t("skillImport.noFolder"))
                .textSelection(.enabled)
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.mutedText)
            Button(localSourceURL == nil ? languageStore.t("skillImport.chooseFolder") : languageStore.t("skillImport.chooseDifferentFolder")) {
                DispatchQueue.main.async { chooseLocalFolder() }
            }
        }
    }

    // MARK: - Claude / Codex source card

    private var claudeCodexSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(languageStore.t("skillImport.claudeCodexBody"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)

            HStack(spacing: 8) {
                sourceBadge(provider: "anthropic", label: "Claude")
                sourceBadge(provider: "openai-codex", label: "Codex")
                Label(languageStore.t("skillImport.globalProject"), systemImage: "folder.badge.gearshape")
                    .font(AppTheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.contentSubtleFill, in: Capsule())
                Spacer()
                Button(claudeCodexCandidates.isEmpty ? languageStore.t("skillImport.scan") : languageStore.t("skillImport.rescan")) { startClaudeCodexScan() }
                    .appSecondaryButton()
                    .disabled(isBusy)
            }
        }
    }

    private func sourceBadge(provider: String, label: String) -> some View {
        HStack(spacing: 5) {
            ProviderLogoImage(provider: provider, size: 12)
            Text(label)
        }
        .font(AppTheme.Font.micro.weight(.semibold))
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(AppTheme.contentSubtleFill, in: Capsule())
    }

    // MARK: - Git source card

    private var gitSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(AppTheme.mutedText)
                    TextField(languageStore.t("skillImport.pasteURL"), text: $gitURLInput)
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

                Button(languageStore.t("skillImport.fetchSkills")) { fetchRemoteSkills() }
                    .appPrimaryButton()
                    .disabled(gitURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetchingRemote)
            }

            if let remoteContext, !isFetchingRemote {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(String(format: languageStore.t(remoteContext.candidates.count == 1 ? "skillImport.remoteMetaOne" : "skillImport.remoteMeta"), remoteContext.source.displayName, remoteContext.resolvedRef, remoteContext.candidates.count))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    if remoteContext.existingRepository != nil {
                        Text(languageStore.t("skillImport.alreadySynced"))
                            .font(AppTheme.Font.micro.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }

            Text(languageStore.t("skillImport.examples"))
                .font(AppTheme.Font.micro)
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

            Button(languageStore.t("skillImport.clear")) { selectedIDs.removeAll() }
                .appSecondaryButton()
                .disabled(isBusy || selectedIDs.isEmpty)
        }
    }

    private var skillsCardHint: String {
        switch mode {
        case .localFolder:
            return languageStore.t("skillImport.hint.local")
        case .claudeCodex:
            return languageStore.t("skillImport.hint.claudeCodex")
        case .gitRepository:
            return languageStore.t("skillImport.hint.git")
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
        case .claudeCodex:
            if isScanningClaudeCodex {
                claudeCodexScanningView
            } else if claudeCodexCandidates.isEmpty {
                claudeCodexPlaceholderView
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
                Text(String(format: languageStore.t("skillImport.scanningNamed"), localSourceURL?.lastPathComponent ?? languageStore.t("skillImport.folderFallback")))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if let progress = localScanProgress {
                    Text(String(format: languageStore.t((progress.directoriesScanned == 1 && progress.skillsFound == 1) ? "skillImport.scanProgressOne" : "skillImport.scanProgress"), progress.directoriesScanned, progress.skillsFound))
                        .font(AppTheme.Font.micro)
                        .foregroundStyle(AppTheme.mutedText)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var claudeCodexScanningView: some View {
        VStack(spacing: 12) {
            AppSpinner().controlSize(.regular)
            Text(claudeCodexScanProgress.isEmpty ? languageStore.t("skillImport.scanningKnown") : claudeCodexScanProgress)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var remoteFetchingView: some View {
        VStack(spacing: 12) {
            AppSpinner().controlSize(.regular)
            Text(remoteFetchPhase.isEmpty ? languageStore.t("skillImport.fetchingRepo") : remoteFetchPhase)
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
            Text(languageStore.t("skillImport.remotePlaceholder"))
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
            Text(languageStore.t("skillImport.localPlaceholder"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var claudeCodexPlaceholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(AppTheme.mutedText)
            Text(languageStore.t("skillImport.claudePlaceholder"))
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
                TextField(languageStore.t("skillImport.searchPlaceholder"), text: $searchText)
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
                    .accessibilityLabel(languageStore.t("skillImport.clearSearchA11y"))
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
                .font(AppTheme.Font.micro)
                .foregroundStyle(AppTheme.mutedText)

            collectionOptionsView

            let lastCandidateID = filteredCandidates.last?.id
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredCandidates.isEmpty {
                    Text(isSearchActive
                         ? languageStore.t("skillImport.noMatch")
                         : languageStore.t("skillImport.noneNew"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(filteredCandidates) { candidate in
                    CandidateRow(
                        candidate: candidate,
                        isSelected: Binding(
                            get: { selectedIDs.contains(candidate.id) },
                            set: { isSelected in
                                if isSelected { selectedIDs.insert(candidate.id) }
                                else { selectedIDs.remove(candidate.id) }
                            }
                        ),
                        summaryState: summariesByID[candidate.id],
                        onRequestSummary: { Task { await requestSummary(for: candidate) } },
                        canGenerateSummary: viewModel.skillDescriptionGenerationModel() != nil
                    )
                    if candidate.id != lastCandidateID {
                        Divider()
                    }
                }
            }
        }
    }

    /// Triggers a recomputation of `filteredCandidates` after a short debounce
    /// when the search text changes, and immediately when the source data
    /// changes (local/remote candidates arriving).
    @MainActor
    private func scheduleFilterUpdate(immediate: Bool = false, candidates: [DisplayCandidate]? = nil) {
        searchDebounceTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let delay: Duration = immediate || query.isEmpty ? .milliseconds(0) : .milliseconds(80)
        let candidates = candidates ?? importableCandidates
        searchDebounceTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = Self.filteredImportableCandidates(from: candidates, query: query)
            guard !Task.isCancelled else { return }
            filteredCandidates = result
            visibleImportableIDs = Set(result.map(\.id))
        }
    }

    private static func filteredImportableCandidates(
        from candidates: [DisplayCandidate],
        query: String
    ) -> [DisplayCandidate] {
        guard !query.isEmpty else { return candidates }
        return candidates
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
        case .claudeCodex:
            guard let match = claudeCodexCandidates.first(where: { $0.id == candidate.id }) else {
                throw SkillSummaryError.skillNotFound
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: match.external.skillFilePath))
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
        let sourceProvider: String?
        let sourceLabel: String?
    }

    struct KnownSkillCandidate: Identifiable, Hashable {
        let external: ExternalSkillCandidate
        let source: KnownSkillSource
        let pluginReference: CodexPluginSkillReference?
        let pluginVersion: String?
        var id: String {
            guard let pluginReference else { return external.sourceRootPath }
            return "codex-plugin:\(pluginReference.marketplace):\(pluginReference.plugin):\(pluginReference.relativeSkillRoot)"
        }
    }

    struct KnownSkillSource: Hashable {
        let root: URL
        let label: String
        let provider: String
    }

    private func makeDisplayCandidates() -> [DisplayCandidate] {
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
                    alreadyImported: catalogedSkillFilePaths.contains(skillPath),
                    sourceProvider: nil,
                    sourceLabel: nil
                )
            }
        case .claudeCodex:
            return filteredKnownSkillCandidates(claudeCodexCandidates).map { candidate in
                let skillPath = URL(fileURLWithPath: candidate.external.skillFilePath).standardizedFileURL.path
                return DisplayCandidate(
                    id: candidate.id,
                    name: candidate.external.name,
                    description: candidate.external.description,
                    detailLabel: "Path",
                    detailValue: candidate.external.sourceRootPath,
                    badge: candidate.pluginReference.map { "Codex Plugin · \(candidate.pluginVersion ?? "active") · \($0.marketplace)" },
                    alreadyImported: candidate.pluginReference.map { viewModel.appSettings.codexPluginSkillReferences.contains($0) } ?? catalogedSkillFilePaths.contains(skillPath),
                    sourceProvider: candidate.source.provider,
                    sourceLabel: candidate.source.label
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
                    alreadyImported: remoteContext.alreadySyncedDirectories.contains(candidate.repoRelativeDirectory),
                    sourceProvider: nil,
                    sourceLabel: nil
                )
            }
        }
    }

    private func filteredKnownSkillCandidates(_ candidates: [KnownSkillCandidate]) -> [KnownSkillCandidate] {
        let existingPaths = Set(viewModel.appSettings.externalSkillPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let duplicateNames = Set(
            Dictionary(grouping: candidates, by: { Self.normalizedSkillName($0.external.name) })
                .filter { !$0.key.isEmpty && $0.value.count > 1 }
                .keys
        )

        return candidates.filter { candidate in
            let skillPath = URL(fileURLWithPath: candidate.external.skillFilePath).standardizedFileURL.path
            let rootPath = URL(fileURLWithPath: candidate.external.sourceRootPath).standardizedFileURL.path
            let normalizedName = Self.normalizedSkillName(candidate.external.name)
            let isExistingPlugin = candidate.pluginReference.map { viewModel.appSettings.codexPluginSkillReferences.contains($0) } ?? false
            return !isExistingPlugin
                && !catalogedSkillFilePaths.contains(skillPath)
                && !existingPaths.contains(rootPath)
                && !catalogedSkillNames.contains(normalizedName)
                && !duplicateNames.contains(normalizedName)
        }
    }

    private static func normalizedSkillName(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    @MainActor
    private func updateCandidateCaches() -> [DisplayCandidate] {
        let display = makeDisplayCandidates()
        let importable = display.filter { !$0.alreadyImported }
        displayCandidates = display
        importableCandidates = importable
        let importableIDs = Set(importable.map(\.id))
        importableCandidateIDs = importableIDs
        hiddenAlreadyImportedCount = display.count - importable.count
        visibleImportableIDs = Set(filteredCandidates.map(\.id)).intersection(importableIDs)
        return importable
    }

    private var allVisibleImportableSelected: Bool {
        !visibleImportableIDs.isEmpty && visibleImportableIDs.isSubset(of: selectedIDs)
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectionButtonTitle: String {
        if isSearchActive {
            return allVisibleImportableSelected
                ? languageStore.t("skillImport.deselectVisible")
                : languageStore.t("skillImport.selectVisible")
        }
        return allVisibleImportableSelected
            ? languageStore.t("skillImport.deselectAll")
            : languageStore.t("skillImport.selectAll")
    }

    private var candidateCountSummary: String {
        let showingKey = importableCandidates.count == 1
            ? "skillImport.showingCountOne"
            : "skillImport.showingCount"
        var parts = [
            String(
                format: languageStore.t(showingKey),
                filteredCandidates.count,
                importableCandidates.count
            )
        ]
        if hiddenAlreadyImportedCount > 0 {
            parts.append(String(format: languageStore.t("skillImport.hiddenCatalog"), hiddenAlreadyImportedCount))
        }
        if !selectedIDs.isEmpty {
            parts.append(String(format: languageStore.t("skillImport.selectedCount"), selectedIDs.count))
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var collectionOptionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { importAsCollection },
                set: { newValue in
                    didManuallySetImportAsCollection = true
                    importAsCollection = newValue
                    if newValue, collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        collectionName = suggestedCollectionName
                    }
                }
            )) {
                Text(languageStore.t("skillImport.asCollection"))
                    .font(.caption.weight(.semibold))
            }
            .appCheckbox()
            .disabled(isBusy || selectedIDs.isEmpty)

            HStack(spacing: 8) {
                Text(languageStore.t("skillImport.collectionName"))
                    .font(AppTheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                TextField(languageStore.t("skillImport.collectionName"), text: Binding(
                    get: { collectionName },
                    set: { newValue in
                        didEditCollectionName = true
                        collectionName = newValue
                    }
                ))
                .textFieldStyle(.plain)
                .appBrandTint()
                .disabled(!importAsCollection || isBusy || selectedIDs.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.contentStroke.opacity(importAsCollection ? 0.8 : 0.35), lineWidth: 1)
            )
            .opacity(importAsCollection ? 1 : 0.55)

            Text(importAsCollection
                 ? languageStore.t("skillImport.collectionOn")
                 : languageStore.t("skillImport.collectionOff"))
                .font(AppTheme.Font.micro)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(10)
        .background(AppTheme.panelFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.contentStroke.opacity(0.5), lineWidth: 1)
        )
    }

    private var trimmedCollectionName: String {
        collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedImportableCount: Int {
        selectedIDs.intersection(importableCandidateIDs).count
    }

    private var suggestedCollectionName: String {
        switch mode {
        case .localFolder:
            let name = localSourceURL?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "Imported Skills" : name
        case .claudeCodex:
            return "Claude / Codex Skills"
        case .gitRepository:
            let name = remoteContext?.source.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "Imported Skills" : name
        }
    }

    private var isBusy: Bool {
        isScanningLocal || isScanningClaudeCodex || isFetchingRemote || isImporting
    }

    private var canImport: Bool {
        guard !isBusy, !selectedIDs.isEmpty else { return false }
        return !importAsCollection || !trimmedCollectionName.isEmpty
    }

    private func resetCollectionOptions() {
        importAsCollection = false
        collectionName = ""
        didManuallySetImportAsCollection = false
        didEditCollectionName = false
    }

    private func updateCollectionDefaultsForCurrentSelection() {
        if !didEditCollectionName || trimmedCollectionName.isEmpty {
            collectionName = suggestedCollectionName
        }
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
        resetCollectionOptions()
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
        let importable = updateCandidateCaches()
        scheduleFilterUpdate(immediate: true, candidates: importable)

        guard !localCandidates.isEmpty else {
            selectedIDs = []
            importErrorMessage = "No importable skill folders were found. Choose a skill root containing SKILL.md, or a folder that contains skill roots below it."
            return
        }
        // Pre-select only skills that are not already in the catalog.
        selectedIDs = Set(importable.map(\.id))
        updateCollectionDefaultsForCurrentSelection()
    }

    // MARK: - Claude / Codex actions

    private func startClaudeCodexScan() {
        claudeCodexScanTask?.cancel()
        importErrorMessage = nil
        searchText = ""
        claudeCodexCandidates = []
        selectedIDs = []
        resetCollectionOptions()
        isScanningClaudeCodex = true
        claudeCodexScanProgress = "Scanning known skill folders…"
        let sources = knownSkillSources()

        claudeCodexScanTask = Task {
            var discovered: [KnownSkillCandidate] = []
            var seenRootPaths = Set<String>()

            for (index, source) in sources.enumerated() {
                if Task.isCancelled { break }
                claudeCodexScanProgress = "Scanning \(source.label)… \(index + 1)/\(sources.count)"
                let candidates = await ExternalSkillDiscovery.discover(root: source.root)
                for candidate in candidates {
                    let rootPath = URL(fileURLWithPath: candidate.sourceRootPath).standardizedFileURL.path
                    guard seenRootPaths.insert(rootPath).inserted else { continue }
                    discovered.append(KnownSkillCandidate(external: candidate, source: source, pluginReference: nil, pluginVersion: nil))
                }
            }
            claudeCodexScanProgress = "Scanning installed Codex plugins…"
            for (candidate, reference, package) in await CodexPluginSkillDiscovery.candidateReferences() {
                guard seenRootPaths.insert("plugin:\(reference.marketplace):\(reference.plugin):\(reference.relativeSkillRoot)").inserted else { continue }
                discovered.append(KnownSkillCandidate(
                    external: candidate,
                    source: KnownSkillSource(root: package.root, label: "Codex Plugin · \(package.displayName) · \(package.version) · \(reference.marketplace)", provider: "openai-codex"),
                    pluginReference: reference,
                    pluginVersion: package.version
                ))
            }

            guard !Task.isCancelled else { return }
            applyClaudeCodexCandidates(discovered.sorted { lhs, rhs in
                let nameOrder = lhs.external.name.localizedCaseInsensitiveCompare(rhs.external.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.external.sourceRootPath < rhs.external.sourceRootPath
            })
        }
    }

    private func knownSkillSources() -> [KnownSkillSource] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var sources: [KnownSkillSource] = [
            KnownSkillSource(root: home.appendingPathComponent(".claude/skills", isDirectory: true), label: "Claude · Global", provider: "anthropic"),
            KnownSkillSource(root: home.appendingPathComponent(".codex/skills", isDirectory: true), label: "Codex · Global", provider: "openai-codex")
        ]

        for project in viewModel.discoveredProjects.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            sources.append(KnownSkillSource(root: project.url.appendingPathComponent(".claude/skills", isDirectory: true), label: "Claude · \(project.name)", provider: "anthropic"))
            sources.append(KnownSkillSource(root: project.url.appendingPathComponent(".codex/skills", isDirectory: true), label: "Codex · \(project.name)", provider: "openai-codex"))
        }
        return sources
    }

    private func applyClaudeCodexCandidates(_ candidates: [KnownSkillCandidate]) {
        isScanningClaudeCodex = false
        claudeCodexScanProgress = ""
        claudeCodexCandidates = candidates
        let importable = updateCandidateCaches()
        scheduleFilterUpdate(immediate: true, candidates: importable)

        guard !candidates.isEmpty else {
            selectedIDs = []
            importErrorMessage = "No Claude or Codex skills with a SKILL.md were found in known folders."
            return
        }
        selectedIDs = Set(importable.map(\.id))
        updateCollectionDefaultsForCurrentSelection()
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
        resetCollectionOptions()
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
                let importable = updateCandidateCaches()
                scheduleFilterUpdate(immediate: true, candidates: importable)
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
        updateCollectionDefaultsForCurrentSelection()
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
                let result = try viewModel.importExternalSkills(
                    selected,
                    collectionName: importAsCollection ? trimmedCollectionName : nil
                )
                finish(result)
            } catch {
                importErrorMessage = error.localizedDescription
            }

        case .claudeCodex:
            let selected = filteredKnownSkillCandidates(claudeCodexCandidates)
                .filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            do {
                let result = try viewModel.importKnownSkills(
                    selected,
                    collectionName: importAsCollection ? trimmedCollectionName : nil
                )
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
                    let result = try await viewModel.importRemoteSkills(
                        context: context,
                        selectedCandidates: selected,
                        collectionName: importAsCollection ? trimmedCollectionName : nil
                    )
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
        claudeCodexScanTask?.cancel()
        remoteFetchTask?.cancel()
        if let remoteContext {
            viewModel.discardDiscoveryClone(remoteContext)
        }
        isPresented = false
    }

    // MARK: - Row view

    private struct CandidateRow: View {
        let candidate: DisplayCandidate
        @Binding var isSelected: Bool
        let summaryState: SummaryState?
        let onRequestSummary: () -> Void
        let canGenerateSummary: Bool
        @State private var isHovered = false

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Toggle(isOn: $isSelected) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(candidate.name)
                                .font(.body.weight(.semibold))
                            if let badge = candidate.badge {
                                Text(badge)
                                    .font(AppTheme.Font.micro.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                            }
                        }

                        sourceBlock

                        if let description = candidate.description {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LanguageStore.shared.t("skillImport.description"))
                                    .font(AppTheme.Font.micro.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedText)
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                        }

                        summaryBlock

                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.detailLabel)
                                .font(AppTheme.Font.micro.weight(.semibold))
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

                if canGenerateSummary {
                    magicButton
                        .padding(.top, 10)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
        }

        @ViewBuilder
        private var sourceBlock: some View {
            if let sourceLabel = candidate.sourceLabel {
                HStack(spacing: 5) {
                    if let provider = candidate.sourceProvider {
                        ProviderLogoImage(provider: provider, size: 12)
                    }
                    Text(sourceLabel)
                }
                .font(AppTheme.Font.micro.weight(.medium))
                .foregroundStyle(AppTheme.mutedText)
            }
        }

        @ViewBuilder
        private var summaryBlock: some View {
            switch summaryState {
            case .loading:
                HStack(spacing: 6) {
                    AppSpinner().controlSize(.small)
                    Text(LanguageStore.shared.t("skillImport.summarising"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            case let .ready(text):
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(AppTheme.brandAccent)
                        Text(LanguageStore.shared.t("skillImport.aiSummary"))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .font(AppTheme.Font.micro.weight(.semibold))
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AppTheme.Font.micro)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case nil:
                EmptyView()
            }
        }

        @ViewBuilder
        private var magicButton: some View {
            let isVisible = isHovered || summaryState != nil
            AppCircleIconButton(
                style: .soft,
                tint: AppTheme.brandAccent,
                size: 28,
                imageScale: .medium,
                help: magicButtonHelpText,
                action: onRequestSummary
            ) {
                switch summaryState {
                case .loading:
                    AppSpinner().controlSize(.small)
                case .failed:
                    Image(systemName: "arrow.clockwise")
                default:
                    Image(systemName: "sparkles")
                }
            }
            .disabled(summaryState == .loading)
            .opacity(isVisible ? 1 : 0)
        }

        private var magicButtonHelpText: String {
            switch summaryState {
            case .loading: return "Generating summary…"
            case .failed: return "Retry AI summary"
            case .ready: return "Regenerate AI summary"
            case .none: return "Summarise this skill with AI"
            }
        }
    }

    // MARK: - Search scoring

    private static func searchScore(_ candidate: DisplayCandidate, query: String) -> Int? {
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

    private static func searchTokens(_ text: String) -> [String] {
        normalizedSearchText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !["skill", "skills", "native", "claude", "code"].contains($0) }
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactSearchText(_ text: String) -> String {
        normalizedSearchText(text).replacingOccurrences(of: " ", with: "")
    }
}
