//
//  pi_managerApp.swift
//  pi-manager
//
//  Created by Andrea Corvi on 29/04/2026.
//

import AppKit
import SwiftUI

final class PiManagerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct pi_managerApp: App {
    @NSApplicationDelegateAdaptor(PiManagerAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
