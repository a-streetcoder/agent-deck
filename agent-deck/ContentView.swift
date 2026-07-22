import AppKit
import SwiftUI
import os


/// Shared animation for the sidebar's Resources ↔ Coding Agent push. A gentle
/// spring (slightly over-damped so it settles without overshoot) reads as a
/// crisp navigation push rather than a flat cross-fade.
/// Curves for the Coding Agent pull-up. `move` drives the offset/scale
/// transforms (gentle spring, slight settle); `fade` is deliberately shorter
/// so the incoming layer is already readable while still in motion.
enum PanelTransition {
    static let move: Animation = .spring(response: 0.42, dampingFraction: 0.86)
    static let fade: Animation = .easeOut(duration: 0.22)
}

/// Hosts the two permanently-mounted sidebar layers and owns the ONLY read of
/// `isCodingAgentPanelExpanded`, so toggling the panel invalidates just this
/// subtree — never the window body, toolbar, or detail/transcript.
///
/// Both layers stay mounted so expanding is a pure clip/transform/opacity
/// animation over already-laid-out trees — no teardown/rebuild (which re-ran
/// the session caches' onAppear mid-animation) and no cross-fade rendering two
/// heavy trees from scratch. Motion and fade run on separate scoped curves so
/// the layers hand off without the dead "both translucent" dip.
///
/// Animate ONLY scale/offset/opacity here: CoreAnimation interpolates those
/// without re-rendering content. An animated clipShape radius morph was tried
/// and reverted — an animatable shape makes SwiftUI rebuild the panel's
/// display list every frame (40-70ms hitches in NSHostingView.layout/render),
/// the same reason matchedGeometryEffect (per-frame layout) is out.
private struct CodingAgentPanelLayers<Nav: View, Panel: View>: View {
    var viewModel: AppViewModel
    @ViewBuilder var nav: () -> Nav
    let panel: (Bool) -> Panel

    var body: some View {
        let isPanelExpanded = viewModel.isCodingAgentPanelExpanded
        ZStack(alignment: .topLeading) {
            nav()
                // Recedes slightly in scale as well as position — reads as the
                // nav dropping back a layer while the panel grows over it.
                .scaleEffect(isPanelExpanded ? 0.98 : 1, anchor: .top)
                .offset(y: isPanelExpanded ? -24 : 0)
                .animation(PanelTransition.move, value: isPanelExpanded)
                .opacity(isPanelExpanded ? 0 : 1)
                .animation(PanelTransition.fade, value: isPanelExpanded)
                .allowsHitTesting(!isPanelExpanded)

            panel(isPanelExpanded)
                .offset(y: isPanelExpanded ? 0 : 52)
                .animation(PanelTransition.move, value: isPanelExpanded)
                .opacity(isPanelExpanded ? 1 : 0)
                .animation(PanelTransition.fade, value: isPanelExpanded)
                .allowsHitTesting(isPanelExpanded)
        }
    }
}

enum SidebarTransition {
    static let curve: Animation = .spring(response: 0.34, dampingFraction: 0.86)
}

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

}

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
        /// Long enough for the splash animation (2.5s) to finish its lockup.
        private let minimumOnScreen: TimeInterval = 2.8
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
    @State private var loopSearchText = ""
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
    @State private var isIssuesProjectPopoverPresented = false
    @State private var isMemoryProjectPopoverPresented = false
    @State private var isIssuesFilterPopoverPresented = false
    @State private var isAgentsFilterPopoverPresented = false
    #if DEBUG
    @State private var sidebarExpandBenchTask: Task<Void, Never>?
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
            .sheet(isPresented: $isOnboardingPresented) {
                WelcomeOnboardingSheet(viewModel: viewModel) { target in
                    if let target {
                        viewModel.selectedSidebarItem = target
                    }
                    completeOnboarding()
                }
                .interactiveDismissDisabled()
            }
#if DEBUG
            .onAppear { startSidebarExpandBenchIfEnabled() }
            .onReceive(NotificationCenter.default.publisher(for: .sidebarExpandBenchShouldStart)) { _ in
                startSidebarExpandBenchIfEnabled()
            }
            .onDisappear {
                sidebarExpandBenchTask?.cancel()
                sidebarExpandBenchTask = nil
            }
