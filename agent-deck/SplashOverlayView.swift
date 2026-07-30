import AppKit
import Lottie
import SwiftUI

/// Plays the bundled brand splash animation once (paper-plane fleet) over a
/// transparent background, holding the final lockup frame. Wordmark is drawn in
/// SwiftUI as `AppBrand.displayName` so the fork always shows **Pi Deck**.
/// Hosted inside `AppInitialLoadOverlay`, which owns the backdrop and dismissal.
struct SplashAnimationView: NSViewRepresentable {
    func makeNSView(context: Context) -> LottieAnimationView {
        // Bundled file remains `agent-deck-splash.json` (asset name); composition
        // wordmark layer opacity is forced to 0 — title comes from SwiftUI.
        let animation = LottieAnimation.named("agent-deck-splash", subdirectory: "Animations")
            ?? LottieAnimation.named("agent-deck-splash")
        let view = LottieAnimationView(animation: animation)
        view.contentMode = .scaleAspectFit
        view.loopMode = .playOnce
        view.play()
        return view
    }

    func updateNSView(_ nsView: LottieAnimationView, context: Context) {}
}
