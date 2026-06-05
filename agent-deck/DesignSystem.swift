import AppKit
import OSLog
import SwiftUI

enum AppTheme {
    static let pagePadding: CGFloat = 24
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 18
    static let contentSpacing: CGFloat = 12

    /// Default geometry for the list/detail split shared by every resource and
    /// workspace screen (Issues, Agents, Prompts, Skills), all built with
    /// `SplitView`. One source of truth — tweak here to re-balance every split at
    /// once.
    enum Split {
        /// List-pane share of the available width (0–1). The detail pane gets the
        /// rest, and both panes scale proportionally on window resize. `0.5` = even.
        /// Change this one number to re-balance every split.
        static let listFraction: CGFloat = 0.42
        /// Top inset for the *content* of both panes, so the list's first row and
        /// the detail's first card start at the same height. The detail pane uses
        /// this instead of the full `pagePadding` at the top.
        static let contentTopInset: CGFloat = 8
    }
    static let toolbarIconFrame = CGSize(width: 26, height: 20)
    static let toolbarAssetIconSize = CGSize(width: 16, height: 16)

    /// SF Symbol scale for the glyphs inside transcript cards & bubbles — one knob
    /// so every header symbol renders at the same scale. The AppKit equivalent of
    /// SwiftUI's `.imageScale(.large)`.
    static let cardSymbolScale: NSImage.SymbolScale = .large

    // MARK: Typography
    //
    // Fixed-size font tokens for the chat / transcript UI. macOS semantic
    // styles (.body = 13pt, .caption = 10pt, .caption2 = 9pt) render too small
    // for comfortable reading in a conversation thread. These tokens bump every
    // tier up ~1pt so body text lands at 14pt, captions at 11–12pt — matching
    // aligned with Apple HIG guidance to avoid
    // sub-11pt readable text.
    //
    // Non-chat views (settings, management, sidebar) can keep using semantic
    // styles directly — those contexts have native control sizing that already
    // reads well.
    enum Font {
        static let titleSize: CGFloat = 20
        static let headlineSize: CGFloat = 14
        static let subheadlineSize: CGFloat = 13
        static let bodySize: CGFloat = 14
        static let calloutSize: CGFloat = 13
        static let footnoteSize: CGFloat = 12
        static let captionSize: CGFloat = 11
        static let caption2Size: CGFloat = 10
        static let codeSize: CGFloat = 13
        static let smallLabelSize: CGFloat = 9

        static let title = SwiftUI.Font.system(size: titleSize)
        static let headline = SwiftUI.Font.system(size: headlineSize, weight: .semibold)
        static let subheadline = SwiftUI.Font.system(size: subheadlineSize)
        static let body = SwiftUI.Font.system(size: bodySize)
        static let callout = SwiftUI.Font.system(size: calloutSize)
        static let footnote = SwiftUI.Font.system(size: footnoteSize)
        static let caption = SwiftUI.Font.system(size: captionSize)
        static let caption2 = SwiftUI.Font.system(size: caption2Size)
        static let code = SwiftUI.Font.system(size: codeSize, design: .monospaced)
        static let smallLabel = SwiftUI.Font.system(size: smallLabelSize, weight: .bold, design: .monospaced)
    }

    // MARK: Component geometry
    //
    // Corner radii and padding for the transcript / chat component set. Keeps
    // bubbles, tool cards, diff cards, and status rows visually consistent and
    // avoids the scatter of 6/8/10/11/12/14/16 radii that crept in ad-hoc.
    enum Chat {
        static let bubbleCornerRadius: CGFloat = 12
        static let cardCornerRadius: CGFloat = 12
        static let codeCornerRadius: CGFloat = 8
        static let inputCornerRadius: CGFloat = 8
        static let panelCornerRadius: CGFloat = 14
        static let subCardCornerRadius: CGFloat = 10
        static let thumbnailCornerRadius: CGFloat = 14
        static let composerCornerRadius: CGFloat = 20
        static let suggestionCornerRadius: CGFloat = 12
        static let chipCornerRadius: CGFloat = 6
        static let glassPanelCornerRadius: CGFloat = 22
        static let quoteBarCornerRadius: CGFloat = 1

        // Neutral transcript-card surface (Memory, subagent, tool group, fork,
        // state, archive, supervisor). A whisper of fill defined mostly by a crisp
        // hairline edge — replaces the old muddy `contentSubtleFill` box. Both
        // compute off the active theme via the shared neutral tokens, so they
        // track the theme (and light/dark) automatically.
        static var cardFill: Color { AppTheme.contentSubtleFill.opacity(0.18) }
        static var cardStroke: Color { AppTheme.hairlineStroke }

