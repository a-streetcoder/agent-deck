import Combine
import Foundation
import SwiftUI
import Sparkle

@MainActor
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var availableVersion: String? = nil

    /// Sparkle app-update is opt-in for Pi Deck.
    ///
    /// Upstream Agent Deck pointed Sparkle at `https://agentdeck.site/appcast.xml`.
    /// This fork must not follow that feed (would overwrite Pi Deck with Agent Deck).
    /// Enable only when Info.plist has a non-empty first-party `SUFeedURL`.
    /// Debug builds never start the updater.
    private static let isEnabled: Bool = {
        #if DEBUG
        return false
        #else
        return hasConfiguredFeedURL
        #endif
    }()

    /// True when the bundle advertises a non-empty Sparkle appcast URL.
    private static var hasConfiguredFeedURL: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        let feed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if feed.isEmpty { return false }
        // Hard block: never follow upstream Agent Deck releases under a Pi Deck install.
        if feed.contains("agentdeck.site") { return false }
        return true
    }

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
        // counting from launch, not from the first manual check. Skipped when
        // disabled so the updater is never constructed in a debug build.
        guard Self.isEnabled else { return }
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
        guard Self.isEnabled else { return }
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
        guard Self.isEnabled else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
#if DEBUG
        NSLog("Sparkle: didFindValidUpdate version=%@", item.versionString)
#endif
        Task { @MainActor [weak self] in
            self?.updateAvailable = true
            self?.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            self?.updateAvailable = false
            self?.availableVersion = nil
        }
    }

    /// Surface failures so CI release issues (signature mismatch, 404 on the
    /// enclosure URL, malformed appcast) show up in Console.app instead of
    /// failing silently.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
#if DEBUG
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
#endif
    }
}
