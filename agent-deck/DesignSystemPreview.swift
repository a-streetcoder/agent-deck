#if DEBUG
import SwiftUI

// MARK: - App Title + Beta Badge Sandbox

#Preview("App Title") {
    // Edit the title and badge styles here, then port the winner to ContentView.
    VStack(alignment: .leading, spacing: 32) {

        // -- Current production style --
        previewLabel("Current")
        HStack(spacing: 8) {
            Text("AGENT DECK")
                .font(AppFonts.kemcoPixelBold(size: 18))
                .foregroundStyle(.primary)

            Text("BETA")
                .font(.caption2.weight(.bold))
                .fontWidth(.expanded)
                .foregroundStyle(AppTheme.brandAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppTheme.brandAccent.opacity(0.12), in: Capsule(style: .continuous))
        }

        Divider()

        // -- Variant A: larger badge, filled background --
        previewLabel("Variant A — filled badge")
        HStack(spacing: 8) {
            Text("AGENT DECK")
                .font(AppFonts.kemcoPixelBold(size: 18))
                .foregroundStyle(.primary)

            Text("BETA")
                .font(.caption2.weight(.bold))
                .fontWidth(.expanded)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(AppTheme.brandAccent, in: Capsule(style: .continuous))
        }

        Divider()

        // -- Variant B: subdued, secondary text --
        previewLabel("Variant B — muted")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AGENT DECK")
                .font(AppFonts.kemcoPixelBold(size: 18))
                .foregroundStyle(.primary)

            Text("BETA")
                .font(.caption2.weight(.semibold))
                .fontWidth(.expanded)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppTheme.contentSubtleFill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        }

        Divider()

        // -- Variant C: stacked layout --
        previewLabel("Variant C — stacked")
        VStack(alignment: .leading, spacing: 2) {
            Text("AGENT DECK")
                .font(AppFonts.kemcoPixelBold(size: 18))
                .foregroundStyle(.primary)

            Text("BETA")
                .font(.caption2.weight(.bold))
                .fontWidth(.expanded)
                .foregroundStyle(AppTheme.brandAccent)
                .tracking(2)
        }

        Divider()

        // -- Variant D: smaller title, rounded-rect badge --
        previewLabel("Variant D — rounded-rect badge")
        HStack(spacing: 8) {
            Text("AGENT DECK")
                .font(AppFonts.kemcoPixelBold(size: 16))
                .foregroundStyle(.primary)

            Text("BETA")
                .font(.system(size: 9, weight: .bold))
                .fontWidth(.expanded)
                .foregroundStyle(AppTheme.brandAccentBright)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(AppTheme.brandAccentDeep.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(AppTheme.brandAccentDeep.opacity(0.4), lineWidth: 1))
        }
    }
    .padding(24)
    .frame(width: 360)
}

// MARK: - Colors

#Preview("Colors") {
    VStack(alignment: .leading, spacing: 12) {
        Group {
            dsColorRow("brandAccent", AppTheme.brandAccent)
            dsColorRow("brandAccentBright", AppTheme.brandAccentBright)
            dsColorRow("brandAccentDeep", AppTheme.brandAccentDeep)
            dsColorRow("brandAccentShadow", AppTheme.brandAccentShadow)
            dsColorRow("assistantAccent", AppTheme.assistantAccent)
        }

        Divider()

        Group {
            dsColorRow("windowBackground", AppTheme.windowBackground)
            dsColorRow("panelFill", AppTheme.panelFill)
            dsColorRow("contentFill", AppTheme.contentFill)
            dsColorRow("contentSubtleFill", AppTheme.contentSubtleFill)
            dsColorRow("textContentFill", AppTheme.textContentFill)
        }

        Divider()

        Group {
            dsColorRow("contentStroke", AppTheme.contentStroke)
            dsColorRow("hairlineStroke", AppTheme.hairlineStroke)
            dsColorRow("selectionFill", AppTheme.selectionFill)
            dsColorRow("selectionStroke", AppTheme.selectionStroke)
            dsColorRow("accentSelectionFill", AppTheme.accentSelectionFill)
            dsColorRow("accentSelectionStroke", AppTheme.accentSelectionStroke)
        }

        Divider()

        Group {
            dsColorRow("primary", .primary)
            dsColorRow("secondary (mutedText)", AppTheme.mutedText)
            dsColorRow("accentForeground", AppTheme.accentForeground)
        }
    }
    .padding(24)
    .frame(width: 360)
}

// MARK: - Typography

#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENT DECK")
                .font(AppFonts.kemcoPixelBold(size: 18))
            Text("kemcoPixelBold 18 — app title")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Group {
                dsTypeRow("largeTitle", .largeTitle)
                dsTypeRow("title", .title)
                dsTypeRow("title2", .title2)
                dsTypeRow("title3", .title3)
                dsTypeRow("headline", .headline)
                dsTypeRow("body", .body)
                dsTypeRow("callout", .callout)
                dsTypeRow("subheadline", .subheadline)
                dsTypeRow("footnote", .footnote)
                dsTypeRow("caption", .caption)
                dsTypeRow("caption2", .caption2)
            }

            Divider()

            Group {
                Text("SECTION HEADER")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text(".headline + .fontWidth(.expanded) — list section headers")
                    .font(.caption).foregroundStyle(.secondary)

                Text("KEY LABEL")
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(AppTheme.mutedText)
                Text(".caption.semibold + .expanded + mutedText — key labels")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
    .frame(width: 360, height: 600)
}

// MARK: - Spacing

