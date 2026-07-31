import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentSessionSearchField: View {
    var placeholder: String? = nil
    @Binding var text: String
    @ObservedObject private var languageStore = LanguageStore.shared

    private var resolvedPlaceholder: String {
        placeholder ?? languageStore.t("session.searchAll")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField(resolvedPlaceholder, text: $text)
                .textFieldStyle(.plain)
                .appBrandTint()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(languageStore.t("session.clearSearch"))
                .help(languageStore.t("session.clearSearch"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.subCardCornerRadius, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }
}

struct PiAgentAddSessionButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        AppCircleIconButton(
            style: .soft,
            tint: isEnabled ? AppTheme.brandAccent : AppTheme.mutedText,
            size: 30,
            help: LanguageStore.shared.t("session.new"),
            action: action
        ) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(LanguageStore.shared.t("session.new"))
    }
}

struct PiAgentAddSessionMenuButton: View {
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let action: () -> Void
    let onSelectAgentDeckBuilder: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false

    var body: some View {
        AppCircleIconButton(
            style: .soft,
            tint: isEnabled ? AppTheme.brandAccent : AppTheme.mutedText,
            size: 30,
            help: projects.isEmpty
                ? LanguageStore.shared.t("session.newGeneralHelp")
                : LanguageStore.shared.t("session.newChoose"),
            action: primaryAction
        ) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(LanguageStore.shared.t("session.new"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PiAgentProjectPickerPopover(
                projects: orderedProjects,
                selectedProject: selectedProject,
                onSelectNoProject: {
                    isPresented = false
                    action()
                },
                onSelectAgentDeckBuilder: {
                    isPresented = false
                    onSelectAgentDeckBuilder()
                },
                onSelectProject: { project in
                    isPresented = false
                    onSelectProject(project)
                }
            )
        }
    }

    private func primaryAction() {
        if projects.isEmpty {
            action()
        } else {
            isPresented.toggle()
        }
    }

    private var orderedProjects: [DiscoveredProject] {
        guard let selectedProject,
              let index = projects.firstIndex(where: { $0.id == selectedProject.id }) else { return projects }
        var ordered = projects
        ordered.remove(at: index)
        ordered.insert(selectedProject, at: 0)
        return ordered
    }
}

/// New-session control surfaced when Deck agents are enabled: a single glass
/// capsule split into `+` (new session) and a paperplane (1:1 with an agent),
/// separated by a hairline. Built as a split control —
/// the glass sits on the `HStack` and each tap zone is a plain `Button`, so the
/// fill renders reliably (a `Menu` label's glass does not, outside a toolbar).
/// The agent list opens as a popover; with no scoped project the `+` opens the
/// project picker first (mirroring `PiAgentAddSessionMenuButton`).
struct PiAgentNewSessionSplitButton: View {
    let viewModel: AppViewModel
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let onNewSession: () -> Void
    let onNewSessionForProject: (DiscoveredProject) -> Void

