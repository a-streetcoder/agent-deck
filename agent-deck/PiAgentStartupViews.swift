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

    // Snapshotted once on appear (not read in body) so an open popover doesn't
    // recompute the recap on every streaming pulse.
    @State private var toolRecap: [PiAgentToolCallRecapItem] = []
    @State private var mcpRecap: [PiAgentMCPSessionRecap] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPopoverHeader(title: "Session resources")

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    resourceSection("Runtime", icon: "cpu", items: runtimeItems, columns: 1, showsDetails: true)
                    resourceSection("Extensions", icon: "puzzlepiece.extension", items: extensionItems, columns: 1, showsDetails: true)
                    mcpSection
                    toolCallSection

                    if isEmpty {
                        Text("No agents, skills, prompts, or environment overrides were discovered for this session.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        resourceSection("Context", icon: "doc.text", items: contextItems, columns: 1)
                        resourceSection("Environment", icon: "key", items: envItems, columns: 1)
                        resourceSection("Agents", icon: "paperplane", items: agentItems, columns: 1, showsDetails: true)
                        resourceSection("Memory", icon: "brain", items: memoryItems, columns: 1, showsDetails: true)
                        resourceSection("Skills", icon: "wand.and.stars", items: skillItems, columns: 1)
                        resourceSection("Prompts", icon: AppSymbols.promptTemplate, items: promptItems, columns: 1)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: AppTheme.Popover.wideWidth, height: 480)
        .onAppear {
            toolRecap = viewModel.toolCallRecap(forSessionID: session.id)
            mcpRecap = viewModel.mcpSessionRecap(for: session)
        }
    }

    @ViewBuilder
    private var mcpSection: some View {
        if !mcpRecap.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "powerplug")
                        .foregroundStyle(AppTheme.brandAccent)
                        .frame(width: 18)
                    Text("MCP")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.brandAccent)
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(mcpRecap) { server in
                        mcpServerRow(server)
                        if server.id != mcpRecap.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func mcpServerRow(_ server: PiAgentMCPSessionRecap) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "server.rack")
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 17)
                Text(server.server)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(server.advertisedToolCount == 1 ? "1 tool" : "\(server.advertisedToolCount) tools")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }

            if server.calledTools.isEmpty {
                Text("No tools called yet")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.leading, 26)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(server.calledTools) { tool in
                        HStack(spacing: 7) {
                            Image(systemName: tool.errorCount > 0 ? "exclamationmark.triangle" : "bolt.horizontal")
                                .font(.caption2)
                                .foregroundStyle(tool.errorCount > 0 ? AppTheme.roleError : AppTheme.mutedText)
                                .frame(width: 13)
                            Text(tool.name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text("\(tool.callCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.mutedText)
                            if tool.errorCount > 0 {
                                Text("\(tool.errorCount)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(AppTheme.roleError)
                            }
                        }
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var toolCallSection: some View {
        if !toolRecap.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(AppTheme.brandAccent)
                        .frame(width: 18)
                    Text("Tool calls")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.brandAccent)
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(toolRecap) { item in
                        toolCallRow(item)
                        if item.id != toolRecap.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func toolCallRow(_ item: PiAgentToolCallRecapItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.icon)
                .foregroundStyle(item.errorCount > 0 ? AppTheme.roleError : AppTheme.mutedText)
                .frame(width: 17)
            Text(item.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("\(item.successCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.mutedText)
            if item.errorCount > 0 {
                Text("\(item.errorCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.roleError)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(item.name): \(item.successCount) ok\(item.errorCount > 0 ? ", \(item.errorCount) failed" : "")")
    }

    private var isEmpty: Bool {
        contextItems.isEmpty && envItems.isEmpty && agentItems.isEmpty
            && skillItems.isEmpty && promptItems.isEmpty && extensionItems.isEmpty
    }

    // MARK: - Resource items

    private var contextItems: [PiStartupResourceItem] {
        guard let projectPath = session.projectPathForProjectFeatures else { return [] }
        let agents = URL(fileURLWithPath: projectPath).appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: agents.path) {
            return [.init(title: "AGENTS.md", detail: agents.path, kind: .file(agents))]
        }
        return []
    }

    private var startupSnapshot: ScanSnapshot {
        guard let projectPath = session.projectPathForProjectFeatures else { return viewModel.snapshot }
        return viewModel.startupSnapshot(forProjectPath: projectPath)
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

    private var extensionItems: [PiStartupResourceItem] {
        guard let extensions = session.injectedExtensions, !extensions.isEmpty else { return [] }
        return extensions.map { path in
            let url = URL(fileURLWithPath: path)
            let name = extensionDisplayName(for: path)
            let exists = FileManager.default.fileExists(atPath: path)
            return PiStartupResourceItem(
                title: name,
                detail: nil,
                kind: exists ? .file(url) : .none
            )
        }
    }

    private func extensionDisplayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "index.ts" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private var agentItems: [PiStartupResourceItem] {
        guard !session.isNoProject else {
            return [.init(title: "General Chat session", detail: "Project-scoped Deck agents are not injected.", kind: .none)]
        }
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

    private var memoryItems: [PiStartupResourceItem] {
        guard !session.isNoProject else {
            return [.init(title: "General Chat session", detail: "Project memory is not injected.", kind: .none)]
        }
        guard session.memoryEnabled else {
            return [.init(title: "This session started with Memory disabled", detail: "Enable Memory before starting a new session if you want recall and capture again.", kind: .none)]
        }
        let recalledCount = session.recalledMemoryIDs?.count ?? 0
        let title: String
        if recalledCount > 0 {
            title = recalledCount == 1 ? "1 memory recalled at start" : "\(recalledCount) memories recalled at start"
        } else if session.memoryRecallCompleted {
            title = "No relevant memories recalled at start"
        } else {
            title = "Memory enabled"
        }
        return [.init(title: title, detail: "Relevant memories are injected at launch; new durable facts are captured as you work.", kind: .none)]
    }

    private var skillItems: [PiStartupResourceItem] {
        // Only the skills the orchestration parent was actually launched with —
        // global defaults ∪ project-assigned — not every skill discovered on
        // disk. Reuses the exact active set the composer `/` browser computes.
        guard let projectPath = session.projectPathForProjectFeatures else { return [] }
        return viewModel.activeParentSkills(forProjectPath: projectPath)
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
        guard let projectPath = session.projectPathForProjectFeatures else { return [] }
        return viewModel.activeParentPromptTemplates(forProjectPath: projectPath)
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
    private func resourceSection(_ title: String, icon: String, items: [PiStartupResourceItem], columns: Int = 1, showsDetails: Bool = false) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(AppTheme.brandAccent)
                        .frame(width: 18)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.brandAccent)
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        resourceChip(items[index], showsDetail: showsDetails)
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
    @State private var isExpandedContentVisible = false
    @State private var expansionGeneration = 0
    @State private var isAddSheetPresented = false
#if DEBUG
    var stressExpansionRequest: Bool? = nil
    var stressAcknowledgements: PickerStressCardAcknowledgements? = nil
#endif

    static let accent = Color.teal
    private static let expandContentAnimation = Animation.easeOut(duration: 0.16)
    private static let collapseContentAnimation = Animation.easeInOut(duration: 0.12)
    private static let collapseSnapDelay: TimeInterval = 0.12

    /// All render-time data, resolved once per `body` evaluation so the
    /// catalog scan in `selectableAgentUniverse` runs exactly once — not once
    /// per derived list.
    private struct Resolved {
        let rows: [EffectiveAgentRecord]
        let addedRows: [EffectiveAgentRecord]
        let addable: [EffectiveAgentRecord]
        let selection: Set<String>
        let hasExplicitSelection: Bool

        var selectedCount: Int {
            rows.filter { selection.contains($0.name) }.count
        }

        var addedCount: Int {
            addedRows.count
        }

        var subtitle: String {
            var text = "\(selectedCount) of \(rows.count) default selected"
            // Never say "None selected" once there are hidden added agents —
            // the count alone would understate the effective launch set.
            if addedCount > 0 {
                text += " · \(addedCount) added"
            }
            return text
        }
    }

    private func resolve() -> Resolved {
        guard let projectPath = session.projectPathForProjectFeatures else {
#if DEBUG
            if stressExpansionRequest != nil {
                let rows = debugStressRows()
                return Resolved(
                    rows: rows,
                    addedRows: [],
                    addable: [],
                    selection: Set(rows.map(\.name)),
                    hasExplicitSelection: false
                )
            }
#endif
            return Resolved(rows: [], addedRows: [], addable: [], selection: [], hasExplicitSelection: session.agentSelection != nil)
        }
        let universe = viewModel.selectableAgentUniverse(forProjectPath: projectPath)
            .filter { $0.resolved.disabled != true }
        let defaultNames = Set(
            viewModel.startupSnapshot(forProjectPath: projectPath).effectiveAgents
                .filter { $0.resolved.disabled != true }
                .map(\.name)
        )
        var selection = session.agentSelection ?? defaultNames
        // Main card rows start with the project assigned/default agents. Agents
        // added via "Add agents" render as their own section below a divider so
        // the effective launch set is visible without mixing defaults/extras.
        let rowNames = defaultNames

        let byName: (EffectiveAgentRecord, EffectiveAgentRecord) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var seenRows = Set<String>()
        var rows = universe
            .filter { rowNames.contains($0.name) && seenRows.insert($0.name).inserted }
            .sorted(by: byName)
#if DEBUG
        // The actual-app stress journey must exercise the expanded catalog even
        // on a developer machine with no project-assigned agents. These records
        // exist only in memory for AGENTDECK_PICKER_STRESS; no resource is saved
        // or injected into a normal launch.
        if stressExpansionRequest != nil, rows.isEmpty {
            rows = debugStressRows()
            selection.formUnion(rows.map(\.name))
        }
#endif
        var seenAddedRows = Set<String>()
        let addedRows = universe
            .filter { selection.contains($0.name) && !rowNames.contains($0.name) && seenAddedRows.insert($0.name).inserted }
            .sorted(by: byName)
        var seenAddable = Set<String>()
        let addable = universe
            .filter { !rowNames.contains($0.name) && seenAddable.insert($0.name).inserted }
            .sorted(by: byName)

        return Resolved(
            rows: rows,
            addedRows: addedRows,
            addable: addable,
            selection: selection,
            hasExplicitSelection: session.agentSelection != nil
        )
    }

#if DEBUG
    private func debugStressRows() -> [EffectiveAgentRecord] {
        (0..<12).map { index in
            let name = "picker-stress-agent-\(index + 1)"
            var config = AgentConfig.empty
            config.name = name
            config.description = "Debug-only picker resize stress agent"
            config.model = "openai/gpt-5.4-mini"
            config.thinking = "medium"
            return EffectiveAgentRecord(
                id: name,
                name: name,
                projectRoot: session.projectPath ?? "",
                builtin: nil,
                globalCustom: nil,
                projectCustom: nil,
                userOverride: nil,
                projectOverride: nil,
                resolved: config,
                resolutionKind: .builtin
            )
        }
    }
#endif

    var body: some View {
        // General Chat sessions never expose Deck-agent delegation.
        if session.isNoProject {
#if DEBUG
            if stressExpansionRequest != nil {
                cardBody
            } else {
                EmptyView()
            }
#else
            EmptyView()
#endif
        } else if session.isAgentBound {
            // 1:1 agent chats never delegate to other subagents — the user IS the
            // supervisor, and the runner does not install the `managed_subagent`
            // bridge for these sessions. The picker's job is done, so it collapses
            // to a summary of the binding with an undo, instead of a list that
            // would imply a capability the session doesn't have.
            boundSummaryCard
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
            // ONE persistent card across on/off: toggling the switch only dims
            // the content in place. Branching to a separate "off" card view
            // here would replay the card's enter/exit transition on every flip,
            // which reads as the card reloading.
            let enabled = session.subagentsEnabled
            let data = enabled ? resolve() : nil
#if DEBUG
            let isHidden = stressExpansionRequest == nil && enabled && data?.rows.isEmpty == true && data?.addable.isEmpty == true
#else
            let isHidden = enabled && data?.rows.isEmpty == true && data?.addable.isEmpty == true
#endif
            // Fade in on cold start: the universe is briefly empty while the
            // first project scan runs, then populates. Softens that handoff.
            return Group {
                if isHidden {
                    EmptyView()
                } else {
                    AppRowCard(
                        contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14)
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            header(data)
                            if isExpanded, let data {
                                expandedContent(data)
                                    .onAppear { acknowledgeStressCard(data: data, expanded: true) }
                                    .opacity(isExpandedContentVisible ? 1 : 0)
                                    .offset(y: isExpandedContentVisible ? 0 : -6)
                                    .allowsHitTesting(isExpandedContentVisible)
                                    .accessibilityHidden(!isExpandedContentVisible)
                            }
                        }
                    }
#if DEBUG
                    .onChange(of: stressExpansionRequest) { _, expanded in
                        guard let expanded else { return }
                        setExpanded(expanded)
                        acknowledgeStressCard(data: data, expanded: expanded)
                    }
#endif
                    .sheet(isPresented: $isAddSheetPresented) {
                        if let data {
                            PiAgentAddAgentsSheet(
                                addable: data.addable,
                                currentSelection: data.selection,
                                launchDetail: launchDetail(for:),
                                onApply: { chosenExtras in
                                    // Preserve visible default-row selections
                                    // (intersect current selection with default
                                    // row names), then union the chosen extras.
                                    let defaults = data.selection.intersection(data.rows.map(\.name))
                                    viewModel.setAgentSelection(defaults.union(chosenExtras), for: session.id)
                                }
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onAppear {
                        acknowledgeStressCard(data: data, expanded: isExpanded)
                    }
                }
            }
            .animation(.easeOut(duration: 0.22), value: isHidden)
    }

    /// One header for both states — same view identity, so flipping the switch
    /// dims the content in place instead of swapping (and re-transitioning) the
    /// card. `data` is nil when Deck agents are off; only the switch keeps full
    /// strength there, as the way back on.
    private func header(_ data: Resolved?) -> some View {
        let enabled = data != nil
        return HStack(spacing: 10) {
            Button {
                guard enabled else { return }
                setExpanded(!isExpanded)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(Self.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Deck agents for this session")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(data?.subtitle ?? "Off, Pi will not delegate in this session")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .saturation(enabled ? 1 : 0.4)
            enabledSwitch
            if enabled {
                Button {
                    setExpanded(!isExpanded)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: 0.18), value: isExpanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Per-session on/off, themed like every other switch in the app. A draft's
    /// toggle acts as the session default: it flips this draft AND the default
    /// for new sessions, so the preference sticks for the next session instead
    /// of silently resetting (the launcher consumes `subagentsEnabled` at first
    /// send to decide whether Pi gets the Deck agent tools at all).
    private var enabledSwitch: some View {
        Toggle("Deck agents", isOn: Binding(
            get: { session.subagentsEnabled },
            set: { newValue in
                if !newValue { setExpanded(false) }
                viewModel.setSubagentsEnabledForSelectedDraftAndNewSessions(newValue)
            }
        ))
        .appSwitch()
        .labelsHidden()
        .controlSize(.small)
        .help(session.subagentsEnabled
            ? "Deck agents are on. Applies to this session and as the default for new sessions"
            : "Deck agents are off. Applies to this session and as the default for new sessions")
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded || expanded != isExpandedContentVisible else { return }
        expansionGeneration += 1
        let generation = expansionGeneration
        if expanded {
            isExpandedContentVisible = false
            setLayoutExpanded(true)
            DispatchQueue.main.async {
                guard generation == expansionGeneration else { return }
                withAnimation(Self.expandContentAnimation) {
                    isExpandedContentVisible = true
                }
            }
        } else {
            withAnimation(Self.collapseContentAnimation) {
                isExpandedContentVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseSnapDelay) {
                guard generation == expansionGeneration else { return }
                setLayoutExpanded(false)
            }
        }
    }

    private func setLayoutExpanded(_ expanded: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isExpanded = expanded
        }
        acknowledgeStressCard(data: nil, expanded: expanded)
    }

#if DEBUG
    private func acknowledgeStressCard(data: Resolved?, expanded: Bool) {
        guard let acknowledgements = stressAcknowledgements,
              acknowledgements.sessionID == session.id else { return }
        acknowledgements.mounted = true
        acknowledgements.expanded = expanded
        if let data { acknowledgements.rowCount = data.rows.count + data.addedRows.count }
        acknowledgements.isCompact = false
    }
#else
    private func acknowledgeStressCard(data: Resolved?, expanded: Bool) {}
#endif

    private func expandedContent(_ data: Resolved) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 10)
            agentList(data)
            delegationPolicySelector
        }
    }

    private var delegationPolicySelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.top, 10)
                .padding(.bottom, 17)

            PiAgentAdaptiveDelegationLayout(spacing: 14) {
                delegationPolicyDescription
                    .frame(maxWidth: .infinity, alignment: .leading)
                delegationPolicyPicker
                    .frame(width: 220, alignment: .leading)
            }
        }
    }

    private var delegationPolicyDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Delegation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(compactDelegationPolicyDescription)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private var delegationPolicyPicker: some View {
        Picker("Delegation policy", selection: delegationPolicyBinding) {
            ForEach(NativeSubagentDelegationPolicy.allCases) { policy in
                Text(policy.displayName).tag(policy)
            }
        }
        .appSegmentedPicker()
        .labelsHidden()
        .controlSize(.small)
    }

    private var compactDelegationPolicyDescription: String {
        switch viewModel.appSettings.nativeSubagentDelegationPolicy {
        case .light:
            return "Parent handles simple work directly; delegates when a Deck agent clearly helps."
        case .balanced:
            return "Delegates substantive specialist work by default; keeps trivial tasks in the parent."
        case .strict:
            return "Delegates any substantive work when a matching Deck agent exists."
        }
    }

    private var delegationPolicyBinding: Binding<NativeSubagentDelegationPolicy> {
        Binding(
            get: { viewModel.appSettings.nativeSubagentDelegationPolicy },
            set: { policy in
                withAnimation(nil) {
                    viewModel.setNativeSubagentDelegationPolicy(policy)
                }
            }
        )
    }

    private func agentList(_ data: Resolved) -> some View {
        // The card lives above the composer in an HSplitView. Its full agent
        // catalog must not become the split view's intrinsic minimum height:
        // doing so made AppKit repeatedly renegotiate NSHostingView.minSize as
        // rows changed between their horizontal and vertical variants. Keep the
        // complete catalog available in a bounded, native scroll region instead.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(data.rows, id: \.name) { agent in
                    agentRow(agent, checked: data.selection.contains(agent.name), selection: data.selection)
                }
                if !data.addedRows.isEmpty {
                    Divider()
                        .padding(.vertical, 6)
                    ForEach(data.addedRows, id: \.name) { agent in
                        agentRow(agent, checked: true, selection: data.selection)
                    }
                }
                PiAgentPickerAddRow(
                    isEnabled: !data.addable.isEmpty,
                    showsReset: data.hasExplicitSelection,
                    onAdd: { isAddSheetPresented = true },
                    onReset: { viewModel.setAgentSelection(nil, for: session.id) }
                )
            }
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .frame(
            minHeight: min(560, CGFloat(data.rows.count + data.addedRows.count) * 40 + 52),
            maxHeight: 560
        )
        .bottomEdgeFade(height: 18)
#if DEBUG
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard let acknowledgements = stressAcknowledgements,
                  acknowledgements.sessionID == session.id else { return }
            acknowledgements.catalogSize = size
            // The bounded catalog is the card's expanded measured surface;
            // report its real layout result without publishing SwiftUI state.
            acknowledgements.cardSize = size
            acknowledgements.rowCount = data.rows.count + data.addedRows.count
            acknowledgements.expanded = isExpanded
        }
#endif
    }

    private func agentRow(_ agent: EffectiveAgentRecord, checked: Bool, selection: Set<String>) -> some View {
        PiAgentSubagentPickerRow(
            agent: agent,
            checked: checked,
            avatarURL: viewModel.agentImageStore.imageURL(for: agent.name),
            launchDetail: launchDetail(for: agent),
            availableModels: viewModel.enabledAvailableModels,
            selectedModelIdentifier: editableModelIdentifier(for: agent),
            selectedThinkingLevel: editableThinkingLevel(for: agent),
            thinkingLevels: editableThinkingLevels(for: agent),
            onSelectModel: { applyModel($0, to: agent) },
            onSelectThinking: { applyThinking($0, to: agent) },
            onToggle: { apply(selection, name: agent.name, include: !checked) },
            onStartDirectChat: {
                withAnimation(.easeOut(duration: 0.22)) {
                    viewModel.bindPiAgentDraft(session.id, to: agent)
                }
            }
        )
    }

    /// Replaces the picker once the draft is bound: avatar + what changed +
    /// the way back. Mirrors the picker header's layout so the swap reads as
    /// the card changing state, not a different component.
    private var boundSummaryCard: some View {
        AppRowCard {
            HStack(spacing: 10) {
                boundAgentAvatar
                VStack(alignment: .leading, spacing: 2) {
                    Text("1:1 chat with \(session.agentName ?? "agent")")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Only this agent replies, with its own prompt and tools")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.22)) {
                        viewModel.unbindPiAgentDraft(session.id)
                    }
                } label: {
                    Text("Switch back")
                        .font(.caption.weight(.semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Self.accent)
                .help("Turn this back into a regular session with Deck agents")
            }
        }
    }

    private var boundAgentAvatar: some View {
        PiAgentPickerAvatar(imageURL: session.agentName.flatMap { viewModel.agentImageStore.imageURL(for: $0) })
    }

    private func apply(_ selection: Set<String>, name: String, include: Bool) {
        var updated = selection
        if include { updated.insert(name) } else { updated.remove(name) }
        viewModel.setAgentSelection(updated, for: session.id)
    }

    // MARK: - Per-agent launch controls
    //
    // Inline model + thinking chips let the user override an agent's model and
    // reasoning effort directly from the picker, persisting via the same
    // `saveAgentDraft` path as the agent editor. These mirror the chip pair
    // that used to live on each picker row.

    private func launchDetail(for agent: EffectiveAgentRecord) -> String {
        let modelPart = editableModelIdentifier(for: agent)
        var parts: [String] = []
        if let modelPart, !modelPart.isEmpty {
            parts.append(modelPart)
        }
        if let thinking = editableThinkingLevel(for: agent), !hasThinkingSuffix(modelPart) {
            parts.append("thinking \(thinking)")
        }
        return parts.isEmpty ? "Pi default" : parts.joined(separator: " · ")
    }

    private func trimmed(_ value: String?) -> String? {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    private func resolvedThinkingToken(for agent: EffectiveAgentRecord) -> String? {
        trimmed(agent.resolved.thinking)
    }

    /// True when `detail` already encodes a thinking level, so callers don't
    /// append a duplicate thinking segment.
    private func hasThinkingSuffix(_ detail: String?) -> Bool {
        guard let detail, !detail.isEmpty else { return false }
        return detail.lowercased().contains("thinking")
    }

    private func editableModelIdentifier(for agent: EffectiveAgentRecord) -> String? {
        trimmed(agent.resolved.model)
    }

    private func editableThinkingLevel(for agent: EffectiveAgentRecord) -> String? {
        let level = resolvedThinkingToken(for: agent)
        guard let level, level != "off" else { return nil }
        return level
    }

    private func editableThinkingLevels(for agent: EffectiveAgentRecord) -> [String] {
        thinkingLevels(forModelIdentifier: editableModelIdentifier(for: agent))
    }

    private func thinkingLevels(forModelIdentifier identifier: String?) -> [String] {
        let models = viewModel.enabledAvailableModels
        if let identifier, let model = models.first(where: { $0.identifier == identifier }) {
            return model.supportedThinkingLevels.isEmpty ? defaultThinkingLevels : model.supportedThinkingLevels
        }
        let discovered = Array(Set(models.flatMap(\.supportedThinkingLevels)))
            .sorted { thinkingSortIndex($0) < thinkingSortIndex($1) }
        return discovered.isEmpty ? defaultThinkingLevels : discovered
    }

    private let defaultThinkingLevels = PiThinkingLevelCatalog.ordered

    private func thinkingSortIndex(_ level: String) -> Int {
        defaultThinkingLevels.firstIndex(of: level) ?? Int.max
    }

    private var overrideScope: AgentEditingTarget.OverrideScope {
        let path = viewModel.selectedProjectPath
        return (path == nil || path?.isEmpty == true) ? .global : .project
    }

    private func applyModel(_ identifier: String?, to agent: EffectiveAgentRecord) {
        guard var draft = viewModel.makeAgentDraft(for: agent, preferredOverrideScope: overrideScope) else { return }
        draft.config.model = (identifier?.isEmpty == false) ? identifier : nil
        saveAgentDraft(draft, for: agent)
    }

    private func applyThinking(_ level: String?, to agent: EffectiveAgentRecord) {
        guard var draft = viewModel.makeAgentDraft(for: agent, preferredOverrideScope: overrideScope) else { return }
        let resolved = trimmed(level)
        draft.config.thinking = (resolved == nil || resolved == "off") ? nil : resolved
        saveAgentDraft(draft, for: agent)
    }

    private func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) {
        do {
            try viewModel.saveAgentDraft(draft, for: agent)
        } catch {
            NSSound.beep()
        }
    }
}

/// 28pt circular agent avatar with a paperplane placeholder, shared by the
/// picker rows and the bound-session summary so the bind animation reads as
/// the row's avatar moving up into the header.
private struct PiAgentPickerAvatar: View {
    let imageURL: URL?

    var body: some View {
        if let imageURL, let nsImage = AgentImageLoader.image(at: imageURL) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(PiAgentSessionSubagentPickerCard.accent.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "paperplane")
                        .font(.caption)
                        .foregroundStyle(PiAgentSessionSubagentPickerCard.accent)
                }
        }
    }
}

/// Proposal-driven footer layout. Unspecified proposals choose vertical so
/// intrinsic measurement never establishes the wide footer as a minimum.
private struct PiAgentAdaptiveDelegationLayout: Layout {
    struct Cache {
        var width: CGFloat = -.infinity
        var height: CGFloat?
        var sizes: [CGSize] = []
    }

    let spacing: CGFloat
    private let descriptionWidth: CGFloat = 260
    private let pickerWidth: CGFloat = 220
    private var wideThreshold: CGFloat { descriptionWidth + spacing + pickerWidth }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func measurements(width: CGFloat, height: CGFloat?, subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if cache.width == width, cache.height == height, cache.sizes.count == 2 { return cache.sizes }
        let wide = width >= wideThreshold
        let widths = wide ? [max(0, width - spacing - pickerWidth), pickerWidth] : [width, min(pickerWidth, width)]
        cache.width = width
        cache.height = height
        cache.sizes = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: height)) }
        return cache.sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 320
        let sizes = measurements(width: width, height: proposal.height, subviews: subviews, cache: &cache)
        return width >= wideThreshold
            ? .init(width: width, height: max(sizes[0].height, sizes[1].height))
            : .init(width: min(width, max(sizes[0].width, sizes[1].width)), height: sizes[0].height + spacing + sizes[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        let wide = bounds.width >= wideThreshold
        let widths = wide ? [max(0, bounds.width - spacing - pickerWidth), pickerWidth] : [bounds.width, min(pickerWidth, bounds.width)]
        let sizes = measurements(width: bounds.width, height: proposal.height, subviews: subviews, cache: &cache)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: widths[0], height: sizes[0].height))
        let secondOrigin = wide
            ? CGPoint(x: bounds.maxX - pickerWidth, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + sizes[0].height + spacing)
        subviews[1].place(at: secondOrigin, anchor: .topLeading, proposal: .init(width: widths[1], height: sizes[1].height))
    }
}

