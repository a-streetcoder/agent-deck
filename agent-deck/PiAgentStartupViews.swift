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

/// Compact keyboard-shortcut strip printed at the top of the transcript. Not a
/// card — just the hint chips. Replaces the old expandable
/// `PiAgentStartupResourcesCard`: the in-transcript expandable block never
/// re-measured reliably inside the AppKit table, so the session resources
/// moved to a toolbar popover (`PiAgentStartupResourcesPopover`) and the
/// shortcuts stay here as a fixed-height, always-visible row.
struct PiAgentShortcutsStrip: View {
    var body: some View {
        HStack(spacing: 14) {
            hintChip(["↩"], "send / steer")
            hintChip(["⇧", "↩"], "newline")
            hintChip(["esc"], "stop running turn")
            hintChip(["esc ×2"], "clear input")
            hintChip(["/"], "commands")
            hintChip(["@"], "file suggestions")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintChip(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    AppKeyCap(key)
                }
            }
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(AppTheme.mutedText)
        }
    }
}

/// Session resources (Context / Environment / Agents / Skills / Prompts) shown
/// as a toolbar popover instead of an in-transcript expandable card. Reachable
/// from the `info.circle` button grouped with the transcript-display eye.
struct PiAgentStartupResourcesPopover: View {
    var viewModel: AppViewModel
    let session: PiAgentSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("pi")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(AppTheme.piLogo.gradient)
                Text("Session resources")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if isEmpty {
                        Text("No agents, skills, prompts, or environment overrides were discovered for this session.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        resourceSection("Context", icon: "doc.text", color: .blue, items: contextItems, columns: 1)
                        resourceSection("Environment", icon: "key", color: .green, items: envItems, columns: 1)
                        resourceSection("Agents", icon: "rectangle.connected.to.line.below", color: .teal, items: agentItems, columns: 1, showsDetails: true)
                        resourceSection("Skills", icon: "wand.and.stars", color: AppTheme.assistantAccent, items: skillItems, columns: 1)
                        resourceSection("Prompts", icon: "text.badge.star", color: .indigo, items: promptItems, columns: 1)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 460, height: 480)
    }

    private var isEmpty: Bool {
        contextItems.isEmpty && envItems.isEmpty && agentItems.isEmpty
            && skillItems.isEmpty && promptItems.isEmpty
    }

    // MARK: - Resource items

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
        startupSnapshot.skills
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

    // MARK: - Section / chip

    @ViewBuilder
    private func resourceSection(_ title: String, icon: String, color: Color, items: [PiStartupResourceItem], columns: Int = 1, showsDetails: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .frame(width: 18)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        resourceChip(item, showsDetail: showsDetails)
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

    private func resourceChip(_ item: PiStartupResourceItem, showsDetail: Bool = false) -> some View {
        Button {
            openResource(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
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
                    .fill(AppTheme.contentFill.opacity(0.75))
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