    @State private var resolvedProject: DiscoveredProject?
    @State private var resolvedAgents: [EffectiveAgentRecord] = []
    @State private var isAgentPickerPresented = false
    @State private var isProjectPickerPresented = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                // Re-resolve at click time: the button stays mounted from app
                // launch (both panel layers are permanent), so the cached
                // resolution can predate project discovery. The onChange
                // triggers keep it live while the popover is open; this
                // guarantees it's right when the popover opens.
                refresh()
                isAgentPickerPresented.toggle()
            } label: {
                Image(systemName: "paperplane")
                    .imageScale(.medium)
                    .fontWeight(.bold)
                    .padding(.leading, 11)
                    .padding(.trailing, 9)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(LanguageStore.shared.t("session.chatWithAgentHelp"))
            .accessibilityLabel(LanguageStore.shared.t("session.chatWithAgent"))
            .popover(isPresented: $isAgentPickerPresented, arrowEdge: .bottom) {
                PiAgentChatWithAgentPopover(
                    project: resolvedProject,
                    agents: resolvedAgents,
                    imageStore: viewModel.agentImageStore,
                    onSelect: { agent, project in
                        isAgentPickerPresented = false
                        viewModel.startAgentSession(agent: agent, project: project, initialInstruction: nil)
                    }
                )
            }

            Rectangle()
                .fill(AppTheme.brandAccent.opacity(0.32))
                .frame(width: 1, height: 16)

            Button(action: plusAction) {
                Image(systemName: "plus")
                    .imageScale(.large)
                    .fontWeight(.bold)
                    .padding(.leading, 9)
                    .padding(.trailing, 11)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                selectedProject == nil
                    ? LanguageStore.shared.t("session.new")
                    : LanguageStore.shared.t("session.newInProject", selectedProject!.repositoryDisplayName)
            )
            .accessibilityLabel(LanguageStore.shared.t("session.new"))
            .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
                PiAgentProjectPickerPopover(
                    projects: projects,
                    selectedProject: selectedProject,
                    onSelectNoProject: {
                        isProjectPickerPresented = false
                        onNewSession()
                    },
                    onSelectAgentDeckBuilder: {
                        isProjectPickerPresented = false
                        viewModel.createAgentDeckBuilderDraft()
                    },
                    onSelectProject: { project in
                        isProjectPickerPresented = false
                        onNewSessionForProject(project)
                    }
                )
            }
        }
        .foregroundStyle(AppTheme.brandAccent)
        .fixedSize()
        .glassEffect(.regular.tint(AppTheme.brandAccent.opacity(0.18)), in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onAppear { refresh() }
        .onChange(of: viewModel.selectedDiscoveredProject?.path) { _, _ in refresh() }
        .onChange(of: viewModel.discoveredProjects.count) { _, _ in refresh() }
    }

    private func plusAction() {
        if selectedProject == nil, !projects.isEmpty {
            isProjectPickerPresented.toggle()
        } else {
            onNewSession()
        }
    }

    private func refresh() {
        resolvedProject = resolveProject()
        guard let project = resolvedProject else {
            resolvedAgents = []
            return
        }
        resolvedAgents = viewModel.selectableAgentUniverse(forProjectPath: project.path)
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func resolveProject() -> DiscoveredProject? {
        if let scoped = viewModel.selectedDiscoveredProject { return scoped }
        let sessions = viewModel.piAgentSessionStore.sessions
        if let candidate = sessions.max(by: { $0.updatedAt < $1.updatedAt }),
           let match = viewModel.projectByPath[candidate.projectPath] {
            return match
        }
        return viewModel.discoveredProjects.first
    }
}

/// Agent picker for the 1:1 button — mirrors `PiAgentProjectPickerPopover`'s glass
/// panel chrome. Tapping an agent starts a fresh 1:1 chat in the resolved project.
private struct PiAgentChatWithAgentPopover: View {
    let project: DiscoveredProject?
    let agents: [EffectiveAgentRecord]
    let imageStore: AgentImageStore
    let onSelect: (EffectiveAgentRecord, DiscoveredProject) -> Void

    var body: some View {
        AppPopoverContainer(
            title: LanguageStore.shared.t("session.start1on1"),
            subtitle: project.map { LanguageStore.shared.t("session.pickAgentIn", $0.repositoryDisplayName) }
        ) {
            if let project, !agents.isEmpty {
                AppPopoverScrollList {
                    ForEach(agents, id: \.name) { agent in
                        PiAgentChatAgentRow(
                            agent: agent,
                            avatarURL: imageStore.imageURL(for: agent.name)
                        ) {
                            onSelect(agent, project)
                        }
                    }
                }
            } else {
                AppPopoverEmptyState(
                    text: project == nil
                        ? LanguageStore.shared.t("session.noProject")
                        : LanguageStore.shared.t("session.noAgents")
                )
            }
        }
    }
}

/// Rich agent row for the 1:1 picker: avatar (same circle treatment as the
/// subagent run cards), name + model, and the agent's description underneath.
private struct PiAgentChatAgentRow: View {
    let agent: EffectiveAgentRecord
    let avatarURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(agent.name)
                            .font(AppTheme.Popover.itemTitleFont)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        if let model = agent.resolved.model, !model.isEmpty {
                            Text(model)
                                .font(AppTheme.Font.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !agentDescription.isEmpty {
                        Text(agentDescription)
                            .font(AppTheme.Popover.itemSubtitleFont)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, AppTheme.Popover.rowHInset)
            .padding(.vertical, AppTheme.Popover.rowVInset)
        }
        .buttonStyle(.plain)
    }

    private var agentDescription: String {
        agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarURL, let nsImage = AgentImageLoader.image(at: avatarURL) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(AppTheme.contentSubtleFill)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "paperplane")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
        }
    }
}

