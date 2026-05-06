//
//  pi_managerApp.swift
//  pi-manager
//
//  Created by Andrea Corvi on 29/04/2026.
//

import AppKit
import SwiftUI
import UserNotifications

final class PiManagerAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var onboardingCoordinator: WelcomeOnboardingCoordinator?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        DispatchQueue.main.async {
            if UserDefaults.standard.bool(forKey: WelcomeOnboardingCoordinator.completedDefaultsKey) {
                self.showMainWindow()
            } else {
                let coordinator = WelcomeOnboardingCoordinator { [weak self] in
                    self?.showMainWindow()
                }
                self.onboardingCoordinator = coordinator
                coordinator.start()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: WelcomeOnboardingCoordinator.completedDefaultsKey) {
            showMainWindow()
        }
        return true
    }

    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pi Manager"
        window.minSize = NSSize(width: 1120, height: 700)
        window.contentView = NSHostingView(rootView: ContentView())
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
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
struct pi_managerApp: App {
    @NSApplicationDelegateAdaptor(PiManagerAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsSceneContent()
        }
        .commands {
            PiManagerCommands()
        }
    }
}
