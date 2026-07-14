import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Shared `JSONDecoder` for view-layer payload decoding. Reused so SwiftUI
/// computed properties don't allocate a fresh decoder on every `body` eval.
private let transcriptJSONDecoder = JSONDecoder()

/// Memoizes a parse done from a source string, so a SwiftUI computed property
/// doesn't re-decode JSON on every `body` evaluation. The result is a pure
/// function of the source string — the cache never goes stale — and keys carry
/// a call-site discriminator so different parses of the same string can't
/// collide. Bounded LRU. A cast miss simply recomputes, so it is always safe.
@MainActor
enum JSONParseMemo {
    private static var cache: [String: Any] = [:]
    private static var order: [String] = []
    private static let limit = 256

    /// Discriminator and source must be joined with this so a source string
    /// can never be confused for a different call site's key.
    static let separator = "\u{1}"

    static func value<T>(_ key: String, parse: () -> T) -> T {
        if let cached = cache[key], let typed = cached as? T {
            return typed
        }
        let value = parse()
        cache[key] = value
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return value
    }
}

struct PiAgentThreadToolGroup: Hashable {
    var id: UUID
    var entries: [PiAgentTranscriptEntry]
    // Activities are computed once at thread-build time (per publish), not per render.
    // PiAgentTranscriptActivity.make is O(entries) and would otherwise run on every body
    // re-evaluation during streaming.
    var activities: [PiAgentTranscriptActivity]
}

enum PiAgentThreadChild: Hashable, Identifiable {
    case steering(PiAgentTranscriptEntry)
    case thinking(PiAgentTranscriptEntry)
    case assistant(PiAgentTranscriptEntry)
    case toolGroup(PiAgentThreadToolGroup)
    case status(PiAgentTranscriptEntry)
    case error(PiAgentTranscriptEntry)
    /// A Pi auto-retry burst, collapsed to one entry. `ProviderRetryInfo` is parsed
    /// once here at thread-build time so the card never re-parses during render.
    case retry(PiAgentTranscriptEntry, ProviderRetryInfo)

    var id: String {
        switch self {
        case .steering(let e): return "st-\(e.id.uuidString)"
        case .thinking(let e): return "th-\(e.id.uuidString)"
        case .assistant(let e): return "as-\(e.id.uuidString)"
        case .toolGroup(let g): return "tg-\(g.id.uuidString)"
        case .status(let e): return "ss-\(e.id.uuidString)"
        case .error(let e): return "er-\(e.id.uuidString)"
        case .retry(let e, _): return "rt-\(e.id.uuidString)"
        }
    }
}

struct PiAgentTranscriptThread: Identifiable, Hashable {
    var id: UUID
    var question: PiAgentTranscriptEntry?
    var steeringMessages: [PiAgentTranscriptEntry]
    // Thinking entries are kept as a list (not merged into one) so they can be rendered
    // at their actual timestamp position in the timeline. Merging the post-tool thinking
    // back to the top would push already-rendered tool activities down on every new
    // thinking_delta — the source of the "thinking block jumps content around" issue.
    var thinkingParts: [PiAgentTranscriptEntry]
    var assistantMessages: [PiAgentTranscriptEntry]
    var activities: [PiAgentTranscriptActivity]
    var statuses: [PiAgentTranscriptEntry]
    var errors: [PiAgentTranscriptEntry]
    // Chronological children for rendering. The card body iterates this list in order,
    // so each entry lands at the position it arrived. Consecutive tool/error entries fold
    // into a single `.toolGroup` so multi-tool bursts still aggregate into one summary
    // card. Anything else (thinking, assistant, status, non-tool error) renders as its
    // own row. This is what gives zero jumpiness: only the bottom-most child ever grows
    // because new arrivals always have a later timestamp.
    var children: [PiAgentThreadChild]

    @MainActor
    static func make(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptThread] {
        var threads: [PiAgentTranscriptThread] = []
        var builder = Builder()

        func flush() {
            guard let thread = builder.makeThread() else { return }
            threads.append(thread)
            builder = Builder()
        }

        for entry in entries {
            if entry.role == .status && entry.title == "Compaction" {
                flush()
                builder.add(entry)
                flush()
            } else if entry.role == .user && entry.title != "Steering" {
                flush()
                builder.question = entry
            } else {
                builder.add(entry)
            }
        }
        flush()
        return threads
    }

    private struct Builder {
        // Category tag for arrival-order tracking. .toolError is split out from .error
        // so the renderer can fold tool-prefixed errors into adjacent tool groups while
        // non-tool errors (Launch Failed, Connection Error, etc.) stay as standalone
        // rows in their chronological position.
        enum ArrivalKind {
            case steering, thinking, assistant, tool, toolError, status, error
        }

        var question: PiAgentTranscriptEntry?
        var steeringMessages: [PiAgentTranscriptEntry] = []
        var thinkingParts: [PiAgentTranscriptEntry] = []
        var assistantMessages: [PiAgentTranscriptEntry] = []
        var toolEntries: [PiAgentTranscriptEntry] = []
        var statuses: [PiAgentTranscriptEntry] = []
        var errors: [PiAgentTranscriptEntry] = []
        // Same entries as above, kept in arrival order with a category tag. The renderer
        // walks this list to lay children out chronologically — preserving the order
        // events actually came off the RPC stream rather than re-sorting by timestamp
        // (which can tie or shift as entries get re-upserted during streaming).
        var arrivals: [(kind: ArrivalKind, entry: PiAgentTranscriptEntry)] = []

        mutating func add(_ entry: PiAgentTranscriptEntry) {
            switch entry.role {
            case .user where entry.title == "Steering":
                steeringMessages.append(entry)
                arrivals.append((.steering, entry))
            case .thinking:
                thinkingParts.append(entry)
                arrivals.append((.thinking, entry))
            case .assistant:
                assistantMessages.append(entry)
                arrivals.append((.assistant, entry))
            case .tool:
                toolEntries.append(entry)
                arrivals.append((.tool, entry))
            case .status, .stderr:
                statuses.append(entry)
                arrivals.append((.status, entry))
            case .error:
                errors.append(entry)
                arrivals.append((entry.title.hasPrefix("Tool: ") ? .toolError : .error, entry))
            case .user, .raw:
                statuses.append(entry)
                arrivals.append((.status, entry))
            }
        }

        @MainActor
        func makeThread() -> PiAgentTranscriptThread? {
            let activities = PiAgentTranscriptActivity.make(from: toolEntries)
            guard question != nil || !steeringMessages.isEmpty || !thinkingParts.isEmpty || !assistantMessages.isEmpty || !activities.isEmpty || !statuses.isEmpty || !errors.isEmpty else {
                return nil
            }
            let first = question ?? steeringMessages.first ?? thinkingParts.first ?? assistantMessages.first ?? activities.first?.representativeEntry ?? statuses.first ?? errors.first

            // Dedupe identical thinking texts (Pi sometimes re-emits a turn boundary's
            // prior thinking). Whitelisted ids drive both the per-role thinkingParts
            // array (used by the per-thread revision cache) and the chronological
            // children list (used by the renderer).
            var seenThinkingTexts = Set<String>()
            var allowedThinkingIDs = Set<UUID>()
            for entry in thinkingParts {
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seenThinkingTexts.insert(trimmed).inserted else { continue }
                allowedThinkingIDs.insert(entry.id)
            }
            let dedupedThinking = thinkingParts.filter { allowedThinkingIDs.contains($0.id) }

            // Coalesce compaction status entries to the latest one only. Skip the rest
            // when building the chronological list so the user doesn't see "Compacting
            // context…" stacking up across retries.
            var latestCompactionID: UUID?
            for entry in statuses where entry.title == "Compaction" {
                latestCompactionID = entry.id
            }

            let children = chronologicalChildren(
                allowedThinkingIDs: allowedThinkingIDs,
                latestCompactionID: latestCompactionID
            )

            return PiAgentTranscriptThread(
                id: question?.id ?? first?.id ?? UUID(),
                question: question,
                steeringMessages: steeringMessages,
                thinkingParts: dedupedThinking,
                assistantMessages: assistantMessages,
                activities: activities,
                statuses: coalescedStatuses(statuses),
                errors: coalescedErrors(errors),
                children: children
            )
        }

        // Walks arrivals in arrival order and produces the chronological children list.
        // Consecutive `.tool` and `.toolError` arrivals fold into a single `.toolGroup`;
        // any other kind seals the current group and emits its own child.
        private func chronologicalChildren(
            allowedThinkingIDs: Set<UUID>,
            latestCompactionID: UUID?
        ) -> [PiAgentThreadChild] {
            var children: [PiAgentThreadChild] = []
            var groupEntries: [PiAgentTranscriptEntry] = []

            func flushGroup() {
                guard !groupEntries.isEmpty else { return }
                let firstID = groupEntries.first?.id ?? UUID()
                let groupActivities = PiAgentTranscriptActivity.make(from: groupEntries)
                children.append(.toolGroup(PiAgentThreadToolGroup(
                    id: firstID,
                    entries: groupEntries,
                    activities: groupActivities
                )))
                groupEntries = []
            }

            for arrival in arrivals {
                switch arrival.kind {
                case .tool, .toolError:
                    groupEntries.append(arrival.entry)
                case .thinking:
                    guard allowedThinkingIDs.contains(arrival.entry.id) else { continue }
                    flushGroup()
                    children.append(.thinking(arrival.entry))
                case .steering:
                    flushGroup()
                    children.append(.steering(arrival.entry))
                case .assistant:
                    // Empty placeholders are filtered upstream in normalizedTranscriptEntry,
                    // so any assistant arrival that reaches here has visible text and is
                    // worth rendering.
                    flushGroup()
                    children.append(.assistant(arrival.entry))
                case .status:
                    if arrival.entry.title == "Compaction" && arrival.entry.id != latestCompactionID {
                        continue
                    }
                    flushGroup()
                    let normalized = arrival.entry.title == "Compaction"
                        ? normalizedCompaction(arrival.entry)
                        : arrival.entry
                    if normalized.title == "Retry", let retryInfo = ProviderRetryInfo(entry: normalized) {
                        // Collapse a retry burst into one card. Pi emits TWO entries per
                        // failed attempt — a paired `Model Error` (role:error) carrying the
                        // raw provider payload, immediately followed by the `Retry` status —
                        // so on Codex usage-limit bursts we used to render four Error cards
                        // and four hourglass cards for what's a single event. Drop the
                        // trailing paired Model Error(s) whose text matches this retry's
                        // payload, then collapse any adjacent retry (the prior attempt of
                        // the same burst). Only the final `auto_retry_end` survives — the
                        // repeating attempt text is still parsed at thread-build time so
                        // the card never re-parses during render.
                        let payload = retryInfo.errorPayload
                        while case .error(let prev)? = children.last,
                              prev.text == payload {
                            children.removeLast()
                        }
                        if case .retry? = children.last { children.removeLast() }
                        children.append(.retry(normalized, retryInfo))
                    } else {
                        children.append(.status(normalized))
                    }
                case .error:
                    flushGroup()
                    children.append(.error(arrival.entry))
                }
            }
            flushGroup()
            return children
        }

        private func coalescedStatuses(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
            var output: [PiAgentTranscriptEntry] = []
            var latestCompaction: PiAgentTranscriptEntry?
            for entry in entries {
                if entry.title == "Compaction" {
                    latestCompaction = entry
                } else {
                    output.append(entry)
                }
            }
            if let latestCompaction {
                output.append(normalizedCompaction(latestCompaction))
            }
            return output.sorted { $0.timestamp < $1.timestamp }
        }

        private func normalizedCompaction(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry {
            var copy = entry
            let text = entry.text
            if text.localizedCaseInsensitiveContains("nothing to compact") {
                copy.text = "Nothing to compact."
            } else if text.localizedCaseInsensitiveContains("compaction finished") || text.localizedCaseInsensitiveContains("compaction complete") {
                copy.text = text.localizedCaseInsensitiveContains("retrying turn") ? "Context compacted · retrying turn" : "Context compacted."
            } else if text.localizedCaseInsensitiveContains("is compacting") || text.localizedCaseInsensitiveContains("compacting conversation context") {
                copy.text = "Compacting context…"
            }
            return copy
        }

        private func coalescedErrors(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
            var output: [PiAgentTranscriptEntry] = []
            var seenNonToolTexts = Set<String>()
            var latestByTool: [String: PiAgentTranscriptEntry] = [:]
            var toolOrder: [String] = []
            for entry in entries {
                let key = PiAgentTranscriptActivity.toolName(for: entry)
                if entry.title.hasPrefix("Tool: ") {
                    if latestByTool[key] == nil { toolOrder.append(key) }
                    latestByTool[key] = normalizedToolError(entry)
                } else {
                    // Pi emits a paired (Model Error, Retry) per failed attempt, so a
                    // retry burst with the same underlying payload (e.g. a Codex
                    // usage-limit burst once credits are gone) would otherwise stack N
                    // identical Model Error rows here. Keep only the first per distinct
                    // text; the burst's final verdict is surfaced by the consolidated
                    // retry card.
                    if seenNonToolTexts.insert(entry.text).inserted {
                        output.append(entry)
                    }
                }
            }
            output.append(contentsOf: toolOrder.compactMap { latestByTool[$0] })
            return output.sorted { $0.timestamp < $1.timestamp }
        }

        private func normalizedToolError(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry {
            var copy = entry
            copy.text = entry.text
                .replacingOccurrences(of: "\n\nCommand exited with code", with: " · exit")
                .replacingOccurrences(of: "Validation failed for tool", with: "Validation failed")
            return copy
        }
    }
}

struct PiAgentWebLink: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var url: String

    var domain: String {
        URL(string: url)?.host(percentEncoded: false)?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? url
    }
}

struct PiAgentTranscriptActivity: Identifiable, Hashable {
    var id: UUID
    var name: String
    var entries: [PiAgentTranscriptEntry]
    var isError: Bool
    var compactDetail: String?
    var webLinks: [PiAgentWebLink]

    var representativeEntry: PiAgentTranscriptEntry? { entries.first }
    nonisolated var count: Int { entries.count }
    nonisolated var isWebActivity: Bool {
        switch name.lowercased() {
        case "web_search", "fetch_content", "get_search_content", "web_fetch": return true
        default: return false
        }
    }
    /// The native MCP proxy tool. Every assigned MCP server is reached through this
    /// one tool, so the activity's per-call breakdown (server/tool) lives in `args`.
    nonisolated var isMCPActivity: Bool { name.lowercased() == "mcp" }

