import SwiftUI

struct LoopDefinitionEditorDraft: Equatable {
    var id: String?
    var filePath: String?
    var name: String
    var description: String
    var goalTemplate: String
    var launchContext: String
    var launchContextScope: LoopLaunchContextScope
    var structure: LoopStructureKind
    var writeTarget: LoopWriteTarget
    var maxIterations: Int
    var validationCommand: String
    var successCondition: String
    var evaluatorModel: String
    var evaluatorThinkingLevel: String
    var makerName: String
    var checkerName: String
    var checkerRubric: String
    var pipelineStageNames: [String]
    var parallelAgentNames: [String]
    var triageAgentName: String
    var classificationPrompt: String
    var checkpointPrompt: String
    var source: LoopDefinitionSource
    var availability: LoopDefinitionAvailability
    var projectPathsText: String
    var createdAt: Date?
    var updatedAt: Date?

    init(definition: LoopDefinition? = nil, currentProjectPath: String? = nil) {
        id = definition?.id
        filePath = definition?.filePath
        name = definition?.name ?? ""
        description = definition?.description ?? ""
        goalTemplate = definition?.goalTemplate ?? ""
        launchContext = definition?.launchContext ?? ""
        launchContextScope = definition?.launchContextScope ?? .firstIterationOnly
        structure = definition?.structure ?? .singleAgent
        writeTarget = definition?.writeTarget ?? .artifactMarkdown
        maxIterations = definition?.maxIterations ?? LoopDraft.defaultMaxIterations
        validationCommand = definition?.validationCommand ?? ""
        let goalEvaluation = definition?.goalEvaluation ?? LoopGoalEvaluationConfig(successCondition: definition?.goalTemplate ?? "")
        successCondition = goalEvaluation.successCondition
        evaluatorModel = goalEvaluation.model ?? ""
        evaluatorThinkingLevel = goalEvaluation.thinkingLevel ?? ""
        let makerChecker = definition?.makerChecker ?? LoopMakerCheckerConfig()
        makerName = makerChecker.makerName
        checkerName = makerChecker.checkerName
        checkerRubric = makerChecker.checkerRubric
        pipelineStageNames = definition?.pipeline.stageNames ?? LoopPipelineConfig().stageNames
        parallelAgentNames = definition?.parallel.branchNames ?? LoopParallelConfig().branchNames
        triageAgentName = definition?.discoveryTriage.agentName ?? LoopDiscoveryTriageConfig().agentName
        classificationPrompt = definition?.discoveryTriage.classificationPrompt ?? LoopDiscoveryTriageConfig().classificationPrompt
        checkpointPrompt = definition?.humanApproval.checkpointPrompt ?? LoopHumanApprovalConfig().checkpointPrompt
        source = definition?.source ?? .user
        availability = definition?.availability ?? .allProjects
        projectPathsText = (definition?.projectPaths ?? currentProjectPath.map { [$0] } ?? []).joined(separator: "\n")
        createdAt = definition?.createdAt
        updatedAt = definition?.updatedAt
    }

