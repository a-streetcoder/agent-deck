# SwiftUI & macOS UI Guidelines

## Target Platform

macOS 26 (Tahoe) with Liquid Glass design. Requires Xcode 26.4+.

## Toolbar Pattern (Liquid Glass)

### Correct structure

- **2+ related buttons** → `ToolbarItem(placement: .primaryAction)` containing a `ControlGroup`.
- **Single standalone button** → `ToolbarItem(placement: .primaryAction)` with a plain `Button` (NO `ControlGroup` on a single item).
- Separate groups with `ToolbarSpacer(.fixed, placement: .primaryAction)`.
- Place `ToolbarSpacer` BEFORE an optional block so spacing is consistent whether or not it appears.

### Labels and chrome

- Always use `Label("Name", systemImage: "symbol")` — never `Image(systemName:)` alone.
- `ControlGroup` renders icon-only automatically; do NOT add `.labelStyle(.iconOnly)`.
- Chrome modifiers defined in `ContentView.swift`:
  - `toolbarNeutralChrome()` — secondary actions, foreground `.primary`.
  - `toolbarPrimaryActionChrome()` — main actions, foreground `AppTheme.brandAccent`.
  - Apply per-button or per-group.

### Sheet toolbars

- Use `.cancellationAction`, `.confirmationAction`, `.principal` placements.
- NO `ControlGroup` in sheet toolbars.

### Prohibited patterns

| Pattern | Reason |
|---|---|
| `ToolbarItemGroup { ... }` | Items coalesce into one glass blob |
| `ToolbarItem` with no placement | Defaults to `.automatic`, inconsistent |
| Single-item `ControlGroup` | Capsule sizes from full text width |
| `HStack` or `Divider()` inside toolbar item | Custom layout instead of native islands |
| `Image(systemName:)` as label | No overflow text, no VoiceOver |
| `.labelStyle(.iconOnly)` on toolbar Labels | Redundant; ControlGroup already icon-only |
| `frame(width:height:)` on button label containers | Breaks native spacing |

For the full reference, see `agent-deck-documentation/toolbar-guidelines.md`.

## Scope and Status Colors

Every resource must show its scope visibly — this is a hard product rule.

| Scope | Color | Visual Cue |
|-------|-------|------------|
| Builtin | Gray | Lock/read-only marker |
| Global | Blue | — |
| Library | Violet | — |
| Project | Cyan | — |
| Running | Teal | — |
| Success | Green | — |
| Warning | Amber | — |
| Danger | Red | — |

Every status indicator must include both text and icon, not color alone.

## Brand and Voice

- External brand name: **Pilot**. Internal/code name: **agent-deck** (bundle ID, process name, Xcode target).
- Brand voice: authoritative, professional, calm, precise. No hype.
- UI principles: native macOS first, high information density, opaque panels for code/logs/diffs. No robot mascots or chat bubbles.
- Accent colors: `brandAccentBright: #8DDEFF`, `brandAccentDeep: #008080`.
- Destructive actions must be separated and clearly labeled.

## Design System

- Shared UI components and styling live in `DesignSystem.swift`.
- Font registration in `AppFonts.swift` (Kemco Pixel Bold for branding).
- Theme constants in `AppTheme` namespace.
- Check `DesignSystem.swift` before creating new reusable components.

## Key View Files

These are the main view files, not an exhaustive list — discover others by reading the project:

- `ContentView.swift` — main navigation, toolbar, sheets, routing
- `AppViewModel.swift` — central state (`@MainActor ObservableObject`)
- `PiAgentViews.swift`, `PiAgentToolbarViews.swift` — Pi Agent sessions
- `DesignSystem.swift` — shared components and styling