    /// Whether this activity holds at least one real MCP tool *call* (action == call,
    /// i.e. an args.tool address) — as opposed to only list/search/describe
    /// introspection. The dedicated card renders only when this is true, so visibility
    /// gating MUST use this (not just the name) or the row toggles between a real card
    /// and a 0-height spacer mid-stream. Cheap: the RPC event is render-cached.
    @MainActor
    var hasMCPCall: Bool {
        guard isMCPActivity else { return false }
        return entries.contains { entry in
            guard let tool = PiAgentTranscriptActivity.toolArgs(from: entry)?["tool"]?.stringValue else { return false }
            return !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }


    /// One resolved MCP tool call, parsed from an `mcp` proxy entry's args/result.
    /// Built once in the items pass (see `NativeToolGroupModel.make`) so the card is
    /// a dumb renderer.
    struct MCPCall: Identifiable, Hashable {
        var id: UUID
        var server: String
        var tool: String
        var argsPreview: String?
        var resultPreview: String?
        var imageReferences: [PiAgentTranscriptImageReference] = []
        var isError: Bool
    }

    /// The actual tool calls in this `mcp` activity (action == call), each with its
    /// server/tool address, a compact args preview, and a result preview. List /
    /// search / describe introspection entries (no `tool` arg) are skipped — the card
    /// surfaces real tool invocations only.
    @MainActor
    func mcpCalls() -> [MCPCall] {
        entries.compactMap { entry in
            let args = PiAgentTranscriptActivity.toolArgs(from: entry)
            guard let rawTool = args?["tool"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTool.isEmpty,
                  let address = MCPConnectionManager.resolveAddress(rawTool, serverHint: args?["server"]?.stringValue)
            else { return nil }

            let resultText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isError = entry.role == .error
                || resultText.hasPrefix("MCP tool reported an error")
                || resultText.hasPrefix("MCP call failed")

            return MCPCall(
                id: entry.id,
                server: address.server,
                tool: address.tool,
                argsPreview: PiAgentTranscriptActivity.mcpArgsPreview(args?["args"]),
                resultPreview: resultText.isEmpty ? nil : resultText,
                imageReferences: entry.imageReferences,
                isError: isError
            )
        }
    }

    /// A compact, single-line preview of a tool's arguments object (keys + scalar
    /// values), for the card's call row. Returns nil for an empty/absent args object.
    nonisolated static func mcpArgsPreview(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .object(object) where !object.isEmpty:
            let parts = object.keys.sorted().map { key -> String in
                "\(key): \(mcpScalarPreview(object[key]))"
            }
            return parts.joined(separator: ", ")
        case .object:
            return nil
        default:
            let scalar = mcpScalarPreview(value)
            return scalar.isEmpty ? nil : scalar
        }
    }

    nonisolated private static func mcpScalarPreview(_ value: JSONValue?) -> String {
        switch value {
        case let .string(string): return string
        case let .number(number):
            return number == number.rounded() ? String(Int(number)) : String(number)
        case let .bool(bool): return bool ? "true" : "false"
        case let .array(items): return "[\(items.count)]"
        case .object: return "{…}"
        case .null, .none: return ""
        }
    }

    @MainActor
    static func make(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptActivity] {
        var orderedNames: [String] = []
        var grouped: [String: [PiAgentTranscriptEntry]] = [:]
        for entry in entries {
            let name = toolName(for: entry)
            if grouped[name] == nil { orderedNames.append(name) }
            grouped[name, default: []].append(entry)
        }
        return orderedNames.compactMap { name in
            guard let entries = grouped[name], !entries.isEmpty else { return nil }
            return PiAgentTranscriptActivity(
                id: entries.first?.id ?? UUID(),
                name: name,
                entries: entries,
                isError: entries.contains { $0.role == .error },
                compactDetail: compactDetail(for: name, entries: entries),
                webLinks: webLinks(for: name, entries: entries)
            )
        }
    }

    static func toolName(for entry: PiAgentTranscriptEntry) -> String {
        if entry.title.hasPrefix("Tool: ") {
            return entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    @MainActor
    private static func webLinks(for name: String, entries: [PiAgentTranscriptEntry]) -> [PiAgentWebLink] {
        switch name.lowercased() {
        case "web_search":
            let curated = entries.flatMap { entry in
                curatedSourceLinks(from: toolDetails(from: entry))
            }
            if !curated.isEmpty { return Array(uniqueLinks(curated).prefix(20)) }
            let links = entries.flatMap { entry in
                extractedLinks(from: toolDetails(from: entry)) + parseSourceLinks(from: entry.text)
            }
            return Array(uniqueLinks(links).prefix(20))
        case "fetch_content", "web_fetch":
            let links = entries.flatMap(fetchContentLinks)
            if !links.isEmpty { return Array(uniqueLinks(links).prefix(20)) }
            return Array(uniqueLinks(entries.flatMap { extractedLinks(from: toolDetails(from: $0)) + parseSourceLinks(from: $0.text) }).prefix(20))
        case "get_search_content":
            let links = entries.compactMap { entry -> PiAgentWebLink? in
                let details = toolDetails(from: entry)
                let textMetadata = contentFrontMatter(from: entry.text)
                guard let url = details?["url"]?.stringValue ?? textMetadata["source"] else { return nil }
                let title = details?["title"]?.stringValue ?? textMetadata["title"] ?? domain(from: url) ?? url
                return PiAgentWebLink(title: title, url: url)
            }
            return Array(uniqueLinks(links).prefix(20))
        default:
            return []
        }
    }

    @MainActor
    private static func compactDetail(for name: String, entries: [PiAgentTranscriptEntry]) -> String? {
        switch name.lowercased() {
        case "web_search":
            return webSearchDetail(from: entries)
        case "fetch_content", "web_fetch":
            return fetchContentDetail(from: entries)
        case "get_search_content":
            return retrievedContentDetail(from: entries)
        default:
            return nil
        }
    }

    @MainActor
    private static func webSearchDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let args = entries.lazy.compactMap(toolArgs).last
        let queries = stringArray(details?["queries"]) ?? stringArray(args?["queries"]) ?? args?["query"]?.stringValue.map { [$0] } ?? []
        let resultCount = intValue(details?["totalResults"])

        var parts: [String] = []
        if queries.count == 1, let query = queries.first {
            parts.append("“\(query.truncatedMiddle(max: 56))”")
        } else if queries.count > 1 {
            parts.append("\(queries.count) queries")
        }
        if let resultCount {
            parts.append(resultCount == 1 ? "1 result" : "\(resultCount) results")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func fetchContentDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let args = entries.lazy.compactMap(toolArgs).last
        let urls = stringArray(details?["urls"]) ?? stringArray(args?["urls"]) ?? args?["url"]?.stringValue.map { [$0] } ?? []
        let title = details?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let successful = intValue(details?["successful"])
        let urlCount = intValue(details?["urlCount"]) ?? urls.count
        let domains = domains(from: urls)

        var parts: [String] = []
        let fetchedTitles = entries.flatMap(fetchContentLinks).map(\.title).filter { !$0.isEmpty }
        if let title, !title.isEmpty, urlCount <= 1 {
            parts.append(title.truncatedMiddle(max: 44))
        } else if urlCount == 1, let fetchedTitle = fetchedTitles.first {
            parts.append(fetchedTitle.truncatedMiddle(max: 44))
        } else if urlCount > 0 {
            parts.append(urlCount == 1 ? "1 page" : "\(urlCount) pages")
        }
        if let successful, urlCount > 1, successful != urlCount {
            parts.append("\(successful)/\(urlCount) fetched")
        }
        if !domains.isEmpty {
            parts.append(domains.prefix(3).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func retrievedContentDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        // The inline source bullets already show what was read. Keep this row quiet
        // instead of adding a redundant title/source-count summary after "Read content".
        return nil
    }

    @MainActor
    private static func toolDetails(from entry: PiAgentTranscriptEntry) -> JSONValue? {
        toolEvent(from: entry)?.result?["details"]
    }

    @MainActor
    private static func toolArgs(from entry: PiAgentTranscriptEntry) -> JSONValue? {
        toolEvent(from: entry)?.args
    }

    @MainActor
    private static func toolEvent(from entry: PiAgentTranscriptEntry) -> PiAgentRPCEvent? {
        PiAgentRPCEventRenderCache.event(from: entry.rawJSON)
    }

    nonisolated private static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case let .array(items)? = value else { return nil }
        let strings = items.compactMap(\.stringValue).filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    nonisolated private static func intValue(_ value: JSONValue?) -> Int? {
        value?.numberValue.map(Int.init)
    }

    nonisolated private static func curatedSourceURLs(from details: JSONValue?) -> [String] {
        curatedSourceLinks(from: details).map(\.url)
    }

    nonisolated private static func uniqueLinks(_ links: [PiAgentWebLink]) -> [PiAgentWebLink] {
        var seen = Set<String>()
        return links.filter { link in
            seen.insert(link.url).inserted
        }
    }

    nonisolated private static func curatedSourceLinks(from details: JSONValue?) -> [PiAgentWebLink] {
        guard case let .array(queries)? = details?["curatedQueries"] else { return [] }
        return queries.flatMap { query -> [PiAgentWebLink] in
            guard case let .array(sources)? = query["sources"] else { return [] }
            return sources.compactMap { source in
                guard let url = source["url"]?.stringValue else { return nil }
                return PiAgentWebLink(title: source["title"]?.stringValue ?? domain(from: url) ?? url, url: url)
            }
        }
    }

    @MainActor
    private static func fetchContentLinks(from entry: PiAgentTranscriptEntry) -> [PiAgentWebLink] {
        let details = toolDetails(from: entry)
        let args = toolArgs(from: entry)
        let urls = stringArray(details?["urls"]) ?? stringArray(args?["urls"]) ?? args?["url"]?.stringValue.map { [$0] } ?? []
        guard !urls.isEmpty else { return [] }

        let titles = fetchedURLTitles(from: entry.text)
        let fallbackTitle = details?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return urls.enumerated().map { index, url in
            let parsedTitle = index < titles.count ? titles[index] : nil
            let displayTitle: String
            if let parsedTitle, !parsedTitle.isEmpty {
                displayTitle = parsedTitle
            } else if let fallbackTitle, !fallbackTitle.isEmpty {
                displayTitle = fallbackTitle
            } else {
                displayTitle = domain(from: url) ?? url
            }
            return PiAgentWebLink(title: displayTitle, url: url)
        }
    }

    nonisolated private static func fetchedURLTitles(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = trimmed.firstMatch(of: /^-\s+(.+?)\s+\(\d+\s+chars\)$/) else { return nil }
            return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    nonisolated private static func contentFrontMatter(from text: String) -> [String: String] {
        var metadata: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { return metadata }
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { metadata[key] = value }
        }
        return metadata
    }

    nonisolated private static func extractedLinks(from value: JSONValue?) -> [PiAgentWebLink] {
        guard let value else { return [] }
        switch value {
        case let .object(object):
            var output: [PiAgentWebLink] = []
            if let url = object["url"]?.stringValue ?? object["href"]?.stringValue ?? object["source"]?.stringValue {
                let title = object["title"]?.stringValue ?? object["name"]?.stringValue ?? object["path"]?.stringValue ?? domain(from: url) ?? url
                output.append(PiAgentWebLink(title: title, url: url))
            }
            output += object.values.flatMap(extractedLinks)
            return output
        case let .array(items):
            return items.flatMap(extractedLinks)
        case let .string(string):
            return parseSourceLinks(from: string)
        default:
            return []
        }
    }

    nonisolated private static func parseSourceLinks(from text: String) -> [PiAgentWebLink] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [PiAgentWebLink] = []
        var pendingTitle: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = trimmed.firstMatch(of: /^\d+\.\s+(.+)$/) {
                pendingTitle = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if let match = trimmed.firstMatch(of: /^[-*]\s+\[(.+?)\]\((https?:\/\/[^\s)]+)\)/) {
                output.append(PiAgentWebLink(title: String(match.1), url: String(match.2)))
                pendingTitle = nil
            } else if let match = trimmed.firstMatch(of: /\[(.+?)\]\((https?:\/\/[^\s)]+)\)/) {
                output.append(PiAgentWebLink(title: String(match.1), url: String(match.2)))
                pendingTitle = nil
            } else if let match = trimmed.firstMatch(of: /(https?:\/\/[^\s)>,]+)[),.]?/) {
                let url = String(match.1)
                output.append(PiAgentWebLink(title: pendingTitle ?? domain(from: url) ?? url, url: url))
                pendingTitle = nil
            }
            if output.count >= 20 { break }
        }
        return output
    }

    nonisolated private static func domains(from urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap(domain).filter { seen.insert($0).inserted }
    }

    nonisolated private static func domain(from url: String) -> String? {
        guard let host = URL(string: url)?.host(percentEncoded: false) else { return nil }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}

extension String {
    nonisolated func truncatedMiddle(max: Int) -> String {
        guard count > max, max > 1 else { return self }
        let headCount = max / 2
        let tailCount = max - headCount - 1
        return String(prefix(headCount)) + "…" + String(suffix(tailCount))
    }
}

// MARK: - Dynamic bubble width

/// The transcript pane's current content width, published by the AppKit table
/// cell host (`TranscriptTableCellView.configure`). Chat bubbles read this to
/// size themselves as a fraction of the pane — no `GeometryReader`, no extra
/// measurement pass: it is the same width the cell already applies via
/// `.frame(width:)`, so it is stable and only changes on an actual resize.
private struct TranscriptContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 880
}

extension EnvironmentValues {
    var transcriptContentWidth: CGFloat {
        get { self[TranscriptContentWidthKey.self] }
        set { self[TranscriptContentWidthKey.self] = newValue }
    }
}

/// Chat-bubble width policy
///
/// User (question) bubbles **hug their content**: a short message gets a small
/// bubble. This is cheap and jump-free — a user message is immutable once sent,
/// so its width is measured exactly once (then served from cache) and never
/// changes afterwards (user messages never stream).
///
/// Agent reply / tool / plan cards use a **fixed width** (a clamped fraction of
/// the pane, so it degrades gracefully on a narrow window). They never
/// re-measure and never change width while a response streams in — preserving
/// the transcript's "only the bottom child grows, and only vertically"
/// zero-jumpiness design. Tune `replyCapMax` to taste.
@MainActor
enum PiAgentBubbleWidth {
    // Agent reply / tool / plan card width — fixed, content-independent.
    static let replyCapMultiplier: CGFloat = 0.72
    static let replyCapMax: CGFloat = 720

    // User (question) bubble — hugs the message text, within these bounds.
    static let userCapMultiplier: CGFloat = 0.62
    static let userCapMax: CGFloat = 720
    static let userMinWidth: CGFloat = 120
    static let userChrome: CGFloat = 34   // card h-padding (14*2) + a little slack

    /// Fixed width for an agent reply / tool / plan card.
    static func replyCap(for paneWidth: CGFloat) -> CGFloat {
        min(paneWidth * replyCapMultiplier, replyCapMax)
    }