/// Proposal-driven production row layout. A nil width is deliberately compact,
/// preventing intrinsic measurement from creating a dense split-view minimum.
private struct PiAgentAdaptiveRowLayout: Layout {
    struct Cache {
        var width: CGFloat = -.infinity
        var height: CGFloat?
        var sizes: [CGSize] = []
    }

    let isHovered: Bool
    private let spacing: CGFloat = 10
    private let wideIdentityWidth: CGFloat = 340
    private let wideControlsWidth: CGFloat = 528
    private let mediumIdentityWidth: CGFloat = 220
    private let mediumControlsWidth: CGFloat = 338
    private let chatWidth: CGFloat = 76
    // Preserve the July-era wide columns where they genuinely fit, but keep an
    // inline medium arrangement before falling back to a stacked row.
    private var wideThreshold: CGFloat { wideIdentityWidth + spacing + wideControlsWidth + 60 }
    private var mediumThreshold: CGFloat { mediumIdentityWidth + spacing + mediumControlsWidth + spacing + chatWidth }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func widths(for width: CGFloat) -> [CGFloat] {
        if width >= wideThreshold { return [wideIdentityWidth, wideControlsWidth, chatWidth] }
        if width >= mediumThreshold { return [mediumIdentityWidth, mediumControlsWidth, chatWidth] }
        return [width, min(wideControlsWidth, width), chatWidth]
    }