        static let bubbleHPadding: CGFloat = 16
        static let bubbleVPadding: CGFloat = 12
        static let bubbleChildHPadding: CGFloat = 14
        static let bubbleChildVPadding: CGFloat = 10

        static let cardHPadding: CGFloat = 12
        static let cardVPadding: CGFloat = 10

        // Vertical gaps between transcript rows. `rowSpacing` separates distinct
        // bubbles/cards; `threadSpacing` is the tighter question↔reply gap inside
        // one thread; `childSpacing` is the tightest gap between sibling children.
        static let rowSpacing: CGFloat = 32
        static let threadSpacing: CGFloat = 20
        static let childSpacing: CGFloat = 24
    }

    // Brand accent and the assistant tint are theme-driven — see Theme.swift and
    // ThemeManager. The macOS *global* accent still comes from the `AccentColor`
    // asset catalog (Apple's cyan); it is intentionally left fixed because in-app
    // surfaces are almost entirely custom-styled, so a few unstyled system
    // controls keeping the system accent is not noticeable. The bright/deep/shadow
    // shades are derived from the accent by ThemeManager so the primary-button
    // gradient and strokes always stay in the accent's color family.
    static var brandAccent: Color { ThemeManager.shared.activeTheme.accent.color }
    static var brandAccentBright: Color { ThemeManager.shared.accentBright.color }
    static var brandAccentDeep: Color { ThemeManager.shared.accentDeep.color }
    static var brandAccentShadow: Color { ThemeManager.shared.accentShadow.color }
    static var assistantAccent: Color { ThemeManager.shared.activeTheme.assistant.color }

    /// Subtle theme tint for Liquid Glass *chrome* (composer chips, glass circles,
    /// floating panels) so the glass picks up the active theme rather than reading as
    /// a neutral system material. Kept low-opacity so it tints the glass rather than
    /// coloring it — the button-role tints (primary accent, destructive red) are
    /// separate and intentionally stronger.
    static var glassTint: Color { brandAccent.opacity(0.55) }

    // Source-kind tags for library list rows / detail avatars. Each kind has a
    // distinct hue per theme so the avatar tint signals where an item came from.
    // The "global" fallback intentionally reuses `brandAccent` — items with no
    // specific source belong to the theme's default color, not a fourth slot.
    static var sourceBuiltin: Color { ThemeManager.shared.activeTheme.sourceBuiltin.color }
    static var sourceLibrary: Color { ThemeManager.shared.activeTheme.sourceLibrary.color }
    static var sourceProject: Color { ThemeManager.shared.activeTheme.sourceProject.color }

    // Official Pi coding-agent brand mark. Near-black (#09090B) on light, white
    // on dark — the pi logo should read as a logo, not a tinted glyph. Apply
    // `.gradient` on the icon to match the rest of the brand-mark treatment.
    static let piLogo = adaptiveColor(light: RGB(9, 9, 11), dark: RGB(255, 255, 255))

    // MARK: Transcript role accents
    // Every transcript message card derives its background fill, border stroke,
    // and icon/label tint from a single role base color, applied through the
    // fixed opacity scale below. Dark variants are desaturated and lightened so
    // the tints sit calmly on the dark transcript surface instead of
    // over-saturating the way raw system colors (.orange/.red/.indigo) do.
    static var roleUser: Color { assistantAccent }
    static var roleThinking: Color { ThemeManager.shared.activeTheme.thinking.color }
    static var roleTool: Color { ThemeManager.shared.activeTheme.tool.color }
    static var roleError: Color { ThemeManager.shared.activeTheme.error.color }
    static var roleStderr: Color { ThemeManager.shared.activeTheme.stderr.color }
    static let roleStatus = mutedText
    // Diff line accents.
    static var diffAdded: Color { ThemeManager.shared.activeTheme.diffAdded.color }
    static var diffRemoved: Color { roleError }
    // Fixed tint scale for role-derived surfaces — replaces ad-hoc per-role opacities.
    static let roleFillOpacity = 0.08
    static let roleFillStrongOpacity = 0.10
    static let roleStrokeOpacity = 0.20
    static let roleChipOpacity = 0.12

    // Native (TextKit) markdown surfaces — code fences, frontmatter, quote bar.
    // Mirror the WKWebView CSS palette so HTML and native markdown look identical.
    static let codeBlockFill = adaptiveColor(light: RGB(240, 240, 240), dark: RGB(30, 30, 32))
    static let quoteBarFill = adaptiveColor(light: RGB(180, 180, 184), dark: RGB(96, 96, 102))
    // AppKit-side NSColor mirrors of the same tokens, for callers that need a
    // dynamic NSColor (e.g. CALayer.backgroundColor via DynamicFillView). Built
    // with the same dynamicProvider so they resolve under each view's effective
    // appearance, not the global one.
    static let nsCodeBlockFill = adaptiveNSColor(light: RGB(240, 240, 240), dark: RGB(30, 30, 32))
    static let nsQuoteBarFill = adaptiveNSColor(light: RGB(180, 180, 184), dark: RGB(96, 96, 102))
    // Hairline border for the native code block — one step off the fill so the
    // surface reads as a defined code panel rather than a flat highlight box.
    static let nsCodeBlockBorder = adaptiveNSColor(light: RGB(214, 214, 218), dark: RGB(56, 56, 60))