    var isNew: Bool { id == nil }
    var isBuiltin: Bool { source == .builtin }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var projectPaths: [String] {
        var seen = Set<String>()
        return projectPathsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    func makeDefinition() -> LoopDefinition {
        LoopDefinition(
            id: id ?? UUID().uuidString,
            name: name,
            description: description,
            goalTemplate: goalTemplate,
            launchContext: launchContext,
            launchContextScope: launchContextScope,
            structure: structure,
            writeTarget: writeTarget,
            maxIterations: maxIterations,
            validationCommand: validationCommand,
            goalEvaluation: LoopGoalEvaluationConfig(successCondition: successCondition.isEmpty ? goalTemplate : successCondition, model: evaluatorModel, thinkingLevel: evaluatorThinkingLevel),
            makerChecker: LoopMakerCheckerConfig(
                makerName: makerName,
                checkerName: checkerName,
                checkerRubric: checkerRubric
            ),
            pipeline: LoopPipelineConfig(stageNames: pipelineStageNames),
            parallel: LoopParallelConfig(branchNames: parallelAgentNames),
            discoveryTriage: LoopDiscoveryTriageConfig(agentName: triageAgentName, classificationPrompt: classificationPrompt),
            humanApproval: LoopHumanApprovalConfig(checkpointPrompt: checkpointPrompt),
            source: .user,
            availability: availability,
            projectPaths: availability == .projectPaths ? projectPaths : [],
            filePath: filePath,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

}

private enum LoopEditTab: String, CaseIterable, Identifiable {
    case definition = "Definition"
    case structure = "Structure"
    case assignment = "Assignment"

    var id: String { rawValue }
}

struct LoopBankScreen: View {
    var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var editorDraft = LoopDefinitionEditorDraft()
    @State private var errorMessage: String?
    @State private var pendingDelete: LoopDefinition?
    @State private var isEditorSheetPresented = false
    @State private var selectedEditTab: LoopEditTab = .definition
    @State private var isCreatingNewLoop = false
    @State private var isDiscardNewLoopDraftAlertPresented = false
    @State private var cachedListSections: [AppListSection<LoopDefinition>] = []

    private var availableLoopAgents: [EffectiveAgentRecord] {
        viewModel.allDisplayAgents
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SplitView {
            loopListPane
        } detail: {
            loopDetailPane
        }
        .onAppear {
            viewModel.reloadLoopDefinitions()
            refreshListSections()
            if let pendingDraft = viewModel.pendingNewLoopEditorDraft {
                isCreatingNewLoop = true
                editorDraft = pendingDraft
                selectedEditTab = .definition
                isEditorSheetPresented = true
            } else {
                if viewModel.selectedLoopDefinitionID == nil, let first = viewModel.loopDefinitions.first {
                    viewModel.selectedLoopDefinitionID = first.id
                }
                if viewModel.selectedLoopDefinition != nil {
                    resetEditor(to: viewModel.selectedLoopDefinition)
                }
            }
        }
        .onChange(of: viewModel.selectedLoopDefinitionID) { _, newID in
            if newID != nil {
                if !isCreatingNewLoop {
                    resetEditor(to: viewModel.selectedLoopDefinition)
                }
            } else if !isCreatingNewLoop {
                resetEditor(to: nil)
            }
        }
        .onChange(of: viewModel.loopDefinitions) { _, definitions in
            refreshListSections()
            if viewModel.selectedLoopDefinitionID == nil, let first = definitions.first, !isCreatingNewLoop, viewModel.pendingNewLoopEditorDraft == nil {
                viewModel.selectedLoopDefinitionID = first.id
            }
            if viewModel.selectedLoopDefinition != nil, !isCreatingNewLoop {
                resetEditor(to: viewModel.selectedLoopDefinition)
            }
        }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            refreshListSections()
        }
        .onChange(of: searchText) { _, _ in
            refreshListSections()
        }
        .onChange(of: viewModel.newLoopRequestID) { _, _ in
            createNewLoop()
        }
        .onChange(of: editorDraft) { _, draft in
            if isCreatingNewLoop {
                viewModel.pendingNewLoopEditorDraft = draft
            }
        }
        .alert("Loop Bank", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Discard new loop draft?", isPresented: $isDiscardNewLoopDraftAlertPresented) {
            Button("Discard and Create New", role: .destructive) {
                startNewLoop(discardPendingDraft: true)
            }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("You already have an unsaved new loop draft. Discard it and start over?")
        }
        .alert("Delete Loop?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { definition in
            Button("Delete", role: .destructive) {
                delete(definition)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { definition in
            Text("Delete \"\(definition.name)\" from the user Loop Bank? Built-in loop resources are never edited.")
        }
        .sheet(isPresented: $isEditorSheetPresented, onDismiss: handleEditorSheetDismiss) {
            loopEditSheet
        }
    }

    private var loopListPane: some View {
        AppList(
            sections: cachedListSections,
            selection: .single(Binding(
                get: { viewModel.selectedLoopDefinitionID },
                set: { selectLoopDefinition($0) }
            )),
            isDisabled: { _ in false },
            keyboardNavigation: true
        ) { definition in
            loopRow(definition)
        }
    }

    @ViewBuilder
    private var loopDetailPane: some View {
        if let definition = viewModel.selectedLoopDefinition {
            loopReadOnlyPane(for: definition)
        } else {
            emptyLoopDetailPane
        }
    }

    private var emptyLoopDetailPane: some View {
        AppPage("Loops", subtitle: "No loop selected", constrainsContentToViewport: true) {
            AppCard(title: "Loop Bank") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No saved loops yet.")
                        .font(AppTheme.Font.sectionTitle)
                        .fontWidth(.expanded)
                    Text("Use the + button in the toolbar to create a new saved loop.")
                        .font(AppTheme.Font.primary)
                        .foregroundStyle(AppTheme.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loopReadOnlyPane(for definition: LoopDefinition) -> some View {
        AppPage(definition.name.nonEmpty ?? "Loop", subtitle: detailSubtitle(for: definition), constrainsContentToViewport: true) {
            AppCard(title: "Definition", trailing: { loopDetailActions(for: definition) }) {
                VStack(alignment: .leading, spacing: 0) {
                    if definition.source == .builtin {
                        Text("Built-in templates are read-only. Duplicate to create an editable user copy.")
                            .font(AppTheme.Font.metadata)
                            .foregroundStyle(AppTheme.mutedText)
                            .padding(.bottom, 12)
                        Divider()
                    }

                    readOnlyDefinitionFields(for: definition)
                }
            }

            readOnlyStructureSection(for: definition)

            readOnlyAvailabilitySection(for: definition)
        }
    }

    @ViewBuilder
    private func loopDetailActions(for definition: LoopDefinition) -> some View {
        HStack(spacing: 8) {
            Button("Duplicate") { duplicate(definition) }
                .appSmallSecondaryButton()
            if definition.source == .user {
                Button("Delete", role: .destructive) { pendingDelete = definition }
                    .appSmallSecondaryButton()
                sectionEditButton(for: definition)
            }
        }
    }

    private func sectionEditButton(for definition: LoopDefinition) -> some View {
        Button {
            resetEditor(to: definition)
            selectedEditTab = .definition
            isEditorSheetPresented = true
        } label: {
            Label("Edit", systemImage: "square.and.pencil")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
        }
        .appSmallSecondaryButton()
        .help("Edit loop")
    }

    private var savedEditorDraft: LoopDefinitionEditorDraft {
        LoopDefinitionEditorDraft(definition: viewModel.selectedLoopDefinition, currentProjectPath: viewModel.selectedProjectPath)
    }

    private var hasUnsavedEditorChanges: Bool {
        if editorDraft.isNew {
            return editorDraft != LoopDefinitionEditorDraft(currentProjectPath: viewModel.selectedProjectPath)
        }
        return editorDraft != savedEditorDraft
    }

    private var canSaveEditorDraft: Bool {
        hasUnsavedEditorChanges && !editorDraft.trimmedName.isEmpty && !editorDraft.isBuiltin && requiredAgentsAreSelected
    }

    private func readOnlyDefinitionFields(for definition: LoopDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            readOnlyFieldRow("Name", value: definition.name, placeholder: "Untitled loop")
            readOnlyMarkdownFieldRow("Description", value: definition.description, placeholder: "No description")
            readOnlyFieldRow("Structure", value: definition.structure.displayName)
            readOnlyFieldRow("Write target", value: definition.writeTarget.displayName)
            readOnlyFieldRow("Max iterations", value: definition.maxIterations > 0 ? "\(definition.maxIterations)" : "No limit")
            readOnlyMarkdownFieldRow("Goal template", value: definition.goalTemplate, placeholder: "No goal template")
            if let launchContext = definition.launchContext, !launchContext.isEmpty {
                readOnlyMarkdownFieldRow("Launch context", value: launchContext)
                readOnlyFieldRow("Context scope", value: definition.launchContextScope.displayName)
            } else {
                readOnlyFieldRow("Launch context", value: "None")
            }
            readOnlyMarkdownFieldRow("Success condition", value: definition.goalEvaluation.successCondition.isEmpty ? definition.goalTemplate : definition.goalEvaluation.successCondition, placeholder: "Loop goal")
            readOnlyFieldRow("Evaluator model", value: definition.goalEvaluation.model ?? "", placeholder: "Default")
            readOnlyFieldRow("Evaluator thinking", value: definition.goalEvaluation.thinkingLevel ?? "", placeholder: "Default")
            readOnlyFieldRow("Validation command", value: definition.validationCommand, placeholder: "None", isLast: true)
        }
    }

    private var definitionFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("Name", info: "Use a short action-oriented name. This is what appears in the Loop Bank and launch menus.") {
                TextField("", text: $editorDraft.name)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
            }
            detailEditor("Description", text: $editorDraft.description, minHeight: 64, info: "Optional summary for the Loop Bank list. Use it to explain when someone should choose this loop.")
            detailRow("Structure", infoRows: loopStructureInfoRows) {
                Picker("Structure", selection: $editorDraft.structure) {
                    ForEach(LoopStructureKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
            }
            detailRow("Write target", infoRows: loopWriteTargetInfoRows) {
                Picker("Write target", selection: $editorDraft.writeTarget) {
                    ForEach(LoopWriteTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .labelsHidden()
            }
            detailRow("Max iterations", info: "A hard safety limit. Set 0 for no iteration limit so the loop continues until it reaches its goal or another stop condition.") {
                let hasIterationLimit = editorDraft.maxIterations > 0
                HStack(spacing: 8) {
                    LoopNumericStepper(value: $editorDraft.maxIterations, range: 0...LoopDraft.maximumMaxIterations)
                        .disabled(!hasIterationLimit)
                        .opacity(hasIterationLimit ? 1 : 0.45)
                    Button(hasIterationLimit ? "No limit" : "Set limit") {
                        if hasIterationLimit {
                            editorDraft.maxIterations = 0
                        } else {
                            editorDraft.maxIterations = min(max(LoopDraft.defaultMaxIterations, 1), LoopDraft.maximumMaxIterations)
                        }
                    }
                    .appSmallSecondaryButton()
                }
            }
            detailEditor("Goal template", text: $editorDraft.goalTemplate, minHeight: 120, info: "The reusable instruction the loop runs against. Be explicit about the desired outcome, constraints, and what counts as done.")
            detailEditor("Success condition", text: $editorDraft.successCondition, minHeight: 84, info: "Always-on report-only evaluator uses this natural-language condition after every iteration. Leave empty to use the loop goal.")
            detailRow("Evaluator model", info: "Optional model override for the report-only goal evaluator. Leave empty to use Pi's current default/inherited model.") {
                AppTextField(text: $editorDraft.evaluatorModel, placeholder: "Default")
                    .frame(maxWidth: 360)
            }
            detailRow("Evaluator thinking", info: "Optional thinking level for the report-only goal evaluator, such as off, low, medium, high, or xhigh.") {
                AppTextField(text: $editorDraft.evaluatorThinkingLevel, placeholder: "Default")
                    .frame(maxWidth: 360)
            }
            detailEditor("Launch context (optional)", text: $editorDraft.launchContext, minHeight: 84, infoRows: loopLaunchContextInfoRows)
            if !editorDraft.launchContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detailRow("Context scope", info: "First iteration only is the default. Every iteration repeats this context in each child-agent prompt.") {
                    Picker("Context scope", selection: $editorDraft.launchContextScope) {
                        ForEach(LoopLaunchContextScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .labelsHidden()
                }
            }
            detailRow("Validation command (optional)", info: "Agent Deck can run one shell command after each loop iteration, from the project directory when available. Its output is attached as evidence. Leave empty to skip automatic validation.", showsDivider: false) {
                AppTextField(text: $editorDraft.validationCommand, placeholder: "Optional, e.g. swift test")
                    .frame(maxWidth: 360)
            }
        }
    }

    private var availabilitySection: some View {
        AppCard(title: "Project Assignment") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enable for every project at once, or pick specific projects below. Assignments are stored in the Loop Bank and do not move loop files.")
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVStack(alignment: .leading, spacing: 0) {
                    AllProjectsAssignmentRow(
                        isOn: Binding(
                            get: { editorDraft.availability == .allProjects },
                            set: { enabled in
                                if enabled { setAllProjectsAvailability() }
                                else { setUnassignedAvailability() }
                            }
                        ),
                        subtitle: "Enable this loop for every project"
                    )
                    if !availableProjectsForLoopAssignment.isEmpty { Divider() }
                    ForEach(availableProjectsForLoopAssignment) { project in
                        ProjectAssignmentToggleRow(
                            project: project,
                            isOn: Binding(
                                get: { editorDraft.availability == .allProjects ? true : editorDraft.projectPaths.contains(project.path) },
                                set: { setLoopAssigned($0, toProjectPath: project.path) }
                            )
                        )
                        .opacity(editorDraft.availability == .allProjects ? 0.4 : 1)
                        .allowsHitTesting(editorDraft.availability != .allProjects)
                        if project.id != availableProjectsForLoopAssignment.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var currentProjectPath: String? {
        let trimmed = viewModel.selectedProjectPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func setAllProjectsAvailability() {
        editorDraft.availability = .allProjects
        editorDraft.projectPathsText = ""
    }

    private func setCurrentProjectAvailability() {
        guard let currentProjectPath else { return }
        setLoopAssigned(true, toProjectPath: currentProjectPath)
    }

    private var availableProjectsForLoopAssignment: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func setLoopAssigned(_ assigned: Bool, toProjectPath projectPath: String) {
        var paths = editorDraft.projectPaths
        if assigned {
            if !paths.contains(projectPath) { paths.append(projectPath) }
        } else {
            paths.removeAll { $0 == projectPath }
        }
        editorDraft.availability = .projectPaths
        editorDraft.projectPathsText = paths.joined(separator: "\n")
    }

    private func setUnassignedAvailability() {
        editorDraft.availability = .projectPaths
        editorDraft.projectPathsText = ""
    }

    private var loopEditSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(editorDraft.isNew ? "New Loop" : "Edit Loop")
                        .font(.headline.weight(.semibold))
                    Text(editorDraft.name.nonEmpty ?? "Untitled loop")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LoopEditTab.allCases) { tab in
                        Button {
                            selectedEditTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .fontWidth(.expanded)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selectedEditTab == tab ? AppTheme.selectionFill : AppTheme.contentSubtleFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    switch selectedEditTab {
                    case .definition:
                        AppCard(title: "Definition") { definitionFields }
                    case .structure:
                        loopStructureSection
                    case .assignment:
                        availabilitySection
                    }
                }
                .padding(24)
            }

            Divider()

            HStack(spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Discard") {
                    if editorDraft.isNew {
                        discardNewLoopDraft()
                    } else {
                        resetEditor(to: viewModel.selectedLoopDefinition)
                    }
                    isEditorSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    if save() {
                        isEditorSheetPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(AppTheme.brandAccent)
                .disabled(!canSaveEditorDraft)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 700, height: 640)
    }

    @ViewBuilder
    private func readOnlyStructureSection(for definition: LoopDefinition) -> some View {
        switch definition.structure {
        case .makerChecker:
            AppCard(title: "Maker + Checker") {
                VStack(alignment: .leading, spacing: 10) {
                    readOnlyFieldRow("Maker agent", value: definition.makerChecker.makerName, placeholder: "Not selected")
                    readOnlyFieldRow("Checker agent", value: definition.makerChecker.checkerName, placeholder: "Not selected")
                    readOnlyMarkdownFieldRow("Checker rubric", value: definition.makerChecker.checkerRubric, isLast: true)
                }
            }
        case .agentPipeline:
            AppCard(title: "Agent Pipeline") {
                readOnlyFieldRow("Stages", value: definition.pipeline.stageNames.isEmpty ? "No stages" : definition.pipeline.stageNames.joined(separator: " → "), isLast: true)
            }
        case .parallelAgents:
            AppCard(title: "Parallel Agents") {
                readOnlyFieldRow("Branches", value: definition.parallel.branchNames.joined(separator: " | "), placeholder: "No branches", isLast: true)
            }
        case .discoveryTriage:
            AppCard(title: "Discovery / Triage") {
                VStack(alignment: .leading, spacing: 10) {
                    readOnlyFieldRow("Triage agent", value: definition.discoveryTriage.agentName, placeholder: "Not selected")
                    readOnlyMarkdownFieldRow("Classification prompt", value: definition.discoveryTriage.classificationPrompt, isLast: true)
                }
            }
        case .humanApproval:
            AppCard(title: "Human Approval") {
                readOnlyMarkdownFieldRow("Checkpoint prompt", value: definition.humanApproval.checkpointPrompt, isLast: true)
            }
        case .singleAgent:
            AppCard(title: "Single Agent") {
                readOnlyFieldRow("Agent", value: definition.makerChecker.makerName, placeholder: "Not selected", isLast: true)
            }
        }
    }

    @ViewBuilder
    private func readOnlyAvailabilitySection(for definition: LoopDefinition) -> some View {
        AppCard(title: "Project Assignment") {
            if definition.source == .builtin {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Built-in loops are bundled with \(AppBrand.displayName). Duplicate this loop to create an editable user copy and assign it to projects.")
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    readOnlyFieldRow("Availability", value: availabilityLabel(for: definition))
                    readOnlyFieldRow("Projects", value: projectAssignmentSummary(for: definition), isLast: true)
                }
            } else {
                let isGlobal = definition.availability == .allProjects
                let assignedProjectPaths = Set(definition.projectPaths)
                let projects = availableProjectsForLoopAssignment

                VStack(alignment: .leading, spacing: 10) {
                    Text("Enable for every project at once, or pick specific projects below. Assignments are stored in the Loop Bank and do not move loop files.")
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        AllProjectsAssignmentRow(
                            isOn: Binding(
                                get: { isGlobal },
                                set: { enabled in
                                    updateLoopAvailability(
                                        definition,
                                        availability: enabled ? .allProjects : .projectPaths,
                                        projectPaths: []
                                    )
                                }
                            ),
                            subtitle: "Enable this loop for every project"
                        )
                        if !projects.isEmpty { Divider() }
                        ForEach(projects) { project in
                            ProjectAssignmentToggleRow(
                                project: project,
                                isOn: Binding(
                                    get: { isGlobal ? true : assignedProjectPaths.contains(project.path) },
                                    set: { enabled in
                                        var paths = definition.projectPaths
                                        if enabled {
                                            if !paths.contains(project.path) { paths.append(project.path) }
                                        } else {
                                            paths.removeAll { $0 == project.path }
                                        }
                                        updateLoopAvailability(definition, availability: .projectPaths, projectPaths: paths)
                                    }
                                )
                            )
                            .opacity(isGlobal ? 0.4 : 1)
                            .allowsHitTesting(!isGlobal)
                            if project.id != projects.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var loopStructureSection: some View {
        switch editorDraft.structure {
        case .makerChecker:
            AppCard(title: "Maker + Checker") {
                VStack(alignment: .leading, spacing: 0) {
                    detailRow("Maker agent", info: "The agent that produces the work for each iteration.") {
                        LoopAgentNameMenu(selection: $editorDraft.makerName, availableAgents: availableLoopAgents, fallbackLabel: "Maker")
                    }
                    detailRow("Checker agent", info: "The agent that reviews the maker output and decides whether another round is needed.") {
                        LoopAgentNameMenu(selection: $editorDraft.checkerName, availableAgents: availableLoopAgents, fallbackLabel: "Checker")
                    }
                    detailEditor("Checker rubric", text: $editorDraft.checkerRubric, minHeight: 84, info: "Instructions for the checker. Keep the approval criteria concrete so the loop knows when to stop retrying.")
                }
            }
        case .agentPipeline:
            AppCard(title: "Agent Pipeline") {
                VStack(alignment: .leading, spacing: 10) {
                    LoopPipelineStagePicker(stages: $editorDraft.pipelineStageNames, availableAgents: availableLoopAgents)
                    Text("Stages are saved as an ordered agent list. The current runner records this order; child agent execution is the next runner slice.")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        case .parallelAgents:
            AppCard(title: "Parallel Agents") {
                VStack(alignment: .leading, spacing: 8) {
                    LoopPipelineStagePicker(stages: $editorDraft.parallelAgentNames, availableAgents: availableLoopAgents)
                    Text("Select enabled agents for independent report-only investigations. Parallel loops never share a writable target.")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        case .discoveryTriage:
            AppCard(title: "Discovery / Triage") {
                detailRow("Triage agent", info: "The agent that gathers findings and applies the classification prompt.") {
                    LoopAgentNameMenu(selection: $editorDraft.triageAgentName, availableAgents: availableLoopAgents, fallbackLabel: "Explorer")
                }
                detailEditor("Classification prompt", text: $editorDraft.classificationPrompt, minHeight: 84, info: "Tell the triage agent how to sort findings, for example by severity, confidence, owner, or next action.")
            }
        case .humanApproval:
            AppCard(title: "Human Approval") {
                detailEditor("Checkpoint prompt", text: $editorDraft.checkpointPrompt, minHeight: 84, info: "The question or review instruction shown for a terminal approval checkpoint. Approval is recorded; it does not resume this same run.")
            }
        case .singleAgent:
            AppCard(title: "Single Agent") {
                detailRow("Agent", info: "The agent that will run each iteration. Choose the role best matched to the goal, such as explorer, coder, or reviewer.", showsDivider: false) {
                    LoopAgentNameMenu(selection: $editorDraft.makerName, availableAgents: availableLoopAgents, fallbackLabel: "Agent")
                }
            }
        }
    }

    private var requiredAgentsAreSelected: Bool {
        switch editorDraft.structure {
        case .singleAgent:
            return !editorDraft.makerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .makerChecker:
            return !editorDraft.makerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !editorDraft.checkerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .discoveryTriage:
            return !editorDraft.triageAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .agentPipeline:
            return !editorDraft.pipelineStageNames.isEmpty
                && editorDraft.pipelineStageNames.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .parallelAgents:
            return !editorDraft.parallelAgentNames.isEmpty
                && editorDraft.parallelAgentNames.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .humanApproval:
            return true
        }
    }

    private var loopStructureInfoRows: [LoopInlineInfoButton.Row] {
        [
            .init("Single Agent", "Repeats one selected agent against the goal."),
            .init("Maker + Checker", "A maker produces work, a checker reviews it, and iterations can retry."),
            .init("Agent Pipeline", "Records ordered stages such as Explorer → Implementer → Verifier."),
            .init("Parallel Agents", "Names independent branches or hypotheses in the same loop run."),
            .init("Discovery / Triage", "Collects findings and classifies them by severity or next action."),
            .init("Approval Checkpoint", "Records an explicit approval or rejection; start a new attempt for follow-up work.")
        ]
    }

    private var loopWriteTargetInfoRows: [LoopInlineInfoButton.Row] {
        [
            .init("Artifact / Markdown output", "Safest mode. The loop writes artifacts and does not modify project files."),
            .init("New worktree", "Creates an isolated git worktree for code changes and validation."),
            .init("Current checkout", "Writes directly into the current project checkout. Use only when in-place edits are intended.")
        ]
    }

    private var loopLaunchContextInfoRows: [LoopInlineInfoButton.Row] {
        [
            .init("What it is", "Optional background or arguments added to child-agent launch prompts, kept separate from the goal template."),
            .init("Good uses", "Paste repro steps, observed hitches or hangs, logs, device state, or constraints such as report-only or avoid API changes."),
            .init("Scope", "First iteration only seeds the loop once. Every iteration repeats this context in each prompt when constraints must stay visible.")
        ]
    }

    private var loopAvailabilityInfoRows: [LoopInlineInfoButton.Row] {
        [
            .init("All Projects/default", "Available as a default saved loop everywhere."),
            .init("Current Project only", "Assigns the loop to the selected project path."),
            .init("Unassigned/catalog", "Keeps the loop saved but out of project launch menus until assigned.")
        ]
    }

    private func detailRow<Content: View>(
        _ title: String,
        info: String? = nil,
        infoRows: [LoopInlineInfoButton.Row] = [],
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.contentSpacing) {
                detailLabel(title, info: info, infoRows: infoRows)
                Spacer(minLength: AppTheme.contentSpacing)
                content()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 11)
            if showsDivider { Divider() }
        }
    }

    private func detailEditor(_ title: String, text: Binding<String>, minHeight: CGFloat, monospaced: Bool = false, info: String? = nil, infoRows: [LoopInlineInfoButton.Row] = []) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailLabel(title, info: info, infoRows: infoRows)
            TextEditor(text: text)
                .font(monospaced ? .body.monospaced() : AppTheme.Font.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(AppTheme.textContentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.contentStroke, lineWidth: 1)
                }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func readOnlyFieldRow(_ title: String, value: String, placeholder: String? = nil, isLast: Bool = false) -> some View {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = trimmedValue.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            readOnlyFieldLabel(title)
            Text(isPlaceholder ? (placeholder ?? "None") : value)
                .font(AppTheme.Font.body)
                .foregroundStyle(isPlaceholder ? AppTheme.mutedText : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !isLast {
            Divider()
        }
    }

    @ViewBuilder
    private func readOnlyMarkdownFieldRow(_ title: String, value: String, placeholder: String? = nil, isLast: Bool = false) -> some View {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = trimmedValue.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            readOnlyFieldLabel(title)
            if isPlaceholder {
                Text(placeholder ?? "None")
                    .font(AppTheme.Font.body)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownDocumentView(source: value, minimumHeight: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !isLast {
            Divider()
        }
    }

    private func readOnlyFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .foregroundStyle(AppTheme.mutedText)
    }

    private func detailLabel(_ title: String, info: String? = nil, infoRows: [LoopInlineInfoButton.Row] = []) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
                .foregroundStyle(AppTheme.mutedText)
            if let info {
                LoopInlineInfoButton(title: title, message: info)
            } else if !infoRows.isEmpty {
                LoopInlineInfoButton(title: title, rows: infoRows)
            }
        }
    }

    private func detailSubtitle(for definition: LoopDefinition) -> String {
        if definition.source == .builtin { return "Built-in template · duplicate to customize" }
        return "Read-only details · edit in the sheet"
    }

    private func refreshListSections() {
        cachedListSections = buildListSections()
    }

    private func buildListSections() -> [AppListSection<LoopDefinition>] {
        let selectedProjectPath = viewModel.selectedProjectPath
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let definitions = viewModel.loopDefinitions
            .filter { definition in
                guard !query.isEmpty else { return true }
                return [
                    definition.name,
                    definition.description,
                    definition.goalTemplate,
                    definition.structure.displayName,
                    definition.writeTarget.displayName,
                    availabilityLabel(for: definition),
                    definition.filePath ?? ""
                ].contains { $0.lowercased().contains(query) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var current: [LoopDefinition] = []
        var currentIDs = Set<LoopDefinition.ID>()
        let defaults = definitions.filter { $0.source == .user && $0.availability == .allProjects }
        var catalog: [LoopDefinition] = []
        var builtins: [LoopDefinition] = []

        for definition in definitions {
            if definition.source == .builtin {
                builtins.append(definition)
            } else if definition.source == .user,
                      definition.availability == .projectPaths,
                      let selectedProjectPath,
                      definition.projectPaths.contains(selectedProjectPath) {
                current.append(definition)
                currentIDs.insert(definition.id)
            }
        }

        for definition in definitions where definition.source == .user && definition.availability == .projectPaths {
            if definition.projectPaths.isEmpty || !currentIDs.contains(definition.id) {
                catalog.append(definition)
            }
        }

        return [
            AppListSection(
                id: "default",
                title: "Default Loops",
                info: "User loops available to every project. Assign one to specific projects from its detail card.",
                items: defaults,
                emptyMessage: "No default loops."
            ),
            AppListSection(
                id: "project",
                title: "Project Loops",
                items: current,
                emptyMessage: "No loops assigned to the selected project."
            ),
            AppListSection(
                id: "catalog",
                title: "Catalog Loops",
                items: catalog,
                emptyMessage: "No catalog loops."
            ),
            AppListSection(
                id: "builtin",
                title: "Builtin Loops",
                info: "Builtins are bundled with \(AppBrand.displayName) and customized by duplicating them into the user Loop Bank.",
                items: builtins,
                emptyMessage: "No builtin loops discovered."
            )
        ]
    }

    private func loopRow(_ definition: LoopDefinition) -> some View {
        LoopListRow(
            definition: definition,
            tint: availabilityColor(for: definition),
            isMuted: loopIsInactive(definition)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            if definition.source == .user {
                Button("Make All Projects/default") {
                    updateLoopAvailability(definition, availability: .allProjects, projectPaths: [])
                }
                if let currentProjectPath {
                    Button(definition.projectPaths.contains(currentProjectPath) ? "Remove Current Project" : "Assign to Current Project") {
                        var paths = definition.projectPaths
                        if paths.contains(currentProjectPath) { paths.removeAll { $0 == currentProjectPath } }
                        else { paths.append(currentProjectPath) }
                        updateLoopAvailability(definition, availability: .projectPaths, projectPaths: paths)
                    }
                }
                Button("Disable / Move to Catalog") {
                    updateLoopAvailability(definition, availability: .projectPaths, projectPaths: [])
                }
                Divider()
                Button("Duplicate") { duplicate(definition) }
                Button("Delete", role: .destructive) { pendingDelete = definition }
            } else {
                Button("Duplicate") { duplicate(definition) }
            }
        }
    }

    private func loopIsInactive(_ definition: LoopDefinition) -> Bool {
        definition.source == .user && definition.availability == .projectPaths && definition.projectPaths.isEmpty
    }

    private func updateLoopAvailability(_ definition: LoopDefinition, availability: LoopDefinitionAvailability, projectPaths: [String]) {
        var draft = LoopDefinitionEditorDraft(definition: definition, currentProjectPath: viewModel.selectedProjectPath)
        draft.availability = availability
        draft.projectPathsText = availability == .projectPaths ? projectPaths.joined(separator: "\n") : ""
        do {
            let saved = try viewModel.saveLoopDefinition(draft.makeDefinition())
            if editorDraft.id == saved.id { resetEditor(to: saved) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectLoopDefinition(_ id: String?) {
        if isCreatingNewLoop {
            isCreatingNewLoop = false
            viewModel.pendingNewLoopEditorDraft = nil
        }
        viewModel.selectedLoopDefinitionID = id
    }

    private func handleEditorSheetDismiss() {
        if isCreatingNewLoop {
            discardNewLoopDraft()
        }
    }

    private func createNewLoop() {
        if isCreatingNewLoop || viewModel.pendingNewLoopEditorDraft != nil {
            isDiscardNewLoopDraftAlertPresented = true
        } else {
            startNewLoop(discardPendingDraft: false)
        }
    }

    private func startNewLoop(discardPendingDraft: Bool) {
        isCreatingNewLoop = true
        if discardPendingDraft {
            viewModel.pendingNewLoopEditorDraft = nil
        }
        editorDraft = viewModel.pendingNewLoopEditorDraft ?? LoopDefinitionEditorDraft(currentProjectPath: viewModel.selectedProjectPath)
        selectedEditTab = .definition
        isEditorSheetPresented = true
    }

    private func resetEditor(to definition: LoopDefinition?) {
        editorDraft = LoopDefinitionEditorDraft(definition: definition, currentProjectPath: viewModel.selectedProjectPath)
    }

    private func discardNewLoopDraft() {
        guard editorDraft.isNew else { return }
        viewModel.pendingNewLoopEditorDraft = nil
        isCreatingNewLoop = false
        resetEditor(to: viewModel.selectedLoopDefinition)
    }

    @discardableResult
    private func save() -> Bool {
        guard !editorDraft.isBuiltin else { return false }
        do {
            let saved = try viewModel.saveLoopDefinition(editorDraft.makeDefinition())
            isCreatingNewLoop = false
            viewModel.pendingNewLoopEditorDraft = nil
            resetEditor(to: saved)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func duplicate(_ definition: LoopDefinition) {
        do {
            let saved = try viewModel.duplicateLoopDefinition(definition)
            resetEditor(to: saved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ definition: LoopDefinition) {
        do {
            try viewModel.deleteLoopDefinition(definition)
            pendingDelete = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func availabilityLabel(for definition: LoopDefinition) -> String {
        if definition.source == .builtin { return "Built-in" }
        switch definition.availability {
        case .allProjects:
            return "All Projects/default"
        case .projectPaths:
            if definition.projectPaths.isEmpty { return "Unassigned" }
            if let selectedProjectPath = viewModel.selectedProjectPath,
               definition.projectPaths.contains(selectedProjectPath) {
                return "Current Project"
            }
            return definition.projectPaths.count == 1 ? "1 Project" : "\(definition.projectPaths.count) Projects"
        }
    }

    private func projectAssignmentSummary(for definition: LoopDefinition) -> String {
        switch definition.availability {
        case .allProjects:
            return "Every project"
        case .projectPaths:
            return definition.projectPaths.isEmpty ? "None" : definition.projectPaths.joined(separator: ", ")
        }
    }

    private func availabilityLabel(for draft: LoopDefinitionEditorDraft) -> String {
        switch draft.availability {
        case .allProjects:
            return "All Projects/default"
        case .projectPaths:
            if draft.projectPaths.isEmpty { return "Unassigned/catalog" }
            if let currentProjectPath, draft.projectPaths == [currentProjectPath] { return "Current Project only" }
            return draft.projectPaths.count == 1 ? "1 Project" : "\(draft.projectPaths.count) Projects"
        }
    }

    private func availabilityColor(for definition: LoopDefinition) -> Color {
        if definition.source == .builtin { return AppTheme.sourceBuiltin }
        switch definition.availability {
        case .allProjects: return AppTheme.brandAccent
        case .projectPaths: return definition.projectPaths.isEmpty ? AppTheme.sourceLibrary : AppTheme.sourceProject
        }
    }

    private func availabilityColor(for draft: LoopDefinitionEditorDraft) -> Color {
        switch draft.availability {
        case .allProjects: return AppTheme.brandAccent
        case .projectPaths: return draft.projectPaths.isEmpty ? AppTheme.sourceLibrary : AppTheme.sourceProject
        }
    }
}

private struct LoopListRow: View {
    let definition: LoopDefinition
    let tint: Color
    let isMuted: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10))
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 1)
                Image(systemName: "infinity")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(definition.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(definition.description.isEmpty ? definition.goalTemplate : definition.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(isMuted ? 0.62 : 1)
        .saturation(isMuted ? 0.25 : 1)
    }
}
