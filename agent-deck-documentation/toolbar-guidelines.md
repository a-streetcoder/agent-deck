# Toolbar Guidelines

Agent Deck targets macOS 26 (Tahoe) with Liquid Glass. Every toolbar must follow the same pattern so buttons render as native glass capsule islands with correct hover states, disabled states, and overflow-menu behaviour.

---

## The one rule

> **One logical group = one `ToolbarItem(placement: .primaryAction)` whose content is a `ControlGroup`.**

Separate groups are divided by `ToolbarSpacer(.fixed, placement: .primaryAction)`. Nothing else.

---

## Correct pattern

```swift
// Single group
ToolbarItem(placement: .primaryAction) {
    ControlGroup {
        Button { } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .toolbarNeutralChrome()
            .help("Refresh")

        Button { } label: { Label("Add", systemImage: "plus") }
            .toolbarPrimaryActionChrome()
            .help("Add item")
    }
}

// Two separate groups
ToolbarItem(placement: .primaryAction) {
    ControlGroup {
        Button { } label: { Label("Info", systemImage: "info.circle") }
            .toolbarNeutralChrome()
            .help("Show info")
    }
}

ToolbarSpacer(.fixed, placement: .primaryAction)

ToolbarItem(placement: .primaryAction) {
    ControlGroup {
        Button { } label: { Label("Import", systemImage: "plus") }
            .toolbarPrimaryActionChrome()
            .help("Import items")
    }
}
```

macOS renders each `ControlGroup` as its own glass capsule island. `ToolbarSpacer` produces the visual gap between islands.

---

## Chrome modifiers

These two extensions live in `ContentView.swift` and must be applied to every toolbar button or menu:

```swift
// Neutral — secondary or informational actions
func toolbarNeutralChrome() -> some View {
    symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .tint(.primary)
}

// Primary — the main action for the screen
func toolbarPrimaryActionChrome() -> some View {
    symbolRenderingMode(.monochrome)
        .foregroundStyle(AppTheme.brandAccent)
        .tint(AppTheme.brandAccent)
}
```

Apply the modifier **per button or menu** when items inside one `ControlGroup` have different visual weight (e.g. a neutral info button alongside a primary add button). Apply it **on the `ControlGroup`** when every item should share the same chrome.

---

## Label vs Image

Always use `Label("Name", systemImage: "symbol")` for button labels — never `Image(systemName:)` alone.

```swift
// ✅ correct
Button { } label: { Label("Commit", systemImage: "checkmark") }

// ❌ wrong — no text for overflow menus or accessibility
Button { } label: { Image(systemName: "checkmark") }
```

The toolbar renders icon-only in normal mode; the text appears in the overflow menu (when the window is too narrow) and is read by VoiceOver. `ControlGroup` handles icon-only display automatically — you do not need `.labelStyle(.iconOnly)`.

---

## Conditional groups and spacers

When a group is conditionally visible, place the `ToolbarSpacer` **before the optional block** so spacing is consistent regardless of whether the optional group is present.

```swift
// ✅ correct — spacer is unconditional
ToolbarItem(placement: .primaryAction) {
    ControlGroup { /* always-visible group */ }
}

ToolbarSpacer(.fixed, placement: .primaryAction)   // always here

if condition {
    ToolbarItem(placement: .primaryAction) {
        ControlGroup { /* conditional group */ }
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
}

ToolbarItem(placement: .primaryAction) {
    ControlGroup { /* always-visible group */ }
}
```

If the spacer lives **inside** the conditional block, the groups adjacent to the hidden item run together with no visual gap.

---

## Conditional content inside a group

A `ControlGroup` can hold conditionally rendered items. Use this when buttons belong to the same logical group but one only appears in certain states:

```swift
ToolbarItem(placement: .primaryAction) {
    ControlGroup {
        Button { } label: { Label("New", systemImage: "plus") }
            .toolbarPrimaryActionChrome()

        if let selected = viewModel.selectedItem {
            Menu {
                Button("Open File") { }
                Button("Reveal in Finder") { }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .toolbarNeutralChrome()
        }
    }
}
```

---

## Fixed frame sizes on button labels

Do not add explicit `frame(width:height:)` to button labels inside a `ControlGroup`. The system sizes ControlGroup items natively and uniformly. Explicit frames fight the layout and produce uneven spacing.

```swift
// ✅ correct
Button { } label: {
    Label("Commit", systemImage: "checkmark")
        .symbolEffect(.rotate, isActive: isCommitting)
}

// ❌ wrong — forces a fixed footprint that breaks native ControlGroup spacing
Button { } label: {
    Label("Commit", systemImage: "checkmark")
        .frame(width: 28, height: 22)
}
```

For custom image assets (non-SF Symbols) you may need a frame on the image itself to set the intrinsic size, but do not wrap it in an extra `ZStack` or apply a frame to the outer label container:

```swift
// ✅ correct for custom assets
Button { } label: {
    Image("github")
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .frame(width: AppTheme.toolbarAssetIconSize.width,
               height: AppTheme.toolbarAssetIconSize.height)
}
```

---

## Sheet / modal toolbars

Sheet toolbars use different placements and do **not** use `ControlGroup`:

```swift
.toolbar {
    ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
    }
    ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
            .disabled(!isValid)
    }
}
```

`ControlGroup` is for the main window toolbar. Sheet toolbars express intent through `.cancellationAction` / `.confirmationAction` / `.principal` and let the system render them appropriately for the sheet context.

---

## What not to do

| Pattern | Problem |
|---|---|
| `ToolbarItemGroup { ... }` | Multiple items coalesce into one glass blob; cannot be separated with spacers |
| `ToolbarItemGroup(placement: .primaryAction) { ... }` | Same coalescing problem even with explicit placement |
| `ToolbarItem { ... }` (no placement) | Defaults to `.automatic`; behaviour is implicit and inconsistent |
| `HStack` or `Divider()` inside a toolbar item | Creates custom layout inside one item instead of native islands |
| Adjacent `ToolbarItem`s with no spacer | Items run together visually |
| `Image(systemName:)` as button label | No overflow-menu text, no VoiceOver label |
| `.labelStyle(.iconOnly)` on toolbar Labels | Redundant; `ControlGroup` already renders icon-only |
| `frame(width:height:)` on button label containers | Breaks native ControlGroup spacing |

---

## Placement reference

| Placement | Where | Use for |
|---|---|---|
| `.primaryAction` | Right of title, before search | All main window action groups |
| `.navigation` | Left of title | Destructive or navigation-scoped actions (e.g. trash, filter) |
| `.principal` | Centred in title bar | Title text in sheets |
| `.confirmationAction` | Sheet trailing | Confirm / save buttons in sheets |
| `.cancellationAction` | Sheet leading | Cancel / dismiss buttons in sheets |
| `ToolbarSpacer(.fixed, placement: .primaryAction)` | Between groups | Creates gap between glass islands in the primary action area |
| `ToolbarSpacer(.flexible)` | Anywhere | Pushes subsequent items to the trailing edge |