    /// AppKit `NSColor` from any AppTheme SwiftUI `Color`, for native
    /// (CALayer / NSView) surfaces that must match the SwiftUI rendering. Theme
    /// tints resolve to static RGB for the active theme (same as SwiftUI draws
    /// them); system-derived colors stay dynamic across light/dark.
    static func ns(_ color: Color) -> NSColor { NSColor(color) }

    // Neutral surfaces are theme-driven (see Theme.background/surface/stroke) so the
    // whole canvas takes on each theme's personality, not just the accents. These are
    // computed `var`s — a theme switch repaints via `.id(themeManager.revision)` at the
    // window root, and the values resolve from the now-active theme.
    private static var activeTheme: Theme { ThemeManager.shared.activeTheme }

    static var windowBackground: Color { activeTheme.background.color }
    static var panelFill: Color { activeTheme.surface.color }
    static var contentFill: Color { activeTheme.surface.color }
    static var textContentFill: Color { activeTheme.background.color }
    static var contentStroke: Color { activeTheme.stroke.color.opacity(0.55) }
    static var hairlineStroke: Color { activeTheme.stroke.color.opacity(0.38) }
    static var contentSubtleFill: Color { activeTheme.surface.lightened(by: 0.12).color }
    static let selectionFill = Color.primary.opacity(0.055)
    static var selectionStroke: Color { brandAccent.opacity(0.24) }
    static let selectionGlow = Color.clear
    static var accentSelectionFill: Color { brandAccent.opacity(0.10) }
    static var accentSelectionStroke: Color { brandAccent.opacity(0.32) }
    static let mutedText = Color.secondary
    static let accentForeground = adaptiveColor(light: RGB(255, 255, 255), dark: RGB(0, 0, 0))

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            self.red = red / 255
            self.green = green / 255
            self.blue = blue / 255
        }
    }

    private static func adaptiveColor(light: RGB, dark: RGB) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    private static func adaptiveNSColor(light: RGB, dark: RGB) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }

    @available(*, deprecated, message: "Use semantic content, panel, or control surface helpers based on role.")
    static var cardFill: Color { contentFill }
    @available(*, deprecated, message: "Use contentStroke or selectionStroke based on role.")
    static var cardStroke: Color { contentStroke }
    @available(*, deprecated, message: "Use contentSubtleFill or semantic surface helpers based on role.")
    static var subtleFill: Color { contentSubtleFill }
}

extension View {
    /// Liquid Glass capsule chrome for pill-shaped controls (composer chips, keyboard
    /// shortcut hints, the like). Replaces the previous `.background(Capsule().fill(…))`
    /// idiom that produced flat-gray surfaces. Per Apple HIG: glass is reserved for
    /// the navigation/control layer — do NOT apply to content cells (transcript cards,
    /// list rows).
    func appGlassCapsule() -> some View {
        glassEffect(.regular.tint(AppTheme.glassTint), in: Capsule(style: .continuous))
    }

    /// Glass circle for icon-only chrome buttons (compact, attach, etc.).
    func appGlassCircle() -> some View {
        glassEffect(.regular.tint(AppTheme.glassTint), in: Circle())
    }

    /// Glass rounded rectangle for larger chrome surfaces — popovers, dropdowns,
    /// floating panels. Use for non-capsule, non-circle navigation-layer surfaces.
    func appGlassPanel(cornerRadius: CGFloat = 12) -> some View {
        glassEffect(.regular.tint(AppTheme.glassTint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Button style modifiers
    //
    // Every Button in the app should use one of these helpers. They bundle the
    // Apple Liquid Glass button style + border shape + (optional) tint into a
    // named semantic role so the design stays consistent and we can re-skin
    // the system from one place. Guidance: docs/agent-guidelines/LIQUID-GLASS.md.

    /// Primary action — opaque tinted glass capsule. Use for the call-to-action
    /// in dialogs, sheets, settings rows (Save, Done, Install, Submit,
    /// Configure, Continue, etc.).
    func appPrimaryButton(tint: Color = AppTheme.brandAccent) -> some View {
        buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(tint)
    }

    /// Secondary action — translucent glass capsule. Use for Cancel, Refresh,
    /// Reset, Choose Folder, inline utility buttons.
    func appSecondaryButton() -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.capsule)
    }

    /// Compact secondary action — translucent glass capsule with small native metrics.
    /// Use for inline edit/reveal/preview controls that should remain button-like but
    /// lighter and smaller than a standard row action.
    func appSmallSecondaryButton() -> some View {
        appSecondaryButton()
            .controlSize(.small)
    }

    /// Destructive action — opaque red-tinted glass capsule. Use for Delete,
    /// Remove, Move to Trash, Disconnect, Sign Out.
    func appDestructiveButton() -> some View {
        buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color.red)
    }

