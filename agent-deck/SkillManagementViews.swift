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
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var selectedSkillID: SkillRecord.ID?
    @State private var selectedWarning: SkillWarningSelection?
    @State private var isImportSheetPresented = false
    @State private var shouldPromptForImportSource = false
    @State private var importSourceURL: URL?
    @State private var importCandidates: [ExternalSkillCandidate] = []
    @State private var importSearchText = ""
    @State private var selectedImportCandidateIDs: Set<String> = []
    @State private var importErrorMessage: String?
    @State private var importSummaryMessage: String?
    @State private var isScanningImportSource = false
    @State private var importScanProgress: ExternalSkillDiscovery.Progress?
    @State private var importScanTask: Task<Void, Never>?
    @State private var skillActionErrorMessage: String?
    @State private var skillPendingDeletion: SkillRecord?
    @State private var skillPendingRename: SkillRecord?
    @State private var hoveredSkillID: SkillRecord.ID?
    @State private var skillEditTarget: MarkdownFileEditTarget?
    @State private var newSkillDraft: NewSkillDraft?

    var body: some View {
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
                    selectedWarning?.title ?? selectedSkill?.name ?? "Skill Details",
                    subtitle: selectedWarning?.subtitle ?? selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.snapshot.projectRoot) }
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
        .onChange(of: selectedSkillID) { _, id in
            guard viewModel.selectedSkillID != id else { return }
            if id != nil {
                selectedWarning = nil
            }
            viewModel.selectedSkillID = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportSkillsRequested)) { _ in
            beginSkillImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewSkillRequested)) { _ in
            createNewSkill()
        }
        .sheet(isPresented: $isImportSheetPresented) {
            importSkillsSheet
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
        .alert("Skill Import", isPresented: Binding(
            get: { importErrorMessage != nil || importSummaryMessage != nil },
            set: { if !$0 { importErrorMessage = nil; importSummaryMessage = nil } }
        )) {
            Button("OK") {
                importErrorMessage = nil
                importSummaryMessage = nil
            }
        } message: {
            Text(importErrorMessage ?? importSummaryMessage ?? "")
        }
        .alert("Skill Assignment", isPresented: Binding(
            get: { skillActionErrorMessage != nil },
            set: { if !$0 { skillActionErrorMessage = nil } }
        )) {
            Button("OK") {
                skillActionErrorMessage = nil
            }
        } message: {
            Text(skillActionErrorMessage ?? "")
        }
        .alert("Delete Skill?", isPresented: Binding(
            get: { skillPendingDeletion != nil },
            set: { if !$0 { skillPendingDeletion = nil } }
        ), presenting: skillPendingDeletion) { skill in
            Button("Move to Trash", role: .destructive) {
                deleteSkill(skill)
            }
            Button("Cancel", role: .cancel) {
                skillPendingDeletion = nil
            }
        } message: { skill in
            Text("Move \"\(skill.name)\" to the Trash and remove its Default, project, and agent assignments?")
        }
    }

    @ViewBuilder
    private var skillLibraryContent: some View {
        // Precomputed in AppViewModel, rebuilt only on data rescans — was
        // O(skills × warnings/projects/agents) on every body eval.
        let metadataByID = viewModel.cachedSkillMetadataByID
        List(selection: skillSelection) {
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
            selectedSkillID = nil
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
            selectedSkillID = nil
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

    private var selectedSkill: SkillRecord? {
        guard selectedWarning == nil else { return nil }
        guard let selectedSkillID else { return managedSkills.first }
        return managedSkills.first { $0.id == selectedSkillID } ?? managedSkills.first
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

    private var skillSelection: Binding<SkillRecord.ID?> {
        Binding(
            get: { selectedSkillID },
            set: { selectedSkillID = $0 }
        )
    }

    private func scheduleSelectionSynchronization() {
        Task { @MainActor in
            await Task.yield()
            synchronizeSelectionFromViewModel()
        }
    }

    private func synchronizeSelectionFromViewModel() {
        guard let viewModelSkillID = viewModel.selectedSkillID else {
            ensureSelection()
            return
        }

        if managedSkills.contains(where: { $0.id == viewModelSkillID }) {
            selectedSkillID = viewModelSkillID
            return
        }

        if let selectedSkillName = viewModel.allVisibleSkillRecords.first(where: { $0.id == viewModelSkillID })?.name,
           let preferredSkill = managedSkills.first(where: { $0.name == selectedSkillName }) {
            selectedSkillID = preferredSkill.id
            return
        }

        ensureSelection()
    }

    private func ensureSelection() {
        guard selectedWarning == nil else { return }
        guard selectedSkillID == nil || !managedSkills.contains(where: { $0.id == selectedSkillID }) else { return }
        selectedSkillID = managedSkills.first?.id
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
            Button(role: .destructive) {
                skillPendingDeletion = skill
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!viewModel.canDeleteSkill(skill))
        }
        .contextMenu {
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

            Divider()

            Button(role: .destructive) {
                skillPendingDeletion = skill
            } label: {
                Label("Delete Skill", systemImage: "trash")
            }
            .disabled(!viewModel.canDeleteSkill(skill))
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
                            bundledImageName: bundledAvatarName(for: agent),
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

    private var existingExternalSkillPaths: Set<String> {
        viewModel.appSettings.externalSkillPaths
    }

    private func candidateAlreadyImported(_ candidate: ExternalSkillCandidate) -> Bool {
        // Both sides are already standardized paths — `sourceRootPath` comes
        // from `URL.standardizedFileURL` and stored paths are normalized on
        // write — so a direct set lookup is correct and avoids rebuilding a URL
        // for every candidate on every search keystroke.
        existingExternalSkillPaths.contains(candidate.sourceRootPath)
    }

    private var importableCandidates: [ExternalSkillCandidate] {
        importCandidates.filter { !candidateAlreadyImported($0) }
    }

    private var hiddenAlreadyImportedCandidateCount: Int {
        importCandidates.count - importableCandidates.count
    }

    private var filteredImportCandidates: [ExternalSkillCandidate] {
        let query = importSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return importableCandidates }
        return importableCandidates
            .compactMap { candidate -> (ExternalSkillCandidate, Int)? in
                guard let score = importSearchScore(candidate, query: query) else { return nil }
                return (candidate, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                let nameOrder = lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.0.sourceRootPath < rhs.0.sourceRootPath
            }
            .map(\.0)
    }

    private var visibleImportableCandidateIDs: Set<String> {
        Set(filteredImportCandidates.map(\.id))
    }

    private var allVisibleImportableCandidatesSelected: Bool {
        !visibleImportableCandidateIDs.isEmpty && visibleImportableCandidateIDs.isSubset(of: selectedImportCandidateIDs)
    }

    private var importSearchIsActive: Bool {
        !importSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var importSelectionButtonTitle: String {
        if importSearchIsActive {
            return allVisibleImportableCandidatesSelected ? "Deselect Visible" : "Select Visible"
        }
        return allVisibleImportableCandidatesSelected ? "Deselect All" : "Select All"
    }

    private func importSearchScore(_ candidate: ExternalSkillCandidate, query: String) -> Int? {
        let queryTokens = skillSearchTokens(query)
        guard !queryTokens.isEmpty else { return 0 }

        let name = normalizedSkillSearchText(candidate.name)
        let description = normalizedSkillSearchText(candidate.description ?? "")
        let path = normalizedSkillSearchText(candidate.sourceRootPath)
        let compactName = compactSkillSearchText(candidate.name)
        let compactQuery = compactSkillSearchText(query)
        let searchable = [name, description, path].joined(separator: " ")

        guard queryTokens.allSatisfy({ token in
            searchable.contains(token) || compactName.contains(token) || compactName.contains(compactSkillSearchText(token))
        }) else {
            return nil
        }

        var score = 0
        if name == normalizedSkillSearchText(query) { score += 120 }
        if compactName == compactQuery { score += 110 }
        if name.hasPrefix(normalizedSkillSearchText(query)) || compactName.hasPrefix(compactQuery) { score += 80 }

        for token in queryTokens {
            if name.split(separator: " ").contains(Substring(token)) { score += 30 }
            else if name.contains(token) || compactName.contains(token) { score += 20 }
            else if description.contains(token) { score += 10 }
            else if path.contains(token) { score += 4 }
        }

        return score
    }

    private func skillSearchTokens(_ text: String) -> [String] {
        normalizedSkillSearchText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !["skill", "skills", "native", "claude", "code"].contains($0) }
    }

    private func normalizedSkillSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactSkillSearchText(_ text: String) -> String {
        normalizedSkillSearchText(text).replacingOccurrences(of: " ", with: "")
    }

    @ViewBuilder
    private var importSkillsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Skills")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text("Add external skill folders to the \(AppBrand.displayName) catalog. Files stay in place.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                AppCard(title: "Source") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(importSourceURL?.path ?? "No source selected")
                            .textSelection(.enabled)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                        Button("Choose Different Folder") {
                            DispatchQueue.main.async {
                                chooseDifferentImportFolder()
                            }
                        }
                    }
                }

                AppCard(title: "Skills") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Select one or more discovered skill roots to add to the \(AppBrand.displayName) skill catalog. Files stay in place and selected roots are passed to Pi by path.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                            Spacer()
                            Button(importSelectionButtonTitle) {
                                if allVisibleImportableCandidatesSelected {
                                    selectedImportCandidateIDs.subtract(visibleImportableCandidateIDs)
                                } else {
                                    selectedImportCandidateIDs.formUnion(visibleImportableCandidateIDs)
                                }
                            }
                            .buttonStyle(.glass)
                            .disabled(isScanningImportSource || visibleImportableCandidateIDs.isEmpty)

                            Button("Clear") {
                                selectedImportCandidateIDs.removeAll()
                            }
                            .buttonStyle(.glass)
                            .disabled(isScanningImportSource || selectedImportCandidateIDs.isEmpty)
                        }

                        if isScanningImportSource {
                            importScanningView
                        } else {
                            importCandidateListView
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    importScanTask?.cancel()
                    isImportSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    importSelectedSkills()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isScanningImportSource || selectedImportCandidateIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 740)
        .task(id: shouldPromptForImportSource) {
            guard shouldPromptForImportSource else { return }
            shouldPromptForImportSource = false
            DispatchQueue.main.async {
                chooseDifferentImportFolder()
            }
        }
        .onDisappear {
            // Stop any in-flight folder walk when the sheet closes.
            importScanTask?.cancel()
            importScanTask = nil
        }
    }

    /// Shown in place of the candidate list while the chosen folder is being
    /// walked off the main actor. A large skills folder can take a while; the
    /// live count makes it clear the app is working rather than hung.
    private var importScanningView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            VStack(spacing: 4) {
                Text("Scanning \(importSourceURL?.lastPathComponent ?? "folder") for skills…")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if let progress = importScanProgress {
                    Text("\(progress.directoriesScanned) folder\(progress.directoriesScanned == 1 ? "" : "s") scanned • \(progress.skillsFound) skill\(progress.skillsFound == 1 ? "" : "s") found")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    @ViewBuilder
    private var importCandidateListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.mutedText)
                TextField("Search skills by name, description, or path", text: $importSearchText)
                    .textFieldStyle(.plain)
                if importSearchIsActive {
                    Button {
                        importSearchText = ""
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

            Text("Showing \(filteredImportCandidates.count) of \(importableCandidates.count) importable skill\(importableCandidates.count == 1 ? "" : "s")\(hiddenAlreadyImportedCandidateCount == 0 ? "" : " • \(hiddenAlreadyImportedCandidateCount) already imported hidden")\(selectedImportCandidateIDs.isEmpty ? "" : " • \(selectedImportCandidateIDs.count) selected")")
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredImportCandidates.isEmpty {
                        Text(importSearchIsActive ? "No importable skills match your search." : "No new importable skills were found. Already-imported skills are hidden.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    ForEach(filteredImportCandidates) { candidate in
                        Toggle(isOn: Binding(
                            get: { selectedImportCandidateIDs.contains(candidate.id) },
                            set: { isSelected in
                                if isSelected { selectedImportCandidateIDs.insert(candidate.id) }
                                else { selectedImportCandidateIDs.remove(candidate.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(candidate.name)
                                        .font(.body.weight(.semibold))
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

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Path")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AppTheme.mutedText)
                                    Text(candidate.sourceRootPath)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(AppTheme.mutedText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                        .toggleStyle(.checkbox)
                        if candidate.id != filteredImportCandidates.last?.id {
                            Divider()
                        }
                    }
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
        importScanTask?.cancel()
        importScanTask = nil
        importErrorMessage = nil
        importSummaryMessage = nil
        importCandidates = []
        importSearchText = ""
        selectedImportCandidateIDs.removeAll()
        importSourceURL = nil
        isScanningImportSource = false
        importScanProgress = nil

        // Reuse the configured or last-used skills folder instead of prompting
        // every time. The import sheet still offers "Choose Different Folder".
        if let remembered = viewModel.rememberedSkillsImportDirectoryURL {
            shouldPromptForImportSource = false
            isImportSheetPresented = true
            loadImportCandidates(from: remembered)
        } else {
            shouldPromptForImportSource = true
            isImportSheetPresented = true
        }
    }

    private func chooseDifferentImportFolder() {
        viewModel.chooseExternalSkillsDirectory(startingAt: importSourceURL) { url in
            guard let url else { return }
            DispatchQueue.main.async {
                loadImportCandidates(from: url)
            }
        }
    }

    private func loadImportCandidates(from url: URL) {
        // Cancel any in-flight scan — e.g. the user picked a new folder while
        // the previous (possibly huge) folder was still being walked.
        importScanTask?.cancel()
        importErrorMessage = nil
        importSummaryMessage = nil
        importSearchText = ""
        importSourceURL = url
        importCandidates = []
        selectedImportCandidateIDs.removeAll()
        importScanProgress = nil
        isScanningImportSource = true

        if !isImportSheetPresented {
            isImportSheetPresented = true
        }

        // Discovery walks the folder tree off the main actor; the UI stays
        // responsive and shows a live progress count while it runs.
        importScanTask = Task { @MainActor in
            for await event in ExternalSkillDiscovery.scan(root: url) {
                if Task.isCancelled { break }
                switch event {
                case let .progress(progress):
                    importScanProgress = progress
                case let .finished(candidates):
                    applyDiscoveredImportCandidates(candidates)
                }
            }
        }
    }

    private func applyDiscoveredImportCandidates(_ candidates: [ExternalSkillCandidate]) {
        isScanningImportSource = false
        importScanProgress = nil
        importCandidates = candidates

        guard !candidates.isEmpty else {
            selectedImportCandidateIDs.removeAll()
            importErrorMessage = "No importable skill folders were found. Choose either a skill root containing SKILL.md or a folder that contains skill roots somewhere below it."
            return
        }

        selectedImportCandidateIDs = Set(candidates.filter { !candidateAlreadyImported($0) }.map(\.id))
    }

    private func importSelectedSkills() {
        let selectedCandidates = importCandidates.filter { selectedImportCandidateIDs.contains($0.id) }
        guard !selectedCandidates.isEmpty else { return }
        do {
            let result = try viewModel.importExternalSkills(selectedCandidates)
            isImportSheetPresented = false
            var summaryParts: [String] = []
            if !result.importedNames.isEmpty {
                summaryParts.append("Imported \(result.importedNames.count) skill\(result.importedNames.count == 1 ? "" : "s"): \(result.importedNames.joined(separator: ", ")).")
            }
            if !result.skippedNames.isEmpty {
                summaryParts.append("Skipped \(result.skippedNames.count) existing skill\(result.skippedNames.count == 1 ? "" : "s"): \(result.skippedNames.joined(separator: ", ")).")
            }
            importSummaryMessage = summaryParts.joined(separator: "\n\n")
        } catch {
            importErrorMessage = error.localizedDescription
        }
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

    private func bundledAvatarName(for agent: EffectiveAgentRecord) -> String? {
        guard agent.builtin != nil else { return nil }
        switch agent.name {
        case "coder", "explorer", "planner", "reviewer":
            return "agent-avatar-\(agent.name)"
        default:
            return nil
        }
    }
}

private struct AgentAssignmentToggleRow: View {
    let agent: EffectiveAgentRecord
    let imageURL: URL?
    let bundledImageName: String?
    let isInactive: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agentIconFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isOn ? AppTheme.accentSelectionStroke : AppTheme.contentStroke, lineWidth: 1)
                    }

                if let nsImage = AgentImageLoader.image(at: imageURL, bundledImageName: bundledImageName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: SidebarItem.agents.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isOn ? AppTheme.accentForeground : AppTheme.mutedText)
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
            isOn.toggle()
        }
    }

    private var agentIconFill: LinearGradient {
        LinearGradient(
            colors: isOn
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
