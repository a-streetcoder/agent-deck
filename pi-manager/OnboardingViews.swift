import AppKit
import SwiftUI

#if canImport(TourKit)
import TourKit
#endif

struct WelcomeOnboardingSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let onFinish: () -> Void
    @State private var phase: Phase = .tour

    private enum Phase {
        case tour
        case setup
    }

    var body: some View {
        Group {
            switch phase {
            case .tour:
                tourView
            case .setup:
                SetupChecklistView(viewModel: viewModel, onFinish: onFinish)
            }
        }
        .frame(minWidth: 680, minHeight: 620)
    }

    @ViewBuilder
    private var tourView: some View {
        #if canImport(TourKit)
        TourSlideshowView(
            pages: tourPages,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Check Setup",
            onFinish: { phase = .setup },
            onClose: onFinish
        )
        .padding(22)
        #else
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image("pi")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
                Text("Welcome to Pi Manager")
                    .font(.title.bold())
                    .fontWidth(.expanded)
            }

            VStack(alignment: .leading, spacing: 12) {
                onboardingBullet("Run app-managed Pi Agent sessions with native transcript, activity, and repo sidebars.")
                onboardingBullet("Browse and edit agents, chains, prompts, skills, models, settings, and environment files.")
                onboardingBullet("Use native subagents for single, chain, and parallel delegation without external orchestration packages.")
                onboardingBullet("Connect GitHub when you want issue, commit, and push workflows.")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Check Setup") {
                    phase = .setup
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        #endif
    }

    #if canImport(TourKit)
    private var tourPages: [TourPage] {
        [
            TourPage(
                imageName: "pi",
                title: "Welcome to Pi Manager",
                description: "A native macOS workspace for Pi Agent sessions, projects, agents, prompts, skills, models, and GitHub work."
            ),
            TourPage(
                imageName: "pi",
                title: "Native Pi Agent",
                description: "Start and resume Pi sessions in the app with transcript rendering, activity tracking, repo changes, and inspector controls."
            ),
            TourPage(
                imageName: "pi",
                title: "Native Subagents",
                description: "Delegate single, chain, or parallel work through app-managed child Pi sessions with supervisor cards and worktree safety."
            ),
            TourPage(
                imageName: "github",
                title: "GitHub When You Need It",
                description: "Connect the GitHub CLI for issue boards, comments, repo changes, commits, and pushes from selected projects."
            )
        ]
    }
    #endif

    private func onboardingBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 18)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupChecklistView: View {
    @ObservedObject var viewModel: AppViewModel
    let onFinish: () -> Void
    @State private var items: [SetupCheckItem] = []
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Check")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("Pi Manager works best after these checks pass.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .help("Refresh setup checks")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        setupRow(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Open Settings") {
                    viewModel.selectedSidebarItem = .settings
                    onFinish()
                }
                Button("Open Doctor") {
                    viewModel.selectedSidebarItem = .diagnostics
                    onFinish()
                }
                Spacer()
                Button("Done") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .task {
            if items.isEmpty {
                await refresh()
            }
        }
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let projectRootPath = viewModel.appSettings.projectsRootPath
        let githubAccount = viewModel.currentGitHubAccount
        items = await SetupDependencyService().loadItems(projectRootPath: projectRootPath, githubAccount: githubAccount)
    }

    private func setupRow(_ item: SetupCheckItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status.systemImage)
                .font(.title3)
                .foregroundStyle(item.status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Text(item.status.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
        }
        .padding(12)
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SetupCheckItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let status: SetupCheckStatus
}

private enum SetupCheckStatus: Hashable {
    case passed
    case warning
    case failed

    var label: String {
        switch self {
        case .passed: "Ready"
        case .warning: "Optional"
        case .failed: "Missing"
        }
    }