    /// Content-hugging width for a user (question) bubble. Pure arithmetic plus
    /// one cached text measurement — see `MessageTextWidth`.
    ///
    /// `pillsWidth` is the natural unwrapped width of the attachment chip row
    /// (file/skill/command/paste/issue/image chips) — measured at the call
    /// site so a short message with wide pills still grows to fit them
    /// (within the same cap). Pass 0 when there are no chips.
    static func huggedUser(text: String, pillsWidth: CGFloat = 0, paneWidth: CGFloat) -> CGFloat {
        let cap = min(paneWidth * userCapMultiplier, userCapMax)
        // Fenced code renders in a monospace font this measurement can't model;
        // let those messages fill the cap rather than risk wrapping code.
        if text.contains("```") { return cap }
        let textNatural = MessageTextWidth.naturalWidth(of: text)
        let natural = max(textNatural, pillsWidth) + userChrome
        return min(cap, max(natural, min(userMinWidth, cap)))
    }
}

/// Measurement of an attachment chip label in `.caption2`, used by the bubble
/// width calculation so chips can grow the bubble to fit (within the cap).
/// Per-chip width is capped — a single huge filename can't blow the bubble;
/// the chip will middle-truncate beyond that ceiling.
@MainActor
enum ChipLabelWidth {
    private static var cache: [String: CGFloat] = [:]
    private static var order: [String] = []
    private static let limit = 256
    private static let attributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.preferredFont(forTextStyle: .caption2)]
    /// Width contribution per chip beyond its label: icon + spacing + glass-capsule
    /// horizontal padding (small button style).
    static let chipChrome: CGFloat = 38
    /// Per-chip cap. Beyond this the chip middle-truncates inside itself instead of
    /// stretching the whole bubble.
    static let perChipMax: CGFloat = 130
    /// HStack inter-chip gap (matches the body HStack spacing).
    static let chipGap: CGFloat = 8

    static func labelWidth(of text: String) -> CGFloat {
        if let cached = cache[text] { return cached }
        let width = (text as NSString).size(withAttributes: attributes).width
        let result = ceil(width)
        cache[text] = result
        order.append(text)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    /// One chip's width = label (capped) + icon/spacing/padding chrome.
    static func chipWidth(for label: String) -> CGFloat {
        min(labelWidth(of: label), perChipMax) + chipChrome
    }

    /// Sum of chip widths plus inter-chip gaps.
    static func rowWidth(forLabels labels: [String]) -> CGFloat {
        guard !labels.isEmpty else { return 0 }
        let chips = labels.map { chipWidth(for: $0) }.reduce(0, +)
        return chips + chipGap * CGFloat(labels.count - 1)
    }
}

/// Cheap, cached measurement of a message's natural (unwrapped) text width —
/// the width below which the body text would begin to wrap. This lets chat
/// bubbles size to their content WITHOUT touching the markdown view's own
/// (carefully tuned) layout / height-measurement path.
@MainActor
enum MessageTextWidth {
    private static var cache: [String: CGFloat] = [:]
    private static var order: [String] = []
    private static let limit = 256
    // Bounds work for pathologically long lines; far above any real bubble cap.
    private static let ceiling: CGFloat = 5000
    private static let attributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.preferredFont(forTextStyle: .body)]

    /// Width of the widest line of `text` in the body font. Measures the raw
    /// markdown source, so syntax characters bias the result slightly wide —
    /// the safe direction (a bubble never ends up narrower than its text).
    static func naturalWidth(of text: String) -> CGFloat {
        if let cached = cache[text] { return cached }
        var widest: CGFloat = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let width = (String(line) as NSString).size(withAttributes: attributes).width
            if width > widest { widest = width }
            if widest >= ceiling { break }
        }
        let result = min(ceil(widest), ceiling)
        cache[text] = result
        order.append(text)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
}

/// Hover-driven copy-button wrapper for thread messages. Used by
/// `PiAgentTranscriptThreadCard` to place a glass copy button beside user
/// bubbles and assistant cards.
///
/// CRITICAL: the copy button is an `.overlay` on the card, NOT a sibling in
/// the row's HStack. Overlays never contribute to their host's layout size,
/// so the row the AppKit table measures is byte-for-byte the long-stable
/// `HStack { card; Spacer }` layout — adding/removing/animating the copy
/// button cannot change a row's measured height. (A previous version put the
/// button in the HStack; that changed what the offscreen measurement cell
/// saw and reintroduced the card-overlap bug.)
///
/// The button floats into the 60pt `Spacer` gap via `.offset`. `@State` is
/// per-row, so each row tracks its own hover with no cross-row coupling.
/// One option in the fork "Fork as 1:1 agent chat…" submenu. The action is
/// pre-bound to the entry + agent so `ThreadMessageRow` stays agnostic to
/// the upstream session/viewModel types.
struct ForkAgentMenuItem {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
}

private struct ThreadMessageRow<Content: View>: View {
    enum CopySide { case leading, trailing }

    let copyText: String
    let copyOn: CopySide
    let cardMaxWidth: CGFloat
    var onFork: (() -> Void)? = nil
    /// When non-nil and non-empty, the fork affordance becomes a Menu offering
    /// "Fork as Pi session" (the original `onFork` action) plus a nested
    /// "Fork as 1:1 agent chat…" submenu. Otherwise the existing single
    /// `AppForkIconButton` is shown unchanged.
    var forkAgentOptions: [ForkAgentMenuItem]? = nil
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            if copyOn == .leading {
                Spacer(minLength: 60)
                card
            } else {
                card
                Spacer(minLength: 60)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var card: some View {
        // Both buttons float into the 60pt Spacer beside the card via .overlay,
        // never contributing to layout. Copy sits closer to the card; Fork sits
        // outboard of Copy. Leading side: [Fork][Copy][card]. Trailing side:
        // [card][Copy][Fork] — symmetric. Single button offset = 38pt (28pt
        // button + 10pt gap to card). Two-button HStack is 28+4+28 = 60pt;
        // offset 70 preserves the same 10pt gap to the card.
        content()
            .frame(maxWidth: cardMaxWidth, alignment: copyOn == .leading ? .trailing : .leading)
            .overlay(alignment: copyOn == .leading ? .leading : .trailing) {
                HStack(spacing: 4) {
                    if copyOn == .leading, onFork != nil {
                        forkAffordance
                    }
                    AppCopyIconButton(
                        text: copyText,
                        help: "Copy message",
                        size: CGSize(width: 28, height: 28)
                    )
                    if copyOn == .trailing, onFork != nil {
                        forkAffordance
                    }
                }
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
                .offset(x: copyOn == .leading ? -(onFork == nil ? 38 : 70) : (onFork == nil ? 38 : 70))
            }
    }

    @ViewBuilder
    private var forkAffordance: some View {
        if let onFork {
            if let options = forkAgentOptions, !options.isEmpty {
                Menu {
                    Button("Fork as Pi session", action: onFork)
                    Menu("Fork as 1:1 agent chat…") {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            Button(option.title, action: option.action)
                                .disabled(option.isDisabled)
                        }
                    }
                } label: {
                    ZStack {
                        Color.clear
                            .contentShape(Capsule(style: .continuous))
                        Image(systemName: "arrow.trianglehead.branch")
                            .font(AppTheme.Font.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Fork session…")
            } else {
                AppForkIconButton(action: onFork)
            }
        }
    }
}

struct PiAgentTranscriptThreadCard: View {
    /// Which slice of the thread to render. `.fullThread` is the original
    /// behaviour (used by the "Earlier Transcript" sheet). `.question` and
    /// `.child` each render exactly ONE `ThreadMessageRow` — this is what lets
    /// the AppKit transcript host each block as its own NSTableView row, so
    /// streaming/scrolling only touch one small block instead of a whole thread.
    enum RenderMode: Hashable {
        case fullThread
        case question
        case child(PiAgentThreadChild)
    }

    let thread: PiAgentTranscriptThread
    let visibility: PiAgentTranscriptVisibilitySettings
    let skills: [SkillRecord]
    var commandSlashNames: Set<String> = []
    let projectPath: String?
    let nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    let nativeSubagentCard: (PiSubagentRunRecord) -> PiNativeSubagentRunCard
    var renderMode: RenderMode = .fullThread
    /// Invoked when the hover-revealed Fork button on a user-message row is
    /// tapped. Only user-question rows render the button — child rows never do.
    /// nil disables the button (e.g. earlier-transcript sheet, where fork doesn't apply).
    var onFork: ((PiAgentTranscriptEntry) -> Void)? = nil
    /// When non-nil and non-empty, the fork button becomes a Menu that also
    /// offers "Fork as 1:1 agent chat…" with one row per agent. The closure
    /// receives the user message entry and the chosen agent.
    var forkAgentChoices: [EffectiveAgentRecord]? = nil
    var onForkAsAgentChat: ((PiAgentTranscriptEntry, EffectiveAgentRecord) -> Void)? = nil

    @Environment(\.transcriptContentWidth) private var transcriptContentWidth

    var body: some View {
        switch renderMode {
        case .fullThread: fullThreadBody
        case .question: questionBlock
        case .child(let child): childBlock(child)
        }
    }

    /// Builds the per-agent submenu items for the fork affordance on `entry`.
    /// Returns `nil` (single-action fork) when the upstream session has no
    /// agent choices wired up — i.e. subagents are off or no agents discovered.
    fileprivate func forkAgentMenuItems(for entry: PiAgentTranscriptEntry) -> [ForkAgentMenuItem]? {
        guard let choices = forkAgentChoices, !choices.isEmpty,
              let handler = onForkAsAgentChat else { return nil }
        return choices.map { agent in
            ForkAgentMenuItem(
                title: agent.name,
                isDisabled: agent.resolved.disabled == true,
                action: { handler(entry, agent) }
            )
        }
    }

    @ViewBuilder
    private var fullThreadBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.threadSpacing) {
            questionBlock
            if hasChildren {
                VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
                    ForEach(thread.children) { child in
                        childBlock(child)
                    }
                }
            }
        }
    }

    /// The user-question row — iMessage-style right-aligned bubble with the
    /// hover-revealed glass copy + fork buttons just to its LEFT.
    @ViewBuilder
    private var questionBlock: some View {
        if let question = thread.question {
            ThreadMessageRow(
                copyText: question.text,
                copyOn: .leading,
                cardMaxWidth: PiAgentBubbleWidth.huggedUser(
                    text: PiAgentUserMessageContent.displayMessageText(for: question, skills: skills, commandSlashNames: commandSlashNames),
                    pillsWidth: PiAgentUserMessageContent.displayChipsNaturalWidth(for: question, skills: skills, commandSlashNames: commandSlashNames),
                    paneWidth: transcriptContentWidth
                ),
                onFork: onFork.map { handler in { handler(question) } },
                forkAgentOptions: forkAgentMenuItems(for: question)
            ) {
                PiAgentTranscriptCard(entry: question, style: .question, skills: skills, commandSlashNames: commandSlashNames)
                    .id(question.id)
            }
        }
    }

    /// One reply row — assistant / tool / status card on the left, copy button
    /// hover-revealed on the RIGHT. Steering messages are user messages and are
    /// rendered like the initial question (right-aligned, hugged width). Divider-
    /// style status entries bypass ThreadMessageRow so they span the full
    /// transcript width instead of sitting inside the assistant bubble column.
    @ViewBuilder
    private func childBlock(_ child: PiAgentThreadChild) -> some View {
        if case .status(let entry) = child,
           entry.isDividerStatus,
           !Self.shouldHideNativeSubagentStatus(entry, nativeSubagentRunsByID: nativeSubagentRunsByID) {
            statusRowView(entry)
        } else if case .steering(let entry) = child {
            ThreadMessageRow(
                copyText: entry.text,
                copyOn: .leading,
                cardMaxWidth: PiAgentBubbleWidth.huggedUser(
                    text: PiAgentUserMessageContent.displayMessageText(for: entry, skills: skills, commandSlashNames: commandSlashNames),
                    pillsWidth: PiAgentUserMessageContent.displayChipsNaturalWidth(for: entry, skills: skills, commandSlashNames: commandSlashNames),
                    paneWidth: transcriptContentWidth
                )
            ) {
                PiAgentTranscriptCard(entry: entry, style: .question, skills: skills, commandSlashNames: commandSlashNames)
                    .id(entry.id)
            }
        } else {
            ThreadMessageRow(
                copyText: copyText(for: child),
                copyOn: .trailing,
                cardMaxWidth: PiAgentBubbleWidth.replyCap(for: transcriptContentWidth)
            ) {
                childView(child)
            }
        }
    }

    /// Plain-text representation of a thread child suitable for the system
    /// pasteboard. Combines text from underlying entries (or tool-group
    /// entries) and falls back to the raw entry text.
    private func copyText(for child: PiAgentThreadChild) -> String {
        switch child {
        case .steering(let entry), .thinking(let entry), .assistant(let entry),
             .status(let entry), .error(let entry):
            return entry.text
        case .toolGroup(let group):
            return group.entries.map(\.text).joined(separator: "\n\n")
        case .retry(let entry, _):
            return entry.text
        }
    }

    @ViewBuilder
    private func childView(_ child: PiAgentThreadChild) -> some View {
        switch child {
        case .steering:
            // Steering children are rendered directly in childBlock so they can
            // use user-message (right-aligned) layout. This branch is unreachable.
            EmptyView()
        case .thinking(let entry):
            if visibility.showThinking {
                PiAgentTranscriptCard(entry: entry, style: childStyle, skills: skills, commandSlashNames: commandSlashNames)
                    .id(entry.id)
            }
        case .assistant(let entry):
            PiAgentTranscriptCard(entry: entry, style: childStyle, skills: skills, commandSlashNames: commandSlashNames)
                .id(entry.id)
        case .toolGroup(let group):
            toolGroupView(group)
        case .status(let entry):
            if Self.shouldShowStatusEntry(entry, visibility: visibility, nativeSubagentRunsByID: nativeSubagentRunsByID) {
                statusRowView(entry)
            }
        case .error(let entry):
            // Fatal turn/model/provider errors always render (even with the Errors
            // toggle off) so a turn that produced no output is never silent; tool
            // errors keep honoring the toggle.
            if entry.isModelError || visibility.showErrors {
                PiAgentStatusTranscriptRow(entry: entry)
                    .id(entry.id)
            }
        case .retry(let entry, let info):
            PiAgentRetryCard(info: info, timestamp: entry.timestamp)
                .id(entry.id)
        }
    }

