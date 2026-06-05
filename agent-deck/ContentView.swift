import AppKit
import SwiftUI


extension View {
    func bottomEdgeFade(height: CGFloat = 36) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
            }
        }
    }
}

extension View {
    func transcriptEdgeFade(height: CGFloat = 28) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
                Rectangle()
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
            }
        }
    }

    /// Hides the native macOS scroller for the nearest enclosing `NSScrollView`.
    /// `.scrollIndicators(.hidden)` is unreliable for `List` — especially when the
    /// system "Show scroll bars" preference is set to "Always" — so we reach down
    /// to AppKit to guarantee no scrollers anywhere in the app.
    func hideNativeScrollers() -> some View {
        background(ScrollerHidingConfigurator())
    }
}

private struct ScrollerHidingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerHidingProbe {
        ScrollerHidingProbe()
    }

    func updateNSView(_ nsView: ScrollerHidingProbe, context: Context) {
        nsView.suppressScrollers()
    }
}

/// A scroller that occupies zero width and never draws. Installed onto a
/// `List`'s `NSScrollView`, it makes the scroll indicator permanently invisible
/// without fighting SwiftUI: `List` re-toggles `hasVerticalScroller` on every
/// layout pass, but the scroller it toggles is this one — nothing to show.
private final class HiddenScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        0
    }

    override func draw(_ dirtyRect: NSRect) {
        // Intentionally empty — the scroller renders nothing.
    }
}

/// A zero-cost probe inserted via `.background(...)`. It locates the sibling
/// `NSScrollView` it is layered behind — by matching frames window-wide, since
/// SwiftUI does not make the scroll view a reachable ancestor — and swaps in
/// `HiddenScroller`s. Once swapped, the scrollers stay hidden permanently
/// regardless of how `List` re-renders, so there is no visible "fighting".
/// Sets the host `NSWindow`'s background color so the theme's canvas shows through
/// the app's transparent surfaces (the native transcript and the detail scroll
/// views draw no background of their own). SwiftUI's `.background(Color)` only fills
/// the view's own rect, not the window chrome/gaps — this reaches the window. Also
/// makes the titlebar transparent so the unified toolbar shows the themed window
/// background instead of the system's gray titlebar material.
struct WindowBackgroundApplier: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view, color: NSColor(color))
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView, color: NSColor(color))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Themes the window canvas and keeps the toolbar dark in fullscreen.
    ///
    /// In a normal window we make the titlebar transparent so the unified toolbar
    /// shows the themed (navy) window background instead of the system material.
    /// But macOS 26's toolbar background is translucent Liquid Glass: a transparent
    /// titlebar removes the solid dark backing the glass needs, and in native
    /// fullscreen — where the toolbar lives in its own window with no app content
    /// behind it — the glass then renders bright (a white strip).
    ///
    /// NetNewsWire's main window avoids this by never making the titlebar
    /// transparent, so the solid dark titlebar material is always there. We want the
    /// themed blend in windowed mode, so we only drop the transparency in
    /// fullscreen: the solid dark material returns as the glass's backing — no white.
    /// `titlebarAppearsTransparent` is pure window chrome, so toggling it neither
    /// flattens the toolbar's glass islands nor shifts the split-view layout.
    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var color: NSColor = .windowBackgroundColor

        deinit { NotificationCenter.default.removeObserver(self) }

        func attach(to view: NSView, color: NSColor) {
            self.color = color
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = view.window else { return }
                window.backgroundColor = color
                if window !== self.window {
                    self.window = window
                    let center = NotificationCenter.default
                    center.removeObserver(self)
                    center.addObserver(self, selector: #selector(self.fullScreenChanged),
                                       name: NSWindow.didEnterFullScreenNotification, object: window)
                    center.addObserver(self, selector: #selector(self.fullScreenChanged),
                                       name: NSWindow.didExitFullScreenNotification, object: window)
                }
                self.updateTitlebarTransparency(window)
            }
        }

        @objc private func fullScreenChanged(_ note: Notification) {
            guard let window = note.object as? NSWindow else { return }
            updateTitlebarTransparency(window)
        }

        /// Transparent (themed blend) when windowed; opaque (solid dark backing,
        /// so the Liquid Glass toolbar never goes white) when fullscreen.
        private func updateTitlebarTransparency(_ window: NSWindow) {
            window.titlebarAppearsTransparent = !window.styleMask.contains(.fullScreen)
        }
    }
}

/// Covers the ENTIRE window — titlebar and toolbar included — with the launch
/// splash, then fades it out once `isActive` flips false.
///
/// A normal SwiftUI `.overlay` only reaches the window's content region; the
/// `NavigationSplitView` toolbar lives in the titlebar *above* that, so it would
/// stay visible and clickable through the splash. We cover everything with a
/// chromeless **child window** ordered above the main window — titled (so macOS
/// rounds its corners to match the host) but stripped of all titlebar chrome. (An
/// earlier version
/// parented the splash into the window's private `NSThemeFrame`, which worked but
/// made AppKit log `_didAddUnknownSubview` every launch and is flagged "may break
/// in the future." A child window is the supported way to overlay the
/// titlebar/traffic-lights and swallow all interaction.)
struct AppInitialLoadWindowCover: NSViewRepresentable {
    /// Master switch for the launch splash. Flip to `false` to disable it — the
    /// workspace usually loads fast enough that the splash isn't strictly needed.
    static let isEnabled = true

    var isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let anchor = AnchorView()
        anchor.coordinator = context.coordinator
        anchor.active = isActive
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let anchor = nsView as? AnchorView else { return }
        anchor.active = isActive
        // Synchronous so the dismissal animation starts in the same frame the
        // refresh completes — no async hop.
        context.coordinator.sync(active: isActive, anchor: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Installs the cover the instant it enters the window — before the window's
    /// first paint — so the splash is the first thing on screen, never a flash of
    /// the app followed by the overlay.
    final class AnchorView: NSView {
        weak var coordinator: Coordinator?
        var active = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            coordinator?.sync(active: active, anchor: self)
        }
    }

