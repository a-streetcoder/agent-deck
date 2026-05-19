import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentSessionSearchField: View {
    var placeholder = "Search all sessions"
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }
}

struct PiAgentAddSessionButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            PiAgentAddSessionButtonLabel(showsChevron: false, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Pi Agent session")
    }
}

struct PiAgentAddSessionMenuButton: View {
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let action: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false

    var body: some View {
        Button(action: buttonAction) {
            PiAgentAddSessionButtonLabel(showsChevron: false, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Pi Agent session")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PiAgentProjectPickerPopover(
                projects: orderedProjects,
                selectedProject: selectedProject,
                onSelectProject: { project in
                    isPresented = false
                    onSelectProject(project)
                }
            )
        }
    }

    private func buttonAction() {
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

private struct PiAgentProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let onSelectProject: (DiscoveredProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session")
                    .font(.headline)
                Text("Choose a project for Pi Agent.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(projects) { project in
                        Button {
                            onSelectProject(project)
                        } label: {
                            HStack(spacing: 10) {
                                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(project.repositoryDisplayName)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if project.id == selectedProject?.id {
                                            Text("Current")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(AppTheme.brandAccent)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.10)))
                                        }
                                    }
                                    Text(project.path)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.mutedText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 340)
        .appGlassPanel(cornerRadius: 14)
    }
}

private struct PiAgentAddSessionButtonLabel: View {
    let showsChevron: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(foregroundStyle)
        .frame(width: showsChevron ? 42 : 30, height: 30)
        .appGlassCapsule(tint: tintColor)
        .contentShape(Capsule(style: .continuous))
    }

    private var foregroundStyle: AnyShapeStyle {
        isEnabled
            ? AnyShapeStyle(AppTheme.accentForeground.gradient)
            : AnyShapeStyle(AppTheme.mutedText.opacity(0.55).gradient)
    }

    private var tintColor: Color {
        isEnabled ? AppTheme.brandAccent : AppTheme.mutedText.opacity(0.35)
    }
}

struct PiAgentSessionRow: View {
    let session: PiAgentSessionRecord
    let project: DiscoveredProject?
    let isSelected: Bool
    let isRunning: Bool
    let isRenaming: Bool
    let isGeneratingTitle: Bool
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onEndRename: () -> Void
    let onRename: (String) -> Void
    let onTogglePinned: () -> Void

    @State private var draftTitle = ""
    @State private var isTitleHovered = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    PiAgentProjectIcon(project: project, session: session)

                    titleView
                        .layoutPriority(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
            }
            .font(.footnote)
            .foregroundStyle(AppTheme.mutedText)

            Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .saturation(seenAppearanceAmount)
        .opacity(seenContentOpacity)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            attentionStatusSlot
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(statusHelp)
        .onAppear {
            draftTitle = sessionTitle
        }
        .onChange(of: session.id) { _, _ in resetRenameState() }
        .onChange(of: session.title) { _, _ in draftTitle = sessionTitle }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftTitle = sessionTitle
                isTitleFocused = true
            } else {
                isTitleFocused = false
            }
        }
        .onChange(of: isTitleFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .onDisappear(perform: commitRename)
    }

    private var selectedSessionIndicator: some View {
        Circle()
            .fill(AppTheme.brandAccent.opacity(0.72))
            .frame(width: 6, height: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var isSeenInactive: Bool {
        !isSelected && !isRunning && !session.needsAttention
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
            if isRunning {
                activeStatusLabel
                    .transition(.opacity)
            } else if session.needsAttention {
                needsAttentionBell
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.24), value: isRunning)
        .animation(.snappy(duration: 0.24), value: session.needsAttention)
    }

    private var activeStatusLabel: some View {
        Text("ACTIVE")
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(AppTheme.brandAccent.opacity(0.72))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(AppTheme.contentFill.opacity(0.72)))
            .accessibilityHidden(true)
    }

    private var needsAttentionBell: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.brandAccent)
            .help("Pi Agent finished and needs review")
            .accessibilityLabel("Needs review")
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

    @ViewBuilder
    private var titleView: some View {
        if isRenaming {
            TextField("Session name", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .fontWidth(.expanded)
                .lineLimit(1)
                .frame(height: 22, alignment: .center)
                .focused($isTitleFocused)
                .onSubmit(commitRename)
                .onExitCommand { resetRenameState() }
                .onAppear {
                    draftTitle = sessionTitle
                    isTitleFocused = true
                }
        } else {
            HStack(alignment: .center, spacing: 5) {
                Text(sessionTitle)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsTightening(true)
                    .lineSpacing(-2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxHeight: 30, alignment: .center)
                    .contentTransition(.numericText())
                    .opacity(isGeneratingTitle ? 0.62 : 1)
                    .animation(isGeneratingTitle ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default, value: isGeneratingTitle)
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .opacity(isTitleHovered ? 0.8 : 0)
            }
            .font(.system(size: 11, weight: .semibold))
            .fontWidth(.expanded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(minHeight: 22, maxHeight: 30, alignment: .center)
            .contentShape(Rectangle())
            .onHover { isTitleHovered = $0 }
            .onTapGesture(perform: onBeginRename)
            .help("Rename session")
        }
    }

    private func resetRenameState() {
        draftTitle = sessionTitle
        onEndRename()
        isTitleFocused = false
    }

    private func commitRename() {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            draftTitle = sessionTitle
        } else if trimmedTitle != session.title {
            onRename(trimmedTitle)
        }
        onEndRename()
        isTitleFocused = false
    }

    private var sessionTitle: String {
        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.issueNumber.map { "#\($0)" } ?? "Project agent"
        }
        return session.title
    }

    private var subtitle: String {
        if let repository = session.repository {
            return repository
        }
        return session.projectName
    }

    private var statusHelp: String {
        if isRunning { return "Active" }
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
            Text("ACTIVE")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
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

struct PiAgentProjectIcon: View {
    let project: DiscoveredProject?
    let session: PiAgentSessionRecord

    var body: some View {
        Group {
            if let url = project?.iconFileURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(AppTheme.contentSubtleFill)
            .overlay {
                Image(session.kind == .issue ? "github" : "pi")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(5)
                    .foregroundStyle(AppTheme.mutedText)
            }
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
                    .foregroundStyle(AppTheme.assistantAccent)
                    .frame(width: 14, height: 14)
                Text(message)
                    .font(.callout.weight(.semibold))
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
                    .offset(y: reduceMotion ? 0 : (isActive ? -2 : 0))
            }
        }
        .padding(.vertical, 5)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(620))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .accessibilityLabel("Pi is typing")
    }
}
