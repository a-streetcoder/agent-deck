import Foundation

@main
struct PiParityHarness {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fputs("usage: parity-harness <scan|serialize-agent|serialize-chain|builtin-override> ...\n", stderr)
            exit(2)
        }

        switch command {
        case "scan":
            guard args.count == 2 else { fail("scan requires <projectRoot>") }
            let scanner = PiScanner()
            let snapshot = scanner.scan(projectRoot: URL(fileURLWithPath: args[1], isDirectory: true))
            try printJSON(buildSnapshotSummary(snapshot))
        case "serialize-agent":
            guard args.count == 2 else { fail("serialize-agent requires <config.json>") }
            let config = try loadAgentConfig(path: args[1])
            let persistence = AgentPersistence()
            FileHandle.standardOutput.write(Data(persistence.serializedText(for: config).utf8))
        case "serialize-chain":
            guard args.count == 2 else { fail("serialize-chain requires <chain.json>") }
            let chain = try loadChainRecord(path: args[1])
            let persistence = ChainPersistence()
            FileHandle.standardOutput.write(Data(persistence.serialize(chain).utf8))
        case "builtin-override":
            guard args.count == 3 else { fail("builtin-override requires <base.json> <edited.json>") }
            let base = try loadAgentConfig(path: args[1])
            let edited = try loadAgentConfig(path: args[2])
            let persistence = AgentPersistence()
            try printJSON(persistence.builtinOverrideValuesForTesting(base: base, edited: edited) ?? [:])
        default:
            fail("unknown command: \(command)")
        }
    }

    private static func buildSnapshotSummary(_ snapshot: ScanSnapshot) -> [String: Any] {
        [
            "builtin": snapshot.builtinAgents.map(agentSummary).sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") },
            "global": snapshot.globalAgents.map(agentSummary).sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") },
            "project": (snapshot.legacyProjectAgents + snapshot.projectAgents).reduce(into: [String: [String: Any]]()) { partial, agent in partial[agent.name] = agentSummary(agent) }.values.sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") },
            "effective": snapshot.effectiveAgents.map { effective in
                [
                    "name": effective.name,
                    "resolutionKind": effective.resolutionKind.rawValue,
                    "sourcePath": normalizedPath(effective.sourcePath) as Any,
                    "resolved": agentConfigSummary(effective.resolved),
                    "userOverridePath": normalizedPath(effective.userOverride?.settingsPath) as Any,
                    "projectOverridePath": normalizedPath(effective.projectOverride?.settingsPath) as Any
                ]
            }.sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") },
            "chains": snapshot.chains.map(chainSummary).sorted { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") },
            "settings": snapshot.settings.sorted { $0.path < $1.path }.map { settings in
                [
                    "path": normalizedPath(settings.path),
                    "disableBuiltins": settings.disableBuiltins as Any,
                    "packages": settings.packages,
                    "agentOverrides": settings.agentOverrides.map { override in
                        [
                            "agentName": override.agentName,
                            "settingsPath": normalizedPath(override.settingsPath),
                            "values": normalizeJSON(override.values)
                        ]
                    }
                ]
            }
        ]
    }

    private static func agentSummary(_ agent: AgentRecord) -> [String: Any] {
        [
            "name": agent.name,
            "filePath": normalizedPath(agent.filePath),
            "source": normalizedScope(agent.source.kind),
            "config": agentConfigSummary(agent.parsed)
        ]
    }

    private static func effectiveSummary(_ agent: EffectiveAgentRecord) -> [String: Any] {
        ["name": agent.name]
    }

    private static func chainSummary(_ chain: ChainRecord) -> [String: Any] {
        [
            "name": chain.name,
            "filePath": normalizedPath(chain.filePath),
            "source": normalizedScope(chain.source.kind),
            "description": chain.description,
            "extraFields": chain.extraFields,
            "steps": chain.steps.map { step in
                [
                    "agent": step.agent,
                    "output": step.output as Any,
                    "outputDisabled": step.outputDisabled,
                    "reads": step.reads as Any,
                    "readsDisabled": step.readsDisabled,
                    "model": step.model as Any,
                    "skills": step.skills as Any,
                    "skillsDisabled": step.skillsDisabled,
                    "progress": step.progress as Any,
                    "body": step.body
                ]
            }
        ]
    }

    private static func agentConfigSummary(_ config: AgentConfig) -> [String: Any] {
        [
            "name": config.name,
            "description": config.description,
            "model": config.model as Any,
            "fallbackModels": config.fallbackModels,
            "thinking": config.thinking as Any,
            "systemPromptMode": config.systemPromptMode as Any,
            "inheritProjectContext": config.inheritProjectContext as Any,
            "inheritSkills": config.inheritSkills as Any,
            "disabled": config.disabled as Any,
            "tools": config.tools as Any,
            "mcpDirectTools": config.mcpDirectTools as Any,
            "extensions": config.extensions as Any,
            "skills": config.skills,
            "output": config.output as Any,
            "defaultReads": config.defaultReads as Any,
            "defaultProgress": config.defaultProgress as Any,
            "interactive": config.interactive as Any,
            "maxSubagentDepth": config.maxSubagentDepth as Any,
            "systemPrompt": config.systemPrompt,
            "unknownFields": config.unknownFields
        ]
    }

    private static func normalizedScope(_ scope: ResourceScopeKind) -> String {
        switch scope {
        case .project, .legacyProject:
            return "Project"
        case .global, .package:
            return "Global"
        case .builtin:
            return "Builtin"
        case .override:
            return "Override"
        }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return path.replacingOccurrences(of: "^/private", with: "", options: .regularExpression)
    }

    private static func loadAgentConfig(path: String) throws -> AgentConfig {
        let object = try loadJSONObject(path: path)
        return AgentConfig(
            name: object["name"] as? String ?? "",
            description: object["description"] as? String ?? "",
            model: object["model"] as? String,
            fallbackModels: object["fallbackModels"] as? [String] ?? [],
            thinking: object["thinking"] as? String,
            systemPromptMode: object["systemPromptMode"] as? String,
            inheritProjectContext: object["inheritProjectContext"] as? Bool,
            inheritSkills: object["inheritSkills"] as? Bool,
            disabled: object["disabled"] as? Bool,
            tools: object["tools"] as? [String],
            mcpDirectTools: object["mcpDirectTools"] as? [String],
            extensions: object["extensions"] as? [String],
            skills: object["skills"] as? [String] ?? [],
            output: object["output"] as? String,
            defaultReads: object["defaultReads"] as? [String],
            defaultProgress: object["defaultProgress"] as? Bool,
            interactive: object["interactive"] as? Bool,
            maxSubagentDepth: object["maxSubagentDepth"] as? Int,
            systemPrompt: object["systemPrompt"] as? String ?? "",
            unknownFields: object["unknownFields"] as? [String: String] ?? [:]
        )
    }

    private static func loadChainRecord(path: String) throws -> ChainRecord {
        let object = try loadJSONObject(path: path)
        let steps = (object["steps"] as? [[String: Any]] ?? []).enumerated().map { index, step in
            ChainStepRecord(
                id: "fixture-\(index)",
                agent: step["agent"] as? String ?? "",
                title: step["agent"] as? String ?? "",
                output: step["output"] as? String,
                outputDisabled: step["outputDisabled"] as? Bool ?? false,
                reads: step["reads"] as? [String],
                readsDisabled: step["readsDisabled"] as? Bool ?? false,
                model: step["model"] as? String,
                skills: step["skills"] as? [String],
                skillsDisabled: step["skillsDisabled"] as? Bool ?? false,
                progress: step["progress"] as? Bool,
                body: step["body"] as? String ?? ""
            )
        }
        return ChainRecord(
            id: "fixture-chain",
            name: object["name"] as? String ?? "",
            source: ScopeID(kind: .global, path: path),
            filePath: path,
            description: object["description"] as? String ?? "",
            steps: steps,
            extraFields: object["extraFields"] as? [String: String] ?? [:]
        )
    }

    private static func loadJSONObject(path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            fail("expected JSON object in \(path)")
        }
        return dictionary
    }

    private static func normalizeJSON(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().reduce(into: [String: Any]()) { result, key in
                result[key] = normalizeJSON(dictionary[key]!)
            }
        case let array as [Any]:
            return array.map(normalizeJSON)
        default:
            return value
        }
    }

    private static func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: normalizeJSON(object), options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        fputs(message + "\n", stderr)
        exit(1)
    }
}
