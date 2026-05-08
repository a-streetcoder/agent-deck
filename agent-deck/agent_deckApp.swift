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

    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark:
            return .darkAqua
        }
    }

    func applyApplicationAppearance() {
        if let nsAppearanceName {
            NSApp.appearance = NSAppearance(named: nsAppearanceName)
        } else {
            NSApp.appearance = nil
        }
    }
}

final class AgentDeckAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFonts.registerBundledFonts()
        UNUserNotificationCenter.current().delegate = self
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
                .preferredColorScheme(viewModel.appSettings.appearanceMode.preferredColorScheme)
                .tint(AppTheme.brandAccent)
                .accentColor(AppTheme.brandAccent)
                .onAppear { viewModel.appSettings.appearanceMode.applyApplicationAppearance() }
                .onChange(of: viewModel.appSettings.appearanceMode) { _, mode in
                    mode.applyApplicationAppearance()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsSceneContent()
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.appSettings.appearanceMode.preferredColorScheme)
                .tint(AppTheme.brandAccent)
                .accentColor(AppTheme.brandAccent)
                .onAppear { viewModel.appSettings.appearanceMode.applyApplicationAppearance() }
                .onChange(of: viewModel.appSettings.appearanceMode) { _, mode in
                    mode.applyApplicationAppearance()
                }
        }
        .commands {
            AgentDeckCommands()
        }
    }
}
