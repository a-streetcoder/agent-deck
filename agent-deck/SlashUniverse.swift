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
        case skill(name: String, body: String)
        case skillCollection(name: String, body: String)
        case prompt(name: String, body: String)
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
        case .skill(let name, let body):
            if isActive {
                return trimmed.isEmpty ? "/skill:\(name)" : "/skill:\(name)\n\(trimmed)"
            }
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(trimmed)"
        case .skillCollection(_, let body):
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(trimmed)"
        case .prompt:
            return trimmed
        case .loopCreateNew, .loopDefinition:
            return trimmed
        }
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
        case .prompt(_, let body):
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

    func matches(query lowercasedQuery: String) -> Bool {
        if lowercasedQuery.isEmpty { return true }
        if displayName.lowercased().contains(lowercasedQuery) { return true }
        if let description, description.lowercased().contains(lowercasedQuery) { return true }
        if case .command(let slashName, _) = payload, slashName.lowercased().contains(lowercasedQuery) { return true }
        if case .skillCollection(let name, let body) = payload {
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

/// A renderable row in the `/` browser. Headers are non-selectable separators;
/// categories and items advance the highlight.
struct SlashSuggestionRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case category(SlashItemKind)
        case header(String)
        case item(SlashItem)
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
                rows.append(SlashSuggestionRow(id: "item:\(item.id)", kind: .item(item)))
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
                rows.append(SlashSuggestionRow(id: "item:\(item.id)", kind: .item(item)))
            }
        }
        if !inactive.isEmpty {
            rows.append(SlashSuggestionRow(id: "head:available", kind: .header("Available")))
            for item in inactive {
                rows.append(SlashSuggestionRow(id: "item:\(item.id)", kind: .item(item)))
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
