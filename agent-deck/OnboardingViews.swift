import SwiftUI
import TourKit

private enum WelcomeTourContent {
    static var pages: [TourPage] {
        [
            TourPage(
                imageName: "pop-onb-1",
                title: "Command Pi from \(AppBrand.displayName)",
                description: "Run Pi coding sessions from a focused Mac workspace with project context, models, repo activity, and session state in one place."
            ),
            TourPage(
                imageName: "pop-onb-2",
                title: "Work in a Coding Chat",
                description: "Use a customizable chat view built for implementation work: full transcripts, tool calls, file previews, attachments, and live controls."
            ),
            TourPage(
                imageName: "pop-onb-3",
                title: "Orchestrate Subagents",
                description: "Delegate focused work to custom subagents, run them alone or in parallel, supervise decisions, and keep worktrees isolated."
            ),
            TourPage(
                imageName: "pop-onb-4",
                title: "Shape Your Agent System",
                description: "Create, organize, assign, and reuse agents, skills, and prompts so project workflows become clear, portable, and repeatable."
            ),
            TourPage(
                imageName: "pop-onb-5",
                title: "Manage Project Instructions",
                description: "Control system guidance, AGENTS.md, CLAUDE.md, and project-scoped instructions from one place instead of hunting through files."
            ),
            TourPage(
                imageName: "pop-onb-6",
                title: "Connect the Wider Workflow",
                description: "Bring in GitHub, project folders, environment keys, and model setup when you need them. Setup checks confirm the workspace is ready."
            )
        ]
    }
}

struct WelcomeOnboardingSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let onFinish: (SidebarItem?) -> Void
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
                SetupChecklistView(
                    viewModel: viewModel,
                    preloadedItems: setupItemsTask,
                    onBack: { phase = .tour },
                    onFinish: onFinish
                )
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
            onClose: { onFinish(nil) }
        )
        .frame(width: 660)
    }

    private func preloadSetupChecksIfNeeded() {
        guard setupItemsTask == nil else { return }
        let projectRootPath = viewModel.appSettings.projectsRootPath
        let githubAccount = viewModel.currentGitHubAccount
        let selectedProjectPath = viewModel.selectedProjectPath
        let hasConfirmedProjectsRootPath = viewModel.hasConfirmedProjectsRootPath
        let suggestedProjectsRootPath = viewModel.suggestedProjectsRootPath
        setupItemsTask = Task {
            await SetupDependencyService().loadItems(
                projectRootPath: projectRootPath,
                githubAccount: githubAccount,
                selectedProjectPath: selectedProjectPath,
                hasConfirmedProjectsRootPath: hasConfirmedProjectsRootPath,
                suggestedProjectsRootPath: suggestedProjectsRootPath
            )
        }
    }
}

struct SetupChecklistView: View {
    @ObservedObject var viewModel: AppViewModel
    fileprivate let preloadedItems: Task<[SetupCheckItem], Never>?
    let onBack: () -> Void
    let onFinish: (SidebarItem?) -> Void
    @State private var items: [SetupCheckItem] = []
    @State private var isRefreshing = true

    fileprivate init(
        viewModel: AppViewModel,
        preloadedItems: Task<[SetupCheckItem], Never>? = nil,
        onBack: @escaping () -> Void,
        onFinish: @escaping (SidebarItem?) -> Void
    ) {
        self.viewModel = viewModel
        self.preloadedItems = preloadedItems
        self.onBack = onBack
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
                VStack(alignment: .leading, spacing: 12) {
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
                }
                .padding(24)
            }
            .background(AppTheme.windowBackground)

