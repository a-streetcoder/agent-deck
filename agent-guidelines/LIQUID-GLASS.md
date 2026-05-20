# Liquid Glass — agent-deck guide

Agent Deck targets macOS 26 (Tahoe). Every glass API is reachable without availability checks. **No conditional gates, no fallback materials, no `if #available`.** If you find yourself reaching for `.regularMaterial` or `NSVisualEffectView`, stop — use Liquid Glass instead.

This document is the canonical reference for how this codebase adopts Liquid Glass. When in doubt, follow it before reaching for SwiftUI or Apple's iOS-centric docs (which document touch-only behaviors that don't apply here).

## Layering rule

Apple's HIG: **glass is reserved for the navigation / control layer that floats above content.** Never apply it to the content itself.

| Layer | Examples in this app | Treatment |
|---|---|---|
| Content | Transcript message cards, list rows, code blocks, file diffs | **Solid surfaces** (`AppTheme.contentFill`, `AppTheme.textContentFill`, semantic SwiftUI colors). No glass. |
| Navigation / control | Composer chips, popovers, dropdowns, buttons (send, copy, add session), keyboard hint pills, status badges | **Liquid Glass.** |
| Overlay (vibrancy/fills *on* glass) | Tints inside glass surfaces | Use `.tint(_:)` on the glass or the button. |

Stacking glass-on-glass is an anti-pattern — the lensing compounds into haze. If a parent surface is glass, its inner controls should usually *not* be glass (or use `GlassEffectContainer` so they merge into one surface).

## Which API for which surface

### Buttons → button styles, **not** `.glassEffect(.interactive())`

`.glassEffect(...).interactive()` is documented as **iOS-only**. The interactive press behaviors (scaling, bouncing, shimmering, touch-point illumination) are touch-specific. On macOS the modifier is at best a no-op; we observed it *intercepting taps* on `Button` and eating ~90% of clicks.

For buttons that should grow to the system's natural button size, use the system glass styles directly:

```swift
// Primary action — opaque tinted glass, designed to be the call-to-action.
Button("Save") { … }
    .buttonStyle(.glassProminent)
    .tint(AppTheme.brandAccent)
    .buttonBorderShape(.capsule) // or .circle / .roundedRectangle

// Secondary action — translucent glass.
Button("Cancel") { … }
    .buttonStyle(.glass)
    .buttonBorderShape(.capsule)
```

`.buttonStyle(.glass)` and `.buttonStyle(.glassProminent)` each add a system-controlled padding around the label and own the hit-test region. **Don't combine them with an explicit `.frame(...)` on the label expecting the visible button to match that frame** — the system chrome pads outward beyond your frame, producing a larger visible button than you specified. Use these styles when the system's natural size is correct for the surface (most primary actions, most general buttons).

When you need an **exact button footprint** (e.g. an icon-only button in a tight header slot), use the manual chrome pattern instead:

```swift
Button { … } label: {
    ZStack {
        Color.clear.contentShape(Capsule(style: .continuous))
        Image(systemName: "doc.on.doc")
            .font(.caption.weight(.semibold))
    }
    .frame(width: 44, height: 22)
    .glassEffect(.regular, in: Capsule(style: .continuous))    // no `.interactive()`
    .contentShape(Capsule(style: .continuous))                  // hit shape for Button
}
.buttonStyle(.plain)
```

