import Foundation

nonisolated enum LoopStructureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case singleAgent
    case makerChecker
    case agentPipeline
    case parallelAgents
    case discoveryTriage
    case humanApproval

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .singleAgent: return "Single Agent"
        case .makerChecker: return "Maker + Checker"
        case .agentPipeline: return "Agent Pipeline"
        case .parallelAgents: return "Parallel Agents"
        case .discoveryTriage: return "Discovery / Triage"
        case .humanApproval: return "Human Approval"
        }
    }
}

nonisolated enum LoopWriteTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case artifactMarkdown
    case newWorktree
    case currentCheckout

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .artifactMarkdown: return "Artifact / Markdown output"
        case .newWorktree: return "New worktree (explicit coding target)"
        case .currentCheckout: return "Current checkout (explicit/direct)"
        }
    }
}

nonisolated enum LoopRunStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case running
    case stopping
    case stopped
    case completed
    case failed
    case interrupted

    var id: String { rawValue }

    var isActive: Bool {
        self == .running || self == .stopping
    }

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }
}

nonisolated enum LoopWorktreeState: String, Codable, Equatable, Sendable {
    case available
    case applied
    case discarded
}

nonisolated enum LoopStopReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case success
    case maxIterationsReached
    case userStopped
    case validationUnavailable
    case validationFailedAfterFinalIteration
    case unsafeWriteTarget
    case humanInputRequired
    case humanRejected
    case agentFailed
    case toolFailed
    case appInterrupted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .success: return "Success"
        case .maxIterationsReached: return "Max iterations reached"
        case .userStopped: return "User stopped"
        case .validationUnavailable: return "Validation unavailable"
        case .validationFailedAfterFinalIteration: return "Validation failed after final iteration"
        case .unsafeWriteTarget: return "Unsafe write target"
        case .humanInputRequired: return "Human input required"
        case .humanRejected: return "Human rejected"
        case .agentFailed: return "Agent failed"
        case .toolFailed: return "Tool failed"
        case .appInterrupted: return "App interrupted"
        }
    }
}

nonisolated struct LoopMakerCheckerConfig: Codable, Equatable, Hashable, Sendable {
    var makerName: String
    var checkerName: String
    var checkerRubric: String

    init(makerName: String = "", checkerName: String = "", checkerRubric: String = "approve") {
        self.makerName = makerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.checkerName = checkerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.checkerRubric = checkerRubric
    }
}

nonisolated struct LoopPipelineConfig: Codable, Equatable, Hashable, Sendable {
    var stageNames: [String]

    init(stageNames: [String] = []) {
        self.stageNames = stageNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

nonisolated struct LoopParallelConfig: Codable, Equatable, Hashable, Sendable {
    var branchNames: [String]

    init(branchNames: [String] = ["Branch A", "Branch B"]) {
        let trimmed = branchNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.branchNames = trimmed.isEmpty ? ["Branch A", "Branch B"] : trimmed
    }
}

nonisolated struct LoopDiscoveryTriageConfig: Codable, Equatable, Hashable, Sendable {
    var agentName: String
    var classificationPrompt: String

    init(agentName: String = "", classificationPrompt: String = "Classify findings by severity and summarize recommended next action.") {
        self.agentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = classificationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.classificationPrompt = trimmedPrompt.isEmpty ? "Classify findings by severity and summarize recommended next action." : classificationPrompt
    }

    enum CodingKeys: String, CodingKey { case agentName, classificationPrompt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName) ?? "Explorer"
        classificationPrompt = try container.decodeIfPresent(String.self, forKey: .classificationPrompt) ?? "Classify findings by severity and summarize recommended next action."
        self = LoopDiscoveryTriageConfig(agentName: agentName, classificationPrompt: classificationPrompt)
    }
}

nonisolated struct LoopHumanApprovalConfig: Codable, Equatable, Hashable, Sendable {
    var checkpointPrompt: String

    init(checkpointPrompt: String = "Review the proposal before continuing.") {
        self.checkpointPrompt = checkpointPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Review the proposal before continuing." : checkpointPrompt
    }
}

nonisolated enum LoopCheckerResult: String, Codable, CaseIterable, Identifiable, Sendable {
    case approve
    case reject
    case continueLoop = "continue"
    case askHuman
    case fail

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .approve: return "Approve"
        case .reject: return "Reject"
        case .continueLoop: return "Continue"
        case .askHuman: return "Ask human"
        case .fail: return "Fail"
        }
    }
}

nonisolated enum LoopGoalEvaluationResult: String, Codable, CaseIterable, Identifiable, Sendable {
    case success
    case continueLoop = "continue"
    case fail

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .success: return "SUCCESS"
        case .continueLoop: return "CONTINUE"
        case .fail: return "FAIL"
        }
    }
}

