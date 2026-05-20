import Combine
import Foundation
import SwiftUI
import Sparkle

@MainActor
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var availableVersion: String? = nil

    /// Lazy so it can reference `self` as the delegate.
    /// Sparkle 2.x binds delegates at construction time and exposes
    /// `SPUUpdater.delegate` as read-only.
    private lazy var controller: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    override init() {
        super.init()
        // Touch the lazy controller so Sparkle's scheduled-check timer starts
        // counting from launch, not from the first manual check.
        _ = controller
    }

    /// User-initiated check. Shows the full Sparkle dialog
    /// (Install / Remind Me Later / Skip This Version).
    ///
    /// If a background check is already in flight (common when the user opens
    /// the menu shortly after launch), `canCheckForUpdates` reports false and
    /// `checkForUpdates(_:)` silently drops the call. Poll briefly for the
    /// in-flight session to settle before giving up.
    func checkForUpdates() {
        if controller.updater.canCheckForUpdates {
            controller.checkForUpdates(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if self.controller.updater.canCheckForUpdates {
                    self.controller.checkForUpdates(nil)
                    return
                }
            }
        }
    }

    /// Silent background check. Sparkle surfaces a dialog only if a newer
    /// version is found. Safe to call from launch.
    func checkForUpdatesInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        NSLog("Sparkle: didFindValidUpdate version=%@", item.versionString)
        Task { @MainActor in
            self.updateAvailable = true
            self.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
            self.availableVersion = nil
        }
    }

    /// Surface failures so CI release issues (signature mismatch, 404 on the
    /// enclosure URL, malformed appcast) show up in Console.app instead of
    /// failing silently.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsErr = error as NSError
        NSLog(
            "Sparkle: didAbortWithError domain=%@ code=%ld desc=%@",
            nsErr.domain,
            nsErr.code,
            nsErr.localizedDescription
        )
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
            NSLog(
                "Sparkle: underlyingError domain=%@ code=%ld desc=%@",
                underlying.domain,
                underlying.code,
                underlying.localizedDescription
            )
        }
    }
}
