import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentTranscriptThread: Identifiable, Hashable {
    var id: UUID
    var question: PiAgentTranscriptEntry?
    var steeringMessages: [PiAgentTranscriptEntry]
    var thinking: PiAgentTranscriptEntry?
    var assistantMessages: [PiAgentTranscriptEntry]
    var activities: [PiAgentTranscriptActivity]
    var statuses: [PiAgentTranscriptEntry]
    var errors: [PiAgentTranscriptEntry]

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
        var question: PiAgentTranscriptEntry?
        var steeringMessages: [PiAgentTranscriptEntry] = []
        var thinkingParts: [PiAgentTranscriptEntry] = []
        var assistantMessages: [PiAgentTranscriptEntry] = []
        var toolEntries: [PiAgentTranscriptEntry] = []
        var statuses: [PiAgentTranscriptEntry] = []
        var errors: [PiAgentTranscriptEntry] = []

        mutating func add(_ entry: PiAgentTranscriptEntry) {
            switch entry.role {
            case .user where entry.title == "Steering":
                steeringMessages.append(entry)
            case .thinking:
                thinkingParts.append(entry)
            case .assistant:
                assistantMessages.append(entry)
            case .tool:
                toolEntries.append(entry)
            case .status, .stderr:
                statuses.append(entry)
            case .error:
                errors.append(entry)
            case .user, .raw:
                statuses.append(entry)
            }
        }

        @MainActor
        func makeThread() -> PiAgentTranscriptThread? {
            let activities = PiAgentTranscriptActivity.make(from: toolEntries)
            guard question != nil || !steeringMessages.isEmpty || !thinkingParts.isEmpty || !assistantMessages.isEmpty || !activities.isEmpty || !statuses.isEmpty || !errors.isEmpty else {
                return nil
            }
            let first = question ?? steeringMessages.first ?? thinkingParts.first ?? assistantMessages.first ?? activities.first?.representativeEntry ?? statuses.first ?? errors.first
            let thinking = PiAgentTranscriptEntry.mergedThinking(from: thinkingParts)
            return PiAgentTranscriptThread(
                id: question?.id ?? first?.id ?? UUID(),
                question: question,
                steeringMessages: steeringMessages,
                thinking: thinking,
                assistantMessages: assistantMessages,
                activities: activities,
                statuses: coalescedStatuses(statuses),
                errors: coalescedErrors(errors)
            )
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
            var latestByTool: [String: PiAgentTranscriptEntry] = [:]
            var toolOrder: [String] = []
            for entry in entries {
                let key = PiAgentTranscriptActivity.toolName(for: entry)
                if entry.title.hasPrefix("Tool: ") {
                    if latestByTool[key] == nil { toolOrder.append(key) }
                    latestByTool[key] = normalizedToolError(entry)
                } else {
                    output.append(entry)
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
    var subagentSummary: PiAgentSubagentSummary?

    var representativeEntry: PiAgentTranscriptEntry? { entries.first }
    nonisolated var count: Int { entries.count }
    nonisolated var isWebActivity: Bool {
        switch name.lowercased() {
        case "web_search", "fetch_content", "get_search_content": return true
        default: return false
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
            let subagentSummary = entries.lazy.compactMap(PiAgentSubagentSummary.init(entry:)).first { $0.total > 0 }
            return PiAgentTranscriptActivity(
                id: entries.first?.id ?? UUID(),
                name: name,
                entries: entries,
                isError: entries.contains { $0.role == .error },
                compactDetail: compactDetail(for: name, entries: entries),
                webLinks: webLinks(for: name, entries: entries),
                subagentSummary: subagentSummary
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
        case "fetch_content":
            let links = entries.flatMap(fetchContentLinks)
            return Array(uniqueLinks(links).prefix(20))
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
        case "fetch_content":
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

private extension PiAgentTranscriptEntry {
    static func mergedThinking(from entries: [PiAgentTranscriptEntry]) -> PiAgentTranscriptEntry? {
        guard let first = entries.first else { return nil }
        var seen = Set<String>()
        let text = entries.compactMap { entry -> String? in
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }.joined(separator: "\n\n")
        return PiAgentTranscriptEntry(
            id: first.id,
            sessionID: first.sessionID,
            role: .thinking,
            title: first.title,
            text: text,
            rawJSON: first.rawJSON,
            timestamp: first.timestamp
        )
    }
}

struct PiAgentTranscriptThreadCard: View {
    let thread: PiAgentTranscriptThread
    let thinkingDisplayMode: PiAgentThinkingDisplayMode
    let visibility: PiAgentTranscriptVisibilitySettings
    let skills: [SkillRecord]
    let projectPath: String?
    let planEvents: [PiSessionPlanEventRecord]
    let nativeSubagentRunsByID: [UUID: PiSubagentRunRecord]
    let nativeSubagentCard: (PiSubagentRunRecord) -> PiNativeSubagentRunCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = thread.question {
                PiAgentTranscriptCard(entry: question, thinkingDisplayMode: thinkingDisplayMode, style: .question, skills: skills)
                    .id(question.id)
            }

            if hasChildren {
                HStack(alignment: .top, spacing: 12) {
                    if thread.question != nil {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(AppTheme.contentStroke)
                            .frame(width: 2)
                            .padding(.leading, 16)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(thread.steeringMessages) { entry in
                            PiAgentTranscriptCard(entry: entry, thinkingDisplayMode: thinkingDisplayMode, style: childStyle, skills: skills)
                                .id(entry.id)
                        }
                        if let thinking = thread.thinking, effectiveThinkingDisplayMode != .hidden {
                            PiAgentTranscriptCard(entry: thinking, thinkingDisplayMode: effectiveThinkingDisplayMode, style: childStyle, skills: skills)
                                .id(thinking.id)
                        }
                        if visibility.showWebActivity && !webActivities.isEmpty {
                            PiAgentWebActivitySummaryView(activities: webActivities)
                        }
                        if visibility.showToolCalls && !toolActivities.isEmpty {
                            PiAgentActivitySummaryView(activities: toolActivities)
                        }
                        if visibility.showDiffs {
                            PiAgentThreadDiffSummaryView(activities: toolActivities, projectPath: projectPath)
                        }
                        if visibility.showPlans {
                            ForEach(latestPlanEvents) { event in
                                PiAgentCurrentPlanCard(event: event)
                                    .id(event.id)
                            }
                        }
                        ForEach(thread.statuses) { entry in
                            if let runID = entry.nativeSubagentRunID, let run = nativeSubagentRunsByID[runID] {
                                nativeSubagentCard(run)
                                    .id(entry.id)
                            } else {
                                PiAgentStatusTranscriptRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        ForEach(thread.assistantMessages) { entry in
                            PiAgentTranscriptCard(entry: entry, thinkingDisplayMode: thinkingDisplayMode, style: childStyle, skills: skills)
                                .id(entry.id)
                        }
                        if visibility.showErrors {
                            ForEach(thread.errors) { entry in
                                PiAgentStatusTranscriptRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var childStyle: PiAgentTranscriptCardStyle {
        thread.question == nil ? .standalone : .threadChild
    }

    private var hasChildren: Bool {
        !thread.steeringMessages.isEmpty || (effectiveThinkingDisplayMode != .hidden && thread.thinking != nil) || !thread.assistantMessages.isEmpty || (visibility.showWebActivity && !webActivities.isEmpty) || (visibility.showToolCalls && !toolActivities.isEmpty) || (visibility.showDiffs && !editablePaths.isEmpty) || (visibility.showPlans && !latestPlanEvents.isEmpty) || !thread.statuses.isEmpty || (visibility.showErrors && !thread.errors.isEmpty)
    }

    private var effectiveThinkingDisplayMode: PiAgentThinkingDisplayMode {
        visibility.showThinking ? thinkingDisplayMode : .hidden
    }

    private var webActivities: [PiAgentTranscriptActivity] {
        thread.activities.filter(\.isWebActivity)
    }

    private var toolActivities: [PiAgentTranscriptActivity] {
        thread.activities.filter { !$0.isWebActivity }
    }

    private var editablePaths: [String] {
        PiAgentThreadDiffSummaryView.changedPaths(from: toolActivities)
    }

    private var latestPlanEvents: [PiSessionPlanEventRecord] {
        var latestByPlanID: [UUID: PiSessionPlanEventRecord] = [:]
        for event in planEvents where event.kind != .cleared {
            if let existing = latestByPlanID[event.planID], existing.timestamp >= event.timestamp { continue }
            latestByPlanID[event.planID] = event
        }
        return latestByPlanID.values.sorted { $0.timestamp < $1.timestamp }
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
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Text("Changes")
                        .font(.caption.weight(.semibold))
                    Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                if isLoading && rows.isEmpty {
                    Text("Preparing file changes…")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
                ForEach(rows.prefix(4)) { row in
                    PiAgentInlineDiffCard(row: row)
                }
                if rows.count > 4 {
                    Text("\(rows.count - 4) more changed file\(rows.count - 4 == 1 ? "" : "s") hidden")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
            .task(id: Self.signature(for: changes)) { await loadRows(changes: changes) }
        }
    }

    @MainActor
    static func changedPaths(from activities: [PiAgentTranscriptActivity]) -> [String] {
        changedFiles(from: activities).map(\.path)
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
            let added = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.path.truncatedMiddle(max: 54))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.changeCountText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
                AppCopyTextButton(title: "Copy", text: row.diff)
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
            }
            PiAgentCompactDiffPreview(diffText: row.diff)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.textContentFill.opacity(0.75)))
    }
}

private struct PiAgentCompactDiffPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diffText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(displayLines.indices, id: \.self) { index in
                let line = displayLines[index]
                HStack(spacing: 6) {
                    Text(line.prefix)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(line.color)
                        .frame(width: 12, alignment: .trailing)
                    Text(line.content.isEmpty ? " " : line.content)
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)
                .background(line.background)
            }
            if canExpand {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(isExpanded ? "Show fewer lines" : "Show \(hiddenCount) more lines", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
        }
    }

    private var meaningfulLines: [String] {
        diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            guard !line.hasPrefix("diff --git"), !line.hasPrefix("index "), !line.hasPrefix("---"), !line.hasPrefix("+++") else { return false }
            return line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@")
        }
    }

    private var displayLines: [Line] {
        let visibleLines = isExpanded ? meaningfulLines : Array(meaningfulLines.prefix(10))
        return visibleLines.map(Line.init(raw:))
    }

    private var canExpand: Bool { meaningfulLines.count > 10 }

    private var hiddenCount: Int { max(0, meaningfulLines.count - 10) }

    private struct Line: Hashable {
        let prefix: String
        let content: String

        init(raw: String) {
            if raw.hasPrefix("@@") {
                prefix = "…"
                content = raw
            } else {
                prefix = String(raw.prefix(1))
                content = String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }

        var color: Color {
            switch prefix {
            case "+": return .green
            case "-": return .red
            default: return AppTheme.mutedText
            }
        }

        var background: Color {
            switch prefix {
            case "+": return Color.green.opacity(0.10)
            case "-": return Color.red.opacity(0.10)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasErrors ? .red : AppTheme.mutedText)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(callCountText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(displayRows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: row.icon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(row.isError ? .red : AppTheme.mutedText)
                                .frame(width: 14)
                            Text(row.title)
                                .font(.caption.weight(.semibold))
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.caption)
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
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(link.domain)
                                            .font(.caption2)
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
                                            .font(.caption2.weight(.semibold))
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
                if hiddenCount > 0 {
                    Text("\(hiddenCount) older web update\(hiddenCount == 1 ? "" : "s") hidden")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
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

    private var hiddenCount: Int {
        max(0, activities.count - displayRows.count)
    }

    private var title: String {
        let names = Set(activities.map { $0.name.lowercased() })
        if names.count == 1, let name = names.first {
            switch name {
            case "web_search": return "Web search"
            case "fetch_content": return "Fetch content"
            case "get_search_content": return "Read web content"
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
            default: return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        nonisolated private static func icon(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "magnifyingglass"
            case "fetch_content", "get_search_content": return "doc.text.magnifyingglass"
            default: return "globe"
            }
        }
    }
}

struct PiAgentActivitySummaryView: View {
    let activities: [PiAgentTranscriptActivity]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasErrors ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasErrors ? .red : AppTheme.mutedText)
            Text("Tools")
                .font(.caption.weight(.semibold))
            Text(callCountText)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activities) { activity in
                        activityChip(activity)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var hasErrors: Bool {
        activities.contains(where: \.isError)
    }

    private var callCountText: String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private func activityChip(_ activity: PiAgentTranscriptActivity) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon(for: activity.name))
                .font(.caption2.weight(.semibold))
            Text(displayName(for: activity.name, count: activity.count))
                .font(.caption)
            Text("\(activity.count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(AppTheme.contentStroke.opacity(0.55)))
        }
        .foregroundStyle(activity.isError ? .red : AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill((activity.isError ? Color.red : AppTheme.contentStroke).opacity(0.12)))
    }

    private func displayName(for name: String, count: Int) -> String {
        switch name.lowercased() {
        case "bash": return "Shell"
        case "read": return "File read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "set_session_plan": return "Plan"
        case "update_session_plan": return "Plan update"
        case "subagent": return count == 1 ? "Subagent" : "Subagents"
        case "web_search": return "Web search"
        case "fetch_content", "get_search_content": return "Web content"
        default:
            return name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func icon(for name: String) -> String {
        switch name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "set_session_plan", "update_session_plan": return "checklist"
        case "subagent": return "person.2.wave.2"
        case "web_search", "fetch_content", "get_search_content": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct PiAgentActivityDetailView: View {
    let activity: PiAgentTranscriptActivity

    var body: some View {
        if let summary = activity.subagentSummary {
            PiAgentSubagentTranscriptView(summary: summary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(activity.isError ? .red : AppTheme.mutedText)
                    Text(activity.name)
                        .font(.caption.weight(.semibold))
                    if activity.count > 1 {
                        Text("×\(activity.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer()
                }
                ForEach(activity.entries.suffix(3)) { entry in
                    PiAgentToolTranscriptView(entry: entry, startsExpanded: false)
                }
                if activity.entries.count > 3 {
                    Text("\(activity.entries.count - 3) older updates hidden")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
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

struct PiAgentStatusTranscriptRow: View {
    let entry: PiAgentTranscriptEntry
    @State private var promptPopover: PromptPopover?

    private struct PromptPopover: Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }

    var body: some View {
        if entry.title == "Compaction" {
            compactionDivider
        } else {
            compactStatusRow
                .popover(item: $promptPopover, arrowEdge: .bottom) { prompt in
                    PiAgentPromptAuditPopover(title: prompt.title, text: prompt.text)
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
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.75)).stroke(AppTheme.contentStroke, lineWidth: 1))
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var compactStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
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
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(action.help)
                .disabled(!action.isEnabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.08)).stroke(color.opacity(0.16), lineWidth: 1))
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

    private var color: Color {
        if entry.title == "Compaction" { return .secondary }
        if entry.role == .error { return .red }
        return .secondary
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
        guard let raw = entry.rawJSON,
              let data = raw.data(using: .utf8),
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

    private var subagentPromptMetadata: SubagentPromptMetadata? {
        guard let raw = entry.rawJSON,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "agent_deck_subagent_started",
              let authored = object["authoredSystemPromptPath"] as? String,
              let final = object["finalSystemPromptPath"] as? String else { return nil }
        return SubagentPromptMetadata(authoredSystemPromptPath: authored, finalSystemPromptPath: final)
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
                        .font(.headline)
                    HStack(spacing: 6) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                            Text("·")
                        }
                        Image(systemName: "tugriksign.circle")
                            .font(.caption2.weight(.semibold))
                        Text("~\(formatPromptTokens(estimatedPromptTokens(prompt)))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                }

                Spacer(minLength: 0)

                Button("View") {
                    isPromptPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $isPromptPresented, arrowEdge: .bottom) {
                    PiAgentPromptAuditPopover(title: title, text: prompt)
                }
            }
        }
    }
}

private extension PiAgentTranscriptEntry {
    var nativeSubagentRunID: UUID? {
        guard title == "Subagent Started",
              let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "agent_deck_subagent_started",
              let runID = object["runID"] as? String else { return nil }
        return UUID(uuidString: runID)
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
                    .font(.headline)
                Spacer(minLength: 0)
                AppCopyIconButton(
                    text: text,
                    help: "Copy prompt",
                    size: CGSize(width: 26, height: 26)
                )
            }

            ScrollView {
                Text(text.isEmpty ? "No prompt content captured." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(width: 720, height: 520)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.contentSubtleFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .padding(14)
    }
}

enum PiAgentTranscriptCardStyle {
    case standalone
    case question
    case threadChild
}

private struct PiAgentUserMessageContent: View {
    let entry: PiAgentTranscriptEntry
    @State private var preview: AttachmentPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !messageText.isEmpty {
                MarkdownTextView(source: messageText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !imageAttachments.isEmpty || !legacyImageNames.isEmpty || !fileAttachments.isEmpty || !folderAttachments.isEmpty {
                HStack(alignment: .top, spacing: 8) {
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
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedText)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.contentSubtleFill))
                    }
                }
            }
        }
    }

    private var messageText: String {
        let markers = ["Attached files:", "Attached images:"]
        let firstRange = markers.compactMap { entry.text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let base = firstRange.map { String(entry.text[..<$0.lowerBound]) } ?? entry.text
        return Self.removingFolderReferences(from: Self.removingFileTags(from: base)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var imageAttachments: [PiAgentImageAttachment] { images }

    private var folderAttachments: [FolderAttachmentPreview] {
        uniqueFolders(Self.folderReferences(in: entry.text).map { path in
            FolderAttachmentPreview(name: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent, path: path)
        })
    }

    private var fileAttachments: [FileAttachmentPreview] {
        let listed = attachmentLines(after: "Attached files:").compactMap { line -> FileAttachmentPreview? in
            guard !line.contains("<image ") else { return nil }
            return .init(name: line, path: nil)
        }
        let tagged = inlineFileTags.filter { !Self.isImageName($0.name) }
        // Prefer inline <file name="/path"> tags because they preserve the local path
        // needed by the popover preview. The human-readable "Attached files:"
        // list only contains display names, so de-duping it first drops previews.
        return uniqueFiles(tagged + listed)
    }

    private var legacyImageNames: [String] {
        let imageLines = attachmentLines(after: "Attached images:") + attachmentLines(after: "Attached files:").filter { $0.contains("<image ") }
        return uniqueNames(imageLines.compactMap(Self.imageName(from:)) + inlineFileTags.filter { Self.isImageName($0.name) }.map(\.name)).filter { name in
            !images.contains { $0.name == name }
        }
    }

    private func attachmentLines(after marker: String) -> [String] {
        guard let range = entry.text.range(of: marker) else { return [] }
        let tail = entry.text[range.upperBound...]
        let stop = marker == "Attached files:" ? tail.range(of: "Attached images:")?.lowerBound : nil
        let slice = stop.map { tail[..<$0] } ?? tail[...]
        return slice.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    private var inlineFileTags: [FileAttachmentPreview] {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(entry.text.startIndex..<entry.text.endIndex, in: entry.text)
        return regex.matches(in: entry.text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: entry.text) else { return nil }
            let path = String(entry.text[range])
            return .init(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
    }

    private static func imageName(from raw: String) -> String? {
        guard let range = raw.range(of: #"name=\"([^\"]+)\""#, options: .regularExpression) else { return nil }
        let match = raw[range]
        return match.replacingOccurrences(of: "name=\"", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func removingFileTags(from text: String) -> String {
        text.replacingOccurrences(of: #"<file name=\"[^\"]+\">[\s\S]*?</file>"#, with: "", options: .regularExpression)
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

    private func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func uniqueFiles(_ files: [FileAttachmentPreview]) -> [FileAttachmentPreview] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.name).inserted }
    }

    private func uniqueFolders(_ folders: [FolderAttachmentPreview]) -> [FolderAttachmentPreview] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.path).inserted }
    }

    private var images: [PiAgentImageAttachment] {
        guard let rawJSON = entry.rawJSON, let data = rawJSON.data(using: .utf8), let object = try? JSONDecoder().decode([String: [PiAgentImageAttachment]].self, from: data) else { return [] }
        return object["images"] ?? []
    }

    private var hiddenCount: Int { max(0, imageAttachments.count + legacyImageNames.count + fileAttachments.count + folderAttachments.count - 12) }

    private func attachmentChip(name: String, systemImage: String, attachment: AttachmentPreview) -> some View {
        Button { preview = attachment } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.contentSubtleFill))
        }
        .buttonStyle(.plain)
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

private enum AttachmentPreview: Identifiable, Hashable {
    case image(PiAgentImageAttachment)
    case file(FileAttachmentPreview)
    case folder(FolderAttachmentPreview)
    case missing(String)

    var id: String {
        switch self {
        case .image(let image): return "image-\(image.id.uuidString)"
        case .file(let file): return "file-\(file.id)"
        case .folder(let folder): return "folder-\(folder.id)"
        case .missing(let name): return "missing-\(name)"
        }
    }
}

private struct AttachmentPreviewPopover: View {
    let attachment: AttachmentPreview
    @State private var filePreviewPath: String?
    @State private var filePreviewText: String?
    @State private var isLoadingFilePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            previewBody
        }
        .padding(12)
        .frame(width: 420, alignment: .topLeading)
        .frame(maxHeight: 300)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.brandAccent)
            Text(title)
                .font(.headline)
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.contentSubtleFill))
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
        case .missing:
            empty("Preview is not available for older attachment metadata.")
        }
    }

    @ViewBuilder private func filePreviewBody(path: String) -> some View {
        if isLoadingFilePreview || filePreviewPath != path {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if let text = filePreviewText {
            ScrollView {
                Text(String(text.prefix(12_000)))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 240)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.contentSubtleFill))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                Text("Preview is not available for this file type.")
                Text(path)
                    .font(.caption.monospaced())
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
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path, isDirectory: true)])
            }
            .buttonStyle(.bordered)
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
        case .missing(let name): return name
        }
    }

    private var icon: String {
        switch attachment {
        case .image, .missing: return "photo"
        case .file: return "doc.text"
        case .folder: return "folder"
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
            .font(.callout)
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

struct PiAgentTranscriptCard: View {
    let entry: PiAgentTranscriptEntry
    let thinkingDisplayMode: PiAgentThinkingDisplayMode
    var style: PiAgentTranscriptCardStyle = .standalone
    var skills: [SkillRecord] = []
    @State private var isThinkingExpanded = true
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                headerIcon
                Text(headerTitle)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(headerColor)
                Spacer(minLength: 8)
                ZStack {
                    if isHovering {
                        AppCopyIconButton(
                            text: copyText,
                            help: "Copy message",
                            size: CGSize(width: 44, height: 22),
                            usesMaterialBackground: true
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.mutedText)
                            .transition(.opacity)
                    }
                }
                .frame(width: 44, height: 22)
            }

            content
        }
        .padding(.horizontal, style == .threadChild ? 12 : 14)
        .padding(.vertical, style == .threadChild ? 9 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.16), value: isHovering)
    }

    @ViewBuilder
    private var headerIcon: some View {
        if entry.role == .assistant {
            Image("pi")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let subagentSummary = PiAgentSubagentSummary(entry: entry) {
            PiAgentSubagentTranscriptView(summary: subagentSummary)
        } else if entry.role == .tool {
            PiAgentToolTranscriptView(entry: entry)
        } else if entry.role == .thinking {
            thinkingContent
        } else if entry.role == .assistant && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 10) {
                Text("Pi is thinking")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                PiAgentTypingIndicator()
            }
        } else if entry.role == .user, let skillUse = skillUse {
            VStack(alignment: .leading, spacing: 8) {
                PiAgentSkillUsePill(skill: skillUse.skill, invocation: skillUse.invocation)
                if !skillUse.remainingText.isEmpty {
                    MarkdownTextView(source: skillUse.remainingText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if entry.role == .user {
            PiAgentUserMessageContent(entry: entry)
        } else if entry.role == .assistant {
            MarkdownTextView(source: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thinkingContent: some View {
        switch thinkingDisplayMode {
        case .full:
            reasoningDisclosure(source: entry.text, defaultExpanded: true)
        case .hidden:
            Text("Thinking…")
                .font(.body.italic())
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private func reasoningDisclosure(source: String, defaultExpanded: Bool) -> some View {
        let displayText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return DisclosureGroup(isExpanded: $isThinkingExpanded) {
            MarkdownTextView(source: displayText.isEmpty ? "Pi has not emitted reasoning text yet." : displayText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Text("Reasoning")
                    .font(.caption.weight(.semibold))
            }
        }
        .onAppear {
            isThinkingExpanded = defaultExpanded
        }
    }


    private var skillUse: (skill: SkillRecord?, invocation: String, remainingText: String)? {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/skill:") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let invocationPart = parts.first else { return nil }
        let invocation = String(invocationPart)
        let name = String(invocation.dropFirst("/skill:".count))
        let skill = skills.first { $0.name == name }
        let remaining = parts.count > 1 ? String(parts[1]) : ""
        return (skill, invocation, remaining)
    }

    private var headerTitle: String {
        if entry.title == "Steering" { return "Steering" }
        switch entry.role {
        case .user: return "You"
        case .assistant: return "Pi"
        case .tool: return toolHeaderTitle
        default: return entry.title
        }
    }

    private var toolHeaderTitle: String {
        if entry.title.localizedCaseInsensitiveContains("subagent") || entry.text.localizedCaseInsensitiveContains("subagent") {
            return "Subagents"
        }
        if entry.title.hasPrefix("Tool: ") {
            return "Tool · " + entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    private var headerColor: Color {
        entry.role == .user ? AppTheme.brandAccent : .primary
    }

    private var backgroundStyle: AnyShapeStyle {
        switch entry.role {
        case .user:
            return AnyShapeStyle((style == .question ? AppTheme.brandAccent.opacity(0.10) : AppTheme.brandAccent.opacity(0.08)).gradient)
        case .assistant:
            return AnyShapeStyle(AppTheme.assistantAccent.opacity(0.06).gradient)
        case .thinking:
            return AnyShapeStyle(Color.indigo.opacity(0.07).gradient)
        case .tool:
            return AnyShapeStyle((style == .threadChild ? Color.orange.opacity(0.05) : Color.orange.opacity(0.08)).gradient)
        case .status:
            return AnyShapeStyle(AppTheme.contentSubtleFill.opacity(0.7).gradient)
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.08).gradient)
        case .stderr:
            return AnyShapeStyle(Color.pink.opacity(0.08).gradient)
        case .raw:
            return AnyShapeStyle(AppTheme.contentSubtleFill.gradient)
        }
    }

    private var strokeColor: Color {
        switch entry.role {
        case .user: return AppTheme.brandAccent.opacity(0.2)
        case .assistant: return AppTheme.assistantAccent.opacity(0.18)
        case .thinking: return Color.indigo.opacity(0.18)
        case .tool: return Color.orange.opacity(0.2)
        case .error: return Color.red.opacity(0.22)
        case .stderr: return Color.pink.opacity(0.2)
        case .status: return AppTheme.contentStroke
        case .raw: return AppTheme.contentStroke
        }
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

    private var color: Color {
        switch entry.role {
        case .user: return AppTheme.brandAccent
        case .assistant: return AppTheme.assistantAccent
        case .thinking: return .indigo
        case .tool: return .orange
        case .status: return .secondary
        case .error: return .red
        case .stderr: return .pink
        case .raw: return .secondary
        }
    }

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(toolName, systemImage: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(phaseLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                if isLong {
                    Button(isExpanded ? "Show less" : "Show details") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { isExpanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                }
            }

            Text(displayText)
                .font(.caption.monospaced())
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(isExpanded ? nil : 6)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.7)))
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
        entry.role == .error ? .red : .orange
    }
}