    var systemImage: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct SetupDependencyService {
    private let commandRunner = CommandRunner()

    func loadItems(projectRootPath: String, githubAccount: GitHubHostAccount?) async -> [SetupCheckItem] {
        async let pi = piCheck()
        async let rpc = piRPCCheck()
        async let models = modelCheck()
        let project = projectRootCheck(path: projectRootPath)
        let github = githubCheck(account: githubAccount)
        let web = packageCheck(name: "pi-web-access", title: "Web Access Tools", installCommand: "pi install npm:pi-web-access")
        let askUser = packageCheck(name: "pi-ask-user", title: "Ask User Tool", installCommand: "pi install npm:pi-ask-user")

        return await [pi, rpc, models, project, github, web, askUser]
    }

    private func piCheck() async -> SetupCheckItem {
        do {
            let result = try await commandRunner.run("pi", arguments: ["--help"], timeout: 6)
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi CLI",
                detail: result.exitCode == 0 ? "The `pi` executable is available from the user shell." : "`pi --help` exited with code \(result.exitCode).",
                status: result.exitCode == 0 ? .passed : .failed
            )
        } catch {
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi CLI",
                detail: "Install Pi and make sure `pi` is available from your login shell.",
                status: .failed
            )
        }
    }

    private func modelCheck() async -> SetupCheckItem {
        let models = await PiModelDiscoveryService(commandRunner: commandRunner).loadAvailableModels()
        return SetupCheckItem(
            id: "pi-models",
            title: "Pi Models",
            detail: models.isEmpty ? "`pi --list-models` did not return any usable models." : "\(models.count) models are available to Pi Manager.",
            status: models.isEmpty ? .failed : .passed
        )
    }

    private func piRPCCheck() async -> SetupCheckItem {
        do {
            let result = try await commandRunner.run("pi", arguments: ["--mode", "rpc"], timeout: 3)
            return SetupCheckItem(
                id: "pi-rpc",
                title: "Pi Agent RPC Runtime",
                detail: result.exitCode == 0 ? "Pi RPC mode launched and exited cleanly." : "`pi --mode rpc` exited with code \(result.exitCode).",
                status: result.exitCode == 0 ? .passed : .failed
            )
        } catch CommandRunnerError.timedOut {
            return SetupCheckItem(
                id: "pi-rpc",
                title: "Pi Agent RPC Runtime",
                detail: "`pi --mode rpc` launches and stays alive for app-managed sessions.",
                status: .passed
            )
        } catch {
            return SetupCheckItem(
                id: "pi-rpc",
                title: "Pi Agent RPC Runtime",
                detail: "Pi Manager could not launch `pi --mode rpc`.",
                status: .failed
            )
        }
    }

    private func projectRootCheck(path: String) -> SetupCheckItem {
        let isDirectory = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return SetupCheckItem(
            id: "project-root",
            title: "Projects Folder",
            detail: isDirectory ? path : "Choose a folder Pi Manager can scan for projects.",
            status: isDirectory ? .passed : .failed
        )
    }

    private func githubCheck(account: GitHubHostAccount?) -> SetupCheckItem {
        if let account {
            return SetupCheckItem(
                id: "github",
                title: "GitHub",
                detail: "Connected as \(account.login) on \(account.host).",
                status: .passed
            )
        }

        return SetupCheckItem(
            id: "github",
            title: "GitHub",
            detail: "Optional. Install GitHub CLI and run `gh auth login` for issue, comment, commit, and push workflows.",
            status: .warning
        )
    }

    private func packageCheck(name: String, title: String, installCommand: String) -> SetupCheckItem {
        let installed = isPackageInstalled(name)
        return SetupCheckItem(
            id: name,
            title: title,
            detail: installed ? "\(name) is installed." : "Optional Pi extension. Install with `\(installCommand)` if you want this tool in Pi.",
            status: installed ? .passed : .warning
        )
    }

    private func isPackageInstalled(_ name: String) -> Bool {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(name)"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("node_modules/\(name)")
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
