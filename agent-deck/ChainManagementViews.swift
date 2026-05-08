import AppKit
import SwiftUI

struct ChainsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isRecapPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                AppPage("Chains", subtitle: "\(viewModel.allVisibleChainRecords.count) total") {
                    List(viewModel.allVisibleChainRecords, selection: $viewModel.selectedChainID) { chain in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(chain.name)
                                .font(.headline)
                                .fontWidth(.expanded)
                                .lineLimit(2)
                            Text(chain.description.isEmpty ? "\(chain.steps.count) steps" : chain.description)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 6)
                        .tag(chain.id)
                    }
                    .listStyle(.inset)
                }
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
                    chainRecapSection("Effective Chains", chains: snapshot.chains, color: AppTheme.brandAccentDeep)
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