#Preview("Spacing") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Spacing Tokens")
            .font(.title3.weight(.semibold))

        dsSpacingRow("pagePadding", AppTheme.pagePadding)
        dsSpacingRow("cardPadding", AppTheme.cardPadding)
        dsSpacingRow("cardCornerRadius", AppTheme.cardCornerRadius)
        dsSpacingRow("sectionSpacing", AppTheme.sectionSpacing)
        dsSpacingRow("contentSpacing", AppTheme.contentSpacing)
    }
    .padding(24)
    .frame(width: 360)
}

// MARK: - Surfaces

#Preview("Surfaces") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            previewLabel("appContentSurface")
            VStack(alignment: .leading, spacing: 4) {
                Text("Content surface")
                Text("Default card background").foregroundStyle(.secondary).font(.caption)
            }
            .padding(AppTheme.cardPadding)
            .appContentSurface()

            previewLabel("appContentSurface (selected)")
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected state")
                Text("Accent tint + border").foregroundStyle(.secondary).font(.caption)
            }
            .padding(AppTheme.cardPadding)
            .appContentSurface(isSelected: true)

            previewLabel("appPanelSurface")
            VStack(alignment: .leading, spacing: 4) {
                Text("Panel surface")
                Text("For sidebar panes / sheets").foregroundStyle(.secondary).font(.caption)
            }
            .padding(AppTheme.cardPadding)
            .appPanelSurface()

            previewLabel("appControlSurface")
            HStack {
                Text("Control surface")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .appControlSurface()
        }
        .padding(24)
    }
    .frame(width: 360, height: 520)
}

// MARK: - Buttons

#Preview("Buttons") {
    VStack(alignment: .leading, spacing: 20) {
        previewLabel("AppPrimaryButtonStyle")
        Button("Launch Agent") {}
            .buttonStyle(AppPrimaryButtonStyle())

        previewLabel("AppSecondaryButtonStyle")
        Button("Cancel") {}
            .buttonStyle(AppSecondaryButtonStyle())

        previewLabel("AppPillButtonStyle (inactive)")
        Button("All") {}
            .buttonStyle(AppPillButtonStyle())

        previewLabel("AppPillButtonStyle (active)")
        Button("Project") {}
            .buttonStyle(AppPillButtonStyle(isActive: true))

        Divider()

        previewLabel("AppCopyIconButton")
        AppCopyIconButton(text: "claude --model sonnet")

        previewLabel("AppCopyTextButton")
        AppCopyTextButton(title: "Copy Path", text: "/Users/andrea/.claude")
    }
    .padding(24)
    .frame(width: 360)
}

// MARK: - Components

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            previewLabel("AppCard (no title)")
            AppCard {
                Text("Card content goes here")
            }

            previewLabel("AppCard (with title)")
            AppCard(title: "Agent Settings") {
                Text("Card body")
            }

            previewLabel("AppCard (title + trailing)")
            AppCard(title: "Memory") {
                Button("Edit") {}
                    .buttonStyle(AppSecondaryButtonStyle())
            } content: {
                Text("Card body with trailing action")
            }

            previewLabel("AppMetricTile")
            HStack(spacing: AppTheme.contentSpacing) {
                AppMetricTile(title: "Agents", value: 12)
                AppMetricTile(title: "Sessions", value: 47)
            }

            previewLabel("AppRowCard")
            AppRowCard {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(AppTheme.brandAccent)
                    Text("Row card item")
                }
            }

            previewLabel("AppLabelTag")
            HStack(spacing: 8) {
                AppLabelTag(text: "Beta", color: AppTheme.brandAccent)
                AppLabelTag(text: "Active", color: .green)
                AppLabelTag(text: "Disabled", color: .secondary)
                AppLabelTag(text: "Warning", color: .orange)
            }

            previewLabel("AppKeyValueList")
            AppKeyValueList(rows: [
                ("Model", "claude-sonnet-4-6"),
                ("Max Tokens", "8096"),
                ("Temperature", "1.0")
            ])
            .padding(AppTheme.cardPadding)
            .appContentSurface()

            previewLabel("AppStepper")
            AppStepper("Context Window", value: .constant(4), in: 1...8, unit: "k")

            previewLabel("AppLoadingView")
            AppLoadingView("Loading agents…")
                .frame(height: 80)
                .appContentSurface()
        }
        .padding(24)
    }
    .frame(width: 380, height: 900)
}

// MARK: - List Sections

#Preview("List Sections") {
    List {
        appListSection("Resources") {
            Label("Agents", systemImage: "rectangle.connected.to.line.below")
            Label("Skills", systemImage: "wand.and.stars")
        }
        appListSection("Runtime", info: "System-level configuration for Claude Code.") {
            Label("Models", systemImage: "cpu")
            Label("Environment", systemImage: "key")
        }
        appListSection("Accented", tint: AppTheme.brandAccent) {
            nativeEmptyRow("No items yet")
        }
    }
    .appListStyle()
    .frame(width: 360, height: 400)
}

// MARK: - Helpers

private func previewLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption.weight(.semibold))
        .fontWidth(.expanded)
        .foregroundStyle(AppTheme.mutedText)
}

private func dsColorRow(_ name: String, _ color: Color) -> some View {
    HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        Text(name)
            .font(.callout)
        Spacer()
    }
}

private func dsTypeRow(_ name: String, _ font: Font) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text("Aa \(name)")
            .font(font)
        Spacer()
        Text(".\(name)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private func dsSpacingRow(_ name: String, _ value: CGFloat) -> some View {
    HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 3)
            .fill(AppTheme.brandAccent.opacity(0.5))
            .frame(width: value, height: 14)
        Text("\(name): \(Int(value))pt")
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        Spacer()
    }
}

#endif
