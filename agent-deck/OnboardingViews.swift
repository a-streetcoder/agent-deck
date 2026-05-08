import SwiftUI
import TourKit

private enum WelcomeTourContent {
    static var pages: [TourPage] {
        [
            TourPage(
                imageName: "pi",
                title: "Welcome to \(AppBrand.displayName)",
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
}

struct WelcomeOnboardingSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let onFinish: (Bool) -> Void
    @State private var phase: Phase = .tour
    @State private var setupItemsTask: Task<[SetupCheckItem], Never>?

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
                SetupChecklistView(viewModel: viewModel, preloadedItems: setupItemsTask, onFinish: onFinish)
            }
        }
        .task {
            preloadSetupChecksIfNeeded()
        }
    }

    private var tourView: some View {
        TourSlideshowView(
            pages: WelcomeTourContent.pages,
            width: 660,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Check Setup",
            onFinish: { phase = .setup },
            onClose: { onFinish(false) }
        )
        .frame(width: 660)
    }

    private func preloadSetupChecksIfNeeded() {
        guard setupItemsTask == nil else { return }
        let projectRootPath = viewModel.appSettings.projectsRootPath
        let githubAccount = viewModel.currentGitHubAccount
        setupItemsTask = Task {
            await SetupDependencyService().loadItems(projectRootPath: projectRootPath, githubAccount: githubAccount)
        }
    }
}

struct SetupChecklistView: View {
    @ObservedObject var viewModel: AppViewModel
    fileprivate let preloadedItems: Task<[SetupCheckItem], Never>?
    let onFinish: (Bool) -> Void
    @State private var items: [SetupCheckItem] = []
    @State private var isRefreshing = true

