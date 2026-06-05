import AppKit
import ImagePlayground
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct AgentsFilterPopover: View {
    var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Filter agents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Spacer()
                if viewModel.selectedAgentFilter != .all {
                    Button("Clear") { viewModel.selectedAgentFilter = .all }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.bottom, 2)

            ForEach(AgentFilter.allCases) { filter in
                filterRow(filter)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private func filterRow(_ filter: AgentFilter) -> some View {
        let isOn = viewModel.selectedAgentFilter == filter
        return Button {
            viewModel.selectedAgentFilter = filter
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AppTheme.brandAccent : AppTheme.mutedText)
                Text(filter.rawValue)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AgentsScreen: View {
    private static let layoutLog = Logger(subsystem: "streetcoding.agent-deck", category: "ResourceLayout")
    var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var agentBeingEdited: AgentEditPresentation?

    var body: some View {
        HStack(spacing: 0) {
            SplitView {
                if viewModel.hasCompletedInitialRefresh {
                    AgentLibraryPane(
                        viewModel: viewModel,
                        searchText: $searchText,
                        onEditAgent: { agent in
                            agentBeingEdited = AgentEditPresentation(agent: agent, initialTab: .config)
                        }
                    )
                    .appDebugLayout("Agents.libraryPane", logger: Self.layoutLog)
                } else {
                    AppLoadingView("Loading agents…")
                        .appDebugLayout("Agents.libraryLoading", logger: Self.layoutLog)
                }
            } detail: {
                if !viewModel.hasCompletedInitialRefresh {
                    AppLoadingView("Loading agent details…")
                        .appDebugLayout("Agents.detailLoading", logger: Self.layoutLog)
                } else if let agent = viewModel.selectedAgent {
                    AgentDetailView(
                        agent: agent,
                        sourceColor: agentSourceColor(
                            for: agent,
                            libraryBackedNames: Set(viewModel.snapshot.libraryAgents.map(\.name)),
                            isInProjectContext: viewModel.selectedProjectPath != nil
                        ),
                        globalDisableBuiltinsActive: viewModel.userDisableBuiltins,
                        onSetBuiltinDisabled: { scope, isDisabled in
                            viewModel.setBuiltinDisabled(isDisabled, for: agent, scope: scope)
                        },
                        onSetBuiltinGloballyEnabled: { isEnabled in
                            viewModel.setBuiltinGloballyEnabled(isEnabled, for: agent)
                        },
                        isBuiltinDisabledInProject: { project in
                            viewModel.builtinIsDisabled(agentName: agent.name, inProject: project.path)
                        },
                        onSetBuiltinDisabledInProject: { project, isDisabled in
                            viewModel.setBuiltinDisabled(isDisabled, for: agent, scope: .project, explicitProjectRoot: project.path)
                        },
                        managedAgent: libraryManagedAgentRecord(for: agent, libraryAgents: viewModel.snapshot.libraryAgents),
                        isAgentGlobal: { record in viewModel.agentIsEnabledGlobally(record) },
                        assignedAgentProjects: { record in viewModel.assignedProjects(for: record) },
                        skillVisibilityIssues: { viewModel.explicitSkillVisibilityIssues(for: $0) },
                        setAgentGlobal: { record, enabled in
                            if enabled { try viewModel.enableAgentGlobally(record) } else { try viewModel.disableAgentGlobally(record) }
                        },
                        setAgentForProject: { record, project, enabled in
                            try viewModel.setAgent(record, enabled: enabled, for: project)
                        },
                        moveAgentToLibrary: { record in
                            try viewModel.moveAgentToLibrary(record)
                        },
                        canRenameAgent: { viewModel.canRenameAgent($0) },
                        renameAgent: { agent, name in try viewModel.renameAgent(agent, to: name) },
                        deleteAgent: { try viewModel.deleteAgent($0) },
                        onEditAgent: { tab in
                            agentBeingEdited = AgentEditPresentation(agent: agent, initialTab: tab)
                        },
                        projects: viewModel.enabledProjects,
                        imageStore: viewModel.agentImageStore,
                        autoGenerateAvatarPrompts: viewModel.appSettings.autoGenerateAgentAvatarPrompts,
                        generateAvatarPrompt: { try await viewModel.generateAgentAvatarPrompt(for: $0) }
                    )
                    .appDebugLayout("Agents.detail selected=\(agent.name)", logger: Self.layoutLog)
                } else {
                    ContentUnavailableView("No Agent Selected", systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .appDebugLayout("Agents.detailEmpty", logger: Self.layoutLog)
                }
            }
            .appDebugLayout("Agents.hsplit", logger: Self.layoutLog)
        }
        .appDebugLayout("Agents.rootHStack", logger: Self.layoutLog)
        .onAppear {
            #if DEBUG
            Self.layoutLog.debug("Agents.state event=appear selected=\(viewModel.selectedAgent?.name ?? "nil", privacy: .public) project=\(viewModel.selectedDiscoveredProject?.name ?? "nil", privacy: .public)")
            #endif
        }
        .sheet(item: $agentBeingEdited) { presentation in
            let agent = presentation.agent
            // `makeAgentDraft` rebuilds the draft from scope snapshots — three
            // separate calls would re-derive the same target each time, and
            // each `availableX` call below rescans broad state (effective
            // agents, skills, settings). Compute the target once.
            let availableTarget = viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)
            AgentEditSheet(
                agent: agent,
                availableModels: viewModel.enabledAvailableModels,
                availableTools: viewModel.availableToolNames(for: availableTarget),
                availableSkills: viewModel.availableSkillNames(for: availableTarget),
                availableExtensions: viewModel.availableExtensionNames(for: availableTarget),
                initialTab: presentation.initialTab,
                makeDraft: { scope in viewModel.makeAgentDraft(for: agent, preferredOverrideScope: scope ?? .global) },
                onSave: { draft in try viewModel.saveAgentDraft(draft, for: agent) }
            )
        }
    }
}

/// Single source of truth for an agent's source-kind tint. The library pane
/// and the detail pane both call this so the avatar circle matches across panes.
fileprivate func agentSourceColor(
    for agent: EffectiveAgentRecord,
    libraryBackedNames: Set<String>,
    isInProjectContext: Bool
) -> Color {
    if agent.id.hasPrefix("catalog::") { return .secondary }
    if agent.resolved.disabled == true { return AppTheme.roleError }
    if agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil { return AppTheme.sourceBuiltin }
    if agent.resolutionKind == .library || libraryBackedNames.contains(agent.name) { return AppTheme.sourceLibrary }
    if isInProjectContext { return AppTheme.sourceProject }
    return AppTheme.brandAccent
}

private enum AgentAvatarImageGenerationError: LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Image Playground did not return an image."
        }
    }
}

struct AgentAvatarView: View {
    let imageURL: URL?
    let fallbackSystemImage: String
    let color: Color
    var size: CGFloat = 32
    // When true, fills the available height of the enclosing HStack as a square circle.
    var flexible: Bool = false

    var body: some View {
        if flexible {
            avatarContent
                .aspectRatio(1.0, contentMode: .fit)
                .frame(maxHeight: .infinity)
        } else {
            avatarContent
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private var avatarContent: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.10))
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 1)

            if let nsImage = AgentImageLoader.image(at: imageURL) {
                Image(nsImage: nsImage)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(flexible ? .title3.weight(.medium) : fallbackFont)
                    .foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }

    private var fallbackFont: Font {
        switch size {
        case ..<30:
            return .caption.weight(.medium)
        case ..<44:
            return .title3.weight(.medium)
        default:
            return .title.weight(.medium)
        }
    }
}


private struct AgentAvatarHoverActionButton: View {
    let imageURL: URL?
    let hasCustomImage: Bool
    let isGenerating: Bool
    let color: Color
    let onRemove: () -> Void
    let onEditImage: () -> Void

    @State private var isHovering = false

    private var size: CGFloat { 52 }