    /// Primary icon-only action — opaque tinted glass circle. Use for the send
    /// arrow, add-session `+`, and similar floating call-to-action icons.
    /// Foreground is auto-picked by the system from the tint for contrast.
    /// `controlSize` drives the overall button diameter (use `.large` for the
    /// primary composer CTA, `.regular` for inline icon actions).
    func appPrimaryCircleButton(
        tint: Color = AppTheme.brandAccent,
        controlSize: ControlSize = .regular
    ) -> some View {
        buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(controlSize)
            .tint(tint)
    }

    /// Secondary icon-only action — translucent glass circle. Use for inline
    /// icon utility buttons (refresh, x close, paperclip attach, compact).
    func appSecondaryCircleButton(controlSize: ControlSize = .regular) -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(controlSize)
    }
}

/// Centralized circle icon button with consistent sizing across the app. The
/// system `.glassProminent`/`.glass` button styles add their own padding around
/// the label, so identical labels can render at different sizes depending on
/// the style. This view bypasses that by composing the chrome manually — the
/// `size` argument is the EXACT diameter, not a hint to the system.
///
/// Two variants:
///  - `.prominent` — tinted glass circle with high-contrast (accent-foreground)
///    symbol. Use for primary icon CTAs (send, etc.).
///  - `.soft` — low-opacity tinted glass circle with the tint color used for
///    both the chrome hint and the symbol. Use for secondary icon actions
///    (add-session `+`, clear, etc.).
struct AppCircleIconButton<Symbol: View>: View {
    enum Style { case prominent, soft }

    var style: Style = .soft
    var tint: Color = AppTheme.brandAccent
    var size: CGFloat = 30
    var imageScale: Image.Scale = .large
    var symbolWeight: Font.Weight = .bold
    var help: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @ViewBuilder var symbol: () -> Symbol

    var body: some View {
        Button(role: role, action: action) {
            symbol()
                .imageScale(imageScale)
                .fontWeight(symbolWeight)
                .foregroundStyle(symbolColor)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(tintMaterial), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }

    private var symbolColor: Color {
        switch style {
        case .prominent: return AppTheme.accentForeground
        case .soft: return tint
        }
    }

    private var tintMaterial: Color {
        switch style {
        case .prominent: return tint
        case .soft: return tint.opacity(0.18)
        }
    }
}

/// Circle icon menu button — the `Menu` counterpart of `AppCircleIconButton`.
/// Renders the same glass circle chrome but opens a native dropdown menu on
/// click instead of firing an action. Use for icon-buttons that show a menu
/// of choices (e.g. the agent-picker paperplane button in the session list).
struct AppCircleIconMenu<Symbol: View, Content: View>: View {
    enum Style { case prominent, soft }

    var style: Style = .soft
    var tint: Color = AppTheme.brandAccent
    var size: CGFloat = 30
    var imageScale: Image.Scale = .large
    var symbolWeight: Font.Weight = .bold
    var help: String? = nil
    @ViewBuilder var symbol: () -> Symbol
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu { content() } label: {
            symbol()
                .imageScale(imageScale)
                .fontWeight(symbolWeight)
                .foregroundStyle(symbolColor)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(tintMaterial), in: Circle())
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(help ?? "")
    }

    private var symbolColor: Color {
        switch style {
        case .prominent: return AppTheme.accentForeground
        case .soft: return tint
        }
    }

    private var tintMaterial: Color {
        switch style {
        case .prominent: return tint
        case .soft: return tint.opacity(0.18)
        }
    }
}

struct AppLoadingView: View {
    let title: String

    init(_ title: String = "Loading…") {
        self.title = title
    }

