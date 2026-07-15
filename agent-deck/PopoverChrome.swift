import SwiftUI

// Unified chrome for Pi Agent popovers. One header style (13pt semibold title +
// optional secondary subtitle, hairline divider beneath), one width scale, and a
// small shared row vocabulary so every popover lays out identically.
//
// Accent policy: the theme accent is reserved for selection state (the row
// checkmark), the active "Current" badge, and intentional data-viz. It is never
// applied to a name, title, path, or section label — those stay neutral
// (.primary / mutedText) so content never reads as "themed".

/// Title block shown at the top of every popover, above a divider. Carries an
/// optional trailing accessory (e.g. a refresh button).
struct AppPopoverHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Popover.titleFont)
                    .foregroundStyle(Color.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTheme.Popover.subtitleFont)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Popover.headerHInset)
        .padding(.top, AppTheme.Popover.headerTopInset)
        .padding(.bottom, AppTheme.Popover.headerBottomInset)
    }
}

extension AppPopoverHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

/// Standard popover shell: header + divider + content, sized to one of the three
/// standard widths. Use directly for the common "header over a list/body" case;
/// popovers that need a header accessory compose `AppPopoverHeader` themselves.
struct AppPopoverContainer<Content: View>: View {
    var width: CGFloat = AppTheme.Popover.standardWidth
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPopoverHeader(title: title, subtitle: subtitle)
            Divider()
            content()
        }
        .frame(width: width)
        .foregroundStyle(Color.primary)
    }
}

/// Scrollable list region for selectable rows. Matches every picker's inset and
/// height cap so the lists feel identical.
struct AppPopoverScrollList<Content: View>: View {
    var maxHeight: CGFloat = AppTheme.Popover.listMaxHeight
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                content()
            }
            .padding(.horizontal, AppTheme.Popover.listInset)
            .padding(.vertical, AppTheme.Popover.listInset)
        }
        .frame(maxHeight: maxHeight)
    }
}

/// Taller cap for project pickers: they can safely use most of the app window,
/// while compact model/thinking popovers keep the shared default height.
struct AppProjectPickerPopoverList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        AppPopoverScrollList(maxHeight: max(AppTheme.Popover.listMaxHeight, appWindowListMaxHeight)) {
            content()
        }
    }

    private var appWindowListMaxHeight: CGFloat {
        let fallbackHeight: CGFloat = 640
        let windowHeight = NSApplication.shared.keyWindow?.contentLayoutRect.height
            ?? NSApplication.shared.mainWindow?.contentLayoutRect.height
            ?? fallbackHeight
        // Leave room for the popover header/divider and a little breathing room.
        return max(240, floor(windowHeight * 0.90) - 58)
    }
}

/// Selectable text row (model, thinking, agent). The active choice carries the
/// app-wide selection mark — accent `checkmark.circle.fill` right after the
/// name (same as the Settings/agent-editor pickers) — plus a subtle fill.
struct AppPopoverTextRow: View {
    var isSelected: Bool = false
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(AppTheme.Popover.itemTitleFont)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isSelected {
                            AppPopoverSelectionMark()
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(AppTheme.Popover.itemSubtitleFont)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, AppTheme.Popover.rowHInset)
            .padding(.vertical, AppTheme.Popover.rowVInset)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Chat.chipCornerRadius, style: .continuous)
                    .fill(isSelected ? AppTheme.selectionFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Selectable project row (project pickers). Project icon + name + path; the
/// session's current project shows the accent "Current" badge.
struct AppPopoverProjectRow: View {
    let imageURL: URL?
    let symbolName: String
    let assetName: String?
    let title: String
    let path: String
    var isCurrent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: 24, assetName: assetName)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(AppTheme.Popover.itemTitleFont)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        if isCurrent { AppPopoverBadge(text: "Current") }
                    }
                    Text(path)
                        .font(AppTheme.Popover.itemSubtitleFont)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, AppTheme.Popover.rowHInset)
            .padding(.vertical, AppTheme.Popover.rowVInset)
        }
        .buttonStyle(.plain)
    }
}

/// Toggle row (transcript display options). Leading glyph + title/subtitle + switch.
struct AppPopoverToggleRow: View {
    let systemImage: String
    let assetImage: String?
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    init(systemImage: String, assetImage: String? = nil, title: String, subtitle: String, isOn: Binding<Bool>) {
        self.systemImage = systemImage
        self.assetImage = assetImage
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if let assetImage {
                    Image(assetImage)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .foregroundStyle(AppTheme.mutedText)
            .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Popover.itemTitleFont)
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(AppTheme.Popover.subtitleFont)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(isOn: $isOn) { EmptyView() }
                .appSwitch()
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Popover.rowHInset)
        .padding(.vertical, 8)
    }
}

/// The app-wide "this is the active choice" mark for popover rows: accent
/// `checkmark.circle.fill` placed right after the name, matching the
/// Settings/agent-editor picker rows.
struct AppPopoverSelectionMark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(AppTheme.Font.caption.weight(.semibold))
            .foregroundStyle(AppTheme.brandAccent)
            .accessibilityLabel("Selected")
    }
}

/// Accent capsule badge (e.g. "Current") — the one sanctioned accent on a row.
struct AppPopoverBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Font.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.brandAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.10)))
    }
}

/// Empty-state copy for a popover with no rows to show.
struct AppPopoverEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTheme.Popover.emptyBodyFont)
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Popover.headerHInset)
            .padding(.vertical, 12)
    }
}

/// Footer region (totals / actions) pinned under a divider.
struct AppPopoverFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content()
                .padding(.horizontal, AppTheme.Popover.footerHInset)
                .padding(.vertical, AppTheme.Popover.footerVInset)
        }
    }
}