    final class Coordinator {
        /// Chromeless titled child window that overlays the whole main window.
        private var coverWindow: NSWindow?
        /// Parent-window frame observers, removed on dismiss. Child windows track
        /// the parent's *moves* automatically but not its *resizes*, so we mirror
        /// the frame on both to stay aligned (matters if a restore/resize lands
        /// while the splash is up).
        private var frameObservers: [NSObjectProtocol] = []
        /// When the cover became visible, so a too-fast launch still shows the
        /// splash for at least `minimumOnScreen` before it fades.
        private var shownAt: Date?
        private let minimumOnScreen: TimeInterval = 1.0
        /// Failsafe: the cover blocks the *entire* window — toolbar and the
        /// traffic-light close/minimize buttons included. If the initial refresh
        /// never reports complete (an unforeseen hang or error path that skips
        /// `hasCompletedInitialRefresh`), force the splash away anyway so the user
        /// is never locked out of their own window. A loading splash must never be
        /// able to trap the UI.
        private let maximumOnScreen: TimeInterval = 12.0

        func sync(active: Bool, anchor: NSView, retries: Int = 12) {
            guard let parent = anchor.window,
                  parent.frame.width > 1, parent.frame.height > 1 else {
                // The window may not exist yet on the very first launch pass.
                if active && retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak anchor] in
                        guard let anchor else { return }
                        self.sync(active: active, anchor: anchor, retries: retries - 1)
                    }
                }
                return
            }

            if active {
                guard coverWindow == nil else { return }
                let host = NSHostingView(rootView: AppInitialLoadOverlay())
                // A non-activating *titled* panel. Titled is the key choice: the
                // window server rounds titled windows' corners — content included —
                // at the exact OS radius, so the splash matches the host window's
                // rounding with no hardcoded value to drift across macOS versions.
                // (A `.borderless` panel is the one kind macOS does NOT round, which
                // is why the full-bleed material was painting a bare rectangle.)
                // `.fullSizeContentView` lets the overlay fill the titlebar region
                // too; `.nonactivatingPanel` keeps it from stealing key/main and
                // logging a `makeKeyWindow` warning.
                let window = NSPanel(
                    contentRect: parent.frame,
                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                window.isFloatingPanel = false
                window.level = .normal
                window.hidesOnDeactivate = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = false // swallow clicks so nothing leaks through
                // Titled windows are draggable by their titlebar, and with a
                // transparent full-size titlebar that makes the WHOLE splash a drag
                // handle — dragging would slide the cover off the parent (the frame
                // sync only mirrors parent→cover) and reveal the UI underneath. Pin
                // it so it can't be moved independently.
                window.isMovable = false
                window.isMovableByWindowBackground = false
                // Strip every scrap of titlebar chrome so only the splash shows.
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.contentView = host
                window.setFrame(parent.frame, display: true)
                parent.addChildWindow(window, ordered: .above)
                coverWindow = window
                shownAt = Date()
                installFrameSync(parent: parent, cover: window)
                // Hard ceiling — dismiss no matter what `active` ever reports.
                DispatchQueue.main.asyncAfter(deadline: .now() + maximumOnScreen) { [weak self] in
                    self?.dismiss()
                }
            } else if coverWindow != nil {
                // Keep the splash up for its minimum, then fade. Re-dispatch rather
                // than dismiss now if the refresh beat the floor.
                let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? minimumOnScreen
                let remaining = minimumOnScreen - elapsed
                if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak anchor] in
                        guard let anchor else { return }
                        self.sync(active: false, anchor: anchor)
                    }
                    return
                }
                dismiss()
            }
        }

        private func installFrameSync(parent: NSWindow, cover: NSWindow) {
            let center = NotificationCenter.default
            let mirror: @Sendable (Notification) -> Void = { [weak parent, weak cover] _ in
                MainActor.assumeIsolated {
                    guard let parent, let cover else { return }
                    cover.setFrame(parent.frame, display: false)
                }
            }
            frameObservers = [
                center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main, using: mirror),
                center.addObserver(forName: NSWindow.didMoveNotification, object: parent, queue: .main, using: mirror)
            ]
        }

        private func removeFrameSync() {
            let center = NotificationCenter.default
            frameObservers.forEach(center.removeObserver)
            frameObservers.removeAll()
        }

        private func dismiss() {
            guard let window = coverWindow else { return }
            coverWindow = nil
            shownAt = nil
            removeFrameSync()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                window.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    window.parent?.removeChildWindow(window)
                    window.orderOut(nil)
                }
            }
        }
    }
}

final class ScrollerHidingProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressScrollers()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        suppressScrollers()
    }

    func suppressScrollers() {
        // The target scroll view may not be laid out yet on the first pass, so
        // retry across the next few runloop turns until it turns up.
        for delay in [0.0, 0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applySuppression()
            }
        }
    }

    private func applySuppression() {
        guard let scrollView = targetScrollView() else { return }
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is HiddenScroller) {
            scrollView.verticalScroller = HiddenScroller()
        }
        if !(scrollView.horizontalScroller is HiddenScroller) {
            scrollView.horizontalScroller = HiddenScroller()
        }
    }

    /// Among every scroll view in the window, pick the smallest one that covers
    /// most of this probe — that is the list/scroll view we are layered behind.
    private func targetScrollView() -> NSScrollView? {
        guard let contentView = window?.contentView else { return nil }
        let probe = convert(bounds, to: nil)
        let probeArea = probe.width * probe.height
        guard probeArea > 1 else { return nil }

        var best: NSScrollView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        var stack: [NSView] = [contentView]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let scrollView = view as? NSScrollView else { continue }
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let overlap = frame.intersection(probe)
            guard overlap.width * overlap.height >= probeArea * 0.6 else { continue }
            let area = frame.width * frame.height
            if area < bestArea {
                bestArea = area
                best = scrollView
            }
        }
        return best
    }
}