    var body: some View {
        VStack(spacing: 10) {
            AppSpinner()
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-window frosted overlay shown until the first workspace refresh
/// (projects + agents + skills + GitHub) completes. On launch that refresh
/// fans out background work — project discovery, `gh` calls, file scans — that
/// makes the individual panes load piecemeal and feel janky. Covering the window
/// with one calm loading state until `AppViewModel.hasCompletedInitialRefresh`
/// flips presents a single intentional moment instead, and blocks interaction
/// with half-populated views. Fades out (see the call site's `.animation`).
struct AppInitialLoadOverlay: View {
    var message: String = "Loading workspace…"
    /// One-shot entrance (icon scales/fades in).
    @State private var entered = false
    /// Barely-there idle float so the splash feels alive without jittering.
    @State private var floating = false

    /// The app icon the user currently has selected (Default vs Alternate), so the
    /// splash matches their Dock icon. Falls back to the live application icon.
    private var appIcon: NSImage? {
        let choice = AppIconChoice.choice(forStoredName: AppSettingsStore.shared.settings.selectedAppIconName)
        return NSImage(named: choice.assetName) ?? NSApplication.shared.applicationIconImage
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            // The paper-plane swarm, faint, blended into the background as a subtle
            // decoration drifting behind the icon.
            Image("paperplanes")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 620)
                .opacity(0.07)
                .offset(x: floating ? 14 : -14, y: floating ? -10 : 10)
                .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: floating)
                .allowsHitTesting(false)

            VStack(spacing: 22) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .shadow(color: AppTheme.brandAccent.opacity(0.28), radius: 22, y: 8)
                        .scaleEffect(entered ? 1 : 0.86)
                        // Gentle idle float, separate from the entrance scale.
                        .offset(y: floating ? -3 : 3)
                        .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: floating)
                }

                VStack(spacing: 14) {
                    Text(message)
                        .font(AppTheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    AppIndeterminateBar()
                        .frame(width: 168)
                }
            }
            .opacity(entered ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { entered = true }
            floating = true
        }
    }
}

/// Sleek indeterminate progress bar — an accent-gradient comet sweeps across a
/// faint track, looping. Use as a calm "working…" cue where there's no measurable
/// progress to show.
struct AppIndeterminateBar: View {
    var height: CGFloat = 3.5
    @State private var animating = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let pillWidth = trackWidth * 0.42
            Capsule()
                .fill(AppTheme.contentSubtleFill)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.brandAccent.opacity(0), AppTheme.brandAccent, AppTheme.brandAccent.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: pillWidth)
                        // Sweeps from fully off the left edge to fully off the right,
                        // hidden at both ends so the loop reset is invisible.
                        .offset(x: animating ? trackWidth : -pillWidth)
                        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false), value: animating)
                }
                .clipShape(Capsule())
        }
        .frame(height: height)
        .onAppear { animating = true }
    }
}

/// Themed indeterminate spinner. Use everywhere instead of `ProgressView()`
/// so the spinner stroke tracks the active app theme accent. macOS otherwise
/// paints `NSProgressIndicator` from `NSColor.controlAccentColor`, which
/// ignores in-app theme switches.
///
/// Apple-blessed approach: `View.tint(_:)` colors `ProgressView`'s stroke.
/// `.controlSize(...)` still works as expected — chain it after `AppSpinner`
/// and the environment override drives the size as usual.
struct AppSpinner: View {
    var body: some View {
        ProgressView().appBrandTint()
    }
}

/// Themed text field — the single shared replacement for every native
/// `TextField` in the app. Single-line or multi-line (via `axis`), with an
/// optional prompt and submit handler. Draws a custom bezel + focus border
/// in `AppTheme.brandAccent` so the focus state tracks the active theme.
///
/// Why custom: SwiftUI's native `TextField` style `.automatic` /
/// `.roundedBorder` draws an `NSTextField` focus ring at
/// `NSColor.keyboardFocusIndicatorColor` (≈ `NSColor.controlAccentColor`),
/// which `.tint(_:)` doesn't override on macOS. We switch to
/// `.textFieldStyle(.plain)` to suppress the native ring, then re-draw the
/// bezel + ring ourselves — full theme control without an
/// NSViewRepresentable bridge.
///
/// Caret color tracks the theme via `.appBrandTint()`. Text-selection
/// background still pulls from the system field editor
/// (`NSColor.selectedTextBackgroundColor`) and would need an
/// NSViewRepresentable bridge to override; left on system since it's only
/// visible while actively selecting text.
struct AppTextField: View {
    @Binding var text: String
    let placeholder: String
    var prompt: Text? = nil
    var font: Font = .body
    var axis: Axis = .horizontal
    var onSubmit: (() -> Void)? = nil
    var cornerRadius: CGFloat = 6
    /// Optional explicit horizontal/vertical padding overrides. Defaults
    /// match native NSTextField metrics within ~1pt.
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 5

    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(font)
            .focused($isFocused)
            .appBrandTint()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.textContentFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused && isEnabled ? AppTheme.brandAccent : AppTheme.contentStroke,
                        lineWidth: isFocused && isEnabled ? 2 : 1
                    )
            )
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .onSubmit { onSubmit?() }
    }

    @ViewBuilder
    private var field: some View {
        if let prompt {
            TextField(placeholder, text: $text, prompt: prompt, axis: axis)
        } else {
            TextField(placeholder, text: $text, axis: axis)
        }
    }
}

