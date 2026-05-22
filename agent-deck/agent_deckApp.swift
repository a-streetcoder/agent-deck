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
        // Agent Deck is a dark-only app — force the appearance at the AppKit
        // layer so menus, file panels, and the Sparkle updater are dark too
        // (SwiftUI's `.preferredColorScheme` does not reach those surfaces).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UNUserNotificationCenter.current().delegate = self
        updater.checkForUpdatesInBackground()
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
