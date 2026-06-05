import AppKit
import SwiftUI

// MARK: - AppList
//
// The single, standardized selectable-list primitive for Agent Deck. Every
// in-app list that needs themed selection (sidebar, sessions, agents, skills,
// prompts, and any future list) should use this — do NOT build one-off custom
// lists. Consistency comes from one place.
//
// Why this exists instead of native `List(selection:)`:
//   - macOS `List(selection:)` paints its selection chrome from
//     `NSColor.controlAccentColor` (the asset-catalog `AccentColor`) for
//     `.sidebar` and `.inset` styles, regardless of `.tint(…)`. That means
//     row selection never tracks an in-app theme accent.
//   - We render the list ourselves with `ScrollView` + `LazyVStack` so the
//     selection chip, hover state, padding, and corners are 100% our chrome
//     keyed off `AppTheme.brandAccent`.
//
// What this trades off vs. native `List(selection:)`:
//   ✓ Sections with custom section headers
//   ✓ Single OR multi selection (Finder-style: plain / ⌘ / ⇧)
//   ✓ Mouse hover + click selection
//   ✓ ↑ / ↓ keyboard navigation while focused
//   ✓ Per-row `.contextMenu { … }` (attach inside the row builder)
//   ✗ No `.swipeActions` (native-only API) — use context menu or a
//     hover-revealed pill instead
//   ✗ No native section-collapse affordance
//
// Usage:
//   AppList(
//       sections: [AppListSection(id: "items", title: nil, items: items)],
//       selection: .single($selectedID),
//       isDisabled: { _ in false }
//   ) { item in
//       MyRow(item)
//           .contextMenu { … }
//   }

// MARK: - Section descriptor

/// One section in an `AppList`. `id` must be stable across renders.
/// - `title` — `nil` to render the section with no header.
/// - `info` — optional help-popover text rendered as a `?` next to the title.
/// - `items` — the rows. If empty and `emptyMessage` is set, that row renders
///   in place of the items as a secondary-color placeholder.
struct AppListSection<Item: Identifiable & Hashable>: Identifiable {
    let id: String
    let title: String?
    let info: String?
    let items: [Item]
    let emptyMessage: String?

    init(
        id: String,
        title: String? = nil,
        info: String? = nil,
        items: [Item],
        emptyMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.info = info
        self.items = items
        self.emptyMessage = emptyMessage
    }
}

// MARK: - Selection mode

/// Selection binding for `AppList`. Use `.single` for one-at-a-time selection
/// (sidebar, agents, prompts) and `.multi` for Finder-style multi-selection
/// with ⌘/⇧ click (sessions, skills).
enum AppListSelection<ID: Hashable> {
    case single(Binding<ID?>)
    case multi(Binding<Set<ID>>)
}

// MARK: - List

struct AppList<Item: Identifiable & Hashable, RowContent: View>: View {
    let sections: [AppListSection<Item>]
    let selection: AppListSelection<Item.ID>
    /// Per-item enable predicate. Disabled rows render at reduced opacity and
    /// do not respond to clicks or keyboard navigation.
    var isDisabled: (Item) -> Bool = { _ in false }
    /// Optional per-row tint. When non-`nil` and the row is NOT selected,
    /// the row chrome is filled with this color (typically at low alpha) to
    /// signal an attribute like "needs attention" without changing the
    /// theme-driven selection chip. Selection overrides this.
    var rowTint: (Item) -> Color? = { _ in nil }
    /// Opt-in arrow-key navigation. OFF by default to avoid installing focus
    /// handlers on lists that don't need them (resource lists, sessions —
    /// where the user clicks). Turn ON for primary nav (sidebar).
    var keyboardNavigation: Bool = false
    /// Corner radius for both the selection chip and the hit area.
    var cornerRadius: CGFloat = AppListMetrics.cornerRadius
    /// Padding between row content and the rounded chip edge.
    var rowHorizontalPadding: CGFloat = AppListMetrics.rowHorizontalPadding
    /// Padding above and below row content.
    var rowVerticalPadding: CGFloat = AppListMetrics.rowVerticalPadding
    /// Outer inset between the chip and the list's scroll-area edges.
    var listHorizontalInset: CGFloat = AppListMetrics.listHorizontalInset

    @ViewBuilder let row: (Item) -> RowContent

    @FocusState private var isFocused: Bool
    /// Anchor for shift-click range selection in `.multi` mode — last item
    /// the user single-clicked (or the last extent of a shift-click range).
    @State private var anchorID: Item.ID?

    /// Flat order across sections used for keyboard navigation.
    private var navigableItems: [Item] {
        sections.flatMap { $0.items.filter { !isDisabled($0) } }
    }

