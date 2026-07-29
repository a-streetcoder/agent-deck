import Foundation

enum PiInjectedCommandSource: String, Hashable {
    case builtIn
    case library
}

struct PiInjectedCommand: Identifiable, Hashable {
    let id: String
    let slashName: String
    let title: String
    let description: String
    let source: PiInjectedCommandSource
    let fileName: String
    let sourceText: String?
    let extensionPath: String?
}

enum PiInjectedCommandCatalog {
    static let commandLibraryPath = "~/Library/Application Support/Pi Deck/Command Library"

    static func commandLibraryURL(fileManager: FileManager = .default) -> URL {
        let appSupport = URL.applicationSupportDirectory
        return appSupport.appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Command Library", isDirectory: true)
    }

    static var all: [PiInjectedCommand] { builtIns + libraryCommands() }

    static let builtIns: [PiInjectedCommand] = [
        PiInjectedCommand(
            id: "built-in:optimize-agents-md",
            slashName: "/optimize-agents-md",
            title: "Optimize AGENTS.md",
            description: "Create or replace the repo's AGENTS.md with a concise optimized guide, moving detailed instructions into linked docs.",
            source: .builtIn,
            fileName: "optimize-agents-md.ts",
            sourceText: optimizeAgentsMDCommandSource,
            extensionPath: nil
        ),
        PiInjectedCommand(
            id: "built-in:create-agent-deck-command",
            slashName: "/create-agent-deck-command",
            title: "Create Agent Deck command",
            description: "Create or update a TypeScript slash command that Agent Deck can bundle with the app or import into its Command Library.",
            source: .builtIn,
            fileName: "create-agent-deck-command.ts",
            sourceText: createAgentDeckCommandSource,
            extensionPath: nil
        )
    ]

    private static let createAgentDeckCommandSource = #"""
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        const CREATE_AGENT_DECK_COMMAND_PROMPT = "Use the Agent Deck command creation workflow.\n\nGoal:\nCreate or update a Pi TypeScript slash command that Agent Deck can bundle with the app or import into its Command Library. Inspect the target repo and edit files; do not stop at recommendations unless the requested command behavior is ambiguous.\n\nCommand injection facts:\n- A command file is a .ts or .js Pi extension that exports a default function receiving ExtensionAPI.\n- The factory must call pi.registerCommand(\"name\", { description, handler }). The command name does not include the leading slash.\n- Agent Deck detects commands with a literal registerCommand(\"name\"...) or registerCommand('name'...) call.\n- Workflow-style commands should await ctx.waitForIdle(), append optional args?.trim() as run-specific guidance, then call pi.sendUserMessage(...).\n- Imported command files live in ~/Library/Application Support/Pi Deck/Command Library and are disabled by default until enabled in Settings > Commands.\n- App-bundled stock commands are declared in PiInjectedCommandCatalog.builtIns in agent-deck/PiInjectedCommandExtensions.swift with id built-in:<name>, slashName /<name>, fileName <name>.ts, sourceText, and no extensionPath.\n- Enabled bundled or imported commands are passed to parent Pi RPC sessions with explicit --extension arguments while ambient extension discovery remains disabled.\n\nWorkflow:\n1. Understand the requested slash command, command name, target location, and whether it should be bundled with Agent Deck or created as an importable command file.\n2. If details are missing but the intent is clear, choose a short user-friendly kebab-case command name and a self-explanatory description. Ask only when behavior or safety constraints are genuinely ambiguous.\n3. Create or update the command extension. Keep the handler small, readable, and explicit about scope and guardrails.\n4. For bundled Agent Deck commands, add the PiInjectedCommand entry and source constant, then update relevant documentation.\n5. For importable commands, write a standalone .ts file that users can import into Agent Deck's Command Library.\n6. Verify the file contains a literal registerCommand call and report the final slash command, file path, and any enable/restart steps.\n\nMinimal command shape:\nimport type { ExtensionAPI } from \"@earendil-works/pi-coding-agent\";\n\nconst WORKFLOW_PROMPT = \"Describe the workflow.\";\n\nexport default function (pi: ExtensionAPI) {\n  pi.registerCommand(\"command-name\", {\n    description: \"Self-explanatory description\",\n    handler: async (args, ctx) => {\n      await ctx.waitForIdle();\n      const guidance = args?.trim();\n      pi.sendUserMessage(guidance ? `${WORKFLOW_PROMPT}\\n\\nUser guidance:\\n${guidance}` : WORKFLOW_PROMPT);\n    },\n  });\n}\n\nQuality rules:\n- Make the command name and description understandable to non-implementers.\n- Prefer simple prompt-injection workflow commands unless actual runtime logic is required.\n- Include optional user guidance support for workflow commands.\n- Avoid hidden side effects. State scope and safety constraints in the prompt.\n- Keep docs concise and aligned with behavior changes.";