nonisolated struct LoopGoalEvaluationConfig: Codable, Equatable, Hashable, Sendable {
    var successCondition: String
    var model: String?
    var thinkingLevel: String?

    init(successCondition: String = "", model: String? = nil, thinkingLevel: String? = nil) {
        self.successCondition = successCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.thinkingLevel = thinkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    enum CodingKeys: String, CodingKey { case successCondition, model, thinkingLevel }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            successCondition: try container.decodeIfPresent(String.self, forKey: .successCondition) ?? "",
            model: try container.decodeIfPresent(String.self, forKey: .model),
            thinkingLevel: try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        )
    }
}

nonisolated struct LoopGoalEvaluation: Codable, Equatable, Sendable {
    var result: LoopGoalEvaluationResult
    var rationale: String
    var childRunID: UUID?

    init(result: LoopGoalEvaluationResult, rationale: String = "", childRunID: UUID? = nil) {
        self.result = result
        self.rationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        self.childRunID = childRunID
    }
}

nonisolated enum LoopTimelineStepKind: String, Codable, Sendable {
    case makerAct
    case checkerReview
    case pipelineStage
    case parallelBranch
    case discoveryTriage
    case humanApprovalCheckpoint
}

nonisolated struct LoopTimelineEvent: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var step: LoopTimelineStepKind
    var roleName: String
    var note: String
    var timestamp: Date

    init(id: UUID = UUID(), step: LoopTimelineStepKind, roleName: String, note: String, timestamp: Date = Date()) {
        self.id = id
        self.step = step
        self.roleName = roleName
        self.note = note
        self.timestamp = timestamp
    }
}

nonisolated enum LoopLaunchContextScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case firstIterationOnly
    case everyIteration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .firstIterationOnly: return "First iteration only"
        case .everyIteration: return "Every iteration"
        }
    }
}

nonisolated struct LoopDraft: Codable, Equatable, Sendable {
    var goal: String
    var launchContext: String?
    var launchContextScope: LoopLaunchContextScope
    var structure: LoopStructureKind
    var writeTarget: LoopWriteTarget
    var maxIterations: Int
    var validationCommand: String
    var goalEvaluation: LoopGoalEvaluationConfig
    var makerChecker: LoopMakerCheckerConfig
    var pipeline: LoopPipelineConfig
    var parallel: LoopParallelConfig
    var discoveryTriage: LoopDiscoveryTriageConfig
    var humanApproval: LoopHumanApprovalConfig

    static let defaultMaxIterations = 3
    static let maximumMaxIterations = 100

    init(
        goal: String = "",
        launchContext: String? = nil,
        launchContextScope: LoopLaunchContextScope = .firstIterationOnly,
        structure: LoopStructureKind = .singleAgent,
        writeTarget: LoopWriteTarget = .artifactMarkdown,
        maxIterations: Int = Self.defaultMaxIterations,
        validationCommand: String = "",
        goalEvaluation: LoopGoalEvaluationConfig? = nil,
        makerChecker: LoopMakerCheckerConfig = LoopMakerCheckerConfig(),
        pipeline: LoopPipelineConfig = LoopPipelineConfig(),
        parallel: LoopParallelConfig = LoopParallelConfig(),
        discoveryTriage: LoopDiscoveryTriageConfig = LoopDiscoveryTriageConfig(),
        humanApproval: LoopHumanApprovalConfig = LoopHumanApprovalConfig()
    ) {
        self.goal = goal
        self.launchContext = launchContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.launchContextScope = launchContextScope
        self.structure = structure
        self.writeTarget = writeTarget
        self.maxIterations = max(0, maxIterations)
        self.validationCommand = validationCommand
        self.goalEvaluation = goalEvaluation ?? LoopGoalEvaluationConfig(successCondition: self.goal)
        self.makerChecker = makerChecker
        self.pipeline = pipeline
        self.parallel = parallel
        self.discoveryTriage = discoveryTriage
        self.humanApproval = humanApproval
    }

    enum CodingKeys: String, CodingKey {
        case goal, launchContext, launchContextScope, structure, writeTarget, maxIterations, validationCommand, goalEvaluation, makerChecker, pipeline, parallel, discoveryTriage, humanApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            goal: try container.decodeIfPresent(String.self, forKey: .goal) ?? "",
            launchContext: try container.decodeIfPresent(String.self, forKey: .launchContext),
            launchContextScope: try container.decodeIfPresent(LoopLaunchContextScope.self, forKey: .launchContextScope) ?? .firstIterationOnly,
            structure: try container.decodeIfPresent(LoopStructureKind.self, forKey: .structure) ?? .singleAgent,
            writeTarget: try container.decodeIfPresent(LoopWriteTarget.self, forKey: .writeTarget) ?? .artifactMarkdown,
            maxIterations: try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? Self.defaultMaxIterations,
            validationCommand: try container.decodeIfPresent(String.self, forKey: .validationCommand) ?? "",
            goalEvaluation: try container.decodeIfPresent(LoopGoalEvaluationConfig.self, forKey: .goalEvaluation),
            makerChecker: try container.decodeIfPresent(LoopMakerCheckerConfig.self, forKey: .makerChecker) ?? LoopMakerCheckerConfig(),
            pipeline: try container.decodeIfPresent(LoopPipelineConfig.self, forKey: .pipeline) ?? LoopPipelineConfig(),
            parallel: try container.decodeIfPresent(LoopParallelConfig.self, forKey: .parallel) ?? LoopParallelConfig(),
            discoveryTriage: try container.decodeIfPresent(LoopDiscoveryTriageConfig.self, forKey: .discoveryTriage) ?? LoopDiscoveryTriageConfig(),
            humanApproval: try container.decodeIfPresent(LoopHumanApprovalConfig.self, forKey: .humanApproval) ?? LoopHumanApprovalConfig()
        )
    }
}

