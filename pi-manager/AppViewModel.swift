import AppKit
import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot: ScanSnapshot = .empty
    @Published var selectedSidebarItem: SidebarItem = .overview
    @Published var selectedAgentID: EffectiveAgentRecord.ID?
    @Published var selectedChainID: ChainRecord.ID?
    @Published var selectedSkillID: SkillRecord.ID?
    @Published var selectedAgentFilter: AgentFilter = .all
    @Published var discoveredProjects: [DiscoveredProject] = []
    @Published var selectedProjectPath: String?
    @Published var allProjectSnapshots: [String: ScanSnapshot] = [:]
    @Published var availableModels: [AvailableModel] = []
    @Published var modelsLastUpdatedAt: Date?

    private let scanner = PiScanner()
    private let projectDiscovery = ProjectDiscovery()
    private let agentPersistence = AgentPersistence()
    private let chainPersistence = ChainPersistence()
    private let envPersistence = EnvPersistence()
    private let subagentConfigPersistence = SubagentConfigPersistence()
    private var globalSnapshot: ScanSnapshot = .empty
    private(set) var projectRootURL: URL?
    private var autoRefreshCancellable: AnyCancellable?
    private var lastWatchFingerprint: String = ""
    private var isRefreshingModels = false

    init() {
        refresh(includeModels: true)
        lastWatchFingerprint = watchFingerprint()
        startAutoRefresh()
    }

    func refresh(includeModels: Bool = false) {
        let previousAgentID = selectedAgentID
        let previousChainID = selectedChainID
        let previousSkillID = selectedSkillID

        discoveredProjects = projectDiscovery.discoverProjects()
        globalSnapshot = scanner.scan(projectRoot: nil)
        allProjectSnapshots = Dictionary(uniqueKeysWithValues: discoveredProjects.map { project in
            (project.path, scanner.scan(projectRoot: project.url))
        })

        if let selectedProjectPath,
           let matchingProject = discoveredProjects.first(where: { $0.path == selectedProjectPath }) {
            projectRootURL = matchingProject.url
            snapshot = allProjectSnapshots[selectedProjectPath] ?? scanner.scan(projectRoot: matchingProject.url)
        } else {
            projectRootURL = nil
            selectedProjectPath = nil
            snapshot = makeAggregateSnapshot()
        }

        selectedAgentID = filteredAgents.contains(where: { $0.id == previousAgentID }) ? previousAgentID : filteredAgents.first?.id
        selectedChainID = snapshot.chains.contains(where: { $0.id == previousChainID }) ? previousChainID : snapshot.chains.first?.id
        selectedSkillID = snapshot.skills.contains(where: { $0.id == previousSkillID }) ? previousSkillID : snapshot.skills.first?.id
        lastWatchFingerprint = watchFingerprint()

        if includeModels {
            refreshAvailableModels()
        }
    }

    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project"
        panel.message = "Choose a repo or project root to inspect local Pi resources."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSelectedProject(url)
    }

    func setSelectedProject(_ url: URL?) {
        projectRootURL = url
        selectedProjectPath = url?.path
        refresh(includeModels: false)
    }

    func clearProjectRoot() {
        projectRootURL = nil
        selectedProjectPath = nil
        refresh(includeModels: false)
    }

    var filteredAgents: [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { agent in
            switch selectedAgentFilter {
            case .all:
                return true
            case .builtin:
                return agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            case .global:
                return agent.globalCustom != nil
            case .project:
                return agent.projectCustom != nil
            case .overriddenBuiltins:
                return agent.builtin != nil && (agent.userOverride != nil || agent.projectOverride != nil)
            case .replacedBuiltins:
                return agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil)
            case .customOnly:
                return agent.globalCustom != nil || agent.projectCustom != nil
            case .disabled:
                return agent.resolved.disabled == true
            case .needsAttention:
                return !warnings(for: agent).isEmpty
            }
        }
    }

    var selectedAgent: EffectiveAgentRecord? {
        filteredAgents.first(where: { $0.id == selectedAgentID }) ?? snapshot.effectiveAgents.first(where: { $0.id == selectedAgentID })
    }

    var selectedChain: ChainRecord? {
        snapshot.chains.first(where: { $0.id == selectedChainID })
    }

    var selectedSkill: SkillRecord? {
        snapshot.skills.first(where: { $0.id == selectedSkillID })
    }

    var packageNames: [String] {
        Array(Set(snapshot.settings.flatMap(\.packages))).sorted()
    }

    func availableSkillNames(for target: AgentEditingTarget) -> [String] {
        let snapshot = scopeSnapshot(for: target)
        return Array(Set(snapshot.skills.map(\.name)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableToolNames(for target: AgentEditingTarget) -> [String] {
        let scopeSnapshot = scopeSnapshot(for: target)
        var tools = [
            "read", "grep", "find", "ls", "bash",
            "edit", "write", "ask_user"
        ]

        if isPackageInstalled("pi-web-access") {
            tools += ["web_search", "fetch_content", "get_search_content", "code_search"]
        }
        if isPackageInstalled("pi-subagents") {
            tools.append("subagent")
        }
        if isPackageInstalled("pi-intercom") {
            tools.append("intercom")
        }

        let explicitTools = scopeSnapshot.effectiveAgents.flatMap { $0.resolved.tools ?? [] }
        let directMCPTools = scopeSnapshot.mcpConfigs.flatMap(\.serverNames).map { "mcp:\($0)" }
        let existingMCPTools = scopeSnapshot.effectiveAgents.flatMap { ($0.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" } }
        return Array(Set(tools + explicitTools + directMCPTools + existingMCPTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableModelIdentifiers() -> [String] {
        availableModels.map(\.identifier)
    }

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? "All Projects"
    }

    var availableModelProviders: [String] {
        Array(Set(availableModels.map(\.provider)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var totalProjectWarnings: Int {
        allProjectSnapshots.values.reduce(0) { $0 + $1.warnings.count }
    }

    func makeAgentDraft(for agent: EffectiveAgentRecord, preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) -> AgentEditorDraft? {
        agentPersistence.makeDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        refresh(includeModels: false)
    }

    func makeNewAgentDraft(scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        let base = AgentConfig(
            name: "new-agent",
            description: "",
            model: nil,
            fallbackModels: [],
            thinking: nil,
            systemPromptMode: "replace",
            inheritProjectContext: false,
            inheritSkills: false,
            disabled: nil,
            tools: nil,
            mcpDirectTools: nil,
            extensions: nil,
            skills: [],
            output: nil,
            defaultReads: nil,
            defaultProgress: nil,
            interactive: nil,
            maxSubagentDepth: nil,
            systemPrompt: "Describe the agent behavior here.",
            unknownFields: [:]
        )
        return agentPersistence.makeNewDraft(scope: scope, base: base)
    }

    func makeDuplicateAgentDraft(from agent: EffectiveAgentRecord, scope: AgentEditingTarget.CustomAgentScope? = nil) -> AgentEditorDraft {
        let targetScope = scope ?? defaultCustomScope(for: agent)
        var config = agent.winningRecord?.parsed ?? agent.resolved
        config.name = duplicatedName(for: config.name)
        return agentPersistence.makeNewDraft(scope: targetScope, base: config)
    }

    func saveNewAgentDraft(_ draft: AgentEditorDraft) throws {
        try agentPersistence.saveNewCustomAgent(draft, projectRoot: selectedProjectPath)
        refresh(includeModels: false)
    }

    func makeChainDraft(for chain: ChainRecord) -> ChainEditorDraft {
        ChainEditorDraft(originalName: chain.name, chain: chain)
    }

    func makeNewChainDraft(scope: AgentEditingTarget.CustomAgentScope) -> ChainEditorDraft {
        chainPersistence.makeNewDraft(scope: scope, projectRoot: selectedProjectPath)
    }

    func makeDuplicateChainDraft(from chain: ChainRecord, scope: AgentEditingTarget.CustomAgentScope) -> ChainEditorDraft {
        chainPersistence.makeDuplicateDraft(from: chain, scope: scope, projectRoot: selectedProjectPath)
    }

    func saveChainDraft(_ draft: ChainEditorDraft) throws {
        try chainPersistence.save(draft)
        refresh(includeModels: false)
    }

    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envPersistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(scope: AgentEditingTarget.CustomAgentScope) -> EnvEditorDraft {
        envPersistence.makeNewDraft(scope: scope, projectRoot: selectedProjectPath)
    }

    func saveEnvDraft(_ draft: EnvEditorDraft) throws {
        try envPersistence.save(draft)
        refresh(includeModels: false)
    }

    func makeSubagentConfigDraft() -> SubagentConfigDraft {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/subagent/config.json").path
        return subagentConfigPersistence.makeDraft(path: path, config: snapshot.subagentConfig?.config ?? .empty)
    }

    func saveSubagentConfigDraft(_ draft: SubagentConfigDraft) throws {
        try subagentConfigPersistence.save(draft)
        refresh(includeModels: false)
    }

    func warnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        snapshot.warnings.filter { warning in
            warning.message.contains("Agent \(agent.name) ") || warning.message.contains("Agent \(agent.name)")
        }
    }

    func agentsExplicitlyUsingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents
            .filter { $0.resolved.skills.contains(skill.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentsAmbientlySeeingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        let explicitIDs = Set(agentsExplicitlyUsingSkill(skill).map(\.id))
        return snapshot.effectiveAgents
            .filter { agent in
                !explicitIDs.contains(agent.id) &&
                (agent.resolved.inheritSkills ?? false) &&
                skillVisible(to: agent, skill: skill)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func makeAggregateSnapshot() -> ScanSnapshot {
        let projectSnapshots = Array(allProjectSnapshots.values)
        let projectSpecificEffectiveAgents = projectSnapshots
            .flatMap(\.effectiveAgents)
            .filter { $0.projectCustom != nil || $0.projectOverride != nil }

        let chains = deduplicateByID(globalSnapshot.chains + projectSnapshots.flatMap(\.chains))
        let skills = deduplicateByID(globalSnapshot.skills + projectSnapshots.flatMap(\.skills))
        let envKeys = deduplicateByID(globalSnapshot.envKeys + projectSnapshots.flatMap(\.envKeys))
        let mcpConfigs = deduplicateByID(globalSnapshot.mcpConfigs + projectSnapshots.flatMap(\.mcpConfigs))
        let warnings = deduplicateByID(globalSnapshot.warnings + projectSnapshots.flatMap(\.warnings))
        let settings = Array(Set(globalSnapshot.settings + projectSnapshots.flatMap(\.settings))).sorted { $0.path < $1.path }

        return ScanSnapshot(
            projectRoot: nil,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: deduplicateByID(projectSnapshots.flatMap(\.projectAgents)),
            legacyProjectAgents: deduplicateByID(projectSnapshots.flatMap(\.legacyProjectAgents)),
            effectiveAgents: globalSnapshot.effectiveAgents + projectSpecificEffectiveAgents,
            chains: chains,
            skills: skills,
            settings: settings,
            envKeys: envKeys,
            mcpConfigs: mcpConfigs,
            subagentConfig: globalSnapshot.subagentConfig,
            warnings: warnings
        )
    }

    private func scopeSnapshot(for target: AgentEditingTarget) -> ScanSnapshot {
        switch target {
        case let .builtinOverride(scope):
            return scopedSnapshot(for: scope == .project)
        case let .custom(scope):
            return scopedSnapshot(for: scope == .project)
        }
    }

    private func scopedSnapshot(for includeProject: Bool) -> ScanSnapshot {
        guard includeProject, let selectedProjectPath, let projectSnapshot = allProjectSnapshots[selectedProjectPath] else {
            return globalSnapshot
        }
        return ScanSnapshot(
            projectRoot: projectSnapshot.projectRoot,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: projectSnapshot.projectAgents,
            legacyProjectAgents: projectSnapshot.legacyProjectAgents,
            effectiveAgents: globalSnapshot.effectiveAgents + projectSnapshot.effectiveAgents.filter { $0.projectCustom != nil || $0.projectOverride != nil },
            chains: globalSnapshot.chains + projectSnapshot.chains,
            skills: globalSnapshot.skills + projectSnapshot.skills,
            settings: globalSnapshot.settings + projectSnapshot.settings,
            envKeys: globalSnapshot.envKeys + projectSnapshot.envKeys,
            mcpConfigs: globalSnapshot.mcpConfigs + projectSnapshot.mcpConfigs,
            subagentConfig: globalSnapshot.subagentConfig,
            warnings: globalSnapshot.warnings + projectSnapshot.warnings
        )
    }

    private func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true

        Task.detached(priority: .utility) {
            let models = Self.loadAvailableModels()
            await MainActor.run {
                self.availableModels = models
                self.modelsLastUpdatedAt = Date()
                self.isRefreshingModels = false
            }
        }
    }

    nonisolated private static func loadAvailableModels() -> [AvailableModel] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "if command -v pi >/dev/null 2>&1; then pi --list-models; elif [ -x /opt/homebrew/bin/pi ]; then /opt/homebrew/bin/pi --list-models; elif [ -x /usr/local/bin/pi ]; then /usr/local/bin/pi --list-models; else exit 127; fi"
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return parseAvailableModels(from: text)
        } catch {
            return []
        }
    }

    nonisolated private static func parseAvailableModels(from text: String) -> [AvailableModel] {
        text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 6 else { return nil }
                return AvailableModel(
                    provider: parts[0],
                    model: parts[1],
                    contextWindow: parts[2],
                    maxOutput: parts[3],
                    supportsThinking: parts[4].lowercased() == "yes",
                    supportsImages: parts[5].lowercased() == "yes"
                )
            }
    }

    private func skillVisible(to agent: EffectiveAgentRecord, skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .project, .legacyProject:
            guard let skillProject = projectName(from: skill.filePath) else { return false }
            if let agentProject = agent.projectRoot.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                return skillProject == agentProject
            }
            return false
        default:
            return true
        }
    }

    private func projectName(from path: String) -> String? {
        let marker = "/Documents/GitHub/"
        guard let range = path.range(of: marker) else { return nil }
        let remainder = path[range.upperBound...]
        return remainder.split(separator: "/").first.map(String.init)
    }

    private func defaultCustomScope(for agent: EffectiveAgentRecord) -> AgentEditingTarget.CustomAgentScope {
        if agent.projectCustom != nil || agent.projectOverride != nil || (agent.projectRoot != nil && selectedProjectPath != nil) {
            return .project
        }
        return .global
    }

    private func duplicatedName(for name: String) -> String {
        let existingNames = Set(snapshot.effectiveAgents.map(\.name))
        var candidate = "\(name)-copy"
        var index = 2
        while existingNames.contains(candidate) {
            candidate = "\(name)-copy-\(index)"
            index += 1
        }
        return candidate
    }

    private func deduplicateByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private func startAutoRefresh() {
        autoRefreshCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshIfWatchedFilesChanged()
            }
    }

    private func refreshIfWatchedFilesChanged() {
        let fingerprint = watchFingerprint()
        guard fingerprint != lastWatchFingerprint else { return }
        refresh(includeModels: false)
    }

    private func watchFingerprint() -> String {
        let fileManager = FileManager.default
        let urls = watchedURLs()
        let entries: [String] = urls.flatMap { url in
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
               values.isDirectory == true {
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                var children: [String] = []
                while let child = enumerator?.nextObject() as? URL {
                    guard watchedFileName(child.lastPathComponent) else { continue }
                    let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                    children.append("\(child.path)::\(date)")
                }
                return children
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return ["\(url.path)::\(date)"]
        }
        return entries.sorted().joined(separator: "|")
    }

    private func watchedURLs() -> [URL] {
        var urls: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents", isDirectory: true)
        ]

        for project in discoveredProjects {
            urls.append(project.url.appendingPathComponent(".pi", isDirectory: true))
            urls.append(project.url.appendingPathComponent(".agents", isDirectory: true))
            urls.append(project.url.appendingPathComponent(".mcp.json"))
        }

        return urls
    }

    private func watchedFileName(_ name: String) -> Bool {
        name.hasSuffix(".md") || name.hasSuffix(".json") || name == ".env" || name == "SKILL.md"
    }

    private func isPackageInstalled(_ name: String) -> Bool {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(name)"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("node_modules/\(name)")
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case agents = "Agents"
    case chains = "Chains"
    case skills = "Skills"
    case models = "Models"
    case subagents = "Subagents"
    case environment = "Environment"
    case mcp = "MCP"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .agents: return "rectangle.connected.to.line.below"
        case .chains: return "point.3.connected.trianglepath.dotted"
        case .skills: return "wand.and.stars"
        case .models: return "cpu"
        case .subagents: return "slider.horizontal.3"
        case .environment: return "key"
        case .mcp: return "cable.connector"
        case .diagnostics: return "stethoscope"
        }
    }
}

enum AgentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case builtin = "Builtin"
    case global = "Global"
    case project = "Project"
    case overriddenBuiltins = "Overridden Builtins"
    case replacedBuiltins = "Replaced Builtins"
    case customOnly = "Custom Only"
    case disabled = "Disabled"
    case needsAttention = "Needs Attention"

    var id: String { rawValue }
}