    @ViewBuilder
    private func toolGroupView(_ group: PiAgentThreadToolGroup) -> some View {
        let webActivities = group.activities.filter(\.isWebActivity)
        let toolActivities = group.activities.filter { !$0.isWebActivity }
        // A tool group can emit several cards (web activity, tool calls, diffs).
        // They MUST be wrapped in a VStack — without an explicit vertical
        // container the sibling cards have no imposed arrangement, and the
        // enclosing row lays them out side by side instead of stacked.
        VStack(alignment: .leading, spacing: 8) {
            if visibility.showWebActivity, !webActivities.isEmpty {
                PiAgentWebActivitySummaryView(activities: webActivities)
            }
            if visibility.showDiffs {
                PiAgentThreadDiffSummaryView(activities: toolActivities, projectPath: projectPath)
                    .frame(width: PiAgentBubbleWidth.replyCap(for: transcriptContentWidth), alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func statusRowView(_ entry: PiAgentTranscriptEntry) -> some View {
        if let recapMarker = LoopRunRecapCodec.decode(from: entry) {
            PiAgentLoopRecapTranscriptCard(entry: entry, marker: recapMarker)
                .id(entry.id)
        } else if let memoryEvent = entry.agentMemoryEvent {
            PiAgentMemoryActivityCard(event: memoryEvent)
                .id(entry.id)
        } else if let runID = entry.nativeSubagentRunID, let run = nativeSubagentRunsByID[runID] {
            nativeSubagentCard(run)
                .id(entry.id)
        } else {
            PiAgentStatusTranscriptRow(entry: entry)
                .id(entry.id)
        }
    }

    private var childStyle: PiAgentTranscriptCardStyle {
        thread.question == nil ? .standalone : .threadChild
    }

    private var hasChildren: Bool {
        !thread.children.isEmpty
    }

    static func shouldHideNativeSubagentStatus(
        _ entry: PiAgentTranscriptEntry,
        nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> Bool {
        guard let runID = entry.nativeSubagentRunID,
              let run = nativeSubagentRunsByID[runID],
              run.mode == .single,
              let representedAt = parallelChildUpdatedAtByRunID(nativeSubagentRunsByID)[runID] else { return false }
        // Continuations reuse the same run ID and update the same transcript card.
        // Hide only the child entry while it is still represented by the parent
        // parallel card; later direct continuations must remain visible.
        return entry.timestamp <= representedAt.addingTimeInterval(5)
    }

    private static func parallelChildUpdatedAtByRunID(
        _ nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> [UUID: Date] {
        var output: [UUID: Date] = [:]
        for run in nativeSubagentRunsByID.values where run.mode == .parallel {
            for child in run.children ?? [] {
                guard let executionRunID = child.executionRunID else { continue }
                let existing = output[executionRunID]
                if existing == nil || child.updatedAt > existing! {
                    output[executionRunID] = child.updatedAt
                }
            }
        }
        return output
    }

    /// The children that actually render as rows, given the visibility
    /// settings — mirrors the gating inside `childView`. The AppKit
    /// block-row transcript uses this so a hidden child produces no row.
    @MainActor
    static func visibleChildren(
        of thread: PiAgentTranscriptThread,
        visibility: PiAgentTranscriptVisibilitySettings,
        nativeSubagentRunsByID: [UUID: PiSubagentRunRecord],
        projectPath: String?
    ) -> [PiAgentThreadChild] {
        let filtered = thread.children.filter { child in
            switch child {
            case .thinking: return visibility.showThinking
            case .error(let entry): return entry.isModelError || visibility.showErrors
            case .status(let entry):
                return shouldShowStatusEntry(entry, visibility: visibility, nativeSubagentRunsByID: nativeSubagentRunsByID)
            case .toolGroup(let group):
                // A tool group whose every section is hidden must NOT stay in the
                // list: it would still emit a 0-height row that the inter-row inset
                // pass pads on both sides, leaving a phantom gap between turns.
                return toolGroupHasVisibleContent(group, visibility: visibility, projectPath: projectPath)
            case .steering, .assistant, .retry: return true
            }
        }
        return coalesceAdjacentToolGroups(filtered)
    }

    /// Re-merge tool groups that became adjacent only because the child between them
    /// was filtered out (a hidden thinking block, a hidden status, a read-only tool
    /// group with its sections off, …). The build-time splitter in
    /// `chronologicalChildren` flushes a group on every thinking/status/etc. arrival
    /// without knowing visibility, so a hidden separator would otherwise leave two
    /// "Changes" diff cards split by an invisible gap. A *visible* separator keeps the
    /// groups non-adjacent here, so they correctly stay split.
    ///
    /// A merged run rebuilds its activities via `PiAgentTranscriptActivity.make` over the
    /// combined entries (NOT a plain `activities` concat): two adjacent groups can each
    /// hold an `edit` activity, and only `make` re-folds them into one `edit ×N` so the
    /// tool-call chips and web cards match what an unsplit burst shows. Cost stays off the
    /// common path — `make` runs once per *merged* run (2+ groups), and a lone group is
    /// passed through untouched. For code tools `make` is just string/dictionary grouping
    /// (web link/detail parsing is skipped for non-web tools).
    private static func coalesceAdjacentToolGroups(
        _ children: [PiAgentThreadChild]
    ) -> [PiAgentThreadChild] {
        var result: [PiAgentThreadChild] = []
        var run: [PiAgentThreadToolGroup] = []

        func flushRun() {
            guard let first = run.first else { return }
            if run.count == 1 {
                result.append(.toolGroup(first))                   // untouched, zero cost
            } else {
                let entries = run.flatMap(\.entries)
                result.append(.toolGroup(PiAgentThreadToolGroup(
                    id: first.id,                                  // stable descriptor id
                    entries: entries,
                    activities: PiAgentTranscriptActivity.make(from: entries)
                )))
            }
            run = []
        }

        for child in children {
            if case .toolGroup(let group) = child {
                run.append(group)
            } else {
                flushRun()
                result.append(child)
            }
        }
        flushRun()
        return result
    }

    /// Whether a tool group would render at least one section under the current
    /// visibility. This intentionally uses the same display-model factory as the
    /// native row so edit/write tools without a real diff (for example /tmp writes)
    /// do not survive filtering as 0-height spacer rows.
    @MainActor
    static func toolGroupHasVisibleContent(
        _ group: PiAgentThreadToolGroup,
        visibility: PiAgentTranscriptVisibilitySettings,
        projectPath: String?
    ) -> Bool {
        NativeToolGroupModel.make(group: group, visibility: visibility, projectPath: projectPath) != nil
    }

    private static func shouldShowStatusEntry(
        _ entry: PiAgentTranscriptEntry,
        visibility: PiAgentTranscriptVisibilitySettings,
        nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    ) -> Bool {
        if entry.title == "System Prompt Captured" {
            return visibility.showFinalSystemPrompt
        }
        if entry.agentMemoryEvent != nil {
            return visibility.showMemoryCards
        }
        return !shouldHideNativeSubagentStatus(entry, nativeSubagentRunsByID: nativeSubagentRunsByID)
    }

}

extension PiAgentTranscriptEntry {
    var agentMemoryEvent: AgentMemoryTranscriptEvent? {
        guard let rawJSON,
              rawJSON.contains(AgentMemoryTranscriptEvent.rawType) else {
            return nil
        }
        return JSONParseMemo.value("agentMemoryEvent\(JSONParseMemo.separator)\(rawJSON)") {
            guard let data = rawJSON.data(using: .utf8),
                  let event = try? transcriptJSONDecoder.decode(AgentMemoryTranscriptEvent.self, from: data),
                  event.type == AgentMemoryTranscriptEvent.rawType else {
                return nil
            }
            return event
        }
    }
}

struct PiAgentThreadDiffSummaryView: View {
    let activities: [PiAgentTranscriptActivity]
    let projectPath: String?
    @State private var rows: [Row] = []
    @State private var isLoading = true

    var body: some View {
        let changes = Self.changedFiles(from: activities)
        if !changes.isEmpty && (isLoading || !rows.isEmpty) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "plusminus")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppTheme.mutedText)
                    Text("Changes")
                        .font(AppTheme.Font.caption.weight(.semibold))
                    Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                if isLoading && rows.isEmpty {
                    Text("Preparing file changes…")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
                ForEach(Array(rows.prefix(4).enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().opacity(0.45) }
                    PiAgentInlineDiffCard(row: row)
                }
                if rows.count > 4 {
                    Text("\(rows.count - 4) more changed file\(rows.count - 4 == 1 ? "" : "s") hidden")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .padding(.horizontal, AppTheme.Chat.cardHPadding)
            .padding(.vertical, AppTheme.Chat.cardVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
            .task(id: Self.signature(for: changes)) { await loadRows(changes: changes) }
        }
    }

    @MainActor
    static func changedPaths(from activities: [PiAgentTranscriptActivity]) -> [String] {
        changedFiles(from: activities).map(\.path)
    }

    /// Diff rows (path + diff) for the native tool-group renderer. Mirrors
    /// `loadRows`: at most 8 files, only those with a non-empty diff.
    @MainActor
    static func diffRows(from activities: [PiAgentTranscriptActivity]) -> [Row] {
        changedFiles(from: activities).prefix(8).compactMap { change in
            change.diff.isEmpty ? nil : Row(path: change.path, diff: change.diff)
        }
    }

    @MainActor
    private static func changedFiles(from activities: [PiAgentTranscriptActivity]) -> [ChangedFile] {
        var orderedPaths: [String] = []
        var diffsByPath: [String: [String]] = [:]
        for entry in activities.flatMap(\.entries) {
            let name = normalizedToolName(PiAgentTranscriptActivity.toolName(for: entry))
            guard name == "edit" || name == "write" else { continue }
            let event = PiAgentRPCEventRenderCache.event(from: entry.rawJSON)
            guard let path = path(from: event, entry: entry) else { continue }
            if diffsByPath[path] == nil { orderedPaths.append(path) }
            if let diff = diff(from: event, toolName: name), !diff.isEmpty {
                diffsByPath[path, default: []].append(diff)
            }
        }
        return orderedPaths.map { path in
            ChangedFile(path: path, diff: diffsByPath[path, default: []].joined(separator: "\n\n"))
        }
    }

    private func loadRows(changes: [ChangedFile]) async {
        isLoading = true
        rows = changes.prefix(8).compactMap { change in
            guard !change.diff.isEmpty else { return nil }
            return Row(path: change.path, diff: change.diff)
        }
        isLoading = false
    }

    private static func normalizedToolName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ".").last.map(String.init) ?? name.lowercased()
    }

    private static func path(from event: PiAgentRPCEvent?, entry: PiAgentTranscriptEntry) -> String? {
        let path = event?.args?["path"]?.stringValue
            ?? event?.args?["file_path"]?.stringValue
            ?? event?.result?["details"]?["path"]?.stringValue
            ?? event?.result?["details"]?["file_path"]?.stringValue
            ?? event?.result?["path"]?.stringValue
            ?? event?.result?["file_path"]?.stringValue
            ?? pathFromDiff(event?.result?["details"]?["diff"]?.stringValue ?? event?.result?["diff"]?.stringValue)
            ?? pathFromText(entry.text)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func diff(from event: PiAgentRPCEvent?, toolName: String) -> String? {
        let payloadDiff = event?.result?["details"]?["diff"]?.stringValue
            ?? event?.result?["diff"]?.stringValue
        if let payloadDiff = trimDiff(payloadDiff ?? "").nilIfEmpty { return payloadDiff }
        guard toolName == "edit" else { return nil }
        return trimDiff(syntheticDiff(from: event?.args) ?? "").nilIfEmpty
    }

    private static func pathFromDiff(_ diff: String?) -> String? {
        guard let diff else { return nil }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git a/") {
                let parts = line.split(separator: " ")
                if parts.count >= 4 { return stripDiffPrefix(String(parts[3])) }
            }
            if line.hasPrefix("+++") {
                let value = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                if value != "/dev/null" { return stripDiffPrefix(value) }
            }
        }
        return nil
    }

    private static func stripDiffPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    private static let pathTextRegexes = [#"in ([^\n]+)$"#, #"to ([^\n]+)$"#, #"from ([^\n]+)$"#]
        .compactMap { try? NSRegularExpression(pattern: $0) }

    private static func pathFromText(_ text: String) -> String? {
        for regex in pathTextRegexes {
            guard let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return nil
    }

    private static func syntheticDiff(from args: JSONValue?) -> String? {
        guard let editsValue = args?["edits"] else {
            if let oldText = args?["oldText"]?.stringValue ?? args?["old_text"]?.stringValue,
               let newText = args?["newText"]?.stringValue ?? args?["new_text"]?.stringValue {
                return syntheticDiff(edits: [(oldText, newText)])
            }
            return nil
        }
        let edits: [(String, String)]
        switch editsValue {
        case let .array(values):
            edits = values.compactMap { value in
                guard let old = value["oldText"]?.stringValue ?? value["old_text"]?.stringValue,
                      let new = value["newText"]?.stringValue ?? value["new_text"]?.stringValue else { return nil }
                return (old, new)
            }
        case let .string(raw):
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            edits = decoded.compactMap { dict in
                guard let old = dict["oldText"] as? String ?? dict["old_text"] as? String,
                      let new = dict["newText"] as? String ?? dict["new_text"] as? String else { return nil }
                return (old, new)
            }
        default:
            edits = []
        }
        return syntheticDiff(edits: edits)
    }

    private static func syntheticDiff(edits: [(String, String)]) -> String? {
        guard !edits.isEmpty else { return nil }
        var lines: [String] = []
        for (index, edit) in edits.enumerated() {
            if index > 0 { lines.append("  ...") }
            lines.append(contentsOf: edit.0.split(separator: "\n", omittingEmptySubsequences: false).map { "-  \($0)" })
            lines.append(contentsOf: edit.1.split(separator: "\n", omittingEmptySubsequences: false).map { "+  \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private static func trimDiff(_ diff: String) -> String {
        diff.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func signature(for changes: [ChangedFile]) -> String {
        changes.map { "\($0.path):\($0.diff.count)" }.joined(separator: "\u{0}")
    }

    private struct ChangedFile: Hashable {
        let path: String
        let diff: String
    }

    struct Row: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let diff: String

        var changeCountText: String {
            // Single pass: count added/removed lines without splitting + filtering twice.
            var added = 0
            var removed = 0
            for line in diff.split(separator: "\n") {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            if added == 0 && removed == 0 { return "modified" }
            return "+\(added) −\(removed)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct PiAgentInlineDiffCard: View {
    let row: PiAgentThreadDiffSummaryView.Row
    @State private var isDiffSheetPresented = false
    @State private var openTapCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.path.truncatedMiddle(max: 54))
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.changeCountText)
                    .font(AppTheme.Font.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
                Button {
                    openTapCount += 1
                    isDiffSheetPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: openTapCount)
                            .frame(width: 15, height: 15)
                        Text("Open")
                    }
                }
                .font(AppTheme.Font.caption2.weight(.semibold))
                .appSmallSecondaryButton()
                .help("Open full diff")
                PiAgentDiffCopyButton(text: row.diff)
            }
            PiAgentCompactDiffPreview(diffText: row.diff)
        }
        .sheet(isPresented: $isDiffSheetPresented) {
            PiAgentFullDiffSheet(row: row)
        }
    }
}

private struct PiAgentDiffCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showCopiedFeedback()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 15, height: 15)
                Text("Copy")
            }
        }
        .font(AppTheme.Font.caption2.weight(.semibold))
        .appSmallSecondaryButton()
        .help(copied ? "Copied" : "Copy diff")
    }

    private func showCopiedFeedback() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            copied = false
        }
    }
}

