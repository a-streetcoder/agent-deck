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
    static let shipID = "builtin:ship"
    static let commandLibraryPath = "~/Library/Application Support/Agent Deck/Command Library"

    static func commandLibraryURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Command Library", isDirectory: true)
    }

    static var all: [PiInjectedCommand] { builtIns + libraryCommands() }

    static let builtIns: [PiInjectedCommand] = [
        PiInjectedCommand(id: shipID, slashName: "/ship", title: "Ship", description: "Runs a guarded git ship workflow: inspect changes, stage intentionally, commit, and push the current branch without force-pushing.", source: .builtIn, fileName: "agent-deck-command-ship.ts", sourceText: shipExtensionSource, extensionPath: nil)
    ]

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

    private static let shipExtensionSource = """
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        const SHIP_PROMPT = `Use the commit-and-push workflow.\n\nScope:\n- act only in the current git repository and current branch\n- inspect repository, branch, staged/unstaged/untracked changes, and upstream status before acting\n- stage files deliberately; never use git add -A or git add .\n- never force-push or amend unless explicitly requested\n- stop and report merge, rebase, or conflict states\n\nWorkflow:\n1. Confirm the current repository and branch.\n2. Inspect git status, staged changes, unstaged changes, untracked files, and upstream tracking status.\n3. Prepare a deliberate commit and stage only intended files.\n4. Commit only when there is something intentionally staged.\n5. Push safely to upstream or explain/set upstream explicitly.\n6. If there is nothing to commit or push, say so explicitly.\n\nDo not perform code review; this command is only for deliberate commit and safe push.`;
        export default function (pi: ExtensionAPI) {
          pi.registerCommand("ship", { description: "Deliberately commit current branch changes and push safely", handler: async (args, ctx) => {
            await ctx.waitForIdle();
            const guidance = args?.trim();
            pi.sendUserMessage(guidance ? `${SHIP_PROMPT}\n\nUser guidance for this /ship run:\n${guidance}` : SHIP_PROMPT);
          }});
        }
        """
}