    private func measurements(width: CGFloat, height: CGFloat?, subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if cache.width == width, cache.height == height, cache.sizes.count == 3 { return cache.sizes }
        let widths = widths(for: width)
        cache.width = width
        cache.height = height
        cache.sizes = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: height)) }
        return cache.sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? 260
        let sizes = measurements(width: width, height: proposal.height, subviews: subviews, cache: &cache)
        return width >= mediumThreshold
            ? .init(width: width, height: max(sizes[0].height, sizes[1].height, sizes[2].height))
            : .init(width: min(width, max(sizes[0].width, sizes[1].width)), height: sizes[0].height + 8 + sizes[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        let inline = bounds.width >= mediumThreshold
        let widths = widths(for: bounds.width)
        let sizes = measurements(width: bounds.width, height: proposal.height, subviews: subviews, cache: &cache)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: widths[0], height: sizes[0].height))
        if inline {
            subviews[1].place(at: .init(x: bounds.minX + widths[0] + spacing, y: bounds.minY), anchor: .topLeading, proposal: .init(width: widths[1], height: sizes[1].height))
            subviews[2].place(at: .init(x: bounds.maxX - chatWidth, y: bounds.minY), anchor: .topLeading, proposal: .init(width: chatWidth, height: sizes[2].height))
        } else {
            // Chat is an overlay in compact mode: hover never changes measured geometry.
            subviews[2].place(at: .init(x: bounds.maxX - chatWidth, y: bounds.minY), anchor: .topLeading, proposal: .init(width: chatWidth, height: sizes[2].height))
            subviews[1].place(at: .init(x: bounds.minX, y: bounds.minY + sizes[0].height + 8), anchor: .topLeading, proposal: .init(width: widths[1], height: sizes[1].height))
        }
    }
}