        export default function (pi: ExtensionAPI) {
            pi.registerCommand("create-agent-deck-command", {
                description: "Create or update an Agent Deck slash command extension",
                handler: async (args, ctx) => {
                    await ctx.waitForIdle();
                    const guidance = args?.trim();
                    pi.sendUserMessage(
                        guidance
                            ? `${CREATE_AGENT_DECK_COMMAND_PROMPT}\n\nUser guidance for this /create-agent-deck-command run:\n${guidance}`
                            : CREATE_AGENT_DECK_COMMAND_PROMPT,
                    );
                },
            });
        }
        """#

    private static let optimizeAgentsMDCommandSource = #"""
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        const OPTIMIZE_AGENTS_MD_PROMPT = "Use the AGENTS.md optimization workflow.\n\nGoal:\nCreate or replace the repository's AGENTS.md with concise, optimized instructions that are small, current, and easy for coding agents to follow. Inspect the repo and edit files; do not stop at recommendations unless a conflict requires user input.\n\nExpected outcome:\n- A root AGENTS.md that is short and repo-wide.\n- Linked detailed guidance docs where useful.\n- A final summary of files changed and guidance removed or left for review.\n\nPrinciples:\n- Keep the root AGENTS.md as short as practical.\n- Put only repo-wide, always-relevant instructions in the root file.\n- Move language, framework, testing, deployment, and workflow details into linked markdown files.\n- Prefer stable project concepts over brittle file-path documentation.\n- Remove redundant, stale, obvious, or vague instructions.\n\nRoot AGENTS.md should usually contain:\n1. A one-sentence project description.\n2. Primary tech stack and runtime targets, if important.\n3. Package manager or dependency manager, if non-obvious.\n4. Non-standard build, test, lint, or typecheck commands.\n5. Critical constraints relevant to almost every task.\n6. Links to detailed guides for specific domains.\n\nDo not put long style guides, extensive architecture maps, or detailed command catalogs in the root file unless they are truly relevant to every request.\n\nPreferred structure when detailed guidance exists:\nAGENTS.md\ndocs/\n  agent-guidelines/\n    LANGUAGE.md\n    FRAMEWORK.md\n    TESTING.md\n    ARCHITECTURE.md\n    RELEASE.md\n\nAdapt file names to the project, for example:\n- docs/agent-guidelines/SWIFT.md\n- docs/agent-guidelines/SWIFTUI.md\n- docs/agent-guidelines/TYPESCRIPT.md\n- docs/agent-guidelines/TESTING.md\n- docs/agent-guidelines/PR_CHECKS.md\n\nUse nested AGENTS.md files only when a subdirectory has conventions that differ materially from the root.\n\nWorkflow:\n1. Inspect the repository before editing:\n   - Existing AGENTS.md, CLAUDE.md, or similar agent files.\n   - README and package/project files.\n   - Build/test/lint scripts or Xcode schemes where practical.\n   - Existing docs that can be linked instead of duplicated.\n2. Identify contradictions. If instructions conflict, ask the user which to keep before editing.\n3. Extract essentials for the root AGENTS.md.\n4. Group the remaining useful guidance by topic.\n5. Create or update linked markdown guides under docs/agent-guidelines/ unless the repo already has a better docs location.\n6. Remove or flag guidance that is redundant with normal agent knowledge, too vague to act on, stale or path-fragile, or broad always/never language without a clear reason.\n7. Preserve important project-specific constraints, even if detailed, by moving them to the right guide.\n8. Report the final structure and any guidance intentionally deleted or left for user review.\n\nRoot AGENTS.md template:\n# Agent guide\n\nThis is a <one-sentence project description>.\n\n<One or two short paragraphs with repo-wide constraints, dependency manager, and non-standard commands.>\n\nFor detailed guidance, read the relevant guide before editing that area:\n\n- <Domain>: <path/to/domain-guide.md>\n- <Domain>: <path/to/domain-guide.md>\n\nStyle rules:\n- Be concise and practical.\n- Prefer links over duplicated instructions.\n- Avoid documenting volatile file paths unless necessary.\n- Do not invent commands; verify them from the project when possible.\n- Do not overwrite existing guidance blindly. Preserve useful intent while reorganizing it.\n- If creating CLAUDE.md compatibility is requested, prefer a symlink to AGENTS.md when appropriate.";