    var body: some View {
        ZStack {
            AgentAvatarView(
                imageURL: imageURL,
                fallbackSystemImage: "paperplane",
                color: color,
                size: size
            )

            if isGenerating {
                Circle().fill(Color.black.opacity(0.42))
                AppSpinner()
                    .controlSize(.small)
                    .tint(.white)
            } else if isHovering {
                Circle().fill(Color.black.opacity(0.42))
                Image(systemName: hasCustomImage ? "trash" : "photo.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            guard !isGenerating else { return }
            if hasCustomImage {
                onRemove()
            } else {
                onEditImage()
            }
        }
        .help(helpText)
        .disabled(isGenerating)
    }

    private var helpText: String {
        if isGenerating { return "Generating avatar…" }
        return hasCustomImage ? "Remove avatar image" : "Edit avatar image"
    }
}

private struct EditAgentAvatarSheet: View {
    let agentName: String
    let isGenerating: Bool
    let canGenerate: Bool
    let onGenerate: () -> Void
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Avatar")
                    .font(.title2.bold())
                    .fontWidth(.expanded)
                Text(agentName)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }

            Text("Choose how to set the avatar for this agent.")
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                avatarOptionButton(
                    title: "Generate with Image Playground",
                    subtitle: canGenerate
                        ? "Create an illustrated avatar based on the agent's description."
                        : "Image Playground is not available on this Mac.",
                    systemImage: "wand.and.stars",
                    isPrimary: true,
                    isDisabled: !canGenerate || isGenerating,
                    action: onGenerate
                )

                avatarOptionButton(
                    title: "Import from File…",
                    subtitle: "Pick an image file from your computer to use as the avatar.",
                    systemImage: "photo.on.rectangle",
                    isPrimary: false,
                    isDisabled: isGenerating,
                    action: onImport
                )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .appSecondaryButton()
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    @ViewBuilder
    private func avatarOptionButton(title: String, subtitle: String, systemImage: String, isPrimary: Bool, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(isPrimary ? AppTheme.brandAccent : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.contentSubtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.hairlineStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

private struct AgentWarningPopover: View {
    let agent: EffectiveAgentRecord
    let warnings: [DiagnosticWarning]
    let skillIssues: [AgentSkillVisibilityIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent warnings", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            if !skillIssues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Explicit skills not visible in assigned projects")
                        .font(.subheadline.weight(.semibold))
                    Text("The agent stores skill names only. Assign the missing skills to these projects or enable them globally.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(skillIssues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.project.name)
                                .font(.caption.weight(.semibold))
                            Text(issue.missingSkills.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if !warnings.isEmpty {
                if !skillIssues.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other scanner warnings")
                        .font(.subheadline.weight(.semibold))
                    ForEach(warnings) { warning in
                        Text("• \(warning.message)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

private struct AgentLibraryPane: View {
    var viewModel: AppViewModel
    @Binding var searchText: String
    let onEditAgent: (EffectiveAgentRecord) -> Void
    @State private var warningPopoverAgentID: String?
    @State private var hoveredAgentID: String?
    @State private var pendingDeleteAgentID: EffectiveAgentRecord.ID?
    // Local mirror for the `List` selection — the macOS `List` writes its
    // selection back during the SwiftUI update pass, so it binds to this
    // `@State` rather than straight onto the view model. `viewModel`'s
    // selection is synced from `.onChange`, which runs after the pass.
    // Mirrors the pattern in `SkillsScreen`.
    @State private var selectedAgentID: EffectiveAgentRecord.ID?
    // Cached sectioning + per-row tint metadata. The full layout build runs
    // five filter passes plus a mark loop over the agent list — recomputing
    // it on every body eval (every selection click) was the dominant cost.
    // Recompute only when an actual input changes (revision, search, project).
    @State private var cachedLayout: (
        sections: [AppListSection<EffectiveAgentRecord>],
        inactiveByID: [String: Bool],
        warningIDs: Set<String>
    ) = ([], [:], [])

    private var imageStore: AgentImageStore { viewModel.agentImageStore }

    var body: some View {
        let layout = cachedLayout
        let isRefreshing = viewModel.isRefreshingProjects
        // Perf: the warning lookup ran twice per row per render (once in
        // `rowTint`, once inside `agentListRow`). Cache it once at the layout
        // level and read it both places via O(1) Set lookup.
        let warningIDs = layout.warningIDs
        AppList(
            sections: layout.sections,
            selection: .single($selectedAgentID),
            rowTint: { warningIDs.contains($0.id) ? Color.orange.opacity(0.12) : nil }
        ) { agent in
            agentListRow(agent, inactive: layout.inactiveByID[agent.id] ?? false)
        }
        // While a refresh is in flight (e.g. after a project switch) the list
        // still shows the previous snapshot; if the user clicks a row now the
        // selection jumps to a different agent the moment the new snapshot
        // publishes. Gate interaction until the scan completes — matches the
        // spinner shown in the top-right overlay.
        .opacity(isRefreshing ? 0.5 : 1)
        .allowsHitTesting(!isRefreshing)
        .disabled(isRefreshing)
        .overlay(alignment: .topTrailing) {
            if isRefreshing {
                AppSpinner()
                    .controlSize(.small)
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isRefreshing)
        .onAppear {
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.selectedAgentID) { _, _ in scheduleSelectionSynchronization() }
        .onChange(of: viewModel.displayAgentsRevision) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: searchText) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.selectedDiscoveredProject) { _, _ in
            cachedLayout = recomputeLayout()
        }
        .onChange(of: viewModel.selectedAgentFilter) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: selectedAgentID) { _, id in
            guard viewModel.selectedAgentID != id else { return }
            viewModel.selectedAgentID = id
        }
        .alert("Delete Agent?", isPresented: Binding(
            get: { pendingDeleteAgentRecord != nil },
            set: { if !$0 { pendingDeleteAgentID = nil } }
        ), presenting: pendingDeleteAgentRecord) { record in
            Button("Move to Trash", role: .destructive) {
                deleteAgent(record)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteAgentID = nil
            }
        } message: { record in
            Text("Move \"\(record.name)\" to the Trash and remove its Default and project assignments?")
        }
    }

    /// Resolved breakdown of `filteredAgents` into the sections the agents
    /// list renders, plus per-agent lookups for inactive state and "has
    /// warnings" (precomputed once so both `AppList.rowTint` and
    /// `agentListRow` read it via O(1) Set/Dictionary access instead of
    /// re-running `viewModel.warnings(for:)` per row per render).
    ///
    /// Called only from `.onAppear` / `.onChange` paths via `cachedLayout`
    /// — never per body eval.
    private func recomputeLayout() -> (
        sections: [AppListSection<EffectiveAgentRecord>],
        inactiveByID: [String: Bool],
        warningIDs: Set<String>
    ) {
        var sections: [AppListSection<EffectiveAgentRecord>] = []
        var inactiveByID: [String: Bool] = [:]
        var warningIDs: Set<String> = []

        func mark(_ items: [EffectiveAgentRecord], inactive: Bool) {
            for item in items {
                inactiveByID[item.id] = inactive
                if !viewModel.warnings(for: item).isEmpty
                    || !viewModel.explicitSkillVisibilityIssues(for: item).isEmpty {
                    warningIDs.insert(item.id)
                }
            }
        }

        if viewModel.selectedDiscoveredProject != nil {
            let active = activeCustomAgents
            mark(active, inactive: false)
            sections.append(AppListSection(
                id: "active",
                title: "Active",
                items: active,
                emptyMessage: "No custom agents are active for this project."
            ))

            if !catalogAgents.isEmpty {
                mark(catalogAgents, inactive: true)
                sections.append(AppListSection(
                    id: "catalog",
                    title: "Catalog Agents",
                    info: "Catalog agents are discovered files that are not assigned to this project yet.",
                    items: catalogAgents
                ))
            }

            if !libraryAgents.isEmpty {
                mark(libraryAgents, inactive: true)
                sections.append(AppListSection(
                    id: "library",
                    title: "Library Agents",
                    info: "Library agents are centrally stored and only become active when assigned to this project or enabled globally.",
                    items: libraryAgents
                ))
            }
        } else {
            let global = globalCustomAgents
            for item in global {
                inactiveByID[item.id] = isCatalogOnly(item)
                if !viewModel.warnings(for: item).isEmpty
                    || !viewModel.explicitSkillVisibilityIssues(for: item).isEmpty {
                    warningIDs.insert(item.id)
                }
            }
            sections.append(AppListSection(
                id: "global",
                title: "Global Agents",
                info: "Select a project to see exactly which custom agents are active there and to manage project assignment.",
                items: global,
                emptyMessage: "No global custom agents."
            ))

            if !catalogAgents.isEmpty {
                mark(catalogAgents, inactive: true)
                sections.append(AppListSection(
                    id: "catalog",
                    title: "Catalog Agents",
                    items: catalogAgents
                ))
            }

            if !libraryAgents.isEmpty {
                mark(libraryAgents, inactive: false)
                sections.append(AppListSection(
                    id: "library",
                    title: "Library Agents",
                    items: libraryAgents
                ))
            }
        }

        mark(builtinAgents, inactive: false)
        sections.append(AppListSection(
            id: "builtin",
            title: "Builtin Agents",
            info: "Builtins are bundled with \(AppBrand.displayName) and customized through settings overrides or replacement files.",
            items: builtinAgents,
            emptyMessage: "No builtin agents discovered."
        ))

        return (sections, inactiveByID, warningIDs)
    }

    private var activeCustomAgents: [EffectiveAgentRecord] {
        filteredAgents.filter { agent in
            !isCatalogOnly(agent) && agent.resolutionKind != .library && !(agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil)
        }
    }

    private var globalCustomAgents: [EffectiveAgentRecord] {
        filteredAgents.filter { !isCatalogOnly($0) && $0.globalCustom != nil && $0.globalCustom?.source.kind != .library }
    }

    private var catalogAgents: [EffectiveAgentRecord] {
        filteredAgents.filter(isCatalogOnly)
    }

    private func isCatalogOnly(_ agent: EffectiveAgentRecord) -> Bool {
        agent.id.hasPrefix("catalog::")
    }

    private var libraryAgents: [EffectiveAgentRecord] {
        let candidates = filteredAgents.filter { agent in
            if viewModel.selectedDiscoveredProject == nil, agent.winningRecord?.source.kind == .library { return true }
            return agent.resolutionKind == .library
        }
        return preferredAgentsByName(candidates) { records in
            records.first { $0.resolutionKind == .library }
            ?? records.first { $0.projectCustom == nil }
            ?? records.first
        }
    }

    private func preferredAgentsByName(_ agents: [EffectiveAgentRecord], prefer: ([EffectiveAgentRecord]) -> EffectiveAgentRecord?) -> [EffectiveAgentRecord] {
        Dictionary(grouping: agents, by: \.name).values.compactMap(prefer)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var libraryBackedActiveAgentNames: Set<String> {
        Set(viewModel.snapshot.libraryAgents.map(\.name))
    }

    private var builtinAgents: [EffectiveAgentRecord] {
        filteredAgents.filter { $0.builtin != nil && $0.globalCustom == nil && $0.projectCustom == nil }
    }

    private var filteredAgents: [EffectiveAgentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.filteredAgents }
        return viewModel.filteredAgents.filter { agent in
            [agent.name, agent.resolved.description, agent.resolutionKind.rawValue, agent.sourcePath ?? "", agent.resolved.systemPrompt]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private var agentSelection: Binding<EffectiveAgentRecord.ID?> {
        Binding(get: { selectedAgentID }, set: { selectedAgentID = $0 })
    }

    /// Pulls `viewModel.selectedAgentID` into the local mirror off the current
    /// update pass. Mirrors `SkillsScreen.scheduleSelectionSynchronization()`.
    private func scheduleSelectionSynchronization() {
        Task { @MainActor in
            await Task.yield()
            synchronizeSelectionFromViewModel()
        }
    }

    private func synchronizeSelectionFromViewModel() {
        guard let vmID = viewModel.selectedAgentID else {
            ensureSelection()
            return
        }
        if filteredAgents.contains(where: { $0.id == vmID }) {
            selectedAgentID = vmID
            return
        }
        // Selected agent hidden by search/filter or rebuilt under a new id —
        // keep the user's selection by name when possible.
        if let name = viewModel.selectedAgent?.name,
           let preferred = filteredAgents.first(where: { $0.name == name }) {
            selectedAgentID = preferred.id
            return
        }
        ensureSelection()
    }

    private func ensureSelection() {
        guard selectedAgentID == nil
            || !filteredAgents.contains(where: { $0.id == selectedAgentID }) else { return }
        selectedAgentID = filteredAgents.first?.id
    }

    private func agentListRow(_ agent: EffectiveAgentRecord, inactive: Bool) -> some View {
        // Read the per-agent caches directly (O(1) each, built once per refresh
        // in AppViewModel.rebuildWarningCaches). The previous `agentMetadataByID`
        // computed property rebuilt the whole dictionary on every row, making
        // the list O(N²) to render.
        let warnings = viewModel.warnings(for: agent)
        let skillIssues = viewModel.explicitSkillVisibilityIssues(for: agent)
        let hasWarningDetails = !warnings.isEmpty || !skillIssues.isEmpty
        let warningColor: Color = .orange
        let isMuted = inactive || agent.resolved.disabled == true || agentIsUnusedLibraryAgent(agent)
        let filePath = agent.sourcePath ?? agent.projectOverride?.settingsPath ?? agent.userOverride?.settingsPath

        return HStack(alignment: .center, spacing: 10) {
            AgentAvatarView(
                imageURL: imageStore.imageURL(for: agent.name),
                fallbackSystemImage: icon(for: agent),
                color: color(for: agent),
                size: 40
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.name)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .foregroundStyle(.primary)
                        .strikethrough(agent.resolved.disabled == true, color: AppTheme.mutedText)
                        .lineLimit(1)

                    if hasWarningDetails {
                        Button {
                            warningPopoverAgentID = agent.id
                        } label: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(warningColor)
                                .imageScale(.small)
                                .accessibilityLabel("Agent warnings")
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(
                            get: { warningPopoverAgentID == agent.id },
                            set: { if !$0 { warningPopoverAgentID = nil } }
                        )) {
                            AgentWarningPopover(agent: agent, warnings: warnings, skillIssues: skillIssues)
                        }
                    }
                }

                Text(agent.resolved.description.isEmpty ? "No description" : agent.resolved.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button {
                onEditAgent(agent)
            } label: {
                Text("Edit")
                    .font(.caption.weight(.semibold))
            }
            .appSmallSecondaryButton()
            .opacity(hoveredAgentID == agent.id ? 1 : 0)
            .help("Edit agent")
            .animation(.easeInOut(duration: 0.15), value: hoveredAgentID == agent.id)
        }
        .onHover { hovering in
            hoveredAgentID = hovering ? agent.id : nil
        }
        .padding(.vertical, 6)
        .opacity(isMuted ? 0.62 : 1)
        .saturation(isMuted ? 0.25 : 1)
        .contextMenu {
            Button {
                openFile(filePath)
            } label: {
                Label("Open Raw File", systemImage: "doc.text")
            }
            .disabled(filePath == nil)

            Button {
                revealInFinder(filePath)
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(filePath == nil)

            Divider()

            if agent.resolved.disabled == true {
                Button {
                    do {
                        try viewModel.setAgentDisabled(false, for: agent)
                    } catch {
                        NSSound.beep()
                    }
                } label: {
                    Label("Enable Agent", systemImage: "checkmark.circle")
                }
            } else {
                Button(role: .destructive) {
                    do {
                        try viewModel.setAgentDisabled(true, for: agent)
                    } catch {
                        NSSound.beep()
                    }
                } label: {
                    Label("Disable Agent", systemImage: "nosign")
                }
            }

            Divider()

            Button(role: .destructive) {
                pendingDeleteAgentID = agent.id
            } label: {
                Label("Delete Agent", systemImage: "trash")
            }
            .disabled(!canDeleteAgent(agent))
        }
    }

    /// Whether the agent has any warnings or skill-visibility issues. Both
    /// lookups are O(1) reads of caches built once per refresh.
    private func agentHasWarningDetails(_ agent: EffectiveAgentRecord) -> Bool {
        !viewModel.warnings(for: agent).isEmpty
            || !viewModel.explicitSkillVisibilityIssues(for: agent).isEmpty
    }

    private func capabilityStrip(for agent: EffectiveAgentRecord) -> some View {
        HStack(spacing: 6) {
            if agent.resolutionKind == .globalReplacement || agent.resolutionKind == .projectReplacement {
                capabilityPill("Replacement", symbol: "arrow.triangle.2.circlepath", color: .blue)
            }
            if !agent.resolved.skills.isEmpty {
                capabilityPill("Skills", symbol: "sparkles", color: .green)
            }
            if !((agent.resolved.tools ?? []).isEmpty) || !((agent.resolved.mcpDirectTools ?? []).isEmpty) {
                capabilityPill("Tools", symbol: "wrench.and.screwdriver", color: .blue)
            }
            if agent.resolved.disabled == true {
                capabilityPill("Disabled", symbol: "nosign", color: .red)
            }
            if agentHasWarningDetails(agent) {
                capabilityPill("Warning", symbol: "exclamationmark.triangle", color: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capabilityPill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func statusLabel(_ agent: EffectiveAgentRecord) -> String {
        if agent.id.hasPrefix("catalog::") { return "Catalog" }
        if agent.resolved.disabled == true { return "Disabled" }
        if libraryBackedActiveAgentNames.contains(agent.name) {
            if viewModel.selectedProjectPath != nil, agent.resolutionKind != .library { return "Active" }
            return "Library"
        }
        if viewModel.selectedProjectPath != nil, agent.resolutionKind != .library { return "Active" }
        return agent.resolutionKind.rawValue
    }

    private func icon(for agent: EffectiveAgentRecord) -> String {
        "paperplane"
    }

    private func color(for agent: EffectiveAgentRecord) -> Color {
        agentSourceColor(
            for: agent,
            libraryBackedNames: libraryBackedActiveAgentNames,
            isInProjectContext: viewModel.selectedProjectPath != nil
        )
    }

    private func agentIsUnusedLibraryAgent(_ agent: EffectiveAgentRecord) -> Bool {
        guard agent.resolutionKind == .library,
              let record = viewModel.snapshot.libraryAgents.first(where: { $0.name == agent.name }) else {
            return false
        }
        return !viewModel.agentIsEnabledGlobally(record) && viewModel.assignedProjects(for: record).isEmpty
    }

    private func openFile(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private var pendingDeleteAgentRecord: AgentRecord? {
        guard let pendingDeleteAgentID,
              let agent = filteredAgents.first(where: { $0.id == pendingDeleteAgentID }) else {
            return nil
        }
        return agent.winningRecord
    }

    private func canDeleteAgent(_ agent: EffectiveAgentRecord) -> Bool {
        guard let record = agent.winningRecord else { return false }
        return viewModel.canDeleteAgent(record)
    }

    private func deleteAgent(_ record: AgentRecord) {
        do {
            try viewModel.deleteAgent(record)
            pendingDeleteAgentID = nil
        } catch {
            pendingDeleteAgentID = nil
            NSSound.beep()
        }
    }
}

private func libraryManagedAgentRecord(for agent: EffectiveAgentRecord, libraryAgents: [AgentRecord]) -> AgentRecord? {
    guard let winningRecord = agent.winningRecord else { return nil }
    guard winningRecord.source.kind != .builtin else { return nil }
    // Same-name custom agents that replace builtins are intentional overrides.
    // Keep them in their chosen scope instead of offering reusable library assignment.
    if agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil) { return nil }
    return libraryAgents.first { $0.name == agent.name } ?? winningRecord
}

private func rowIndicator(_ symbol: String, color: Color) -> some View {
    Image(systemName: symbol)
        .font(.caption)
        .foregroundStyle(color)
}

// MARK: - AgentDetailView (read-only)

private struct AgentDetailView: View {
    let agent: EffectiveAgentRecord
    let sourceColor: Color
    let globalDisableBuiltinsActive: Bool
    let onSetBuiltinDisabled: (AgentEditingTarget.OverrideScope, Bool) -> Void
    let onSetBuiltinGloballyEnabled: (Bool) -> Void
    let isBuiltinDisabledInProject: (DiscoveredProject) -> Bool
    let onSetBuiltinDisabledInProject: (DiscoveredProject, Bool) -> Void
    let managedAgent: AgentRecord?
    let isAgentGlobal: (AgentRecord) -> Bool
    let assignedAgentProjects: (AgentRecord) -> [DiscoveredProject]
    let skillVisibilityIssues: (EffectiveAgentRecord) -> [AgentSkillVisibilityIssue]
    let setAgentGlobal: (AgentRecord, Bool) throws -> Void
    let setAgentForProject: (AgentRecord, DiscoveredProject, Bool) throws -> Void
    let moveAgentToLibrary: (AgentRecord) throws -> Void
    let canRenameAgent: (EffectiveAgentRecord) -> Bool
    let renameAgent: (EffectiveAgentRecord, String) throws -> Void
    let deleteAgent: (AgentRecord) throws -> Void
    let onEditAgent: (AgentEditTab) -> Void
    let projects: [DiscoveredProject]
    @ObservedObject var imageStore: AgentImageStore
    let autoGenerateAvatarPrompts: Bool
    let generateAvatarPrompt: (EffectiveAgentRecord) async throws -> String
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var isGeneratingAvatarPrompt = false
    @State private var isAvatarImporterPresented = false
    @State private var isEditImageSheetPresented = false
    @State private var avatarMessage: String?
    @State private var isRenamingAgentName = false
    @State private var draftAgentName = ""
    @State private var isAgentNameHovered = false
    @FocusState private var isAgentNameFocused: Bool
    @State private var renameErrorMessage: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var deleteErrorMessage: String?

    var body: some View {
        AppPage(agent.name, subtitle: agent.resolved.description.isEmpty ? nil : agent.resolved.description, lazy: true) {
            summaryTab
            promptTab
            toolsTab
            skillsTab
            builtinDisableSection
            deleteSection
        }
        .alert(
            "Delete \(agent.name)?",
            isPresented: $isDeleteConfirmationPresented,
            presenting: deletableAgentRecord
        ) { record in
            Button("Move to Trash", role: .destructive) {
                do {
                    deleteErrorMessage = nil
                    try deleteAgent(record)
                } catch {
                    deleteErrorMessage = error.localizedDescription
                    NSSound.beep()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This moves the agent file to the Trash and removes its global and project assignments.")
        }
        .fileImporter(isPresented: $isAvatarImporterPresented, allowedContentTypes: [.image]) { result in
            handleAvatarImport(result)
        }
        .sheet(isPresented: $isEditImageSheetPresented) {
            EditAgentAvatarSheet(
                agentName: agent.name,
                isGenerating: isGeneratingAvatarPrompt,
                canGenerate: supportsImagePlayground,
                onGenerate: {
                    isEditImageSheetPresented = false
                    prepareImagePlaygroundPromptAndPresent()
                },
                onImport: {
                    isEditImageSheetPresented = false
                    isAvatarImporterPresented = true
                }
            )
        }
        .onChange(of: agent.id) { _, _ in
            cancelAgentRename()
            renameErrorMessage = nil
            avatarMessage = nil
            deleteErrorMessage = nil
        }
    }

    // MARK: Avatar

    private var agentAvatarEditor: some View {
        HStack(alignment: .center, spacing: 14) {
            agentAvatarHoverButton

            VStack(alignment: .leading, spacing: 5) {
                agentNameEditableView
                if !agent.resolved.description.isEmpty {
                    Text(agent.resolved.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let renameErrorMessage {
                    Text(renameErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let avatarMessage {
                    Text(avatarMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var agentAvatarHoverButton: some View {
        let hasCustomImage = imageStore.imageURL(for: agent.name) != nil
        AgentAvatarHoverActionButton(
            imageURL: imageStore.imageURL(for: agent.name),
            hasCustomImage: hasCustomImage,
            isGenerating: isGeneratingAvatarPrompt,
            color: sourceColor,
            onRemove: removeCustomAvatar,
            onEditImage: { isEditImageSheetPresented = true }
        )
    }

    @ViewBuilder
    private var agentNameEditableView: some View {
        if isRenamingAgentName {
            TextField("Agent name", text: $draftAgentName)
                .textFieldStyle(.plain)
                .font(.body.weight(.semibold))
                .fontWidth(.expanded)
                .focused($isAgentNameFocused)
                .onSubmit { commitAgentRename() }
                .onExitCommand { cancelAgentRename() }
                .onAppear {
                    draftAgentName = agent.name
                    isAgentNameFocused = true
                }
        } else {
            HStack(alignment: .center, spacing: 6) {
                Text(agent.name)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                    .lineLimit(1)
                if canRenameAgent(agent) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .opacity(isAgentNameHovered ? 0.85 : 0)
                }
            }
            .contentShape(Rectangle())
            .onHover { isAgentNameHovered = $0 }
            .onTapGesture { beginAgentRename() }
            .help(canRenameAgent(agent) ? "Rename agent" : "")
        }
    }

    private func beginAgentRename() {
        guard canRenameAgent(agent), !isRenamingAgentName else { return }
        renameErrorMessage = nil
        draftAgentName = agent.name
        isRenamingAgentName = true
        isAgentNameFocused = true
    }

    private func cancelAgentRename() {
        isRenamingAgentName = false
        isAgentNameFocused = false
        draftAgentName = agent.name
        renameErrorMessage = nil
    }

    private func commitAgentRename() {
        let trimmed = draftAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelAgentRename()
            return
        }
        guard trimmed != agent.name else {
            cancelAgentRename()
            return
        }
        do {
            try renameAgent(agent, trimmed)
            isRenamingAgentName = false
            isAgentNameFocused = false
            renameErrorMessage = nil
        } catch {
            renameErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func removeCustomAvatar() {
        do {
            try imageStore.removeImage(for: agent.name)
            avatarMessage = nil
        } catch {
            avatarMessage = error.localizedDescription
        }
    }

    private func prepareImagePlaygroundPromptAndPresent() {
        guard supportsImagePlayground else { return }
        avatarMessage = nil
        isGeneratingAvatarPrompt = true
        Task { @MainActor in
            defer { isGeneratingAvatarPrompt = false }
            do {
                let prompt = shouldAutoGenerateAvatarPrompt ? try await generatedAvatarPrompt() : fallbackAvatarPrompt
                do {
                    try await generateAvatarImage(with: prompt)
                } catch {
                    try await generateAvatarImage(with: safeFallbackAvatarPrompt)
                }
                avatarMessage = nil
            } catch {
                avatarMessage = "Could not generate an avatar: \(error.localizedDescription)"
            }
        }
    }

    private var shouldAutoGenerateAvatarPrompt: Bool {
        autoGenerateAvatarPrompts
    }

    private func generatedAvatarPrompt() async throws -> String {
        try await generateAvatarPrompt(agent)
    }

    private var fallbackAvatarPrompt: String {
        let description = agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = description.isEmpty ? "software development assistant" : description
        return "\(focus), abstract software development symbol, code brackets and connected nodes, colorful rounded app icon illustration, simple gradient background, high contrast"
    }

    private var safeFallbackAvatarPrompt: String {
        "abstract software development symbol, code brackets, connected nodes, colorful rounded app icon illustration, simple gradient background, high contrast"
    }

    private func generateAvatarImage(with prompt: String) async throws {
        let creator = try await ImageCreator()
        let concepts: [ImagePlaygroundConcept] = [.text(prompt)]

        if #available(macOS 26.4, *) {
            var options = ImagePlaygroundOptions()
            options.personalization = .disabled
            for try await image in creator.images(for: concepts, style: .illustration, options: options, limit: 1) {
                try imageStore.assignGeneratedImage(image.cgImage, to: agent.name)
                return
            }
        } else {
            for try await image in creator.images(for: concepts, style: .illustration, limit: 1) {
                try imageStore.assignGeneratedImage(image.cgImage, to: agent.name)
                return
            }
        }
        throw AgentAvatarImageGenerationError.emptyResponse
    }

    private func handleAvatarImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing { url.stopAccessingSecurityScopedResource() }
            }
            try imageStore.assignGeneratedImage(from: url, to: agent.name)
            avatarMessage = nil
        } catch {
            avatarMessage = "Could not import avatar: \(error.localizedDescription)"
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private func sectionEditButton(_ tab: AgentEditTab) -> some View {
        Button {
            onEditAgent(tab)
        } label: {
            Label("Edit", systemImage: "square.and.pencil")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
        }
        .appSmallSecondaryButton()
        .help("Edit \(tab.rawValue.lowercased())")
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(trailing: { sectionEditButton(.config) }) {
                VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                    agentAvatarEditor

                    VStack(alignment: .leading, spacing: 10) {
                        let rows = configuredFieldRows
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            readOnlyFieldRow(row.0, value: row.1)
                        }
                        if let path = agent.sourcePath {
                            readOnlyFieldRow("File", value: path, isLast: true)
                        } else if rows.isEmpty {
                            Text("Using Pi defaults")
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
            }

            agentVisibilityManagementCards
        }
    }

    private var configuredFieldRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let model = agent.resolved.model { rows.append(("Model", model)) }
        if !agent.resolved.fallbackModels.isEmpty { rows.append(("Fallback Models", agent.resolved.fallbackModels.joined(separator: ", "))) }
        if let thinking = agent.resolved.thinking, thinking != "off" { rows.append(("Thinking", thinking)) }
        if let mode = agent.resolved.systemPromptMode { rows.append(("Prompt Mode", mode)) }
        if let whenToUse = agent.resolved.whenToUse, !whenToUse.isEmpty { rows.append(("When to Use", whenToUse)) }
        if agent.resolved.disabled == true { rows.append(("Disabled", "Yes")) }
        if let output = agent.resolved.output { rows.append(("Output", output)) }
        if let outcome = agent.resolved.defaultExpectedOutcome { rows.append(("Default Outcome", outcome.displayName)) }
        if let reads = agent.resolved.defaultReads, !reads.isEmpty { rows.append(("Default Reads", reads.joined(separator: ", "))) }
        if let progress = agent.resolved.defaultProgress { rows.append(("Default Progress", display(progress))) }
        if let interactive = agent.resolved.interactive { rows.append(("Interactive", display(interactive))) }
        if let depth = agent.resolved.maxSubagentDepth { rows.append(("Max Subagent Depth", String(depth))) }
        return rows
    }

    private var promptTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            LazyMarkdownCard(
                title: resolvedPromptDiffers ? "Resolved Prompt" : "Prompt",
                source: agent.resolved.systemPrompt,
                trailing: { sectionEditButton(.prompt) }
            )
            if resolvedPromptDiffers {
                LazyMarkdownCard(
                    title: "Raw Source Prompt",
                    source: agent.winningRecord?.promptBody ?? ""
                )
            }
        }
    }

    private var toolsTab: some View {
        let tools = (agent.resolved.tools ?? []) + (agent.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" }
        let extensions = agent.resolved.extensions ?? []
        return VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Tools", info: Self.toolAccessInfo, trailing: { sectionEditButton(.tools) }) {
                if tools.isEmpty {
                    Text("Uses Pi's default built-in tools.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    iconList(tools, systemImage: "wrench.and.screwdriver", tint: .blue)
                }
            }

            if !extensions.isEmpty {
                AppCard(title: "Extensions") {
                    iconList(extensions, systemImage: "puzzlepiece.extension", tint: .blue)
                }
            }
        }
    }

    private func iconList(_ items: [String], systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(item)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skills", info: Self.skillsInfo, trailing: { sectionEditButton(.skills) }) {
                VStack(alignment: .leading, spacing: 16) {
                    let issues = skillVisibilityIssues(agent)
                    if !issues.isEmpty {
                        skillVisibilityWarningBlock(issues)
                    }
                    if agent.resolved.skills.isEmpty {
                        Text("No explicit skills")
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        iconList(agent.resolved.skills, systemImage: "sparkles", tint: .green)
                    }
                }
            }
        }
    }

    private static let toolAccessInfo = """
    If tools is omitted, the agent gets Pi's normal default built-in tools.

    If tools is set, it acts like an allowlist for regular tool names.

    Extensions are offered from installed package references Pi already knows about.
    """

    private static let skillsInfo = """
    Assigned skills are attached to this agent through Pi's native --skill support.

    Agents do not inherit parent, default, or project skills; assign required skills explicitly.

    If this agent has a tool allowlist and assigned skills, include the read tool so Pi can load the skill files.
    """

    private var deletableAgentRecord: AgentRecord? {
        guard let record = agent.projectCustom ?? agent.globalCustom ?? managedAgent else { return nil }
        switch record.source.kind {
        case .builtin, .package:
            return nil
        case .global, .project, .legacyProject, .override, .library:
            return record
        }
    }

    private var isPureBuiltin: Bool {
        agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
    }

    private var isDisabledGlobally: Bool {
        agent.userOverride?.disabledOverride == true || globalDisableBuiltinsActive
    }

    @ViewBuilder
    private var builtinDisableSection: some View {
        if isPureBuiltin {
            AppCard(title: "Disable Agent") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(isDisabledGlobally
                         ? "Re-enable this built-in agent so Pi loads it again across every project that hasn't disabled it explicitly."
                         : "Turn this built-in agent off everywhere so Pi does not load it. Per-project overrides still apply.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isDisabledGlobally {
                        Button("Enable Agent") {
                            onSetBuiltinDisabled(.global, false)
                        }
                        .appSecondaryButton()
                    } else {
                        Button("Disable Agent", role: .destructive) {
                            onSetBuiltinDisabled(.global, true)
                        }
                        .appDestructiveButton()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var builtinProjectAssignmentCard: some View {
        AppCard(title: "Project Assignment") {
            VStack(alignment: .leading, spacing: 10) {
                let isGloballyEnabled = !isDisabledGlobally

                Text("Enable this built-in agent for every project at once, or pick specific projects below. Toggling All Projects clears any per-project overrides so the global setting wins.")
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(alignment: .leading, spacing: 0) {
                    AllProjectsAssignmentRow(
                        isOn: Binding(
                            get: { isGloballyEnabled },
                            set: { enabled in
                                onSetBuiltinGloballyEnabled(enabled)
                            }
                        )
                    )
                    Divider()
                    ForEach(projects) { project in
                        ProjectAssignmentToggleRow(
                            project: project,
                            isOn: Binding(
                                get: { isGloballyEnabled ? true : !isBuiltinDisabledInProject(project) },
                                set: { enabled in
                                    onSetBuiltinDisabledInProject(project, !enabled)
                                }
                            )
                        )
                        .opacity(isGloballyEnabled ? 0.4 : 1)
                        .allowsHitTesting(!isGloballyEnabled)
                        if project.id != projects.last?.id { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        if deletableAgentRecord != nil {
            AppCard(title: "Delete Agent") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Move this agent's file to the Trash and remove its global and project assignments.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let deleteErrorMessage {
                        Text(deleteErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Delete Agent", role: .destructive) {
                        deleteErrorMessage = nil
                        isDeleteConfirmationPresented = true
                    }
                    .appDestructiveButton()
                }
            }
        }
    }

    private func skillVisibilityWarningBlock(_ issues: [AgentSkillVisibilityIssue]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Some assigned agent skills cannot be resolved unambiguously.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Agents carry skill names only. Make sure each assigned skill exists once in the Agent Deck skill catalog.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(issues) { issue in
                    Text("\(issue.project.name): \(issue.missingSkills.joined(separator: ", "))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var agentVisibilityManagementCards: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            if isPureBuiltin {
                builtinProjectAssignmentCard
            } else if let managedAgent {
                AppCard(title: "Project Assignment") {
                    VStack(alignment: .leading, spacing: 10) {
                        let visibilityIssues = skillVisibilityIssues(agent)
                        let visibilityIssuesByProjectID = Dictionary(uniqueKeysWithValues: visibilityIssues.map { ($0.project.id, $0) })
                        let assignedProjectIDs = Set(assignedAgentProjects(managedAgent).map(\.id))
                        let isGlobal = isAgentGlobal(managedAgent)

                        Text("Enable for every project at once, or pick specific projects below. Assignments are stored in Agent Deck and do not move agent files.")
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                        if !visibilityIssues.isEmpty {
                            skillVisibilityWarningBlock(visibilityIssues)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            AllProjectsAssignmentRow(
                                isOn: Binding(
                                    get: { isGlobal },
                                    set: { enabled in
                                        do {
                                            try setAgentGlobal(managedAgent, enabled)
                                        } catch {
                                            NSSound.beep()
                                        }
                                    }
                                )
                            )
                            Divider()
                            ForEach(projects) { project in
                                let projectIssue = visibilityIssuesByProjectID[project.id]
                                ProjectAssignmentToggleRow(
                                    project: project,
                                    isOn: Binding(
                                        get: { isGlobal ? true : assignedProjectIDs.contains(project.id) },
                                        set: { enabled in
                                            do { try setAgentForProject(managedAgent, project, enabled) } catch { NSSound.beep() }
                                        }
                                    )
                                )
                                .opacity(isGlobal ? 0.4 : 1)
                                .allowsHitTesting(!isGlobal)
                                if let projectIssue {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                        Text("Missing skills here: \(projectIssue.missingSkills.joined(separator: ", "))")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.mutedText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.leading, 60)
                                    .padding(.bottom, 8)
                                    .opacity(isGlobal ? 0.4 : 1)
                                }
                                if project.id != projects.last?.id { Divider() }
                            }
                        }

                        if managedAgent.source.kind != .library {
                            HStack {
                                Spacer()
                                Button("Move to Library") {
                                    do { try moveAgentToLibrary(managedAgent) } catch { NSSound.beep() }
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            } else if canRenameAgent(agent) {
                AppCard(title: "Custom Agent") {
                    Text("This custom agent currently replaces a builtin. Rename it (hover the name in the header above) to turn it into a separate custom agent.")
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Helpers

    private var resolvedPromptDiffers: Bool {
        (agent.winningRecord?.promptBody ?? agent.resolved.systemPrompt) != agent.resolved.systemPrompt
    }

    private var configurationFootnote: String {
        if isPlainBuiltin {
            if agent.projectOverride != nil {
                return "Editing here updates the global builtin override. A project override still takes precedence inside this project until you remove it."
            }
            return hasOverride
                ? "These changes update the global builtin override for this agent."
                : "Saving creates a global builtin override for this agent in ~/.pi/agent/settings.json."
        }
        return "These changes update the agent file directly."
    }

    private var hasOverride: Bool {
        agent.userOverride != nil || agent.projectOverride != nil
    }

    private var isPlainBuiltin: Bool {
        agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
    }

    @ViewBuilder
    private func readOnlyFieldRow(_ title: String, value: String, isLast: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(AppTheme.mutedText)
                if let help = fieldHelpText(for: title) {
                    AppHelpButton(text: help)
                }
            }
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !isLast {
            Divider()
        }
    }

    private func fieldHelpText(for title: String) -> String? {
        agentFieldHelpText(for: title)
    }

    private func display(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "Yes" : "No"
    }

    private func openFile(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Shared field help text

private func agentFieldHelpText(for title: String) -> String? {
    switch title {
    case "Description":
        return "Short summary of what this agent does. Shown in the agent list and under the agent name in the detail header. Distinct from \"When to Use\", which is the routing hint a parent session reads to decide whether to delegate."
    case "When to Use":
        return "Concise routing guidance for parent sessions deciding whether to delegate to this agent. Prefer one short sentence."
    case "Model":
        return "Default model for this agent. Builtin overrides can change this. Custom agents save it in frontmatter."
    case "Fallback Models":
        return "Ordered backup models Pi can use when the primary model is unavailable or unsuitable."
    case "Thinking":
        return "Reasoning effort hint for the selected model. Available options are derived from Pi's installed model metadata."
    case "Prompt Mode":
        return "Replace makes this a focused specialist prompt. Append keeps more of Pi's normal base behavior and adds this agent's instructions on top."
    case "Inherit Project Context", "Project Context":
        return "When enabled, the agent keeps Pi's project instruction context, including files like AGENTS.md or CLAUDE.md."
    case "Skills":
        return "Skills assigned to this agent are passed to Pi with explicit --skill paths. The agent needs the read tool to load full skill files."
    case "Disabled", "Availability":
        return "Disabled agents are hidden from Deck agent discovery and normal launches."
    case "Output", "Output File":
        return "Default output file for single-agent runs. Most useful in managed workflows such as parallel runs."
    case "Default Reads":
        return "Files Pi should read before execution when this agent is launched through managed workflows."
    case "Default Progress", "Progress":
        return "When enabled, managed workflows maintain progress.md for this agent."
    case "Interactive", "Interaction":
        return "Compatibility frontmatter field for interactive behavior. Parsed and preserved."
    case "Max Subagent Depth", "Max Depth":
        return "Limits how many more nested Deck agent launches this agent can create below itself."
    case "Extensions":
        return "Extension loading mode. Omitted means normal extension loading, empty means none, and explicit values act as an allowlist."
    case "Tool Access":
        return "If tools are omitted, the agent keeps Pi's normal tool behavior. If tools are explicitly set, they become an allowlist."
    case "Extension Mode":
        return "If extensions are omitted, Pi uses normal extension loading. An explicit list acts as an allowlist. An empty list means no discovered extensions."
    case "Add Tool":
        return "Choose from built-in Pi tools visible in this agent's scope."
    case "Selected":
        return "Current explicit values for this field. Remove any item with the x button."
    case "Add Extension":
        return "Choose from installed Pi package references already visible to \(AppBrand.displayName)."
    case "Add Skill":
        return "Choose from skills in Agent Deck's skill catalog."
    case "Skill Catalog":
        return "All catalog skills are available for explicit assignment; duplicate names must be resolved before launch."
    default:
        return nil
    }
}

// MARK: - AgentEditSheet

fileprivate enum AgentEditTab: String, CaseIterable, Identifiable {
    case config = "Configuration"
    case prompt = "Prompt"
    case tools = "Tools"
    case skills = "Skills"
    var id: String { rawValue }
}

fileprivate struct AgentEditPresentation: Identifiable {
    let agent: EffectiveAgentRecord
    let initialTab: AgentEditTab
    var id: String { "\(agent.id)#\(initialTab.rawValue)" }
}

private struct AgentEditSheet: View {
    let agent: EffectiveAgentRecord
    let availableModels: [AvailableModel]
    let availableTools: [String]
    let availableSkills: [String]
    let availableExtensions: [String]
    let initialTab: AgentEditTab
    let makeDraft: (AgentEditingTarget.OverrideScope?) -> AgentEditorDraft?
    let onSave: (AgentEditorDraft) throws -> Void

    @State private var draft: AgentEditorDraft?
    @State private var baselineDraft: AgentEditorDraft?
    @State private var selectedTab: AgentEditTab
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    typealias EditTab = AgentEditTab

    init(
        agent: EffectiveAgentRecord,
        availableModels: [AvailableModel],
        availableTools: [String],
        availableSkills: [String],
        availableExtensions: [String],
        initialTab: AgentEditTab = .config,
        makeDraft: @escaping (AgentEditingTarget.OverrideScope?) -> AgentEditorDraft?,
        onSave: @escaping (AgentEditorDraft) throws -> Void
    ) {
        self.agent = agent
        self.availableModels = availableModels
        self.availableTools = availableTools
        self.availableSkills = availableSkills
        self.availableExtensions = availableExtensions
        self.initialTab = initialTab
        self.makeDraft = makeDraft
        self.onSave = onSave
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Edit Agent")
                        .font(.headline.weight(.semibold))
                    Text(agent.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                .help("Close")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .fontWidth(.expanded)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selectedTab == tab ? AppTheme.selectionFill : AppTheme.contentSubtleFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }

            Divider()

            // Content
            if let _ = draft {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                        switch selectedTab {
                        case .config: editConfigTab
                        case .prompt: editPromptTab
                        case .tools: editToolsTab
                        case .skills: editSkillsTab
                        }
                    }
                    .padding(24)
                }
            } else {
                AppSpinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Footer
            Divider()

            HStack(spacing: 12) {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Discard") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    performConfirmedSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(AppTheme.brandAccent)
                .disabled(!hasChanges || draft == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 700, height: 640)
        .task {
            loadDraft()
        }
    }

    // MARK: Edit Tabs

    private var editConfigTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Identity") {
                editSection {
                    configRow("Description") {
                        TextEditor(text: descriptionBinding)
                            .frame(minHeight: 64, maxHeight: 120)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                    }
                }
            }

            AppCard(title: "Routing") {
                editSection {
                    configRow("When to Use") {
                        TextEditor(text: optionalStringBinding(for: \.whenToUse))
                            .frame(minHeight: 64, maxHeight: 120)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                    }
                }
            }

            AppCard(title: "Model & Reasoning") {
                editSection {
                    configRow("Model") {
                        Picker("Model", selection: modelSelectionBinding) {
                            Text("Use Pi Default Model").tag("")
                            ForEach(availableModels, id: \.identifier) { model in
                                Text(model.identifier).tag(model.identifier)
                            }
                        }
                        .appMenuPicker()
                        .frame(maxWidth: 360, alignment: .leading)
                        Text(modelSummary)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    configRow("Thinking") {
                        Picker("Thinking", selection: thinkingSelectionBinding) {
                            Text("Pi Default").tag("off")
                            ForEach(availableThinkingLevels.filter { $0 != "off" }, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        .appMenuPicker()
                        .frame(maxWidth: 180, alignment: .leading)
                        Text("Only values supported by the selected model are shown.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    configRow("Fallback Models") {
                        VStack(alignment: .leading, spacing: 10) {
                            Menu("Add Fallback Model") {
                                if !availableModels.isEmpty {
                                    Button("Use None") {
                                        draft?.config.fallbackModels = []
                                    }
                                    Divider()
                                }
                                ForEach(availableModels, id: \.identifier) { model in
                                    Button(model.identifier) {
                                        addFallbackModel(model.identifier)
                                    }
                                }
                            }
                            tokenList(draft?.config.fallbackModels ?? [], remove: removeFallbackModel)
                        }
                    }
                }
            }

            AppCard(title: "Prompt") {
                editSection {
                    configRow("Prompt Mode") {
                        Picker("Prompt Mode", selection: promptModeBinding) {
                            Text("Replace").tag("replace")
                            Text("Append").tag("append")
                        }
                        .appSegmentedPicker()
                        .frame(maxWidth: 260, alignment: .leading)
                        Text(agentFieldHelpText(for: "Prompt Mode") ?? "")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
            }

            AppCard(title: "Behavior") {
                editSection {
                    configRow("Availability") {
                        Toggle("Disabled", isOn: optionalBoolBinding(for: \.disabled))
                            .appSwitch()
                        Text(agentFieldHelpText(for: "Disabled") ?? "")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    if case .custom = draft?.target {
                        configRow("Default Outcome") {
                            Picker("Default Outcome", selection: defaultExpectedOutcomeBinding()) {
                                Text("Unspecified").tag(PiSubagentExpectedOutcome?.none)
                                ForEach(PiSubagentExpectedOutcome.allCases) { outcome in
                                    Text(outcome.displayName).tag(Optional(outcome))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220, alignment: .leading)
                        }

                        configRow("Progress") {
                            Toggle("Default progress", isOn: optionalBoolBinding(for: \.defaultProgress))
                                .appSwitch()
                            Text(agentFieldHelpText(for: "Default Progress") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Interaction") {
                            Toggle("Interactive", isOn: optionalBoolBinding(for: \.interactive))
                                .appSwitch()
                            Text(agentFieldHelpText(for: "Interactive") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
            }

            if case .custom = draft?.target {
                AppCard(title: "Files") {
                    editSection {
                        configRow("Output") {
                            AppTextField(text: optionalStringBinding(for: \.output), placeholder: "Output path")
                                .frame(maxWidth: 360, alignment: .leading)
                            Text(agentFieldHelpText(for: "Output") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Default Reads") {
                            AppTextField(text: stringListBinding(for: \.defaultReads), placeholder: "fileA, fileB")
                                .frame(maxWidth: 360, alignment: .leading)
                            Text(agentFieldHelpText(for: "Default Reads") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Max Depth") {
                            Stepper(value: optionalIntBinding(for: \.maxSubagentDepth), in: 0...10) {
                                Text(draft?.config.maxSubagentDepth.map(String.init) ?? "0")
                            }
                            .appBrandTint()
                            .frame(maxWidth: 180, alignment: .leading)
                            Text(agentFieldHelpText(for: "Max Subagent Depth") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
            }
        }
    }

    private var editPromptTab: some View {
        AppCard(title: "System Prompt") {
            VStack(alignment: .leading, spacing: 12) {
                Text("The system prompt is the main instruction body for this agent. Replace mode uses this as the agent's primary prompt, while append mode adds it on top of Pi's normal base behavior.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: Binding(
                    get: { draft?.config.systemPrompt ?? "" },
                    set: { draft?.config.systemPrompt = $0 }
                ))
                .frame(minHeight: 400)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var editToolsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Tool Access") {
                VStack(alignment: .leading, spacing: 18) {
                    editSection {
                        configRow("Reset") {
                            HStack(spacing: 10) {
                                Button("Reset Tool Access") {
                                    resetToolAccess()
                                }
                                .controlSize(.small)
                                Text(selectedToolValues.isEmpty ? "Currently using Pi default tool access." : "Using an explicit tool allowlist.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }

                        configRow("Add Tool") {
                            Menu("Choose Tool") {
                                ForEach(availableTools, id: \.self) { tool in
                                    Button(tool) {
                                        addTool(tool)
                                    }
                                }
                            }
                            .lineLimit(1)
                            .fontWidth(.condensed)
                        }

                        configRow("Selected") {
                            tokenList(selectedToolValues, remove: removeTool)
                        }
                    }
                }
            }

            if case .custom = draft?.target {
                AppCard(title: "Extensions") {
                    VStack(alignment: .leading, spacing: 18) {
                        editSection {
                            configRow("Extension Mode") {
                                HStack(spacing: 10) {
                                    Button("Use Default Extensions") {
                                        draft?.config.extensions = nil
                                    }
                                    .controlSize(.small)
                                    .lineLimit(1)
                                    Text((draft?.config.extensions == nil) ? "Inherits Pi's default extension behavior." : "Using an explicit extension list.")
                                        .font(.caption)
                                        .fontWidth(.condensed)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                            }

                            configRow("Add Extension") {
                                Menu("Choose Extension") {
                                    ForEach(availableExtensions, id: \.self) { name in
                                        Button(name) {
                                            addExtension(name)
                                        }
                                    }
                                }
                                .lineLimit(1)
                                .fontWidth(.condensed)
                            }

                            configRow("Selected") {
                                tokenList(draft?.config.extensions ?? [], remove: removeExtension)
                            }
                        }
                    }
                }
            }

            AppCard(title: "How Tool Access Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• If `tools` is omitted, the child gets Pi's normal default built-in tools.")
                    Text("• If `tools` is set, it acts like an allowlist for regular tool names.")
                    Text("• Extensions are offered from installed package references Pi already knows about.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var editSkillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skills") {
                VStack(alignment: .leading, spacing: 18) {
                    editSection {
                        configRow("Skill Catalog") {
                            Text("Only skills visible in this agent's scope are selectable here.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Add Skill") {
                            Menu("Choose Skill") {
                                ForEach(availableSkills, id: \.self) { skill in
                                    Button(skill) {
                                        addSkill(skill)
                                    }
                                }
                            }
                        }

                        configRow("Selected") {
                            tokenList(draft?.config.skills ?? [], remove: removeSkill)
                        }
                    }
                }
            }

            AppCard(title: "How Skills Work") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Assigned skills are attached to this agent through Pi's native `--skill` support.")
                    Text("• Agents do not inherit parent/default/project skills; assign required skills explicitly.")
                    Text("• If this agent has a tool allowlist and assigned skills, include `read` so Pi can load the skill files.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Layout Helpers

    @ViewBuilder
    private func editSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.contentSubtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func configRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 18) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.mutedText)
                if let help = agentFieldHelpText(for: title) {
                    AppHelpButton(text: help)
                }
            }
            .frame(width: 170, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func tokenList(_ values: [String], remove: @escaping (String) -> Void) -> some View {
        if values.isEmpty {
            Text("None")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 8) {
                        Text(value)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            remove(value)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    // MARK: Draft State

    private var hasChanges: Bool {
        guard let draft, let baselineDraft else { return false }
        return normalizedDraft(draft) != normalizedDraft(baselineDraft)
    }

    private func loadDraft() {
        guard let d = makeDraft(nil) else {
            draft = nil
            baselineDraft = nil
            return
        }
        draft = d
        baselineDraft = d
        saveError = nil
    }

    private func performConfirmedSave() {
        guard let draft else { return }
        do {
            let normalized = normalizedDraft(draft)
            try onSave(normalized)
            baselineDraft = normalized
            self.draft = normalized
            saveError = nil
            dismiss()
        } catch {
            NSSound.beep()
            saveError = error.localizedDescription
        }
    }

    private func normalizedDraft(_ d: AgentEditorDraft) -> AgentEditorDraft {
        var copy = d
        copy.config.whenToUse = copy.config.whenToUse?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        copy.config.fallbackModels = normalizedList(copy.config.fallbackModels) ?? []
        copy.config.tools = normalizedList(copy.config.tools)
        copy.config.mcpDirectTools = normalizedList(copy.config.mcpDirectTools)
        copy.config.skills = normalizedList(copy.config.skills) ?? []
        copy.config.extensions = copy.config.extensions == nil ? nil : (normalizedList(copy.config.extensions) ?? [])
        copy.config.defaultReads = copy.config.defaultReads == nil ? nil : (normalizedList(copy.config.defaultReads) ?? [])
        if let output = copy.config.output?.trimmingCharacters(in: .whitespacesAndNewlines), output.isEmpty {
            copy.config.output = nil
        }
        if copy.config.thinking == "off" {
            copy.config.thinking = nil
        }
        return copy
    }

    private func normalizedList(_ value: [String]?) -> [String]? {
        guard let value else { return nil }
        let items = value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private func displayBool(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "Yes" : "No"
    }

    // MARK: Bindings

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: { draft?.config.model ?? "" },
            set: { newValue in
                draft?.config.model = newValue.isEmpty ? nil : newValue
                clampThinkingSelection()
            }
        )
    }

    private var thinkingSelectionBinding: Binding<String> {
        Binding(
            get: {
                let current = draft?.config.thinking ?? "off"
                return availableThinkingLevels.contains(current) ? current : (availableThinkingLevels.first ?? "off")
            },
            set: { newValue in
                draft?.config.thinking = newValue == "off" ? nil : newValue
            }
        )
    }

    private var promptModeBinding: Binding<String> {
        Binding(
            get: { draft?.config.systemPromptMode ?? "replace" },
            set: { draft?.config.systemPromptMode = $0 }
        )
    }

    private var selectedModel: AvailableModel? {
        guard let identifier = draft?.config.model else { return nil }
        return availableModels.first(where: { $0.identifier == identifier })
    }

    private var modelSummary: String {
        if let model = selectedModel {
            return "\(model.identifier) · ctx \(model.contextWindow) · out \(model.maxOutput)"
        }
        return "Uses Pi's default model resolution."
    }

    private var availableThinkingLevels: [String] {
        selectedModel?.supportedThinkingLevels ?? []
    }

    private var selectedToolValues: [String] {
        ((draft?.config.tools ?? []) + (draft?.config.mcpDirectTools ?? []).map { "mcp:\($0)" })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func optionalStringBinding(for keyPath: WritableKeyPath<AgentConfig, String?>) -> Binding<String> {
        Binding(
            get: { draft?.config[keyPath: keyPath] ?? "" },
            set: { draft?.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { draft?.config.description ?? "" },
            set: { draft?.config.description = $0 }
        )
    }

    private func stringListBinding(for keyPath: WritableKeyPath<AgentConfig, [String]?>) -> Binding<String> {
        Binding(
            get: { (draft?.config[keyPath: keyPath] ?? []).joined(separator: ", ") },
            set: { newValue in
                let values = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                draft?.config[keyPath: keyPath] = values.isEmpty ? nil : values
            }
        )
    }

    private func optionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draft?.config[keyPath: keyPath] ?? false },
            set: { draft?.config[keyPath: keyPath] = $0 }
        )
    }

    private func optionalIntBinding(for keyPath: WritableKeyPath<AgentConfig, Int?>) -> Binding<Int> {
        Binding(
            get: { draft?.config[keyPath: keyPath] ?? 0 },
            set: { draft?.config[keyPath: keyPath] = $0 }
        )
    }

    private func defaultExpectedOutcomeBinding() -> Binding<PiSubagentExpectedOutcome?> {
        Binding(
            get: { draft?.config.defaultExpectedOutcome },
            set: { draft?.config.defaultExpectedOutcome = $0 }
        )
    }

    // MARK: Mutation Helpers

    private func clampThinkingSelection() {
        let current = draft?.config.thinking ?? "off"
        guard !availableThinkingLevels.contains(current) else { return }
        let fallback = availableThinkingLevels.first ?? "off"
        draft?.config.thinking = fallback == "off" ? nil : fallback
    }

    private func addFallbackModel(_ model: String) {
        guard draft?.config.fallbackModels.contains(model) == false else { return }
        draft?.config.fallbackModels.append(model)
    }

    private func removeFallbackModel(_ model: String) {
        draft?.config.fallbackModels.removeAll { $0 == model }
    }

    private func resetToolAccess() {
        if case .builtinOverride = draft?.target {
            draft?.config.tools = agent.builtin?.parsed.tools
            draft?.config.mcpDirectTools = agent.builtin?.parsed.mcpDirectTools
        } else {
            draft?.config.tools = nil
            draft?.config.mcpDirectTools = nil
        }
    }

    private func addTool(_ tool: String) {
        var values = selectedToolValues
        guard !values.contains(tool) else { return }
        values.append(tool)
        applyToolValues(values)
    }

    private func removeTool(_ tool: String) {
        applyToolValues(selectedToolValues.filter { $0 != tool })
    }

    private func applyToolValues(_ values: [String]) {
        var tools: [String] = []
        var mcpTools: [String] = []
        for value in values {
            if value.hasPrefix("mcp:") {
                let name = String(value.dropFirst(4))
                if !name.isEmpty { mcpTools.append(name) }
            } else {
                tools.append(value)
            }
        }
        draft?.config.tools = tools.isEmpty ? nil : tools
        draft?.config.mcpDirectTools = mcpTools.isEmpty ? nil : mcpTools
    }

    private func addExtension(_ name: String) {
        var values = draft?.config.extensions ?? []
        guard !values.contains(name) else { return }
        values.append(name)
        draft?.config.extensions = values
    }

    private func removeExtension(_ name: String) {
        draft?.config.extensions?.removeAll { $0 == name }
    }

    private func addSkill(_ skill: String) {
        guard draft?.config.skills.contains(skill) == false else { return }
        draft?.config.skills.append(skill)
    }

    private func removeSkill(_ skill: String) {
        draft?.config.skills.removeAll { $0 == skill }
    }
}

// MARK: - SubagentsProjectRecapPanel

private struct SubagentsProjectRecapPanel: View {
    let project: DiscoveredProject
    let snapshot: ScanSnapshot
    let libraryAgents: [AgentRecord]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32, assetName: project.projectType.assetName)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deck Agents Recap").font(.headline).fontWidth(.expanded)
                    Text(project.name).font(.caption).foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close recap")
            }
            .padding(16)
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These are the Deck agents \(AppBrand.displayName) discovers for this project, after global/project precedence and builtin overrides.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    agentRecapSection("Effective Agents", agents: snapshot.effectiveAgents, color: AppTheme.assistantAccent)
                    if !libraryAgents.isEmpty { libraryAgentSection }
                }
                .padding(16)
            }
        }
        .background(AppTheme.contentSubtleFill)
    }

    private func agentRecapSection(_ title: String, agents: [EffectiveAgentRecord], color: Color) -> some View {
        recapShell(title, count: agents.count, color: color) {
            ForEach(agents) { agent in
                recapRow(icon: agent.resolved.disabled == true ? "nosign" : "sparkles.rectangle.stack", color: agent.resolved.disabled == true ? .red : color, title: agent.name, subtitle: agent.resolutionKind.rawValue)
            }
        }
    }

    private var libraryAgentSection: some View {
        recapShell("Library Agents", count: libraryAgents.count, color: .secondary) {
            ForEach(libraryAgents) { agent in recapRow(icon: "books.vertical", color: .secondary, title: agent.name, subtitle: "Stored, not loaded until assigned") }
        }
    }

    private func recapShell<Content: View>(_ title: String, count: Int, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline).fontWidth(.expanded); Spacer() }
            if count == 0 { Text("None").font(.caption).foregroundStyle(AppTheme.mutedText) } else { VStack(alignment: .leading, spacing: 8) { content() } }
        }
    }

    private func recapRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SubagentsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Deck agent library")
                .font(.headline)
                .fontWidth(.expanded)
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Agent Library", "Central storage in ~/.pi/agent/agent-library/agents. Pi does not load these until assigned.")
                infoRow("Default", "Default agents are passed to every parent Pi Agent session.")
                infoRow("Project", "Project assignments are passed only to parent sessions for that project.")
                infoRow("Builtins", "\(AppBrand.displayName) bundled builtins stay read-only. Customize them with settings overrides or replacement files.")
            }
        }
        .padding(16)
        .frame(width: 390, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).fontWidth(.expanded)
            Text(description).font(.caption).foregroundStyle(AppTheme.mutedText).fixedSize(horizontal: false, vertical: true)
        }
    }
}