extension View {
    func toolbarNeutralChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .tint(.primary)
    }

    /// Primary create/`+` actions. `.tint` drives the brand-coloured glyph and
    /// the tinted hover/press highlight. `.menuStyle(.button)` makes a `Menu`
    /// render as a push button so its hover highlight matches a plain `Button`
    /// — a toolbar `Menu` is a pulldown and otherwise draws a different
    /// highlight. It is a harmless no-op on `Button`s.
    func toolbarPrimaryActionChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(AppTheme.brandAccent)
            .tint(AppTheme.brandAccent)
            .menuStyle(.button)
    }
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppViewModel.self) private var viewModel
    @State private var agentDraft: AgentEditorDraft?
    @State private var editingAgent: EffectiveAgentRecord?
    @State private var envDraft: EnvEditorDraft?
    @State private var projectFilterText = ""
    @State private var debouncedProjectFilterText = ""
    @State private var agentSearchText = ""
    @State private var issueSearchText = ""
    @State private var memorySearchText = ""
    @State private var projectSearchText = ""
    @State private var skillSearchText = ""
    @State private var promptSearchText = ""
    @State private var piAgentSessionSearchText = ""
    @State private var isMemoryInfoPresented = false
    @State private var isSkillsInfoPresented = false
    @State private var isSubagentsInfoPresented = false
    @State private var isEnvironmentInfoPresented = false
    @State private var isModelsInfoPresented = false
    @State private var showingEnableAllProjectsAlert = false
    @State private var showingDisableAllProjectsAlert = false
    @State private var showingPiAgentDeleteAlert = false
    @State private var isPiAgentTranscriptOptionsPresented = false
    @State private var isPiAgentStartupResourcesPresented = false
    @State private var isPiAgentSystemPromptPresented = false
    @State private var isPiAgentSubagentsPopoverPresented = false
    @State private var navigationColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var agentModelQuickEditor: AgentModelQuickEditorContext?
    @State private var commandContext = AgentDeckCommandContext()
    @State private var isIssuesFilterPopoverPresented = false
    @State private var isAgentsFilterPopoverPresented = false
    #if DEBUG
    /// Flip to `true` when testing onboarding.
    private static let forceOnboardingOnLaunch = false
    #endif

    @State private var isOnboardingPresented: Bool = {
        #if DEBUG
        if ContentView.forceOnboardingOnLaunch { return true }
        #endif
        return !UserDefaults.standard.bool(forKey: "agentDeckWelcomeTourCompleted.v1")
    }()

    var body: some View {
        mainContent
            // One calm loading state on launch instead of each pane (and the
            // background project/agent/skill/gh refresh) flickering in piecemeal.
            // Installed at the window level so it covers the whole window —
            // titlebar and toolbar included — and blocks interaction underneath.
            // Suppressed during first-run onboarding so a brand-new user lands
            // straight on the welcome flow instead of watching the splash fade out
            // behind it. `isOnboardingPresented` is driven by the persisted
            // completion flag, so quitting mid-onboarding and relaunching keeps the
            // splash skipped until onboarding is actually finished.
            .background(AppInitialLoadWindowCover(
                isActive: AppInitialLoadWindowCover.isEnabled
                    && !isOnboardingPresented
                    && !viewModel.hasCompletedInitialRefresh))
            .sheet(isPresented: $isOnboardingPresented, onDismiss: completeOnboarding) {
                WelcomeOnboardingSheet(viewModel: viewModel) { target in
                    if let target {
                        viewModel.selectedSidebarItem = target
                    }
                    completeOnboarding()
                }
            }
    }

    private var sidebarWarningSnapshot: [SidebarItem: Bool] {
        guard viewModel.hasCompletedInitialRefresh else { return [:] }
        return [
            .projects: viewModel.shouldWarnProjectSelection,
            .agents: viewModel.hasAgentWarnings,
            .skills: viewModel.hasSkillWarnings,
            .prompts: viewModel.hasPromptWarnings,
            .doctor: viewModel.shouldWarnDoctor
        ]
    }

    @ViewBuilder
    private var mainContent: some View {
        let warnings = sidebarWarningSnapshot
        NavigationSplitView(columnVisibility: $navigationColumnVisibility) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    ForEach(AppBrand.titleWords, id: \.self) { word in
                        Text(word)
                            .font(AppFonts.kemcoPixelBold(size: 18))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)

                sidebarSectionsList(warnings: warnings)

                Spacer(minLength: 0)

                SidebarProjectGitHubCard(
                    viewModel: viewModel,
                    projects: filteredProjects,
                    selectedProject: selectedProject,
                    selectedProjectPath: viewModel.selectedProjectPath,
                    filterText: $projectFilterText,
                    isSearchDebouncing: projectFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedProjectFilterText,
                    onSelectProject: { viewModel.setSelectedProject($0?.url) },
                    onChooseProject: { viewModel.chooseProjectRoot() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.7)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    SidebarBottomBar(viewModel: viewModel)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                }
                .background {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: AppTheme.brandAccent.opacity(0.22), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(viewModel.selectedSidebarItem == .agent ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.25), value: viewModel.selectedSidebarItem)
                }
            }
            .frame(minWidth: 240)
            .background(Color.clear, ignoresSafeAreaEdges: .all)
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
            .perfScene("Sidebar")
        } detail: {
            detailSplitView
                .perfScene("Detail")
        }
        .frame(minWidth: 1180, minHeight: 700)
        .navigationTitle(toolbarTitle)
        // Theme the window canvas itself — the transcript and detail scroll views are
        // transparent, so without this they'd show the system (gray) window background
        // instead of the active theme's. Re-applies on theme switch via the root .id.
        .background(WindowBackgroundApplier(color: AppTheme.windowBackground))
        .background(AgentDeckCommandsScope(context: commandContext).equatable())
        .onAppear(perform: updateCommandContext)
        // .task(id:) cancels and restarts asynchronously after body settles, so at most
        // one `updateCommandContext()` call lands per render frame.
        .task(id: commandContextUpdateToken) { updateCommandContext() }
        .onChange(of: viewModel.selectedSidebarItem) { _, newValue in
            handleSidebarSelectionChange(newValue)
        }
        // Tapping an injected memory title in a transcript recall card posts this;
        // handled here (always alive) since it switches the sidebar to Memory.
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckOpenMemoryRequested)) { note in
            if let id = note.userInfo?["id"] as? String {
                viewModel.openMemory(byID: id)
            }
        }
        .alert("Enable all projects?", isPresented: $showingEnableAllProjectsAlert) {
            Button("Enable All") { viewModel.setAllProjectsEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will enable every project currently in \(AppBrand.displayName).")
        }
        .alert("Disable all projects?", isPresented: $showingDisableAllProjectsAlert) {
            Button("Disable All", role: .destructive) { viewModel.setAllProjectsEnabled(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disable every project currently in \(AppBrand.displayName) and clear the active project selection.")
        }
        .alert("Delete Pi Agent session?", isPresented: $showingPiAgentDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let session = viewModel.piAgentSessionStore.selectedSession {
                    viewModel.deletePiAgentSession(session.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName).")
        }
        .toolbar { mainToolbarContent }
        // Detect the selected project's dev-server commands off the render path
        // so the toolbar control can hide for projects that have none.
        .task(id: viewModel.piAgentSessionStore.selectedSession?.projectPath) {
            if let path = viewModel.piAgentSessionStore.selectedSession?.projectPath {
                viewModel.projectServerService.refreshDetectedCommands(forProjectPath: path)
            }
        }
        .task(id: projectFilterText) {
            let trimmed = projectFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedProjectFilterText = trimmed.lowercased()
        }
        .sheet(item: $agentDraft) { draft in
            AgentEditorSheet(
                draft: draft,
                availableTools: viewModel.availableToolNames(for: draft.target),
                availableSkills: viewModel.availableSkillNames(for: draft.target),
                availableModels: viewModel.enabledAvailableModels,
                modelsLastUpdatedAt: viewModel.modelsLastUpdatedAt,
                onCancel: {
                    agentDraft = nil
                    editingAgent = nil
                },
                onSave: { updated in
                    if let editingAgent {
                        try viewModel.saveAgentDraft(updated, for: editingAgent)
                    } else {
                        try viewModel.saveNewAgentDraft(updated)
                    }
                    agentDraft = nil
                    self.editingAgent = nil
                }
            )
        }
        .sheet(item: $agentModelQuickEditor) { context in
            AgentModelQuickEditorSheet(
                context: context,
                availableModels: viewModel.enabledAvailableModels,
                modelsLastUpdatedAt: viewModel.modelsLastUpdatedAt,
                makeDraft: { agent in
                    viewModel.makeAgentDraft(for: agent, preferredOverrideScope: context.preferredOverrideScope)
                },
                onSaveAll: { pairs in
                    try viewModel.saveAgentDrafts(pairs)
                }
            )
        }
        .sheet(item: $envDraft) { draft in
            EnvEditorSheet(
                draft: draft,
                projectRoot: viewModel.selectedProjectPath,
                onCancel: { envDraft = nil },
                onSave: { drafts in
                    try viewModel.saveEnvDrafts(drafts)
                    envDraft = nil
                }
            )
        }
    }

    private func completeOnboarding() {
        #if DEBUG
        if ContentView.forceOnboardingOnLaunch {
            isOnboardingPresented = false
            return
        }
        #endif
        guard isOnboardingPresented || !UserDefaults.standard.bool(forKey: "agentDeckWelcomeTourCompleted.v1") else {
            return
        }
        UserDefaults.standard.set(true, forKey: "agentDeckWelcomeTourCompleted.v1")
        isOnboardingPresented = false
    }

    @ViewBuilder
    private var detailSplitView: some View {
        if toolbarSearchIsVisible {
            detailSplitContent
                .searchable(text: toolbarSearchBinding, placement: .toolbar, prompt: toolbarSearchPrompt)
        } else {
            detailSplitContent
        }
    }

    private var detailSplitContent: some View {
        detailView
            .frame(minWidth: viewModel.selectedSidebarItem == .agent ? 560 : 500, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbarSearchIsVisible: Bool {
        switch viewModel.selectedSidebarItem {
        case .projects, .agents, .issues, .memory, .skills, .prompts, .agent:
            return true
        default:
            return false
        }
    }

    private var toolbarSearchPrompt: String {
        switch viewModel.selectedSidebarItem {
        case .projects: return "Search projects"
        case .agents: return "Search agents"
        case .issues: return "Search issues"
        case .memory: return "Search memories"
        case .skills: return "Search skills"
        case .prompts: return "Search prompts"
        case .agent: return "Search sessions"
        default: return "Search"
        }
    }

    private var toolbarSearchBinding: Binding<String> {
        Binding(
            get: {
                switch viewModel.selectedSidebarItem {
                case .projects: return projectSearchText
                case .agents: return agentSearchText
                case .issues: return issueSearchText
                case .memory: return memorySearchText
                case .skills: return skillSearchText
                case .prompts: return promptSearchText
                case .agent: return piAgentSessionSearchText
                default: return ""
                }
            },
            set: { value in
                switch viewModel.selectedSidebarItem {
                case .projects: projectSearchText = value
                case .agents: agentSearchText = value
                case .issues: issueSearchText = value
                case .memory: memorySearchText = value
                case .skills: skillSearchText = value
                case .prompts: promptSearchText = value
                case .agent: piAgentSessionSearchText = value
                default: break
                }
            }
        )
    }

    private var commandContextUpdateToken: String {
        let selectedSession = viewModel.piAgentSessionStore.selectedSession
        let selectedSessionID = selectedSession?.id
        let selectedSessionIsRunning = selectedSessionID.map { viewModel.isPiAgentSessionRunning($0) } ?? false
        let commitMessage = viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGitProject = viewModel.selectedDiscoveredProject?.isGitRepository == true
        let selectedPrompt = viewModel.selectedPromptTemplate
        let selectedAgent = viewModel.selectedAgent
        return [
            viewModel.selectedSidebarItem.id,
            selectedSessionID?.uuidString ?? "nil",
            String(selectedSessionIsRunning),
            String(viewModel.canOpenSelectedPiAgentSessionInTerminal),
            commitMessage,
            String(viewModel.githubIsCommitting),
            String(viewModel.githubIsPushing),
            String(hasGitProject),
            String(viewModel.discoveredProjects.count),
            selectedPrompt?.id ?? "nil",
            selectedAgent?.id ?? "nil",
            String(selectedAgent?.resolved.disabled ?? false),
            selectedAgentFilePath ?? "nil"
        ].joined(separator: "|")
    }

    private func updateCommandContext() {
        let selectedSession = viewModel.piAgentSessionStore.selectedSession
        let selectedSessionID = selectedSession?.id
        let selectedSessionIsRunning = selectedSessionID.map { viewModel.isPiAgentSessionRunning($0) } ?? false
        let commitMessage = viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGitProject = viewModel.selectedDiscoveredProject?.isGitRepository == true
        let selectedPrompt = viewModel.selectedPromptTemplate
        let selectedAgent = viewModel.selectedAgent
        let selectedAgentPath = selectedAgentFilePath
        let promptsAreVisible = viewModel.selectedSidebarItem == .prompts

        // Mutate the existing `@State` context in place — `AgentDeckCommandContext`
        // is `@Observable`, so the menu `Commands` body's `@FocusedValue` reader
        // re-renders via observation when individual properties change. The stable
        // reference is also what lets `AgentDeckCommandsScope` short-circuit re-renders
        // via `Equatable` identity comparison.
        let ctx = commandContext

        ctx.canCreatePiAgentSession = true
        ctx.canCreateAgent = true
        ctx.canDeletePiAgentSession = selectedSession != nil
        ctx.canStopPiAgentSession = selectedSessionIsRunning
        ctx.canNavigatePiAgentSessions = viewModel.canNavigatePiAgentSessions
        ctx.canOpenPiAgentInTerminal = viewModel.canOpenSelectedPiAgentSessionInTerminal
        ctx.canCommitGitHubChanges = hasGitProject && !commitMessage.isEmpty && !viewModel.githubIsCommitting
        ctx.canPushGitHubBranch = hasGitProject && !viewModel.githubIsPushing
        ctx.canEnableAllProjects = !viewModel.discoveredProjects.isEmpty
        ctx.canDisableAllProjects = !viewModel.discoveredProjects.isEmpty
        ctx.canAddProject = true
        ctx.canImportSkills = true
        ctx.canCreatePrompt = true
        ctx.canCopyPromptInvocation = promptsAreVisible && selectedPrompt != nil
        ctx.canOpenPromptFile = promptsAreVisible && selectedPrompt != nil
        ctx.canRevealPromptFile = promptsAreVisible && selectedPrompt != nil
        ctx.canOpenSelectedAgentFile = selectedAgentPath != nil
        ctx.canRevealSelectedAgentFile = selectedAgentPath != nil
        ctx.canToggleSelectedAgentDisabled = selectedAgent != nil
        ctx.selectedAgentIsDisabled = selectedAgent?.resolved.disabled == true

        ctx.openSettings = { openSettings() }
        ctx.refresh = { viewModel.refreshEverything() }
        ctx.openPiAgent = { viewModel.openPiAgentScreen() }
        ctx.openProjects = { viewModel.selectedSidebarItem = .projects }
        ctx.openIssues = { viewModel.selectedSidebarItem = .issues }
        ctx.openAgents = { viewModel.selectedSidebarItem = .agents }
        ctx.openSkills = { viewModel.selectedSidebarItem = .skills }
        ctx.openPrompts = { viewModel.selectedSidebarItem = .prompts }
        ctx.createPiAgentSession = { viewModel.createPiAgentDraftForSelectedProject() }
        ctx.selectNextPiAgentSession = { viewModel.selectNextPiAgentSession() }
        ctx.selectPreviousPiAgentSession = { viewModel.selectPreviousPiAgentSession() }
        ctx.createAgent = {
            editingAgent = nil
            agentDraft = viewModel.makeNewAgentDraft(scope: viewModel.selectedProjectPath == nil ? .library : .project)
        }
        ctx.deletePiAgentSession = { showingPiAgentDeleteAlert = true }
        ctx.stopPiAgentSession = { viewModel.stopSelectedPiAgentSession() }
        ctx.resumePiAgentInTerminal = { viewModel.openSelectedPiAgentSessionInTerminal() }
        ctx.refreshGitHub = { viewModel.refreshEverything() }
        ctx.commitGitHubChanges = { viewModel.commitChanges() }
        ctx.pushGitHubBranch = { viewModel.pushCurrentBranch() }
        ctx.enableAllProjects = { showingEnableAllProjectsAlert = true }
        ctx.disableAllProjects = { showingDisableAllProjectsAlert = true }
        ctx.addProject = { viewModel.chooseProjectRoot() }
        ctx.importSkills = {
            NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
        }
        ctx.createPrompt = {
            // Route through the Prompts screen so the new prompt opens in the
            // editor sheet and is only written to disk if the user saves.
            if viewModel.selectedSidebarItem != .prompts {
                viewModel.selectedSidebarItem = .prompts
            }
            Task { @MainActor in
                NotificationCenter.default.post(name: .agentDeckNewPromptRequested, object: nil)
            }
        }
        ctx.copyPromptInvocation = {
            guard let selectedPrompt else { return }
            copyCommandValue(selectedPrompt.invocation)
        }
        ctx.openPromptFile = {
            guard let selectedPrompt else { return }
            openPromptFile(selectedPrompt.filePath)
        }
        ctx.revealPromptFile = {
            guard let selectedPrompt else { return }
            revealPromptFile(selectedPrompt.filePath)
        }
        ctx.openSelectedAgentFile = { openSelectedAgentFile() }
        ctx.revealSelectedAgentFile = { revealSelectedAgentFile() }
        ctx.toggleSelectedAgentDisabled = {
            setSelectedAgentDisabled(!(selectedAgent?.resolved.disabled == true))
        }
    }

    private var issuesFiltersAreActive: Bool {
        viewModel.githubAuthorFilter != nil
            || viewModel.githubAssigneeFilter != nil
            || viewModel.githubTypeFilter != nil
            || !viewModel.githubLabelFilters.isEmpty
    }

    /// Extracted from `mainContent` so the type-checker doesn't choke on the
    /// nested-ForEach inside a List inside a NavigationSplitView column. The
    /// inlined version was tipping the compiler over "type-check in reasonable
    /// time" after recent additions to the surrounding toolbar/body.
    @ViewBuilder
    private func sidebarSectionsList(warnings: [SidebarItem: Bool]) -> some View {
        @Bindable var viewModel = viewModel
        AppList(
            sections: SidebarSection.allCases.map { section in
                AppListSection(
                    id: section.id,
                    title: section.rawValue,
                    items: section.items
                )
            },
            selection: .single(Binding(
                get: { viewModel.selectedSidebarItem.id },
                set: { newID in
                    guard let newID,
                          let item = SidebarItem.allCases.first(where: { $0.id == newID })
                    else { return }
                    viewModel.selectedSidebarItem = item
                }
            )),
            isDisabled: { item in
                item == .instructions && viewModel.selectedProjectPath == nil
            },
            keyboardNavigation: true
        ) { item in
            SidebarNavigationRow(
                item: item,
                isSelected: viewModel.selectedSidebarItem == item,
                showsWarning: warnings[item] ?? false
            )
        }
        .bottomEdgeFade(height: 34)
    }

    @ToolbarContentBuilder
    private var mainToolbarContent: some ToolbarContent {
        ToolbarSpacer(.flexible)
        primaryActionToolbarItems
    }

    private var agentsFilterButton: some View {
        Button {
            isAgentsFilterPopoverPresented.toggle()
        } label: {
            Label("Filter", systemImage: viewModel.selectedAgentFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .toolbarNeutralChrome()
        .help("Filter agents")
        .popover(isPresented: $isAgentsFilterPopoverPresented, arrowEdge: .bottom) {
            AgentsFilterPopover(viewModel: viewModel)
        }
    }

    @ToolbarContentBuilder
    private var primaryActionToolbarItems: some ToolbarContent {
        if viewModel.selectedSidebarItem == .projects {
            projectsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .issues {
            issuesPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .memory {
            memoryPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .agents {
            agentsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .environment {
            environmentPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .prompts {
            promptsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .skills {
            skillsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .agent {
            piAgentPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .models {
            modelsPrimaryToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var projectsPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    viewModel.refresh(includeModels: false, scanAllProjects: true)
                } label: {
                    Label(viewModel.isRefreshingProjects ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate.byLayer, isActive: viewModel.isRefreshingProjects)
                .toolbarNeutralChrome()
                .help("Refresh project discovery")
                .disabled(viewModel.isRefreshingProjects)

                Button {
                    viewModel.chooseProjectRoot()
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .toolbarPrimaryActionChrome()
                .help("Add project manually")
            }
        }
    }

    @ToolbarContentBuilder
    private var agentsPrimaryToolbarContent: some ToolbarContent {
        // Utility island: filter the list, bulk-edit models, and (contextually)
        // create a replacement for a selected builtin agent.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                agentsFilterButton

                Button {
                    agentModelQuickEditor = currentAgentModelQuickEditorContext
                } label: {
                    Label("Quick Edit Models", systemImage: "cpu")
                }
                .toolbarNeutralChrome()
                .help("Quick edit agent models and thinking")
                .disabled(currentAgentModelQuickEditorContext.sections.allSatisfy { $0.agents.isEmpty })

                if let agent = viewModel.selectedAgent {
                    replacementAgentButton(for: agent)
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Info + create island. `newAgentMenu` is the tinted trailing member, so
        // the ControlGroup renders it as a filled prominent segment — matching
        // the primary action in the instruction-editor toolbars.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                subagentsInfoButton
                newAgentMenu
            }
        }
    }

    private var newAgentMenu: some View {
        Menu {
            Button("New Library Agent") {
                editingAgent = nil
                agentDraft = viewModel.makeNewAgentDraft(scope: .library)
            }
            if viewModel.selectedProjectPath != nil {
                Button("New Project Agent") {
                    editingAgent = nil
                    agentDraft = viewModel.makeNewAgentDraft(scope: .project)
                }
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .toolbarPrimaryActionChrome()
        .help("Create a library agent, then choose global or project visibility")
    }

    private func replacementAgentButton(for agent: EffectiveAgentRecord) -> some View {
        Button {
            editingAgent = nil
            agentDraft = viewModel.makeReplacementAgentDraft(from: agent, scope: .global)
        } label: {
            Label("Replacement", systemImage: "arrow.triangle.2.circlepath")
        }
        .toolbarNeutralChrome()
        .help("Create a global replacement for this builtin agent")
        .disabled(!(agent.builtin != nil && agent.globalCustom == nil))
    }

    private var subagentsInfoButton: some View {
        Button {
            isSubagentsInfoPresented.toggle()
        } label: {
            Label("Info", systemImage: "info.circle")
        }
        .help("Explain Deck agent library visibility")
        .popover(isPresented: $isSubagentsInfoPresented, arrowEdge: .bottom) {
            SubagentsInfoPopover()
        }
        .toolbarNeutralChrome()
    }

    @ToolbarContentBuilder
    private var environmentPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    isEnvironmentInfoPresented.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .help("Explain environment resolution order")
                .popover(isPresented: $isEnvironmentInfoPresented, arrowEdge: .bottom) {
                    EnvironmentInfoPopover()
                }
                .toolbarNeutralChrome()

                Button {
                    // The sheet itself carries the scope picker now — open it
                    // defaulting to Project when one is selected, else Global.
                    let scope: AgentEditingTarget.CustomAgentScope =
                        viewModel.selectedProjectPath == nil ? .global : .project
                    envDraft = viewModel.makeNewEnvDraft(scope: scope)
                } label: {
                    Label("New Key", systemImage: "plus")
                }
                .toolbarPrimaryActionChrome()
                .help("Add one or more environment keys")
            }
        }
    }

    @ToolbarContentBuilder
    private var modelsPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    isModelsInfoPresented.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .help("Explain the models catalog and Pi Agent defaults")
                .popover(isPresented: $isModelsInfoPresented, arrowEdge: .bottom) {
                    ModelsInfoPopover()
                }
                .toolbarNeutralChrome()

                Button {
                    viewModel.refreshModels()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .toolbarNeutralChrome()
                .help("Refresh models")
            }
        }
    }

    @ToolbarContentBuilder
    private var promptsPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Prompt") {
                    NotificationCenter.default.post(name: .agentDeckNewPromptRequested, object: nil)
                }
                Button("Import Prompt") {
                    NotificationCenter.default.post(name: .agentDeckImportPromptRequested, object: nil)
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .toolbarPrimaryActionChrome()
            .help("Create a new prompt template or import an existing markdown file")
        }
    }

    private var skillsUpdateAllTitle: String {
        if viewModel.isUpdatingAllSkillRepositories { return "Updating" }
        let count = viewModel.skillRepositoriesWithKnownUpdates.count
        return count > 0 ? "Update All (\(count))" : "Update All"
    }

    @ToolbarContentBuilder
    private var skillsPrimaryToolbarContent: some ToolbarContent {
        // Sync island — manage updates for skills imported from Git repos.
        // Only shown once at least one skill repository has been synced.
        if !viewModel.appSettings.importedSkillRepositories.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        Task { await viewModel.checkAllSkillRepositoriesForUpdates() }
                    } label: {
                        Label(
                            viewModel.isCheckingAllSkillUpdates ? "Checking" : "Check for Updates",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .symbolEffect(.rotate.byLayer, isActive: viewModel.isCheckingAllSkillUpdates)
                    .toolbarNeutralChrome()
                    .help("Check every synced skill repository for updates")
                    .disabled(viewModel.isCheckingAllSkillUpdates || viewModel.isUpdatingAllSkillRepositories)

                    Button {
                        Task { await viewModel.updateAllSkillRepositoriesWithKnownUpdates() }
                    } label: {
                        Label(skillsUpdateAllTitle, systemImage: "arrow.down.circle")
                    }
                    .toolbarNeutralChrome()
                    .help("Update every synced skill that has a new version available")
                    .disabled(
                        viewModel.skillRepositoriesWithKnownUpdates.isEmpty
                            || viewModel.isCheckingAllSkillUpdates
                            || viewModel.isUpdatingAllSkillRepositories
                    )
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Rescan + info + create island — `New` is the tinted trailing member
        // so the ControlGroup renders it as a filled prominent segment.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    viewModel.refresh(includeModels: false, scanAllProjects: true)
                } label: {
                    Label(viewModel.isRefreshingProjects ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate.byLayer, isActive: viewModel.isRefreshingProjects)
                .toolbarNeutralChrome()
                .help("Rescan skills")
                .disabled(viewModel.isRefreshingProjects)

                Button {
                    isSkillsInfoPresented.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .help("Explain Pi skill visibility")
                .popover(isPresented: $isSkillsInfoPresented, arrowEdge: .bottom) {
                    SkillsInfoPopover()
                }
                .toolbarNeutralChrome()

                Menu {
                    Button("New Skill") {
                        NotificationCenter.default.post(name: .agentDeckNewSkillRequested, object: nil)
                    }
                    Button("Import Skills") {
                        NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("Create a new skill or import skill folders from an external source")
                .toolbarPrimaryActionChrome()
            }
        }
    }

    @ToolbarContentBuilder
    private var piAgentPrimaryToolbarContent: some ToolbarContent {
        // agent-deck only: standalone "Release" island left of the first group.
        // A bare leading ToolbarItem coalesces the whole toolbar into one capsule,
        // so it gets its own ControlGroup to render as a distinct glass island.
        if viewModel.shouldShowAgentDeckReleaseAction {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    PiAgentReleaseToolbarButton(viewModel: viewModel)
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                PiAgentPlanToolbarButton(store: viewModel.piAgentSessionStore)

                Button {
                    isPiAgentStartupResourcesPresented.toggle()
                } label: {
                    Label("Session Resources", systemImage: "info.circle")
                }
                .toolbarNeutralChrome()
                .help("Agents, skills, prompts, and environment available to this session")
                .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
                .popover(isPresented: $isPiAgentStartupResourcesPresented, arrowEdge: .bottom) {
                    if let session = viewModel.piAgentSessionStore.selectedSession {
                        PiAgentStartupResourcesPopover(viewModel: viewModel, session: session)
                    }
                }

                Button {
                    isPiAgentTranscriptOptionsPresented.toggle()
                } label: {
                    Label("Transcript Display", systemImage: "eye")
                }
                .toolbarNeutralChrome()
                .help("Choose what appears in the agent transcript")
                .popover(isPresented: $isPiAgentTranscriptOptionsPresented, arrowEdge: .bottom) {
                    PiAgentTranscriptDisplayOptionsPopover(viewModel: viewModel)
                }

                Button {
                    isPiAgentSystemPromptPresented.toggle()
                } label: {
                    Label("System Prompt", systemImage: "doc.text.magnifyingglass")
                }
                .toolbarNeutralChrome()
                .help("View the final system prompt sent to the agent")
                .disabled((viewModel.piAgentSessionStore.selectedSession?.finalSystemPrompt ?? "").isEmpty)
                .sheet(isPresented: $isPiAgentSystemPromptPresented) {
                    if let prompt = viewModel.piAgentSessionStore.selectedSession?.finalSystemPrompt, !prompt.isEmpty {
                        PiAgentFinalSystemPromptSheet(text: prompt)
                    }
                }
            }
        }

        // Put fixed spacers before optional groups. On the first Pi Agent render
        // the Git/server availability can arrive after toolbar construction;
        // leading spacers keep late-arriving controls in separate glass islands.
        ToolbarSpacer(.fixed, placement: .primaryAction)

        if viewModel.shouldShowPiAgentGitActions {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    PiAgentCommitToolbarButton(viewModel: viewModel)
                    PiAgentPushToolbarButton(viewModel: viewModel)
                    if viewModel.shouldShowMergeSelectedPiAgentSession {
                        PiAgentMergeToolbarButton(viewModel: viewModel)
                    }
                } label: {
                    Label("Git Actions", systemImage: "checkmark")
                }
                .toolbarNeutralChrome()
            }
        }

        if viewModel.shouldShowProjectServerControls {
            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                ProjectServerToolbarButton(
                    viewModel: viewModel,
                    store: viewModel.piAgentSessionStore
                )
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            PiAgentOpenTerminalToolbarButton(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore
            )
        }
    }

    @ToolbarContentBuilder
    private var issuesPrimaryToolbarContent: some ToolbarContent {
        // One ControlGroup so the two buttons share an island with the same
        // spacing as every other view (Memory, Projects, …), instead of the
        // narrower separate-items + ToolbarSpacer look.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                issuesFilterButton
                issuesRefreshButton
            }
        }
    }

    // Memory's toolbar lives here in the central switch — same level as every
    // other view — so its button island sits in the same place and doesn't jump
    // when switching to/from Projects. The "New Memory" action is posted to
    // MemoryScreen (which owns the editor sheet) via NotificationCenter.
    @ToolbarContentBuilder
    private var memoryPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    isMemoryInfoPresented.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .toolbarNeutralChrome()
                .help("Explain Agent Deck memory")
                .popover(isPresented: $isMemoryInfoPresented, arrowEdge: .bottom) {
                    let counts = memoryInfoCounts()
                    MemoryInfoPopover(
                        enabled: viewModel.appSettings.agentMemoryEnabled,
                        projectName: viewModel.selectedProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project selected",
                        recordCount: counts.total,
                        injectableCount: counts.injectable,
                        staleCount: counts.stale
                    )
                }

                Button {
                    NotificationCenter.default.post(name: .agentDeckNewMemoryRequested, object: nil)
                } label: {
                    Label("New Memory", systemImage: "plus")
                }
                .toolbarPrimaryActionChrome()
                .help(viewModel.selectedProjectPath == nil ? "Select a project before creating memory." : "Create a project memory")
                .disabled(viewModel.selectedProjectPath == nil)
            }
        }
    }

    /// Counts for the memory info popover. Computed only when the popover opens
    /// (inside its content closure), never on the toolbar render path.
    private func memoryInfoCounts() -> (total: Int, injectable: Int, stale: Int) {
        let records = viewModel.agentMemoryStore.records(projectPath: viewModel.selectedProjectPath)
        var injectable = 0
        var stale = 0
        for record in records {
            if record.isInjectable { injectable += 1 }
            if record.status == .stale { stale += 1 }
        }
        return (records.count, injectable, stale)
    }

    private var issuesFilterButton: some View {
        Button {
            isIssuesFilterPopoverPresented.toggle()
        } label: {
            Label("Filter", systemImage: issuesFiltersAreActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .toolbarNeutralChrome()
        .help("Filter issues")
        .disabled(viewModel.selectedGitHubProject?.gitHubRemote == nil)
        .popover(isPresented: $isIssuesFilterPopoverPresented, arrowEdge: .bottom) {
            IssuesFiltersPopover(viewModel: viewModel)
        }
    }

    private var issuesRefreshButton: some View {
        Button {
            viewModel.refreshProjectBoard(force: true)
        } label: {
            Label(viewModel.githubIsLoadingProjectBoard ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
        }
        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsLoadingProjectBoard)
        .toolbarNeutralChrome()
        .help("Refresh issues")
        .disabled(!viewModel.githubConnectionState.isConnected || viewModel.githubIsLoadingProjectBoard)
    }

    private var currentAgentModelQuickEditorContext: AgentModelQuickEditorContext {
        AgentModelQuickEditorContext(
            title: "Agent Models",
            subtitle: viewModel.selectedDiscoveredProject.map { "Quick edits for agents visible in \($0.name)." } ?? "Quick edits for agents visible in the current global view.",
            sections: currentAgentModelQuickEditorSections,
            preferredOverrideScope: viewModel.selectedProjectPath == nil ? .global : .project
        )
    }

    private var currentAgentModelQuickEditorSections: [AgentModelQuickEditorSection] {
        let filteredAgents = viewModel.selectedProjectPath == nil ? viewModel.allDisplayAgents : viewModel.filteredAgents

        func sortedUnique(_ agents: [EffectiveAgentRecord]) -> [EffectiveAgentRecord] {
            preferredAgentsByName(agents) { records in records.first }
        }

        func preferredAgentsByName(_ agents: [EffectiveAgentRecord], prefer: ([EffectiveAgentRecord]) -> EffectiveAgentRecord?) -> [EffectiveAgentRecord] {
            Dictionary(grouping: agents, by: { $0.name.lowercased() }).values.compactMap(prefer)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        let builtinCandidates = filteredAgents.filter { agent in
            agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
        }
        let builtinAgents = sortedUnique(builtinCandidates)

        let editableNonBuiltinAgents = filteredAgents.filter { agent in
            let isPlainBuiltin = agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            return !isPlainBuiltin
        }
        if viewModel.selectedProjectPath == nil {
            return [
                AgentModelQuickEditorSection(title: "Custom Agents", agents: sortedUnique(editableNonBuiltinAgents)),
                AgentModelQuickEditorSection(title: "Builtin Agents", agents: builtinAgents)
            ]
        }

        let activeCandidates = editableNonBuiltinAgents.filter { agent in
            agent.resolved.disabled != true
        }
        let inactiveCandidates = editableNonBuiltinAgents.filter { agent in
            agent.resolved.disabled == true
        }
        let activeAgents = sortedUnique(activeCandidates)
        let inactiveAgents = sortedUnique(inactiveCandidates)

        return [
            AgentModelQuickEditorSection(title: "Active Agents", agents: activeAgents),
            AgentModelQuickEditorSection(title: "Inactive Agents", agents: inactiveAgents, isDimmed: true),
            AgentModelQuickEditorSection(title: "Builtin Agents", agents: builtinAgents)
        ]
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selectedSidebarItem {
        case .projects:
            ProjectsScreen(viewModel: viewModel, searchText: $projectSearchText)
        case .instructions:
            SystemInstructionsScreen(viewModel: viewModel)
        case .memory:
            MemoryScreen(viewModel: viewModel, memoryStore: viewModel.agentMemoryStore, searchText: $memorySearchText)
        case .issues:
            IssuesScreen(viewModel: viewModel, searchText: $issueSearchText)
        case .agents:
            AgentsScreen(
                viewModel: viewModel,
                searchText: $agentSearchText
            )
        case .skills:
            SkillsScreen(
                viewModel: viewModel,
                searchText: $skillSearchText
            )
        case .prompts:
            PromptsScreen(viewModel: viewModel, searchText: $promptSearchText)
        case .agent:
            PiAgentScreen(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore,
                sessionSearchText: $piAgentSessionSearchText
            )
        case .models:
            ModelsScreen(viewModel: viewModel)
        case .subagents:
            SubagentsScreen(viewModel: viewModel)
        case .environment:
            EnvironmentScreen(
                snapshot: viewModel.snapshot,
                onEditKey: { record in
                    envDraft = viewModel.makeEnvDraft(for: record)
                },
                onDeleteKey: { record in
                    do { try viewModel.deleteEnvKey(record) }
                    catch { NSSound.beep() }
                }
            )
        case .doctor:
            DoctorScreen(viewModel: viewModel)
        }
    }

    private func handleSidebarSelectionChange(_ newValue: SidebarItem) {
        if newValue == .agent {
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
        }
    }

    private var toolbarTitle: String {
        switch viewModel.selectedSidebarItem {
        case .agents:
            return viewModel.selectedAgent?.name ?? "Agents"
        case .agent:
            return viewModel.piAgentSessionStore.selectedSession?.displayTitle ?? "Pi Agent"
        case .skills:
            return viewModel.selectedSkill?.name ?? "Skills"
        case .issues:
            return viewModel.selectedGitHubProject?.gitHubRemote?.nameWithOwner ?? "Issues"
        default:
            return viewModel.selectedSidebarItem.rawValue
        }
    }


    private var filteredProjects: [DiscoveredProject] {
        let query = debouncedProjectFilterText
        guard !query.isEmpty else { return viewModel.enabledProjects }

        return viewModel.enabledProjects.filter { project in
            project.searchIndex.contains(query)
        }
    }

    private var selectedProject: DiscoveredProject? {
        guard let selectedProjectPath = viewModel.selectedProjectPath else { return nil }
        return viewModel.projectByPath[selectedProjectPath]
    }

    private var selectedAgentFilePath: String? {
        guard let agent = viewModel.selectedAgent else { return nil }
        return agent.sourcePath ?? agent.projectOverride?.settingsPath ?? agent.userOverride?.settingsPath
    }

    private func openSelectedAgentFile() {
        guard let path = selectedAgentFilePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealSelectedAgentFile() {
        guard let path = selectedAgentFilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openSelectedSkillFile() {
        guard let skill = viewModel.selectedSkill else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: skill.filePath))
    }

    private func revealSelectedSkillFile() {
        guard let skill = viewModel.selectedSkill else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.filePath)])
    }

    private func addSelectedSkillToProject() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.addSkillToSelectedProject(skill) } catch { NSSound.beep() }
    }

    private func removeSelectedSkillFromProject() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.removeSkillFromSelectedProject(skill) } catch { NSSound.beep() }
    }

    private func enableSelectedSkillGlobally() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.enableSkillGlobally(skill) } catch { NSSound.beep() }
    }

    private func disableSelectedSkillGlobally() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.disableSkillGlobally(skill) } catch { NSSound.beep() }
    }

    private func setSelectedAgentDisabled(_ isDisabled: Bool) {
        guard let agent = viewModel.selectedAgent else { return }
        do {
            try viewModel.setAgentDisabled(isDisabled, for: agent)
        } catch {
            NSSound.beep()
        }
    }

}

#Preview {
    ContentView()
}
