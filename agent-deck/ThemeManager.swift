import Observation

/// In-memory holder for the active color theme. `AppTheme` (DesignSystem.swift)
/// reads its themed tokens from here, and `agent_deckApp` observes `revision` to
/// repaint the window when the theme changes.
///
/// This is not the source of truth — `AppSettings` is. `AppViewModel` calls
/// `apply(_:)` at launch and whenever the selection or the active theme's colors
/// change.
@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var activeTheme: Theme

    /// Gradient/depth shades derived from the accent. Cached on `apply(_:)` so
    /// the `AppTheme` getters that read them stay cheap (they are hit on every
    /// view body evaluation, including per streaming token).
    private(set) var accentBright: ThemeColor
    private(set) var accentDeep: ThemeColor
    private(set) var accentShadow: ThemeColor
    private(set) var markdownHighlightingEnabled = true

    /// Bumped on every change. `agent_deckApp` keys the window content on this so
    /// a theme switch forces a uniform repaint of every view that reads `AppTheme`.
    private(set) var revision: Int = 0

    private init() {
        let theme = Theme.defaultTheme
        activeTheme = theme
        accentBright = theme.accentBright
        accentDeep = theme.accentDeep
        accentShadow = theme.accentShadow
    }

    func apply(_ theme: Theme) {
        activeTheme = theme
        accentBright = theme.accentBright
        accentDeep = theme.accentDeep
        accentShadow = theme.accentShadow
        revision += 1
    }

    func setMarkdownHighlightingEnabled(_ isEnabled: Bool) {
        guard markdownHighlightingEnabled != isEnabled else { return }
        markdownHighlightingEnabled = isEnabled
        revision += 1
    }
}
