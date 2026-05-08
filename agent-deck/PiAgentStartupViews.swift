import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiStartupResourceItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case agent(String)
        case skill(String)
        case command(String)
        case prompt(String)
        case extensions
        case environment
        case file(URL)
        case none
    }

    let title: String
    var detail: String?
    let kind: Kind

    var id: String { "\(title)-\(String(describing: kind))" }
    var isClickable: Bool {
        if case .none = kind { return false }
        return true
    }
}

private extension Array where Element == PiStartupResourceItem {
    func uniqueByTitleAndDetail() -> [PiStartupResourceItem] {
        reduce(into: [PiStartupResourceItem]()) { result, item in
            if !result.contains(where: { $0.title == item.title && $0.detail == item.detail }) {
                result.append(item)
            }
        }
    }
}

struct PiAgentStartupResourcesCard: View {
    @ObservedObject var viewModel: AppViewModel
    let session: PiAgentSessionRecord
    @State private var isExpanded = false

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            resourceSection("Context", count: contextItems.count, icon: "doc.text", color: AppTheme.brandAccentDeep, items: contextItems, columns: 2)
                            resourceSection("Environment", count: envItems.count, icon: "key", color: .green, items: envItems, columns: 2)
                        }
                        resourceSection("Agents", count: effectiveResourceCount(agentItems), icon: "rectangle.connected.to.line.below", color: .teal, items: agentItems, columns: 3, showsDetails: true)
                        resourceSection("Skills", count: effectiveResourceCount(skillItems), icon: "wand.and.stars", color: AppTheme.assistantAccent, items: skillItems)
                        resourceSection("Prompts", count: effectiveResourceCount(promptItems), icon: "text.badge.star", color: .indigo, items: promptItems)
                        resourceSection("Extensions", count: extensionItems.count, icon: "puzzlepiece.extension", color: .orange, items: extensionItems)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("pi")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(AppTheme.brandAccent)
                .padding(9)
                .background(Circle().fill(AppTheme.brandAccent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Pi startup resources")
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                HStack(spacing: 6) {
                    hintChip("↩", "send / steer")
                    hintChip("⇧/⌘/⌥ ↩", "newline")
                    hintChip("Esc", "stop running turn")
                    hintChip("Esc Esc", "clear input")
                    hintChip("/", "commands")
                    hintChip("@", "file suggestions")
                }
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(AppTheme.contentSubtleFill))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .contentShape(Rectangle())
    }

    private var contextItems: [PiStartupResourceItem] {
        let agents = URL(fileURLWithPath: session.projectPath).appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: agents.path) {
            return [.init(title: "AGENTS.md", detail: agents.path, kind: .file(agents))]
        }
        return [.init(title: "No AGENTS.md detected", kind: .none)]
    }

    private var startupSnapshot: ScanSnapshot {
        viewModel.startupSnapshot(forProjectPath: session.projectPath)
    }

    private var agentItems: [PiStartupResourceItem] {
        guard session.subagentsEnabled else {
            return [.init(title: "This session started with subagents disabled", detail: "Re-enable subagents before creating a new session if you want agent discovery again.", kind: .none)]
        }

        let enabled = startupSnapshot.effectiveAgents
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return enabled.isEmpty
            ? [.init(title: "No enabled agents", kind: .none)]
            : enabled.map { agent in
                let description = agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelSuffix = agent.resolved.model.map { " · \($0)" } ?? ""
                let source = agent.resolutionKind.rawValue
                let detail = [description, source + modelSuffix]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return .init(title: agent.name, detail: detail, kind: .agent(agent.id))
            }
    }

    private var skillItems: [PiStartupResourceItem] {
        return startupSnapshot.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                let scope = skill.source.kind == .project ? "Project" : skill.source.kind.rawValue
                let detail = [scope, skill.description].compactMap { $0 }.joined(separator: " · ")
                return .init(title: skill.name, detail: detail, kind: .skill(skill.id))
            }
    }

    private var promptItems: [PiStartupResourceItem] {
        let commands = startupSnapshot.commands.map { PiStartupResourceItem(title: $0.invocation, detail: $0.description, kind: .command($0.id)) }
        let prompts = startupSnapshot.promptTemplates.map { PiStartupResourceItem(title: $0.invocation, detail: $0.description, kind: .prompt($0.id)) }
        return (commands + prompts).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var extensionItems: [PiStartupResourceItem] {
        let enabledPaths = viewModel.appSettings.enabledExtensionPaths
        let projectURL = URL(fileURLWithPath: session.projectPath, isDirectory: true)
        let managedItems = PiExtensionManagementService()
            .scan(projectRoot: projectURL)
            .filter { record in
                enabledPaths.contains(URL(fileURLWithPath: record.path).standardizedFileURL.path)
            }
            .map { record in
                let detail = [record.scope.rawValue, record.origin.rawValue, shortPath(record.path)]
                    .joined(separator: " · ")
                return PiStartupResourceItem(title: record.displayName, detail: detail, kind: .file(URL(fileURLWithPath: record.path)))
            }

        return managedItems
            .uniqueByTitleAndDetail()
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var envItems: [PiStartupResourceItem] {
        startupSnapshot.envKeys.map { env in
            let scope = env.source.kind.rawValue.lowercased()
            let title: String
            if let value = env.value, !value.isEmpty {
                title = "\(env.key) = \(masked(value)) · \(scope)"
            } else {
                title = "\(env.key) · \(scope)"
            }
            return .init(title: title, detail: env.source.path, kind: .environment)
        }
    }

    private func resourceSection(_ title: String, count: Int, icon: String, color: Color, items: [PiStartupResourceItem], columns: Int = 5, showsDetails: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            let rows = chunk(items, size: columns)
            Grid(horizontalSpacing: 8, verticalSpacing: 7) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    GridRow {
                        ForEach(row) { item in
                            resourceChip(item, showsDetail: showsDetails)
                        }
                        ForEach(0..<max(columns - row.count, 0), id: \.self) { _ in
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.contentSubtleFill.opacity(0.65))
                .stroke(AppTheme.contentStroke.opacity(0.8), lineWidth: 1)
        )
    }

    private func effectiveResourceCount(_ items: [PiStartupResourceItem]) -> Int {
        guard items.count == 1, let first = items.first else { return items.count }
        if case PiStartupResourceItem.Kind.none = first.kind {
            return 0
        }
        return items.count
    }

    private func chunk(_ items: [PiStartupResourceItem], size: Int) -> [[PiStartupResourceItem]] {
        stride(from: 0, to: items.count, by: max(size, 1)).map { start in
            Array(items[start..<min(start + max(size, 1), items.count)])
        }
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced().weight(.bold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }

    private func resourceChip(_ item: PiStartupResourceItem, isOverflow: Bool = false, showsDetail: Bool = false) -> some View {
        Button {
            openResource(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isOverflow ? AppTheme.brandAccent : .primary)
                if showsDetail, let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, showsDetail ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOverflow ? AppTheme.brandAccent.opacity(0.10) : AppTheme.contentFill.opacity(0.75))
            )
        }
        .buttonStyle(.plain)
        .disabled(!item.isClickable)
        .help(item.detail ?? item.title)
    }

    private func openResource(_ item: PiStartupResourceItem) {
        switch item.kind {
        case .agent(let id):
            viewModel.selectedAgentID = id
            viewModel.selectedSidebarItem = .agents
        case .skill(let id):
            viewModel.selectedSkillID = id
            viewModel.selectedSidebarItem = .skills
        case .command(let id):
            viewModel.selectedCommandItemID = id
            viewModel.selectedSidebarItem = .commands
        case .prompt(let id):
            viewModel.selectedCommandItemID = id
            viewModel.selectedSidebarItem = .prompts
        case .extensions:
            viewModel.selectedSidebarItem = .extensions
        case .environment:
            viewModel.selectedSidebarItem = .environment
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .none:
            break
        }
    }

    private func shortExtensionName(_ value: String) -> String {
        if value.hasPrefix("npm:") { return String(value.dropFirst(4)) }
        if value.contains("/") { return URL(fileURLWithPath: value).lastPathComponent }
        return value
    }

    private func extensionPackageItem(_ package: String) -> PiStartupResourceItem? {
        let resolved = resolvePackageURL(package)
        if let resolved, !packageDeclaresExtensions(at: resolved) {
            return nil
        }
        let title = extensionPackageTitle(package, resolvedURL: resolved)
        return PiStartupResourceItem(title: title, detail: package, kind: .extensions)
    }

    private func extensionPackageTitle(_ package: String, resolvedURL: URL?) -> String {
        if let resolvedURL, let manifest = readPackageManifest(at: resolvedURL), let pi = manifest["pi"] as? [String: Any], let extensions = pi["extensions"] as? [String], extensions.count == 1 {
            return "\(shortExtensionName(package)):\(extensions[0].replacingOccurrences(of: "./", with: ""))"
        }
        return shortExtensionName(package)
    }

    private func packageDeclaresExtensions(at url: URL) -> Bool {
        guard let manifest = readPackageManifest(at: url) else { return false }
        if let pi = manifest["pi"] as? [String: Any], let extensions = pi["extensions"] as? [String], !extensions.isEmpty {
            return true
        }
        return extensionFiles(in: url.appendingPathComponent("extensions", isDirectory: true)).isEmpty == false
    }

    private func readPackageManifest(at url: URL) -> [String: Any]? {
        let manifestURL = url.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func resolvePackageURL(_ package: String) -> URL? {
        let raw = package.hasPrefix("npm:") ? String(package.dropFirst(4)) : package
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules").appendingPathComponent(raw),
            URL(fileURLWithPath: "/usr/local/lib/node_modules").appendingPathComponent(raw),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/npm/node_modules").appendingPathComponent(raw),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/git").appendingPathComponent(raw)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private struct ExtensionEntry: Hashable {
        let title: String
        let url: URL
    }

    private func discoveredExtensionEntries() -> [ExtensionEntry] {
        let global = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions", isDirectory: true)
        let project = URL(fileURLWithPath: session.projectPath).appendingPathComponent(".pi/extensions", isDirectory: true)
        return [global, project]
            .flatMap { extensionEntries(in: $0) }
            .reduce(into: [ExtensionEntry]()) { result, entry in
                if !result.contains(where: { $0.title == entry.title && $0.url.path == entry.url.path }) {
                    result.append(entry)
                }
            }
    }

    private func extensionEntries(in directory: URL) -> [ExtensionEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isRegularFile == true, isExtensionSourceFile(url) {
                return ExtensionEntry(title: url.lastPathComponent, url: url)
            }
            if values?.isDirectory == true, directoryContainsExtension(url) {
                return ExtensionEntry(title: url.lastPathComponent, url: url)
            }
            return nil
        }
    }

    private func directoryContainsExtension(_ directory: URL) -> Bool {
        if packageDeclaresExtensions(at: directory) { return true }
        return extensionFiles(in: directory).isEmpty == false
    }

    private func extensionFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return contents.filter(isExtensionSourceFile)
    }

    private func isExtensionSourceFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && ["ts", "js", "mjs", "cjs"].contains(url.pathExtension.lowercased())
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else { return "••••" }
        return String(value.prefix(4)) + "••••"
    }
}
