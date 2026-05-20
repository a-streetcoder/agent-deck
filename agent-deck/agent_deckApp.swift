//
//  agent_deckApp.swift
//  agent-deck
//
//  Created by Andrea Corvi on 29/04/2026.
//

import AppKit
import SwiftUI
import UserNotifications

private extension AppAppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

final class AgentDeckAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AgentDeckAppDelegate?

    let updater = UpdaterService()

    override init() {
        super.init()
        AgentDeckAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFonts.registerBundledFonts()
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
    @StateObject private var viewModel = AppViewModel()

    init() {
        AppFonts.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(appDelegate.updater)
                .preferredColorScheme(viewModel.appSettings.appearanceMode.preferredColorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsSceneContent()
                .environmentObject(viewModel)
                .environmentObject(appDelegate.updater)
                .preferredColorScheme(viewModel.appSettings.appearanceMode.preferredColorScheme)
        }
        .commands {
            AgentDeckCommands()
        }
    }
}