struct AppContentSurface: ViewModifier {
    var cornerRadius: CGFloat = AppTheme.cardCornerRadius
    var isSelected = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(AppTheme.contentFill)
                    .overlay(shape.fill(isSelected ? AppTheme.selectionFill : Color.clear))
                    .overlay(shape.stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1))
            )
    }
}

struct AppPanelSurface: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(AppTheme.panelFill)
                    .overlay(shape.stroke(AppTheme.contentStroke, lineWidth: 1))
            )
    }
}

struct AppControlSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(AppTheme.contentSubtleFill)
                    .overlay(shape.stroke(AppTheme.contentStroke, lineWidth: 1))
            )
    }
}

struct AppControlGroup<Content: View>: View {
    var spacing: CGFloat = AppTheme.contentSpacing
    @ViewBuilder let content: Content

    init(spacing: CGFloat = AppTheme.contentSpacing, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(AppTheme.accentForeground.gradient)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.brandAccentBright, AppTheme.brandAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(AppTheme.brandAccentBright.opacity(configuration.isPressed ? 0.45 : 0.65), lineWidth: 1)
            )
            .shadow(color: AppTheme.brandAccent.opacity(configuration.isPressed ? 0.10 : 0.18), radius: configuration.isPressed ? 2 : 5, y: 0)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .appGlassCapsule()
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct AppPillButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? AppTheme.brandAccent : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(
                isActive ? .regular.tint(AppTheme.brandAccent.opacity(0.18)).interactive() : .regular,
                in: Capsule(style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct AppCopyIconButton: View {
    var text: String
    var help: String = "Copy"
    var size = CGSize(width: 28, height: 28)
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedFeedback()
        } label: {
            ZStack {
                Color.clear
                    .contentShape(Capsule(style: .continuous))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(copied ? "Copied" : "Copy")
            }
            .frame(width: size.width, height: size.height)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(copied ? "Copied" : help)
    }

    private func showCopiedFeedback() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            copied = false
        }
    }
}

struct AppForkIconButton: View {
    var help: String = "Fork session from here"
    var size = CGSize(width: 28, height: 28)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear
                    .contentShape(Capsule(style: .continuous))
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Fork session")
            }
            .frame(width: size.width, height: size.height)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(help)
    }
}

struct AppCopyTextButton: View {
    var title = "Copy"
    var text: String
    var help: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedFeedback()
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help(copied ? "Copied" : (help ?? title))
    }

    private func showCopiedFeedback() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            copied = false
        }
    }
}

extension View {
    func appContentSurface(cornerRadius: CGFloat = AppTheme.cardCornerRadius, isSelected: Bool = false) -> some View {
        modifier(AppContentSurface(cornerRadius: cornerRadius, isSelected: isSelected))
    }

    func appPanelSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(AppPanelSurface(cornerRadius: cornerRadius))
    }

    func appControlSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(AppControlSurface(cornerRadius: cornerRadius))
    }

    func appToolbarIconFrame() -> some View {
        frame(width: AppTheme.toolbarIconFrame.width, height: AppTheme.toolbarIconFrame.height)
    }

    // Canonical list style for all resource lists (agents, skills, prompts).
    func appListStyle() -> some View {
        listStyle(.inset)
            .alternatingRowBackgrounds()
            .scrollIndicators(.hidden)
            .hideNativeScrollers()
            .tint(AppTheme.brandAccent)
    }

    /// Apply the active theme accent as the tint. Use on any native control
    /// whose color is driven by `.tint(_:)` per Apple's docs but doesn't have
    /// a dedicated `app*` style helper — `ProgressView`, `TextField` caret,
    /// `Stepper`, `Link`. Don't apply scene-wide (it would bleed into `.glass`
    /// secondary buttons whose hover background must stay neutral).
    func appBrandTint() -> some View {
        tint(AppTheme.brandAccent)
    }

    /// Themed `.switch`-style toggle. Use everywhere a switch-style `Toggle`
    /// is needed so the on-state tracks the active app theme accent. macOS
    /// otherwise paints `NSSwitch` from `NSColor.controlAccentColor`, which
    /// ignores in-app theme switches.
    ///
    /// Apple-blessed approach: `View.tint(_:)` ("the tint color is always
    /// respected... use it to provide additional meaning to the control").
    /// No custom replacement view needed.
    func appSwitch() -> some View {
        toggleStyle(.switch).appBrandTint()
    }

    /// Themed `.checkbox`-style toggle. Checkmark fill tracks the active app
    /// theme accent.
    func appCheckbox() -> some View {
        toggleStyle(.checkbox).appBrandTint()
    }

    /// Themed `.segmented` picker. Selected segment's background tracks the
    /// active app theme accent instead of the system accent.
    func appSegmentedPicker() -> some View {
        pickerStyle(.segmented).appBrandTint()
    }

    /// Themed `.menu` picker. Dropdown chevron + selected-item highlight
    /// track the active app theme accent.
    func appMenuPicker() -> some View {
        pickerStyle(.menu).appBrandTint()
    }
}

