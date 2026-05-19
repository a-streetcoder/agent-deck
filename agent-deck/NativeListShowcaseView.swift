import SwiftUI

// MARK: - Sample Data

private struct SItem: Identifiable {
    var id = UUID()
    var label: String
    var icon: String
}

private struct SGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [SItem]
}

private struct SNode: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    var children: [SNode]?
}

private let sampleRows: [SItem] = [
    .init(label: "Documents", icon: "doc.fill"),
    .init(label: "Downloads", icon: "arrow.down.circle.fill"),
    .init(label: "Desktop", icon: "desktopcomputer"),
    .init(label: "Pictures", icon: "photo.fill"),
    .init(label: "Music", icon: "music.note"),
    .init(label: "Movies", icon: "film.fill"),
]

private let sampleGroups: [SGroup] = [
    .init(title: "Favorites", items: [
        .init(label: "Desktop", icon: "desktopcomputer"),
        .init(label: "Documents", icon: "doc.fill"),
    ]),
    .init(title: "Locations", items: [
        .init(label: "Macintosh HD", icon: "internaldrive.fill"),
        .init(label: "Network", icon: "network"),
    ]),
    .init(title: "Tags", items: [
        .init(label: "Red", icon: "tag.fill"),
        .init(label: "Blue", icon: "tag.fill"),
        .init(label: "Green", icon: "tag.fill"),
    ]),
]

private let sampleTree: [SNode] = [
    .init(label: "Applications", icon: "app.fill", children: [
        .init(label: "Utilities", icon: "folder.fill", children: [
            .init(label: "Terminal", icon: "terminal.fill"),
            .init(label: "Activity Monitor", icon: "chart.bar.fill"),
        ]),
        .init(label: "Safari", icon: "safari.fill"),
        .init(label: "Mail", icon: "envelope.fill"),
    ]),
    .init(label: "System", icon: "gear", children: [
        .init(label: "Library", icon: "books.vertical.fill"),
    ]),
    .init(label: "Users", icon: "person.2.fill"),
]

// MARK: - Layout Constants

private let cardListHeight: CGFloat = 180
private let twoCol = [GridItem(.flexible()), GridItem(.flexible())]
private let threeCol = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

// MARK: - Screen

struct NativeListShowcaseScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Native List Showcase")
                        .font(.largeTitle.weight(.bold))
                    Text("macOS 26 · Default system appearance · No custom theming")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ShowcaseSection("List Styles") { ListStylesSection() }
                ShowcaseSection("Section Features") { SectionsSection() }
                ShowcaseSection("Row Modifiers") { RowModifiersSection() }
                ShowcaseSection("Item Tint") { ItemTintSection() }
                ShowcaseSection("Selection") { SelectionSection() }
                ShowcaseSection("Swipe Actions") { SwipeActionsSection() }
                ShowcaseSection("Context Menu") { ContextMenuSection() }
                ShowcaseSection("Edit Mode") { EditModeSection() }
                ShowcaseSection("Hierarchical (Tree)") { HierarchicalSection() }
                ShowcaseSection("Environment Values") { EnvironmentValuesSection() }
            }
            .padding(32)
        }
    }
}

// MARK: - Reusable Layout

private struct ShowcaseSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Divider()
            }
            content()
        }
    }
}

// MARK: - List Styles

private struct ListStylesSection: View {
    var body: some View {
        LazyVGrid(columns: threeCol, spacing: 20) {
            GroupBox(".plain") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.plain)
                .frame(height: cardListHeight)
            }

