//
//  agent_deckApp.swift
//  agent-deck
//
//  Created by Andrea Corvi on 29/04/2026.
//

import AppKit
import SwiftUI
import UserNotifications

final class AgentDeckAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AgentDeckAppDelegate?

    let updater = UpdaterService()

    override init() {
        super.init()
        AgentDeckAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash-proof hang detector: when the main thread freezes (janky scroll),
        // it auto-captures the hung backtrace via the external `sample` tool to
        // /tmp/agentdeck-hang-<n>.txt. Disable with HangWatchdogEnabled=NO.
        HangWatchdog.shared.start()
        // Debug: render sample native transcript bubbles for visual verification
        // without loading a real session. Off unless NativeBubblePreview=YES.
        NativeBubblePreviewDebug.showIfEnabled()
        // Agent Deck is a dark-only app — force the appearance at the AppKit
        // layer so menus, file panels, and the Sparkle updater are dark too
        // (SwiftUI's `.preferredColorScheme` does not reach those surfaces).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Restore the user's chosen Dock icon. The override is per-launch:
        // macOS resets `applicationIconImage` to the bundle default every time.
        AppIconChoice.apply(
            AppIconChoice.choice(forStoredName: AppSettingsStore.shared.settings.selectedAppIconName)
        )
        UNUserNotificationCenter.current().delegate = self
        // Defer the background update check off the launch path. Sparkle's
        // controller is still constructed at first scene-body eval (via the
        // `.environmentObject(appDelegate.updater)` injection), but the
        // explicit `checkForUpdatesInBackground()` call no longer sits inside
        // applicationDidFinishLaunching.
        let updater = updater
        Task.detached(priority: .background) {
            await MainActor.run {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionID = response.notification.request.content.userInfo["sessionID"] as? String {
            var userInfo: [AnyHashable: Any] = ["sessionID": sessionID]
            if let windowID = response.notification.request.content.userInfo["windowID"] as? String {
                userInfo["windowID"] = windowID
            }
            NotificationCenter.default.post(
                name: .piAgentNotificationResponse,
                object: nil,
                userInfo: userInfo
            )
        }
        completionHandler()
    }
}

@main
struct agent_deckApp: App {
    @NSApplicationDelegateAdaptor(AgentDeckAppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()
    @State private var themeManager = ThemeManager.shared

    init() {
        AppFonts.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environmentObject(appDelegate.updater)
                .preferredColorScheme(.dark)
                // `AppTheme`'s themed tokens are computed `static var`s, so a
                // theme switch is invisible to SwiftUI's dependency graph.
                // Re-keying on the theme revision forces a uniform repaint.
                .id(themeManager.revision)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsSceneContent()
                .environment(viewModel)
                .environmentObject(appDelegate.updater)
                .preferredColorScheme(.dark)
                // The theme re-key lives INSIDE SettingsSceneContent (around the
                // themed content only) rather than here, so a theme switch repaints
                // without discarding the view's `selectedTab` @State — otherwise
                // every theme change bounced the user back to the General tab.
        }
        .commands {
            AgentDeckCommands()
        }

        Window("About \(AppBrand.displayName)", id: AboutWindow.id) {
            AboutView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 440, height: 560)
        .defaultPosition(.center)
    }
}
