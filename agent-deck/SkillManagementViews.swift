import AppKit
import SwiftUI

struct SkillsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skill assignment")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Catalog", "Agent Deck scans skills from bundled, user, project, compatibility, package, and imported external locations.")
                infoRow("Default", "Default skills are passed to every parent Pi Agent session with explicit --skill flags.")
                infoRow("Project", "Project assignments are passed only to parent sessions for that project.")
                infoRow("Agents", "Native subagents receive only skills explicitly assigned to that agent.")
            }

            Text("Discovery does not inject a skill. Agent Deck launches with --no-skills and passes only assigned skills using --skill <path>.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
            Text(description)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum SkillWarningSelection: Identifiable, Hashable {
    case missing(SkillReferenceWarning)
    case diagnostic(DiagnosticWarning)

    var id: String {
        switch self {
        case let .missing(warning): return "missing:\(warning.id)"
        case let .diagnostic(warning): return "diagnostic:\(warning.id)"
        }
    }

    var title: String {
        switch self {
        case let .missing(warning): return warning.missingSkill
        case .diagnostic: return "Skill Warning"
        }
    }

    var subtitle: String {
        switch self {
        case let .missing(warning): return "Referenced by \(warning.agentName) in \(warning.project.name)"
        case .diagnostic: return "Skill catalog issue"
        }
    }
}

struct SkillListMetadata {
    let isAssigned: Bool
    let hasWarnings: Bool
    /// Globally enabled, or enabled for the currently-selected project — drives
    /// the active/catalog split. Cached so the split isn't an O(skills) project-
    /// preference scan on every body eval.
    let isActiveForCurrentProject: Bool
}

struct SkillsScreen: View {
    var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var selectedSkillIDs: Set<SkillRecord.ID> = []
    @State private var skillsPendingBatchDeletion: [SkillRecord]?
    @State private var selectedWarning: SkillWarningSelection?
    @State private var isImportSheetPresented = false
    @State private var importSummaryMessage: String?
    @State private var skillActionErrorMessage: String?
    @State private var skillPendingDeletion: SkillRecord?
    @State private var skillPendingRemoval: SkillRecord?
    @State private var skillsPendingBatchRemoval: [SkillRecord]?
    @State private var skillPendingRename: SkillRecord?
    @State private var hoveredSkillID: SkillRecord.ID?
    @State private var skillEditTarget: MarkdownFileEditTarget?
    @State private var newSkillDraft: NewSkillDraft?
    @State private var isCheckingSkillUpdate = false
    @State private var isUpdatingSkillRepository = false
    @State private var skillUpdateStatusMessage: String?
    @State private var skillUpdateConflict: SkillUpdateConflictContext?

    var body: some View {
        skillsScreenWithSheets
            .alert("Skill Import", isPresented: Binding(
                get: { importSummaryMessage != nil },
                set: { if !$0 { importSummaryMessage = nil } }
            )) {
                Button("OK") { importSummaryMessage = nil }
            } message: {
                Text(importSummaryMessage ?? "")
            }
            .alert("Skill Assignment", isPresented: Binding(
                get: { skillActionErrorMessage != nil },
                set: { if !$0 { skillActionErrorMessage = nil } }
            )) {
                Button("OK") { skillActionErrorMessage = nil }
            } message: {
                Text(skillActionErrorMessage ?? "")
            }
            .alert("Delete Skill?", isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
            ), presenting: skillPendingDeletion) { skill in
                Button("Move to Trash", role: .destructive) { deleteSkill(skill) }
                Button("Cancel", role: .cancel) { skillPendingDeletion = nil }
            } message: { skill in
                Text("Move \"\(skill.name)\" to the Trash and remove its Default, project, and agent assignments?")
            }
            .alert("Delete Skills?", isPresented: Binding(
                get: { skillsPendingBatchDeletion != nil },
                set: { if !$0 { skillsPendingBatchDeletion = nil } }
            ), presenting: skillsPendingBatchDeletion) { skills in
                Button("Move \(skills.count) to Trash", role: .destructive) { batchDeleteSkills(skills) }
                Button("Cancel", role: .cancel) { skillsPendingBatchDeletion = nil }
            } message: { skills in
                Text("Move \(skills.count) skills to the Trash and remove their Default, project, and agent assignments?")
            }
            .alert("Remove Skill?", isPresented: Binding(
                get: { skillPendingRemoval != nil },
                set: { if !$0 { skillPendingRemoval = nil } }
            ), presenting: skillPendingRemoval) { skill in
                Button("Remove from Catalog") { removeSkill(skill) }
                Button("Cancel", role: .cancel) { skillPendingRemoval = nil }
            } message: { skill in
                Text("Remove \"\(skill.name)\" from the \(AppBrand.displayName) catalog and clear its Default, project, and agent assignments? The skill files are not deleted — a Git-synced clone is kept.")
            }
            .alert("Remove Skills?", isPresented: Binding(
                get: { skillsPendingBatchRemoval != nil },
                set: { if !$0 { skillsPendingBatchRemoval = nil } }
            ), presenting: skillsPendingBatchRemoval) { skills in
                Button("Remove \(skills.count) from Catalog") { batchRemoveSkills(skills) }
                Button("Cancel", role: .cancel) { skillsPendingBatchRemoval = nil }
            } message: { skills in
                Text("Remove \(skills.count) skills from the \(AppBrand.displayName) catalog and clear their assignments? The skill files are not deleted.")
            }
            .alert("Skill Updates", isPresented: Binding(
                get: { viewModel.skillBatchActionMessage != nil },
                set: { if !$0 { viewModel.skillBatchActionMessage = nil } }
            )) {
                Button("OK") { viewModel.skillBatchActionMessage = nil }
            } message: {
                Text(viewModel.skillBatchActionMessage ?? "")
            }
    }

    private var skillsScreenCore: some View {
        HSplitView {
            if viewModel.hasCompletedInitialRefresh {
                skillLibraryContent
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
            } else {
                AppLoadingView("Loading skills…")
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
            }

            if viewModel.hasCompletedInitialRefresh {
                AppPage(
                    selectedWarning?.title ?? skillDetailTitle,
                    subtitle: selectedWarning?.subtitle ?? skillDetailSubtitle
                ) {
                    skillDetailContent
                }
            } else {
                AppLoadingView("Loading skill details…")
            }
        }
        .onAppear { scheduleSelectionSynchronization() }
        .onChange(of: viewModel.allVisibleSkillRecords) { _, _ in scheduleSelectionSynchronization() }
        .onChange(of: viewModel.selectedSkillID) { _, _ in scheduleSelectionSynchronization() }
        .onChange(of: selectedSkillIDs) { _, ids in
            skillUpdateStatusMessage = nil
            if !ids.isEmpty {
                selectedWarning = nil
            }
            // The view model tracks a single focused skill (toolbar title,
            // cross-view state); a multi-selection has no single focus.
            let primary: SkillRecord.ID? = ids.count == 1 ? ids.first : nil
            if viewModel.selectedSkillID != primary {
                viewModel.selectedSkillID = primary
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportSkillsRequested)) { _ in
            beginSkillImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewSkillRequested)) { _ in
            createNewSkill()
        }
    }

    private var skillsScreenWithSheets: some View {
        skillsScreenCore
        .sheet(isPresented: $isImportSheetPresented) {
            SkillImportSheet(viewModel: viewModel, isPresented: $isImportSheetPresented) { result in
                importSummaryMessage = importSummary(for: result)
            }
        }
        .sheet(item: $skillEditTarget) { target in
            MarkdownFileEditorSheet(target: target) {
                viewModel.refreshVisibleStateImmediately(scanAllProjects: true)
                viewModel.refresh(includeModels: false, scanAllProjects: true)
                if target.isNew {
                    viewModel.selectedSkillID = viewModel.allVisibleSkillRecords.first { $0.filePath == target.path }?.id ?? viewModel.selectedSkillID
                }
            }
        }
        .sheet(item: $newSkillDraft) { draft in
            NewSkillEditorSheet(draft: draft, destinationPath: viewModel.newLibrarySkillPath(for: draft.name.isEmpty ? "skill-name" : draft.name)) { savedDraft in
                try viewModel.saveNewLibrarySkill(savedDraft)
                let savedPath = viewModel.newLibrarySkillPath(for: savedDraft.name)
                viewModel.refreshVisibleStateImmediately(scanAllProjects: true)
                viewModel.refresh(includeModels: false, scanAllProjects: true)
                viewModel.selectedSkillID = viewModel.allVisibleSkillRecords.first { $0.filePath == savedPath }?.id ?? viewModel.selectedSkillID
            }
        }
        .sheet(item: $skillPendingRename) { skill in
            RenameResourceSheet(
                title: "Rename Skill",
                currentName: skill.name,
                resourceLabel: "skill",
                makePreview: { viewModel.renamePreview(for: skill, to: $0) },
                onRename: { try viewModel.renameSkill(skill, to: $0) }
            )
        }
        .sheet(item: $skillUpdateConflict) { conflict in
            SkillUpdateConflictSheet(
                viewModel: viewModel,
                context: conflict,
                isPresented: Binding(
                    get: { skillUpdateConflict != nil },
                    set: { if !$0 { skillUpdateConflict = nil } }
                )
            ) { outcome in
                if case .updated = outcome {
                    skillUpdateStatusMessage = "Updated to the latest version."
                }
            }
        }
    }

    @ViewBuilder
    private var skillLibraryContent: some View {
        // Precomputed in AppViewModel, rebuilt only on data rescans — was
        // O(skills × warnings/projects/agents) on every body eval.
        let metadataByID = viewModel.cachedSkillMetadataByID
        List(selection: $selectedSkillIDs) {
            if !viewModel.skillReferenceWarnings.isEmpty || !viewModel.skillWarnings.isEmpty {
                appListSection("Warnings", tint: .orange) {
                    ForEach(viewModel.skillReferenceWarnings) { warning in
                        skillWarningCard(warning)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .selectionDisabled()
                    }
                    ForEach(viewModel.skillWarnings) { warning in
                        diagnosticWarningCard(warning)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .selectionDisabled()
                    }
                }
            }

            if selectedProject != nil {
                appListSection("Active") {
                    if activeSkills.isEmpty {
                        nativeEmptyRow("No skills are assigned for this project.")
                    }
                    ForEach(activeSkills, id: \.name) { skill in
                        skillListRow(skill, metadata: metadataByID[skill.id] ?? SkillListMetadata(isAssigned: false, hasWarnings: false, isActiveForCurrentProject: false), inactive: false)
                            .tag(skill.id)
                    }
                }

                if !catalogSkills.isEmpty {
                    catalogSection(skills: catalogSkills, metadataByID: metadataByID)
                }
            } else {
                appListSection("Default Skills", info: "Injected into every parent Pi Agent session. This is global runtime injection, not per-project assignment.") {
                    if globalSkills.isEmpty {
                        nativeEmptyRow("No default skills.")
                    }
                    ForEach(globalSkills, id: \.name) { skill in
                        skillListRow(skill, metadata: metadataByID[skill.id] ?? SkillListMetadata(isAssigned: false, hasWarnings: false, isActiveForCurrentProject: false), inactive: false)
                            .tag(skill.id)
                    }
                }

                if !catalogSkills.isEmpty {
                    catalogSection(skills: catalogSkills, metadataByID: metadataByID)
                }
            }
        }
        .appListStyle()
        .contextMenu(forSelectionType: SkillRecord.ID.self) { ids in
            skillContextMenu(for: ids)
        }
    }

    /// Selection-aware list context menu. A single right-clicked skill gets the
    /// full action set; a multi-selection gets a batch delete.
    @ViewBuilder
    private func skillContextMenu(for ids: Set<SkillRecord.ID>) -> some View {
        let skills = managedSkills.filter { ids.contains($0.id) }
        if skills.count > 1 {
            let importable = skills.filter { viewModel.isImportedSkill($0) }
            let deletable = skills.filter { viewModel.canDeleteSkill($0) }
            if !importable.isEmpty {
                Button {
                    skillsPendingBatchRemoval = importable
                } label: {
                    Label("Remove \(importable.count) from Catalog", systemImage: "minus.circle")
                }
            }
            if !deletable.isEmpty {
                Button(role: .destructive) {
                    skillsPendingBatchDeletion = deletable
                } label: {
                    Label("Delete \(deletable.count) Skill\(deletable.count == 1 ? "" : "s")", systemImage: "trash")
                }
            }
        } else if let skill = skills.first {
            Button {
                skillEditTarget = makeSkillEditTarget(skill)
            } label: {
                Label("Edit SKILL.md", systemImage: "square.and.pencil")
            }
            .disabled(!viewModel.canRenameSkill(skill))

            Button {
                revealSkillInFinder(skill)
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }

            Button {
                skillPendingRename = skill
            } label: {
                Label("Rename Skill", systemImage: "pencil")
            }
            .disabled(!viewModel.canRenameSkill(skill))

            if viewModel.isImportedSkill(skill) || viewModel.canDeleteSkill(skill) {
                Divider()
            }

            if viewModel.isImportedSkill(skill) {
                Button {
                    skillPendingRemoval = skill
                } label: {
                    Label("Remove from Catalog", systemImage: "minus.circle")
                }
            }

            if viewModel.canDeleteSkill(skill) {
                Button(role: .destructive) {
                    skillPendingDeletion = skill
                } label: {
                    Label("Delete Skill", systemImage: "trash")
                }
            }
        }
    }

    private func catalogSection(skills: [SkillRecord], metadataByID: [SkillRecord.ID: SkillListMetadata]) -> some View {
        appListSection("Catalog", info: "Available skills. They are not injected until made Default, assigned to a project runtime, or assigned to a subagent.") {
            ForEach(skills, id: \.name) { skill in
                skillListRow(skill, metadata: metadataByID[skill.id] ?? SkillListMetadata(isAssigned: false, hasWarnings: false, isActiveForCurrentProject: false), inactive: true)
                    .tag(skill.id)
            }
        }
    }

    private func skillWarningCard(_ warning: SkillReferenceWarning) -> some View {
        Button {
            selectedSkillIDs = []
            selectedWarning = .missing(warning)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.missingSkill)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .lineLimit(1)
                    Text("Referenced by \(warning.agentName) in \(warning.project.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Missing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
            .padding(.leading, 8).padding(.trailing, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
    }

    private func diagnosticWarningCard(_ warning: DiagnosticWarning) -> some View {
        Button {
            selectedSkillIDs = []
            selectedWarning = .diagnostic(warning)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                Text(warning.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var skillDetailContent: some View {
        if let selectedWarning {
            skillWarningDetail(selectedWarning)
        } else if selectedSkillIDs.count > 1 {
            batchSelectionDetail(selectedSkills)
        } else if let skill = selectedSkill {
            let warnings = warningsForSkill(skill)
            if !warnings.isEmpty {
                skillWarningSummaryCard(warnings: warnings)
            }

            if skill.source.kind == .package {
                AppCard(title: "Package Skill") {
                    Text("This skill is provided by an installed package. It is not injected unless assigned as Default, assigned to a project, or assigned to an agent.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            syncedRepositoryCard(for: skill)

            AppCard(title: "Default Skill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(defaultSkillHelpText(for: skill))
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.skillIsEnabledGlobally(skill) {
                            Button("Remove Default") {
                                do { try viewModel.disableSkillGlobally(skill) }
                                catch { presentSkillActionError(error, skill: skill, action: "disable global visibility") }
                            }
                            .appSecondaryButton()
                        } else {
                            Button("Make Default") {
                                do { try viewModel.enableSkillGlobally(skill) }
                                catch { presentSkillActionError(error, skill: skill, action: "enable global visibility") }
                            }
                            .appPrimaryButton()
                        }
                    }
                }

            if !viewModel.skillIsEnabledGlobally(skill) {
                AppCard(title: "Project Runtime Assignment") {
                    projectAssignmentList(for: skill)
                }
            }

            AppCard(title: "Subagent Runtime Assignment") {
                agentAssignmentList(for: skill)
            }

            AppCard(title: "Definition") {
                MarkdownDocumentView(source: skill.body, minimumHeight: 220)
            }

            AppCard(title: "Manage \(skill.name)") {
                VStack(alignment: .leading, spacing: 12) {
                    AppKeyValueList(rows: [
                        ("Source", skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                        ("Default", viewModel.skillIsEnabledGlobally(skill) ? "Yes" : "No"),
                        ("Assigned Projects", assignedProjectSummary(skill)),
                        ("Assigned Agents", assignedAgentSummary(skill)),
                        ("Path", skill.filePath)
                    ])
                    HStack {
                        if viewModel.canRenameSkill(skill) {
                            Button("Edit…") { skillEditTarget = makeSkillEditTarget(skill) }
                        }
                        Button("Rename…") { skillPendingRename = skill }
                            .disabled(!viewModel.canRenameSkill(skill))
                        Button("Reveal in Finder") { revealSkillInFinder(skill) }
                    }
                }
            }
        } else {
            AppCard {
                ContentUnavailableView("No Skill Selected", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    @ViewBuilder
    private func syncedRepositoryCard(for skill: SkillRecord) -> some View {
        if let repository = viewModel.importedRepository(for: skill) {
            AppCard(title: "Synced Repository") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This skill is synced from a GitHub repository. You can edit it here; updates fast-forward and ask before overwriting your edits.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    AppKeyValueList(rows: [
                        ("Source", "GitHub · \(repository.displayName)"),
                        ("Branch", repository.ref),
                        ("Synced", "\(shortCommit(repository.lastSyncedCommit)) · \(repository.lastSyncedDate.formatted(date: .abbreviated, time: .shortened))"),
                        ("Last checked", repository.lastCheckedDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    ])

                    if repository.hasKnownUpdate {
                        Label(
                            "Update available — \(shortCommit(repository.lastSyncedCommit)) → \(shortCommit(repository.latestKnownRemoteCommit ?? ""))",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    }

                    if let skillUpdateStatusMessage {
                        Text(skillUpdateStatusMessage)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button {
                            checkSkillRepositoryForUpdate(repository)
                        } label: {
                            if isCheckingSkillUpdate {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        .appSecondaryButton()
                        .disabled(isCheckingSkillUpdate || isUpdatingSkillRepository)

                        if repository.hasKnownUpdate {
                            Button {
                                applySkillRepositoryUpdate(repository)
                            } label: {
                                if isUpdatingSkillRepository {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Update Skill")
                                }
                            }
                            .appPrimaryButton()
                            .disabled(isCheckingSkillUpdate || isUpdatingSkillRepository)
                        }

                        if let webURL = repository.webURL {
                            Button("Open on GitHub") { NSWorkspace.shared.open(webURL) }
                                .appSecondaryButton()
                        }
                    }
                }
            }
        }
    }

    private func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    private func checkSkillRepositoryForUpdate(_ repository: ImportedSkillRepository) {
        isCheckingSkillUpdate = true
        skillUpdateStatusMessage = nil
        Task {
            do {
                let status = try await viewModel.checkSkillRepositoryForUpdate(repository)
                isCheckingSkillUpdate = false
                if case .upToDate = status {
                    skillUpdateStatusMessage = "Up to date."
                }
            } catch {
                isCheckingSkillUpdate = false
                skillUpdateStatusMessage = error.localizedDescription
            }
        }
    }

    private func applySkillRepositoryUpdate(_ repository: ImportedSkillRepository) {
        isUpdatingSkillRepository = true
        skillUpdateStatusMessage = nil
        Task {
            do {
                let outcome = try await viewModel.updateSkillRepository(repository)
                isUpdatingSkillRepository = false
                switch outcome {
                case .updated:
                    skillUpdateStatusMessage = "Updated to the latest version."
                case .alreadyUpToDate:
                    skillUpdateStatusMessage = "Already up to date."
                case let .conflicts(conflicts):
                    skillUpdateConflict = SkillUpdateConflictContext(repository: repository, conflicts: conflicts)
                }
            } catch {
                isUpdatingSkillRepository = false
                skillUpdateStatusMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func skillWarningDetail(_ selection: SkillWarningSelection) -> some View {
        switch selection {
        case let .missing(warning):
            missingSkillWarningDetail(warning)
        case let .diagnostic(warning):
            diagnosticSkillWarningDetail(warning)
        }
    }

    private func missingSkillWarningDetail(_ warning: SkillReferenceWarning) -> some View {
        AppCard(title: "Missing Skill") {
            VStack(alignment: .leading, spacing: 14) {
                Text("The agent references a skill that is not available to that project at runtime.")
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AppKeyValueList(rows: [
                    ("Skill", warning.missingSkill),
                    ("Agent", warning.agentName),
                    ("Project", warning.project.repositoryDisplayName),
                    ("Project Path", warning.project.path)
                ])

                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolve by doing one of these:")
                        .font(.body.weight(.semibold))
                    Text("Install or import a skill named `\(warning.missingSkill)`, then assign it to the project or make it Default.")
                    Text("Or remove `\(warning.missingSkill)` from the agent's skill list if the reference is obsolete.")
                }
                .foregroundStyle(AppTheme.mutedText)
                .textSelection(.enabled)

                HStack {
                    Button("Search Catalog") {
                        searchText = warning.missingSkill
                    }
                    .appSecondaryButton()
                    Button("Import Skills") {
                        beginSkillImport()
                    }
                    .appSecondaryButton()
                    if let agentPath = sourcePath(forAgentNamed: warning.agentName, projectPath: warning.project.path) {
                        Button("Reveal Agent File") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agentPath)])
                        }
                        .appSecondaryButton()
                    }
                }
            }
        }
    }

    private func diagnosticSkillWarningDetail(_ warning: DiagnosticWarning) -> some View {
        AppCard(title: "Skill Warning") {
            VStack(alignment: .leading, spacing: 14) {
                Text(warning.message)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let duplicate = duplicateSkillWarningDetails(warning) {
                    AppKeyValueList(rows: [
                        ("Skill", duplicate.name),
                        ("Issue", "Duplicate skill name"),
                        ("Locations", duplicate.paths.joined(separator: "\n"))
                    ])

                    Text("Keep one canonical copy of this skill and remove or rename the duplicate. Agent Deck can only pass a skill reliably when the name resolves to one path.")
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Search Catalog") {
                            searchText = duplicate.name
                        }
                        ForEach(Array(duplicate.paths.enumerated()), id: \.offset) { index, path in
                            Button("Reveal Copy \(index + 1)") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                } else {
                    Text("Review the referenced file or setting, then fix the malformed or conflicting skill definition.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private func skillWarningSummaryCard(warnings: [DiagnosticWarning]) -> some View {
        AppCard(title: "Warnings") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(warnings) { warning in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        Text(warning.message)
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedProject: DiscoveredProject? {
        viewModel.selectedDiscoveredProject
    }

    private var managedSkills: [SkillRecord] {
        let grouped = Dictionary(grouping: viewModel.allVisibleSkillRecords, by: \.name)
        let skills = grouped.values.compactMap(preferredSkillRecord)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return skills }
        return skills.filter { skill in
            [skill.name, skill.description ?? "", skill.source.kind.rawValue, skill.filePath, skill.body]
                .contains { $0.lowercased().contains(query) }
        }
    }

    /// The skill shown in the detail pane — only when exactly one is selected.
    private var selectedSkill: SkillRecord? {
        guard selectedWarning == nil, selectedSkillIDs.count == 1, let id = selectedSkillIDs.first else { return nil }
        return managedSkills.first { $0.id == id }
    }

    private var selectedSkills: [SkillRecord] {
        managedSkills.filter { selectedSkillIDs.contains($0.id) }
    }

    private var skillDetailTitle: String {
        if selectedSkillIDs.count > 1 { return "\(selectedSkillIDs.count) Skills Selected" }
        return selectedSkill?.name ?? "Skill Details"
    }

    private var skillDetailSubtitle: String? {
        if selectedSkillIDs.count > 1 { return "Batch actions" }
        return selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.snapshot.projectRoot) }
    }

    private var activeSkills: [SkillRecord] {
        if selectedProject != nil {
            return managedSkills.filter { skillIsActiveForCurrentProject($0) }
        }
        return globalSkills
    }

    private var globalSkills: [SkillRecord] {
        managedSkills.filter { viewModel.skillIsEnabledGlobally($0) }
    }

    private var catalogSkills: [SkillRecord] {
        managedSkills.filter { !skillIsActiveForCurrentProject($0) }
    }

    private var projectAssignedSkills: [SkillRecord] {
        guard let selectedProject else { return [] }
        return managedSkills.filter {
            viewModel.skill($0, isEnabledFor: selectedProject) &&
            !viewModel.skillIsEnabledGlobally($0)
        }
    }

    private func preferredSkillRecord(_ records: [SkillRecord]) -> SkillRecord? {
        records.first { $0.source.kind == .library }
        ?? records.first { $0.source.kind == .global }
        ?? records.first { $0.source.kind == .project }
        ?? records.first { $0.source.kind == .legacyProject }
        ?? records.first
    }

    private func skillIsActiveForCurrentProject(_ skill: SkillRecord) -> Bool {
        // Precomputed in AppViewModel's cachedSkillMetadataByID, rebuilt on
        // data rescans. Live fallback covers the pre-first-scan window.
        if let cached = viewModel.cachedSkillMetadataByID[skill.id] {
            return cached.isActiveForCurrentProject
        }
        if viewModel.skillIsEnabledGlobally(skill) { return true }
        if let selectedProject, viewModel.skill(skill, isEnabledFor: selectedProject) { return true }
        return false
    }

    private func scheduleSelectionSynchronization() {
        Task { @MainActor in
            await Task.yield()
            synchronizeSelectionFromViewModel()
        }
    }

    private func synchronizeSelectionFromViewModel() {
        let validIDs = Set(managedSkills.map(\.id))

        // Drop selections that no longer exist after a rescan.
        let pruned = selectedSkillIDs.intersection(validIDs)
        if pruned != selectedSkillIDs {
            selectedSkillIDs = pruned
        }

        // Adopt an external single-skill focus request (import, warning jump)
        // without clobbering a deliberate multi-selection.
        if let viewModelSkillID = viewModel.selectedSkillID, selectedSkillIDs.count <= 1 {
            if validIDs.contains(viewModelSkillID), selectedSkillIDs != [viewModelSkillID] {
                selectedSkillIDs = [viewModelSkillID]
                return
            }
            // The view model may point at a non-preferred duplicate record;
            // re-anchor to the catalog record actually shown in the list.
            if let name = viewModel.allVisibleSkillRecords.first(where: { $0.id == viewModelSkillID })?.name,
               let preferred = managedSkills.first(where: { $0.name == name }),
               selectedSkillIDs != [preferred.id] {
                selectedSkillIDs = [preferred.id]
                return
            }
        }

        ensureSelection()
    }

    private func ensureSelection() {
        guard selectedWarning == nil, selectedSkillIDs.isEmpty else { return }
        if let first = managedSkills.first {
            selectedSkillIDs = [first.id]
        }
    }

    private func skillListRow(_ skill: SkillRecord, metadata: SkillListMetadata, inactive: Bool? = nil) -> some View {
        let isActive = metadata.isAssigned
        let isInactive = inactive ?? !isActive
        let hasWarnings = metadata.hasWarnings
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: hasWarnings ? "exclamationmark.triangle.fill" : skillIcon(skill))
                .foregroundStyle(hasWarnings ? .orange : skillColor(isAssigned: isActive))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(skill.description ?? "No description")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if viewModel.importedRepository(for: skill)?.hasKnownUpdate == true {
                Text("Update")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .help("An update is available from the source repository")
            }

            if viewModel.canRenameSkill(skill) {
                Button {
                    skillEditTarget = makeSkillEditTarget(skill)
                } label: {
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                }
                .appSmallSecondaryButton()
                .opacity(hoveredSkillID == skill.id ? 1 : 0)
                .help("Edit SKILL.md")
                .animation(.easeInOut(duration: 0.15), value: hoveredSkillID == skill.id)
            }
        }
        .onHover { hovering in
            hoveredSkillID = hovering ? skill.id : nil
        }
        .padding(.vertical, 5)
        .listRowSeparator(.hidden, edges: .top)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.canDeleteSkill(skill) {
                Button(role: .destructive) {
                    skillPendingDeletion = skill
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if viewModel.isImportedSkill(skill) {
                Button {
                    skillPendingRemoval = skill
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .tint(.orange)
            }
        }
    }

    private func projectAssignmentList(for skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign this skill to parent Pi Agent sessions only when they run in the selected project. This does not make the skill default for other projects.")
                .foregroundStyle(AppTheme.mutedText)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.enabledProjects) { project in
                    ProjectAssignmentToggleRow(
                        project: project,
                        isOn: Binding(
                            get: { viewModel.skill(skill, isEnabledFor: project) },
                            set: { enabled in
                                do { try viewModel.setSkill(skill, enabled: enabled, for: project) }
                                catch { presentSkillActionError(error, skill: skill, project: project, action: enabled ? "assign this skill" : "remove this skill assignment") }
                            }
                        )
                    )

                    if project.id != viewModel.enabledProjects.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func agentAssignmentList(for skill: SkillRecord) -> some View {
        let activeAgents = viewModel.snapshot.effectiveAgents
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let activeAgentIDs = Set(activeAgents.map(\.id))
        let inactiveAgents = viewModel.allDisplayAgents
            .filter { !activeAgentIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Assign this skill only to the selected native subagents when they run. Parent Pi Agent sessions do not receive it from this setting.")
                .foregroundStyle(AppTheme.mutedText)

            VStack(alignment: .leading, spacing: 14) {
                agentAssignmentSection(
                    title: "Active",
                    agents: activeAgents,
                    skill: skill,
                    emptyText: "No active subagents."
                )

                if !inactiveAgents.isEmpty {
                    agentAssignmentSection(
                        title: "Inactive",
                        agents: inactiveAgents,
                        skill: skill,
                        emptyText: "No inactive subagents."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func agentAssignmentSection(title: String, agents: [EffectiveAgentRecord], skill: SkillRecord, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)

            if agents.isEmpty {
                nativeEmptyRow(emptyText)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(agents) { agent in
                        AgentAssignmentToggleRow(
                            agent: agent,
                            imageURL: viewModel.agentImageStore.imageURL(for: agent.name),
                            isInactive: title == "Inactive",
                            isOn: Binding(
                                get: { viewModel.skill(skill, isAssignedTo: agent) },
                                set: { enabled in
                                    do { try viewModel.setSkill(skill, enabled: enabled, for: agent) }
                                    catch { presentSkillActionError(error, skill: skill, action: enabled ? "assign this skill to agent" : "remove this skill from agent") }
                                }
                            )
                        )

                        if agent.id != agents.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func skillIcon(_ skill: SkillRecord) -> String {
        if skill.source.kind == .builtin { return "shippingbox" }
        return "wand.and.stars"
    }

    private func skillColor(isAssigned: Bool) -> Color {
        if isAssigned { return .green }
        return AppTheme.mutedText
    }

    private func warningsForSkill(_ skill: SkillRecord) -> [DiagnosticWarning] {
        viewModel.skillWarnings.filter { warning in
            warning.id == "duplicate-skill:\(skill.name)" ||
            warning.id.contains(skill.filePath) ||
            warning.message.contains("`\(skill.name)`") ||
            warning.message.contains(skill.filePath)
        }
    }

    private func duplicateSkillWarningDetails(_ warning: DiagnosticWarning) -> (name: String, paths: [String])? {
        guard warning.id.hasPrefix("duplicate-skill:") else { return nil }
        let name = String(warning.id.dropFirst("duplicate-skill:".count))
        guard let range = warning.message.range(of: " found at: ") else {
            return (name, [])
        }
        let paths = warning.message[range.upperBound...]
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (name, paths)
    }

    private func sourcePath(forAgentNamed agentName: String, projectPath: String) -> String? {
        viewModel.snapshot.effectiveAgents.first {
            $0.name == agentName && ($0.projectRoot == projectPath || $0.projectRoot == nil)
        }?.sourcePath
    }

    private func defaultSkillHelpText(for skill: SkillRecord) -> String {
        if viewModel.skillIsEnabledGlobally(skill) {
            return "This skill is injected into every parent Pi Agent session, including projectless sessions and sessions for any project. It is not copied into projects. Removing Default keeps the skill in its current folder."
        }
        if skill.source.kind == .project || skill.source.kind == .legacyProject {
            return "Make this project-local skill global by moving its skill folder to ~/.pi/agent/skills, then inject it into every parent Pi Agent session."
        }
        return "Inject this skill into every parent Pi Agent session, including projectless sessions and sessions for any project. This does not copy or assign it to project folders."
    }

    private func assignedProjectSummary(_ skill: SkillRecord) -> String {
        let projects = viewModel.assignedProjects(for: skill).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }

    private func assignedAgentSummary(_ skill: SkillRecord) -> String {
        let agents = viewModel.assignedAgents(for: skill).map(\.name)
        return agents.isEmpty ? "—" : agents.joined(separator: ", ")
    }

    private func revealSkillInFinder(_ skill: SkillRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.filePath)])
    }

    private func deleteSkill(_ skill: SkillRecord) {
        do {
            try viewModel.deleteSkill(skill)
            skillPendingDeletion = nil
        } catch {
            skillPendingDeletion = nil
            presentSkillActionError(error, skill: skill, action: "delete this skill")
        }
    }

    private func batchDeleteSkills(_ skills: [SkillRecord]) {
        var failed: [String] = []
        for skill in skills {
            do { try viewModel.deleteSkill(skill) }
            catch { failed.append(skill.name) }
        }
        skillsPendingBatchDeletion = nil
        selectedSkillIDs = []
        if !failed.isEmpty {
            NSSound.beep()
            skillActionErrorMessage = """
            \(AppBrand.displayName) could not delete \(failed.count) skill\(failed.count == 1 ? "" : "s"): \(failed.joined(separator: ", ")).

            Bundled and package skills cannot be deleted.
            """
        }
    }

    private func removeSkill(_ skill: SkillRecord) {
        do {
            try viewModel.removeSkillFromCatalog(skill)
            skillPendingRemoval = nil
        } catch {
            skillPendingRemoval = nil
            presentSkillActionError(error, skill: skill, action: "remove this skill from the catalog")
        }
    }

    private func batchRemoveSkills(_ skills: [SkillRecord]) {
        var failed: [String] = []
        for skill in skills {
            do { try viewModel.removeSkillFromCatalog(skill) }
            catch { failed.append(skill.name) }
        }
        skillsPendingBatchRemoval = nil
        selectedSkillIDs = []
        if !failed.isEmpty {
            NSSound.beep()
            skillActionErrorMessage = """
            \(AppBrand.displayName) could not remove \(failed.count) skill\(failed.count == 1 ? "" : "s"): \(failed.joined(separator: ", ")).

            Only imported skills can be removed from the catalog.
            """
        }
    }

    @ViewBuilder
    private func batchSelectionDetail(_ skills: [SkillRecord]) -> some View {
        let deletable = skills.filter { viewModel.canDeleteSkill($0) }
        let importable = skills.filter { viewModel.isImportedSkill($0) }
        AppCard(title: "\(skills.count) Skills Selected") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cmd- or Shift-click rows to adjust the selection. Right-click the list — or use the button below — to act on every selected skill at once.")
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skills, id: \.id) { skill in
                        HStack(spacing: 10) {
                            Image(systemName: skillIcon(skill))
                                .foregroundStyle(AppTheme.mutedText)
                                .frame(width: 18)
                            Text(skill.name)
                                .font(.callout.weight(.medium))
                            if !viewModel.canDeleteSkill(skill) {
                                Text("Protected")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                HStack(spacing: 10) {
                    if !importable.isEmpty {
                        Button("Remove \(importable.count) from Catalog…") {
                            skillsPendingBatchRemoval = importable
                        }
                        .appSecondaryButton()
                    }

                    Button("Delete \(deletable.count) Skill\(deletable.count == 1 ? "" : "s")…") {
                        skillsPendingBatchDeletion = deletable
                    }
                    .appDestructiveButton()
                    .disabled(deletable.isEmpty)
                }

                if !importable.isEmpty {
                    Text("Remove un-imports a skill (its files and any Git clone are kept). Delete moves the skill folder to the Trash.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if deletable.count != skills.count {
                    Text("Bundled and package skills are protected and will not be deleted.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private func makeSkillEditTarget(_ skill: SkillRecord) -> MarkdownFileEditTarget {
        MarkdownFileEditTarget(
            title: "Edit \(skill.name)",
            path: skill.filePath,
            note: "Editing the raw SKILL.md. Changes apply after you save."
        )
    }

    private func createNewSkill() {
        newSkillDraft = viewModel.makeNewLibrarySkillDraft()
    }

    private func beginSkillImport() {
        isImportSheetPresented = true
    }

    private func importSummary(for result: SkillImportResult) -> String {
        var parts: [String] = []
        if !result.importedNames.isEmpty {
            parts.append("Imported \(result.importedNames.count) skill\(result.importedNames.count == 1 ? "" : "s"): \(result.importedNames.joined(separator: ", ")).")
        }
        if !result.skippedNames.isEmpty {
            parts.append("Skipped \(result.skippedNames.count) existing skill\(result.skippedNames.count == 1 ? "" : "s"): \(result.skippedNames.joined(separator: ", ")).")
        }
        return parts.isEmpty ? "No skills were imported." : parts.joined(separator: "\n\n")
    }

    private func presentSkillActionError(_ error: Error, skill: SkillRecord, project: DiscoveredProject? = nil, action: String) {
        NSSound.beep()
        let target = project.map { "project \($0.name)" } ?? "global skills"
        let conflictPath = project.map { "\($0.path)/.pi/skills/\(skill.name)" } ?? "~/.pi/agent/skills/\(skill.name)"
        skillActionErrorMessage = """
        \(AppBrand.displayName) could not \(action) for "\(skill.name)" in \(target).

        If a skill with this name already exists at \(conflictPath), \(AppBrand.displayName) will not overwrite it automatically. Remove or rename the existing skill, then try again.

        \(error.localizedDescription)
        """
    }

}

private struct AgentAssignmentToggleRow: View {
    let agent: EffectiveAgentRecord
    let imageURL: URL?
    let isInactive: Bool
    @Binding var isOn: Bool

    /// Optimistic value held from a tap until the async snapshot refresh makes
    /// the external `isOn` catch up. Without it the checkbox visibly snaps back
    /// after each tap, because skill→agent assignment now reconciles in the
    /// background instead of via a blocking rescan.
    @State private var optimisticValue: Bool?

    private var displayedIsOn: Bool { optimisticValue ?? isOn }

    var body: some View {
        let toggleBinding = Binding(
            get: { displayedIsOn },
            set: { newValue in
                optimisticValue = newValue
                isOn = newValue
            }
        )

        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: toggleBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agentIconFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(displayedIsOn ? AppTheme.accentSelectionStroke : AppTheme.contentStroke, lineWidth: 1)
                    }

                if let nsImage = AgentImageLoader.image(at: imageURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: SidebarItem.agents.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(displayedIsOn ? AppTheme.accentForeground : AppTheme.mutedText)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.body.weight(.semibold))
                Text(agentSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleBinding.wrappedValue.toggle()
        }
        .onChange(of: isOn) { _, _ in
            // External state has caught up — drop the optimistic override so
            // the snapshot value is authoritative again.
            optimisticValue = nil
        }
    }

    private var agentIconFill: LinearGradient {
        LinearGradient(
            colors: displayedIsOn
                ? [AppTheme.brandAccentBright, AppTheme.brandAccent]
                : [AppTheme.contentFill, AppTheme.contentSubtleFill],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var agentSubtitle: String {
        let whenToUse = agent.resolved.whenToUse?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whenToUse, !whenToUse.isEmpty {
            return whenToUse
        }

        let description = agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "No routing guidance set." : description
    }
}