            GroupBox(".inset") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox(".bordered") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.bordered)
                .frame(height: cardListHeight)
            }

            GroupBox(".inset + .alternatingRowBackgrounds()") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .frame(height: cardListHeight)
            }

            GroupBox(".bordered + .alternatingRowBackgrounds()") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .frame(height: cardListHeight)
            }

            GroupBox(".sidebar (with sections)") {
                List {
                    ForEach(sampleGroups) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                Label(item.label, systemImage: item.icon)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Section Features

private struct SectionsSection: View {
    @State private var isExpanded1 = true
    @State private var isExpanded2 = false

    var body: some View {
        LazyVGrid(columns: twoCol, spacing: 20) {
            GroupBox("String header") {
                List {
                    ForEach(sampleGroups) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                Label(item.label, systemImage: item.icon)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("View header { } + footer { }") {
                List {
                    Section {
                        ForEach(sampleGroups[0].items) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                    } header: {
                        Label("Favorites", systemImage: "star.fill")
                            .font(.headline)
                    } footer: {
                        Text("Your most visited locations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("Collapsible — Section(isExpanded:) — .sidebar only") {
                List {
                    Section("Favorites", isExpanded: $isExpanded1) {
                        ForEach(sampleGroups[0].items) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                    Section("Locations", isExpanded: $isExpanded2) {
                        ForEach(sampleGroups[1].items) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(height: cardListHeight)
            }

            GroupBox("Section separators: tinted first, hidden second") {
                List {
                    Section("First") {
                        ForEach(sampleGroups[0].items) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                    .listSectionSeparatorTint(.blue)

                    Section("Second") {
                        ForEach(sampleGroups[1].items) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                    .listSectionSeparator(.hidden)
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Row Modifiers

private struct RowModifiersSection: View {
    var body: some View {
        LazyVGrid(columns: twoCol, spacing: 20) {
            GroupBox("listRowBackground — per-row custom background") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .listRowBackground(
                            item.label == "Documents" ? Color.blue.opacity(0.12) :
                            item.label == "Downloads" ? Color.green.opacity(0.12) :
                            item.label == "Desktop"   ? Color.orange.opacity(0.12) :
                            nil
                        )
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("listRowInsets — leading: 40, vertical: 10") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .listRowInsets(EdgeInsets(top: 10, leading: 40, bottom: 10, trailing: 16))
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("listRowSeparator(.hidden) — all edges") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("listRowSeparator(.hidden, edges: .top)") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .listRowSeparator(.hidden, edges: .top)
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("listRowSeparatorTint(.purple)") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .listRowSeparatorTint(.purple)
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }

            GroupBox("scrollContentBackground(.hidden) + custom bg") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(.teal.opacity(0.12))
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Item Tint

private struct ItemTintSection: View {
    var body: some View {
        LazyVGrid(columns: threeCol, spacing: 20) {
            GroupBox(".listItemTint(.fixed(.orange))") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .listItemTint(.fixed(.orange))
                .frame(height: cardListHeight)
            }

            GroupBox(".listItemTint(.preferred(.green))") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .listItemTint(.preferred(.green))
                .frame(height: cardListHeight)
            }

            GroupBox(".listItemTint(.monochrome)") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .listItemTint(.monochrome)
                .frame(height: cardListHeight)
            }

            GroupBox("Per-row .listItemTint(.fixed(_:))") {
                let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
                List(Array(sampleRows.enumerated()), id: \.element.id) { i, item in
                    Label(item.label, systemImage: item.icon)
                        .listItemTint(.fixed(colors[i % colors.count]))
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Selection

private struct SelectionSection: View {
    @State private var singleSel: UUID? = nil
    @State private var multiSel: Set<UUID> = []

    var body: some View {
        LazyVGrid(columns: twoCol, spacing: 20) {
            GroupBox("Single selection — Binding<UUID?>") {
                VStack(alignment: .leading, spacing: 6) {
                    List(sampleRows, selection: $singleSel) { item in
                        Label(item.label, systemImage: item.icon)
                            .tag(item.id)
                    }
                    .listStyle(.inset)
                    .frame(height: cardListHeight)

                    if let sel = singleSel, let item = sampleRows.first(where: { $0.id == sel }) {
                        Text("Selected: \(item.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Click a row to select")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            GroupBox("Multiple selection — Binding<Set<UUID>> (Cmd/Shift+click)") {
                VStack(alignment: .leading, spacing: 6) {
                    List(sampleRows, selection: $multiSel) { item in
                        Label(item.label, systemImage: item.icon)
                            .tag(item.id)
                    }
                    .listStyle(.inset)
                    .frame(height: cardListHeight)

                    if multiSel.isEmpty {
                        Text("Cmd+click to select multiple rows")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(multiSel.count) of \(sampleRows.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Swipe Actions

private struct SwipeActionsSection: View {
    var body: some View {
        LazyVGrid(columns: twoCol, spacing: 20) {
            GroupBox("Trailing swipe actions") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.blue)
                        }
                }
                .listStyle(.plain)
                .frame(height: cardListHeight)
            }

            GroupBox("Leading + trailing · allowsFullSwipe: false on trailing") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                        .swipeActions(edge: .leading) {
                            Button { } label: {
                                Label("Flag", systemImage: "flag.fill")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.plain)
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Context Menu

private struct ContextMenuSection: View {
    @State private var lastAction = ""

    var body: some View {
        GroupBox("contextMenu — right-click any row\(lastAction.isEmpty ? "" : " · Last: \(lastAction)")") {
            List(sampleRows) { item in
                Label(item.label, systemImage: item.icon)
                    .contextMenu {
                        Button("Open \(item.label)") { lastAction = "Open \(item.label)" }
                        Button("Reveal in Finder") { lastAction = "Reveal \(item.label)" }
                        Divider()
                        Button("Copy Name") { lastAction = "Copy \(item.label)" }
                        Button("Delete", role: .destructive) { lastAction = "Delete \(item.label)" }
                    }
            }
            .listStyle(.inset)
            .frame(height: cardListHeight)
        }
    }
}

// MARK: - Edit Mode

private struct EditModeSection: View {
    @State private var deletable = sampleRows
    @State private var movable = sampleRows
    @State private var bothEditable = sampleRows

    var body: some View {
        LazyVGrid(columns: threeCol, spacing: 20) {
            GroupBox("onDelete — Delete key or swipe") {
                VStack(alignment: .leading, spacing: 6) {
                    List {
                        ForEach(deletable) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                        .onDelete { deletable.remove(atOffsets: $0) }
                    }
                    .listStyle(.inset)
                    .frame(height: cardListHeight)

                    Button("Reset") { deletable = sampleRows }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }

            GroupBox("onMove — drag handle to reorder") {
                VStack(alignment: .leading, spacing: 6) {
                    List {
                        ForEach(movable) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                        .onMove { movable.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.inset)
                    .frame(height: cardListHeight)

                    Button("Reset") { movable = sampleRows }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }

            GroupBox("onDelete + onMove (both)") {
                VStack(alignment: .leading, spacing: 6) {
                    List {
                        ForEach(bothEditable) { item in
                            Label(item.label, systemImage: item.icon)
                        }
                        .onDelete { bothEditable.remove(atOffsets: $0) }
                        .onMove { bothEditable.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.inset)
                    .frame(height: cardListHeight)

                    Button("Reset") { bothEditable = sampleRows }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - Hierarchical

private struct HierarchicalSection: View {
    var body: some View {
        LazyVGrid(columns: twoCol, spacing: 20) {
            GroupBox("List(data, children: \\.children) — .sidebar") {
                List(sampleTree, children: \.children) { node in
                    Label(node.label, systemImage: node.icon)
                }
                .listStyle(.sidebar)
                .frame(height: cardListHeight)
            }

            GroupBox("List(data, children: \\.children) — .inset") {
                List(sampleTree, children: \.children) { node in
                    Label(node.label, systemImage: node.icon)
                }
                .listStyle(.inset)
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Environment Values

private struct EnvironmentValuesSection: View {
    var body: some View {
        LazyVGrid(columns: twoCol, spacing: 20) {
            GroupBox("defaultMinListRowHeight = 44 (tall rows)") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 44)
                .frame(height: cardListHeight)
            }

            GroupBox("defaultMinListRowHeight = 18 (compact rows)") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 18)
                .frame(height: cardListHeight)
            }

            GroupBox("defaultMinListHeaderHeight = 48 (tall section headers)") {
                List {
                    ForEach(sampleGroups.prefix(2)) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                Label(item.label, systemImage: item.icon)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListHeaderHeight, 48)
                .frame(height: cardListHeight)
            }

            GroupBox(".alternatingRowBackgrounds(.disabled) — overrides style default") {
                List(sampleRows) { item in
                    Label(item.label, systemImage: item.icon)
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .frame(height: cardListHeight)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NativeListShowcaseScreen()
        .frame(width: 1280, height: 900)
}
