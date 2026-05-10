import AppKit
import SwiftUI

struct SkillsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skill visibility")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Library", "Central storage in ~/.pi/agent/skill-library. Pi does not load these until linked.")
                infoRow("Global", "Linked in ~/.pi/agent/skills. Pi loads these in every project.")
                infoRow("Project", "Linked or stored in PROJECT/.pi/skills. Pi loads these only for that project.")
                infoRow("Package", "Provided by installed packages. Treat as read-only unless imported later.")
            }

            Text("Use Global Visibility and Project Assignment in the right column to manage where library skills are loaded.")
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

struct SkillsProjectRecapPanel: View {
    let project: DiscoveredProject
    let globalSkills: [SkillRecord]
    let projectSkills: [SkillRecord]
    let packageSkills: [SkillRecord]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi Skill Recap")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close recap")
                .accessibilityLabel("Close recap")
            }
            .padding(16)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These are the skills Pi will effectively see when launched in this project: global skills, project-assigned library skills, and package-provided skills.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    recapSection("Global", skills: globalSkills, color: .blue, emptyText: "No global skills")
                    recapSection("Project", skills: projectSkills, color: .green, emptyText: "No project-assigned skills")
                    recapSection("Package", skills: packageSkills, color: .orange, emptyText: "No package skills")
                }
                .padding(16)
            }
        }
        .background(AppTheme.contentSubtleFill)
    }

    private func recapSection(_ title: String, skills: [SkillRecord], color: Color, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWidth(.expanded)
                Spacer()
            }

            if skills.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skills, id: \.name) { skill in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: title == "Package" ? "shippingbox" : "wand.and.stars")
                                .foregroundStyle(color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.subheadline.weight(.semibold))
                                if let description = skill.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }
}