private struct PiAgentFullDiffSheet: View {
    let row: PiAgentThreadDiffSummaryView.Row
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.path)
                    .font(AppTheme.Font.headline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(row.changeCountText)
                    .font(AppTheme.Font.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedText)
            }
            PiAgentFullDiffView(diffText: row.diff)
        }
        .padding(AppTheme.pagePadding)
        .frame(minWidth: 780, idealWidth: 920, minHeight: 520, idealHeight: 680)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Copy Diff") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.diff, forType: .string)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// Full-diff sheet content hosted by the native tool-group's "Open" action. The
/// sheet is modal (not a scroll hot path), so reusing the SwiftUI diff view here
/// is pixel-identical to the original `PiAgentFullDiffSheet` by construction.
struct PiAgentNativeFullDiffSheet: View {
    let row: PiAgentThreadDiffSummaryView.Row
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.path)
                        .font(AppTheme.Font.headline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(row.changeCountText)
                        .font(AppTheme.Font.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer(minLength: 0)
                Button("Copy Diff") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.diff, forType: .string)
                }
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            PiAgentFullDiffView(diffText: row.diff)
        }
        .padding(AppTheme.pagePadding)
        .frame(minWidth: 780, idealWidth: 920, minHeight: 520, idealHeight: 680)
    }
}

/// Modal showing an MCP tool's full response, opened by the transcript MCP card's
/// "View" button. Mirrors `PiAgentNativeFullDiffSheet`'s chrome (title + Copy +
/// Done), with the body pretty-printed when the response is JSON.
struct PiAgentNativeMCPResultSheet: View {
    let server: String
    let tool: String
    let text: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(server)/\(tool)")
                        .font(AppTheme.Font.headline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("MCP response")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer(minLength: 0)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            PiAgentMCPResultTextView(text: text)
        }
        .padding(AppTheme.pagePadding)
        .frame(minWidth: 620, idealWidth: 820, minHeight: 440, idealHeight: 620)
    }
}

struct PiAgentMCPResultTextView: View {
    let text: String
    @State private var rendered: String = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(rendered.isEmpty ? text : rendered)
                .font(AppTheme.Font.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.textContentFill))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        .task(id: text) {
            rendered = Self.formatted(text)
        }
    }

    /// Renders a response for display: a pure-JSON body is pretty-printed; an error
    /// like `MCP call failed: … [ {…} ]` keeps its leading message and pretty-prints
    /// the embedded JSON below it; anything else shows verbatim.
    static func formatted(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = prettyJSON(trimmed) { return whole }
        if let jsonStart = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            let prefix = trimmed[..<jsonStart].trimmingCharacters(in: .whitespacesAndNewlines)
            if let body = prettyJSON(String(trimmed[jsonStart...])) {
                return prefix.isEmpty ? body : "\(prefix)\n\n\(body)"
            }
        }
        return trimmed
    }

    /// Pretty-prints `raw` when the whole string parses as JSON; nil otherwise.
    /// Re-indents the ORIGINAL text rather than re-serializing a parsed object, so
    /// number literals stay byte-exact (`5.2` never becomes `5.2000000000000002`) and
    /// key order is preserved.
    static func prettyJSON(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        // Validate it really is JSON before re-indenting.
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }

        var out = ""
        out.reserveCapacity(trimmed.count + trimmed.count / 4)
        var indent = 0
        var inString = false
        var escaped = false
        let pad = "  "
        func newline() { out += "\n" + String(repeating: pad, count: indent) }

        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // Collapse an empty container onto one line.
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
                if j < chars.count, (c == "{" && chars[j] == "}") || (c == "[" && chars[j] == "]") {
                    out.append(c); out.append(chars[j]); i = j
                } else {
                    out.append(c); indent += 1; newline()
                }
            case "}", "]":
                indent = max(0, indent - 1); newline(); out.append(c)
            case ",":
                out.append(c); newline()
            case ":":
                out.append(": ")
            case " ", "\n", "\t", "\r":
                break  // drop insignificant whitespace outside strings
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }
}

struct PiAgentFullDiffView: View {
    let diffText: String
    @State private var lines: [PiAgentFullDiffLine] = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    HStack(alignment: .top, spacing: 10) {
                        Text(line.gutter)
                            .font(AppTheme.Font.caption.monospaced())
                            .foregroundStyle(line.gutterColor)
                            .frame(width: 56, alignment: .trailing)
                            .textSelection(.enabled)
                        Text(line.content.isEmpty ? " " : line.content)
                            .font(AppTheme.Font.caption.monospaced())
                            .foregroundStyle(line.textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.background)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.textContentFill))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        .task(id: diffText) {
            lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map { PiAgentFullDiffLine(raw: String($0)) }
        }
    }
}

private struct PiAgentFullDiffLine: Hashable {
    let prefix: String
    let lineNumber: String
    let content: String

    init(raw: String) {
        guard let first = raw.first, first == "+" || first == "-" || first == " " else {
            prefix = raw.hasPrefix("@@") ? "…" : " "
            lineNumber = ""
            content = raw.replacingOccurrences(of: "\t", with: "   ")
            return
        }
        prefix = String(first)
        let remainder = raw.dropFirst()
        let trimmedLeading = remainder.drop(while: { $0 == " " })
        let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
        lineNumber = String(numberPart)
        let body = numberPart.isEmpty ? remainder : trimmedLeading.dropFirst(numberPart.count)
        content = String(body.drop(while: { $0 == " " })).replacingOccurrences(of: "\t", with: "   ")
    }

    var gutter: String { lineNumber.isEmpty ? prefix : "\(prefix)\(lineNumber)" }

    var background: Color {
        switch prefix {
        case "+": return AppTheme.diffAdded.opacity(AppTheme.roleFillStrongOpacity)
        case "-": return AppTheme.diffRemoved.opacity(AppTheme.roleFillStrongOpacity)
        default: return Color.clear
        }
    }

    var textColor: Color {
        switch prefix {
        case "+": return AppTheme.diffAdded
        case "-": return AppTheme.diffRemoved
        default: return AppTheme.mutedText
        }
    }

    var gutterColor: Color { textColor.opacity(prefix == " " ? 0.75 : 1) }
}

private struct PiAgentCompactDiffPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diffText: String
    @State private var isExpanded = false
    /// `diffText` is a `let` on the card, so we parse once on `.onAppear`
    /// instead of re-splitting + re-filtering + re-allocating `Line`s on every
    /// body eval (this card sits inside the transcript and re-renders on every
    /// streaming token).
    @State private var parsedAllLines: [Line] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                let visible = isExpanded ? parsedAllLines : Array(parsedAllLines.prefix(10))
                ForEach(visible.indices, id: \.self) { index in
                    let line = visible[index]
                    HStack(spacing: 8) {
                        Text(line.gutter)
                            .font(AppTheme.Font.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(line.color)
                            .frame(width: 36, alignment: .trailing)
                        Text(line.content.isEmpty ? " " : line.content)
                            .font(AppTheme.Font.caption2.monospaced())
                            .foregroundStyle(line.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .background(line.background)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous))
            if parsedAllLines.count > 10 {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(isExpanded ? "Show fewer lines" : "Show \(parsedAllLines.count - 10) more lines", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(AppTheme.Font.caption2.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
        }
        .onAppear {
            guard parsedAllLines.isEmpty else { return }
            parsedAllLines = Self.meaningfulLines(in: diffText).map(Line.init(raw:))
        }
    }

    private static func meaningfulLines(in diffText: String) -> [String] {
        diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            guard !line.hasPrefix("diff --git"), !line.hasPrefix("index "), !line.hasPrefix("---"), !line.hasPrefix("+++") else { return false }
            return line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@")
        }
    }

    private struct Line: Hashable {
        let prefix: String
        let lineNumber: String
        let content: String

        init(raw: String) {
            if raw.hasPrefix("@@") {
                prefix = "…"
                lineNumber = ""
                content = raw
                return
            }
            guard let first = raw.first, first == "+" || first == "-" || first == " " else {
                prefix = " "
                lineNumber = ""
                content = raw.trimmingCharacters(in: .whitespaces)
                return
            }
            // Pi's edit diffs prefix each line with its source line number padded
            // for alignment. Split that off so it renders in its own gutter column
            // instead of as a fixed whitespace gap baked into the content.
            prefix = String(first)
            let trimmedLeading = raw.dropFirst().drop(while: { $0 == " " })
            let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
            lineNumber = String(numberPart)
            content = String(trimmedLeading.dropFirst(numberPart.count).drop(while: { $0 == " " }))
        }

        var gutter: String {
            lineNumber.isEmpty ? prefix : "\(prefix) \(lineNumber)"
        }

        var color: Color {
            switch prefix {
            case "+": return AppTheme.diffAdded
            case "-": return AppTheme.diffRemoved
            default: return AppTheme.mutedText
            }
        }

        var background: Color {
            switch prefix {
            case "+": return AppTheme.diffAdded.opacity(AppTheme.roleFillStrongOpacity)
            case "-": return AppTheme.diffRemoved.opacity(AppTheme.roleFillStrongOpacity)
            default: return Color.clear
            }
        }
    }
}

struct PiAgentWebActivitySummaryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activities: [PiAgentTranscriptActivity]
    @State private var expandedRows: Set<UUID> = []

    var body: some View {
        let rows = displayRows
        let hiddenUpdateCount = max(0, activities.count - rows.count)
        VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(hasErrors ? AppTheme.roleError : AppTheme.mutedText)
                Text(title)
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text(callCountText)
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: row.icon)
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .foregroundStyle(row.isError ? AppTheme.roleError : AppTheme.mutedText)
                                .frame(width: 14)
                            Text(row.title)
                                .font(AppTheme.Font.caption.weight(.semibold))
                            if let detail = row.detail {
                                Text(detail)
                                    .font(AppTheme.Font.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }

                        if !row.links.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(visibleLinks(for: row)) { link in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•")
                                            .foregroundStyle(AppTheme.mutedText)
                                        Text(link.title)
                                            .font(AppTheme.Font.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(link.domain)
                                            .font(AppTheme.Font.caption2)
                                            .foregroundStyle(AppTheme.mutedText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                if row.links.count > inlineLinkLimit {
                                    Button {
                                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { toggleExpanded(row.id) }
                                    } label: {
                                        Text(expandedRows.contains(row.id) ? "Show fewer results" : "+\(row.links.count - inlineLinkLimit) more results")
                                            .font(AppTheme.Font.caption2.weight(.semibold))
                                            .foregroundStyle(AppTheme.brandAccent)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 1)
                                }
                            }
                            .padding(.leading, 21)
                        }
                    }
                }
                if hiddenUpdateCount > 0 {
                    Text("\(hiddenUpdateCount) older web update\(hiddenUpdateCount == 1 ? "" : "s") hidden")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .padding(.horizontal, AppTheme.Chat.cardHPadding)
        .padding(.vertical, AppTheme.Chat.cardVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private let inlineLinkLimit = 5

    private func visibleLinks(for row: Row) -> [PiAgentWebLink] {
        expandedRows.contains(row.id) ? row.links : Array(row.links.prefix(inlineLinkLimit))
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
    }

    private var displayRows: [Row] {
        activities.map(Row.init(activity:)).prefix(4).map { $0 }
    }

    private var title: String {
        let names = Set(activities.map { $0.name.lowercased() })
        if names.count == 1, let name = names.first {
            switch name {
            case "web_search": return "Web search"
            case "fetch_content": return "Fetch content"
            case "get_search_content": return "Read web content"
            case "web_fetch": return "URL fetch"
            default: break
            }
        }
        return "Web"
    }

    private var hasErrors: Bool {
        activities.contains(where: \.isError)
    }

    private var callCountText: String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let detail: String?
        let icon: String
        let isError: Bool
        let links: [PiAgentWebLink]

        nonisolated init(activity: PiAgentTranscriptActivity) {
            id = activity.id
            title = Self.title(for: activity.name)
            detail = activity.compactDetail
            icon = Self.icon(for: activity.name)
            isError = activity.isError
            links = activity.webLinks
        }

        nonisolated private static func title(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "Search"
            case "fetch_content": return "Fetched"
            case "get_search_content": return "Read content"
            case "web_fetch": return "Fetched"
            default: return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        nonisolated private static func icon(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "magnifyingglass"
            case "fetch_content", "get_search_content", "web_fetch": return "doc.text.magnifyingglass"
            default: return "globe"
            }
        }
    }
}

struct PiAgentActivityDetailView: View {
    let activity: PiAgentTranscriptActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(activity.isError ? AppTheme.roleError : AppTheme.mutedText)
                Text(activity.name)
                    .font(AppTheme.Font.caption.weight(.semibold))
                if activity.count > 1 {
                    Text("×\(activity.count)")
                        .font(AppTheme.Font.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
            ForEach(activity.entries.suffix(3)) { entry in
                PiAgentToolTranscriptView(entry: entry, startsExpanded: false)
            }
            if activity.entries.count > 3 {
                Text("\(activity.entries.count - 3) older updates hidden")
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var icon: String {
        switch activity.name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct PiAgentLoopRecapTranscriptCard: View {
    let entry: PiAgentTranscriptEntry
    let marker: LoopRunRecapMarker

    @Environment(\.transcriptContentWidth) private var transcriptContentWidth

    private var payload: NativeLoopRecapPayload {
        NativeLoopRecapPayload.make(entry: entry, marker: marker)
    }

    var body: some View {
        let payload = payload
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: payload.icon)
                    .font(AppTheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(Color(nsColor: payload.accent))
                Text(payload.title)
                    .font(AppTheme.Font.footnote.weight(.semibold))
                Text(payload.label)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Text(payload.timeText)
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Text(payload.outcomeText)
                .font(AppTheme.Font.caption.weight(.medium))
                .foregroundStyle(AppTheme.mutedText)
            MarkdownTextView(source: payload.summaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !payload.detailsText.isEmpty {
                MarkdownTextView(source: payload.detailsText)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.72)
            }
        }
        .padding(.horizontal, AppTheme.Chat.bubbleHPadding)
        .padding(.vertical, AppTheme.Chat.bubbleVPadding)
        .frame(maxWidth: PiAgentBubbleWidth.replyCap(for: transcriptContentWidth), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.bubbleCornerRadius, style: .continuous)
                .fill(Color(nsColor: payload.accent).opacity(AppTheme.roleFillStrongOpacity))
                .stroke(Color(nsColor: payload.accent).opacity(AppTheme.roleStrokeOpacity), lineWidth: 1)
        )
    }
}

struct PiAgentStatusTranscriptRow: View {
    let entry: PiAgentTranscriptEntry
    @State private var promptPopover: PromptPopover?
    @State private var isErrorPopoverPresented = false

    private struct PromptPopover: Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }

    var body: some View {
        if isDividerEntry {
            compactionDivider
        } else {
            compactStatusRow
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous))
                .onTapGesture {
                    guard showsErrorPopover else { return }
                    isErrorPopoverPresented = true
                }
                .popover(item: $promptPopover, arrowEdge: .bottom) { prompt in
                    PiAgentPromptAuditPopover(title: prompt.title, text: prompt.text)
                }
                .popover(isPresented: $isErrorPopoverPresented, arrowEdge: .bottom) {
                    PiAgentErrorDetailPopover(title: entry.title, text: entry.text)
                }
        }
    }

    private var compactionDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
            HStack(spacing: 7) {
                if isCompacting {
                    AppSpinner()
                        .controlSize(.small)
                } else {
                    Image(systemName: dividerIcon)
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text(detail)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .appGlassCapsule()
            .layoutPriority(1)
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var compactStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .imageScale(.small)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .font(AppTheme.Font.caption.weight(.semibold))
            Text(detail)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(AppTheme.Font.caption2)
                .foregroundStyle(AppTheme.mutedText)
            if isCopyableToolError {
                AppCopyIconButton(
                    text: errorClipboardText,
                    help: "Copy tool error",
                    size: CGSize(width: 22, height: 22)
                )
            }
            ForEach(promptActions) { action in
                Button {
                    promptPopover = .init(title: action.title, text: action.text())
                } label: {
                    Image(systemName: action.icon)
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(action.help)
                .disabled(!action.isEnabled)
            }
        }
        .padding(.horizontal, AppTheme.Chat.cardHPadding)
        .padding(.vertical, AppTheme.Chat.cardVPadding)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(color.opacity(0.08)).stroke(color.opacity(0.16), lineWidth: 1))
    }

    private var title: String {
        if entry.title == "Compaction" { return "Context" }
        if entry.title.hasPrefix("Tool: ") { return "Tool failed" }
        return entry.title
    }

    private var isCopyableToolError: Bool {
        entry.role == .error && entry.title.hasPrefix("Tool: ")
    }

    private var errorClipboardText: String {
        let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
        return "Tool failed: \(toolName)\n\n\(entry.text)"
    }

    private var detail: String {
        let normalized = entry.text
            .replacingOccurrences(of: "Context compacted.", with: "compacted")
            .replacingOccurrences(of: "Context compacted", with: "compacted")
            .replacingOccurrences(of: "Compacting conversation context (context)…", with: "compacting…")
            .replacingOccurrences(of: "Compacting context…", with: "compacting…")
            .replacingOccurrences(of: "\n", with: " ")
        if entry.title.hasPrefix("Tool: ") {
            let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
            return "\(toolName): \(normalized)"
        }
        return normalized
    }

    private var isCompacting: Bool {
        detail.localizedCaseInsensitiveContains("compacting") && !detail.localizedCaseInsensitiveContains("compacted")
    }

    private var icon: String {
        if entry.title == "Compaction" { return "arrow.triangle.2.circlepath" }
        if entry.role == .error { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var isDividerEntry: Bool {
        entry.isDividerStatus
    }

    private var dividerIcon: String {
        entry.title == LoopIterationSeparatorCodec.title ? "infinity" : (PiAgentGitEventKind.from(title: entry.title)?.icon ?? "arrow.triangle.2.circlepath")
    }

    private var color: Color {
        if entry.title == "Compaction" { return .secondary }
        if entry.role == .error { return AppTheme.roleError }
        return .secondary
    }

    private var showsErrorPopover: Bool {
        entry.role == .error && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptActions: [PromptAuditAction] {
        if entry.title == "System Prompt Captured", let prompt = capturedSystemPrompt {
            return [
                PromptAuditAction(
                    title: "Final System Prompt",
                    icon: "doc.text.magnifyingglass",
                    help: "Show final system prompt captured from Pi runtime",
                    isEnabled: true,
                    text: { prompt }
                )
            ]
        }

        guard entry.title == "Subagent Started", let metadata = subagentPromptMetadata else { return [] }
        return [
            PromptAuditAction(
                title: "\(AppBrand.displayName) Authored System Prompt",
                icon: "doc.text",
                help: "Show system prompt \(AppBrand.displayName) passed to the child",
                isEnabled: true,
                text: { promptFileText(path: metadata.authoredSystemPromptPath) }
            ),
            PromptAuditAction(
                title: "Final Runtime System Prompt",
                icon: "doc.text.magnifyingglass",
                help: "Show system prompt captured from the child Pi runtime",
                isEnabled: true,
                text: { promptFileText(path: metadata.finalSystemPromptPath) }
            )
        ]
    }

    private var capturedSystemPrompt: String? {
        guard let raw = entry.rawJSON else { return nil }
        // Memoized by raw content — re-decoding on every body eval otherwise.
        return JSONParseMemo.value("capturedSystemPrompt\(JSONParseMemo.separator)\(raw)") {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let prefill = object["prefill"] as? String,
               let payload = try? JSONSerialization.jsonObject(with: Data(prefill.utf8)) as? [String: Any],
               let prompt = payload["systemPrompt"] as? String {
                return prompt
            }
            if let dataObject = object["data"] as? [String: Any],
               let prefill = dataObject["prefill"] as? String,
               let payload = try? JSONSerialization.jsonObject(with: Data(prefill.utf8)) as? [String: Any],
               let prompt = payload["systemPrompt"] as? String {
                return prompt
            }
            return object["systemPrompt"] as? String
        }
    }

    private var subagentPromptMetadata: SubagentPromptMetadata? {
        guard let raw = entry.rawJSON else { return nil }
        return JSONParseMemo.value("subagentPromptMetadata\(JSONParseMemo.separator)\(raw)") {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["agent_deck_subagent_started", "agent_deck_subagent_card"].contains(object["type"] as? String),
                  let authored = object["authoredSystemPromptPath"] as? String,
                  let final = object["finalSystemPromptPath"] as? String else { return nil }
            return SubagentPromptMetadata(authoredSystemPromptPath: authored, finalSystemPromptPath: final)
        }
    }
}

private struct PromptAuditAction: Identifiable {
    let id = UUID()
    var title: String
    var icon: String
    var help: String
    var isEnabled: Bool
    var text: () -> String
}

private struct SubagentPromptMetadata {
    var authoredSystemPromptPath: String
    var finalSystemPromptPath: String
}

/// Pinned at the top of a forked session's transcript. Shows where the session
/// was forked from, with a "View" button that pops over the snapshot of the
/// parent transcript captured at fork time. Tapping "Open Parent" selects the
/// parent session in the sidebar so the user can jump back to the source.
struct PiAgentForkOriginCard: View {
    var parentTitle: String
    var parentSessionID: UUID?
    var transcriptSnapshot: String?
    var onSelectParent: ((UUID) -> Void)?
    @State private var isSnapshotPresented = false

    var body: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Forked from")
                        Text("\u{201C}\(parentTitle)\u{201D}")
                            .fontWeight(.semibold)
                    }
                    .font(AppTheme.Font.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    if let snapshot = transcriptSnapshot, !snapshot.isEmpty {
                        Text("~\(formatPromptTokens(estimatedPromptTokens(snapshot))) of parent transcript captured")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    } else {
                        Text("Parent transcript not captured")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }

                Spacer(minLength: 0)

                if let parentSessionID, let onSelectParent {
                    Button("Open Parent") {
                        onSelectParent(parentSessionID)
                    }
                    .appSecondaryButton()
                    .controlSize(.small)
                }

                if let snapshot = transcriptSnapshot, !snapshot.isEmpty {
                    Button("View") {
                        isSnapshotPresented = true
                    }
                    .appSecondaryButton()
                    .controlSize(.small)
                    .popover(isPresented: $isSnapshotPresented, arrowEdge: .bottom) {
                        PiAgentPromptAuditPopover(title: "Forked from \u{201C}\(parentTitle)\u{201D}", text: snapshot)
                    }
                }
            }
        }
    }
}

struct PiAgentSystemPromptAuditCard: View {
    var title: String
    var subtitle: String
    var prompt: String
    @State private var isPromptPresented = false

    var body: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppTheme.Font.headline)
                    HStack(spacing: 6) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                            Text("·")
                        }
                        Image(systemName: "tugriksign.circle")
                            .font(AppTheme.Font.caption2.weight(.semibold))
                        Text("~\(formatPromptTokens(estimatedPromptTokens(prompt)))")
                            .font(AppTheme.Font.caption.monospacedDigit().weight(.semibold))
                    }
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                }

                Spacer(minLength: 0)

                Button("View") {
                    isPromptPresented = true
                }
                .appSecondaryButton()
                .controlSize(.small)
                .popover(isPresented: $isPromptPresented, arrowEdge: .bottom) {
                    PiAgentPromptAuditPopover(title: title, text: prompt)
                }
            }
        }
    }
}

