import Foundation

struct ChainPersistence {
    private let fileManager = FileManager.default

    func serialize(_ chain: ChainRecord) -> String {
        var lines = ["---", "name: \(chain.name)", "description: \(chain.description)"]
        for key in chain.extraFields.keys.sorted() {
            if let value = chain.extraFields[key] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("---")
        lines.append("")

        for (index, step) in chain.steps.enumerated() {
            lines.append("## \(step.agent)")
            if step.outputDisabled { lines.append("output: false") }
            else if let output = step.output { lines.append("output: \(output)") }
            if step.readsDisabled { lines.append("reads: false") }
            else if let reads = step.reads, !reads.isEmpty { lines.append("reads: \(reads.joined(separator: ", "))") }
            if let model = step.model { lines.append("model: \(model)") }
            if step.skillsDisabled { lines.append("skills: false") }
            else if let skills = step.skills, !skills.isEmpty { lines.append("skills: \(skills.joined(separator: ", "))") }
            if let progress = step.progress { lines.append("progress: \(progress ? "true" : "false")") }
            lines.append("")
            lines.append(step.body)
            if index < chain.steps.count - 1 { lines.append("") }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    func save(_ draft: ChainEditorDraft) throws {
        let path = draft.chain.filePath
        guard isWritableChainPath(path) else {
            throw PersistenceError.invalidWriteTarget(path)
        }

        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialize(draft.chain).write(to: url, atomically: true, encoding: .utf8)
    }

    func makeNewDraft(scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> ChainEditorDraft {
        let path = chainPath(name: "new-chain", scope: scope, projectRoot: projectRoot)
        let sourceKind: ResourceScopeKind = scope == .project ? .project : .global
        let chain = ChainRecord(
            id: "chain::\(path)",
            name: "new-chain",
            source: ScopeID(kind: sourceKind, path: path),
            filePath: path,
            description: "",
            steps: [
                ChainStepRecord(
                    id: "step::0",
                    agent: "planner",
                    title: "planner",
                    output: nil,
                    outputDisabled: false,
                    reads: nil,
                    readsDisabled: false,
                    model: nil,
                    skills: nil,
                    skillsDisabled: false,
                    progress: nil,
                    body: "Describe what this step should do."
                )
            ],
            extraFields: [:]
        )
        return ChainEditorDraft(originalName: chain.name, chain: chain)
    }

    func makeDuplicateDraft(from chain: ChainRecord, scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> ChainEditorDraft {
        var copy = chain
        copy.name = duplicatedName(for: chain.name, scope: scope, projectRoot: projectRoot)
        let path = chainPath(name: copy.name, scope: scope, projectRoot: projectRoot)
        let sourceKind: ResourceScopeKind = scope == .project ? .project : .global
        copy = ChainRecord(
            id: "chain::\(path)",
            name: copy.name,
            source: ScopeID(kind: sourceKind, path: path),
            filePath: path,
            description: copy.description,
            steps: copy.steps,
            extraFields: copy.extraFields
        )
        return ChainEditorDraft(originalName: chain.name, chain: copy)
    }

    private func chainPath(name: String, scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> String {
        switch scope {
        case .global:
            let newPath = homeDirectory().appendingPathComponent(".agents", isDirectory: true)
            if fileManager.fileExists(atPath: newPath.path) {
                return newPath.appendingPathComponent("\(name).chain.md").path
            }
            return homeDirectory().appendingPathComponent(".pi/agent/agents/\(name).chain.md").path
        case .project:
            return URL(fileURLWithPath: projectRoot ?? "").appendingPathComponent(".pi/agents/\(name).chain.md").path
        }
    }

    private func duplicatedName(for name: String, scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> String {
        var candidate = "\(name)-copy"
        var index = 2
        while fileManager.fileExists(atPath: chainPath(name: candidate, scope: scope, projectRoot: projectRoot)) {
            candidate = "\(name)-copy-\(index)"
            index += 1
        }
        return candidate
    }

    private func homeDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private func isWritableChainPath(_ path: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if path.hasPrefix(URL(fileURLWithPath: home).appendingPathComponent(".pi/agent/agents").path) { return true }
        if path.contains("/.pi/agents/") { return true }
        if path.contains("/.agents/") { return true }
        return false
    }
}