The `ZStack { Color.clear; Image }` gives the layout an explicit hit layer the size of the frame (a bare `Image` has tiny intrinsic SF Symbol bounds — clicks outside the glyph don't register). `.contentShape(...)` *on the label* tells the Button's tap recognizer to use the Capsule as its hit region. `.glassEffect(.regular, ...)` paints the chrome — **without `.interactive()`**, so its press-feedback gesture handler doesn't compete with the Button's tap recognizer.

In agent-deck:

- **`PiAgentSendButton`** (the `↑` / `■` in the composer) — system style: `.buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(tintColor)` where `tintColor` is `brandAccent` (sendable), `Color.red` (running/stop), or `mutedText` (disabled).
- **`PiAgentAddSessionButton`** (the `+` in the sidebar) — system style: `.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(...)`.
- **`AppCopyIconButton`** (every transcript copy button) — manual pattern: `.buttonStyle(.plain)` + `Color.clear` hit layer + `.glassEffect(.regular, in: Capsule)` + explicit `.contentShape(Capsule)`. Footprint must be exactly the size the caller passes (44×22 in headers, 32×32 in popovers) so the hover slot doesn't reflow on appearance.
- **All other formerly-`.borderedProminent` buttons** — `.buttonStyle(.glassProminent)`. Previously `.bordered` → `.buttonStyle(.glass)`.

Migration cheatsheet (already applied):

| Old | New |
|---|---|
| `.buttonStyle(.bordered)` | `.buttonStyle(.glass)` |
| `.buttonStyle(.borderedProminent)` | `.buttonStyle(.glassProminent).tint(...)` |

### Non-button chrome surfaces → `.glassEffect(...)` modifier

For static or non-Button chrome (chips, pills, popovers, dropdown panels, processing indicators), use one of the helpers in `DesignSystem.swift`:

```swift
extension View {
    func appGlassCapsule() -> some View  // composer chips, hint pills, status capsules
    func appGlassCircle() -> some View   // icon-only chrome (paperclip, compact)
    func appGlassPanel(cornerRadius: CGFloat = 12) -> some View  // popovers, dropdowns
}
```

These all expand to `.glassEffect(.regular, in: <shape>)` — no `.interactive()`. Examples in tree:

- `PiAgentComposerViews.swift` — the Context pill, model picker chip, thinking chip, paperclip, compaction button.
- `PiAgentStartupViews.swift` — the keyboard shortcut row (`↩ send / steer`, `Esc stop`, etc.).
- `PiAgentTranscriptViews.swift` — the compaction status capsule above the transcript.

For tinted non-button chrome (e.g. an `AppLabelTag` colored by status), inline the call so you can pass the tint:

```swift
.glassEffect(.regular.tint(color.opacity(0.18)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
```

### Popovers / sheets / floating panels

Two patterns:

1. **You own the surface** (custom popover view): `.appGlassPanel(cornerRadius: 14)`.
   - Used by `PiAgentComposerProjectPickerPopover`, `PiAgentProjectPickerPopover`.
2. **System-presented sheet**: do *not* set `.presentationBackground(...)`. macOS 26 applies Liquid Glass automatically. Setting `.presentationBackground(.regularMaterial)` overrides this with the legacy material — avoid.

## Variants — when to use which

The `Glass` type has exactly three variants:

| Variant | Use case |
|---|---|
| `.regular` | **Default.** Adapts to background content automatically. Use for almost everything in this app. |
| `.clear` | Only over media-rich content (photos, video, maps) when the foreground content is bold and bright enough to read against a clearer material. We have no current uses. |
| `.identity` | Conditional opt-out — `glassEffect(isEnabled ? .regular : .identity)`. No layout recalculation, just no visual effect. |

Avoid mixing `.regular` and `.clear` on the same screen.

## Tinting

`Glass.tint(_ color: Color)` — convey semantic meaning, **not** decoration. Use it for:

- Call-to-action prominence (`.glassProminent.tint(.brandAccent)` on send/`+`).
- State signals (red tint when running, muted when disabled).
- Per-tag identity (`AppLabelTag` mixes its color in at 0.18 opacity).

Don't tint every glass surface. Untinted glass is the default and reads as "secondary chrome." Tint reserved for surfaces that earn it.

## Hit testing — beware `.interactive()`

Symptoms we hit and what to avoid:

| Symptom | Cause | Fix |
|---|---|---|
| Tapping a button often does nothing | `.glassEffect(.regular.interactive(), in: ...)` on a `Button` — its press-state gesture handler competed with the Button's tap recognizer | Use `.buttonStyle(.glass)` / `.glassProminent` — system-native and reliable |
| Only the SF Symbol inside a button responds; surrounding chrome is dead | `Image` has tiny intrinsic bounds; `.frame(width:height:)` doesn't expand the hit-test region by itself, and `.glassEffect` doesn't help | Use a button style (preferred), or `ZStack { Color.clear; Image(...) }` inside the label with `.contentShape(Rectangle())` for an explicit hit layer |
| Tapping a popover's chrome closes it instead of activating an inner control | Glass-on-glass; the outer popover and inner controls compete for gestures | Use `GlassEffectContainer` to merge sampling, or remove glass from the inner controls |

**Rule of thumb:** for anything tappable, prefer `.buttonStyle(.glass)` or `.buttonStyle(.glassProminent)` over manual `.glassEffect(...)` chrome. The system styles bundle correct hit-testing.

## `GlassEffectContainer`

When multiple glass surfaces sit close together (composer chip row, keyboard hint row), wrap them in a `GlassEffectContainer` so they share a sampling region and morph cleanly:

```swift
GlassEffectContainer(spacing: 4) {
    HStack(spacing: 6) {
        hintChip("↩", "send / steer")
        hintChip("⇧/⌘/⌥ ↩", "newline")
        // …
    }
}
```

The `spacing` parameter is the morphing threshold — glass surfaces within this distance blend into one shape during transitions.

## Light / dark

Liquid Glass adapts automatically to both modes. **Don't** override `.foregroundStyle` on glass-prominent buttons — the system computes the correct contrast color from the tint. Apply only when you have a specific semantic need (e.g. white-on-red for a destructive action).

For the few places we still need explicit `NSColor` palettes (TextKit-driven native markdown view in `MarkdownViews.swift`), we use `AppTheme.nsCodeBlockFill` / `AppTheme.nsQuoteBarFill` — dynamic NSColors backed by `adaptiveNSColor(light:dark:)` and wrapped in `DynamicFillView` so the layer's `cgColor` re-resolves on appearance change.

## Available helpers (DesignSystem.swift)

```swift
// Non-button chrome surfaces
.appGlassCapsule()                                  // pill controls, chips
.appGlassCircle()                                   // icon-only chrome
.appGlassPanel(cornerRadius: CGFloat = 12)          // popovers, dropdowns

// Buttons → just use the system styles directly
.buttonStyle(.glass)
.buttonStyle(.glassProminent)
.buttonBorderShape(.capsule | .circle | .roundedRectangle(radius:))
.tint(Color)
```

## What this app **does not** use

- ❌ `.regularMaterial` / `.ultraThinMaterial` / `.thinMaterial` / `.thickMaterial` / `.ultraThickMaterial` — none. Zero matches in the codebase.
- ❌ `NSVisualEffectView` — none.
- ❌ `UIBlurEffect` (we're macOS, but worth stating: don't add this).
- ❌ `if #available(iOS 26)` / `if #available(macOS 26)` gates around glass APIs — the deployment target is macOS 26.
- ❌ `.glassEffect(...).interactive()` on `Button` — see the hit-testing section.
- ❌ `.presentationBackground(...)` on sheets — let the system apply glass.
- ❌ Glass on transcript message cards, list rows, file diffs, or any other content-layer surface.

## When you're adding a new surface

1. Is it tappable? → button style (`.glass` / `.glassProminent`).
2. Is it a pill / chip / capsule chrome? → `.appGlassCapsule()`.
3. Is it a popover / dropdown / floating panel? → `.appGlassPanel(cornerRadius:)`.
4. Is it a sheet? → no presentation background; system handles it.
5. Is it content? → no glass; use `AppTheme.contentFill` / semantic SwiftUI colors.
6. Multiple glass surfaces side by side? → wrap in `GlassEffectContainer`.

If in doubt, search this codebase for an existing surface of the same kind and match the pattern.