/// The list/detail split used by every resource and workspace screen (Issues,
/// Agents, Prompts, Skills). A plain `HStack`: the list pane takes
/// `AppTheme.Split.listFraction` of the width, the detail fills the rest, and both
/// panes scale proportionally when the window resizes. No divider, no drag — the
/// ratio is fixed (and configurable) in `AppTheme.Split`.
struct SplitView<ListPane: View, DetailPane: View>: View {
    @ViewBuilder var list: () -> ListPane
    @ViewBuilder var detail: () -> DetailPane

    var body: some View {
        GeometryReader { geo in
            let listWidth = geo.size.width * AppTheme.Split.listFraction
            HStack(spacing: 0) {
                list()
                    .frame(width: listWidth)
                    .frame(maxHeight: .infinity)
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct AppPage<Content: View>: View {
    let title: String
    let subtitle: String?
    /// When true, sections render lazily as they scroll into view rather than all
    /// at once. Use for pages whose lower sections are expensive to build (e.g. a
    /// large markdown document) so navigating to the page doesn't pay that cost up
    /// front. Defaults to false so every existing page is byte-for-byte unchanged.
    let lazy: Bool
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, lazy: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.lazy = lazy
        self.content = content()
    }

    var body: some View {
        if lazy {
            // 1:1 with the GitHub Issues detail (`GitHubIssueDetailView.detailContent`),
            // which lays out symmetrically at every window width: a plain
            // `ScrollView(showsIndicators:)` (no `.contentMargins` / `.scrollIndicators`
            // / `.hideNativeScrollers`, which caused this pane to render with trailing
            // slack that grew with width) wrapping a `LazyVStack`.
            //
            // A `LazyVStack` sizes itself to its children's ideal width, not the
            // proposed width, so its greedy cards otherwise sit leading-aligned with
            // empty trailing slack. The Issues detail fills because its first row is a
            // full-width `Text`; we reproduce that with a zero-height, full-width first
            // child that is greedy at layout time and pulls the stack to the full
            // width. The negative bottom padding cancels the stack spacing this anchor
            // would otherwise add above the first card.
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 0)
                        .padding(.bottom, -AppTheme.sectionSpacing)
                    content
                }
                // Smaller top inset so the first card lines up with the list pane's
                // top (which starts at `Split.contentTopInset`). Sides/bottom keep
                // the normal page padding.
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.bottom, AppTheme.pagePadding)
                .padding(.top, AppTheme.Split.contentTopInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    content
                }
                .padding(AppTheme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollIndicators(.never)
            .hideNativeScrollers()
        }
    }
}

/// A single keycap — a rounded-rectangle key glyph. Shared by the Settings
/// shortcuts list and the Pi agent shortcut strip so the keyboard styling
/// stays consistent across the app.
struct AppKeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: text.count > 1 ? 10 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, text.count > 1 ? 5 : 0)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.contentSubtleFill)
                    .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            }
    }
}

struct AppCard<Content: View, Trailing: View>: View {
    let title: String?
    let info: String?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(title: String? = nil, info: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.trailing = trailing()
        self.content = content()
    }

    private var showsHeader: Bool {
        title != nil || info != nil || !(Trailing.self == EmptyView.self)
    }

    var body: some View {
        Group {
            if title == nil && info == nil && !(Trailing.self == EmptyView.self) {
                HStack(alignment: .top, spacing: AppTheme.contentSpacing) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
            } else {
                VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                    if showsHeader {
                        HStack(alignment: .center) {
                            if let title {
                                Text(title)
                                    .font(.headline)
                                    .fontWidth(.expanded)
                            }
                            if let info {
                                AppHelpButton(title: title ?? "Details", text: info)
                            }
                            Spacer()
                            trailing
                        }
                    }

                    content
                }
            }
        }
        .padding(AppTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appContentSurface()
    }
}

/// The standard header for a modal sheet: a tinted icon tile, a title with an
/// optional monospaced subtitle and a muted metadata line, and trailing actions
/// (typically a Copy and a Done button). Includes the trailing `Divider` so
/// every sheet that adopts it lines up identically.
struct AppSheetHeader<Trailing: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var metadata: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .fontWidth(.expanded)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let metadata {
                        Text(metadata)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }

                Spacer(minLength: 12)

                trailing()
            }
            .padding(18)

            Divider()
        }
    }
}

