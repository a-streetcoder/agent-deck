import AppKit
import SwiftUI

struct SkillsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skill assignment")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Catalog", "Agent Deck scans skills from bundled, user, project, compatibility, package, and existing library/import locations.")
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

struct SkillsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var selectedSkillID: SkillRecord.ID?
    @State private var isImportSheetPresented = false
    @State private var shouldPromptForImportSource = false
    @State private var importSourceURL: URL?
    @State private var importCandidates: [ExternalSkillCandidate] = []
    @State private var selectedImportCandidateIDs: Set<String> = []
    @State private var importErrorMessage: String?
    @State private var importSummaryMessage: String?
    @State private var skillActionErrorMessage: String?
    @State private var skillPendingDeletion: SkillRecord?

    var body: some View {
        HSplitView {
            skillLibraryContent
                .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

            AppPage(selectedSkill?.name ?? "Skill Details", subtitle: selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.snapshot.projectRoot) }) {
                skillDetailContent
            }
        }
        .onAppear { synchronizeSelectionFromViewModel() }
        .onChange(of: viewModel.allVisibleSkillRecords) { _, _ in synchronizeSelectionFromViewModel() }
        .onChange(of: viewModel.selectedSkillID) { _, _ in synchronizeSelectionFromViewModel() }
        .onChange(of: selectedSkillID) { _, id in
            guard viewModel.selectedSkillID != id else { return }
            viewModel.selectedSkillID = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportSkillsRequested)) { _ in
            beginSkillImport()
        }
        .sheet(isPresented: $isImportSheetPresented) {
            importSkillsSheet
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
        List(selection: skillSelection) {
            if !viewModel.skillReferenceWarnings.isEmpty || !viewModel.skillWarnings.isEmpty {
                appListSection("Warnings", info: "Skill issues that need attention.") {
                    ForEach(viewModel.skillReferenceWarnings) { warning in
                        skillWarningRow(warning)
                    }
                    ForEach(viewModel.skillWarnings) { warning in
                        diagnosticWarningRow(warning)
                    }
                }
            }

            if selectedProject != nil {
                appListSection("Active") {
                    if activeSkills.isEmpty {
                        nativeEmptyRow("No skills are assigned for this project.")
                    }
                    ForEach(activeSkills, id: \.name) { skill in
                        skillListRow(skill, inactive: false)
                            .tag(skill.id)
                    }
                }

                if !catalogSkills.isEmpty {
                    catalogSection(skills: catalogSkills)
                }
            } else {
                appListSection("Default Skills", info: "Default skills are passed to every parent Pi Agent session, including project and projectless sessions.") {
                    if globalSkills.isEmpty {
                        nativeEmptyRow("No default skills.")
                    }
                    ForEach(globalSkills, id: \.name) { skill in
                        skillListRow(skill, inactive: false)
                            .tag(skill.id)
                    }
                }

                if !catalogSkills.isEmpty {
                    catalogSection(skills: catalogSkills)
                }
            }
        }
        .appResourceListStyle()
    }

    private func catalogSection(skills: [SkillRecord]) -> some View {
        appListSection("Catalog", info: "Catalog skills are not injected until marked Default, assigned to a project, or assigned to an agent.") {
            ForEach(skills, id: \.name) { skill in
                skillListRow(skill, inactive: true)
                    .tag(skill.id)
            }
        }
    }

    private func skillWarningRow(_ warning: SkillReferenceWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(warning.missingSkill)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .lineLimit(1)
                Text("Referenced by \(warning.agentName) in \(warning.project.name)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text("Missing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 6)
    }

    private func diagnosticWarningRow(_ warning: DiagnosticWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(warning.message)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var skillDetailContent: some View {
        if let skill = selectedSkill {
            if skill.source.kind == .package {
                AppCard(title: "Package Skill") {
                    Text("This skill is provided by an installed package. It is not injected unless assigned as Default, assigned to a project, or assigned to an agent.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            AppCard(title: "Default Skill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.skillIsEnabledGlobally(skill) ? "This skill is passed to every parent Pi Agent session." : "Make this skill available by default in every parent Pi Agent session.")
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.skillIsEnabledGlobally(skill) {
                            Button("Remove Default") {
                                do { try viewModel.disableSkillGlobally(skill) }
                                catch { presentSkillActionError(error, skill: skill, action: "disable global visibility") }
                            }
                        } else {
                            Button("Make Default") {
                                do { try viewModel.enableSkillGlobally(skill) }
                                catch { presentSkillActionError(error, skill: skill, action: "enable global visibility") }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

            AppCard(title: "Project Assignment") {
                projectAssignmentList(for: skill)
            }

            AppCard(title: "Agent Assignment") {
                agentAssignmentList(for: skill)
            }

            AppCard(title: "Definition") {
                MarkdownDocumentView(source: skill.body, minimumHeight: 220)
            }

            AppCard(title: "Manage \(skill.name)") {
                AppKeyValueList(rows: [
                    ("Source", skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                    ("Default", viewModel.skillIsEnabledGlobally(skill) ? "Yes" : "No"),
                    ("Assigned Projects", assignedProjectSummary(skill)),
                    ("Assigned Agents", assignedAgentSummary(skill)),
                    ("Path", skill.filePath)
                ])
            }
        } else {
            AppCard {
                ContentUnavailableView("No Skill Selected", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
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
        guard selectedSkillID == nil || !managedSkills.contains(where: { $0.id == selectedSkillID }) else { return }
        selectedSkillID = managedSkills.first?.id
    }

    private func skillListRow(_ skill: SkillRecord, inactive: Bool? = nil) -> some View {
        let isActive = skillHasAnyAssignment(skill)
        let isInactive = inactive ?? !isActive
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: skillIcon(skill))
                .foregroundStyle(skillColor(skill))
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
        }
        .padding(.vertical, 5)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
        .contextMenu {
            Button {
                revealSkillInFinder(skill)
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }

            Divider()

            Button(role: .destructive) {
                skillPendingDeletion = skill
            } label: {
                Label("Delete Skill", systemImage: "trash")
            }
            .disabled(!viewModel.canDeleteSkill(skill))
        }
    }

    private func nativeEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(AppTheme.mutedText)
            .padding(.vertical, 4)
            .selectionDisabled()
            .listRowSeparator(.hidden)
    }

    private func projectAssignmentList(for skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each project whose parent Pi Agent sessions should receive this skill via --skill.")
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each native agent that should receive this skill via --skill when it runs.")
                .foregroundStyle(AppTheme.mutedText)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.snapshot.effectiveAgents) { agent in
                    AgentAssignmentToggleRow(
                        agent: agent,
                        isOn: Binding(
                            get: { viewModel.skill(skill, isAssignedTo: agent) },
                            set: { enabled in
                                do { try viewModel.setSkill(skill, enabled: enabled, for: agent) }
                                catch { presentSkillActionError(error, skill: skill, action: enabled ? "assign this skill to agent" : "remove this skill from agent") }
                            }
                        )
                    )

                    if agent.id != viewModel.snapshot.effectiveAgents.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func skillIcon(_ skill: SkillRecord) -> String {
        if skill.source.kind == .builtin { return "shippingbox" }
        return "wand.and.stars"
    }

    private func skillColor(_ skill: SkillRecord) -> Color {
        if skillHasAnyAssignment(skill) { return .green }
        return AppTheme.mutedText
    }

    private func skillHasAnyAssignment(_ skill: SkillRecord) -> Bool {
        viewModel.skillIsEnabledGlobally(skill) ||
        !viewModel.assignedProjects(for: skill).isEmpty ||
        !viewModel.assignedAgents(for: skill).isEmpty
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
        existingExternalSkillPaths.contains(URL(fileURLWithPath: candidate.sourceRootPath).standardizedFileURL.path)
    }

    private var importableCandidateIDs: Set<String> {
        Set(importCandidates.filter { !candidateAlreadyImported($0) }.map(\.id))
    }

    private var allImportableCandidatesSelected: Bool {
        !importableCandidateIDs.isEmpty && importableCandidateIDs.isSubset(of: selectedImportCandidateIDs)
    }

    @ViewBuilder
    private var importSkillsSheet: some View {
        NavigationStack {
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
                            Text("Select one or more skill roots to add to the \(AppBrand.displayName) skill catalog. Files stay in place and are passed to Pi by path.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                            Spacer()
                            Button(allImportableCandidatesSelected ? "Deselect All" : "Select All") {
                                if allImportableCandidatesSelected {
                                    selectedImportCandidateIDs.removeAll()
                                } else {
                                    selectedImportCandidateIDs = importableCandidateIDs
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Clear") {
                                selectedImportCandidateIDs.removeAll()
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedImportCandidateIDs.isEmpty)
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(importCandidates) { candidate in
                                    let alreadyImported = candidateAlreadyImported(candidate)
                                    Toggle(isOn: Binding(
                                        get: { selectedImportCandidateIDs.contains(candidate.id) },
                                        set: { isSelected in
                                            guard !alreadyImported else { return }
                                            if isSelected { selectedImportCandidateIDs.insert(candidate.id) }
                                            else { selectedImportCandidateIDs.remove(candidate.id) }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(candidate.name)
                                                    .font(.body.weight(.semibold))
                                                if alreadyImported {
                                                    AppLabelTag(text: "Already Imported", color: .gray)
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
                                    .disabled(alreadyImported)
                                    if candidate.id != importCandidates.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 280)
                    }
                }

                Spacer()
            }
            .padding(AppTheme.pagePadding)
            .frame(minWidth: 760, minHeight: 680, alignment: .topLeading)
            .navigationTitle("Import External Skills")
            .task(id: shouldPromptForImportSource) {
                guard shouldPromptForImportSource else { return }
                shouldPromptForImportSource = false
                DispatchQueue.main.async {
                    chooseDifferentImportFolder()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isImportSheetPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importSelectedSkills()
                    }
                    .disabled(selectedImportCandidateIDs.isEmpty)
                }
            }
        }
    }

    private func beginSkillImport() {
        importErrorMessage = nil
        importSummaryMessage = nil
        importCandidates = []
        selectedImportCandidateIDs.removeAll()
        importSourceURL = nil
        shouldPromptForImportSource = true
        isImportSheetPresented = true
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
        importErrorMessage = nil
        importSummaryMessage = nil
        importSourceURL = url

        var candidates = viewModel.discoverImportableSkills(in: url)
        if candidates.isEmpty, let directCandidate = viewModel.externalSkillCandidate(at: url) {
            candidates = [directCandidate]
        }

        guard !candidates.isEmpty else {
            importCandidates = []
            selectedImportCandidateIDs.removeAll()
            importErrorMessage = "No importable skill folders were found. Choose either a skill root containing SKILL.md or a folder whose direct child folders contain SKILL.md files."
            return
        }

        importCandidates = candidates
        selectedImportCandidateIDs = Set(candidates.filter { !candidateAlreadyImported($0) }.map(\.id))

        if !isImportSheetPresented {
            DispatchQueue.main.async {
                isImportSheetPresented = true
            }
        }
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
}

private struct AgentAssignmentToggleRow: View {
    let agent: EffectiveAgentRecord
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
                Image(systemName: SidebarItem.agents.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? AppTheme.accentForeground : AppTheme.mutedText)
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
