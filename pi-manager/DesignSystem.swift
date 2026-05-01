import SwiftUI

enum AppTheme {
    static let pagePadding: CGFloat = 24
    static let cardCornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 18
    static let contentSpacing: CGFloat = 12

    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color.primary.opacity(0.06)
    static let subtleFill = Color.primary.opacity(0.04)
    static let mutedText = Color.secondary
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
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .fill(AppTheme.cardFill)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
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
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .fill(AppTheme.cardFill)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .fontWidth(.expanded)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.subtleFill)
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.subtleFill)
        )
    }

    private func stepButton(icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.3) : .white)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(disabled ? Color.secondary.opacity(0.15) : Color.accentColor)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct AppRowCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.cardFill)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }
}
