import AppKit
import SwiftUI

struct ChainsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isRecapPresented: Bool
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                chainLibraryPane
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

                if let chain = viewModel.selectedChain {
                    AppPage(chain.name, subtitle: chain.description.nonEmpty) {
                        AppCard(title: "How Chains Work") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("• Each step runs in order and later steps can use earlier output.")
                                Text("• Step `output`, `reads`, `skills`, `model`, and `progress` override the agent’s defaults for that step.")
                                Text("• `reads: false`, `skills: false`, or `output: false` explicitly turn that behavior off for the step.")
                                Text("• Relative read/write paths are resolved from the chain working directory.")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        AppCard(title: "Library & Source") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Reusable chains live in ~/.pi/agent/agent-library/chains. Pi only sees them when \(AppBrand.displayName) links them globally or into a project.")
                                    .foregroundStyle(AppTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)

                                AppKeyValueList(rows: [
                                    ("Scope", chain.source.kind.rawValue),
                                    ("In Library", chain.source.kind == .library ? "Yes" : "No"),
                                    ("Active Globally", viewModel.chainIsEnabledGlobally(chain) ? "Yes" : "No"),
                                    ("Assigned Projects", assignedProjectSummary(chain)),
                                    ("Path", chain.filePath),
                                    ("Steps", "\(chain.steps.count)")
                                ])

                                if chain.source.kind != .library {
                                    Button("Move to Library") { do { try viewModel.moveChainToLibrary(chain) } catch { NSSound.beep() } }
                                }
                            }
                        }

                        AppCard(title: "Global Visibility") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(viewModel.chainIsEnabledGlobally(chain) ? "This chain is available in every project." : "Make this chain available globally instead of only selected projects.")
                                    .foregroundStyle(AppTheme.mutedText)
                                if viewModel.chainIsEnabledGlobally(chain) {
                                    Button("Disable Globally") { do { try viewModel.disableChainGlobally(chain) } catch { NSSound.beep() } }
                                } else {
                                    Button("Enable Globally") { do { try viewModel.enableChainGlobally(chain) } catch { NSSound.beep() } }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        AppCard(title: "Project Assignment") {
                            chainProjectAssignmentList(for: chain)
                        }

                        AppCard(title: "Raw Chain") {
                            Text(ChainPersistence().serialize(chain))
                                .font(.footnote.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(chain.steps) { step in
                            AppCard(title: step.agent) {
                                VStack(alignment: .leading, spacing: 14) {
                                    if step.outputDisabled || step.readsDisabled || step.model != nil || step.skillsDisabled || step.progress != nil || !(step.reads ?? []).isEmpty || !(step.skills ?? []).isEmpty {
                                        AppKeyValueList(rows: [
                                            ("Output", step.outputDisabled ? "false" : (step.output ?? "—")),
                                            ("Reads", step.readsDisabled ? "false" : (step.reads?.joined(separator: ", ") ?? "—")),
                                            ("Model", step.model ?? "—"),
                                            ("Skills", step.skillsDisabled ? "false" : (step.skills?.joined(separator: ", ") ?? "—")),
                                            ("Progress", step.progress.map { $0 ? "true" : "false" } ?? "—")
                                        ])
                                    }
                                    MarkdownDocumentView(source: step.body.isEmpty ? "No step body parsed yet." : step.body)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No Chain Selected", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if isRecapPresented, let project = viewModel.selectedDiscoveredProject {
                Divider()
                SubagentsProjectRecapPanel(
                    project: project,
                    snapshot: viewModel.startupSnapshot(forProjectPath: project.path),
                    libraryAgents: viewModel.snapshot.libraryAgents,
                    libraryChains: viewModel.snapshot.libraryChains,
                    onClose: { isRecapPresented = false }
                )
                .frame(width: 400)
            }
        }
    }

    private var chainLibraryPane: some View {
        List(selection: $viewModel.selectedChainID) {
            if !viewModel.chainWarnings.isEmpty {
                appListSection("Warnings", info: "Chain issues that need attention.") {
                    ForEach(viewModel.chainWarnings) { warning in
                        chainWarningRow(warning)
                    }
                }
            }

            if viewModel.selectedDiscoveredProject != nil {
                appListSection("Active") {
                    if activeChains.isEmpty {
                        nativeEmptyRow("No chains are active for this project.")
                    }
                    ForEach(activeChains) { chain in
                        chainListRow(chain)
                            .tag(chain.id)
                    }
                }

                if !libraryChains.isEmpty {
                    appListSection("Chain Library", info: "Reusable chains live in ~/.pi/agent/agent-library/chains and become active when assigned to this project or enabled globally.") {
                        ForEach(libraryChains) { chain in
                            chainListRow(chain, inactive: chainIsUnusedLibraryChain(chain))
                                .tag(chain.id)
                        }
                    }
                }
            } else {
                appListSection("Global Chains") {
                    if globalChains.isEmpty {
                        nativeEmptyRow("No global chains.")
                    }
                    ForEach(globalChains) { chain in
                        chainListRow(chain)
                            .tag(chain.id)
                    }
                }

                if !projectChains.isEmpty {
                    appListSection("Project Chains") {
                        ForEach(projectChains) { chain in
                            chainListRow(chain)
                                .tag(chain.id)
                        }
                    }
                }

                if !libraryChains.isEmpty {
                    appListSection("Chain Library") {
                        ForEach(libraryChains) { chain in
                            chainListRow(chain, inactive: chainIsUnusedLibraryChain(chain))
                                .tag(chain.id)
                        }
                    }
                }
            }
        }
        .appResourceListStyle()
    }

    private func chainWarningRow(_ warning: DiagnosticWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(warning.message)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var visibleChains: [ChainRecord] {
        let chains = viewModel.allVisibleChainRecords
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return chains }
        return chains.filter { chain in
            let stepText = chain.steps.map { [$0.agent, $0.title, $0.body].joined(separator: " ") }.joined(separator: " ")
            return [chain.name, chain.description, chain.source.kind.rawValue, chain.filePath, stepText]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private var activeChains: [ChainRecord] {
        visibleChains.filter { $0.source.kind != .library }
    }

    private var globalChains: [ChainRecord] {
        visibleChains.filter { $0.source.kind == .global }
    }

    private var projectChains: [ChainRecord] {
        visibleChains.filter { $0.source.kind == .project || $0.source.kind == .legacyProject }
    }

    private var libraryChains: [ChainRecord] {
        visibleChains.filter { $0.source.kind == .library }
    }

    private func chainListRow(_ chain: ChainRecord, inactive: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: chainIcon(chain))
                .foregroundStyle(chainColor(chain))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(chain.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .lineLimit(1)
                Text(chain.description.isEmpty ? "\(chain.steps.count) steps" : chain.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    nativePill(chain.source.kind.rawValue, symbol: "folder", color: chainColor(chain))
                    if viewModel.chainIsEnabledGlobally(chain) {
                        nativePill("Global", symbol: "globe", color: .blue)
                    }
                    if !viewModel.assignedProjects(for: chain).isEmpty {
                        nativePill("Assigned", symbol: "checkmark.circle", color: .green)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(inactive ? 0.62 : 1)
        .saturation(inactive ? 0.25 : 1)
        .badge("\(chain.steps.count) steps")
    }

    private func chainIcon(_ chain: ChainRecord) -> String {
        if chain.source.kind == .library { return "building.columns" }
        if viewModel.chainIsEnabledGlobally(chain) { return "globe" }
        if chain.source.kind == .project || chain.source.kind == .legacyProject { return "checkmark.circle" }
        return "point.3.connected.trianglepath.dotted"
    }

    private func chainColor(_ chain: ChainRecord) -> Color {
        if chain.source.kind == .library { return .purple }
        if viewModel.chainIsEnabledGlobally(chain) { return .blue }
        if chain.source.kind == .project || chain.source.kind == .legacyProject { return .green }
        return .blue
    }

    private func chainIsUnusedLibraryChain(_ chain: ChainRecord) -> Bool {
        chain.source.kind == .library &&
        !viewModel.chainIsEnabledGlobally(chain) &&
        viewModel.assignedProjects(for: chain).isEmpty
    }

    private func nativePill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func nativeEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(AppTheme.mutedText)
            .padding(.vertical, 4)
            .selectionDisabled()
            .listRowSeparator(.hidden)
    }

    private func chainProjectAssignmentList(for chain: ChainRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each project that should load this chain. Project links are created in PROJECT/.pi/chains.")
                .foregroundStyle(AppTheme.mutedText)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.enabledProjects) { project in
                    ProjectAssignmentToggleRow(
                        project: project,
                        isOn: Binding(
                            get: { viewModel.chain(chain, isEnabledFor: project) },
                            set: { enabled in
                                do { try viewModel.setChain(chain, enabled: enabled, for: project) }
                                catch { NSSound.beep() }
                            }
                        )
                    )
                    if project.id != viewModel.enabledProjects.last?.id { Divider() }
                }
            }
        }
    }

    private func assignedProjectSummary(_ chain: ChainRecord) -> String {
        let projects = viewModel.assignedProjects(for: chain).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }

}

struct SubagentsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subagent library")
                .font(.headline)
                .fontWidth(.expanded)
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Agent Library", "Central storage in ~/.pi/agent/agent-library/agents. Pi does not load these until linked.")
                infoRow("Chain Library", "Central storage in ~/.pi/agent/agent-library/chains. Pi does not load these until linked.")
                infoRow("Global", "Agent links are created in the standard global agent locations (~/.agents when present, otherwise ~/.pi/agent/agents). Chain links use ~/.pi/agent/chains.")
                infoRow("Project", "Links are created in PROJECT/.pi/agents and PROJECT/.pi/chains.")
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

struct SubagentsProjectRecapPanel: View {
    let project: DiscoveredProject
    let snapshot: ScanSnapshot
    let libraryAgents: [AgentRecord]
    let libraryChains: [ChainRecord]
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
                    Text("These are the native agents and chains \(AppBrand.displayName) discovers for this project, after global/project precedence and builtin overrides.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    agentRecapSection("Effective Agents", agents: snapshot.effectiveAgents, color: AppTheme.assistantAccent)
                    chainRecapSection("Effective Chains", chains: snapshot.chains, color: .blue)
                    if !libraryAgents.isEmpty { libraryAgentSection }
                    if !libraryChains.isEmpty { libraryChainSection }
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

    private func chainRecapSection(_ title: String, chains: [ChainRecord], color: Color) -> some View {
        recapShell(title, count: chains.count, color: color) {
            ForEach(chains) { chain in
                recapRow(icon: "point.3.connected.trianglepath.dotted", color: color, title: chain.name, subtitle: "\(chain.source.kind.rawValue) · \(chain.steps.count) steps")
            }
        }
    }

    private var libraryAgentSection: some View {
        recapShell("Library Agents", count: libraryAgents.count, color: .secondary) {
            ForEach(libraryAgents) { agent in recapRow(icon: "books.vertical", color: .secondary, title: agent.name, subtitle: "Stored, not loaded until assigned") }
        }
    }

    private var libraryChainSection: some View {
        recapShell("Library Chains", count: libraryChains.count, color: .secondary) {
            ForEach(libraryChains) { chain in recapRow(icon: "books.vertical", color: .secondary, title: chain.name, subtitle: "Stored, not loaded until assigned") }
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