nonisolated enum LoopDefinitionSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case user
    case builtin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .user: return "User"
        case .builtin: return "Built-in"
        }
    }
}

nonisolated enum LoopDefinitionAvailability: String, Codable, CaseIterable, Identifiable, Sendable {
    case allProjects
    case projectPaths

    var id: String { rawValue }
}

nonisolated struct LoopDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var goalTemplate: String
    var launchContext: String?
    var launchContextScope: LoopLaunchContextScope
    var structure: LoopStructureKind
    var writeTarget: LoopWriteTarget
    var maxIterations: Int
    var validationCommand: String
    var goalEvaluation: LoopGoalEvaluationConfig
    var makerChecker: LoopMakerCheckerConfig
    var pipeline: LoopPipelineConfig
    var parallel: LoopParallelConfig
    var discoveryTriage: LoopDiscoveryTriageConfig
    var humanApproval: LoopHumanApprovalConfig
    var source: LoopDefinitionSource
    var availability: LoopDefinitionAvailability
    var projectPaths: [String]
    var filePath: String?
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        goalTemplate: String = "",
        launchContext: String? = nil,
        launchContextScope: LoopLaunchContextScope = .firstIterationOnly,
        structure: LoopStructureKind = .singleAgent,
        writeTarget: LoopWriteTarget = .artifactMarkdown,
        maxIterations: Int = LoopDraft.defaultMaxIterations,
        validationCommand: String = "",
        goalEvaluation: LoopGoalEvaluationConfig? = nil,
        makerChecker: LoopMakerCheckerConfig = LoopMakerCheckerConfig(),
        pipeline: LoopPipelineConfig = LoopPipelineConfig(),
        parallel: LoopParallelConfig = LoopParallelConfig(),
        discoveryTriage: LoopDiscoveryTriageConfig = LoopDiscoveryTriageConfig(),
        humanApproval: LoopHumanApprovalConfig = LoopHumanApprovalConfig(),
        source: LoopDefinitionSource = .user,
        availability: LoopDefinitionAvailability = .allProjects,
        projectPaths: [String] = [],
        filePath: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.goalTemplate = goalTemplate
        self.launchContext = launchContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.launchContextScope = launchContextScope
        self.structure = structure
        self.writeTarget = writeTarget
        self.maxIterations = max(0, maxIterations)
        self.validationCommand = validationCommand
        self.goalEvaluation = goalEvaluation ?? LoopGoalEvaluationConfig(successCondition: self.goalTemplate)
        self.makerChecker = makerChecker
        self.pipeline = pipeline
        self.parallel = parallel
        self.discoveryTriage = discoveryTriage
        self.humanApproval = humanApproval
        self.source = source
        self.availability = availability
        self.projectPaths = projectPaths
        self.filePath = filePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, goalTemplate, launchContext, launchContextScope, structure, writeTarget, maxIterations, validationCommand, goalEvaluation, makerChecker, pipeline, parallel, discoveryTriage, humanApproval, source, availability, projectPaths, filePath, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let goalTemplate = try container.decodeIfPresent(String.self, forKey: .goalTemplate) ?? ""
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Loop",
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            goalTemplate: goalTemplate,
            launchContext: try container.decodeIfPresent(String.self, forKey: .launchContext),
            launchContextScope: try container.decodeIfPresent(LoopLaunchContextScope.self, forKey: .launchContextScope) ?? .firstIterationOnly,
            structure: try container.decodeIfPresent(LoopStructureKind.self, forKey: .structure) ?? .singleAgent,
            writeTarget: try container.decodeIfPresent(LoopWriteTarget.self, forKey: .writeTarget) ?? .artifactMarkdown,
            maxIterations: try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? LoopDraft.defaultMaxIterations,
            validationCommand: try container.decodeIfPresent(String.self, forKey: .validationCommand) ?? "",
            goalEvaluation: try container.decodeIfPresent(LoopGoalEvaluationConfig.self, forKey: .goalEvaluation) ?? LoopGoalEvaluationConfig(successCondition: goalTemplate),
            makerChecker: try container.decodeIfPresent(LoopMakerCheckerConfig.self, forKey: .makerChecker) ?? LoopMakerCheckerConfig(),
            pipeline: try container.decodeIfPresent(LoopPipelineConfig.self, forKey: .pipeline) ?? LoopPipelineConfig(),
            parallel: try container.decodeIfPresent(LoopParallelConfig.self, forKey: .parallel) ?? LoopParallelConfig(),
            discoveryTriage: try container.decodeIfPresent(LoopDiscoveryTriageConfig.self, forKey: .discoveryTriage) ?? LoopDiscoveryTriageConfig(),
            humanApproval: try container.decodeIfPresent(LoopHumanApprovalConfig.self, forKey: .humanApproval) ?? LoopHumanApprovalConfig(),
            source: try container.decodeIfPresent(LoopDefinitionSource.self, forKey: .source) ?? .user,
            availability: try container.decodeIfPresent(LoopDefinitionAvailability.self, forKey: .availability) ?? .allProjects,
            projectPaths: try container.decodeIfPresent([String].self, forKey: .projectPaths) ?? [],
            filePath: try container.decodeIfPresent(String.self, forKey: .filePath),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        )
    }

    func isAvailable(in projectPath: String?) -> Bool {
        switch availability {
        case .allProjects:
            return true
        case .projectPaths:
            guard let projectPath else { return false }
            return projectPaths.contains(projectPath)
        }
    }

    func makeDraft() -> LoopDraft {
        LoopDraft(
            goal: goalTemplate,
            launchContext: launchContext,
            launchContextScope: launchContextScope,
            structure: structure,
            writeTarget: writeTarget,
            maxIterations: maxIterations,
            validationCommand: validationCommand,
            goalEvaluation: goalEvaluation,
            makerChecker: makerChecker,
            pipeline: pipeline,
            parallel: parallel,
            discoveryTriage: discoveryTriage,
            humanApproval: humanApproval
        )
    }

    func exactlyMatches(run: LoopRun) -> Bool {
        run.goal == goalTemplate.trimmingCharacters(in: .whitespacesAndNewlines) &&
        run.launchContext == launchContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty &&
        run.launchContextScope == launchContextScope &&
        run.structure == structure &&
        run.writeTarget == writeTarget &&
        run.maxIterations == maxIterations &&
        run.validationCommand == validationCommand.trimmingCharacters(in: .whitespacesAndNewlines) &&
        run.goalEvaluation == goalEvaluation &&
        run.makerChecker == makerChecker &&
        run.pipeline == pipeline &&
        run.parallel == parallel &&
        run.discoveryTriage == discoveryTriage &&
        run.humanApproval == humanApproval
    }
}