private struct PiAgentProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let onSelectNoProject: () -> Void
    let onSelectAgentDeckBuilder: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void

    var body: some View {
        AppPopoverContainer(
            title: LanguageStore.shared.t("session.newSessionTitle"),
            subtitle: LanguageStore.shared.t("session.newSessionSubtitle")
        ) {
            AppProjectPickerPopoverList {
                AppPopoverProjectRow(
                    imageURL: nil,
                    symbolName: "bubble.left.and.bubble.right",
                    assetName: nil,
                    title: PiAgentSessionRecord.noProjectDisplayName,
                    path: LanguageStore.shared.t("session.generalChatsPath"),
                    isCurrent: false
                ) {
                    onSelectNoProject()
                }

                AppPopoverProjectRow(
                    imageURL: nil,
                    symbolName: "hammer",
                    assetName: nil,
                    title: PiAgentSessionRecord.agentDeckBuilderDisplayName,
                    path: LanguageStore.shared.t("session.deckBuilderPath"),
                    isCurrent: false
                ) {
                    onSelectAgentDeckBuilder()
                }

                ForEach(projects) { project in
                    AppPopoverProjectRow(
                        imageURL: project.iconFileURL,
                        symbolName: project.fallbackSymbolName,
                        assetName: project.projectType.assetName,
                        title: project.repositoryDisplayName,
                        path: project.path,
                        isCurrent: project.id == selectedProject?.id
                    ) {
                        onSelectProject(project)
                    }
                }
            }
        }
    }
}

struct PiAgentSessionRow: View, Equatable {
    let session: PiAgentSessionRecord
    let isSelected: Bool
    let isRunning: Bool
    let hasUIRequest: Bool
    let isGeneratingTitle: Bool
    let hasActiveLoop: Bool
    let gitActivity: PiAgentSessionGitActivity
    let onSelect: () -> Void
    let onDelete: () -> Void

    // Equatable so `.equatable()` can short-circuit re-evaluation: the session list
    // lives inside a body that re-runs at the streaming cadence (the transcript cache
    // is an ObservableObject, so any of its published changes invalidates the whole
    // body). Comparing the value inputs lets SwiftUI skip re-laying-out every row on
    // those pulses, refreshing a row only when something it actually shows changes.
    // Closures are intentionally excluded: when the value inputs match, the retained
    // instance's closures captured the same session, so they stay correct.
    static func == (lhs: PiAgentSessionRow, rhs: PiAgentSessionRow) -> Bool {
        lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isRunning == rhs.isRunning
            && lhs.hasUIRequest == rhs.hasUIRequest
            && lhs.isGeneratingTitle == rhs.isGeneratingTitle
            && lhs.hasActiveLoop == rhs.hasActiveLoop
            && lhs.gitActivity == rhs.gitActivity
    }

