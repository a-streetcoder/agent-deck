import SwiftUI

struct LoopLaunchSheet: View {
    let session: PiAgentSessionRecord
    let activeRun: LoopRun?
    let sourceDefinition: LoopDefinition?
    let allAgents: [EffectiveAgentRecord]
    let projectAgents: [EffectiveAgentRecord]
    let availableAgents: [EffectiveAgentRecord]
    let onCancel: () -> Void
    let onAssignMissingAgents: ([String]) -> Void
    let onEnableDeckAgents: () -> Void
    let onLaunch: (LoopLaunchRequest) -> Void

    @State private var draft: LoopDraft
    @State private var stopExistingActive = false
    @State private var saveToLoopBank = false
    @State private var saveName = ""
    @State private var saveDescription = ""
    @State private var saveForCurrentProjectOnly = false
    @State private var isInfoPresented = false
    @State private var confirmsCurrentCheckoutWrite = false

    init(
        session: PiAgentSessionRecord,
        activeRun: LoopRun?,
        initialDraft: LoopDraft = LoopDraft(),
        sourceDefinition: LoopDefinition? = nil,
        availableAgents: [EffectiveAgentRecord] = [],
        projectAgents: [EffectiveAgentRecord] = [],
        onCancel: @escaping () -> Void,
        onAssignMissingAgents: @escaping ([String]) -> Void = { _ in },
        onEnableDeckAgents: @escaping () -> Void = {},
        onLaunch: @escaping (LoopLaunchRequest) -> Void
    ) {
        self.session = session
        self.activeRun = activeRun
        self.sourceDefinition = sourceDefinition
        self.allAgents = availableAgents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.projectAgents = projectAgents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.availableAgents = projectAgents.filter { $0.resolved.disabled != true }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.onCancel = onCancel
        self.onAssignMissingAgents = onAssignMissingAgents
        self.onEnableDeckAgents = onEnableDeckAgents
        self.onLaunch = onLaunch
        _draft = State(initialValue: initialDraft)
        _saveName = State(initialValue: sourceDefinition?.name ?? "")
        _saveDescription = State(initialValue: sourceDefinition?.description ?? "")
    }