struct AppMetricTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(value)")
                .font(.system(size: 30, weight: .bold))
                .fontWidth(.expanded)
            Text(title)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.cardPadding)
        .appContentSurface()
    }
}

struct AppSidebarPane<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .appPanelSurface(cornerRadius: 0)
    }
}

struct AppLabelTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.55), lineWidth: 1)
            )
            .foregroundStyle(color)
    }
}

struct AppListSectionHeader: View {
    let title: String
    let info: String?
    let tint: Color?

    init(_ title: String, info: String? = nil, tint: Color? = nil) {
        self.title = title
        self.info = info
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)
                .foregroundStyle(tint.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(.primary))
                .textCase(nil)

            if let info {
                AppHelpButton(title: title, text: info)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

/// The single shared inline "?" help affordance. Used for field-level help
/// (no `title` — a compact text-only popover) and, with a `title`, for
/// section/card headers (a titled popover that explains how the section works).
struct AppHelpButton: View {
    var title: String? = nil
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.map { "About \($0)" } ?? "Help")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let title {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "questionmark.circle")
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)

                Text(text)
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
        } else {
            Text(text)
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: 280)
        }
    }
}

@ViewBuilder
func appListSection<Content: View>(_ title: String, info: String? = nil, tint: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
    Section {
        content()
    } header: {
        AppListSectionHeader(title, info: info, tint: tint)
    }
    .listSectionSeparator(.hidden)
}

func nativeEmptyRow(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(AppTheme.mutedText)
        .padding(.vertical, 4)
        .selectionDisabled()
        .listRowSeparator(.hidden)
}

/// Shared page-level empty state. Keep empty/list-placeholder styling in one
/// place so sessions, agents, skills, projects, and search results stay aligned.
struct AppEmptyState: View {
    enum Layout {
        case fill
        case compact
    }

    let title: String
    let systemImage: String
    let description: String?
    let layout: Layout

    init(_ title: String, systemImage: String, description: String? = nil, layout: Layout = .compact) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.layout = layout
    }

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: description.map(Text.init)
        )
        .frame(maxWidth: .infinity, maxHeight: layout == .fill ? .infinity : nil)
        .padding(.vertical, layout == .compact ? 12 : 0)
    }
}

struct AppKeyValueList: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0)
                        .font(.caption.weight(.semibold))
                        .fontWidth(.expanded)
                        .foregroundStyle(AppTheme.mutedText)
                    Text(row.1)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if row.0 != rows.last?.0 {
                    Divider()
                }
            }
        }
    }
}

#if DEBUG
private struct AppLayoutDebugSnapshot: Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double

    init(_ frame: CGRect) {
        minX = Self.round(frame.minX)
        minY = Self.round(frame.minY)
        width = Self.round(frame.width)
        height = Self.round(frame.height)
    }

    private static func round(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}

private struct AppLayoutDebugModifier: ViewModifier {
    let name: String
    let logger: Logger
    @State private var lastSnapshot: AppLayoutDebugSnapshot?

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            logSnapshot(AppLayoutDebugSnapshot(proxy.frame(in: .global)))
                        }
                        .onChange(of: AppLayoutDebugSnapshot(proxy.frame(in: .global))) { _, snapshot in
                            logSnapshot(snapshot)
                        }
                }
            }
    }

    private func logSnapshot(_ snapshot: AppLayoutDebugSnapshot) {
        Task { @MainActor in
            guard snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            logger.debug("\(name, privacy: .public) frame x=\(snapshot.minX, privacy: .public) y=\(snapshot.minY, privacy: .public) w=\(snapshot.width, privacy: .public) h=\(snapshot.height, privacy: .public)")
        }
    }
}
#endif

extension View {
    func appDebugLayout(_ name: String, logger: Logger) -> some View {
        #if DEBUG
        modifier(AppLayoutDebugModifier(name: name, logger: logger))
        #else
        self
        #endif
    }
}

/// A design-system stepper for use inside AppCard contexts.
/// Displays a label, value with unit, and styled +/− buttons.
struct AppStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, unit: String = "") {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                stepButton(icon: "minus", disabled: value <= range.lowerBound) {
                    value = max(range.lowerBound, value - step)
                }
                .keyboardShortcut(.downArrow, modifiers: [])

                Text("\(value)\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 64)

                stepButton(icon: "plus", disabled: value >= range.upperBound) {
                    value = min(range.upperBound, value + step)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appContentSurface(cornerRadius: 12)
    }

    private func stepButton(icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .tint(disabled ? Color.secondary : AppTheme.brandAccent)
        .disabled(disabled)
    }
}

struct AppRowCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appContentSurface(cornerRadius: 14)
    }
}