    @State private var isRowHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 5) {
                if session.pinnedAt != nil {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 11, height: 11)
                        .help(LanguageStore.shared.t("session.pinned"))
                        .accessibilityHidden(true)
                }

                titleView
                    .layoutPriority(1)

                Spacer(minLength: 0)
            }

            if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .frame(width: 11, alignment: .center)
                    Text(agentName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(AppTheme.Font.footnote)
                .foregroundStyle(AppTheme.mutedText)
            }

            HStack(spacing: 6) {
                if session.isAgentDeckBuilderSession {
                    Image(systemName: "hammer")
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .frame(width: 11, alignment: .center)
                } else if session.isNoProject {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .frame(width: 11, alignment: .center)
                } else {
                    Image("github")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                }
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(AppTheme.Font.footnote)
            .foregroundStyle(AppTheme.mutedText)

            if let branch = session.branchName, !branch.isEmpty {
                HStack(spacing: 6) {
                    Image("branch")
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .frame(width: 11, alignment: .center)
                    Text(piAgentSessionDisplayBranchName(branch))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(AppTheme.Font.footnote)
                .foregroundStyle(AppTheme.mutedText)
                .help(branch)
            }

            HStack(spacing: 8) {
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                SessionGitActivityStrip(activity: gitActivity, isSelected: isSelected, hasLoop: hasActiveLoop)
            }
        }
        .saturation(seenAppearanceAmount)
        .opacity(seenContentOpacity)
        // Keep the text column clear of the trailing attention/delete slot,
        // which is painted as an overlay rather than participating in layout.
        .padding(.trailing, 30)
        // 6 (AppList inset) + 8 = 14pt from the panel edge, left-aligning the
        // title with the header's project icon.
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                attentionStatusSlot
                    .opacity(isRowHovered ? 0 : 1)
                    .allowsHitTesting(false)
                deleteButton
                    .opacity(isRowHovered ? 1 : 0)
                    .allowsHitTesting(isRowHovered)
            }
            .padding(.trailing, 8)
            .animation(.easeInOut(duration: 0.15), value: isRowHovered)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(LanguageStore.shared.t("session.openA11y", sessionTitle))
        .accessibilityAction(named: Text(LanguageStore.shared.t("session.open")), onSelect)
        .focusable()
        .onKeyPress(.space) {
            onSelect()
            return .handled
        }
        .onHover { isRowHovered = $0 }
        .help(statusHelp)
    }

    private var selectedSessionIndicator: some View {
        Circle()
            .fill(AppTheme.brandAccent.opacity(0.72))
            .frame(width: 6, height: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var isSeenInactive: Bool {
        !isSelected && !hasUIRequest && !isRunning && !session.needsAttention
    }

    private var seenAppearanceAmount: Double {
        isSeenInactive ? 0.38 : 1
    }

    private var seenContentOpacity: Double {
        isSeenInactive ? 0.58 : 1
    }

    @ViewBuilder
    private var attentionStatusSlot: some View {
        ZStack(alignment: .trailing) {
            if hasUIRequest {
                askUserBadge
                    .transition(.opacity)
            } else if hasActiveLoop {
                AppSpinner()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                    .help(LanguageStore.shared.t("session.loopRunning"))
                    .accessibilityLabel(LanguageStore.shared.t("session.loopRunning"))
                    .transition(.opacity)
            } else if isRunning {
                PiAgentTypingIndicator()
                    .transition(.opacity)
            } else if session.needsAttention {
                needsAttentionBell
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.24), value: hasUIRequest)
        .animation(.snappy(duration: 0.24), value: isRunning)
        .animation(.snappy(duration: 0.24), value: hasActiveLoop)
        .animation(.snappy(duration: 0.24), value: session.needsAttention)
    }

    private var askUserBadge: some View {
        Image(systemName: "questionmark.bubble.fill")
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(AppTheme.brandAccent)
            .help(LanguageStore.shared.t("session.waitingHelp"))
            .accessibilityLabel(LanguageStore.shared.t("session.waitingResponse"))
    }

    private var needsAttentionBell: some View {
        Image(systemName: "bell.fill")
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(AppTheme.brandAccent)
            .help(LanguageStore.shared.t("session.needsReviewHelp"))
            .accessibilityLabel(LanguageStore.shared.t("session.needsReview"))
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(AppTheme.Font.caption.weight(.semibold))
        }
        .appSmallSecondaryButton()
        .help(LanguageStore.shared.t("session.delete"))
        .accessibilityLabel(LanguageStore.shared.t("session.delete"))
    }

    private var activeBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.brandAccentBright.opacity(0.10),
                AppTheme.brandAccent.opacity(0.045),
                AppTheme.brandAccentDeep.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var titleView: some View {
        Text(sessionTitle)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
            .contentTransition(.numericText())
            .opacity(isGeneratingTitle ? 0.62 : 1)
            .animation(isGeneratingTitle ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default, value: isGeneratingTitle)
            .layoutPriority(1)
            .font(AppTheme.Font.footnote.weight(.medium))
            .fontWidth(.expanded)
            .foregroundStyle(.primary)
            // Fixed height so the row never depends on title text measurement.
            .frame(height: 18, alignment: .center)
    }

    private var sessionTitle: String {
        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LanguageStore.shared.t("session.projectAgent")
        }
        return session.title
    }

    private var subtitle: String {
        // Prefer the human project name so auto-titled sessions stay anchored
        // to a workspace even when the topic string no longer mentions it.
        if session.isNoProject { return session.projectNameForDisplay }
        let name = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let repository = session.repository?.trimmingCharacters(in: .whitespacesAndNewlines),
           !repository.isEmpty {
            return repository
        }
        return session.projectScopeLabel
    }

    private var statusHelp: String {
        if hasUIRequest { return LanguageStore.shared.t("session.waitingResponse") }
        if hasActiveLoop { return LanguageStore.shared.t("session.loopRunning") }
        if isRunning { return LanguageStore.shared.t("session.statusActive") }
        return session.status.rawValue
    }

    private var statusColor: Color {
        switch session.status {
        case .running, .starting: return AppTheme.brandAccent
        case .idle, .completed: return .secondary
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}

private struct SessionGitActivityStrip: View {
    let activity: PiAgentSessionGitActivity
    let isSelected: Bool
    let hasLoop: Bool

    var body: some View {
        HStack(spacing: 5) {
            if hasLoop {
                Image(systemName: "infinity")
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                    .help(LanguageStore.shared.t("session.loopActive"))
                    .accessibilityLabel(LanguageStore.shared.t("session.loopActive"))
            }
            pip(kind: .commit, date: activity.lastCommit, verb: "commit")
            pip(kind: .push,   date: activity.lastPush,   verb: "push")
            pip(kind: .merge,  date: activity.lastMerge,  verb: "merge")
        }
    }

    @ViewBuilder
    private func pip(kind: PiAgentGitEventKind, date: Date?, verb: String) -> some View {
        if let date {
            icon(for: kind)
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.brandAccent : AppTheme.mutedText)
                .help(LanguageStore.shared.t("session.lastVerbAt", verb, date.formatted(date: .omitted, time: .shortened)))
        }
    }

    @ViewBuilder
    private func icon(for kind: PiAgentGitEventKind) -> some View {
        switch kind {
        case .commit, .commitAndPush:
            Image("git-commit")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
        case .push:
            Image(systemName: "arrow.up")
        case .merge:
            Image(systemName: "arrow.triangle.merge")
        }
    }
}

private struct PiAgentSessionTelemetryStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<18, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(segmentColor(index: index))
                    .frame(width: segmentWidth(index: index), height: segmentHeight(index: index))
                    .shadow(color: AppTheme.brandAccent.opacity(activeSegment(index) ? 0.32 : 0), radius: 4, y: 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(index % 6) * 0.055), value: isActive)
            }
            Spacer(minLength: 0)
            Text(LanguageStore.shared.t("session.activeBadge"))
                .font(AppTheme.Font.smallLabel)
                .tracking(1.2)
                .foregroundStyle(AppTheme.brandAccent.opacity(0.72))
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }

    private func activeSegment(_ index: Int) -> Bool {
        guard !reduceMotion else { return index % 3 == 0 }
        return isActive ? index % 3 != 1 : index % 4 == 0
    }

    private func segmentColor(index: Int) -> Color {
        let baseOpacity = activeSegment(index) ? 0.78 : 0.18
        if index % 5 == 0 {
            return AppTheme.brandAccentBright.opacity(baseOpacity)
        }
        return AppTheme.brandAccent.opacity(baseOpacity)
    }

    private func segmentWidth(index: Int) -> CGFloat {
        activeSegment(index) ? CGFloat([10, 16, 7, 12, 20, 9][index % 6]) : 6
    }

    private func segmentHeight(index: Int) -> CGFloat {
        activeSegment(index) ? CGFloat([2, 3, 2, 4, 3, 2][index % 6]) : 2
    }
}

struct PiAgentProcessingIndicatorBar: View {
    let message: String?

    var body: some View {
        HStack(spacing: 8) {
            if let message {
                Image("pi")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AppTheme.piLogo.gradient)
                    .frame(width: 14, height: 14)
                Text(message)
                    .font(AppTheme.Font.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                PiAgentTypingIndicator()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: message)
    }
}

struct PiAgentTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                let isActive = phase == index
                Circle()
                    .fill(Color.secondary.opacity(isActive ? 0.78 : 0.22))
                    .frame(width: 5, height: 5)
                    .scaleEffect(reduceMotion ? 1 : (isActive ? 1.18 : 0.86))
            }
        }
        .padding(.vertical, 5)
        .task {
            // `try await Task.sleep` (no `?`) throws on cancellation, which
            // exits the loop on the same tick instead of waiting for the
            // subsequent `guard !Task.isCancelled` to fire.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(620))
                } catch {
                    return
                }
                // Pause the wake-up when the window is fully occluded so
                // background apps don't spin a 620ms timer on the cooperative
                // scheduler for every visible typing indicator.
                guard NSApp.occlusionState.contains(.visible) else {
                    continue
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .accessibilityLabel(LanguageStore.shared.t("session.typing"))
    }
}