struct SkillsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isRecapPresented: Bool
    @Binding var searchText: String
    @State private var selectedSkillID: SkillRecord.ID?
    @State private var isImportSheetPresented = false
    @State private var shouldPromptForImportSource = false
    @State private var importSourceURL: URL?
    @State private var importCandidates: [ExternalSkillCandidate] = []
    @State private var selectedImportCandidateIDs: Set<String> = []
    @State private var importMode: SkillLibraryImportMode = .symlink
    @State private var replaceExistingImports = false
    @State private var importErrorMessage: String?
    @State private var importSummaryMessage: String?
    @State private var skillActionErrorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                skillLibraryContent
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

                AppPage(selectedSkill?.name ?? "Skill Details", subtitle: selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.snapshot.projectRoot) }) {
                    skillDetailContent
                }
            }

            if isRecapPresented, let selectedProject {
                Divider()
                SkillsProjectRecapPanel(
                    project: selectedProject,
                    globalSkills: globalSkills,
                    projectSkills: projectAssignedSkills,
                    packageSkills: packageSkills,
                    onClose: { isRecapPresented = false }
                )
                .frame(width: 380)
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
    }

    @ViewBuilder
    private var skillLibraryContent: some View {
        List(selection: skillSelection) {
            if selectedProject != nil {
                appListSection("Active") {
                    if activeSkills.isEmpty {
                        nativeEmptyRow("No skills are active for this project.")
                    }
                    ForEach(activeSkills, id: \.name) { skill in
                        skillListRow(skill, inactive: false)
                            .tag(skill.id)
                    }
                }

                if !inactiveLibrarySkills.isEmpty {
                    appListSection("Library Skills", info: "Library skills are centrally stored and only become active when assigned to this project or enabled globally.") {
                        ForEach(inactiveLibrarySkills, id: \.name) { skill in
                            skillListRow(skill, inactive: true)
                                .tag(skill.id)
                        }
                    }
                }
            } else {
                appListSection("Global Skills", info: "Select a project to see exactly which skills are active there and to manage project assignment.") {
                    if globalSkills.isEmpty {
                        nativeEmptyRow("No global skills.")
                    }
                    ForEach(globalSkills, id: \.name) { skill in
                        skillListRow(skill, inactive: false)
                            .tag(skill.id)
                    }
                }

                if !librarySkills.isEmpty {
                    appListSection("Library Skills") {
                        ForEach(librarySkills, id: \.name) { skill in
                            skillListRow(skill, inactive: false)
                                .tag(skill.id)
                        }
                    }
                }
            }

            if !packageSkills.isEmpty {
                appListSection("Package Skills", info: "Package skills are active by default when their package is discovered. They are package-managed, so \(AppBrand.displayName) does not assign or unlink them per project.") {
                    ForEach(packageSkills, id: \.name) { skill in
                        skillListRow(skill, inactive: false)
                            .tag(skill.id)
                    }
                }
            }
        }
        .appResourceListStyle()
    }

    @ViewBuilder
    private var skillDetailContent: some View {
        if let skill = selectedSkill {
            if skill.source.kind == .package {
                AppCard(title: "Package Skill") {
                    Text("This skill is provided by an installed package and is active through Pi/package discovery. Project assignment is disabled to avoid copying or modifying package-managed content.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                AppCard(title: "Global Visibility") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.skillIsEnabledGlobally(skill) ? "This skill is active in every project." : "Make this skill active everywhere instead of only selected projects.")
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.skillIsEnabledGlobally(skill) {
                            Button("Disable Globally") {
                                do { try viewModel.disableSkillGlobally(skill) }
                                catch { presentSkillActionError(error, skill: skill, action: "disable global visibility") }
                            }
                        } else {
                            Button("Enable Globally") {
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
            }

            AppCard(title: "Definition") {
                MarkdownDocumentView(source: skill.body, minimumHeight: 220)
            }

            AppCard(title: "Manage \(skill.name)") {
                AppKeyValueList(rows: [
                    ("Source", skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                    ("Active Globally", viewModel.skillIsEnabledGlobally(skill) ? "Yes" : "No"),
                    ("Assigned Projects", assignedProjectSummary(skill)),
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
        return globalSkills + packageSkills
    }

    private var globalSkills: [SkillRecord] {
        managedSkills.filter { viewModel.skillIsEnabledGlobally($0) && $0.source.kind != .package }
    }

    private var librarySkills: [SkillRecord] {
        managedSkills.filter {
            $0.source.kind == .library &&
            !viewModel.skillIsEnabledGlobally($0)
        }
    }

    private var inactiveLibrarySkills: [SkillRecord] {
        librarySkills.filter { !skillIsActiveForCurrentProject($0) }
    }

    private var packageSkills: [SkillRecord] {
        managedSkills.filter { $0.source.kind == .package }
    }

    private var projectAssignedSkills: [SkillRecord] {
        guard let selectedProject else { return [] }
        return managedSkills.filter {
            viewModel.skill($0, isEnabledFor: selectedProject) &&
            !viewModel.skillIsEnabledGlobally($0) &&
            $0.source.kind != .package
        }
    }

    private func preferredSkillRecord(_ records: [SkillRecord]) -> SkillRecord? {
        records.first { $0.source.kind == .library }
        ?? records.first { $0.source.kind == .global }
        ?? records.first { $0.source.kind == .project }
        ?? records.first { $0.source.kind == .legacyProject }
        ?? records.first { $0.source.kind == .package }
        ?? records.first
    }

    private func skillIsActiveForCurrentProject(_ skill: SkillRecord) -> Bool {
        if viewModel.skillIsEnabledGlobally(skill) { return true }
        if let selectedProject, viewModel.skill(skill, isEnabledFor: selectedProject) { return true }
        return skill.source.kind == .package && selectedProject != nil
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

    private func skillListRow(_ skill: SkillRecord, inactive: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: skillIcon(skill))
                .foregroundStyle(skillColor(skill))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(skill.description ?? "No description")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .opacity((inactive || skillIsUnusedLibrarySkill(skill)) ? 0.62 : 1)
        .saturation((inactive || skillIsUnusedLibrarySkill(skill)) ? 0.25 : 1)
        .badge(statusLabel(skill))
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
            Text("Check each project that should load this skill. The project icon helps confirm the target quickly.")
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

    private func statusLabel(_ skill: SkillRecord) -> String {
        if skillIsUnusedLibrarySkill(skill) { return "Unused" }
        if skill.source.kind == .package { return "Package" }
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return "Active" }
        if viewModel.skillIsEnabledGlobally(skill) { return "Global" }
        if skill.source.kind == .library && !viewModel.assignedProjects(for: skill).isEmpty { return "Assigned" }
        if skill.source.kind == .library { return "Library" }
        return skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)
    }

    private func skillIcon(_ skill: SkillRecord) -> String {
        if skill.source.kind == .package { return "shippingbox" }
        if viewModel.skillIsEnabledGlobally(skill) { return "globe" }
        if skill.source.kind == .library { return "building.columns" }
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return "checkmark.circle" }
        return "wand.and.stars"
    }

    private func skillColor(_ skill: SkillRecord) -> Color {
        if skill.source.kind == .package { return .orange }
        if viewModel.skillIsEnabledGlobally(skill) { return .blue }
        if skill.source.kind == .library { return .purple }
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return .green }
        switch skill.source.kind {
        case .library: return .purple
        case .package: return .orange
        case .project, .legacyProject: return .green
        default: return .blue
        }
    }

    private func skillIsUnusedLibrarySkill(_ skill: SkillRecord) -> Bool {
        skill.source.kind == .library &&
        !viewModel.skillIsEnabledGlobally(skill) &&
        viewModel.assignedProjects(for: skill).isEmpty
    }

    private func assignedProjectSummary(_ skill: SkillRecord) -> String {
        let projects = viewModel.assignedProjects(for: skill).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }

    private var existingLibrarySkillNames: Set<String> {
        Set(viewModel.snapshot.librarySkills.map(\.name))
    }

    private func candidateAlreadyImported(_ candidate: ExternalSkillCandidate) -> Bool {
        existingLibrarySkillNames.contains(candidate.name)
    }

    private var importableCandidateIDs: Set<String> {
        Set(importCandidates.filter { !candidateAlreadyImported($0) || replaceExistingImports }.map(\.id))
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

                AppCard(title: "Import Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Import Mode", selection: $importMode) {
                            ForEach(SkillLibraryImportMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(importMode.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle("Replace existing library skills with the same name", isOn: $replaceExistingImports)
                    }
                }

                AppCard(title: "Skills") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Select one or more skill roots to import into the \(AppBrand.displayName) library.")
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
                                            guard !alreadyImported || replaceExistingImports else { return }
                                            if isSelected { selectedImportCandidateIDs.insert(candidate.id) }
                                            else { selectedImportCandidateIDs.remove(candidate.id) }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(candidate.name)
                                                    .font(.body.weight(.semibold))
                                                if alreadyImported {
                                                    AppLabelTag(text: replaceExistingImports ? "Will Replace" : "Already Imported", color: .gray)
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
                                    .disabled(alreadyImported && !replaceExistingImports)
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
        selectedImportCandidateIDs = Set(candidates.filter { !existingLibrarySkillNames.contains($0.name) }.map(\.id))
        importMode = .symlink
        replaceExistingImports = false

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
            let result = try viewModel.importExternalSkills(selectedCandidates, mode: importMode, replaceExisting: replaceExistingImports)
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