private struct PiAgentAdaptiveControlsLayout: Layout {
    struct Cache {
        var width: CGFloat = -.infinity
        var height: CGFloat?
        var sizes: [CGSize] = []
    }

    private let wideModelWidth: CGFloat = 300
    private let wideThinkingWidth: CGFloat = 220
    private let mediumModelWidth: CGFloat = 180
    private let mediumThinkingWidth: CGFloat = 150
    private let spacing: CGFloat = 8
    private var wideThreshold: CGFloat { wideModelWidth + spacing + wideThinkingWidth }
    private var mediumThreshold: CGFloat { mediumModelWidth + spacing + mediumThinkingWidth }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func widths(for width: CGFloat) -> [CGFloat] {
        if width >= wideThreshold { return [wideModelWidth, wideThinkingWidth] }
        if width >= mediumThreshold { return [mediumModelWidth, mediumThinkingWidth] }
        return [min(220, width), min(180, width)]
    }

    private func measurements(width: CGFloat, height: CGFloat?, subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if cache.width == width, cache.height == height, cache.sizes.count == 2 { return cache.sizes }
        let widths = widths(for: width)
        cache.width = width
        cache.height = height
        cache.sizes = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: height)) }
        return cache.sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 220
        let sizes = measurements(width: width, height: proposal.height, subviews: subviews, cache: &cache)
        if width >= mediumThreshold {
            return .init(width: widths(for: width).reduce(0, +) + spacing, height: max(sizes[0].height, sizes[1].height))
        }
        return .init(width: max(sizes[0].width, sizes[1].width), height: sizes[0].height + 6 + sizes[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        let horizontal = bounds.width >= mediumThreshold
        let widths = widths(for: bounds.width)
        let sizes = measurements(width: bounds.width, height: proposal.height, subviews: subviews, cache: &cache)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: widths[0], height: sizes[0].height))
        let secondOrigin = horizontal
            ? CGPoint(x: bounds.minX + widths[0] + spacing, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + sizes[0].height + 6)
        subviews[1].place(at: secondOrigin, anchor: .topLeading, proposal: .init(width: widths[1], height: sizes[1].height))
    }
}

