import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiStartupResourceItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case agent(String)
        case skill(String)
        case prompt(String)
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
    var onExpansionChange: () -> Void = {}
    @State private var isExpanded = false

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                    onExpansionChange()
                } label: {
                    header
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            resourceSection("Context", icon: "doc.text", color: .blue, items: contextItems, columns: 2)
                            resourceSection("Environment", icon: "key", color: .green, items: envItems, columns: 2)
                        }
                        resourceSection("Agents", icon: "rectangle.connected.to.line.below", color: .teal, items: agentItems, columns: 3, showsDetails: true)
                        resourceSection("Skills", icon: "wand.and.stars", color: AppTheme.assistantAccent, items: skillItems)
                        resourceSection("Prompts", icon: "text.badge.star", color: .indigo, items: promptItems)
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
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 6) {
                        hintChip("↩", "send / steer")
                        hintChip("⇧/⌘/⌥ ↩", "newline")
                        hintChip("Esc", "stop running turn")
                        hintChip("Esc Esc", "clear input")
                        hintChip("/", "commands")
                        hintChip("@", "file suggestions")
                    }
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
        return []
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
        return enabled.map { agent in
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
        startupSnapshot.promptTemplates
            .map { PiStartupResourceItem(title: $0.invocation, detail: $0.description, kind: .prompt($0.id)) }
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

    @ViewBuilder
    private func resourceSection(_ title: String, icon: String, color: Color, items: [PiStartupResourceItem], columns: Int = 5, showsDetails: Bool = false) -> some View {
        if !items.isEmpty {
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
    }

    private func chunk(_ items: [PiStartupResourceItem], size: Int) -> [[PiStartupResourceItem]] {
        stride(from: 0, to: items.count, by: max(size, 1)).map { start in
            Array(items[start..<min(start + max(size, 1), items.count)])
        }
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
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
        .appGlassCapsule()
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
        case .prompt(let id):
            viewModel.selectedCommandItemID = id
            viewModel.selectedSidebarItem = .prompts
        case .environment:
            viewModel.selectedSidebarItem = .environment
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .none:
            break
        }
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else { return "••••" }
        return String(value.prefix(4)) + "••••"
    }
}