            Divider()
            HStack {
                Button("Back") {
                    onBack()
                }
                Spacer()
                Button(finishButtonTitle) {
                    onFinish(finishTarget)
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
        items.contains { $0.status == .failed }
    }

    private var finishTarget: SidebarItem? {
        if needsDoctor { return .doctor }
        if viewModel.enabledProjects.isEmpty, !viewModel.discoveredProjects.isEmpty { return .projects }
        return nil
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
        items = await SetupDependencyService().loadItems(
            projectRootPath: projectRootPath,
            githubAccount: githubAccount,
            selectedProjectPath: viewModel.selectedProjectPath,
            hasConfirmedProjectsRootPath: viewModel.hasConfirmedProjectsRootPath,
            suggestedProjectsRootPath: viewModel.suggestedProjectsRootPath
        )
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
                if item.status != .passed, item.action != nil || item.secondaryAction != nil {
                    HStack(spacing: 8) {
                        if let action = item.action {
                            Button(action.buttonTitle) { perform(action) }
                        }
                        if let secondaryAction = item.secondaryAction {
                            Button(secondaryAction.buttonTitle) { perform(secondaryAction) }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
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

    private func perform(_ action: SetupCheckAction) {
        switch action {
        case .chooseProjectRoot:
            viewModel.chooseProjectsRootDirectory()
        case .useSuggestedProjectRoot:
            viewModel.useSuggestedProjectsRootDirectory()
        }
        Task { await refresh() }
    }
}

struct SetupCheckItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let status: SetupCheckStatus
    let recovery: String?
    let action: SetupCheckAction?
    let secondaryAction: SetupCheckAction?

    init(
        id: String,
        title: String,
        detail: String,
        status: SetupCheckStatus,
        recovery: String?,
        action: SetupCheckAction? = nil,
        secondaryAction: SetupCheckAction? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.recovery = recovery
        self.action = action
        self.secondaryAction = secondaryAction
    }
}

enum SetupCheckAction: Hashable {
    case chooseProjectRoot
    case useSuggestedProjectRoot

    var buttonTitle: String {
        switch self {
        case .chooseProjectRoot: "Choose Folder…"
        case .useSuggestedProjectRoot: "Use Suggested Folder"
        }
    }
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
        case .warning: "circle.dashed"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: .green
        case .warning: .secondary
        case .failed: .red
        }
    }
}

struct SetupDependencyService {
    private let commandRunner = CommandRunner()

    func loadItems(
        projectRootPath: String,
        githubAccount: GitHubHostAccount?,
        selectedProjectPath: String?,
        hasConfirmedProjectsRootPath: Bool = true,
        suggestedProjectsRootPath: String? = nil
    ) async -> [SetupCheckItem] {
        async let pi = piCheck()
        async let models = modelCheck()
        let github = await githubCheck(account: githubAccount)
        let project = projectRootCheck(path: projectRootPath, isConfirmed: hasConfirmedProjectsRootPath, suggestedPath: suggestedProjectsRootPath)
        let web = webAccessCheck(projectRootPath: selectedProjectPath ?? projectRootPath)

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

    private func projectRootCheck(path: String, isConfirmed: Bool, suggestedPath: String?) -> SetupCheckItem {
        let isDirectory = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let hasSuggestedDirectory = suggestedPath?.isEmpty == false

        if !isConfirmed {
            return SetupCheckItem(
                id: "project-root",
                title: "Projects Root Folder",
                detail: hasSuggestedDirectory
                    ? "Choose the parent folder that contains your projects, not a single project repository. Suggested: \(suggestedPath!)"
                    : "Choose the parent folder that contains your projects, not a single project repository.",
                status: .failed,
                recovery: nil,
                action: hasSuggestedDirectory ? .useSuggestedProjectRoot : .chooseProjectRoot,
                secondaryAction: hasSuggestedDirectory ? .chooseProjectRoot : nil
            )
        }

        return SetupCheckItem(
            id: "project-root",
            title: "Projects Root Folder",
            detail: isDirectory ? path : "Choose the parent folder that contains your projects, not a single project repository.",
            status: isDirectory ? .passed : .failed,
            recovery: isDirectory ? nil : "Choose an existing parent folder for your projects.",
            action: isDirectory ? nil : .chooseProjectRoot
        )
    }

    private func webAccessCheck(projectRootPath: String?) -> SetupCheckItem {
        let projectRoot = projectRootPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectRoot)
        let hasKey = environment["EXA_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let fallbackInstalled = WebFetchDependencyService().status().isInstalled

        if hasKey {
            return SetupCheckItem(
                id: "web-access",
                title: "Web Access",
                detail: "EXA_API_KEY is configured. Exa web tools are available to new Pi sessions.",
                status: .passed,
                recovery: nil
            )
        }

        if fallbackInstalled {
            return SetupCheckItem(
                id: "web-access",
                title: "Web Access",
                detail: "Optional. URL fetch fallback dependencies are installed. Configure Exa search later in Doctor if you want web search.",
                status: .warning,
                recovery: nil
            )
        }

        return SetupCheckItem(
            id: "web-access",
            title: "Web Access",
            detail: "Optional. Configure Exa search or install the URL fetch fallback later in Doctor.",
            status: .warning,
            recovery: nil
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
