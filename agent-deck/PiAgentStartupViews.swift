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
                VStack(alignment: .leading, spacing: 14) {
                    resourceSection("Runtime", icon: "cpu", color: AppTheme.piLogo, items: runtimeItems, columns: 1, showsDetails: true)

                    if isEmpty {
                        Text("No agents, skills, prompts, or environment overrides were discovered for this session.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        resourceSection("Context", icon: "doc.text", color: .blue, items: contextItems, columns: 1)
                        resourceSection("Environment", icon: "key", color: .green, items: envItems, columns: 1)
                        resourceSection("Agents", icon: "paperplane", color: .teal, items: agentItems, columns: 1, showsDetails: true)
                        resourceSection("Skills", icon: "wand.and.stars", color: AppTheme.assistantAccent, items: skillItems, columns: 1)
                        resourceSection("Prompts", icon: AppSymbols.promptTemplate, color: .indigo, items: promptItems, columns: 1)
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

    private var runtimeItems: [PiStartupResourceItem] {
        let provider = session.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = session.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = session.thinkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelTitle: String
        if let provider, !provider.isEmpty, let model, !model.isEmpty {
            modelTitle = "Model: \(provider)/\(model)"
        } else if let model, !model.isEmpty {
            modelTitle = "Model: \(model)"
        } else {
            modelTitle = "Model: waiting for Pi RPC state"
        }
        let thinkingTitle = "Thinking: \((thinking?.isEmpty == false ? thinking : nil) ?? "waiting for Pi RPC state")"
        return [.init(title: modelTitle, detail: thinkingTitle, kind: .none)]
    }

    private var agentItems: [PiStartupResourceItem] {
        guard session.subagentsEnabled else {
            return [.init(title: "This session started with Deck agents disabled", detail: "Re-enable Deck agents before creating a new session if you want agent discovery again.", kind: .none)]
        }

        let enabled = viewModel.catalogAgents(for: session)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !enabled.isEmpty else {
            return [.init(title: "No Deck agents selected for this session", detail: "This session runs without Deck agent delegation.", kind: .none)]
        }
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
        // Only the skills the orchestration parent was actually launched with —
        // global defaults ∪ project-assigned — not every skill discovered on
        // disk. Reuses the exact active set the composer `/` browser computes.
        viewModel.activeParentSkills(forProjectPath: session.projectPath)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                let scope = skill.source.kind == .project ? "Project" : skill.source.kind.rawValue
                let detail = [scope, skill.description].compactMap { $0 }.joined(separator: " · ")
                return .init(title: skill.name, detail: detail, kind: .skill(skill.id))
            }
    }

    private var promptItems: [PiStartupResourceItem] {
        // Only the prompt templates the parent session was launched with — not
        // every template discovered on disk. Mirrors the skills treatment above.
        viewModel.activeParentPromptTemplates(forProjectPath: session.projectPath)
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

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        resourceChip(item, showsDetail: showsDetails)
                        if index < items.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
            .padding(.vertical, showsDetail ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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

/// Pre-launch picker that lets a draft session choose which subagents it
/// launches with. Shown in the chat area above the composer only while the
/// session is a draft with subagents enabled; once the first message is sent
/// the catalog is baked into the system prompt and the card disappears.
struct PiAgentSessionSubagentPickerCard: View {
    var viewModel: AppViewModel
    let session: PiAgentSessionRecord

    @State private var isExpanded = false
    @State private var isAddSheetPresented = false

    static let accent = Color.teal

    /// All render-time data, resolved once per `body` evaluation so the
    /// catalog scan in `selectableAgentUniverse` runs exactly once — not once
    /// per derived list.
    private struct Resolved {
        let rows: [EffectiveAgentRecord]
        let addable: [EffectiveAgentRecord]
        let selection: Set<String>
        let hasExplicitSelection: Bool

        var selectedCount: Int {
            rows.filter { selection.contains($0.name) }.count
        }

        var subtitle: String {
            selectedCount == 0
                ? "None selected · this session runs without Deck agents"
                : "\(selectedCount) of \(rows.count) selected · set before the first message"
        }
    }

    private func resolve() -> Resolved {
        let universe = viewModel.selectableAgentUniverse(forProjectPath: session.projectPath)
            .filter { $0.resolved.disabled != true }
        let defaultNames = Set(
            viewModel.startupSnapshot(forProjectPath: session.projectPath).effectiveAgents
                .filter { $0.resolved.disabled != true }
                .map(\.name)
        )
        let selection = session.agentSelection ?? defaultNames
        let rowNames = defaultNames.union(selection)

        let byName: (EffectiveAgentRecord, EffectiveAgentRecord) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        // `seenRows` ends up holding exactly the row names, so the "addable"
        // pass reuses it instead of rebuilding a separate set.
        var seenRows = Set<String>()
        let rows = universe
            .filter { rowNames.contains($0.name) && seenRows.insert($0.name).inserted }
            .sorted(by: byName)
        var seenAddable = Set<String>()
        let addable = universe
            .filter { !seenRows.contains($0.name) && seenAddable.insert($0.name).inserted }
            .sorted(by: byName)

        return Resolved(
            rows: rows,
            addable: addable,
            selection: selection,
            hasExplicitSelection: session.agentSelection != nil
        )
    }

    var body: some View {
        // 1:1 agent chats never delegate to other subagents — the user IS the
        // supervisor, and the runner does not install the `managed_subagent`
        // bridge for these sessions. Hide the picker entirely so it doesn't
        // imply a capability the session doesn't have.
        if session.isAgentBound {
            EmptyView()
        } else {
            let data = resolve()
            let isHidden = data.rows.isEmpty && data.addable.isEmpty
            // Fade in on cold start: the universe is briefly empty while the
            // first project scan runs, then populates. Softens that handoff.
            Group {
                if isHidden {
                    EmptyView()
                } else {
                    AppRowCard {
                        VStack(alignment: .leading, spacing: 0) {
                            header(data)
                            if isExpanded {
                                Divider().padding(.vertical, 10)
                                agentList(data)
                            }
                        }
                    }
                    .sheet(isPresented: $isAddSheetPresented) {
                        PiAgentAddAgentsSheet(
                            addable: data.addable,
                            description: description(for:),
                            onAdd: { names in
                                var updated = data.selection
                                for name in names { updated.insert(name) }
                                viewModel.setAgentSelection(updated, for: session.id)
                            }
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeOut(duration: 0.22), value: isHidden)
        }
    }

    private func header(_ data: Resolved) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "paperplane")
                    .foregroundStyle(Self.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deck agents for this session")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(data.subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func agentList(_ data: Resolved) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(data.rows, id: \.name) { agent in
                agentRow(agent, checked: data.selection.contains(agent.name), selection: data.selection)
            }
            HStack(spacing: 14) {
                Button {
                    isAddSheetPresented = true
                } label: {
                    Label("Add agents…", systemImage: "plus.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Self.accent)
                .disabled(data.addable.isEmpty)
                .opacity(data.addable.isEmpty ? 0.4 : 1)

                if data.hasExplicitSelection {
                    Button("Reset to default") {
                        viewModel.setAgentSelection(nil, for: session.id)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    private func agentRow(_ agent: EffectiveAgentRecord, checked: Bool, selection: Set<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                apply(selection, name: agent.name, include: !checked)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(checked ? Self.accent : AppTheme.mutedText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        if let detail = description(for: agent) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            chatDirectlyButton(agent)
        }
    }

    @ViewBuilder
    private func chatDirectlyButton(_ agent: EffectiveAgentRecord) -> some View {
        if let project = viewModel.projectByPath[session.projectPath] {
            Button {
                viewModel.startAgentSession(agent: agent, project: project, initialInstruction: nil)
            } label: {
                Image(systemName: "paperplane")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.accent)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a 1:1 chat with \(agent.name)")
            .disabled(agent.resolved.disabled == true)
        }
    }

    private func description(for agent: EffectiveAgentRecord) -> String? {
        let raw = (agent.resolved.whenToUse ?? agent.resolved.description)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private func apply(_ selection: Set<String>, name: String, include: Bool) {
        var updated = selection
        if include { updated.insert(name) } else { updated.remove(name) }
        viewModel.setAgentSelection(updated, for: session.id)
    }
}

/// Multi-select picker presented as a sheet when the user taps "Add agents…"
/// in `PiAgentSessionSubagentPickerCard`. Matches the `MarkdownFileEditorSheet`
/// chrome (compact `.headline` title, 18pt header, divider rails, 16pt footer
/// with prominent confirm button).
struct PiAgentAddAgentsSheet: View {
    let addable: [EffectiveAgentRecord]
    let description: (EffectiveAgentRecord) -> String?
    let onAdd: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    private static let accent = PiAgentSessionSubagentPickerCard.accent

    private var filtered: [EffectiveAgentRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return addable }
        return addable.filter { agent in
            if agent.name.lowercased().contains(q) { return true }
            if let detail = description(agent)?.lowercased(), detail.contains(q) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchField
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            list
            Divider()
            footer
        }
        .frame(width: 540, height: 560)
        .onAppear { isSearchFocused = true }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add agents")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text("Pick agents to include in this session. Selected agents are added when you click Add.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField("Search agents", text: $query)
                .textFieldStyle(.plain)
                .appBrandTint()
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.contentFill.opacity(0.75))
                .stroke(AppTheme.contentStroke.opacity(0.6), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var list: some View {
        if addable.isEmpty {
            emptyState("Every available agent is already in the session.")
        } else if filtered.isEmpty {
            emptyState("No agents match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(filtered, id: \.name) { agent in
                        row(agent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(message)
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ agent: EffectiveAgentRecord) -> some View {
        let isChecked = selected.contains(agent.name)
        return Button {
            if isChecked { selected.remove(agent.name) } else { selected.insert(agent.name) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isChecked ? Self.accent : AppTheme.mutedText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if let detail = description(agent) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isChecked ? Self.accent.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            if !selected.isEmpty {
                Text("\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .appSecondaryButton()
                .keyboardShortcut(.cancelAction)
            Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                onAdd(selected)
                dismiss()
            }
            .appPrimaryButton()
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .padding(16)
    }
}
