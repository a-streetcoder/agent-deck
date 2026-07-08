import Foundation

/// One pickable item in the composer's `/` browser. Value type — built once per
/// panel open, then filtered/grouped purely in memory. No filesystem hits or
/// observable reads happen while the user is navigating the menu.
nonisolated enum SlashItemKind: String, Hashable, Sendable {
    case skill, prompt, command, loop
}

nonisolated struct SlashItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: SlashItemKind
    let displayName: String
    let description: String?
    let scopeLabel: String?
    let isActive: Bool
    let payload: Payload

    enum Payload: Hashable, Sendable {
        case skill(name: String, body: String, filePath: String?, recordID: String?)
        case skillCollection(id: UUID, name: String, body: String)
        case prompt(name: String, body: String, filePath: String?, recordID: String?)
        case command(slashName: String, commandID: String)
        case loopCreateNew
        case loopDefinition(LoopDefinition)
    }
}

/// Snapshot of all Skills / Prompts / Commands the composer can browse. Built
/// once when the `/` panel opens; held in `@State` for its lifetime so neither
/// typing nor scrolling re-runs the discovery.
nonisolated struct SlashUniverse: Hashable, Sendable {
    let skills: [SlashItem]
    let prompts: [SlashItem]
    let commands: [SlashItem]
    let loops: [SlashItem]

    static let empty = SlashUniverse(skills: [], prompts: [], commands: [], loops: [])

    var isEmpty: Bool { skills.isEmpty && prompts.isEmpty && commands.isEmpty && loops.isEmpty }

    func items(in kind: SlashItemKind) -> [SlashItem] {
        switch kind {
        case .skill: return skills
        case .prompt: return prompts
        case .command: return commands
        case .loop: return loops
        }
    }

    var allItems: [SlashItem] { skills + prompts + commands + loops }

    func item(withID id: String) -> SlashItem? {
        allItems.first { $0.id == id }
    }
}

extension SlashItem {
    /// Returns the message text that should be sent to Pi when this item is the
    /// composer's active slash selection and the user typed `userText` after it.
    /// Active commands and skills produce a real slash invocation (`/name args`,
    /// `/skill:name`). Inactive skills inline their body as message content
    /// since the extension isn't loaded in the running RPC process. Prompts
    /// pass through unchanged — their body was already seeded into the editor
    /// at pick-time.
    func materialize(userText: String) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch payload {
        case .command(let slashName, _):
            return trimmed.isEmpty ? slashName : "\(slashName) \(trimmed)"
        case .skill(let name, let body, _, _):
            if isActive {
                return trimmed.isEmpty ? "/skill:\(name)" : "/skill:\(name)\n\(trimmed)"
            }
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(trimmed)"
        case .skillCollection(_, _, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(trimmed)"
        case .prompt:
            return trimmed
        case .loopCreateNew, .loopDefinition:
            return trimmed
        }
    }

    /// Returns true for slash items that can be composed together. Commands,
    /// prompts, and loops remain singleton selections.
    var allowsMultiSelection: Bool {
        switch payload {
        case .skill, .skillCollection: return true
        case .command, .prompt, .loopCreateNew, .loopDefinition: return false
        }
    }

    /// Returns the next composer selection set after accepting `item`. Skills and
    /// skill collections accumulate; commands, prompts, and loops replace any
    /// existing selection.
    static func selections(afterAdding item: SlashItem, to existing: [SlashItem]) -> [SlashItem] {
        guard item.allowsMultiSelection else { return [item] }
        guard existing.allSatisfy(\.allowsMultiSelection) else { return [item] }
        guard !existing.contains(where: { $0.id == item.id }) else { return existing }
        return existing + [item]
    }