    private var trimmedGoal: String {
        draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canLaunch: Bool {
        let saveIsValid = !saveToLoopBank || !saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let writeTargetIsConfirmed = draft.writeTarget != .currentCheckout || confirmsCurrentCheckoutWrite
        let parallelTargetIsSafe = draft.structure != .parallelAgents || draft.writeTarget == .artifactMarkdown
        return !trimmedGoal.isEmpty && requiredAgentsAreSelected && deckAgentsPreflightIsSatisfied && agentPreflightIssues.isEmpty && saveIsValid && writeTargetIsConfirmed && parallelTargetIsSafe && (activeRun == nil || stopExistingActive)
    }

    private var deckAgentsPreflightIsSatisfied: Bool {
        !loopRequiresDeckAgents || session.subagentsEnabled
    }

    private var loopRequiresDeckAgents: Bool {
        switch draft.structure {
        case .humanApproval:
            return false
        case .singleAgent, .makerChecker, .agentPipeline, .parallelAgents, .discoveryTriage:
            return true
        }
    }

    private var requiredAgentsAreSelected: Bool {
        switch draft.structure {
        case .singleAgent:
            return !draft.makerChecker.makerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .makerChecker:
            return !draft.makerChecker.makerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !draft.makerChecker.checkerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .discoveryTriage:
            return !draft.discoveryTriage.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .agentPipeline:
            return !draft.pipeline.stageNames.isEmpty
                && draft.pipeline.stageNames.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .parallelAgents:
            return !draft.parallel.branchNames.isEmpty
                && draft.parallel.branchNames.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .humanApproval:
            return true
        }
    }

    private var requiredAgentNames: [String] {
        switch draft.structure {
        case .singleAgent:
            return [draft.makerChecker.makerName]
        case .makerChecker:
            return [draft.makerChecker.makerName, draft.makerChecker.checkerName]
        case .discoveryTriage:
            return [draft.discoveryTriage.agentName]
        case .agentPipeline:
            return draft.pipeline.stageNames
        case .parallelAgents:
            return draft.parallel.branchNames
        case .humanApproval:
            return []
        }
    }

    private struct AgentPreflightIssue: Identifiable {
        enum Kind {
            case unassigned
            case disabled
            case missingDefinition

            var title: String {
                switch self {
                case .unassigned: return "Not assigned to this project"
                case .disabled: return "Disabled"
                case .missingDefinition: return "Agent definition missing"
                }
            }

            var remediation: String {
                switch self {
                case .unassigned:
                    return "Can be fixed by assigning the existing agent to this project."
                case .disabled:
                    return "Enable this agent in Agents before launching. Agent Deck will not silently enable disabled agents."
                case .missingDefinition:
                    return "Create, import, or choose another agent. There is no agent file to assign."
                }
            }
        }

        let name: String
        let kind: Kind
        var id: String { "\(kind.title)::\(name)" }
    }

    private var agentPreflightIssues: [AgentPreflightIssue] {
        let projectByName = Dictionary(grouping: projectAgents, by: \.name)
        let allByName = Dictionary(grouping: allAgents, by: \.name)
        var seen = Set<String>()
        return requiredAgentNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .compactMap { name in
                if let projectMatches = projectByName[name], !projectMatches.isEmpty {
                    if projectMatches.contains(where: { $0.resolved.disabled != true }) {
                        return nil
                    }
                    return AgentPreflightIssue(name: name, kind: .disabled)
                }
                guard let globalMatches = allByName[name], !globalMatches.isEmpty else {
                    return AgentPreflightIssue(name: name, kind: .missingDefinition)
                }
                if globalMatches.allSatisfy({ $0.resolved.disabled == true }) {
                    return AgentPreflightIssue(name: name, kind: .disabled)
                }
                return AgentPreflightIssue(name: name, kind: .unassigned)
            }
    }

    private var assignablePreflightAgentNames: [String] {
        agentPreflightIssues.filter { $0.kind == .unassigned }.map(\.name)
    }

    private var canSaveToLoopBank: Bool {
        sourceDefinition == nil
    }

    private var pipelineStagesBinding: Binding<[String]> {
        Binding(
            get: { draft.pipeline.stageNames },
            set: { draft.pipeline = LoopPipelineConfig(stageNames: $0) }
        )
    }

    private var parallelAgentsBinding: Binding<[String]> {
        Binding(
            get: { draft.parallel.branchNames },
            set: { draft.parallel = LoopParallelConfig(branchNames: $0) }
        )
    }

    private var launchContextBinding: Binding<String> {
        Binding(
            get: { draft.launchContext ?? "" },
            set: { draft.launchContext = $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        )
    }

    private var successConditionBinding: Binding<String> {
        Binding(
            get: { draft.goalEvaluation.successCondition },
            set: { draft.goalEvaluation = LoopGoalEvaluationConfig(successCondition: $0, model: draft.goalEvaluation.model, thinkingLevel: draft.goalEvaluation.thinkingLevel) }
        )
    }

    private var evaluatorModelBinding: Binding<String> {
        Binding(
            get: { draft.goalEvaluation.model ?? "" },
            set: { draft.goalEvaluation = LoopGoalEvaluationConfig(successCondition: draft.goalEvaluation.successCondition, model: $0, thinkingLevel: draft.goalEvaluation.thinkingLevel) }
        )
    }

    private var evaluatorThinkingBinding: Binding<String> {
        Binding(
            get: { draft.goalEvaluation.thinkingLevel ?? "" },
            set: { draft.goalEvaluation = LoopGoalEvaluationConfig(successCondition: draft.goalEvaluation.successCondition, model: draft.goalEvaluation.model, thinkingLevel: $0) }
        )
    }

    private var title: String {
        sourceDefinition?.name ?? "Create Loop"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    if let activeRun {
                        activeLoopWarning(activeRun)
                    }

                    deckAgentsPreflightSection
                    loopPreflightSection
                    parallelSafetyPreflightSection

                    AppCard(title: "Loop") {
                        VStack(alignment: .leading, spacing: 14) {
                            pickerRow("Structure") {
                                HStack(spacing: 8) {
                                    Picker("Structure", selection: $draft.structure) {
                                        ForEach(LoopStructureKind.allCases) { kind in
                                            Text(kind.displayName).tag(kind)
                                        }
                                    }
                                    .labelsHidden()
                                    .appMenuPicker()

                                    LoopInlineInfoButton(
                                        title: "Structure",
                                        rows: [
                                            .init("Single Agent", "Repeats one agent against the goal."),
                                            .init("Maker/Checker", "Maker produces work, checker reviews it, and retries can happen."),
                                            .init("Agent Pipeline", "Runs named stages in order, like Explorer → Implementer → Verifier."),
                                            .init("Parallel Agents", "Tracks independent branches or hypotheses in the same run."),
                                            .init("Discovery Triage", "Collects findings and classifies them by severity / next action."),
                                            .init("Approval Checkpoint", "Records explicit approval or rejection; it does not resume this same run.")
                                        ]
                                    )
                                }
                            }

                            pickerRow("Write Target") {
                                HStack(spacing: 8) {
                                    Picker("Write Target", selection: $draft.writeTarget) {
                                        ForEach(LoopWriteTarget.allCases) { target in
                                            Text(target.displayName).tag(target)
                                        }
                                    }
                                    .labelsHidden()
                                    .appMenuPicker()

                                    LoopInlineInfoButton(
                                        title: "Write Target",
                                        rows: [
                                            .init("Artifact / Markdown output", "Safest mode; writes only loop artifacts and never modifies project files."),
                                            .init("New worktree", "Creates an isolated git worktree for code changes and validation, leaving the current checkout untouched."),
                                            .init("Current checkout", "Writes directly into this project checkout; use only when you want the loop to edit files in place.")
                                        ]
                                    )
                                }
                            }

                            writeTargetExplanation

                            fieldGroup("Goal") {
                                TextEditor(text: $draft.goal)
                                    .font(AppTheme.Font.body)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(minHeight: 104)
                                    .background(AppTheme.textContentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(AppTheme.contentStroke, lineWidth: 1)
                                    }
                            }

                            fieldGroup {
                                HStack(spacing: 6) {
                                    Text("Success condition")
                                        .font(AppTheme.Font.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.mutedText)
                                    LoopInlineInfoButton(
                                        title: "Goal evaluator",
                                        message: "After every iteration, Agent Deck runs a report-only natural-language evaluator. It returns SUCCESS to stop successfully, CONTINUE to run another iteration until the max, or FAIL to stop as agent failed. Leave this empty to use the loop goal."
                                    )
                                }
                            } content: {
                                AppTextField(text: successConditionBinding, placeholder: "Defaults to loop goal", axis: .vertical)
                                    .lineLimit(2...4)
                                HStack(spacing: 8) {
                                    AppTextField(text: evaluatorModelBinding, placeholder: "Evaluator model: default")
                                    AppTextField(text: evaluatorThinkingBinding, placeholder: "Thinking: default")
                                }
                                Text("Completion requires exact evaluator SUCCESS and, when configured, passing validation. Start with a small Analyze → Fix → Validate loop.")
                                    .font(AppTheme.Font.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            fieldGroup {
                                HStack(spacing: 6) {
                                    Text("Launch context")
                                        .font(AppTheme.Font.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.mutedText)
                                    LoopInlineInfoButton(
                                        title: "Launch context / arguments",
                                        rows: launchContextInfoRows
                                    )
                                }
                            } content: {
                                TextEditor(text: launchContextBinding)
                                    .font(AppTheme.Font.body)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(minHeight: 76)
                                    .background(AppTheme.textContentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(AppTheme.contentStroke, lineWidth: 1)
                                    }
                                if draft.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                                    Picker("Context scope", selection: $draft.launchContextScope) {
                                        ForEach(LoopLaunchContextScope.allCases) { scope in
                                            Text(scope.displayName).tag(scope)
                                        }
                                    }
                                    .labelsHidden()
                                    .appMenuPicker()
                                }
                            }

                            HStack(spacing: 8) {
                                Text("Max iterations")
                                    .font(AppTheme.Font.body)
                                LoopNumericStepper(value: $draft.maxIterations, range: 0...LoopDraft.maximumMaxIterations)
                                Button(draft.maxIterations == 0 ? "No limit" : "Set no limit") {
                                    draft.maxIterations = 0
                                }
                                .buttonStyle(.link)
                                .font(AppTheme.Font.caption)

                                LoopInlineInfoButton(
                                    title: "Max iterations",
                                    message: "A hard safety limit for repeated work. Set 0 for no iteration limit so the loop continues until it reaches its goal or another stop condition."
                                )
                            }
                        }
                    }

                    structureFields

                    AppCard(title: "Validation (optional)") {
                        fieldGroup {
                            HStack(spacing: 6) {
                                Text("Command")
                                    .font(AppTheme.Font.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedText)
                                LoopInlineInfoButton(
                                    title: "Validation command (optional)",
                                    message: "Agent Deck can run one shell command after each loop iteration, from the project directory when available. Its output is attached to the iteration so the loop/checker can use it as evidence. Leave this empty to skip automatic validation."
                                )
                            }
                        } content: {
                            AppTextField(text: $draft.validationCommand, placeholder: "Optional, e.g. swift test")
                                .frame(maxWidth: .infinity)
                            Text("Leave empty to skip automatic validation. When configured, this command must pass and the evaluator must return SUCCESS before the loop can succeed.")
                                .font(AppTheme.Font.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if canSaveToLoopBank {
                        loopBankSection
                    }
                }
                .padding(24)
            }

            Divider()

            sheetFooter
        }
        .frame(width: 560, height: 640)
        .onChange(of: saveToLoopBank) { _, enabled in
            guard enabled, saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            saveName = defaultSaveName()
        }
        .onChange(of: draft.writeTarget) { _, target in
            if target != .currentCheckout {
                confirmsCurrentCheckoutWrite = false
            }
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "infinity")
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppTheme.brandAccent)
                .frame(width: 34, height: 34)
                .background(AppTheme.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .fontWidth(.expanded)
                Text(sourceDefinition == nil ? "Unsaved loop · \(session.title)" : "Saved loop · \(session.title)")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                isInfoPresented.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .help("Explain loops")
            .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                LoopLaunchInfoPopover()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .appSecondaryButton()
                .keyboardShortcut(.cancelAction)
            Button(saveToLoopBank ? "Save & Launch" : "Launch") {
                onLaunch(LoopLaunchRequest(
                    draft: draft,
                    stopExistingActive: stopExistingActive,
                    saveRequest: makeSaveRequest()
                ))
            }
            .appPrimaryButton()
            .keyboardShortcut(.defaultAction)
            .disabled(!canLaunch)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func activeLoopWarning(_ activeRun: LoopRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This transcript already has an active loop.", systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Font.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text(activeRun.goal)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(2)
            Toggle("Stop it and start this loop", isOn: $stopExistingActive)
                .appSwitch()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.20), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var deckAgentsPreflightSection: some View {
        if loopRequiresDeckAgents && !session.subagentsEnabled {
            VStack(alignment: .leading, spacing: 10) {
                Label("Deck agents are disabled for this session.", systemImage: "paperplane.circle")
                    .font(AppTheme.Font.body.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("This loop launches child Deck agents. Enable Deck agents for this session before launching.")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onEnableDeckAgents()
                } label: {
                    Label("Enable Deck agents", systemImage: "checkmark.circle")
                }
                .appTintedSecondaryButton(.orange)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.orange.opacity(0.20), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var loopPreflightSection: some View {
        if !agentPreflightIssues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Fix loop agent configuration before launch.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(AppTheme.Font.body.weight(.semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agentPreflightIssues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• \(issue.name) — \(issue.kind.title)")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(issue.kind.remediation)
                                .font(AppTheme.Font.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
                Text("Agent Deck will not guess replacements or silently enable disabled agents.")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        onAssignMissingAgents(assignablePreflightAgentNames)
                    } label: {
                        Label("Assign fixable agents", systemImage: "plus.circle")
                    }
                    .appTintedSecondaryButton(.orange)
                    .disabled(session.projectPathForProjectFeatures == nil || assignablePreflightAgentNames.isEmpty)
                    .help(assignablePreflightAgentNames.isEmpty ? "No unassigned existing agents can be fixed automatically." : "Assign existing unassigned agents to the current project")

                    if session.projectPathForProjectFeatures == nil {
                        Text("No project path available.")
                            .font(AppTheme.Font.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                    } else if assignablePreflightAgentNames.isEmpty {
                        Text("Open Agents to enable/create the listed agents, or choose different agents.")
                            .font(AppTheme.Font.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.orange.opacity(0.20), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var parallelSafetyPreflightSection: some View {
        if draft.structure == .parallelAgents && draft.writeTarget != .artifactMarkdown {
            Label("Parallel agents are report-only. Select Artifact / Markdown output to launch.", systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var launchContextInfoRows: [LoopInlineInfoButton.Row] {
        [
            .init("What it is", "Optional background or arguments added to child-agent launch prompts, kept separate from the loop goal."),
            .init("Good uses", "Paste repro steps, observed hitches or hangs, logs, device state, or constraints such as report-only or avoid API changes."),
            .init("Scope", "First iteration only seeds the loop once. Every iteration repeats this context in each prompt when constraints must stay visible.")
        ]
    }

    private var structureFields: some View {
        AppCard(title: draft.structure.displayName) {
            VStack(alignment: .leading, spacing: 14) {
                switch draft.structure {
                case .makerChecker:
                    fieldGroup("Maker agent") {
                        LoopAgentNameMenu(selection: $draft.makerChecker.makerName, availableAgents: availableAgents, fallbackLabel: "Maker")
                    }
                    fieldGroup("Checker agent") {
                        LoopAgentNameMenu(selection: $draft.makerChecker.checkerName, availableAgents: availableAgents, fallbackLabel: "Checker")
                    }
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text("Checker rubric")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: "Checker rubric",
                                message: "Tells the checker how to decide whether the maker's result is acceptable, should be retried, needs a human, or should fail the loop."
                            )
                        }
                    } content: {
                        AppTextField(
                            text: $draft.makerChecker.checkerRubric,
                            placeholder: "approve, continue, reject once, ask human, or fail",
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        Text("Checker is report-only. In this deterministic preview runner, the rubric controls the checker result.")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .agentPipeline:
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text("Stages")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: "Pipeline stages",
                                message: "Choose the agents/roles that run in sequence. The loop records the handoff order now; runner work will attach actual child agent runs to these stages."
                            )
                        }
                    } content: {
                        LoopPipelineStagePicker(stages: pipelineStagesBinding, availableAgents: availableAgents)
                        Text("Runs selected agents in this fixed order and records the timeline.")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                case .parallelAgents:
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text("Parallel agents")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: "Parallel agents",
                                message: "Select enabled project agents. Parallel loops are report-only to prevent concurrent writes to one checkout or worktree."
                            )
                        }
                    } content: {
                        LoopPipelineStagePicker(stages: parallelAgentsBinding, availableAgents: availableAgents)
                        Text("Each selected agent investigates independently. Use a later single-agent or pipeline loop to make changes.")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                case .discoveryTriage:
                    fieldGroup("Triage agent") {
                        LoopAgentNameMenu(selection: $draft.discoveryTriage.agentName, availableAgents: availableAgents, fallbackLabel: "Explorer")
                    }
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text("Classification prompt")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: "Classification prompt",
                                message: "Instruction used by discovery triage to sort findings by severity and recommend the next action."
                            )
                        }
                    } content: {
                        AppTextField(text: $draft.discoveryTriage.classificationPrompt, placeholder: "Classification prompt", axis: .vertical)
                            .lineLimit(2...4)
                    }
                case .humanApproval:
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text("Checkpoint prompt")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: "Checkpoint prompt",
                                message: "The message shown for an approval checkpoint. Recording approval does not resume this same run."
                            )
                        }
                    } content: {
                        AppTextField(text: $draft.humanApproval.checkpointPrompt, placeholder: "Checkpoint prompt", axis: .vertical)
                            .lineLimit(2...4)
                        Text("This records a terminal approval or rejection checkpoint; start a new attempt for follow-up work.")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                case .singleAgent:
                    fieldGroup("Agent") {
                        LoopAgentNameMenu(selection: $draft.makerChecker.makerName, availableAgents: availableAgents, fallbackLabel: "Agent")
                    }
                    Text("Runs the selected agent against the selected write target.")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private var loopBankSection: some View {
        AppCard(title: "Loop Bank") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Save to Loop Bank before launch", isOn: $saveToLoopBank)
                    .appSwitch()
                if saveToLoopBank {
                    fieldGroup("Name") {
                        AppTextField(text: $saveName, placeholder: "Name")
                    }
                    fieldGroup("Description") {
                        AppTextField(text: $saveDescription, placeholder: "Description", axis: .vertical)
                            .lineLimit(2...4)
                    }
                    Toggle("Available only in this project", isOn: $saveForCurrentProjectOnly)
                        .appSwitch()
                        .disabled(session.projectPathForProjectFeatures == nil)
                }
            }
        }
    }

    private func pickerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 96, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fieldGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        fieldGroup {
            Text(label)
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
        } content: {
            content()
        }
    }

    private func fieldGroup<Label: View, Content: View>(@ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var writeTargetExplanation: some View {
        switch draft.writeTarget {
        case .artifactMarkdown:
            Text("Writes only to the loop artifact directory. Project files are not modified.")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
        case .newWorktree:
            Text("Explicit coding target. Agent Deck creates a per-run git worktree and runs validation there; the current checkout remains untouched.")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
        case .currentCheckout:
            VStack(alignment: .leading, spacing: 8) {
                Label("Direct write target: this loop may edit files in the current checkout.", systemImage: "exclamationmark.triangle.fill")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Resolved path: \(session.projectPathForProjectFeatures ?? "Unavailable")")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                Toggle("I understand this loop may modify the current checkout", isOn: $confirmsCurrentCheckoutWrite)
                    .appSwitch()
            }
        }
    }

    private func makeSaveRequest() -> LoopSaveRequest? {
        guard saveToLoopBank else { return nil }
        let currentProjectPaths = (saveForCurrentProjectOnly ? session.projectPathForProjectFeatures.map { [$0] } : nil) ?? []
        return LoopSaveRequest(
            name: saveName,
            description: saveDescription,
            availability: currentProjectPaths.isEmpty ? .allProjects : .projectPaths,
            projectPaths: currentProjectPaths
        )
    }

    private func defaultSaveName() -> String {
        let firstLine = trimmedGoal.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled Loop" }
        return String(trimmed.prefix(64))
    }

}

struct LoopAgentNameMenu: View {
    @Binding var selection: String
    let availableAgents: [EffectiveAgentRecord]
    let fallbackLabel: String

    private var names: [String] {
        var seen = Set<String>()
        return ([selection] + availableAgents.map(\.name))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(fallbackLabel, selection: $selection) {
                Text("Select \(fallbackLabel)…").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .appMenuPicker()
            if !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !availableAgents.map(\.name).contains(selection) {
                Label("Saved role not available in this project", systemImage: "exclamationmark.triangle")
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct LoopPipelineStagePicker: View {
    @Binding var stages: [String]
    let availableAgents: [EffectiveAgentRecord]

    private var agentNames: [String] {
        availableAgents.map(\.name)
    }

    private var pickerNames: [String] {
        var seen = Set<String>()
        return (stages + agentNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(stages.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    stageRow(index)
                    if index < stages.count - 1 {
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(AppTheme.contentStroke)
                                .frame(width: 1, height: 12)
                                .padding(.leading, 15)
                            Image(systemName: "arrow.down")
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            Text("then")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    addStage()
                } label: {
                    Label("Add stage", systemImage: "plus")
                }
                .appSecondaryButton()
                .disabled(pickerNames.isEmpty)

                if availableAgents.isEmpty {
                    Text("No agents available yet.")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .onAppear(perform: ensureValidStages)
        .onChange(of: availableAgents.map(\.name)) { _, _ in ensureValidStages() }
    }

    private func stageRow(_ index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(AppTheme.Font.caption.weight(.bold))
                .foregroundStyle(AppTheme.brandAccent)
                .frame(width: 26, height: 26)
                .background(AppTheme.brandAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Picker("Stage \(index + 1)", selection: stageBinding(index)) {
                    Text("Select Agent…").tag("")
                    ForEach(pickerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .appMenuPicker()

                if let stageName = stageName(at: index), !stageName.isEmpty, !agentNames.contains(stageName) {
                    Label("Saved stage not available", systemImage: "exclamationmark.triangle")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                moveStage(from: index, by: -1)
            } label: {
                Label("Move earlier", systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .disabled(index == 0)
            .help("Move earlier")

            Button {
                moveStage(from: index, by: 1)
            } label: {
                Label("Move later", systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .disabled(index >= stages.count - 1)
            .help("Move later")

            Button {
                removeStage(at: index)
            } label: {
                Label("Remove stage", systemImage: "minus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText.opacity(stages.count > 1 ? 1 : 0.45))
            .disabled(stages.count <= 1)
            .help("Remove stage")
        }
        .padding(10)
        .background(AppTheme.textContentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        }
    }

    private func stageName(at index: Int) -> String? {
        stages.indices.contains(index) ? stages[index] : nil
    }

    private func stageBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { stages.indices.contains(index) ? stages[index] : "" },
            set: { newValue in
                guard stages.indices.contains(index) else { return }
                stages[index] = newValue
                ensureValidStages()
            }
        )
    }

    private func addStage() {
        stages.append(firstUnusedAgentName() ?? "")
        ensureValidStages()
    }

    private func removeStage(at index: Int) {
        guard stages.count > 1, stages.indices.contains(index) else { return }
        stages.remove(at: index)
        ensureValidStages()
    }

    private func moveStage(from index: Int, by delta: Int) {
        let target = index + delta
        guard stages.indices.contains(index), stages.indices.contains(target) else { return }
        stages.swapAt(index, target)
    }

    private func ensureValidStages() {
        let cleaned = stages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if cleaned != stages {
            stages = cleaned
        }
    }

    private func firstUnusedAgentName() -> String? {
        let used = Set(stages)
        return agentNames.first { !used.contains($0) } ?? agentNames.first
    }
}

struct LoopInlineInfoButton: View {
    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let description: String

        init(_ title: String, _ description: String) {
            self.title = title
            self.description = description
        }
    }

    let title: String
    let message: String?
    let rows: [Row]
    @State private var isPresented = false

    init(title: String, message: String) {
        self.title = title
        self.message = message
        self.rows = []
    }

    init(title: String, rows: [Row]) {
        self.title = title
        self.message = nil
        self.rows = rows
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Explain \(title)")
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(AppTheme.brandAccent)
                    Text(title)
                        .font(.headline)
                        .fontWidth(.expanded)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            infoRow(row.title, row.description)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: rows.isEmpty ? 320 : 430, alignment: .leading)
        }
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

struct LoopLaunchInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "infinity")
                    .foregroundStyle(AppTheme.brandAccent)
                Text("Loops")
                    .font(.headline)
                    .fontWidth(.expanded)
            }

            VStack(alignment: .leading, spacing: 10) {
                infoRow("What runs", "A loop repeatedly asks Pi to work toward the goal, records each iteration, and stops when it reaches the max iterations or needs attention.")
                infoRow("Structure", "Choose a single agent, maker/checker review, a pipeline, parallel branches, discovery triage, or a human approval checkpoint.")
                infoRow("Write target", "Artifact writes keep project files untouched. Worktree writes isolate code changes. Current checkout writes directly to this project.")
                infoRow("Goal evaluator", "After each iteration, a report-only natural-language evaluator decides SUCCESS, CONTINUE, or FAIL against the success condition. Only an exact SUCCESS can complete the loop.")
            infoRow("Validation (optional)", "If configured, Agent Deck runs this shell command after each loop iteration. It must pass, in addition to evaluator SUCCESS, before the loop can succeed. Leave it empty to skip automatic validation.")
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
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