nonisolated struct LoopSaveRequest: Equatable, Sendable {
    var name: String
    var description: String
    var availability: LoopDefinitionAvailability
    var projectPaths: [String]
}

nonisolated struct LoopLaunchRequest: Equatable, Sendable {
    var draft: LoopDraft
    var stopExistingActive: Bool
    var saveRequest: LoopSaveRequest?
}

nonisolated struct LoopArtifact: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var filename: String
    var markdown: String
    var filePath: String?
    var createdAt: Date

    init(id: UUID = UUID(), filename: String, markdown: String, filePath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.filename = filename
        self.markdown = markdown
        self.filePath = filePath
        self.createdAt = createdAt
    }
}

nonisolated struct LoopValidationResult: Codable, Equatable, Sendable {
    var command: String
    var workingDirectory: String?
    var exitCode: Int?
    var duration: TimeInterval
    var stdout: String
    var stderr: String
    var stdoutPath: String?
    var stderrPath: String?

    init(command: String, workingDirectory: String?, exitCode: Int?, duration: TimeInterval, stdout: String, stderr: String, stdoutPath: String? = nil, stderrPath: String? = nil) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
        self.duration = duration
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
    }

    var didPass: Bool { exitCode == 0 }
}

nonisolated struct LoopIteration: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var index: Int
    var startedAt: Date
    var endedAt: Date?
    var summary: String
    var artifacts: [LoopArtifact]
    var validationResult: LoopValidationResult?
    var goalEvaluation: LoopGoalEvaluation?
    var checkerResult: LoopCheckerResult?
    var timeline: [LoopTimelineEvent]
    var changedFiles: [String]

    init(
        id: UUID = UUID(),
        index: Int,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        summary: String = "",
        artifacts: [LoopArtifact] = [],
        validationResult: LoopValidationResult? = nil,
        goalEvaluation: LoopGoalEvaluation? = nil,
        checkerResult: LoopCheckerResult? = nil,
        timeline: [LoopTimelineEvent] = [],
        changedFiles: [String] = []
    ) {
        self.id = id
        self.index = index
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.artifacts = artifacts
        self.validationResult = validationResult
        self.goalEvaluation = goalEvaluation
        self.checkerResult = checkerResult
        self.timeline = timeline
        self.changedFiles = changedFiles
    }

    enum CodingKeys: String, CodingKey {
        case id, index, startedAt, endedAt, summary, artifacts, validationResult, goalEvaluation, checkerResult, timeline, changedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        summary = try container.decode(String.self, forKey: .summary)
        artifacts = try container.decode([LoopArtifact].self, forKey: .artifacts)
        validationResult = try container.decodeIfPresent(LoopValidationResult.self, forKey: .validationResult)
        goalEvaluation = try container.decodeIfPresent(LoopGoalEvaluation.self, forKey: .goalEvaluation)
        checkerResult = try container.decodeIfPresent(LoopCheckerResult.self, forKey: .checkerResult)
        timeline = try container.decodeIfPresent([LoopTimelineEvent].self, forKey: .timeline) ?? []
        changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
    }
}

