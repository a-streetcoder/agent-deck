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

    private var service: ProjectServerService { viewModel.projectServerService }

    private var projectURL: URL {
        URL(fileURLWithPath: session.projectPath, isDirectory: true)
    }

    private var selectedCommand: ServerCommand? {
        commands.first { $0.id == selectedCommandID } ?? commands.first
    }

    private var currentServer: RunningServer? {
        service.currentServer(forProjectPath: session.projectPath)
    }

    private var predictedPort: Int? {
        if let server = currentServer, server.status.isActive {
            return server.port
        }
        return selectedCommand?.defaultPort
    }

    private var conflicts: [RunningServer] {
        service.conflictingServers(predictedPort: predictedPort, excludingProjectPath: session.projectPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if !conflicts.isEmpty {
                Divider()
                conflictsSection
            }
        }
        .padding(16)
        .frame(width: 360)
        .task {
            let detected = ServerCommandDetector.detect(at: projectURL)
            commands = detected
            if selectedCommandID == nil || !detected.contains(where: { $0.id == selectedCommandID }) {
                selectedCommandID = detected.first?.id
            }
            didLoadCommands = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Dev Server", systemImage: "server.rack")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(session.projectName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !didLoadCommands {
            ProgressView()
                .controlSize(.small)
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
    }

    private var idleServerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if commands.count > 1 {
                Picker("Command", selection: commandSelection) {
                    ForEach(commands) { command in
                        Text(command.label).tag(command.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else if let command = selectedCommand {
                commandLabel(command)
            }

            startButton(command: selectedCommand)
        }
    }

    private func serverStateView(_ server: RunningServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBadge(server.status)
            commandLabel(server.command)

            switch server.status {
            case .starting, .running:
                if let url = server.detectedURL {
                    urlLink(url)
                } else {
                    Text("Waiting for the server to report its URL…")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            case let .crashed(code):
                Text("The server exited unexpectedly (code \(code)).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button { service.stop(server) } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                Button { service.restart(server) } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: 8) {
                Button { service.remove(server) } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)

                Button {
                    let command = server.command
                    service.remove(server)
                    service.start(command: command, projectPath: session.projectPath, projectName: session.projectName)
                } label: {
                    Label("Start Again", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func startButton(command: ServerCommand?) -> some View {
        Button {
            if let command {
                service.start(command: command, projectPath: session.projectPath, projectName: session.projectName)
            }
        } label: {
            Label("Start Server", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(command == nil)
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Port conflicts", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let port = predictedPort {
                Text("Other running servers are using port \(port):")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            ForEach(conflicts) { server in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.projectName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(server.command.label)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Stop") { service.stop(server) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func commandLabel(_ command: ServerCommand) -> some View {
        Text(command.label)
            .font(.callout.monospaced())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func urlLink(_ url: URL) -> some View {
        Link(destination: url) {
            Label(url.absoluteString, systemImage: "arrow.up.right.square")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func statusBadge(_ status: ServerStatus) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(statusText(status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
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