        export default function (pi: ExtensionAPI) {
            pi.registerCommand("optimize-agents-md", {
                description: "Create or replace AGENTS.md with a concise optimized agent guide",
                handler: async (args, ctx) => {
                    await ctx.waitForIdle();
                    const guidance = args?.trim();
                    pi.sendUserMessage(
                        guidance
                            ? `${OPTIMIZE_AGENTS_MD_PROMPT}\n\nUser guidance for this /optimize-agents-md run:\n${guidance}`
                            : OPTIMIZE_AGENTS_MD_PROMPT,
                    );
                },
            });
        }
        """#

    static func isEnabled(_ command: PiInjectedCommand, settings: AppSettings) -> Bool {
        switch command.source {
        case .builtIn: return !settings.disabledInjectedCommandIDs.contains(command.id)
        case .library: return settings.enabledLibraryCommandIDs.contains(command.id)
        }
    }

    static func extensionURLs(settings: AppSettings, fileManager: FileManager = .default) -> [URL] {
        all.compactMap { command in
            guard isEnabled(command, settings: settings) else { return nil }
            if let path = command.extensionPath { return URL(fileURLWithPath: path) }
            guard let source = command.sourceText else { return nil }
            return try? PiNativeSubagentBridgeExtensions.writeExtension(named: command.fileName, content: source, fileManager: fileManager)
        }
    }

    static func libraryCommands(fileManager: FileManager = .default) -> [PiInjectedCommand] {
        extensionFiles(in: commandLibraryURL(fileManager: fileManager), fileManager: fileManager)
            .flatMap { commands(in: $0, source: .library) }
            .sorted { $0.slashName.localizedStandardCompare($1.slashName) == .orderedAscending }
    }

    static func importCommandFile(_ sourceURL: URL, fileManager: FileManager = .default) throws {
        let library = commandLibraryURL(fileManager: fileManager)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: sourceURL.lastPathComponent, in: library, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: sourceURL, to: destination)
    }

    private static func uniqueDestination(for fileName: String, in directory: URL, fileManager: FileManager) -> URL {
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private static func extensionFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return children.flatMap { url -> [URL] in
            if ["ts", "js"].contains(url.pathExtension) { return [url] }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return [] }
            return ["index.ts", "index.js"].map { url.appendingPathComponent($0) }.filter { fileManager.fileExists(atPath: $0.path) }
        }
    }

    private static func commands(in file: URL, source: PiInjectedCommandSource) -> [PiInjectedCommand] {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("registerCommand") else { return [] }
        let pattern = #"registerCommand\s*\(\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let name = ns.substring(with: match.range(at: 1))
            return PiInjectedCommand(id: "library:\(file.path):\(name)", slashName: "/\(name)", title: name, description: "Imported command from \(file.lastPathComponent). Disabled by default.", source: source, fileName: file.lastPathComponent, sourceText: nil, extensionPath: file.path)
        }
    }
}