nonisolated struct LoopRun: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var sessionID: UUID
    var projectPath: String?
    var goal: String
    var launchContext: String?
    var launchContextScope: LoopLaunchContextScope
    var structure: LoopStructureKind
    var status: LoopRunStatus
    var writeTarget: LoopWriteTarget
    var currentIteration: Int
    var maxIterations: Int
    var validationCommand: String
    var goalEvaluation: LoopGoalEvaluationConfig
    var makerChecker: LoopMakerCheckerConfig
    var pipeline: LoopPipelineConfig
    var parallel: LoopParallelConfig
    var discoveryTriage: LoopDiscoveryTriageConfig
    var humanApproval: LoopHumanApprovalConfig
    var startedAt: Date
    var endedAt: Date?
    var stopReason: LoopStopReason?
    var iterations: [LoopIteration]
    var artifactDirectoryPath: String?
    var worktreeState: LoopWorktreeState?
    var transcriptEntryID: UUID

    init(id: UUID = UUID(), sessionID: UUID, projectPath: String?, draft: LoopDraft, startedAt: Date = Date(), artifactDirectoryPath: String? = nil, transcriptEntryID: UUID = UUID()) {
        self.id = id
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.goal = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.launchContext = draft.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.launchContextScope = draft.launchContextScope
        self.structure = draft.structure
        self.status = .running
        self.writeTarget = draft.writeTarget
        self.currentIteration = 0
        self.maxIterations = max(0, draft.maxIterations)
        self.validationCommand = draft.validationCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        self.goalEvaluation = draft.goalEvaluation.successCondition.isEmpty ? LoopGoalEvaluationConfig(successCondition: self.goal, model: draft.goalEvaluation.model, thinkingLevel: draft.goalEvaluation.thinkingLevel) : draft.goalEvaluation
        self.makerChecker = draft.makerChecker
        self.pipeline = draft.pipeline
        self.parallel = draft.parallel
        self.discoveryTriage = draft.discoveryTriage
        self.humanApproval = draft.humanApproval
        self.startedAt = startedAt
        self.endedAt = nil
        self.stopReason = nil
        self.iterations = []
        self.artifactDirectoryPath = artifactDirectoryPath
        self.worktreeState = draft.writeTarget == .newWorktree ? .available : nil
        self.transcriptEntryID = transcriptEntryID
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, projectPath, goal, launchContext, launchContextScope, structure, status, writeTarget, currentIteration
        case maxIterations, validationCommand, goalEvaluation, makerChecker, pipeline, parallel, discoveryTriage, humanApproval
        case startedAt, endedAt, stopReason, iterations, artifactDirectoryPath, worktreeState, transcriptEntryID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        goal = try container.decode(String.self, forKey: .goal)
        launchContext = try container.decodeIfPresent(String.self, forKey: .launchContext)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        launchContextScope = try container.decodeIfPresent(LoopLaunchContextScope.self, forKey: .launchContextScope) ?? .firstIterationOnly
        structure = try container.decode(LoopStructureKind.self, forKey: .structure)
        status = try container.decode(LoopRunStatus.self, forKey: .status)
        writeTarget = try container.decode(LoopWriteTarget.self, forKey: .writeTarget)
        currentIteration = try container.decode(Int.self, forKey: .currentIteration)
        maxIterations = try container.decode(Int.self, forKey: .maxIterations)
        validationCommand = try container.decodeIfPresent(String.self, forKey: .validationCommand) ?? ""
        goalEvaluation = try container.decodeIfPresent(LoopGoalEvaluationConfig.self, forKey: .goalEvaluation) ?? LoopGoalEvaluationConfig(successCondition: goal)
        makerChecker = try container.decodeIfPresent(LoopMakerCheckerConfig.self, forKey: .makerChecker) ?? LoopMakerCheckerConfig()
        pipeline = try container.decodeIfPresent(LoopPipelineConfig.self, forKey: .pipeline) ?? LoopPipelineConfig()
        parallel = try container.decodeIfPresent(LoopParallelConfig.self, forKey: .parallel) ?? LoopParallelConfig()
        discoveryTriage = try container.decodeIfPresent(LoopDiscoveryTriageConfig.self, forKey: .discoveryTriage) ?? LoopDiscoveryTriageConfig()
        humanApproval = try container.decodeIfPresent(LoopHumanApprovalConfig.self, forKey: .humanApproval) ?? LoopHumanApprovalConfig()
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        stopReason = try container.decodeIfPresent(LoopStopReason.self, forKey: .stopReason)
        iterations = try container.decode([LoopIteration].self, forKey: .iterations)
        artifactDirectoryPath = try container.decodeIfPresent(String.self, forKey: .artifactDirectoryPath)
        worktreeState = try container.decodeIfPresent(LoopWorktreeState.self, forKey: .worktreeState)
        transcriptEntryID = try container.decode(UUID.self, forKey: .transcriptEntryID)
    }

    var isActive: Bool { status.isActive }

    var presentsGoalNotMetOutcome: Bool {
        structure == .makerChecker &&
        stopReason == .maxIterationsReached &&
        iterations.last?.checkerResult == .reject
    }

    var displayStatusName: String {
        presentsGoalNotMetOutcome ? "Goal not met" : status.displayName
    }

    var hasIterationLimit: Bool {
        maxIterations > 0
    }

    var effectiveIterationLimit: Int {
        hasIterationLimit ? maxIterations : Int.max
    }

    var iterationLimitDisplayText: String {
        hasIterationLimit ? String(maxIterations) : "No limit"
    }

    var iterationProgressText: String {
        iterationProgressText(currentIteration)
    }

    func iterationProgressText(_ iteration: Int) -> String {
        hasIterationLimit ? "Iteration \(iteration)/\(maxIterations)" : "Iteration \(iteration) · No limit"
    }
}

