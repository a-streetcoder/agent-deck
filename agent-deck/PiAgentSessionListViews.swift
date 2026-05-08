import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentSessionSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField("Search all sessions", text: $text)
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
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isEnabled ? .white : AppTheme.mutedText.opacity(0.55))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isEnabled ? AppTheme.brandAccent : AppTheme.contentStroke.opacity(0.45))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Pi Agent session")
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
            HStack(alignment: .top, spacing: 8) {
                selectedSessionIndicator
                    .opacity(isSelected ? 1 : 0)
                    .padding(.top, 10)

                HStack(alignment: .top, spacing: 5) {
                    PiAgentProjectIcon(project: project, session: session)

                    titleView
                        .layoutPriority(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                Button(action: onTogglePinned) {
                    Image(systemName: session.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.isPinned ? AppTheme.brandAccent : AppTheme.mutedText.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(session.isPinned ? AppTheme.brandAccent.opacity(0.14) : AppTheme.contentSubtleFill.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help(session.isPinned ? "Unpin session" : "Pin session")

                if session.needsAttention {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.brandAccent)
                        .help("Pi Agent finished and needs review")
                }
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
            .padding(.leading, 14)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                if isRunning {
                    activeStatusLabel
                        .transition(.opacity)
                }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .padding(.leading, 14)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sessionRowBackground)
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

    private var sessionRowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return shape
            .fill(isSelected ? AppTheme.selectionFill : AppTheme.contentFill)
            .overlay {
                if isRunning {
                    shape.fill(activeBackgroundGradient)
                }
            }
            .overlay {
                shape.stroke(
                    isRunning || isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke,
                    lineWidth: isRunning ? 2.2 : 1
                )
            }
    }

    private var activeStatusLabel: some View {
        Text("ACTIVE")
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(AppTheme.brandAccent.opacity(0.72))
            .accessibilityHidden(true)
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
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
                .lineLimit(1)
                .focused($isTitleFocused)
                .onSubmit(commitRename)
                .onExitCommand { resetRenameState() }
                .onAppear {
                    draftTitle = sessionTitle
                    isTitleFocused = true
                }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(sessionTitle)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .opacity(isGeneratingTitle ? 0.62 : 1)
                    .animation(isGeneratingTitle ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default, value: isGeneratingTitle)
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .opacity(isTitleHovered ? 1 : 0)
            }
            .font(.subheadline.weight(.semibold))
            .fontWidth(.expanded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isTitleHovered ? AppTheme.contentSubtleFill.opacity(0.65) : Color.clear)
            )
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

struct PiAgentProcessingIndicatorCard: View {
    let message: String

    var body: some View {
        AppRowCard {
            HStack(spacing: 10) {
                Image("pi")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AppTheme.assistantAccent)
                    .frame(width: 16, height: 16)
                Text(message)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                PiAgentTypingIndicator()
                Spacer()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

struct PiAgentTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                let isActive = phase == index
                Circle()
                    .fill(Color.secondary.opacity(isActive ? 0.78 : 0.22))
                    .frame(width: 6, height: 6)
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