    fileprivate init(
        viewModel: AppViewModel,
        preloadedItems: Task<[SetupCheckItem], Never>? = nil,
        onFinish: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.preloadedItems = preloadedItems
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup Check")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("\(AppBrand.displayName) works best after these checks pass.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 28)
                }
                .buttonStyle(.borderless)
                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(isRefreshing)
                .help("Refresh setup checks")
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if isRefreshing && items.isEmpty {
                        loadingRow
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            setupRow(item)
                            if index < items.count - 1 {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                }
                .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.contentStroke, lineWidth: 1)
                )
                .padding(24)
            }
            .background(AppTheme.windowBackground)

            Divider()
            HStack {
                Spacer()
                Button(finishButtonTitle) {
                    onFinish(needsDoctor)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 660, height: 560)
        .background(AppTheme.windowBackground)
        .task {
            if items.isEmpty {
                await loadInitialItems()
            }
        }
    }

    private var needsDoctor: Bool {
        items.contains { $0.status != .passed }
    }

    private var finishButtonTitle: String {
        needsDoctor ? "Review Setup" : "Done"
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text("Checking setup")
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text("\(AppBrand.displayName) is checking Pi, models, project settings, and integrations.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @MainActor
    private func loadInitialItems() async {
        isRefreshing = true
        if let preloadedItems {
            items = await preloadedItems.value
            isRefreshing = false
            return
        }
        await refresh()
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
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.status.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.status.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = item.recovery, item.status != .passed {
                    Text(recovery)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            Text(item.status.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(item.status.color)
                .background(Capsule(style: .continuous).fill(item.status.color.opacity(0.12)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct SetupCheckItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let status: SetupCheckStatus
    let recovery: String?
}

enum SetupCheckStatus: Hashable {
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

struct SetupDependencyService {
    private let commandRunner = CommandRunner()

    func loadItems(projectRootPath: String, githubAccount: GitHubHostAccount?) async -> [SetupCheckItem] {
        async let pi = piCheck()
        async let models = modelCheck()
        async let github = githubCheck(account: githubAccount)
        let project = projectRootCheck(path: projectRootPath)
        let web = packageCheck(name: "pi-web-access", title: "Web Access Tools", installCommand: "pi install npm:pi-web-access")

        return await [pi, models, project, github, web]
    }

    private func piCheck() async -> SetupCheckItem {
        do {
            let result = try await commandRunner.run("pi", arguments: ["--help"], timeout: 6)
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi CLI",
                detail: result.exitCode == 0
                    ? "Pi is installed and available to \(AppBrand.displayName)."
                    : "`pi --help` exited with code \(result.exitCode).",
                status: result.exitCode == 0 ? .passed : .failed,
                recovery: result.exitCode == 0 ? nil : "Install Pi, then verify `pi --help` works in Terminal."
            )
        } catch {
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi CLI",
                detail: "Install Pi and make sure `pi` is available from your login shell.",
                status: .failed,
                recovery: "Install Pi, then verify `pi --help` works in Terminal."
            )
        }
    }

    private func modelCheck() async -> SetupCheckItem {
        let models = await PiModelDiscoveryService(commandRunner: commandRunner).loadAvailableModels()
        if !models.isEmpty {
            return SetupCheckItem(
                id: "pi-models",
                title: "Pi Models",
                detail: "\(models.count) models are available to \(AppBrand.displayName).",
                status: .passed,
                recovery: nil
            )
        }

        do {
            let result = try await commandRunner.run("pi", arguments: ["--list-models"], timeout: 20)
            let modelRowCount = Self.modelRowCount(fromPiListOutput: result.stdout)
            if result.exitCode == 0, modelRowCount > 0 {
                return SetupCheckItem(
                    id: "pi-models",
                    title: "Pi Models",
                    detail: "\(modelRowCount) model rows were returned by `pi --list-models`.",
                    status: .passed,
                    recovery: nil
                )
            }
            return SetupCheckItem(
                id: "pi-models",
                title: "Pi Models",
                detail: "`pi --list-models` exited with code \(result.exitCode) and did not return usable models.",
                status: .failed,
                recovery: "Run `pi --list-models` in Terminal and complete any provider/model setup Pi reports."
            )
        } catch {
            return SetupCheckItem(
                id: "pi-models",
                title: "Pi Models",
                detail: "`pi --list-models` did not return any usable models.",
                status: .failed,
                recovery: "Run `pi --list-models` in Terminal and complete any provider/model setup Pi reports."
            )
        }
    }

    private func projectRootCheck(path: String) -> SetupCheckItem {
        let isDirectory = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return SetupCheckItem(
            id: "project-root",
            title: "Projects Folder",
            detail: isDirectory ? path : "Choose a folder \(AppBrand.displayName) can scan for projects.",
            status: isDirectory ? .passed : .failed,
            recovery: isDirectory ? nil : "Open Settings > Projects and choose an existing projects folder."
        )
    }

    private func githubCheck(account: GitHubHostAccount?) async -> SetupCheckItem {
        let resolvedAccount: GitHubHostAccount?
        if let account {
            resolvedAccount = account
        } else {
            resolvedAccount = await GitHubCLIAuthService(commandRunner: commandRunner).loadStatus().account
        }

        if let resolvedAccount {
            return SetupCheckItem(
                id: "github",
                title: "GitHub",
                detail: "Connected as \(resolvedAccount.login) on \(resolvedAccount.host).",
                status: .passed,
                recovery: nil
            )
        }

        return SetupCheckItem(
            id: "github",
            title: "GitHub",
            detail: "Optional. Install GitHub CLI and run `gh auth login` for issue, comment, commit, and push workflows.",
            status: .warning,
            recovery: "Install GitHub CLI, run `gh auth login`, then refresh this check."
        )
    }

    private func packageCheck(name: String, title: String, installCommand: String) -> SetupCheckItem {
        let installed = isPackageInstalled(name)
        return SetupCheckItem(
            id: name,
            title: title,
            detail: installed ? "\(name) is installed." : "Optional Pi extension. Install with `\(installCommand)` if you want this tool in Pi.",
            status: installed ? .passed : .warning,
            recovery: installed ? nil : installCommand
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

    private static func modelRowCount(fromPiListOutput text: String) -> Int {
        text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .filter { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.count >= 2
            }
            .count
    }
}
