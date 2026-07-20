import Foundation
import PostHog

/// The app's closed, privacy-minimized analytics surface.
///
/// This is intentionally the only file that imports PostHog. It sends only the
/// `app_opened` event and never identifies people or attaches app-authored
/// properties.
enum Analytics {
    private static let projectTokenInfoKey = "AgentDeckPostHogProjectToken"
    private static let postHogHost = "https://eu.i.posthog.com"
    private static var hasTrackedAppOpened = false

    /// Records the single supported analytics event at most once for this process.
    static func trackAppOpened() {
        #if DEBUG
        return
        #else
        let environment = ProcessInfo.processInfo.environment
        let projectToken = Bundle.main.object(forInfoDictionaryKey: projectTokenInfoKey) as? String ?? ""
        guard shouldTrackAppOpened(
            projectToken: projectToken,
            environment: environment,
            hasTrackedAppOpened: hasTrackedAppOpened
        ) else {
            return
        }

        // Mark before configuring so a re-entrant launch notification cannot emit
        // a second event. The SDK queues capture asynchronously; it is not on the
        // application startup critical path.
        hasTrackedAppOpened = true

        let config = PostHogConfig(projectToken: projectToken, host: postHogHost)
        config.personProfiles = .never
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        #if os(iOS)
        // These SDK features are unavailable on macOS but stay explicitly off
        // if this closed analytics wrapper is ever built for iOS.
        config.surveys = false
        config.sessionReplay = false
        #endif
        #if os(iOS) || targetEnvironment(macCatalyst)
        config.captureElementInteractions = false
        #endif
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.errorTrackingConfig.autoCapture = false
        config.debug = false

        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.capture("app_opened")
        #endif
    }

    /// Kept internal for focused tests; callers cannot send arbitrary events or properties.
    nonisolated static func shouldTrackAppOpened(
        projectToken: String,
        environment: [String: String],
        hasTrackedAppOpened: Bool
    ) -> Bool {
        guard !hasTrackedAppOpened,
              !projectToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
            && environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
            && environment["AGENTDECK_AUTOPERF"] == nil
            && environment["AGENTDECK_BENCHMARK"] == nil
    }
}