extension PiAgentTranscriptEntry {
    var nativeSubagentRunID: UUID? {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              ["agent_deck_subagent_started", "agent_deck_subagent_card"].contains(type),
              let runID = object["runID"] as? String else { return nil }
        return UUID(uuidString: runID)
    }

    /// Status entries that should span the full transcript width as a divider,
    /// not be inset to the assistant bubble width.
    var isDividerStatus: Bool {
        guard role == .status else { return false }
        if title == "Compaction" || title == LoopIterationSeparatorCodec.title { return true }
        return PiAgentGitEventKind.from(title: title) != nil
    }
}

func estimatedPromptTokens(_ text: String) -> Int {
    guard text.isEmpty == false else { return 0 }
    return Int(ceil(Double(text.count) / 3.5))
}

func formatPromptTokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 10_000 { return "\(value / 1_000)k" }
    return value.formatted()
}

func promptFileText(path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Prompt file is not available yet:\n\(path)"
}

struct PiAgentPromptAuditPopover: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(AppTheme.brandAccent)
                Text(title)
                    .font(AppTheme.Font.headline)
                Spacer(minLength: 0)
                AppCopyIconButton(
                    text: text,
                    help: "Copy prompt",
                    size: CGSize(width: 26, height: 26)
                )
            }

            ScrollView(showsIndicators: false) {
                Text(text.isEmpty ? "No prompt content captured." : text)
                    .font(AppTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: 720, height: 520)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .padding(14)
    }
}

struct PiAgentErrorDetailPopover: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.roleError)
                Text(title)
                    .font(AppTheme.Font.headline)
                Spacer(minLength: 0)
                AppCopyIconButton(
                    text: text,
                    help: "Copy error",
                    size: CGSize(width: 26, height: 26)
                )
            }

            Text(text)
                .font(AppTheme.Font.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360, alignment: .leading)
                .foregroundStyle(.primary)
        }
        .padding(14)
    }
}

enum PiAgentTranscriptCardStyle {
    case standalone
    case question
    case threadChild
}

struct PiAgentUserMessageContent: View {
    let entry: PiAgentTranscriptEntry
    var skills: [SkillRecord] = []
    var commandSlashNames: Set<String> = []
    @State private var preview: AttachmentPreview?

    private struct ParsedContent {
        let messageText: String
        let imageAttachments: [PiAgentImageAttachment]
        let legacyImageNames: [String]
        let fileAttachments: [FileAttachmentPreview]
        let folderAttachments: [FolderAttachmentPreview]
        let pasteAttachments: [PiAgentPasteAttachment]
        let issueAttachment: PiAgentIssueAttachment?
        /// `/skill:name` if the entry started with that prefix.
        let skillInvocation: String?
        /// `/foo` if the entry started with a bare-slash token (resolved at
        /// render time against `commandSlashNames` to decide whether to render
        /// the command chip — otherwise the prefix stays in `messageText`).
        let bareSlashInvocation: String?
    }

