import Foundation

nonisolated final class LoopDefinitionStore: @unchecked Sendable {
    enum StoreError: Error, LocalizedError {
        case userDefinitionsOnly
        case missingName

        var errorDescription: String? {
            switch self {
            case .userDefinitionsOnly: return "Only user loop definitions can be saved."
            case .missingName: return "Loop definitions need a name."
            }
        }
    }

    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL = LoopDefinitionStore.defaultDirectoryURL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    static var defaultDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("loops", isDirectory: true)
    }

    func loadUserDefinitions() -> [LoopDefinition] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.lastPathComponent.hasSuffix(".loop.md") }
            .compactMap { try? Self.decodeDefinition(at: $0, source: .user) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadDefinitions() -> [LoopDefinition] {
        loadUserDefinitions()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func saveUserDefinition(_ definition: LoopDefinition) throws -> LoopDefinition {
        guard definition.source == .user else { throw StoreError.userDefinitionsOnly }
        let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.missingName }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var saved = definition
        saved.name = name
        saved.description = definition.description.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.goalTemplate = definition.goalTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.launchContext = definition.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        saved.projectPaths = definition.availability == .projectPaths ? sanitizedProjectPaths(definition.projectPaths) : []
        let targetURL: URL
        if let existingPath = saved.filePath, !existingPath.isEmpty {
            targetURL = URL(fileURLWithPath: existingPath)
        } else {
            targetURL = uniqueFileURL(forName: name)
        }
        saved.filePath = targetURL.path
        saved.updatedAt = Date()
        if saved.createdAt == nil { saved.createdAt = saved.updatedAt }

        try Self.encode(saved).write(to: targetURL, atomically: true, encoding: .utf8)
        return saved
    }

    func deleteUserDefinition(_ definition: LoopDefinition) throws {
        guard definition.source == .user else { throw StoreError.userDefinitionsOnly }
        guard let path = definition.filePath?.nonEmpty ?? definition.id.nonEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func duplicateUserDefinition(_ definition: LoopDefinition, name: String? = nil) throws -> LoopDefinition {
        var duplicate = definition
        duplicate.id = UUID().uuidString
        duplicate.name = (name?.nonEmpty ?? "Copy of \(definition.name)")
        duplicate.source = .user
        duplicate.filePath = nil
        duplicate.createdAt = nil
        duplicate.updatedAt = nil
        return try saveUserDefinition(duplicate)
    }

    private func sanitizedProjectPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private func uniqueFileURL(forName name: String) -> URL {
        let slug = Self.slug(for: name)
        var candidate = directoryURL.appendingPathComponent("\(slug).loop.md")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(slug)-\(suffix).loop.md")
            suffix += 1
        }
        return candidate
    }

    private static func slug(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "loop" : collapsed
    }

    static func decodeDefinition(at url: URL, source: LoopDefinitionSource = .user) throws -> LoopDefinition {
        let text = try String(contentsOf: url, encoding: .utf8)
        let document = parseDocument(text)
        let fm = document.frontmatter
        let fallbackName = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        let name = fm["name"]?.nonEmpty ?? fallbackName
        let description = fm["description"]?.nonEmpty ?? ""
        let structure = LoopStructureKind(rawValue: fm["structure"]?.nonEmpty ?? "") ?? .singleAgent
        let writeTarget = LoopWriteTarget(rawValue: fm["writeTarget"]?.nonEmpty ?? "") ?? .artifactMarkdown
        let maxIterations = Int(fm["maxIterations"]?.nonEmpty ?? "") ?? LoopDraft.defaultMaxIterations
        let validationCommand = fm["validationCommand"]?.nonEmpty ?? ""
        let goalEvaluation = LoopGoalEvaluationConfig(
            successCondition: decodeString(json: fm["successConditionJSON"]) ?? fm["successCondition"]?.nonEmpty ?? document.body,
            model: fm["evaluatorModel"]?.nonEmpty,
            thinkingLevel: fm["evaluatorThinkingLevel"]?.nonEmpty
        )
        let launchContext = decodeString(json: fm["launchContextJSON"]) ?? fm["launchContext"]?.nonEmpty
        let launchContextScope = LoopLaunchContextScope(rawValue: fm["launchContextScope"]?.nonEmpty ?? "") ?? .firstIterationOnly
        let makerChecker = LoopMakerCheckerConfig(
            makerName: fm["makerName"]?.nonEmpty ?? "",
            checkerName: fm["checkerName"]?.nonEmpty ?? "",
            checkerRubric: fm["checkerRubric"]?.nonEmpty ?? "approve"
        )
        let pipeline = LoopPipelineConfig(stageNames: splitList(fm["pipelineStages"]))
        let parallel = LoopParallelConfig(branchNames: splitList(fm["parallelBranches"]))
        let discoveryTriage = LoopDiscoveryTriageConfig(agentName: fm["triageAgent"]?.nonEmpty ?? "", classificationPrompt: fm["classificationPrompt"]?.nonEmpty ?? "Classify findings by severity and summarize recommended next action.")
        let humanApproval = LoopHumanApprovalConfig(checkpointPrompt: fm["checkpointPrompt"]?.nonEmpty ?? "Review the proposal before continuing.")
        let availability = LoopDefinitionAvailability(rawValue: fm["availability"]?.nonEmpty ?? "") ?? .allProjects
        let projectPaths = decodeProjectPaths(json: fm["projectPathsJSON"]) ?? splitProjectPaths(fm["projectPaths"])
        let parsedSource = LoopDefinitionSource(rawValue: fm["source"]?.nonEmpty ?? "") ?? source
        let createdAt = parseDate(fm["createdAt"])
        let updatedAt = parseDate(fm["updatedAt"])
        return LoopDefinition(
            id: url.path,
            name: name,
            description: description,
            goalTemplate: document.body,
            launchContext: launchContext,
            launchContextScope: launchContextScope,
            structure: structure,
            writeTarget: writeTarget,
            maxIterations: max(0, maxIterations),
            validationCommand: validationCommand,
            goalEvaluation: goalEvaluation,
            makerChecker: makerChecker,
            pipeline: pipeline,
            parallel: parallel,
            discoveryTriage: discoveryTriage,
            humanApproval: humanApproval,
            source: parsedSource,
            availability: availability,
            projectPaths: projectPaths,
            filePath: url.path,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func encode(_ definition: LoopDefinition) -> String {
        var lines = ["---"]
        lines.append("name: \(oneLine(definition.name))")
        lines.append("description: \(oneLine(definition.description))")
        lines.append("source: \(definition.source.rawValue)")
        lines.append("structure: \(definition.structure.rawValue)")
        lines.append("writeTarget: \(definition.writeTarget.rawValue)")
        lines.append("maxIterations: \(definition.maxIterations)")
        if !definition.validationCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("validationCommand: \(oneLine(definition.validationCommand))")
        }
        let successCondition = definition.goalEvaluation.successCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !successCondition.isEmpty && successCondition != definition.goalTemplate.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.append("successConditionJSON: \(jsonString(successCondition))")
        }
        if let model = definition.goalEvaluation.model?.nonEmpty { lines.append("evaluatorModel: \(oneLine(model))") }
        if let thinkingLevel = definition.goalEvaluation.thinkingLevel?.nonEmpty { lines.append("evaluatorThinkingLevel: \(oneLine(thinkingLevel))") }
        if let launchContext = definition.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines), !launchContext.isEmpty {
            lines.append("launchContextScope: \(definition.launchContextScope.rawValue)")
            lines.append("launchContextJSON: \(jsonString(launchContext))")
        }
        if definition.structure == .singleAgent || definition.structure == .makerChecker {
            lines.append("makerName: \(oneLine(definition.makerChecker.makerName))")
        }
        if definition.structure == .makerChecker {
            lines.append("checkerName: \(oneLine(definition.makerChecker.checkerName))")
            lines.append("checkerRubric: \(oneLine(definition.makerChecker.checkerRubric))")
        }
        if definition.structure == .agentPipeline {
            lines.append("pipelineStages: \(oneLine(definition.pipeline.stageNames.joined(separator: " | ")))")
        }
        if definition.structure == .parallelAgents {
            lines.append("parallelBranches: \(oneLine(definition.parallel.branchNames.joined(separator: " | ")))")
        }
        if definition.structure == .discoveryTriage {
            lines.append("triageAgent: \(oneLine(definition.discoveryTriage.agentName))")
            lines.append("classificationPrompt: \(oneLine(definition.discoveryTriage.classificationPrompt))")
        }
        if definition.structure == .humanApproval {
            lines.append("checkpointPrompt: \(oneLine(definition.humanApproval.checkpointPrompt))")
        }
        lines.append("availability: \(definition.availability.rawValue)")
        if !definition.projectPaths.isEmpty {
            lines.append("projectPathsJSON: \(jsonString(definition.projectPaths))")
        }
        if let createdAt = definition.createdAt { lines.append("createdAt: \(isoFormatter().string(from: createdAt))") }
        if let updatedAt = definition.updatedAt { lines.append("updatedAt: \(isoFormatter().string(from: updatedAt))") }
        lines.append("---")
        lines.append("")
        lines.append(definition.goalTemplate.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func parseDocument(_ text: String) -> (frontmatter: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([:], normalized.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let remainder = String(normalized.dropFirst(4))
        guard let closingRange = remainder.range(of: "\n---\n")
            ?? (remainder.hasSuffix("\n---") ? remainder.range(of: "\n---", options: .backwards) : nil)
        else { return ([:], normalized.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let frontmatter = String(remainder[..<closingRange.lowerBound])
        let bodyStart = remainder.index(closingRange.upperBound, offsetBy: 0)
        let body = String(remainder[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String: String] = [:]
        for line in frontmatter.components(separatedBy: "\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { values[key] = value }
        }
        return (values, body)
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitProjectPaths(_ value: String?) -> [String] {
        splitList(value)
    }

    private static func splitList(_ value: String?) -> [String] {
        (value ?? "")
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func decodeProjectPaths(json: String?) -> [String]? {
        guard let json = json?.nonEmpty,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return values
    }

    private static func decodeString(json: String?) -> String? {
        guard let json = json?.nonEmpty,
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return value
    }

    private static func jsonString(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value = value?.nonEmpty else { return nil }
        return isoFormatter().date(from: value)
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
