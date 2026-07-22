import SwiftUI

/// Dev-server controls for the selected session's project: start/stop/restart,
/// status, a clickable localhost URL, and any port-clashing servers from other
/// projects. Presented from `ProjectServerToolbarButton`.
struct ProjectServerPopover: View {
    var viewModel: AppViewModel
    let session: PiAgentSessionRecord

    @State private var commands: [ServerCommand] = []
    @State private var selectedCommandID: String?
    @State private var didLoadCommands = false
    @State private var isURLHovering = false

    private var service: ProjectServerService { viewModel.projectServerService }

    private var projectURL: URL? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        return URL(fileURLWithPath: projectPath, isDirectory: true)
    }

    private var selectedCommand: ServerCommand? {
        commands.first { $0.id == selectedCommandID } ?? commands.first
    }

    private var currentServer: RunningServer? {
        guard let projectPath = session.projectPathForProjectFeatures else { return nil }
        return service.currentServer(forProjectPath: projectPath)
    }

    private var predictedPort: Int? {
        if let server = currentServer, server.status.isActive {
            return server.port
        }
        return selectedCommand?.defaultPort
    }

    private var conflicts: [RunningServer] {
        service.conflictingServers(predictedPort: predictedPort, excludingProjectPath: session.projectPathForProjectFeatures ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPopoverHeader(title: "Dev Server", subtitle: session.projectNameForDisplay) {
                if let status = currentServer?.status {
                    headerStatusPill(status)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                content
                if !conflicts.isEmpty {
                    Divider()
                    conflictsSection
                }
            }
            .padding(.horizontal, AppTheme.Popover.headerHInset)
            .padding(.vertical, 12)
        }
        .frame(width: AppTheme.Popover.standardWidth)
        .task {
            guard let projectURL else {
                commands = []
                didLoadCommands = true
                return
            }
            let detected = ServerCommandDetector.detect(at: projectURL)
            commands = detected
            if selectedCommandID == nil || !detected.contains(where: { $0.id == selectedCommandID }) {
                selectedCommandID = detected.first?.id
            }
            didLoadCommands = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !didLoadCommands {
            AppSpinner()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let server = currentServer {
            serverStateView(server)
        } else if commands.isEmpty {
            emptyState
        } else {
            idleServerView
        }
    }

    private var emptyState: some View {
        Text("No dev server detected. Add a dev, start, or serve script to package.json, or open a Cargo or Django project.")
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var idleServerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if commands.count > 1 {
                Picker("Command", selection: commandSelection) {
                    ForEach(commands) { command in
                        Text(command.label).tag(command.id)
                    }
                }
                .appMenuPicker()
                .labelsHidden()
                .tint(AppTheme.brandAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let command = selectedCommand {
                commandChip(command)
            }

            startButton(command: selectedCommand)
        }
    }

    private func serverStateView(_ server: RunningServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            commandChip(server.command)

            switch server.status {
            case .starting, .running:
                if let url = server.detectedURL {
                    urlLink(url)
                } else {
                    Text("Waiting for the server to report its URL…")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case let .crashed(code):
                statusMessage("The server exited unexpectedly (code \(code)).")
            case let .failed(message):
                statusMessage(message)
            case .stopped:
                EmptyView()
            }

            controlButtons(for: server)
        }
    }

    @ViewBuilder
    private func controlButtons(for server: RunningServer) -> some View {
        if server.status.isActive {
            HStack(spacing: 8) {
                Button { viewModel.stopProjectServer(for: session, server: server) } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .appSecondaryButton()

                Button { viewModel.restartProjectServer(for: session, server: server) } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .appSecondaryButton()
            }
        } else {
            HStack(spacing: 8) {
                Button { service.remove(server) } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .appSecondaryButton()

                Button {
                    let command = server.command
                    service.remove(server)
                    viewModel.startProjectServer(for: session, command: command)
                } label: {
                    Label("Start Again", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .appPrimaryButton()
            }
        }
    }

    @ViewBuilder
    private func startButton(command: ServerCommand?) -> some View {
        Button {
            if let command {
                viewModel.startProjectServer(for: session, command: command)
            }
        } label: {
            Label("Start Server", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .appPrimaryButton()
        .disabled(command == nil)
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Port conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let port = predictedPort {
                Text("Other running servers are using port \(port):")
                    .font(AppTheme.Font.micro)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(conflicts) { server in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.projectName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(server.command.label)
                                .font(AppTheme.Font.micro)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button("Stop") { viewModel.stopProjectServer(for: session, server: server) }
                            .appSmallSecondaryButton()
                    }
                }
            }
        }
    }

    private func commandChip(_ command: ServerCommand) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(AppTheme.Font.micro.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(command.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.contentSubtleFill.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    /// URL row styled as a sibling of `commandChip` (same shape, fill, stroke)
    /// so command + address read as one stacked info block. The accent lives
    /// only on the address text — a full accent-tinted row read as a warning.
    private func urlLink(_ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(AppTheme.Font.micro.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Text(url.absoluteString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.brandAccent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(AppTheme.Font.micro.weight(.semibold))
                    .foregroundStyle(isURLHovering ? AppTheme.brandAccent : AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isURLHovering ? AppTheme.contentSubtleFill : AppTheme.contentSubtleFill.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isURLHovering = $0 }
        .help("Open \(url.absoluteString) in the browser")
    }

    private func statusMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerStatusPill(_ status: ServerStatus) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(statusText(status))
                .font(AppTheme.Font.micro.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .appGlassCapsule()
    }

    private var commandSelection: Binding<String> {
        Binding(
            get: { selectedCommandID ?? commands.first?.id ?? "" },
            set: { selectedCommandID = $0 }
        )
    }

    private func statusColor(_ status: ServerStatus) -> Color {
        switch status {
        case .starting: return .yellow
        case .running: return .green
        case .stopped: return .gray
        case .crashed, .failed: return .red
        }
    }

    private func statusText(_ status: ServerStatus) -> String {
        switch status {
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .crashed: return "Crashed"
        case .failed: return "Failed"
        }
    }
}
