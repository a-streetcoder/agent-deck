import SwiftUI

struct LoopLaunchSheet: View {
    @ObservedObject private var languageStore = LanguageStore.shared
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

                    AppCard(title: languageStore.t("loopLaunch.loopCard")) {
                        VStack(alignment: .leading, spacing: 14) {
                            pickerRow(languageStore.t("loopLaunch.structurePicker")) {
                                HStack(spacing: 8) {
                                    Picker(languageStore.t("loopLaunch.structurePicker"), selection: $draft.structure) {
                                        ForEach(LoopStructureKind.allCases) { kind in
                                            Text(kind.displayName).tag(kind)
                                        }
                                    }
                                    .labelsHidden()
                                    .appMenuPicker()

                                    LoopInlineInfoButton(
                                        title: languageStore.t("loopLaunch.structurePicker"),
                                        rows: [
                                            .init(languageStore.t("loopLaunch.struct.single"), languageStore.t("loopLaunch.struct.singleBody")),
                                            .init(languageStore.t("loopLaunch.struct.maker"), languageStore.t("loopLaunch.struct.makerBody")),
                                            .init(languageStore.t("loopLaunch.struct.pipeline"), languageStore.t("loopLaunch.struct.pipelineBody")),
                                            .init(languageStore.t("loopLaunch.struct.parallel"), languageStore.t("loopLaunch.struct.parallelBody")),
                                            .init(languageStore.t("loopLaunch.struct.discovery"), languageStore.t("loopLaunch.struct.discoveryBody")),
                                            .init(languageStore.t("loopLaunch.struct.approval"), languageStore.t("loopLaunch.struct.approvalBody")),
                                        ]
                                    )
                                }
                            }

                            pickerRow(languageStore.t("loopLaunch.writeTargetTitle")) {
                                HStack(spacing: 8) {
                                    Picker(languageStore.t("loopLaunch.writeTargetTitle"), selection: $draft.writeTarget) {
                                        ForEach(LoopWriteTarget.allCases) { target in
                                            Text(target.displayName).tag(target)
                                        }
                                    }
                                    .labelsHidden()
                                    .appMenuPicker()

                                    LoopInlineInfoButton(
                                        title: languageStore.t("loopLaunch.writeTargetTitle"),
                                        rows: [
                                            .init(languageStore.t("loopLaunch.write.artifact"), languageStore.t("loopLaunch.write.artifactBody")),
                                            .init(languageStore.t("loopLaunch.write.worktree"), languageStore.t("loopLaunch.write.worktreeBody")),
                                            .init(languageStore.t("loopLaunch.struct.checkout"), languageStore.t("loopLaunch.struct.checkoutBody"))
                                        ]
                                    )
                                }
                            }

                            writeTargetExplanation

                            fieldGroup(languageStore.t("loopLaunch.goal")) {
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
                                    Text(languageStore.t("loopLaunch.successCondition"))
                                        .font(AppTheme.Font.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.mutedText)
                                    LoopInlineInfoButton(
                                        title: languageStore.t("loopLaunch.goalEvaluator"),
                                        message: languageStore.t("loopLaunch.goalEvaluatorHelp")
                                    )
                                }
                            } content: {
                                AppTextField(text: successConditionBinding, placeholder: languageStore.t("loopLaunch.successPlaceholder"), axis: .vertical)
                                    .lineLimit(2...4)
                                HStack(spacing: 8) {
                                    AppTextField(text: evaluatorModelBinding, placeholder: languageStore.t("loopLaunch.evaluatorModel"))
                                    AppTextField(text: evaluatorThinkingBinding, placeholder: languageStore.t("loopLaunch.thinkingDefault"))
                                }
                                Text(languageStore.t("loopLaunch.completionNote"))
                                    .font(AppTheme.Font.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            fieldGroup {
                                HStack(spacing: 6) {
                                    Text(languageStore.t("loopLaunch.launchContext"))
                                        .font(AppTheme.Font.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.mutedText)
                                    LoopInlineInfoButton(
                                        title: languageStore.t("loopLaunch.launchContextTitle"),
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
                                Text(languageStore.t("loopLaunch.maxIterations"))
                                    .font(AppTheme.Font.body)
                                LoopNumericStepper(value: $draft.maxIterations, range: 0...LoopDraft.maximumMaxIterations)
                                Button(draft.maxIterations == 0 ? languageStore.t("loopLaunch.noLimit") : languageStore.t("loopLaunch.setNoLimit")) {
                                    draft.maxIterations = 0
                                }
                                .buttonStyle(.link)
                                .font(AppTheme.Font.caption)

                                LoopInlineInfoButton(
                                    title: languageStore.t("loopLaunch.maxIterations"),
                                    message: languageStore.t("loopLaunch.maxIterationsHelp")
                                )
                            }
                        }
                    }

                    structureFields

                    AppCard(title: languageStore.t("loopLaunch.validationOptional")) {
                        fieldGroup {
                            HStack(spacing: 6) {
                                Text(languageStore.t("loopLaunch.command"))
                                    .font(AppTheme.Font.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedText)
                                LoopInlineInfoButton(
                                    title: languageStore.t("loopLaunch.validationOptional"),
                                    message: languageStore.t("loopLaunch.validationHelp")
                                )
                            }
                        } content: {
                            AppTextField(text: $draft.validationCommand, placeholder: languageStore.t("loopLaunch.validationPlaceholder"))
                                .frame(maxWidth: .infinity)
                            Text(languageStore.t("loopLaunch.validationNote"))
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
        .frame(
            minWidth: 420,
            idealWidth: 560,
            maxWidth: 760,
            minHeight: 520,
            idealHeight: 640,
            maxHeight: 800
        )
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
                Text(String(format: languageStore.t(sourceDefinition == nil ? "loopLaunch.unsaved" : "loopLaunch.saved"), session.title))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                isInfoPresented.toggle()
            } label: {
                Label(languageStore.t("loopLaunch.info"), systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .help(languageStore.t("loopLaunch.explain"))
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
            Button(languageStore.t("common.cancel"), action: onCancel)
                .appSecondaryButton()
                .keyboardShortcut(.cancelAction)
            Button(saveToLoopBank ? languageStore.t("loopLaunch.saveAndLaunch") : languageStore.t("loopLaunch.launch")) {
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
            Label(languageStore.t("loopLaunch.activeWarning"), systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Font.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text(activeRun.goal)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(2)
            Toggle(languageStore.t("loopLaunch.stopAndStart"), isOn: $stopExistingActive)
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
                Label(languageStore.t("loopLaunch.deckDisabled"), systemImage: "paperplane.circle")
                    .font(AppTheme.Font.body.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(languageStore.t("loopLaunch.deckDisabledBody"))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onEnableDeckAgents()
                } label: {
                    Label(languageStore.t("loopLaunch.enableDeck"), systemImage: "checkmark.circle")
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
                Label(languageStore.t("loopLaunch.fixConfig"), systemImage: "person.crop.circle.badge.exclamationmark")
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
                Text(languageStore.t("loopLaunch.noGuess"))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        onAssignMissingAgents(assignablePreflightAgentNames)
                    } label: {
                        Label(languageStore.t("loopLaunch.assignFixable"), systemImage: "plus.circle")
                    }
                    .appTintedSecondaryButton(.orange)
                    .disabled(session.projectPathForProjectFeatures == nil || assignablePreflightAgentNames.isEmpty)
                    .help(assignablePreflightAgentNames.isEmpty ? languageStore.t("loopLaunch.assignHelpEmpty") : languageStore.t("loopLaunch.assignHelp"))

                    if session.projectPathForProjectFeatures == nil {
                        Text(languageStore.t("loopLaunch.noProjectPath"))
                            .font(AppTheme.Font.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                    } else if assignablePreflightAgentNames.isEmpty {
                        Text(languageStore.t("loopLaunch.openAgents"))
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
            Label(languageStore.t("loopLaunch.parallelSafety"), systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var launchContextInfoRows: [LoopInlineInfoButton.Row] {
        [
            .init(languageStore.t("loopLaunch.contextWhat"), languageStore.t("loopLaunch.contextWhatBody")),
            .init(languageStore.t("loopLaunch.contextUses"), languageStore.t("loopLaunch.contextUsesBody")),
            .init(languageStore.t("loopLaunch.contextScope"), languageStore.t("loopLaunch.contextScopeBody"))
        ]
    }

    private var structureFields: some View {
        AppCard(title: draft.structure.displayName) {
            VStack(alignment: .leading, spacing: 14) {
                switch draft.structure {
                case .makerChecker:
                    fieldGroup(languageStore.t("loopLaunch.makerAgent")) {
                        LoopAgentNameMenu(selection: $draft.makerChecker.makerName, availableAgents: availableAgents, fallbackLabel: languageStore.t("loopLaunch.maker"))
                    }
                    fieldGroup(languageStore.t("loopLaunch.checkerAgent")) {
                        LoopAgentNameMenu(selection: $draft.makerChecker.checkerName, availableAgents: availableAgents, fallbackLabel: languageStore.t("loopLaunch.checker"))
                    }
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text(languageStore.t("loopLaunch.checkerRubric"))
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: languageStore.t("loopLaunch.checkerRubric"),
                                message: languageStore.t("loopLaunch.checkerRubricHelp")
                            )
                        }
                    } content: {
                        AppTextField(
                            text: $draft.makerChecker.checkerRubric,
                            placeholder: languageStore.t("loopLaunch.checkerRubricPlaceholder"),
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        Text(languageStore.t("loopLaunch.checkerNote"))
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .agentPipeline:
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text(languageStore.t("loopLaunch.stages"))
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: languageStore.t("loopLaunch.stages"),
                                message: languageStore.t("loopLaunch.pipelineHelp")
                            )
                        }
                    } content: {
                        LoopPipelineStagePicker(stages: pipelineStagesBinding, availableAgents: availableAgents)
                        Text(languageStore.t("loopLaunch.pipelineNote"))
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                case .parallelAgents:
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text(languageStore.t("loopLaunch.parallelAgents"))
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: languageStore.t("loopLaunch.parallelAgents"),
                                message: languageStore.t("loopLaunch.parallelHelp")
                            )
                        }
                    } content: {
                        LoopPipelineStagePicker(stages: parallelAgentsBinding, availableAgents: availableAgents)
                        Text(languageStore.t("loopLaunch.parallelNote"))
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                case .discoveryTriage:
                    fieldGroup(languageStore.t("loopLaunch.triageAgent")) {
                        LoopAgentNameMenu(selection: $draft.discoveryTriage.agentName, availableAgents: availableAgents, fallbackLabel: languageStore.t("loopLaunch.explorer"))
                    }
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text(languageStore.t("loopLaunch.classificationPrompt"))
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: languageStore.t("loopLaunch.classificationPrompt"),
                                message: languageStore.t("loopLaunch.classificationHelp")
                            )
                        }
                    } content: {
                        AppTextField(text: $draft.discoveryTriage.classificationPrompt, placeholder: languageStore.t("loopLaunch.classificationPrompt"), axis: .vertical)
                            .lineLimit(2...4)
                    }
                case .humanApproval:
                    fieldGroup {
                        HStack(spacing: 6) {
                            Text(languageStore.t("loopLaunch.checkpointPrompt"))
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            LoopInlineInfoButton(
                                title: languageStore.t("loopLaunch.checkpointPrompt"),
                                message: languageStore.t("loopLaunch.checkpointHelp")
                            )
                        }
                    } content: {
                        AppTextField(text: $draft.humanApproval.checkpointPrompt, placeholder: languageStore.t("loopLaunch.checkpointPrompt"), axis: .vertical)
                            .lineLimit(2...4)
                        Text(languageStore.t("loopLaunch.checkpointNote"))
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                case .singleAgent:
                    fieldGroup(languageStore.t("loopLaunch.agent")) {
                        LoopAgentNameMenu(selection: $draft.makerChecker.makerName, availableAgents: availableAgents, fallbackLabel: languageStore.t("loopLaunch.agent"))
                    }
                    Text(languageStore.t("loopLaunch.singleNote"))
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private var loopBankSection: some View {
        AppCard(title: languageStore.t("loopLaunch.loopBank")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(languageStore.t("loopLaunch.saveBefore"), isOn: $saveToLoopBank)
                    .appSwitch()
                if saveToLoopBank {
                    fieldGroup(languageStore.t("loopLaunch.name")) {
                        AppTextField(text: $saveName, placeholder: languageStore.t("loopLaunch.name"))
                    }
                    fieldGroup(languageStore.t("loopLaunch.description")) {
                        AppTextField(text: $saveDescription, placeholder: languageStore.t("loopLaunch.description"), axis: .vertical)
                            .lineLimit(2...4)
                    }
                    Toggle(languageStore.t("loopLaunch.projectOnly"), isOn: $saveForCurrentProjectOnly)
                        .appSwitch()
                        .disabled(session.projectPathForProjectFeatures == nil)
                }
            }
        }
    }

    private func pickerRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        LoopPickerRow(label, content: content)
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
            Text(languageStore.t("loopLaunch.writeArtifact"))
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
        case .newWorktree:
            Text(languageStore.t("loopLaunch.writeWorktree"))
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
        case .currentCheckout:
            VStack(alignment: .leading, spacing: 8) {
                Label(languageStore.t("loopLaunch.directWrite"), systemImage: "exclamationmark.triangle.fill")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(String(format: languageStore.t("loopLaunch.resolvedPath"), session.projectPathForProjectFeatures ?? languageStore.t("loopLaunch.unavailable")))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                Toggle(languageStore.t("loopLaunch.confirmCheckout"), isOn: $confirmsCurrentCheckoutWrite)
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
        if trimmed.isEmpty { return languageStore.t("loopLaunch.untitled") }
        return String(trimmed.prefix(64))
    }

}

/// Shared production picker-row layout for the Loop launch sheet. Kept
/// internal so layout tests can exercise the real compact fallback.
struct LoopPickerRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                rowLabel
                    .frame(width: 96, alignment: .leading)
                content
                    .frame(minWidth: 220, idealWidth: 420, maxWidth: 620, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                rowLabel
                content
                    .frame(minWidth: 180, idealWidth: 320, maxWidth: 620, alignment: .leading)
            }
        }
    }

    private var rowLabel: some View {
        Text(label)
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(AppTheme.mutedText)
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
                Text(String(format: LanguageStore.shared.t("loopLaunch.selectFallback"), fallbackLabel)).tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .appMenuPicker()
            if !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !availableAgents.map(\.name).contains(selection) {
                Label(LanguageStore.shared.t("loopLaunch.roleUnavailable"), systemImage: "exclamationmark.triangle")
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
                            Text(LanguageStore.shared.t("loopLaunch.then"))
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
                    Label(LanguageStore.shared.t("loopLaunch.addStage"), systemImage: "plus")
                }
                .appSecondaryButton()
                .disabled(pickerNames.isEmpty)

                if availableAgents.isEmpty {
                    Text(LanguageStore.shared.t("loopLaunch.noAgents"))
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
                    Text(LanguageStore.shared.t("loopLaunch.selectAgent")).tag("")
                    ForEach(pickerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .appMenuPicker()

                if let stageName = stageName(at: index), !stageName.isEmpty, !agentNames.contains(stageName) {
                    Label(LanguageStore.shared.t("loopLaunch.stageUnavailable"), systemImage: "exclamationmark.triangle")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                moveStage(from: index, by: -1)
            } label: {
                Label(LanguageStore.shared.t("loopLaunch.moveEarlierLabel"), systemImage: "arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .disabled(index == 0)
            .help(LanguageStore.shared.t("loopLaunch.moveEarlier"))

            Button {
                moveStage(from: index, by: 1)
            } label: {
                Label(LanguageStore.shared.t("loopLaunch.moveLaterLabel"), systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .disabled(index >= stages.count - 1)
            .help(LanguageStore.shared.t("loopLaunch.moveLater"))

            Button {
                removeStage(at: index)
            } label: {
                Label(LanguageStore.shared.t("loopLaunch.removeStageLabel"), systemImage: "minus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText.opacity(stages.count > 1 ? 1 : 0.45))
            .disabled(stages.count <= 1)
            .help(LanguageStore.shared.t("loopLaunch.removeStage"))
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
                .appActionTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: LanguageStore.shared.t("loopLaunch.explainTitle"), title))
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
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "infinity")
                    .foregroundStyle(AppTheme.brandAccent)
                Text(languageStore.t("loopLaunch.popoverTitle"))
                    .font(.headline)
                    .fontWidth(.expanded)
            }

            VStack(alignment: .leading, spacing: 10) {
                infoRow(languageStore.t("loopLaunch.whatRuns"), languageStore.t("loopLaunch.whatRunsBody"))
                infoRow(languageStore.t("loopLaunch.structure"), languageStore.t("loopLaunch.structureBody"))
                infoRow(languageStore.t("loopLaunch.writeTarget"), languageStore.t("loopLaunch.writeTargetBody"))
                infoRow(languageStore.t("loopLaunch.goalEvalRow"), languageStore.t("loopLaunch.goalEvalRowBody"))
                infoRow(languageStore.t("loopLaunch.validationRow"), languageStore.t("loopLaunch.validationRowBody"))
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