    /// Materializes the composer's selected slash items. A single selection keeps
    /// existing item-specific behavior (including active `/skill:name` calls).
    /// Multiple selections are only valid for skills/skill collections and are
    /// inlined as bodies before the user's text.
    static func materialize(selections: [SlashItem], userText: String) -> String {
        guard !selections.isEmpty else { return userText.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard selections.count > 1 else { return selections[0].materialize(userText: userText) }

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodies = selections.compactMap { item -> String? in
            switch item.payload {
            case .skill(_, let body, _, _), .skillCollection(_, _, let body):
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedBody.isEmpty ? nil : trimmedBody
            case .command, .prompt, .loopCreateNew, .loopDefinition:
                return nil
            }
        }
        return (bodies + (trimmed.isEmpty ? [] : [trimmed])).joined(separator: "\n\n")
    }

    /// Source text for automatic chat titles. Unlike `materialize`, this must
    /// not include inlined skill/prompt bodies or command implementation text.
    func titleGenerationSource(userText: String) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch payload {
        case .command:
            return trimmed
        case .skill, .skillCollection:
            return trimmed
        case .prompt(_, let body, _, _):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == trimmedBody { return "" }
            if trimmed.hasPrefix(trimmedBody) {
                return String(trimmed.dropFirst(trimmedBody.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        case .loopCreateNew, .loopDefinition:
            return trimmed
        }
    }

    static func titleGenerationSource(selections: [SlashItem], userText: String) -> String {
        guard !selections.isEmpty else { return userText.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard selections.count > 1 else { return selections[0].titleGenerationSource(userText: userText) }
        return userText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(query lowercasedQuery: String) -> Bool {
        if lowercasedQuery.isEmpty { return true }
        if displayName.lowercased().contains(lowercasedQuery) { return true }
        if let description, description.lowercased().contains(lowercasedQuery) { return true }
        if case .command(let slashName, _) = payload, slashName.lowercased().contains(lowercasedQuery) { return true }
        if case .skillCollection(_, let name, let body) = payload {
            if name.lowercased().contains(lowercasedQuery) { return true }
            if body.lowercased().contains(lowercasedQuery) { return true }
        }
        if case .loopCreateNew = payload, "loops".contains(lowercasedQuery) { return true }
        if case .loopDefinition(let definition) = payload {
            if definition.name.lowercased().contains(lowercasedQuery) { return true }
            if definition.goalTemplate.lowercased().contains(lowercasedQuery) { return true }
        }
        return false
    }
}

/// Persistent navigation state for the `/` browser, owned by the composer.
/// Re-uses the same lifecycle as path attachments — created on `/` trigger,
/// reset on dismiss or send.
struct SlashSuggestionState: Equatable {
    enum Screen: Equatable {
        case categoryPicker
        case category(SlashItemKind)
    }
    var screen: Screen = .categoryPicker
    var highlightedIndex: Int = 0
    /// Bumped only by keyboard navigation / typing — never by hover — so the
    /// highlight is scrolled into view only on keyboard interaction.
    var scrollTick: Int = 0
}

/// Lightweight render data for one item row in the `/` browser. Deliberately
/// excludes the full `SlashItem.Payload` body so SwiftUI row identity/diffing and
/// rendering never carry large skill or prompt text. Commit resolves the full
/// item from the cached `SlashUniverse` by `itemID`.
struct SlashSuggestionItemRow: Identifiable, Hashable {
    let id: String
    let itemID: String
    let kind: SlashItemKind
    let displayName: String
    let description: String?
    let scopeLabel: String?
    let isActive: Bool

    init(item: SlashItem) {
        id = item.id
        itemID = item.id
        kind = item.kind
        displayName = item.displayName
        description = item.description
        scopeLabel = item.scopeLabel
        isActive = item.isActive
    }
}

/// A renderable row in the `/` browser. Headers are non-selectable separators;
/// categories and items advance the highlight.
struct SlashSuggestionRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case category(SlashItemKind)
        case header(String)
        case item(SlashSuggestionItemRow)
    }
    let id: String
    let kind: Kind

    var isSelectable: Bool {
        switch kind {
        case .category, .item: return true
        case .header: return false
        }
    }
}

enum SlashSuggestionRowBuilder {
    /// Pure function over (universe, state, query) → rows. Called from `.onChange`
    /// in the composer, never from a SwiftUI `body` directly.
    static func rows(
        universe: SlashUniverse,
        state: SlashSuggestionState,
        query: String
    ) -> [SlashSuggestionRow] {
        let lowered = query.lowercased()
        switch state.screen {
        case .categoryPicker:
            if lowered.isEmpty {
                return [SlashItemKind.command, .prompt, .skill, .loop]
                    .filter { !universe.items(in: $0).isEmpty }
                    .map { SlashSuggestionRow(id: "cat:\($0.rawValue)", kind: .category($0)) }
            }
            return globalSearchRows(universe: universe, query: lowered)
        case .category(let kind):
            return categoryRows(universe: universe, kind: kind, query: lowered)
        }
    }

    /// Selectable rows in display order — used by keyboard nav to clamp the
    /// highlight and by the accept handler to resolve the chosen item.
    static func selectableRows(_ rows: [SlashSuggestionRow]) -> [SlashSuggestionRow] {
        rows.filter(\.isSelectable)
    }

    private static func globalSearchRows(universe: SlashUniverse, query lowered: String) -> [SlashSuggestionRow] {
        var rows: [SlashSuggestionRow] = []
        for kind in [SlashItemKind.command, .prompt, .skill, .loop] {
            let matched = universe.items(in: kind).filter { $0.matches(query: lowered) }
            guard !matched.isEmpty else { continue }
            rows.append(SlashSuggestionRow(id: "global-head:\(kind.rawValue)", kind: .header(headerLabel(for: kind))))
            for item in matched.sorted(by: activeFirstThenAlpha) {
                rows.append(SlashSuggestionRow(id: "item:\(item.id)", kind: .item(SlashSuggestionItemRow(item: item))))
            }
        }
        return rows
    }

    private static func categoryRows(universe: SlashUniverse, kind: SlashItemKind, query lowered: String) -> [SlashSuggestionRow] {
        let items = universe.items(in: kind)
        let matched = lowered.isEmpty ? items : items.filter { $0.matches(query: lowered) }
        let active = matched.filter(\.isActive)
        let inactive = matched.filter { !$0.isActive }

        var rows: [SlashSuggestionRow] = []
        if !active.isEmpty {
            if !inactive.isEmpty {
                rows.append(SlashSuggestionRow(id: "head:active", kind: .header("Active")))
            }
            for item in active {
                rows.append(SlashSuggestionRow(id: "item:\(item.id)", kind: .item(SlashSuggestionItemRow(item: item))))
            }
        }
        if !inactive.isEmpty {
            rows.append(SlashSuggestionRow(id: "head:available", kind: .header("Available")))
            for item in inactive {
                rows.append(SlashSuggestionRow(id: "item:\(item.id)", kind: .item(SlashSuggestionItemRow(item: item))))
            }
        }
        return rows
    }

    private static func activeFirstThenAlpha(_ a: SlashItem, _ b: SlashItem) -> Bool {
        if a.isActive != b.isActive { return a.isActive && !b.isActive }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    private static func headerLabel(for kind: SlashItemKind) -> String {
        switch kind {
        case .command: return "Commands"
        case .prompt: return "Prompts"
        case .skill: return "Skills"
        case .loop: return "Loops"
        }
    }
}