extension PiAgentTranscriptEntry {
    var isLoopTranscriptCard: Bool {
        LoopRunTranscriptCodec.decode(from: self) != nil
    }

    var isLoopRecapEntry: Bool {
        LoopRunRecapCodec.decode(from: self) != nil
    }
}

enum LoopRunRecapKind: String, Codable, Hashable, Sendable {
    case iteration
    case final
}

struct LoopRunRecapMarker: Codable, Equatable, Sendable {
    var runID: UUID
    var kind: LoopRunRecapKind
    var iterationIndex: Int?
}

enum LoopIterationSeparatorCodec {
    static let title = "Loop Round"

    static func decode(from entry: PiAgentTranscriptEntry) -> LoopRunRecapMarker? {
        guard entry.role == .status,
              entry.title == title,
              let rawJSON = entry.rawJSON,
              let data = rawJSON.data(using: .utf8),
              let marker = try? JSONDecoder().decode(LoopRunRecapMarker.self, from: data),
              marker.kind == .iteration else { return nil }
        return marker
    }

    static func transcriptEntry(for run: LoopRun, iterationIndex: Int, id: UUID = UUID(), timestamp: Date = Date()) -> PiAgentTranscriptEntry {
        let marker = LoopRunRecapCodec.marker(for: run, iterationIndex: iterationIndex)
        return PiAgentTranscriptEntry(
            id: id,
            sessionID: run.sessionID,
            role: .status,
            title: title,
            text: "\(run.iterationProgressText(iterationIndex)) — \(run.structure.displayName)",
            rawJSON: LoopRunRecapCodec.rawJSON(for: marker),
            timestamp: timestamp
        )
    }

    static func dividerEntry(from legacyRecapEntry: PiAgentTranscriptEntry, marker: LoopRunRecapMarker) -> PiAgentTranscriptEntry {
        PiAgentTranscriptEntry(
            id: legacyRecapEntry.id,
            sessionID: legacyRecapEntry.sessionID,
            role: .status,
            title: title,
            text: marker.iterationIndex.map { "Iteration \($0)" } ?? "Loop iteration",
            rawJSON: legacyRecapEntry.rawJSON,
            timestamp: legacyRecapEntry.timestamp
        )
    }
}

enum LoopRunRecapCodec {
    static let title = "Loop Recap"

    static func marker(for run: LoopRun, iterationIndex: Int) -> LoopRunRecapMarker {
        LoopRunRecapMarker(runID: run.id, kind: .iteration, iterationIndex: iterationIndex)
    }

    static func finalMarker(for run: LoopRun) -> LoopRunRecapMarker {
        LoopRunRecapMarker(runID: run.id, kind: .final, iterationIndex: nil)
    }

