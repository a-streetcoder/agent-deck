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
    static let assistantAccent = Color.purple

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
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }

    @available(*, deprecated, message: "Use semantic content, panel, or control surface helpers based on role.")
    static let cardFill = contentFill
    @available(*, deprecated, message: "Use contentStroke or selectionStroke based on role.")
    static let cardStroke = contentStroke
    @available(*, deprecated, message: "Use contentSubtleFill or semantic surface helpers based on role.")
    static let subtleFill = contentSubtleFill
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
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
            .overlay(Capsule(style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
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
            .background(Capsule(style: .continuous).fill(isActive ? AppTheme.selectionFill : AppTheme.contentSubtleFill))
            .overlay(Capsule(style: .continuous).stroke(isActive ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct AppCopyIconButton: View {
    var text: String
    var help: String = "Copy"
    var size = CGSize(width: 28, height: 22)
    var usesMaterialBackground = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedFeedback()
        } label: {
            ZStack {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(copied ? Color.green : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(copied ? "Copied" : "Copy")
            }
            .frame(width: size.width, height: size.height)
            .background {
                if usesMaterialBackground {
                    Capsule(style: .continuous)
                        .fill(.regularMaterial)
                }
            }
        }
        .buttonStyle(.plain)
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

    func appResourceListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
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
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(color)
    }
}

struct AppListSectionHeader: View {
    let title: String
    let info: String?
    @State private var isInfoPresented = false

    init(_ title: String, info: String? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)
                .foregroundStyle(.primary)
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

@ViewBuilder
func appListSection<Content: View>(_ title: String, info: String? = nil, @ViewBuilder content: () -> Content) -> some View {
    Section {
        content()
    } header: {
        AppListSectionHeader(title, info: info)
    }
    .listSectionSeparator(.hidden)
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
        .buttonStyle(.bordered)
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