/// One agent in the picker card: check + avatar + name + inline launch
/// (model + thinking) chips, with a soft hover fill. The 1:1 action is a small
/// glass capsule revealed on row hover only — same treatment as the session
/// rows' hover delete — labeled so it doesn't rely on the paperplane glyph
/// alone. Unchecked rows render desaturated and dimmed, matching the session
/// list's "seen" treatment. The row adapts from its dense inline arrangement
/// to stacked identity/action and launch-control rows as space narrows.
private struct PiAgentSubagentPickerRow: View {
    let agent: EffectiveAgentRecord
    let checked: Bool
    let avatarURL: URL?
    let launchDetail: String
    let availableModels: [AvailableModel]
    let selectedModelIdentifier: String?
    let selectedThinkingLevel: String?
    let thinkingLevels: [String]
    let onSelectModel: (String?) -> Void
    let onSelectThinking: (String?) -> Void
    let onToggle: () -> Void
    let onStartDirectChat: () -> Void

    @State private var isHovered = false

    private static let accent = PiAgentSessionSubagentPickerCard.accent

    var body: some View {
        PiAgentAdaptiveRowLayout(isHovered: isHovered) {
            identityToggle
            launchControls
            chatButton
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.contentSubtleFill)
                .opacity(isHovered ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    // Toggle area = check + avatar + name only, so the launch-control chips
    // (separate buttons) stay independently tappable.
    private var identityToggle: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(checked ? Self.accent : AppTheme.mutedText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20, height: 28)
                PiAgentPickerAvatar(imageURL: avatarURL)
                    .saturation(checked ? 1 : 0)
                Text(agent.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(checked ? 1 : 0.66)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var launchControls: some View {
        PiAgentPickerLaunchControls(
            launchDetail: launchDetail,
            availableModels: availableModels,
            selectedModelIdentifier: selectedModelIdentifier,
            selectedThinkingLevel: selectedThinkingLevel,
            thinkingLevels: thinkingLevels,
            onSelectModel: onSelectModel,
            onSelectThinking: onSelectThinking
        )
    }

    private var chatButton: some View {
        Button(action: onStartDirectChat) {
            HStack(spacing: 5) {
                Image(systemName: "paperplane")
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text("1:1 chat")
                    .font(AppTheme.Font.caption.weight(.semibold))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 1)
        }
        .appSmallSecondaryButton()
        .help("Make this a 1:1 chat with \(agent.name)")
        .accessibilityLabel("Start a 1:1 chat with \(agent.name)")
        .disabled(agent.resolved.disabled == true)
    }
}

/// Production-layout fixture for deterministic AppKit hosting tests. This keeps
/// `PiAgentSubagentPickerRow` private while letting the tests exercise its
/// actual width-fitting hierarchy rather than a duplicate approximation.
struct PiAgentSubagentPickerRowLayoutFixture: View {
    let agent: EffectiveAgentRecord
    let width: CGFloat

    var body: some View {
        PiAgentSubagentPickerRow(
            agent: agent,
            checked: true,
            avatarURL: nil,
            launchDetail: "openai/gpt-5.4-mini · thinking medium",
            availableModels: [
                AvailableModel(
                    provider: "openai",
                    model: "gpt-5.4-mini",
                    contextWindow: "128k",
                    maxOutput: "16k",
                    supportsThinking: true,
                    supportsImages: true,
                    supportedThinkingLevels: ["low", "medium", "high"]
                )
            ],
            selectedModelIdentifier: "openai/gpt-5.4-mini",
            selectedThinkingLevel: "medium",
            thinkingLevels: ["low", "medium", "high"],
            onSelectModel: { _ in },
            onSelectThinking: { _ in },
            onToggle: {},
            onStartDirectChat: {}
        )
        .frame(width: width, alignment: .leading)
    }
}

/// Inline per-agent model + thinking chips for a picker row. The model chip
/// opens a popover listing Pi's known models grouped by provider (plus "Pi
/// default"); the thinking chip lists the levels supported by the current
/// model (plus "Pi default"). `launchDetail` is the combined summary shown as
/// the chips' help text. The controls stack vertically when the two chips no
/// longer fit side by side.
private struct PiAgentPickerLaunchControls: View {
    let launchDetail: String
    let availableModels: [AvailableModel]
    let selectedModelIdentifier: String?
    let selectedThinkingLevel: String?
    let thinkingLevels: [String]
    let onSelectModel: (String?) -> Void
    let onSelectThinking: (String?) -> Void

    @State private var isModelPresented = false
    @State private var isThinkingPresented = false

    private static let chipMinHeight: CGFloat = 22

    var body: some View {
        PiAgentAdaptiveControlsLayout {
            modelChip
            thinkingChip
        }
        .help(launchDetail)
    }

    private var modelLabel: String {
        guard let id = selectedModelIdentifier, !id.isEmpty else { return "Pi default" }
        return id
    }

    private var thinkingLabel: String {
        guard let level = selectedThinkingLevel, !level.isEmpty, level != "off" else { return "Pi default" }
        return level.capitalized
    }

    private var modelChip: some View {
        Button {
            isModelPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: Self.chipMinHeight, alignment: .leading)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isModelPresented) {
            modelPopover
        }
    }

    private var thinkingChip: some View {
        Button {
            isThinkingPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                Text("Thinking: \(thinkingLabel)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(AppTheme.Font.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(AppTheme.Font.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: Self.chipMinHeight, alignment: .leading)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(thinkingLevels.isEmpty)
        .popover(isPresented: $isThinkingPresented) {
            thinkingPopover
        }
    }

    private var modelPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPopoverHeader(title: "Model")
            Divider()
            ScrollView(showsIndicators: false) {
                let groups = groupedModels
                LazyVStack(alignment: .leading, spacing: 12) {
                    Button {
                        onSelectModel(nil)
                        isModelPresented = false
                    } label: {
                        popoverRow(label: "Pi default", isSelected: selectedModelIdentifier == nil)
                    }
                    .buttonStyle(.plain)
                    ForEach(groups, id: \.provider) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            ProviderLabel(provider: group.provider, logoSize: 13, spacing: 5)
                                .font(AppTheme.Font.caption.weight(.bold))
                                .fontWidth(.expanded)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, AppTheme.Popover.rowHInset)
                            Divider()
                                .padding(.horizontal, AppTheme.Popover.rowHInset)
                            VStack(spacing: 2) {
                                ForEach(group.models) { model in
                                    Button {
                                        onSelectModel(model.identifier)
                                        isModelPresented = false
                                    } label: {
                                        popoverRow(label: model.identifier, isSelected: model.identifier == selectedModelIdentifier)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Popover.listInset)
                .padding(.vertical, AppTheme.Popover.listInset)
            }
            .frame(maxHeight: AppTheme.Popover.listMaxHeight)
        }
        .frame(width: AppTheme.Popover.standardWidth)
        .foregroundStyle(.primary)
    }

    private var thinkingPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPopoverHeader(title: "Thinking")
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    Button {
                        onSelectThinking(nil)
                        isThinkingPresented = false
                    } label: {
                        popoverRow(label: "Pi default", isSelected: isThinkingDefault)
                    }
                    .buttonStyle(.plain)
                    ForEach(thinkingOptions, id: \.self) { level in
                        Button {
                            onSelectThinking(level)
                            isThinkingPresented = false
                        } label: {
                            popoverRow(label: level.capitalized, isSelected: level == selectedThinkingLevel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppTheme.Popover.listInset)
                .padding(.vertical, AppTheme.Popover.listInset)
            }
            .frame(maxHeight: AppTheme.Popover.listMaxHeight)
        }
        .frame(width: AppTheme.Popover.compactWidth)
        .foregroundStyle(.primary)
    }

    private func popoverRow(label: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : "circle")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                .frame(width: 14)
            Text(label)
                .font(AppTheme.Font.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Popover.rowHInset)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var isThinkingDefault: Bool {
        guard let level = selectedThinkingLevel else { return true }
        return level.isEmpty || level == "off"
    }

    private var thinkingOptions: [String] {
        thinkingLevels.filter { !$0.isEmpty && $0 != "off" }
    }

    private var groupedModels: [(provider: String, models: [AvailableModel])] {
        Dictionary(grouping: availableModels, by: \.provider)
            .map { provider, models in
                (provider: provider, models: models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending })
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }
}

/// Non-interactive summary chip shown on Add Agents sheet rows: the agent's
/// resolved model/thinking detail (or "Pi default"). FIXED capsule height so
/// every sheet row stays one line at an identical height.
private struct PiAgentPickerModelChip: View {
    let label: String

    private static let chipHeight: CGFloat = 18

    var body: some View {
        Text(label)
            .font(AppTheme.Font.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.mutedText)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .frame(height: Self.chipHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.contentSubtleFill)
            )
    }
}

/// Trailing list row of the picker: "Add agents…" styled like the agent rows
/// (plus circle in the avatar column, hover fill) so it reads as part of the
/// list, with "Reset to default" tucked into the same row's trailing edge.
private struct PiAgentPickerAddRow: View {
    let isEnabled: Bool
    let showsReset: Bool
    let onAdd: () -> Void
    let onReset: () -> Void

    @State private var isHovered = false

    private static let accent = PiAgentSessionSubagentPickerCard.accent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onAdd) {
                HStack(alignment: .center, spacing: 10) {
                    // Empty check column so the plus circle lines up under the
                    // agent avatars.
                    Color.clear
                        .frame(width: 20, height: 28)
                    Circle()
                        .fill(Self.accent.opacity(0.14))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Self.accent)
                        }
                    Text("Add agents…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Self.accent)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)

            if showsReset {
                Button("Reset to default", action: onReset)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.contentSubtleFill)
                .opacity(isHovered && isEnabled ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Multi-select picker presented as a sheet when the user taps "Add agents…"
/// in `PiAgentSessionSubagentPickerCard`. Matches the `MarkdownFileEditorSheet`
/// chrome (compact `.headline` title, 18pt header, divider rails, 16pt footer
/// with prominent confirm button). Reflects the current explicit selection
/// (preselecting already-added agents on appear) and applies by preserving
/// visible default-row selections and unioning the chosen extras.
struct PiAgentAddAgentsSheet: View {
    let addable: [EffectiveAgentRecord]
    let currentSelection: Set<String>
    let launchDetail: (EffectiveAgentRecord) -> String
    let onApply: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var query: String = ""
    @FocusState private var isSearchFocused: Bool

    private static let accent = PiAgentSessionSubagentPickerCard.accent
    /// Fixed row height so every row is identical — no shifting when the model
    /// chip content changes.
    private static let rowHeight: CGFloat = 34

    private var filtered: [EffectiveAgentRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return addable }
        return addable.filter { agent in
            agent.name.lowercased().contains(q) || launchDetail(agent).lowercased().contains(q)
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
        .onAppear {
            // Preselect the agents already in the explicit selection that are
            // part of the addable set, so added agents show as checked and can
            // be removed by unchecking.
            let addableNames = Set(addable.map(\.name))
            selected = currentSelection.intersection(addableNames)
            isSearchFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add agents")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text("Pick agents to include in this session. Existing default-row selections are preserved; chosen agents are added when you click Update.")
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
        let filteredAgents = filtered
        if addable.isEmpty {
            emptyState("Every available agent is already in the session.")
        } else if filteredAgents.isEmpty {
            emptyState("No agents match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(filteredAgents, id: \.name) { agent in
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
            // Single fixed-height line: check + name + model chip. No
            // description caption, so rows never wrap or jump.
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isChecked ? Self.accent : AppTheme.mutedText)
                Text(agent.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                PiAgentPickerModelChip(label: launchDetail(agent))
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
            .padding(.horizontal, 10)
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
            Button(selected.isEmpty ? "Update" : "Update \(selected.count)") {
                onApply(selected)
                dismiss()
            }
            .appPrimaryButton()
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