    static func decode(from entry: PiAgentTranscriptEntry) -> LoopRunRecapMarker? {
        guard entry.role == .status,
              entry.title == title,
              let rawJSON = entry.rawJSON,
              let data = rawJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LoopRunRecapMarker.self, from: data)
    }

    static func rawJSON(for marker: LoopRunRecapMarker) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(marker) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func iterationText(for run: LoopRun, iteration: LoopIteration) -> String {
        var parts: [String] = ["∞ Round \(iteration.index) recap — \(run.structure.displayName)"]
        if !iteration.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(iteration.summary)
        }
        if let checkerResult = iteration.checkerResult,
           !iteration.summary.localizedCaseInsensitiveContains("Checker outcome:") {
            parts.append("Checker outcome: \(checkerResult.displayName)")
        }
        if let validation = iteration.validationResult {
            parts.append("Validation: \(validation.didPass ? "passed" : "did not pass")\(validation.exitCode.map { " (exit \($0))" } ?? "")")
        }
        if let evaluation = iteration.goalEvaluation {
            parts.append("Goal evaluation: \(evaluation.result.displayName)")
        }
        if !iteration.artifacts.isEmpty {
            parts.append("Artifacts: \(iteration.artifacts.map(\.filename).joined(separator: ", "))")
        }
        if run.artifactDirectoryPath != nil {
            parts.append("Shared progress artifact: loop-progress.md")
        }
        if !iteration.changedFiles.isEmpty {
            parts.append("Changed files: \(iteration.changedFiles.prefix(6).joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    static func finalText(for run: LoopRun, progressMarkdown: String? = nil) -> String {
        let iterationLine = run.hasIterationLimit ? "Iterations: \(run.iterations.count)/\(run.maxIterations)" : "Iterations: \(run.iterations.count) · No limit"
        var lines: [String] = [
            "∞ Loop final recap — \(run.displayStatusName)",
            "Structure: \(run.structure.displayName)",
            iterationLine
        ]
        if let stopReason = run.stopReason {
            lines.append("Outcome: \(stopReason.displayName)")
        }
        if run.structure == .makerChecker {
            if let checkerResult = run.iterations.last?.checkerResult {
                lines.append("Final checker result: \(checkerResult.displayName)")
            }
            if run.stopReason == .maxIterationsReached {
                if run.iterations.last?.checkerResult == .continueLoop {
                    lines.append("Maker + Checker used all configured iterations while continuing accepted work; treat this as iteration budget exhausted, not a rejection.")
                } else {
                    lines.append("Maker + Checker used all configured iterations without approval; treat this as goal not fully met, not an agent error.")
                }
            } else if run.iterations.last?.checkerResult == .reject {
                lines.append("Maker + Checker ended on a rejection.")
            }
        }
        if let validation = run.iterations.last?.validationResult {
            lines.append("Latest validation: \(validation.didPass ? "passed" : "failed")\(validation.exitCode.map { " (exit \($0))" } ?? "")")
        }
        if let evaluation = run.iterations.last?.goalEvaluation {
            lines.append("Latest goal evaluation: \(evaluation.result.displayName)")
        }
        if let progressSummary = finalProgressSummary(from: progressMarkdown) {
            lines.append("")
            lines.append("Loop outcome summary:")
            lines.append(contentsOf: progressSummary)
        }
        let artifacts = run.iterations.flatMap(\.artifacts)
        if !artifacts.isEmpty {
            lines.append("Artifacts: \(artifacts.suffix(3).map(\.filename).joined(separator: ", "))")
        }
        if run.artifactDirectoryPath != nil {
            lines.append("Shared progress artifact: loop-progress.md")
        }
        return lines.joined(separator: "\n")
    }

    private static func finalProgressSummary(from markdown: String?) -> [String]? {
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sections = markdownSections(markdown)
        let wanted = ["Current Understanding", "What Worked", "What Did Not Work", "Current Evidence", "Avoid Repeating", "Next Recommended Move"]
        var lines: [String] = []
        for title in wanted {
            guard let body = sections[title]?.filter({ !$0.contains("None yet") && !$0.contains("Not established yet") }), !body.isEmpty else { continue }
            lines.append("\(title):")
            lines.append(contentsOf: body.prefix(3))
        }
        return lines.isEmpty ? nil : Array(lines.prefix(18))
    }

    private static func markdownSections(_ markdown: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var currentTitle: String?
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("## ") {
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let currentTitle { result[currentTitle, default: []] = [] }
            } else if let currentTitle {
                result[currentTitle, default: []].append(line)
            }
        }
        return result
    }

    static func transcriptEntry(for run: LoopRun, iteration: LoopIteration, id: UUID = UUID()) -> PiAgentTranscriptEntry {
        let marker = marker(for: run, iterationIndex: iteration.index)
        return PiAgentTranscriptEntry(
            id: id,
            sessionID: run.sessionID,
            role: .status,
            title: title,
            text: iterationText(for: run, iteration: iteration),
            rawJSON: rawJSON(for: marker),
            timestamp: iteration.endedAt ?? Date()
        )
    }

    static func finalTranscriptEntry(for run: LoopRun, id: UUID = UUID(), progressMarkdown: String? = nil) -> PiAgentTranscriptEntry {
        let marker = finalMarker(for: run)
        return PiAgentTranscriptEntry(
            id: id,
            sessionID: run.sessionID,
            role: .status,
            title: title,
            text: finalText(for: run, progressMarkdown: progressMarkdown),
            rawJSON: rawJSON(for: marker),
            timestamp: run.endedAt ?? Date()
        )
    }
}