#endif
    }

#if DEBUG
    /// DEBUG/autoperf bench that reproduces the reported journey into Agents,
    /// Models, then the first Coding Agent sidebar expansion. Enable with
    /// `SidebarExpandBenchEnabled` or run through `AGENTDECK_AUTOPERF=1`.
    private func startSidebarExpandBenchIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "SidebarExpandBenchEnabled"),
              sidebarExpandBenchTask == nil else { return }
        sidebarExpandBenchTask = Task { @MainActor in
            await runSidebarExpandBench()
            sidebarExpandBenchTask = nil
        }
    }

    @MainActor
    private func runSidebarExpandBench() async {
        let defaults = UserDefaults.standard
        let rounds = max(1, defaults.object(forKey: "SidebarExpandBenchRounds") as? Int ?? 10)
        let settleMs = max(80, defaults.object(forKey: "SidebarExpandBenchSettleMs") as? Int ?? 650)

        viewModel.openPiAgentScreen()
        for _ in 0..<20 {
            guard !Task.isCancelled else { return }
            if !viewModel.piAgentSessionStore.sessions.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        let store = viewModel.piAgentSessionStore
        let chosen = store.sidebarExpandBenchLargestParentTranscriptCandidate()
        if let chosen, store.selectedSessionID != chosen.sessionID {
            viewModel.selectPiAgentSession(chosen.sessionID)
        } else if let chosen {
            store.requestTranscriptLoad(for: chosen.sessionID)
        }
        for _ in 0..<40 {
            guard !Task.isCancelled else { return }
            let selectedID = store.selectedSessionID
            if selectedID != nil && !store.isSelectedTranscriptLoading { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        let selectedID = store.selectedSessionID
        let selectedSession = selectedID?.uuidString ?? "none"
        let fileSize = chosen?.fileSize ?? 0
        let loadedCount = selectedID.map { store.transcriptsBySessionID[$0]?.count ?? 0 } ?? 0
        TranscriptScrollProfiler.logger.error("SIDEBAR_EXPANDBENCH PREPARE cycles=\(rounds) settleMs=\(settleMs) chosen=\(selectedSession, privacy: .public) fileSize=\(fileSize) entries=\(loadedCount)")
        TranscriptScrollProfiler.fileLog("SIDEBAR_EXPANDBENCH PREPARE cycles=\(rounds) settleMs=\(settleMs) chosen=\(selectedSession) fileSize=\(fileSize) entries=\(loadedCount)")

        let originalExpanded = viewModel.isCodingAgentPanelExpanded
        let originalSidebarItem = viewModel.selectedSidebarItem

        if !viewModel.isCodingAgentPanelExpanded || viewModel.selectedSidebarItem != .agent {
            viewModel.openPiAgentScreen()
            viewModel.isCodingAgentPanelExpanded = true
            try? await Task.sleep(for: .milliseconds(settleMs))
            guard !Task.isCancelled else { return }
        }

        sidebarExpandBenchLog("SIDEBAR_EXPANDBENCH JOURNEY_COLLAPSE from=expanded")
        viewModel.isCodingAgentPanelExpanded = false
        try? await Task.sleep(for: .milliseconds(settleMs))
        guard !Task.isCancelled else { return }

        viewModel.selectedSidebarItem = .agents
        try? await Task.sleep(for: .milliseconds(settleMs))
        NotificationCenter.default.post(name: .sidebarExpandBenchAgentsScrollRequested, object: nil)
        try? await Task.sleep(for: .milliseconds(settleMs))
        guard !Task.isCancelled else { return }
        sidebarExpandBenchLog("SIDEBAR_EXPANDBENCH JOURNEY_AGENTS_SCROLL")

        viewModel.selectedSidebarItem = .models
        try? await Task.sleep(for: .milliseconds(settleMs))
        NotificationCenter.default.post(name: .sidebarExpandBenchModelsScrollRequested, object: nil)
        try? await Task.sleep(for: .milliseconds(settleMs))
        guard !Task.isCancelled else { return }
        sidebarExpandBenchLog("SIDEBAR_EXPANDBENCH JOURNEY_MODELS_SCROLL")

        let hitchesAtStart = HangWatchdog.hitchCount
        let hangsAtStart = HangWatchdog.hangCount
        let hangMsAtStart = HangWatchdog.hangMsTotal
        HangWatchdog.worstHitchMs = 0
        PerfScene.current = "SidebarExpandBench"
        defer { PerfScene.current = "app" }
        let ready = "SIDEBAR_EXPANDBENCH START_READY action=firstExpand configuredCycles=\(rounds) startState=compact selected=models chosen=\(selectedSession) fileSize=\(fileSize) entries=\(loadedCount)"
        sidebarExpandBenchLog(ready)

        let expandStartedAt = CACurrentMediaTime()
        viewModel.expandCodingAgentPanel()
        try? await Task.sleep(for: .milliseconds(settleMs))
        let expandElapsedMs = Int((CACurrentMediaTime() - expandStartedAt) * 1000)
        let expandLine = "SIDEBAR_EXPANDBENCH cycle=1/1 action=expand state=expanded elapsed=\(expandElapsedMs)ms hitches=\(HangWatchdog.hitchCount - hitchesAtStart) hangs=\(HangWatchdog.hangCount - hangsAtStart) worstHitch=\(HangWatchdog.worstHitchMs)ms"
        sidebarExpandBenchLog(expandLine)

        if originalSidebarItem == .agent {
            viewModel.isCodingAgentPanelExpanded = originalExpanded
        } else {
            viewModel.selectedSidebarItem = originalSidebarItem
            viewModel.isCodingAgentPanelExpanded = originalExpanded
        }
        let summary = "SIDEBAR_EXPANDBENCH COMPLETE cycles=1 hitches=\(HangWatchdog.hitchCount - hitchesAtStart) hangs=\(HangWatchdog.hangCount - hangsAtStart) hangMs=\(HangWatchdog.hangMsTotal - hangMsAtStart) worstHitch=\(HangWatchdog.worstHitchMs)ms"
        sidebarExpandBenchLog(summary)
    }

    private func sidebarExpandBenchLog(_ line: String) {
        TranscriptScrollProfiler.logger.error("\(line, privacy: .public)")
        TranscriptScrollProfiler.fileLog(line)
    }
#endif

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
            // The expansion flag is read ONLY inside CodingAgentPanelLayers:
            // reading it here made every expand/collapse invalidate the whole
            // window body — NavigationSplitView, `.toolbar` (AppKit re-tiles
            // every item and rebuilds its menus, a 100ms+ main-thread hang) and
            // the detail tree (transcript updateNSView mid-animation).
            CodingAgentPanelLayers(
                viewModel: viewModel,
                nav: { navigationSidebarLayer(warnings: warnings) },
                panel: { isExpanded in
                    CodingAgentExpandedPanel(
                        viewModel: viewModel,
                        store: viewModel.piAgentSessionStore,
                        sessionSearchText: $piAgentSessionSearchText,
                        isActive: isExpanded,
                        onCollapse: { viewModel.isCodingAgentPanelExpanded = false }
                    )
                }
            )
            // Min width fits the pixel title + refresh/gear without wrapping.
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear, ignoresSafeAreaEdges: .all)
            .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
            .perfScene("Sidebar")
        } detail: {
            detailSplitView
                .perfScene("Detail")
        }
        .frame(minWidth: 900, minHeight: 640)
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
            Text("This removes the selected session’s local conversation data, saved MCP images, and Deck agent artifacts from this Mac.")
        }
        .toolbar { mainToolbarContent }
        // Detect the selected project's dev-server commands off the render path
        // so the toolbar control can hide for projects that have none.
        .task(id: viewModel.piAgentSessionStore.selectedSession?.projectPathForProjectFeatures) {
            if let path = viewModel.piAgentSessionStore.selectedSession?.projectPathForProjectFeatures {
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
                onCancel: { envDraft = nil },
                onSave: { drafts in
                    try viewModel.saveEnvDrafts(drafts)
                    envDraft = nil
                }
            )
        }
    }

    /// The navigation layer of the sidebar: brand title bar, GitHub account
    /// card, section list, and the collapsed Coding Agent panel. Extracted so
    /// it can live as a permanently-mounted ZStack layer underneath the
    /// expanded panel (see `mainContent`), which overlays all of it.
    @ViewBuilder
    private func navigationSidebarLayer(warnings: [SidebarItem: Bool]) -> some View {
        VStack(spacing: 0) {
            SidebarTitleBar(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            sidebarSectionsList(warnings: warnings)
                .padding(.top, 14)

            Spacer(minLength: 0)

            CodingAgentCollapsedPanel(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore,
                sessionSearchText: piAgentSessionSearchText
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var projectSearchIsDebouncing: Bool {
        projectFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedProjectFilterText
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
        case .projects, .agents, .issues, .memory, .skills, .prompts, .loops, .agent:
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
        case .loops: return "Search loops"
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
                case .loops: return loopSearchText
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
                case .loops: loopSearchText = value
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
        // Mirrors the header chevron: expanding keeps the current navigation
        // selection/detail/toolbar stable, collapsing just clears the flag,
        // same as the expanded panel's onCollapse.
        ctx.toggleSessionsPanel = {
            if viewModel.isCodingAgentPanelExpanded {
                viewModel.isCodingAgentPanelExpanded = false
            } else {
                viewModel.expandCodingAgentPanel()
            }
        }
        ctx.openProjects = { viewModel.selectedSidebarItem = .projects }
        ctx.openIssues = { viewModel.selectedSidebarItem = .issues }
        ctx.openAgents = { viewModel.selectedSidebarItem = .agents }
        ctx.openSkills = { viewModel.selectedSidebarItem = .skills }
        ctx.openPrompts = { viewModel.selectedSidebarItem = .prompts }
        ctx.createPiAgentSession = { viewModel.createPiAgentDraftForSelectedSessionProjectOrSelectedProject() }
        ctx.selectNextPiAgentSession = { viewModel.selectNextPiAgentSession() }
        ctx.selectPreviousPiAgentSession = { viewModel.selectPreviousPiAgentSession() }
        ctx.createAgent = {
            editingAgent = nil
            agentDraft = viewModel.makeNewAgentDraft(scope: .library)
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
                    withAnimation(SidebarTransition.curve) {
                        viewModel.selectedSidebarItem = item
                    }
                }
            )),
            isDisabled: { _ in false },
            // Constant on purpose: tying this to the panel-expansion flag handed
            // AppList a changed parameter on every toggle, forcing a full nav
            // re-diff (a per-toggle hitch). Arrow keys while the panel covers
            // the nav aren't silent anyway — selection collapses the panel.
            keyboardNavigation: true,
            // Past the 34pt fade below, so the last row ("Models") can scroll
            // clear of the gradient instead of always sitting dimmed in it.
            bottomContentInset: 36
        ) { item in
            SidebarNavigationRow(
                item: item,
                isSelected: viewModel.selectedSidebarItem == item,
                showsWarning: warnings[item] ?? false,
                showsNewFeatureBadge: item == .loops && !viewModel.appSettings.didOpenLoopsFromSidebar
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

    private var agentsToggleButton: some View {
        let enabled = viewModel.appSettings.nativeSubagentsEnabledForNewSessions
        // Button-style toggle matching the Memory toolbar's on/off control, so
        // both screens encode "feature is on" the same way (semantic toggle,
        // native tinted glass on-state) instead of a chrome-swapped Button.
        return Toggle(isOn: Binding(
            get: { viewModel.appSettings.nativeSubagentsEnabledForNewSessions },
            set: { _ in viewModel.toggleSubagentsForNewSessions() }
        )) {
            Label("Deck Agents", systemImage: "paperplane")
        }
        .toggleStyle(.button)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(enabled ? AppTheme.brandAccent : .secondary)
        .tint(AppTheme.brandAccent)
        .help(enabled ? "Deck agents are on for new sessions. Click to turn off." : "Deck agents are off for new sessions. Click to turn on.")
    }

    @ToolbarContentBuilder
    private var primaryActionToolbarItems: some ToolbarContent {
        workspaceToolbarItems
        resourceToolbarItems
        runtimeToolbarItems
    }

    @ToolbarContentBuilder
    private var workspaceToolbarItems: some ToolbarContent {
        if viewModel.selectedSidebarItem == .projects {
            projectsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .issues {
            issuesPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .memory {
            memoryPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .agent {
            piAgentPrimaryToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var resourceToolbarItems: some ToolbarContent {
        if viewModel.selectedSidebarItem == .agents {
            agentsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .prompts {
            promptsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .loops {
            loopsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .skills {
            skillsPrimaryToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var runtimeToolbarItems: some ToolbarContent {
        if viewModel.selectedSidebarItem == .environment {
            environmentPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .models {
            modelsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .extensions {
            extensionsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .mcp {
            mcpPrimaryToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var mcpPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                // Button-style toggle (not a switch), mirroring Memory: the on-state
                // renders as the native tinted glass highlight and the title shows
                // "MCP: On/Off" so the state reads at a glance.
                Toggle(isOn: Binding(
                    get: { viewModel.appSettings.mcpEnabled },
                    set: { viewModel.setMCPEnabled($0) }
                )) {
                    Label {
                        Text("Enable MCP")
                    } icon: {
                        Image(AppSymbols.mcp)
                    }
                }
                .toggleStyle(.button)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(viewModel.appSettings.mcpEnabled ? AppTheme.brandAccent : .secondary)
                .tint(AppTheme.brandAccent)
                .help(viewModel.appSettings.mcpEnabled ? "MCP is on for new sessions. Click to turn off." : "MCP is off. Click to enable it for new sessions.")

                Button {
                    viewModel.requestRefreshMCPServers()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .toolbarNeutralChrome()
                .help("Reload MCP servers")

                Button {
                    viewModel.requestAddMCPServer()
                } label: {
                    Label("Add server", systemImage: "plus")
                }
                .toolbarPrimaryActionChrome()
                .help("Add an MCP server")
            }
        }
    }

    @ToolbarContentBuilder
    private var extensionsPrimaryToolbarContent: some ToolbarContent {
        // Single standalone button — no ControlGroup wrapper (that double-rings it).
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.refreshDiscoveredPiExtensions()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .toolbarNeutralChrome()
            .help("Re-scan for Pi extensions")
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
        // Utility island: filter the list and, contextually, create a
        // replacement for a selected builtin agent. Persistent model editing
        // is available only from the Models screen.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                agentsFilterButton

                if let agent = viewModel.selectedAgent {
                    replacementAgentButton(for: agent)
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Toggle + info + create island, mirroring the Memory toolbar's
        // (Toggle, Info, New) so the two screens read identically.
        // `newAgentMenu` is the tinted trailing member, so the ControlGroup
        // renders it as a filled prominent segment — matching the primary
        // action in the instruction-editor toolbars.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                agentsToggleButton
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
                    envDraft = viewModel.makeNewEnvDraft()
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

                Button {
                    agentModelQuickEditor = currentAgentModelQuickEditorContext
                } label: {
                    Label("Quick Edit", systemImage: "cpu")
                }
                .toolbarNeutralChrome()
                .help("Quick edit every agent's model and thinking at once")
                .disabled(currentAgentModelQuickEditorContext.sections.allSatisfy { $0.agents.isEmpty })

                Button {
                    viewModel.isAddProviderPresented = true
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .toolbarPrimaryActionChrome()
                .help("Connect a model provider")
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

    @ToolbarContentBuilder
    private var loopsPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.requestNewLoopDefinition()
            } label: {
                Label("New Loop", systemImage: "plus")
            }
            .toolbarPrimaryActionChrome()
            .help("Create a user loop")
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

                Button {
                    NotificationCenter.default.post(name: .agentDeckManageSkillCollectionsRequested, object: nil)
                } label: {
                    Label("Collections", systemImage: "folder.badge.gearshape")
                }
                .help("Create and manage skill collections")
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
        ToolbarItem(placement: .primaryAction) {
            ProjectToolbarSelector(
                viewModel: viewModel,
                isPresented: $isIssuesProjectPopoverPresented
            )
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

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
            ProjectToolbarSelector(
                viewModel: viewModel,
                isPresented: $isMemoryProjectPopoverPresented
            )
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                // Button-style toggle, not a switch: toolbar islands hold
                // Label-based controls so overflow menus and VoiceOver get the
                // text, and the on-state renders as the native tinted glass
                // highlight instead of an embedded NSSwitch.
                Toggle(isOn: Binding(
                    get: { viewModel.appSettings.agentMemoryEnabled },
                    set: { viewModel.setAgentMemoryEnabled($0) }
                )) {
                    Label("Project Memory", systemImage: SidebarItem.memory.systemImage)
                }
                .toggleStyle(.button)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(viewModel.appSettings.agentMemoryEnabled ? AppTheme.brandAccent : .secondary)
                .tint(AppTheme.brandAccent)
                .help(viewModel.appSettings.agentMemoryEnabled ? "Project memory is on. Click to pause." : "Project memory is paused. Click to turn it on.")

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
            subtitle: "Quick edits for agents visible in the current global view.",
            sections: currentAgentModelQuickEditorSections,
            preferredOverrideScope: .global
        )
    }

    private var currentAgentModelQuickEditorSections: [AgentModelQuickEditorSection] {
        // Global catalog — independent of `selectedProjectPath`.
        let filteredAgents = viewModel.allDisplayAgents

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
        return [
            AgentModelQuickEditorSection(title: "Custom Agents", agents: sortedUnique(editableNonBuiltinAgents)),
            AgentModelQuickEditorSection(title: "Builtin Agents", agents: builtinAgents)
        ]
    }

    @ViewBuilder
    private var detailView: some View {
        // The Coding Agent screen owns a heavy AppKit transcript table. A plain
        // `switch` gives each branch a distinct view identity, so leaving `.agent`
        // and returning would destroy and rebuild the whole NSTableView + every row
        // (a 150ms+ hang on every entry). Instead it stays permanently mounted in
        // this ZStack and is just shown/hidden — re-entry is instant. The other
        // screens are lightweight SwiftUI and build on demand as before.
        ZStack {
            if viewModel.selectedSidebarItem != .agent {
                otherDetailScreens
            }

            PiAgentScreen(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore,
                sessionSearchText: $piAgentSessionSearchText,
                showsSessionsColumn: false,
                isActive: viewModel.selectedSidebarItem == .agent
            )
            .opacity(viewModel.selectedSidebarItem == .agent ? 1 : 0)
            .allowsHitTesting(viewModel.selectedSidebarItem == .agent)
        }
    }

    @ViewBuilder
    private var otherDetailScreens: some View {
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
        case .loops:
            LoopBankScreen(viewModel: viewModel, searchText: $loopSearchText)
        case .agent:
            // Handled by the always-mounted layer above.
            EmptyView()
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
        case .extensions:
            ExtensionsScreen(viewModel: viewModel)
        case .mcp:
            MCPServersScreen(viewModel: viewModel)
        case .doctor:
            DoctorScreen(viewModel: viewModel)
        }
    }

    private func handleSidebarSelectionChange(_ newValue: SidebarItem) {
        if newValue == .loops {
            viewModel.markLoopsOpenedFromSidebar()
        }

        if newValue == .agent {
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
        } else {
            viewModel.releaseTransientFocusedPiAgentSession()
            if viewModel.isCodingAgentPanelExpanded {
                // The expanded panel covers the nav list, so any non-agent selection
                // (commands, programmatic jumps) must reveal it again.
                viewModel.isCodingAgentPanelExpanded = false
            }
        }
    }

    private var toolbarTitle: String {
        switch viewModel.selectedSidebarItem {
        case .agent:
            return viewModel.piAgentSessionStore.selectedSession?.displayTitle ?? "Coding Agent"
        case .memory:
            // Mirrors the toolbar toggle so the state reads at a glance.
            return viewModel.appSettings.agentMemoryEnabled ? "Memory: On" : "Memory: Off"
        case .agents:
            // Same at-a-glance state as Memory, driven by the same toolbar toggle.
            return viewModel.appSettings.nativeSubagentsEnabledForNewSessions ? "Agents: On" : "Agents: Off"
        case .mcp:
            // Same at-a-glance state as Memory, driven by the toolbar enable toggle.
            return viewModel.appSettings.mcpEnabled ? "MCP: On" : "MCP: Off"
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
