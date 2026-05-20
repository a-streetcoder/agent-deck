import AppKit
import ImagePlayground
import SwiftUI
import UniformTypeIdentifiers

struct AgentsFilterPopover: View {
    @ObservedObject var viewModel: AppViewModel
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
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var agentBeingEdited: EffectiveAgentRecord?

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                if viewModel.hasCompletedInitialRefresh {
                    AgentLibraryPane(
                        viewModel: viewModel,
                        searchText: $searchText,
                        onEditAgent: { agent in agentBeingEdited = agent }
                    )
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
                } else {
                    AppLoadingView("Loading agents…")
                        .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
                }

                if !viewModel.hasCompletedInitialRefresh {
                    AppLoadingView("Loading agent details…")
                } else if let agent = viewModel.selectedAgent {
                    AgentDetailView(
                        agent: agent,
                        stateBadge: viewModel.builtinStateBadge(for: agent),
                        onSetBuiltinDisabled: { scope, isDisabled in
                            viewModel.setBuiltinDisabled(isDisabled, for: agent, scope: scope)
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
                        projects: viewModel.enabledProjects,
                        imageStore: viewModel.agentImageStore,
                        autoGenerateAvatarPrompts: viewModel.appSettings.autoGenerateAgentAvatarPrompts,
                        generateAvatarPrompt: { try await viewModel.generateAgentAvatarPrompt(for: $0) }
                    )
                } else {
                    ContentUnavailableView("No Agent Selected", systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $agentBeingEdited) { agent in
            AgentEditSheet(
                agent: agent,
                availableModels: viewModel.enabledAvailableModels,
                availableTools: viewModel.availableToolNames(for: viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)),
                availableSkills: viewModel.availableSkillNames(for: viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)),
                availableExtensions: viewModel.availableExtensionNames(for: viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)),
                makeDraft: { scope in viewModel.makeAgentDraft(for: agent, preferredOverrideScope: scope ?? .global) },
                onSave: { draft in try viewModel.saveAgentDraft(draft, for: agent) }
            )
        }
    }
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
    var bundledImageName: String?
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

            if let nsImage = AgentImageLoader.image(at: imageURL, bundledImageName: bundledImageName) {
                Image(nsImage: nsImage)
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
    let bundledImageName: String?
    let isReadOnly: Bool
    let hasCustomImage: Bool
    let isGenerating: Bool
    let onRemove: () -> Void
    let onEditImage: () -> Void

    @State private var isHovering = false

    private var size: CGFloat { 52 }

    var body: some View {
        ZStack {
            AgentAvatarView(
                imageURL: imageURL,
                fallbackSystemImage: "rectangle.connected.to.line.below",
                color: AppTheme.assistantAccent,
                size: size,
                bundledImageName: bundledImageName
            )

            if isGenerating {
                Circle().fill(Color.black.opacity(0.42))
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if !isReadOnly && isHovering {
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
        .scaleEffect(isHovering && !isReadOnly ? 1.03 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            guard !isReadOnly else { return }
            isHovering = hovering
        }
        .onTapGesture {
            guard !isReadOnly, !isGenerating else { return }
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
        if isReadOnly { return "" }
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
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String
    let onEditAgent: (EffectiveAgentRecord) -> Void
    @State private var warningPopoverAgentID: String?
    @State private var hoveredAgentID: String?

    private var imageStore: AgentImageStore { viewModel.agentImageStore }

    var body: some View {
        List(selection: $viewModel.selectedAgentID) {
            if viewModel.selectedDiscoveredProject != nil {
                appListSection("Active") {
                    if activeCustomAgents.isEmpty {
                        nativeEmptyRow("No custom agents are active for this project.")
                    }
                    ForEach(activeCustomAgents) { agent in
                        agentListRow(agent, inactive: false)
                            .tag(agent.id)
                    }
                }

                if !catalogAgents.isEmpty {
                    appListSection("Catalog Agents", info: "Catalog agents are discovered files that are not assigned to this project yet.") {
                        ForEach(catalogAgents) { agent in
                            agentListRow(agent, inactive: true)
                                .tag(agent.id)
                        }
                    }
                }

                if !libraryAgents.isEmpty {
                    appListSection("Library Agents", info: "Library agents are centrally stored and only become active when assigned to this project or enabled globally.") {
                        ForEach(libraryAgents) { agent in
                            agentListRow(agent, inactive: true)
                                .tag(agent.id)
                        }
                    }
                }
            } else {
                appListSection("Global Agents", info: "Select a project to see exactly which custom agents are active there and to manage project assignment.") {
                    if globalCustomAgents.isEmpty {
                        nativeEmptyRow("No global custom agents.")
                    }
                    ForEach(globalCustomAgents) { agent in
                        agentListRow(agent, inactive: isCatalogOnly(agent))
                            .tag(agent.id)
                    }
                }

                if !catalogAgents.isEmpty {
                    appListSection("Catalog Agents") {
                        ForEach(catalogAgents) { agent in
                            agentListRow(agent, inactive: true)
                                .tag(agent.id)
                        }
                    }
                }

                if !libraryAgents.isEmpty {
                    appListSection("Library Agents") {
                        ForEach(libraryAgents) { agent in
                            agentListRow(agent, inactive: false)
                                .tag(agent.id)
                        }
                    }
                }
            }

            appListSection("Builtin Agents", info: "Builtins are bundled with \(AppBrand.displayName) and customized through settings overrides or replacement files.") {
                if builtinAgents.isEmpty {
                    nativeEmptyRow("No builtin agents discovered.")
                }
                ForEach(builtinAgents) { agent in
                    agentListRow(agent, inactive: false)
                        .tag(agent.id)
                }
            }
        }
        .appListStyle()
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

    private func bundledAvatarName(for agent: EffectiveAgentRecord) -> String? {
        guard agent.builtin != nil else { return nil }
        switch agent.name {
        case "coder", "explorer", "planner", "reviewer":
            return "agent-avatar-\(agent.name)"
        default:
            return nil
        }
    }

    private var filteredAgents: [EffectiveAgentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.filteredAgents }
        return viewModel.filteredAgents.filter { agent in
            [agent.name, agent.resolved.description, agent.resolutionKind.rawValue, agent.sourcePath ?? "", agent.resolved.systemPrompt]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private func agentListRow(_ agent: EffectiveAgentRecord, inactive: Bool) -> some View {
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
                size: 40,
                bundledImageName: bundledAvatarName(for: agent)
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
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .appGlassCapsule()
            }
            .buttonStyle(.plain)
            .opacity(hoveredAgentID == agent.id ? 1 : 0)
            .help("Edit agent")
            .animation(.easeInOut(duration: 0.15), value: hoveredAgentID == agent.id)
        }
        .onHover { hovering in
            hoveredAgentID = hovering ? agent.id : nil
        }
        .padding(.vertical, 6)
        .listRowBackground(hasWarningDetails ? AnyView(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(warningColor.opacity(0.12).gradient).padding(.horizontal, 8)) : nil)
        .listRowSeparator(.hidden, edges: .top)
        .opacity(isMuted ? 0.62 : 1)
        .saturation(isMuted ? 0.25 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if agent.resolved.disabled == true {
                Button {
                    do { try viewModel.setAgentDisabled(false, for: agent) }
                    catch { NSSound.beep() }
                } label: {
                    Label("Enable", systemImage: "checkmark.circle")
                }
                .tint(.green)
            } else {
                Button {
                    do { try viewModel.setAgentDisabled(true, for: agent) }
                    catch { NSSound.beep() }
                } label: {
                    Label("Disable", systemImage: "nosign")
                }
                .tint(.orange)
            }
        }
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
        }
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
            if !viewModel.warnings(for: agent).isEmpty || !viewModel.explicitSkillVisibilityIssues(for: agent).isEmpty {
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
        "rectangle.connected.to.line.below"
    }

    private func color(for agent: EffectiveAgentRecord) -> Color {
        if agent.id.hasPrefix("catalog::") { return .secondary }
        if agent.resolved.disabled == true { return .red }
        if agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil { return .orange }
        if agent.resolutionKind == .library || libraryBackedActiveAgentNames.contains(agent.name) { return .purple }
        if viewModel.selectedProjectPath != nil { return .green }
        return .blue
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
    let stateBadge: (text: String, color: Color)?
    let onSetBuiltinDisabled: (AgentEditingTarget.OverrideScope, Bool) -> Void
    let managedAgent: AgentRecord?
    let isAgentGlobal: (AgentRecord) -> Bool
    let assignedAgentProjects: (AgentRecord) -> [DiscoveredProject]
    let skillVisibilityIssues: (EffectiveAgentRecord) -> [AgentSkillVisibilityIssue]
    let setAgentGlobal: (AgentRecord, Bool) throws -> Void
    let setAgentForProject: (AgentRecord, DiscoveredProject, Bool) throws -> Void
    let moveAgentToLibrary: (AgentRecord) throws -> Void
    let canRenameAgent: (EffectiveAgentRecord) -> Bool
    let renameAgent: (EffectiveAgentRecord, String) throws -> Void
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

    var body: some View {
        AppPage(agent.name, subtitle: agent.resolved.description.isEmpty ? nil : agent.resolved.description) {
            summaryTab
            promptTab
            toolsTab
            skillsTab
            advancedTab
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
            bundledImageName: bundledAvatarName,
            isReadOnly: isReadOnlyBuiltinAvatar,
            hasCustomImage: hasCustomImage,
            isGenerating: isGeneratingAvatarPrompt,
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

    private var isReadOnlyBuiltinAvatar: Bool {
        isPlainBuiltin && bundledAvatarName != nil
    }

    private var bundledAvatarName: String? {
        guard isPlainBuiltin else { return nil }
        switch agent.name {
        case "coder", "explorer", "planner", "reviewer":
            return "agent-avatar-\(agent.name)"
        default:
            return nil
        }
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

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard {
                agentAvatarEditor

                VStack(alignment: .leading, spacing: 8) {
                    let rows = configuredFieldRows
                    if rows.isEmpty {
                        Text("Using Pi defaults")
                            .foregroundStyle(AppTheme.mutedText)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                readOnlyFieldRow(row.0, value: row.1, isLast: index == rows.count - 1)
                            }
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
            AppCard(title: resolvedPromptDiffers ? "Resolved Prompt" : "Prompt") {
                MarkdownDocumentView(source: agent.resolved.systemPrompt)
            }
            if resolvedPromptDiffers {
                AppCard(title: "Raw Source Prompt") {
                    MarkdownDocumentView(source: agent.winningRecord?.promptBody ?? "")
                }
            }
        }
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Tools & Extensions") {
                VStack(alignment: .leading, spacing: 16) {
                    let tools = (agent.resolved.tools ?? []) + (agent.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" }
                    if tools.isEmpty {
                        readOnlyFieldRow("Tool Access", value: "Pi defaults")
                    } else {
                        readOnlyFieldRow("Tools", value: tools.joined(separator: ", "))
                    }
                    if let exts = agent.resolved.extensions {
                        readOnlyFieldRow("Extensions", value: exts.isEmpty ? "—" : exts.joined(separator: ", "), isLast: true)
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

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skills") {
                VStack(alignment: .leading, spacing: 16) {
                    let issues = skillVisibilityIssues(agent)
                    if !issues.isEmpty {
                        skillVisibilityWarningBlock(issues)
                    }
                    if agent.resolved.skills.isEmpty {
                        Text("No explicit skills")
                            .foregroundStyle(AppTheme.mutedText)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(agent.resolved.skills, id: \.self) { skill in
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkles").foregroundStyle(.green)
                                    Text(skill)
                                }
                            }
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

    @ViewBuilder
    private func visibilityKeyValueRow<Trailing: View>(_ label: String, value: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(AppTheme.mutedText)
                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing()
        }
    }

    private var agentVisibilityManagementCards: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            if let managedAgent {
                AppCard(title: "Library & Visibility") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Agents are catalog entries. Choose whether this agent is assigned globally, per project, or both.")
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 10) {
                            visibilityKeyValueRow(
                                "In Library",
                                value: managedAgent.source.kind == .library ? "Yes" : "No"
                            )
                            Divider()
                            visibilityKeyValueRow(
                                "Active Globally",
                                value: isAgentGlobal(managedAgent) ? "Yes" : "No"
                            ) {
                                if isAgentGlobal(managedAgent) {
                                    Button("Disable Globally") {
                                        do { try setAgentGlobal(managedAgent, false) } catch { NSSound.beep() }
                                    }
                                    .controlSize(.small)
                                } else {
                                    Button("Enable Globally") {
                                        do { try setAgentGlobal(managedAgent, true) } catch { NSSound.beep() }
                                    }
                                    .buttonStyle(.glassProminent)
                                    .controlSize(.small)
                                }
                            }
                            Divider()
                            visibilityKeyValueRow(
                                "Assigned Projects",
                                value: assignedAgentProjects(managedAgent).map(\.name).joined(separator: ", ").nonEmpty ?? "—"
                            )
                        }

                        if managedAgent.source.kind != .library {
                            HStack(spacing: 10) {
                                Button("Move to Library") {
                                    do { try moveAgentToLibrary(managedAgent) } catch { NSSound.beep() }
                                }
                            }
                        }
                    }
                }

                AppCard(title: "Project Assignment") {
                    VStack(alignment: .leading, spacing: 10) {
                        let visibilityIssues = skillVisibilityIssues(agent)
                        let visibilityIssuesByProjectID = Dictionary(uniqueKeysWithValues: visibilityIssues.map { ($0.project.id, $0) })
                        let assignedProjectIDs = Set(assignedAgentProjects(managedAgent).map(\.id))

                        Text("Check each project that should load this agent. Project assignment is stored in Agent Deck and does not create or remove agent files.")
                            .foregroundStyle(AppTheme.mutedText)
                        if !visibilityIssues.isEmpty {
                            skillVisibilityWarningBlock(visibilityIssues)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(projects) { project in
                                let projectIssue = visibilityIssuesByProjectID[project.id]
                                ProjectAssignmentToggleRow(
                                    project: project,
                                    isOn: Binding(
                                        get: { assignedProjectIDs.contains(project.id) },
                                        set: { enabled in
                                            do { try setAgentForProject(managedAgent, project, enabled) } catch { NSSound.beep() }
                                        }
                                    )
                                )
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
                                }
                                if project.id != projects.last?.id { Divider() }
                            }
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

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Source Files") {
                AppKeyValueList(rows: [
                    ("Builtin File", agent.builtin?.filePath ?? "—"),
                    ("Global File", agent.globalCustom?.filePath ?? "—"),
                    ("Project File", agent.projectCustom?.filePath ?? "—"),
                    ("Global Override", agent.userOverride?.settingsPath ?? "—"),
                    ("Project Override", agent.projectOverride?.settingsPath ?? "—"),
                    ("Write Target", writeTargetSummary)
                ])
            }

            AppCard(title: "Resolved Frontmatter") {
                Text(prettyJSONObject(resolvedFrontmatter))
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !agent.resolved.unknownFields.isEmpty {
                AppCard(title: "Unknown Fields") {
                    Text(prettyJSONObject(agent.resolved.unknownFields.mapValues { $0 }))
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let rawFrontmatter = agent.winningRecord?.rawFrontmatter, !rawFrontmatter.isEmpty {
                AppCard(title: "Raw Frontmatter") {
                    Text(prettyJSONObject(rawFrontmatter.mapValues { $0 }))
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var writeTargetSummary: String {
        if agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil {
            return agent.userOverride?.settingsPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").path
        }
        return agent.sourcePath ?? "—"
    }

    private var extensionsSummary: String {
        guard let extensions = agent.resolved.extensions else { return "Default / inherited" }
        return extensions.isEmpty ? "None" : extensions.joined(separator: ", ")
    }

    private var resolvedFrontmatter: [String: Any] {
        var values: [String: Any] = [
            "name": agent.resolved.name,
            "description": agent.resolved.description,
            "systemPromptMode": agent.resolved.systemPromptMode ?? "",
            "disabled": agent.resolved.disabled as Any,
            "skills": agent.resolved.skills
        ]
        if let whenToUse = agent.resolved.whenToUse { values["whenToUse"] = whenToUse }
        if let model = agent.resolved.model { values["model"] = model }
        if !agent.resolved.fallbackModels.isEmpty { values["fallbackModels"] = agent.resolved.fallbackModels }
        if let thinking = agent.resolved.thinking { values["thinking"] = thinking }
        if let tools = agent.resolved.tools { values["tools"] = tools + (agent.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" } }
        if let extensions = agent.resolved.extensions { values["extensions"] = extensions }
        if let output = agent.resolved.output { values["output"] = output }
        if let defaultExpectedOutcome = agent.resolved.defaultExpectedOutcome { values["defaultExpectedOutcome"] = defaultExpectedOutcome.rawValue }
        if let reads = agent.resolved.defaultReads { values["defaultReads"] = reads }
        if let defaultProgress = agent.resolved.defaultProgress { values["defaultProgress"] = defaultProgress }
        if let interactive = agent.resolved.interactive { values["interactive"] = interactive }
        if let maxSubagentDepth = agent.resolved.maxSubagentDepth { values["maxSubagentDepth"] = maxSubagentDepth }
        for (key, value) in agent.resolved.unknownFields { values[key] = value }
        return values
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
                    FieldHelpButton(text: help)
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
        return "Disabled agents are hidden from subagent discovery and normal launches."
    case "Output", "Output File":
        return "Default output file for single-agent runs. Most useful in managed workflows such as parallel runs."
    case "Default Reads":
        return "Files Pi should read before execution when this agent is launched through managed workflows."
    case "Default Progress", "Progress":
        return "When enabled, managed workflows maintain progress.md for this agent."
    case "Interactive", "Interaction":
        return "Compatibility frontmatter field for interactive behavior. Parsed and preserved."
    case "Max Subagent Depth", "Max Depth":
        return "Limits how many more nested subagent launches this agent can create below itself."
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

private struct AgentEditSheet: View {
    let agent: EffectiveAgentRecord
    let availableModels: [AvailableModel]
    let availableTools: [String]
    let availableSkills: [String]
    let availableExtensions: [String]
    let makeDraft: (AgentEditingTarget.OverrideScope?) -> AgentEditorDraft?
    let onSave: (AgentEditorDraft) throws -> Void

    @State private var draft: AgentEditorDraft?
    @State private var baselineDraft: AgentEditorDraft?
    @State private var selectedTab: EditTab = .config
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    enum EditTab: String, CaseIterable, Identifiable {
        case config = "Configuration"
        case prompt = "Prompt"
        case tools = "Tools"
        case skills = "Skills"
        var id: String { rawValue }
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
                ProgressView()
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
                        .pickerStyle(.menu)
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
                        .pickerStyle(.menu)
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
                        .pickerStyle(.segmented)
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
                            .toggleStyle(.switch)
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
                                .toggleStyle(.switch)
                            Text(agentFieldHelpText(for: "Default Progress") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Interaction") {
                            Toggle("Interactive", isOn: optionalBoolBinding(for: \.interactive))
                                .toggleStyle(.switch)
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
                            TextField("Output path", text: optionalStringBinding(for: \.output))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360, alignment: .leading)
                            Text(agentFieldHelpText(for: "Output") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Default Reads") {
                            TextField("fileA, fileB", text: stringListBinding(for: \.defaultReads))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360, alignment: .leading)
                            Text(agentFieldHelpText(for: "Default Reads") ?? "")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        configRow("Max Depth") {
                            Stepper(value: optionalIntBinding(for: \.maxSubagentDepth), in: 0...10) {
                                Text(draft?.config.maxSubagentDepth.map(String.init) ?? "0")
                            }
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
                    FieldHelpButton(text: help)
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
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi Subagents Recap").font(.headline).fontWidth(.expanded)
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
                    Text("These are the native agents \(AppBrand.displayName) discovers for this project, after global/project precedence and builtin overrides.")
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
            Text("Subagent library")
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