    @MainActor private static var parsedContentCache: [String: ParsedContent] = [:]
    @MainActor private static var parsedContentCacheOrder: [String] = []
    private static let parsedContentCacheLimit = 256

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !messageText.isEmpty {
                MarkdownTextView(source: messageText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasAnyChip {
                HStack(alignment: .top, spacing: 8) {
                    if let skillUse = resolvedSkillUse {
                        attachmentChip(name: skillUse.name, systemImage: "sparkles", attachment: .skill(skillUse))
                    }
                    if let commandUse = resolvedCommandUse {
                        attachmentChip(name: commandUse.name, systemImage: "terminal", attachment: .command(commandUse))
                    }
                    if let issueAttachment {
                        attachmentChip(name: "\(issueAttachment.kindShortTitle) #\(issueAttachment.number) \(issueAttachment.title)", systemImage: "exclamationmark.circle", attachment: .issue(issueAttachment))
                    }
                    ForEach(imageAttachments.prefix(6)) { image in
                        attachmentChip(name: image.name, systemImage: "photo", attachment: .image(image))
                    }
                    ForEach(legacyImageNames.prefix(max(0, 6 - imageAttachments.count)), id: \.self) { name in
                        attachmentChip(name: name, systemImage: "photo", attachment: .missing(name))
                    }
                    ForEach(fileAttachments.prefix(6)) { file in
                        attachmentChip(name: file.name, systemImage: "doc.text", attachment: .file(file))
                    }
                    ForEach(folderAttachments.prefix(6)) { folder in
                        attachmentChip(name: folder.name, systemImage: "folder", attachment: .folder(folder))
                    }
                    ForEach(pasteAttachments.prefix(6)) { paste in
                        attachmentChip(name: paste.marker, systemImage: "doc.plaintext", attachment: .paste(paste))
                    }
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount)")
                            .font(AppTheme.Font.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedText)
                            .padding(8)
                            .appGlassCapsule()
                    }
                }
            }
        }
    }

    private var hasAnyChip: Bool {
        !imageAttachments.isEmpty || !legacyImageNames.isEmpty || !fileAttachments.isEmpty || !folderAttachments.isEmpty || !pasteAttachments.isEmpty || issueAttachment != nil || resolvedSkillUse != nil || resolvedCommandUse != nil
    }

    private var parsedContent: ParsedContent {
        Self.parsedContent(for: entry)
    }

    /// The visible message text after stripping inline `<file>` tags, paste
    /// markers, and folder references — i.e. what `MarkdownTextView` actually
    /// renders. Exposed so the iMessage bubble width can be measured against
    /// what's drawn, not the raw entry text (which embeds long file paths
    /// from image attachments and would otherwise saturate the width cap).
    /// Treats a `/skill:` prefix as stripped (always rendered as a chip).
    /// `commandSlashNames` lets the same stripping happen for resolved commands.
    /// When `skills` is provided, an inactive-skill body match also gets its
    /// body stripped (only the user's trailing text remains as the bubble text).
    @MainActor
    static func displayMessageText(for entry: PiAgentTranscriptEntry, skills: [SkillRecord] = [], commandSlashNames: Set<String> = []) -> String {
        let parsed = parsedContent(for: entry)
        let visibleText: String
        if parsed.skillInvocation != nil {
            visibleText = parsed.messageText
        } else if let inactive = inactiveSkillMatch(for: entry, parsed: parsed, skills: skills) {
            visibleText = inactive.remainingText
        } else if let cmd = parsed.bareSlashInvocation {
            visibleText = commandSlashNames.contains(cmd)
                ? parsed.messageText
                : (parsed.messageText.isEmpty ? "/\(cmd)" : "/\(cmd) \(parsed.messageText)")
        } else {
            visibleText = parsed.messageText
        }
        return visibleText.isEmpty ? attachmentSummary(for: parsed) : visibleText
    }

    /// Natural unwrapped width of the chip row this bubble will draw, so the
    /// bubble can grow to fit pills (within the cap) for messages with short
    /// text but wide attachments. Mirrors the chips emitted in `body`.
    @MainActor
    static func displayChipsNaturalWidth(for entry: PiAgentTranscriptEntry, skills: [SkillRecord] = [], commandSlashNames: Set<String> = []) -> CGFloat {
        let parsed = parsedContent(for: entry)
        var labels: [String] = []
        if let name = parsed.skillInvocation {
            labels.append(name)
        } else if let inactive = inactiveSkillMatch(for: entry, parsed: parsed, skills: skills) {
            labels.append(inactive.skill.name)
        }
        if let name = parsed.bareSlashInvocation, commandSlashNames.contains(name) {
            labels.append(name)
        }
        if let issue = parsed.issueAttachment {
            labels.append("\(issue.kindShortTitle) #\(issue.number) \(issue.title)")
        }
        let imageNames = parsed.imageAttachments.prefix(6).map(\.name)
        labels.append(contentsOf: imageNames)
        let remainingLegacy = max(0, 6 - parsed.imageAttachments.count)
        labels.append(contentsOf: parsed.legacyImageNames.prefix(remainingLegacy))
        labels.append(contentsOf: parsed.fileAttachments.prefix(6).map(\.name))
        labels.append(contentsOf: parsed.folderAttachments.prefix(6).map(\.name))
        labels.append(contentsOf: parsed.pasteAttachments.prefix(6).map(\.marker))
        return ChipLabelWidth.rowWidth(forLabels: labels)
    }

    /// The text drawn by the bubble. This is a display projection only: copy,
    /// fork, and re-run continue to use the canonical `entry.text`.
    private var messageText: String {
        Self.displayMessageText(for: entry, skills: skills, commandSlashNames: commandSlashNames)
    }

    private static func attachmentSummary(for parsed: ParsedContent) -> String {
        var descriptions: [String] = []
        if let issue = parsed.issueAttachment {
            descriptions.append(issue.isPullRequest ? "a pull request" : "an issue")
        }
        appendAttachmentDescription(&descriptions, count: parsed.imageAttachments.count + parsed.legacyImageNames.count, singular: "image", plural: "images", article: "an")
        appendAttachmentDescription(&descriptions, count: parsed.fileAttachments.count, singular: "file", plural: "files", article: "a")
        appendAttachmentDescription(&descriptions, count: parsed.folderAttachments.count, singular: "folder", plural: "folders", article: "a")
        appendAttachmentDescription(&descriptions, count: parsed.pasteAttachments.count, singular: "text paste", plural: "text pastes", article: "a")
        guard !descriptions.isEmpty else { return "" }
        switch descriptions.count {
        case 1:
            return "Attached \(descriptions[0])."
        case 2:
            return "Attached \(descriptions.joined(separator: " and "))."
        default:
            return "Attached \(descriptions.dropLast().joined(separator: ", ")), and \(descriptions.last!)."
        }
    }

    private static func appendAttachmentDescription(_ descriptions: inout [String], count: Int, singular: String, plural: String, article: String) {
        guard count > 0 else { return }
        descriptions.append(count == 1 ? "\(article) \(singular)" : "\(count) \(plural)")
    }
    private var imageAttachments: [PiAgentImageAttachment] { parsedContent.imageAttachments }
    private var folderAttachments: [FolderAttachmentPreview] { parsedContent.folderAttachments }
    private var fileAttachments: [FileAttachmentPreview] { parsedContent.fileAttachments }
    private var legacyImageNames: [String] { parsedContent.legacyImageNames }
    private var pasteAttachments: [PiAgentPasteAttachment] { parsedContent.pasteAttachments }
    private var issueAttachment: PiAgentIssueAttachment? { parsedContent.issueAttachment }
    /// Resolved skill chip — from `/skill:` prefix when active, or from a
    /// body match against the known skills list when inactive.
    private var resolvedSkillUse: SkillUseAttachment? {
        if let name = parsedContent.skillInvocation {
            return SkillUseAttachment(name: name, skill: skills.first { $0.name == name })
        }
        if let inactive = Self.inactiveSkillMatch(for: entry, parsed: parsedContent, skills: skills) {
            return SkillUseAttachment(name: inactive.skill.name, skill: inactive.skill)
        }
        return nil
    }

    /// Detect that the bubble's text is an inactive-skill invocation: the
    /// message text begins with a known skill's body (optionally followed
    /// by user-typed text after a blank line — the format `SlashItem.materialize`
    /// produces when the skill extension isn't loaded in Pi).
    @MainActor
    private static func inactiveSkillMatch(for entry: PiAgentTranscriptEntry, parsed: ParsedContent, skills: [SkillRecord]) -> (skill: SkillRecord, remainingText: String)? {
        guard parsed.skillInvocation == nil, parsed.bareSlashInvocation == nil else { return nil }
        let trimmed = parsed.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for skill in skills {
            let body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, trimmed.count >= body.count else { continue }
            if trimmed == body {
                return (skill, "")
            }
            // Inactive materialize separates body and user text with `\n\n`.
            if trimmed.hasPrefix(body + "\n\n") {
                let remaining = String(trimmed.dropFirst(body.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (skill, remaining)
            }
        }
        return nil
    }
    /// Resolved command chip, only when the bare-slash prefix matches an
    /// active command for the session.
    private var resolvedCommandUse: CommandUseAttachment? {
        guard let name = parsedContent.bareSlashInvocation, commandSlashNames.contains(name) else { return nil }
        return CommandUseAttachment(name: name)
    }

    @MainActor
    private static func parsedContent(for entry: PiAgentTranscriptEntry) -> ParsedContent {
        let key = parsedContentCacheKey(for: entry)
        if let cached = parsedContentCache[key] { return cached }

        let markers = ["Attached files:", "Attached images:"]
        let firstRange = markers.compactMap { entry.text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let base = firstRange.map { String(entry.text[..<$0.lowerBound]) } ?? entry.text
        let pasteAttachments = pastes(for: entry)
        let messageWithoutPastes = removingPasteMarkers(from: base, pasteAttachments: pasteAttachments)
        let messageWithoutTagsFoldersPastes = removingFolderReferences(from: removingFileTags(from: messageWithoutPastes)).trimmingCharacters(in: .whitespacesAndNewlines)
        let (skillInvocation, bareSlashInvocation, messageText) = extractSlashInvocation(from: messageWithoutTagsFoldersPastes)
        let imageAttachments = images(for: entry)
        let issueAttachment = issue(for: entry)
        let inlineFileTags = inlineFileTags(in: entry.text)
        let folderAttachments = uniqueFolders(folderReferences(in: entry.text).map { path in
            FolderAttachmentPreview(name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent, path: path)
        })
        let payloadFiles = payloadFiles(for: entry).filter { !isImageName($0.name) }
        let payloadFileNames = Set(payloadFiles.map(\.name))
        // Fall back to the basename-only "Attached files:" list for entries
        // written before `files[]` was added to the JSON payload, or for files
        // that somehow weren't captured there. The payload entries carry the
        // real path (preview works); the listed fallbacks don't.
        let listedFiles = attachmentLines(after: "Attached files:", in: entry.text).compactMap { line -> FileAttachmentPreview? in
            guard !line.contains("<image ") else { return nil }
            guard !payloadFileNames.contains(line) else { return nil }
            return .init(name: line, path: nil)
        }
        let taggedFiles = inlineFileTags.filter { !isImageName($0.name) && !payloadFileNames.contains($0.name) }
        let fileAttachments = uniqueFiles(payloadFiles + taggedFiles + listedFiles)
        let imageLines = attachmentLines(after: "Attached images:", in: entry.text) + attachmentLines(after: "Attached files:", in: entry.text).filter { $0.contains("<image ") }
        let legacyImageNames = uniqueNames(imageLines.compactMap(imageName(from:)) + inlineFileTags.filter { isImageName($0.name) }.map(\.name)).filter { name in
            !imageAttachments.contains { $0.name == name }
        }

        let parsed = ParsedContent(
            messageText: messageText,
            imageAttachments: imageAttachments,
            legacyImageNames: legacyImageNames,
            fileAttachments: fileAttachments,
            folderAttachments: folderAttachments,
            pasteAttachments: pasteAttachments,
            issueAttachment: issueAttachment,
            skillInvocation: skillInvocation,
            bareSlashInvocation: bareSlashInvocation
        )
        parsedContentCache[key] = parsed
        parsedContentCacheOrder.append(key)
        if parsedContentCacheOrder.count > parsedContentCacheLimit {
            let overflow = parsedContentCacheOrder.count - parsedContentCacheLimit
            for oldKey in parsedContentCacheOrder.prefix(overflow) {
                parsedContentCache[oldKey] = nil
            }
            parsedContentCacheOrder.removeFirst(overflow)
        }
        return parsed
    }

    private static func parsedContentCacheKey(for entry: PiAgentTranscriptEntry) -> String {
        // User entries are immutable after insertion. Avoid hashing large attached
        // file payloads on every SwiftUI body pass for long chats.
        "\(entry.id.uuidString):\(entry.text.count):\(entry.rawJSON?.count ?? 0)"
    }

    private static func attachmentLines(after marker: String, in text: String) -> [String] {
        guard let range = text.range(of: marker) else { return [] }
        let tail = text[range.upperBound...]
        let stop = marker == "Attached files:" ? tail.range(of: "Attached images:")?.lowerBound : nil
        let slice = stop.map { tail[..<$0] } ?? tail[...]
        return slice.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    private static func inlineFileTags(in text: String) -> [FileAttachmentPreview] {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let path = String(text[range])
            return .init(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
    }

    private static func imageName(from raw: String) -> String? {
        guard let range = raw.range(of: #"name=\"([^\"]+)\""#, options: .regularExpression) else { return nil }
        let match = raw[range]
        return match.replacingOccurrences(of: "name=\"", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Detect a leading slash invocation produced by `SlashItem.materialize`.
    /// Returns `(skillInvocation, bareSlashInvocation, remainingMessage)`:
    /// - `/skill:name` → `(name, nil, rest)` — always treated as a skill chip.
    /// - `/foo …`     → `(nil, "foo", text-without-prefix)` — the caller decides
    ///   whether to render the chip based on the active command set; if not, the
    ///   prefix stays in the displayed message.
    private static func extractSlashInvocation(from text: String) -> (skill: String?, bareSlash: String?, remaining: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return (nil, nil, text) }
        if trimmed.hasPrefix("/skill:") {
            // `/skill:name` is followed by either whitespace/newline (then rest) or end of string.
            let afterPrefix = trimmed.dropFirst("/skill:".count)
            let nameEnd = afterPrefix.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? afterPrefix.endIndex
            let name = String(afterPrefix[..<nameEnd])
            guard !name.isEmpty else { return (nil, nil, text) }
            let remaining = String(afterPrefix[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, nil, remaining)
        }
        // Bare `/foo …` — accept names made of [A-Za-z0-9_-:], no spaces.
        let afterSlash = trimmed.dropFirst()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-:"))
        let nameEnd = afterSlash.firstIndex(where: { ch in
            guard let scalar = ch.unicodeScalars.first else { return true }
            return !allowed.contains(scalar)
        }) ?? afterSlash.endIndex
        let name = String(afterSlash[..<nameEnd])
        guard !name.isEmpty else { return (nil, nil, text) }
        let remaining = String(afterSlash[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, name, remaining)
    }

    private static func removingFileTags(from text: String) -> String {
        text.replacingOccurrences(of: #"<file name=\"[^\"]+\">[\s\S]*?</file>"#, with: "", options: .regularExpression)
    }

    private static func removingPasteMarkers(from text: String, pasteAttachments: [PiAgentPasteAttachment]) -> String {
        guard !pasteAttachments.isEmpty else { return text }
        var output = text
        for paste in pasteAttachments {
            output = output.replacingOccurrences(of: paste.marker, with: "")
        }
        return output
    }

    private static func removingFolderReferences(from text: String) -> String {
        guard !folderReferences(in: text).isEmpty else { return text }
        var output = text
        for pattern in folderReferencePatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return output
            .replacingOccurrences(of: #"^\s*-\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private static func folderReferences(in text: String) -> [String] {
        let explicit = matches(pattern: #"\bfolder:\s*`([^`]+)`"#, in: text)
            + matches(pattern: #"\bfolder:\s*(/[^\n`]+?)(?=\s+-\s+|\n|$)"#, in: text)
        let bare = matches(pattern: #"^\s*`(/[^`]+)`(?=\s+-\s+|\s*$)"#, in: text)
            + matches(pattern: #"^\s*(/[^\n`]+?)(?=\s+-\s+|\n|$)"#, in: text)
        return uniquePaths(explicit) + uniqueExistingDirectories(bare)
    }

    private static var folderReferencePatterns: [String] {
        [
            #"\bfolder:\s*`[^`]+`\s*(?:-\s*)?"#,
            #"\bfolder:\s*/[^\n`]+?(?=\s+-\s+|\n|$)\s*(?:-\s*)?"#,
            #"^\s*`/[^`]+`(?=\s+-\s+|\s*$)\s*(?:-\s*)?"#,
            #"^\s*/[^\n`]+?(?=\s+-\s+|\n|$)\s*(?:-\s*)?"#
        ]
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func uniqueExistingDirectories(_ paths: [String]) -> [String] {
        uniquePaths(paths).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func isImageName(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func uniqueFiles(_ files: [FileAttachmentPreview]) -> [FileAttachmentPreview] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.name).inserted }
    }

    private static func uniqueFolders(_ folders: [FolderAttachmentPreview]) -> [FolderAttachmentPreview] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.path).inserted }
    }

    private struct AttachmentPayload: Decodable {
        let images: [PiAgentImageAttachment]?
        let pastes: [PiAgentPasteAttachment]?
        let issue: PiAgentIssueAttachment?
        let files: [FilePayload]?
    }

    private struct FilePayload: Decodable {
        let name: String
        let path: String
    }

    private static func attachmentPayload(for entry: PiAgentTranscriptEntry) -> AttachmentPayload? {
        guard let rawJSON = entry.rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? transcriptJSONDecoder.decode(AttachmentPayload.self, from: data)
    }

    private static func images(for entry: PiAgentTranscriptEntry) -> [PiAgentImageAttachment] {
        attachmentPayload(for: entry)?.images ?? []
    }

    private static func pastes(for entry: PiAgentTranscriptEntry) -> [PiAgentPasteAttachment] {
        attachmentPayload(for: entry)?.pastes ?? []
    }

    private static func issue(for entry: PiAgentTranscriptEntry) -> PiAgentIssueAttachment? {
        attachmentPayload(for: entry)?.issue
    }

    private static func payloadFiles(for entry: PiAgentTranscriptEntry) -> [FileAttachmentPreview] {
        (attachmentPayload(for: entry)?.files ?? []).map { FileAttachmentPreview(name: $0.name, path: $0.path) }
    }

    private var hiddenCount: Int {
        let chipCount = imageAttachments.count + legacyImageNames.count + fileAttachments.count + folderAttachments.count + pasteAttachments.count
            + (issueAttachment == nil ? 0 : 1)
            + (resolvedSkillUse == nil ? 0 : 1)
            + (resolvedCommandUse == nil ? 0 : 1)
        return max(0, chipCount - 12)
    }

    private func attachmentChip(name: String, systemImage: String, attachment: AttachmentPreview) -> some View {
        Button { preview = attachment } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(AppTheme.Font.caption2)
        }
        .appSmallSecondaryButton()
        .help("Preview \(name)")
        .popover(isPresented: Binding(
            get: { preview == attachment },
            set: { isPresented in
                if isPresented {
                    preview = attachment
                } else if preview == attachment {
                    preview = nil
                }
            }
        ), arrowEdge: .bottom) {
            AttachmentPreviewPopover(attachment: attachment)
        }
    }
}

private struct FileAttachmentPreview: Identifiable, Hashable {
    var id: String { path ?? name }
    let name: String
    let path: String?
}

private struct FolderAttachmentPreview: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

private struct SkillUseAttachment: Hashable {
    let name: String
    let skill: SkillRecord?
}

private struct CommandUseAttachment: Hashable {
    let name: String
}

private enum AttachmentPreview: Identifiable, Hashable {
    case image(PiAgentImageAttachment)
    case file(FileAttachmentPreview)
    case folder(FolderAttachmentPreview)
    case paste(PiAgentPasteAttachment)
    case issue(PiAgentIssueAttachment)
    case missing(String)
    case skill(SkillUseAttachment)
    case command(CommandUseAttachment)

    var id: String {
        switch self {
        case .image(let image): return "image-\(image.id.uuidString)"
        case .file(let file): return "file-\(file.id)"
        case .folder(let folder): return "folder-\(folder.id)"
        case .paste(let paste): return "paste-\(paste.id)-\(paste.marker)"
        case .issue(let issue): return "issue-\(issue.id)"
        case .missing(let name): return "missing-\(name)"
        case .skill(let use): return "skill-\(use.name)"
        case .command(let use): return "command-\(use.name)"
        }
    }
}

private struct AttachmentPreviewPopover: View {
    let attachment: AttachmentPreview
    @State private var filePreviewPath: String?
    @State private var filePreviewText: String?
    @State private var isLoadingFilePreview = false

    /// Single shared popover ceiling. The previous `300` cap was too tight
    /// for skill/file/issue/paste/command bodies. ScrollViews inside use
    /// `.frame(maxHeight: .infinity)` so they expand to fill this height
    /// rather than collapsing to ScrollView's tiny intrinsic; popovers whose
    /// preview body has a natural size (image, folder, missing) ignore this
    /// cap and size to content.
    private static let popoverMaxHeight: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            previewBody
        }
        .padding(12)
        .frame(width: 420, alignment: .topLeading)
        .frame(maxHeight: Self.popoverMaxHeight)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.brandAccent)
            Text(title)
                .font(AppTheme.Font.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder private var previewBody: some View {
        switch attachment {
        case .image(let image):
            if let nsImage = PiAgentComposerImageLoader.previewImage(for: image) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
            } else {
                empty("Preview is not available for this image.")
            }
        case .file(let file):
            if let path = file.path {
                filePreviewBody(path: path)
                    .task(id: path) {
                        await loadTextPreview(atPath: path)
                    }
            } else {
                empty("Preview is not available for this attachment.")
            }
        case .folder(let folder):
            folderPreviewBody(folder: folder)
        case .paste(let paste):
            pastePreviewBody(paste: paste)
        case .issue(let issue):
            issuePreviewBody(issue: issue)
        case .missing:
            empty("Preview is not available for older attachment metadata.")
        case .skill(let use):
            skillPreviewBody(use: use)
        case .command(let use):
            commandPreviewBody(use: use)
        }
    }

    private func skillPreviewBody(use: SkillUseAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let description = use.skill?.description, !description.isEmpty {
                Text(description)
                    .font(AppTheme.Font.subheadline)
                    .foregroundStyle(.secondary)
            }
            ScrollView(showsIndicators: false) {
                Text(use.skill?.body.isEmpty == false
                    ? use.skill!.body
                    : (use.skill?.filePath ?? "Skill details are not available in \(AppBrand.displayName)'s current scan snapshot."))
                    .font(AppTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
        }
    }

    private func commandPreviewBody(use: CommandUseAttachment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command invocation sent to Pi.")
                .font(AppTheme.Font.subheadline)
                .foregroundStyle(.secondary)
            Text("/\(use.name)")
                .font(AppTheme.Font.code)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
        }
    }

    private func pastePreviewBody(paste: PiAgentPasteAttachment) -> some View {
        ScrollView(showsIndicators: false) {
            Text(paste.text)
                .font(AppTheme.Font.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
    }

    private func issuePreviewBody(issue: PiAgentIssueAttachment) -> some View {
        let commentsText = issue.comments.map { comment in
            """
            \(comment.author) · \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
            \(comment.body)
            """
        }
        .joined(separator: "\n\n")
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text(issue.repository)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Text("\(issue.kindTitle) #\(issue.number) \(issue.title)")
                    .font(AppTheme.Font.body.weight(.semibold))
                if let author = issue.author, !author.isEmpty {
                    Text("Author: \(author)")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text("State: \(issue.state)")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if !issue.labels.isEmpty {
                    Text("Labels: \(issue.labels.joined(separator: ", "))")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text("Comments: \(issue.comments.count)")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                if !issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()
                    Text(issue.body)
                        .font(AppTheme.Font.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !issue.comments.isEmpty {
                    Divider()
                    Text(commentsText)
                        .font(AppTheme.Font.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
    }

    @ViewBuilder private func filePreviewBody(path: String) -> some View {
        if isLoadingFilePreview || filePreviewPath != path {
            AppSpinner()
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if let text = filePreviewText {
            ScrollView(showsIndicators: false) {
                Text(String(text.prefix(12_000)))
                    .font(AppTheme.Font.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius).fill(AppTheme.contentSubtleFill))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                Text("Preview is not available for this file type.")
                Text(path)
                    .font(AppTheme.Font.code)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder private func folderPreviewBody(folder: FolderAttachmentPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(folder.path)
                .font(AppTheme.Font.code)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path, isDirectory: true)])
            }
            .appSecondaryButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadTextPreview(atPath path: String) async {
        filePreviewPath = path
        filePreviewText = nil
        isLoadingFilePreview = true
        let text = await Task.detached(priority: .utility) {
            Self.textPreview(atPath: path)
        }.value
        guard !Task.isCancelled, filePreviewPath == path else { return }
        filePreviewText = text
        isLoadingFilePreview = false
    }

    private var title: String {
        switch attachment {
        case .image(let image): return image.name
        case .file(let file): return file.name
        case .folder(let folder): return folder.name
        case .paste(let paste): return paste.marker
        case .issue(let issue): return "\(issue.kindShortTitle) #\(issue.number) \(issue.title)"
        case .missing(let name): return name
        case .skill(let use): return use.skill?.name ?? use.name
        case .command(let use): return "/\(use.name)"
        }
    }

    private var icon: String {
        switch attachment {
        case .image, .missing: return "photo"
        case .file: return "doc.text"
        case .folder: return "folder"
        case .paste: return "doc.plaintext"
        case .issue: return "exclamationmark.circle"
        case .skill: return "sparkles"
        case .command: return "terminal"
        }
    }

    private nonisolated static func textPreview(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .macOSRoman)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.Font.callout)
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

struct PiAgentTranscriptCard: View {
    let entry: PiAgentTranscriptEntry
    var style: PiAgentTranscriptCardStyle = .standalone
    var skills: [SkillRecord] = []
    var commandSlashNames: Set<String> = []
    /// Applies only to automatic transcript image markup; user attachment chips
    /// continue through `PiAgentUserMessageContent` unchanged.
    var showInlineImagePreviews: Bool = true

    /// User questions render as messaging-style bubbles. They still show the
    /// "You" header (icon + label + hover-revealed copy button) like other
    /// cards, but the bubble itself shrinks to fit its content and is pushed
    /// right by the enclosing thread card — content inside stays left-aligned
    /// so text reads naturally.
    private var isUserBubble: Bool {
        entry.role == .user && style == .question
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
            HStack(spacing: 7) {
                headerIcon
                Text(headerTitle)
                    .font(AppTheme.Font.footnote.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(headerColor)
                Spacer(minLength: 0)
            }

            content
        }
        .padding(.horizontal, style == .threadChild ? AppTheme.Chat.bubbleChildHPadding : AppTheme.Chat.bubbleHPadding)
        .padding(.vertical, style == .threadChild ? AppTheme.Chat.bubbleChildVPadding : AppTheme.Chat.bubbleVPadding)
        // User bubbles size to their content (the outer thread card caps the
        // width and pushes them right). Other cards stretch full-width as
        // before. Internal alignment is always .leading so text reads naturally.
        .frame(maxWidth: isUserBubble ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.bubbleCornerRadius, style: .continuous)
                .fill(backgroundStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.bubbleCornerRadius, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var headerIcon: some View {
        if entry.role == .assistant {
            Image("pi")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(AppTheme.piLogo.gradient)
                // Rendered smaller than its 16pt slot so the filled pi mark
                // optically matches the SF Symbols the other roles use.
                .frame(width: 13, height: 13)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var content: some View {
        if entry.role == .tool {
            PiAgentToolTranscriptView(entry: entry)
        } else if entry.role == .thinking {
            // Mirrors the native thinking bubble: a single MarkdownTextView, no
            // subhead. Both renderers MUST stay in lockstep — see
            // `nativeReplyPayload(for:)` for the production path.
            let display = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            MarkdownTextView(source: Self.projectedImageSource(display.isEmpty ? "Pi has not emitted reasoning text yet." : display, references: entry.imageReferences, showImages: showInlineImagePreviews))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if entry.role == .user {
            PiAgentUserMessageContent(entry: entry, skills: skills, commandSlashNames: commandSlashNames)
        } else if entry.role == .assistant {
            MarkdownTextView(source: Self.projectedImageSource(entry.text, references: entry.imageReferences, showImages: showInlineImagePreviews))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? AppTheme.Font.code : AppTheme.Font.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    static func projectedImageSource(
        _ source: String,
        references: [PiAgentTranscriptImageReference],
        showImages: Bool
    ) -> String {
        PiAgentTranscriptImagePresentation.projectedSource(source, references: references, showImages: showImages)
    }

    private var headerTitle: String {
        if entry.title == "Steering" { return "Steering" }
        switch entry.role {
        case .user: return "You"
        case .assistant: return "Coding Agent"
        case .tool: return toolHeaderTitle
        default: return entry.title
        }
    }

    private var toolHeaderTitle: String {
        if entry.title.localizedCaseInsensitiveContains("subagent") || entry.text.localizedCaseInsensitiveContains("subagent") {
            return "Deck agents"
        }
        if entry.title.hasPrefix("Tool: ") {
            return "Tool · " + entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    /// Single base color per role. The card's background fill, border stroke,
    /// and icon/label tint are all derived from this through AppTheme's fixed
    /// opacity scale, so a role reads consistently and adapts to light/dark.
    private var roleBase: Color {
        switch entry.role {
        case .user: return AppTheme.roleUser
        case .assistant: return AppTheme.brandAccent
        case .thinking: return AppTheme.roleThinking
        case .tool: return AppTheme.roleTool
        case .error: return AppTheme.roleError
        case .stderr: return AppTheme.roleStderr
        case .status, .raw: return AppTheme.roleStatus
        }
    }

    /// Status and raw cards sit on the neutral surface rather than a tinted role
    /// color — they are informational. Every other role (user / assistant /
    /// thinking / tool / error / stderr) takes its role base tint.
    private var usesNeutralSurface: Bool {
        entry.role == .status || entry.role == .raw
    }

    private var headerColor: Color {
        entry.role == .assistant ? AppTheme.piLogo : .primary
    }

    private var backgroundStyle: AnyShapeStyle {
        // The Pi reply bubble takes a brand-accent tint through the same
        // role-base path as the user bubble, so it reads as conversation rather
        // than another neutral tool/diff card — light and dark alike.
        if usesNeutralSurface {
            return AnyShapeStyle(AppTheme.contentSubtleFill.opacity(0.7).gradient)
        }
        let fill = style == .question ? AppTheme.roleFillStrongOpacity : AppTheme.roleFillOpacity
        return AnyShapeStyle(roleBase.opacity(fill).gradient)
    }

    private var strokeColor: Color {
        return usesNeutralSurface
            ? AppTheme.contentStroke
            : roleBase.opacity(AppTheme.roleStrokeOpacity)
    }

    private var icon: String {
        switch entry.role {
        case .user: return entry.title == "Steering" ? "arrowshape.turn.up.forward.circle" : "person.crop.circle"
        case .assistant: return "pi"
        case .thinking: return "brain.head.profile"
        case .tool: return entry.title.localizedCaseInsensitiveContains("subagent") ? "person.2.wave.2" : "hammer"
        case .status: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .stderr: return "terminal"
        case .raw: return "curlybraces"
        }
    }

    private var color: Color { roleBase }

    private var copyText: String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

struct PiAgentToolTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: PiAgentTranscriptEntry
    @State private var isExpanded: Bool

    init(entry: PiAgentTranscriptEntry, startsExpanded: Bool = false) {
        self.entry = entry
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Chat.childSpacing) {
            HStack(spacing: 8) {
                Label(toolName, systemImage: icon)
                    .font(AppTheme.Font.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(phaseLabel)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                if isLong {
                    Button(isExpanded ? "Show less" : "Show details") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { isExpanded.toggle() }
                    }
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .buttonStyle(.plain)
                }
            }

            Text(displayText)
                .font(AppTheme.Font.code)
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(isExpanded ? nil : 6)
                .textSelection(.enabled)
                .padding(AppTheme.Chat.cardVPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: AppTheme.Chat.codeCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.7)))
        }
    }

    private var toolName: String {
        entry.title.replacingOccurrences(of: "Tool: ", with: "")
    }

    private var phaseLabel: String {
        let lower = entry.text.lowercased()
        if lower.contains("starting") || lower.contains("preparing") { return "starting" }
        if lower.contains("running") || lower.contains("0/1 done") { return "running" }
        if entry.role == .error { return "failed" }
        return "result"
    }

    private var displayText: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No details emitted yet." : trimmed
    }

    private var isLong: Bool {
        displayText.count > 600 || displayText.split(separator: "\n").count > 8
    }

    private var icon: String {
        switch toolName.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        default: return "wrench.and.screwdriver"
        }
    }

    private var color: Color {
        entry.role == .error ? AppTheme.roleError : AppTheme.roleTool
    }
}
