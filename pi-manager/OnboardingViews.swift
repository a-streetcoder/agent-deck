import AppKit
import SwiftUI

#if canImport(TourKit)
import TourKit
#endif

private enum WelcomeTourContent {
    #if canImport(TourKit)
    static var pages: [TourPage] {
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
}

@MainActor
final class WelcomeOnboardingCoordinator: NSObject, NSWindowDelegate {
    static let completedDefaultsKey = "piManagerWelcomeTourCompleted.v1"

    #if canImport(TourKit)
    private let tourController = TourKitWindowController()
    #endif
    private let onComplete: () -> Void
    private let viewModel = AppViewModel()
    private var setupWindow: NSWindow?
    private var setupItemsTask: Task<[SetupCheckItem], Never>?
    private var didComplete = false

    init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
        super.init()
    }

    func start() {
        guard !UserDefaults.standard.bool(forKey: Self.completedDefaultsKey) else { return }
        NSApp.activate(ignoringOtherApps: true)
        preloadSetupChecks()

        #if canImport(TourKit)
        tourController.present(
            pages: WelcomeTourContent.pages,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Check Setup",
            onFinish: { [weak self] in self?.presentSetupCheck() },
            onClose: { [weak self] in self?.completeOnboarding() }
        )
        #else
        presentSetupCheck()
        #endif
    }

    private func presentSetupCheck() {
        let rootView = SetupChecklistView(viewModel: viewModel, preloadedItems: setupItemsTask) { [weak self] in
            self?.completeOnboarding()
        }
        .frame(width: 680, height: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pi Manager"
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    private func preloadSetupChecks() {
        guard setupItemsTask == nil else { return }
        let projectRootPath = viewModel.appSettings.projectsRootPath
        let githubAccount = viewModel.currentGitHubAccount
        setupItemsTask = Task {
            await SetupDependencyService().loadItems(projectRootPath: projectRootPath, githubAccount: githubAccount)
        }
    }

    private func completeOnboarding() {
        guard !didComplete else { return }
        didComplete = true

        #if canImport(TourKit)
        tourController.close()
        #endif

        setupWindow?.delegate = nil
        setupWindow?.close()
        setupWindow = nil

        UserDefaults.standard.set(true, forKey: Self.completedDefaultsKey)
        NSApp.activate(ignoringOtherApps: true)
        onComplete()
    }

    func windowWillClose(_ notification: Notification) {
        completeOnboarding()
    }
}

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
            pages: WelcomeTourContent.pages,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Check Setup",
            onFinish: { phase = .setup },
            onClose: onFinish
        )
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

struct SetupChecklistView: View {
    @ObservedObject var viewModel: AppViewModel
    fileprivate let preloadedItems: Task<[SetupCheckItem], Never>?
    let onFinish: () -> Void
    @State private var items: [SetupCheckItem] = []
    @State private var isRefreshing = true

    fileprivate init(
        viewModel: AppViewModel,
        preloadedItems: Task<[SetupCheckItem], Never>? = nil,
        onFinish: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.preloadedItems = preloadedItems
        self.onFinish = onFinish
    }

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
                    if isRefreshing && items.isEmpty {
                        loadingRow
                    } else {
                        ForEach(items) { item in
                            setupRow(item)
                        }
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
                await loadInitialItems()
            }
        }
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
                Text("Pi Manager is checking Pi, models, project settings, and integrations.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer()
        }
        .padding(12)
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        async let models = modelCheck()
        async let github = githubCheck(account: githubAccount)
        let project = projectRootCheck(path: projectRootPath)
        let web = packageCheck(name: "pi-web-access", title: "Web Access Tools", installCommand: "pi install npm:pi-web-access")
        let askUser = packageCheck(name: "pi-ask-user", title: "Ask User Tool", installCommand: "pi install npm:pi-ask-user")

        return await [pi, models, project, github, web, askUser]
    }

    private func piCheck() async -> SetupCheckItem {
        do {
            let result = try await commandRunner.run("pi", arguments: ["--help"], timeout: 6)
            let supportsRPC = result.stdout.contains("--mode") && result.stdout.contains("rpc")
            return SetupCheckItem(
                id: "pi-cli",
                title: "Pi CLI",
                detail: result.exitCode == 0
                    ? (supportsRPC ? "Pi is installed and supports RPC mode for app-managed sessions." : "Pi is installed, but this version may not support app-managed RPC sessions.")
                    : "`pi --help` exited with code \(result.exitCode).",
                status: result.exitCode == 0 ? (supportsRPC ? .passed : .warning) : .failed
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

    private func projectRootCheck(path: String) -> SetupCheckItem {
        let isDirectory = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return SetupCheckItem(
            id: "project-root",
            title: "Projects Folder",
            detail: isDirectory ? path : "Choose a folder Pi Manager can scan for projects.",
            status: isDirectory ? .passed : .failed
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