    var body: some View {
        // Perf-critical notes:
        //   - `.hideNativeScrollers()` keeps AppList chrome consistent when
        //     macOS is configured to always show scroll bars.
        //   - Focus + arrow-key handlers attach ONLY when the caller opts
        //     into `keyboardNavigation`.
        //   - Selection state is snapshotted ONCE per body eval into a
        //     `SelectionSnapshot`, so each row gets a cheap `Bool` check
        //     instead of reading the binding per row.
        //   - The first-section id is cached so we don't re-equate per row.
        let selectionSnapshot = SelectionSnapshot(selection: selection)
        let firstSectionID = sections.first?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppListMetrics.rowSpacing) {
                ForEach(sections) { section in
                    if let title = section.title {
                        AppListSectionHeaderView(title: title, info: section.info)
                            .padding(.top, firstSectionID == section.id ? AppTheme.Split.contentTopInset : 16)
                            .padding(.bottom, 2)
                    }

                    if section.items.isEmpty {
                        if let message = section.emptyMessage {
                            AppListEmptyRow(message: message)
                        }
                    } else {
                        ForEach(section.items) { item in
                            AppListRow(
                                isSelected: selectionSnapshot.contains(item.id),
                                isDisabled: isDisabled(item),
                                tint: rowTint(item),
                                cornerRadius: cornerRadius,
                                horizontalPadding: rowHorizontalPadding,
                                verticalPadding: rowVerticalPadding,
                                onSelect: { handleTap(item) },
                                content: { row(item) }
                            )
                            .id(item.id)
                        }
                    }
                }
            }
            .padding(.horizontal, listHorizontalInset)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.never`, not `.hidden`: `.hidden` still lets AppKit briefly *flash* the
        // overlay scroller when the content size changes — which a list hits as its
        // rows lay out on appear (most visible on the Skills list, whose warning
        // strip + sections grow the content height). `.never` suppresses the
        // reservation entirely so there's no flash. `.hideNativeScrollers()` then
        // guarantees no scroller even when macOS is set to always show scroll bars.
        .scrollIndicators(.never)
        .hideNativeScrollers()
        .modifier(AppListKeyboardNavigation(
            enabled: keyboardNavigation,
            isFocused: $isFocused,
            onMove: moveSelection
        ))
    }

    private func handleTap(_ item: Item) {
        guard !isDisabled(item) else { return }
        switch selection {
        case .single(let binding):
            binding.wrappedValue = item.id
            anchorID = item.id
        case .multi(let binding):
            let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmd = modifiers.contains(.command)
            let isShift = modifiers.contains(.shift)

            if isShift, let anchor = anchorID {
                binding.wrappedValue = idsInRange(from: anchor, to: item.id)
            } else if isCmd {
                if binding.wrappedValue.contains(item.id) {
                    binding.wrappedValue.remove(item.id)
                } else {
                    binding.wrappedValue.insert(item.id)
                }
                anchorID = item.id
            } else {
                binding.wrappedValue = [item.id]
                anchorID = item.id
            }
        }
        isFocused = true
    }

    private func idsInRange(from anchor: Item.ID, to target: Item.ID) -> Set<Item.ID> {
        let flat = navigableItems
        guard let a = flat.firstIndex(where: { $0.id == anchor }),
              let b = flat.firstIndex(where: { $0.id == target })
        else { return [target] }
        let lo = min(a, b), hi = max(a, b)
        return Set(flat[lo...hi].map(\.id))
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let flat = navigableItems
        guard !flat.isEmpty else { return }

        let currentID: Item.ID? = {
            switch selection {
            case .single(let binding): return binding.wrappedValue
            case .multi(let binding): return binding.wrappedValue.first
            }
        }()

        guard let current = currentID,
              let idx = flat.firstIndex(where: { $0.id == current }) else {
            apply(flat.first?.id)
            return
        }

        switch direction {
        case .up where idx > 0:
            apply(flat[idx - 1].id)
        case .down where idx + 1 < flat.count:
            apply(flat[idx + 1].id)
        default:
            break
        }
    }

    private func apply(_ id: Item.ID?) {
        switch selection {
        case .single(let binding):
            binding.wrappedValue = id
        case .multi(let binding):
            if let id { binding.wrappedValue = [id] } else { binding.wrappedValue = [] }
        }
        anchorID = id
    }
}

// MARK: - Selection snapshot

/// Snapshot of the selection binding's value, taken once per `AppList` body
/// eval so per-row selection checks don't repeatedly read the binding.
/// Reading `Binding<...>.wrappedValue` is cheap individually but does involve
/// observation-system bookkeeping; doing it N times per render adds up on
/// long lists.
private enum SelectionSnapshot<ID: Hashable> {
    case single(ID?)
    case multi(Set<ID>)

    init(selection: AppListSelection<ID>) {
        switch selection {
        case .single(let binding): self = .single(binding.wrappedValue)
        case .multi(let binding): self = .multi(binding.wrappedValue)
        }
    }

    @inline(__always)
    func contains(_ id: ID) -> Bool {
        switch self {
        case .single(let current): return current == id
        case .multi(let set): return set.contains(id)
        }
    }
}

// MARK: - Keyboard navigation modifier

/// Conditionally attaches focus + arrow-key handlers to an `AppList`. When
/// disabled, this is a true no-op (no `.focusable()`, no event monitor), so
/// lists that don't need keyboard nav pay nothing.
private struct AppListKeyboardNavigation: ViewModifier {
    let enabled: Bool
    @FocusState.Binding var isFocused: Bool
    let onMove: (MoveCommandDirection) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onMoveCommand(perform: onMove)
        } else {
            content
        }
    }
}

// MARK: - Shared row chrome

/// Shared row chrome for `AppList`. Themed background, hover state, hit area,
/// disabled opacity — every list row in the app passes through this.
///
/// Implementation note: uses `Button(action:)` `.buttonStyle(.plain)` rather
/// than `.onTapGesture`. SwiftUI gives nested `Button`s (e.g. the inline
/// "Edit" pill inside an agent row) priority over outer ones, and nested
/// `.onTapGesture` calls inside row content (e.g. the session row's
/// modifier-aware tap) also win, so caller-installed handlers still fire
/// without regression — and we get native macOS press feedback for free.
private struct AppListRow<Content: View>: View {
    let isSelected: Bool
    let isDisabled: Bool
    /// Per-row tint (e.g., warning highlight). Selection overrides.
    let tint: Color?
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        // Conditional disabled/opacity: skip both modifiers entirely when the
        // row is enabled. `.disabled(false)` and `.opacity(1)` are not free —
        // each one keeps SwiftUI tracking and a CALayer property — and most
        // rows in most lists are enabled. The branch consolidates to a single
        // path for the common case.
        Button(action: { if !isDisabled { onSelect() } }) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(rowBackground)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(AppListRowDisabledModifier(isDisabled: isDisabled))
        .onHover { hovering in
            isHovering = hovering && !isDisabled
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if isSelected {
            shape.fill(AppListMetrics.selectionFill)
        } else if let tint {
            shape.fill(tint)
        } else if isHovering {
            shape.fill(AppListMetrics.hoverFill)
        } else {
            shape.fill(Color.clear)
        }
    }
}

/// Conditional disabled/opacity modifier for `AppListRow`. The vast majority
/// of rows are enabled — keeping `.disabled(false)` and `.opacity(1)` always-
/// on costs SwiftUI tracking on every row. Branching the modifier collapses
/// the common path to no extra modifiers at all.
private struct AppListRowDisabledModifier: ViewModifier {
    let isDisabled: Bool

    func body(content: Content) -> some View {
        if isDisabled {
            content.disabled(true).opacity(0.5)
        } else {
            content
        }
    }
}

/// Empty-state row rendered when a section's `items` is empty and an
/// `emptyMessage` was provided. Matches the previous `nativeEmptyRow` helper
/// used inside native `List` sections.
private struct AppListEmptyRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppListMetrics.rowHorizontalPadding)
            .padding(.vertical, AppListMetrics.rowVerticalPadding + 2)
    }
}

// MARK: - Section header

/// Header for an `AppList` section. Matches macOS sidebar section header
/// proportions (small caps, secondary color) but stays theme-aware. When
/// `info` is non-`nil` a help-popover affordance renders next to the title.
private struct AppListSectionHeaderView: View {
    let title: String
    let info: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(AppTheme.mutedText)
            if let info {
                AppHelpButton(title: title, text: info)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Shared metrics

/// Single source of truth for `AppList` visual tokens. Don't hard-code these
/// elsewhere — pass overrides through `AppList`'s init if a specific list
/// needs different geometry, but think hard before diverging.
enum AppListMetrics {
    static let cornerRadius: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 2
    static let listHorizontalInset: CGFloat = 8
    /// Themed selection chip. Sits at the soft end of the accent range so the
    /// row stays readable while clearly marked.
    static var selectionFill: Color { AppTheme.brandAccent.opacity(0.22) }
    /// Hover wash. Neutral so it doesn't compete with the themed selection.
    static let hoverFill = Color.primary.opacity(0.06)
}