enum LoopRunTranscriptCodec {
    static let title = "Loop"

    static func rawJSON(for run: LoopRun) -> String? {
        guard let data = try? JSONEncoder.loopRun.encode(run) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(from entry: PiAgentTranscriptEntry) -> LoopRun? {
        guard entry.role == .status,
              entry.title == title,
              let rawJSON = entry.rawJSON,
              let data = rawJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder.loopRun.decode(LoopRun.self, from: data)
    }

    static func transcriptText(for run: LoopRun) -> String {
        var lines: [String] = [
            "∞ Loop \(run.displayStatusName)",
            "Structure: \(run.structure.displayName)",
            "Write target: \(run.writeTarget.displayName)",
            "Goal: \(run.goal)",
            "Progress: \(run.iterationProgressText)"
        ]
        if run.launchContext?.isEmpty == false {
            lines.append("Launch context: present (\(run.launchContextScope.displayName.lowercased()))")
        }
        lines.append("Goal evaluation: report-only natural-language evaluator")
        lines.append("Success condition: \(run.goalEvaluation.successCondition.isEmpty ? run.goal : run.goalEvaluation.successCondition)")
        if !run.validationCommand.isEmpty {
            lines.append("Validation command: \(run.validationCommand)")
        }
        switch run.structure {
        case .makerChecker:
            lines.append("Maker: \(run.makerChecker.makerName)")
            lines.append("Checker: \(run.makerChecker.checkerName) (report-only)")
            lines.append("Checker rubric: \(run.makerChecker.checkerRubric)")
            if let checkerResult = run.iterations.last?.checkerResult {
                lines.append("Checker result: \(checkerResult.displayName)")
            }
        case .agentPipeline:
            lines.append("Pipeline stages: \(run.pipeline.stageNames.joined(separator: " → "))")
        case .parallelAgents:
            lines.append("Parallel branches: \(run.parallel.branchNames.joined(separator: ", "))")
        case .discoveryTriage:
            lines.append("Classification prompt: \(run.discoveryTriage.classificationPrompt)")
        case .humanApproval:
            lines.append("Checkpoint: \(run.humanApproval.checkpointPrompt)")
        case .singleAgent:
            lines.append("Agent: \(run.makerChecker.makerName)")
        }
        if let timeline = run.iterations.last?.timeline, !timeline.isEmpty {
            lines.append("Timeline: \(timeline.map { $0.roleName }.joined(separator: " → "))")
        }
        if let stopReason = run.stopReason {
            lines.append("Stop reason: \(stopReason.displayName)")
        }
        if let directoryPath = run.artifactDirectoryPath {
            lines.append("Artifact directory: \(directoryPath)")
        }
        if let validation = run.iterations.last?.validationResult {
            lines.append("Validation exit code: \(validation.exitCode.map(String.init) ?? "unavailable")")
            lines.append("Validation duration: \(String(format: "%.2fs", validation.duration))")
        }
        if let evaluation = run.iterations.last?.goalEvaluation {
            lines.append("Goal evaluator result: \(evaluation.result.displayName)")
            if !evaluation.rationale.isEmpty { lines.append("Goal evaluator rationale: \(evaluation.rationale)") }
        }
        if let changedFiles = run.iterations.last?.changedFiles, !changedFiles.isEmpty {
            lines.append("Changed files: \(changedFiles.joined(separator: ", "))")
        }
        if let artifact = run.iterations.last?.artifacts.first {
            lines.append("")
            lines.append("Artifact: \(artifact.filename)")
            if let filePath = artifact.filePath {
                lines.append("Artifact path: \(filePath)")
            }
            lines.append(artifact.markdown)
        }
        return lines.joined(separator: "\n")
    }

    static func transcriptEntry(for run: LoopRun) -> PiAgentTranscriptEntry {
        PiAgentTranscriptEntry(
            id: run.transcriptEntryID,
            sessionID: run.sessionID,
            role: .status,
            title: title,
            text: transcriptText(for: run),
            rawJSON: rawJSON(for: run),
            timestamp: run.endedAt ?? run.startedAt
        )
    }
}

private nonisolated extension JSONEncoder {
    static var loopRun: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private nonisolated extension JSONDecoder {
    static var loopRun: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
