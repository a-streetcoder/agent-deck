import AppKit
import SwiftUI

enum AppTheme {
    static let pagePadding: CGFloat = 24
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 18
    static let contentSpacing: CGFloat = 12
    static let toolbarIconFrame = CGSize(width: 26, height: 20)
    static let toolbarAssetIconSize = CGSize(width: 16, height: 16)

    static let brandAccent = Color("AccentColor")
    static let brandAccentBright = adaptiveColor(light: RGB(44, 205, 199), dark: RGB(96, 232, 224))
    static let brandAccentDeep = adaptiveColor(light: RGB(13, 132, 129), dark: RGB(49, 122, 121))
    static let brandAccentShadow = adaptiveColor(light: RGB(207, 245, 243), dark: RGB(37, 72, 74))
    // Halfway between the original Color.purple and a fully softened variant — keeps
    // the original's punch in light mode while easing the dark-mode saturation just
    // enough to sit on the dark transcript surface without screaming.
    static let assistantAccent = adaptiveColor(light: RGB(155, 82, 207), dark: RGB(186, 110, 238))

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

    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let panelFill = Color(nsColor: .windowBackgroundColor)
    static let contentFill = Color(nsColor: .controlBackgroundColor)
    static let textContentFill = Color(nsColor: .textBackgroundColor)
    static let contentStroke = Color(nsColor: .separatorColor).opacity(0.55)
    static let hairlineStroke = Color(nsColor: .separatorColor).opacity(0.38)
    static let contentSubtleFill = Color(nsColor: .controlColor).opacity(0.62)
    static let selectionFill = Color.primary.opacity(0.055)
    static let selectionStroke = brandAccent.opacity(0.24)
    static let selectionGlow = Color.clear
    static let accentSelectionFill = brandAccent.opacity(0.10)
    static let accentSelectionStroke = brandAccent.opacity(0.32)
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
    static let cardFill = contentFill
    @available(*, deprecated, message: "Use contentStroke or selectionStroke based on role.")
    static let cardStroke = contentStroke
    @available(*, deprecated, message: "Use contentSubtleFill or semantic surface helpers based on role.")
    static let subtleFill = contentSubtleFill
}

extension View {
    /// Liquid Glass capsule chrome for pill-shaped controls (composer chips, keyboard
    /// shortcut hints, the like). Replaces the previous `.background(Capsule().fill(…))`
    /// idiom that produced flat-gray surfaces. Per Apple HIG: glass is reserved for
    /// the navigation/control layer — do NOT apply to content cells (transcript cards,
    /// list rows).
    func appGlassCapsule() -> some View {
        glassEffect(.regular, in: Capsule(style: .continuous))
    }

    /// Tinted variant for primary actions (the `+` add-session button, etc.).
    /// Includes `.interactive()` for the press-state material feedback Apple's
    /// HIG calls out for prominent controls.
    func appGlassCapsule(tint: Color) -> some View {
        glassEffect(.regular.tint(tint).interactive(), in: Capsule(style: .continuous))
    }

    /// Glass circle for icon-only chrome buttons (compact, attach, etc.).
    func appGlassCircle() -> some View {
        glassEffect(.regular, in: Circle())
    }

    /// Tinted glass circle for primary icon-only actions (send button, etc.).
    func appGlassCircle(tint: Color) -> some View {
        glassEffect(.regular.tint(tint).interactive(), in: Circle())
    }

    /// Glass rounded rectangle for larger chrome surfaces — popovers, dropdowns,
    /// floating panels. Use for non-capsule, non-circle navigation-layer surfaces.
    func appGlassPanel(cornerRadius: CGFloat = 12) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct AppLoadingView: View {
    let title: String

    init(_ title: String = "Loading…") {
        self.title = title
    }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var size = CGSize(width: 28, height: 22)
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedFeedback()
        } label: {
            // The label is a Rectangle-shape ZStack so the Button's hit area
            // covers the entire frame, not just the SF Symbol's intrinsic
            // glyph bounds. Inside the ZStack the Image is overlaid centered.
            ZStack {
                Color.clear
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copied ? Color.green : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(copied ? "Copied" : "Copy")
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Glass chrome lives OUTSIDE the Button so it doesn't interfere with
        // hit-testing. `.interactive()` gives us press-state material feedback
        // on the full button area.
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
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
    }
}

struct AppPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                content
            }
            .padding(AppTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppCard<Content: View, Trailing: View>: View {
    let title: String?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        Group {
            if title == nil && !(Trailing.self == EmptyView.self) {
                HStack(alignment: .top, spacing: AppTheme.contentSpacing) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
            } else {
                VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                    if title != nil || !(Trailing.self == EmptyView.self) {
                        HStack(alignment: .firstTextBaseline) {
                            if let title {
                                Text(title)
                                    .font(.headline)
                                    .fontWidth(.expanded)
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
        .appContentSurface()
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
            .glassEffect(.regular.tint(color.opacity(0.18)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(color)
    }
}

struct AppListSectionHeader: View {
    let title: String
    let info: String?
    let tint: Color?
    @State private var isInfoPresented = false

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
                Button {
                    isInfoPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(info)
                .accessibilityLabel("About \(title)")
                .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                    AppListSectionInfoPopover(title: title, message: info)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

private struct AppListSectionInfoPopover: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "info.circle")
                .font(.headline)
                .fontWidth(.expanded)
                .foregroundStyle(.primary)

            Text(message)
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }
}

struct FieldHelpButton: View {
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
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if row.0 != rows.last?.0 {
                    Divider()
                }
            }
        }
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
