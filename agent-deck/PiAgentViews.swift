import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers


let piAgentLeakedToolNames: Set<String> = ["bash", "read", "edit", "write", "find", "grep", "subagent", "web_search", "fetch_content", "get_search_content", "web_fetch"]

@MainActor
enum PiAgentRPCEventRenderCache {
    private static var cache: [String: PiAgentRPCEvent] = [:]
    private static var order: [String] = []
    private static let limit = 512

    static func event(from rawJSON: String?) -> PiAgentRPCEvent? {
        guard let rawJSON else { return nil }
        let key = cacheKey(for: rawJSON)
        if let cached = cache[key] { return cached }
        guard let data = rawJSON.data(using: .utf8),
              let event = try? JSONDecoder().decode(PiAgentRPCEvent.self, from: data) else {
            return nil
        }
        cache[key] = event
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
        return event
    }

    private static func cacheKey(for rawJSON: String) -> String {
        var hasher = Hasher()
        hasher.combine(rawJSON)
        return "\(rawJSON.count):\(hasher.finalize())"
    }
}

struct PiAgentTranscriptStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(alignment: HorizontalAlignment = .leading, spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVStack(alignment: alignment, spacing: spacing) {
            content()
        }
        .scrollTargetLayout()
    }
}

@MainActor
final class PiAgentTranscriptRenderCache: ObservableObject {
    @Published private(set) var entries: [PiAgentTranscriptEntry] = []
    @Published private(set) var threads: [PiAgentTranscriptThread] = []
    @Published private(set) var renderRevision = 0
    @Published private(set) var streamingRevision = 0
    @Published private(set) var autoScrollTurnRevision = 0
    @Published private(set) var lastThreadID: UUID?

    private var updateTask: Task<Void, Never>?
    private var lastSessionID: UUID?
    private var lastRevision = -1
    private var lastThreadSignature: [UUID] = []
    private var lastAutoScrollTurnEntryID: UUID?
    // Per-thread cached content revision keyed by a cheap signature (counts + last-entry
    // text length). Repeat lookups during the same body re-evaluation, or across unrelated
    // body re-evaluations (composer typing etc.), skip the full O(entries) walk.
    private var threadRevisionCache: [UUID: (signature: Int, revision: Int)] = [:]

    func cachedThreadRevision(for threadID: UUID, signature: Int, compute: () -> Int) -> Int {
        if let cached = threadRevisionCache[threadID], cached.signature == signature {
            return cached.revision
        }
        let revision = compute()
        threadRevisionCache[threadID] = (signature, revision)
        return revision
    }

    func scheduleUpdate(sessionID: UUID?, revision: Int, rawEntries: [PiAgentTranscriptEntry]) {
        guard let sessionID else {
            updateTask?.cancel()
            entries = []
            threads = []
            lastThreadID = nil
            lastSessionID = nil
            lastRevision = -1
            lastThreadSignature = []
            lastAutoScrollTurnEntryID = nil
            threadRevisionCache.removeAll()
            renderRevision += 1
            return
        }
        guard sessionID != lastSessionID || revision != lastRevision else { return }
        let isSessionSwitch = sessionID != lastSessionID
        // Don't wipe threadRevisionCache on session switch — keys are per-thread UUIDs
        // which are globally unique, so cached revisions for a different session can't
        // collide. Persisting the cache means a return-visit to a previously-viewed
        // session reuses its thread revisions instead of re-hashing every entry.
        lastSessionID = sessionID
        lastRevision = revision
        updateTask?.cancel()

        if isSessionSwitch {
            publish(rawEntries)
            return
        }

        updateTask = Task { [weak self] in
            // Lowered from 66 ms (the previous safety value when each publish triggered
            // an expensive SwiftUI body rebuild) to 33 ms. With TextKit-based markdown
            // measurement and in-place NSTextStorage updates, each publish is cheap;
            // halving the coalesce window means streaming feels like smooth scroll
            // instead of discrete 66 ms steps.
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            self?.publish(rawEntries)
        }
    }

    private func publish(_ rawEntries: [PiAgentTranscriptEntry]) {
        let normalized = normalizeThinkingOrder(
            coalescedCompactionEntries(
                rawEntries.compactMap(normalizedTranscriptEntry).filter(isValuableTranscriptEntry)
            )
        )
        let nextThreads = PiAgentTranscriptThread.make(from: normalized)
        let signature = nextThreads.map(\.id)
        let structurallyChanged = signature != lastThreadSignature
        let latestUserEntryID = normalized.last(where: { $0.role == .user })?.id
        let userTurnAdvanced = latestUserEntryID != nil && latestUserEntryID != lastAutoScrollTurnEntryID
        if structurallyChanged {
            let nextThreadIDs = Set(signature)
            threadRevisionCache = threadRevisionCache.filter { nextThreadIDs.contains($0.key) }
        }
        entries = normalized
        threads = nextThreads
        lastThreadID = nextThreads.last?.id
        lastThreadSignature = signature
        lastAutoScrollTurnEntryID = latestUserEntryID
        if userTurnAdvanced {
            autoScrollTurnRevision += 1
        }
        if structurallyChanged {
            renderRevision += 1
        } else {
            streamingRevision += 1
        }
    }

    private enum AssistantContentInterpretation {
        case assistant(String)
        case thinking(String)
        case drop
    }

    private func normalizedTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry? {
        var copy = entry
        if copy.role == .assistant {
            if let interpretation = assistantContentInterpretation(fromRawJSON: copy.rawJSON) {
                switch interpretation {
                case let .assistant(text):
                    copy.text = sanitizedAssistantText(text)
                case let .thinking(text):
                    copy.role = .thinking
                    copy.title = "Thinking"
                    copy.text = sanitizedAssistantText(text)
                case .drop:
                    return nil
                }
            } else {
                copy.text = sanitizedAssistantText(copy.text)
            }
            if copy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
        }
        return copy
    }

    private func assistantContentInterpretation(fromRawJSON rawJSON: String?) -> AssistantContentInterpretation? {
        guard let event = PiAgentRPCEventRenderCache.event(from: rawJSON),
              event.type == "message_end",
              let message = event.message,
              message["role"]?.stringValue == "assistant",
              let content = message["content"] else {
            return nil
        }

        switch content {
        case let .string(value):
            return .assistant(value)
        case let .array(blocks):
            let textParts = blocks.compactMap { block -> String? in
                let blockType = block["type"]?.stringValue
                guard blockType == nil || blockType == "text" || blockType == "output_text" || blockType == "message" else { return nil }
                return block["text"]?.stringValue
            }
            if !textParts.isEmpty { return .assistant(textParts.joined(separator: "\n")) }

            let thinkingParts = blocks.compactMap { block -> String? in
                guard block["type"]?.stringValue == "thinking" else { return nil }
                return block["thinking"]?.stringValue
            }
            if !thinkingParts.isEmpty { return .thinking(thinkingParts.joined(separator: "\n\n")) }

            let hasToolCall = blocks.contains { block in
                let blockType = block["type"]?.stringValue
                return blockType == "toolCall" || blockType == "tool_call" || block["name"]?.stringValue != nil
            }
            return hasToolCall ? .drop : nil
        default:
            return .drop
        }
    }

    private func sanitizedAssistantText(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !piAgentLeakedToolNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func coalescedCompactionEntries(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        var output: [PiAgentTranscriptEntry] = []
        for entry in entries {
            guard entry.role == .status && entry.title == "Compaction" else {
                output.append(entry)
                continue
            }
            if let last = output.last,
               last.role == .status,
               last.title == "Compaction",
               abs(entry.timestamp.timeIntervalSince(last.timestamp)) < 600 {
                output[output.count - 1] = entry
            } else {
                output.append(entry)
            }
        }
        return output
    }

    private func normalizeThinkingOrder(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        var normalized: [PiAgentTranscriptEntry] = []
        for entry in entries {
            if entry.role == .thinking,
               let previous = normalized.last,
               previous.role == .assistant,
               abs(entry.timestamp.timeIntervalSince(previous.timestamp)) < 180 {
                normalized.removeLast()
                normalized.append(entry)
                normalized.append(previous)
            } else {
                normalized.append(entry)
            }
        }
        return normalized
    }

    private func isValuableTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        switch entry.role {
        case .raw:
            return false
        case .assistant:
            return isMeaningfulAssistantEntry(entry)
        case .status:
            return entry.isNativeSubagentCard
                || entry.title == "Compaction"
                || entry.title == "Retry"
                || entry.title == "Subagent Started"
        case .tool:
            return !(entry.title == "Tool Call" && entry.text.localizedCaseInsensitiveContains("preparing tool call"))
        case .stderr:
            return !entry.text.localizedCaseInsensitiveContains("ready for input") && !entry.text.contains(";notify;Pi;")
        default:
            return true
        }
    }

    private func isMeaningfulAssistantEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return !piAgentLeakedToolNames.contains(text.lowercased())
    }
}

private extension PiAgentTranscriptEntry {
    var isNativeSubagentCard: Bool {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return false }
        return type == "agent_deck_subagent_started" || type == "agent_deck_subagent_card"
    }
}

private struct PiAgentTranscriptTimelineItem: Identifiable {
    enum Kind {
        case thread(PiAgentTranscriptThread)
        case plan(PiSessionPlanEventRecord)
    }

    let id: String
    let timestamp: Date
    let kind: Kind
}

private struct PiAgentTranscriptTimelineSnapshot {
    let allItems: [PiAgentTranscriptTimelineItem]
    let visibleItems: [PiAgentTranscriptTimelineItem]
    let mainVisibleItems: [PiAgentTranscriptTimelineItem]
    let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
    let preCompactionArchive: (hiddenCount: Int, compactedAt: Date)?
    let recentWindowArchive: (hiddenCount: Int, limit: Int)?
    let planEventsByThreadID: [UUID: [PiSessionPlanEventRecord]]
}

private struct PiAgentAppKitTranscriptItem {
    let id: String
    let view: AnyView
    let contentRevision: Int
    /// Fast height estimate used by `heightOfRow` before the cell renders.
    /// Closer estimates produce smoother first paint — the cell self-measures
    /// after it renders and reports its actual height back via callback.
    let estimatedHeight: (CGFloat) -> CGFloat

    init(
        id: String,
        view: AnyView,
        contentRevision: Int = 0,
        estimatedHeight: @escaping (CGFloat) -> CGFloat = { _ in 120 }
    ) {
        self.id = id
        self.view = view
        self.contentRevision = contentRevision
        self.estimatedHeight = estimatedHeight
    }
}

private enum PiAgentTranscriptTableSection: Hashable {
    case main
}

private struct PiAgentAppKitTranscriptView: NSViewRepresentable {
    let items: [PiAgentAppKitTranscriptItem]
    let sessionID: UUID?
    let renderRevision: Int
    let streamingRevision: Int
    let autoScrollTurnRevision: Int
    let bottomScrollRequest: Int
    let onPinnedToBottomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPinnedToBottomChange: onPinnedToBottomChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 12)
        tableView.rowHeight = 120
        tableView.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TranscriptColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true

        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.setupDataSource(for: tableView)
        context.coordinator.setupScrollObservation(scrollView)
        context.coordinator.updateColumnWidthIfNeeded()
        context.coordinator.apply(
            items: items,
            sessionID: sessionID,
            renderRevision: renderRevision,
            streamingRevision: streamingRevision,
            autoScrollTurnRevision: autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPinnedToBottomChange = onPinnedToBottomChange
        coordinator.updateColumnWidthIfNeeded()
        coordinator.apply(
            items: items,
            sessionID: sessionID,
            renderRevision: renderRevision,
            streamingRevision: streamingRevision,
            autoScrollTurnRevision: autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {
        weak var scrollView: NSScrollView?
        weak var tableView: NSTableView?
        private var dataSource: NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>?

        var sessionID: UUID?
        var lastRenderRevision = -1
        var lastStreamingRevision = -1
        var lastAutoScrollTurnRevision = -1
        var lastBottomScrollRequest = -1
        var onPinnedToBottomChange: (Bool) -> Void

        private var items: [PiAgentAppKitTranscriptItem] = []
        private var itemByID: [String: PiAgentAppKitTranscriptItem] = [:]
        private var orderedIDs: [String] = []
        private var contentRevisionByID: [String: Int] = [:]
        // Heights are populated by two paths:
        //  1. `heightOfRow` returns the item's estimator (cached) when there's no measurement.
        //  2. The cell measures itself after configure() and reports back via `reportMeasuredHeight`.
        // The table re-queries heightOfRow only when `noteHeightOfRows` is called, which we
        // do (debounced ~16ms) when a reported height differs from the cache.
        private var heightByID: [String: CGFloat] = [:]
        private var pendingHeightIDs = Set<String>()
        private var pendingHeightWork: DispatchWorkItem?
        private var pendingScrollWork: DispatchWorkItem?
        private var pendingSettleScrollWork: DispatchWorkItem?
        private var pendingRemeasureWork: DispatchWorkItem?
        private var pendingScrollSettle = false
        private var pendingWidthWork: DispatchWorkItem?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var lastPinnedState = true
        private var isProgrammaticScroll = false
        private var contentWidth: CGFloat = 0
        private let estimatedRowHeight: CGFloat = 120
        private let heightChangeEpsilon: CGFloat = 0.5
        // One-frame debounce so a burst of cell measurements during a single
        // layout pass coalesces into one noteHeightOfRows call.
        private let heightReportInterval: TimeInterval = 0.016

        private struct ScrollAnchor {
            let id: String
            let offsetFromRowTop: CGFloat
        }

        init(onPinnedToBottomChange: @escaping (Bool) -> Void) {
            self.onPinnedToBottomChange = onPinnedToBottomChange
        }

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>(tableView: tableView) { [weak self] tableView, _, row, id in
                guard let self, let item = self.itemByID[id] else { return NSView() }
                let cell = (tableView.makeView(withIdentifier: TranscriptTableCellView.reuseIdentifier, owner: nil) as? TranscriptTableCellView)
                    ?? TranscriptTableCellView(frame: .zero)
                cell.identifier = TranscriptTableCellView.reuseIdentifier
                cell.onHeightChanged = { [weak self] itemID, height in
                    self?.reportMeasuredHeight(height, forItemID: itemID)
                }
                self.configure(cell, with: item, row: row)
                return cell
            }
            tableView.delegate = self
        }

        func setupScrollObservation(_ scrollView: NSScrollView) {
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView = self.scrollView else { return }
                    if !self.isProgrammaticScroll {
                        self.pendingScrollWork?.cancel()
                        self.pendingScrollWork = nil
                        self.pendingSettleScrollWork?.cancel()
                        self.pendingSettleScrollWork = nil
                        self.pendingScrollSettle = false
                    }
                    self.publishPinnedState(self.isPinnedToBottom(scrollView))
                }
            }

            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateColumnWidthIfNeeded()
                }
            }
        }

        func invalidate() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            pendingHeightWork?.cancel()
            pendingScrollWork?.cancel()
            pendingSettleScrollWork?.cancel()
            pendingRemeasureWork?.cancel()
            pendingWidthWork?.cancel()
        }

        func apply(
            items: [PiAgentAppKitTranscriptItem],
            sessionID: UUID?,
            renderRevision: Int,
            streamingRevision: Int,
            autoScrollTurnRevision: Int,
            bottomScrollRequest: Int
        ) {
            guard let tableView, let scrollView else { return }
            let wasPinned = isPinnedToBottom(scrollView)
            let isSessionSwitch = self.sessionID != sessionID
            let structuralUpdate = lastRenderRevision != renderRevision
            let streamingUpdate = lastStreamingRevision != streamingRevision
            let explicitScroll = lastAutoScrollTurnRevision != autoScrollTurnRevision || lastBottomScrollRequest != bottomScrollRequest

            self.items = items
            itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let nextIDs = items.map(\.id)
            let nextRevisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.contentRevision) })
            let idsChanged = nextIDs != orderedIDs

            if isSessionSwitch || idsChanged {
                let anchor = (!isSessionSwitch && !explicitScroll && !wasPinned) ? captureScrollAnchor() : nil
                if isSessionSwitch {
                    pendingHeightIDs.removeAll()
                    pendingHeightWork?.cancel()
                    pendingHeightWork = nil
                }
                let previousIDs = Set(orderedIDs)
                let removedIDs = previousIDs.subtracting(nextIDs)
                for id in removedIDs {
                    heightByID.removeValue(forKey: id)
                    contentRevisionByID.removeValue(forKey: id)
                    pendingHeightIDs.remove(id)
                }
                // Existing rows whose contentRevision changed need their cached heights
                // invalidated — heightOfRow will fall back to the item's estimator until
                // the cell re-measures and reports back. This is what eliminates the
                // overlap: the table never has to use a stale height because it always
                // queries the estimator (close enough) or the freshly-reported value.
                for id in nextIDs {
                    if contentRevisionByID[id] != nil, contentRevisionByID[id] != nextRevisions[id] {
                        heightByID.removeValue(forKey: id)
                    }
                }
                orderedIDs = nextIDs
                contentRevisionByID = nextRevisions
                applySnapshot(ids: nextIDs) { [weak self] in
                    guard let self else { return }
                    // Visible cells whose content changed (same id, new revision) are NOT
                    // reconfigured automatically by the diffable data source — it only
                    // touches cells whose ids changed. Walk the visible window and
                    // reconfigure those whose item revision has shifted.
                    self.reconfigureChangedVisibleCells()
                    self.restoreScrollAnchorIfNeeded(anchor)
                    self.handleScrollAfterUpdate(isSessionSwitch: isSessionSwitch, explicitScroll: explicitScroll, wasPinned: wasPinned)
                }
            } else {
                let changedIDs = nextIDs.filter { contentRevisionByID[$0] != nextRevisions[$0] }
                contentRevisionByID = nextRevisions
                if !changedIDs.isEmpty {
                    for id in changedIDs { heightByID.removeValue(forKey: id) }
                    reconfigureVisibleCellsForIDs(Set(changedIDs))
                } else if streamingUpdate || structuralUpdate {
                    publishPinnedState(isPinnedToBottom(scrollView))
                }
                handleScrollAfterUpdate(isSessionSwitch: false, explicitScroll: explicitScroll, wasPinned: wasPinned)
            }

            self.sessionID = sessionID
            lastRenderRevision = renderRevision
            lastStreamingRevision = streamingRevision
            lastAutoScrollTurnRevision = autoScrollTurnRevision
            lastBottomScrollRequest = bottomScrollRequest
            tableView.sizeLastColumnToFit()
        }

        private func applySnapshot(ids: [String], completion: @escaping () -> Void) {
            var snapshot = NSDiffableDataSourceSnapshot<PiAgentTranscriptTableSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(ids, toSection: .main)
            dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
        }

        func updateColumnWidthIfNeeded() {
            guard let scrollView, let tableView else { return }
            let width = max(200, scrollView.contentView.bounds.width)
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            tableView.tableColumns.first?.width = width

            // Heights are width-specific. Wipe the cache so heightOfRow falls back to the
            // item estimator until cells re-measure for the new width.
            heightByID.removeAll()

            pendingWidthWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingWidthWork = nil
                self.reconfigureAllVisibleCells()
            }
            pendingWidthWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        /// Walk visible rows and reconfigure cells whose content has changed since
        /// they were last configured. Used after a snapshot apply (diffable data
        /// source only reconfigures rows whose ids changed).
        private func reconfigureChangedVisibleCells() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                // configure() is a no-op when nothing's changed; otherwise the cell
                // measures itself and reports a new height via onHeightChanged.
                configure(cell, with: item, row: row)
            }
        }

        private func reconfigureVisibleCellsForIDs(_ ids: Set<String>) {
            guard let tableView, !ids.isEmpty else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard ids.contains(id),
                      let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                configure(cell, with: item, row: row)
            }
        }

        private func reconfigureAllVisibleCells() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                heightByID.removeValue(forKey: id)
                configure(cell, with: item, row: row)
            }
        }

        private func configure(_ cell: TranscriptTableCellView, with item: PiAgentAppKitTranscriptItem, row: Int) {
            let width = max(contentWidth, tableView?.tableColumns.first?.width ?? 200)
            // The cell self-measures inside configure() and calls onHeightChanged
            // with its natural height. We don't need to call measure() manually.
            cell.configure(item: item, width: width)
        }

        /// Called by a cell after it has measured its natural height. Updates the
        /// cache and (debounced) tells the table to re-tile the changed row.
        func reportMeasuredHeight(_ height: CGFloat, forItemID itemID: String) {
            let existing = heightByID[itemID]
            heightByID[itemID] = height
            let delta = abs((existing ?? estimatedRowHeight) - height)
            guard delta > heightChangeEpsilon else { return }
            pendingHeightIDs.insert(itemID)
            guard pendingHeightWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let ids = self.pendingHeightIDs
                self.pendingHeightIDs.removeAll()
                self.pendingHeightWork = nil
                self.noteHeightsChanged(forIDs: ids)
            }
            pendingHeightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + heightReportInterval, execute: work)
        }

        private func noteHeightsChanged(forIDs ids: Set<String>) {
            guard let tableView, let scrollView, !ids.isEmpty else { return }
            let wasPinned = isPinnedToBottom(scrollView)
            var rows = IndexSet()
            for id in ids {
                if let row = orderedIDs.firstIndex(of: id), row < tableView.numberOfRows {
                    rows.insert(row)
                }
            }
            guard !rows.isEmpty else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            NSAnimationContext.endGrouping()
            if wasPinned {
                scrollToBottom(settle: false)
            }
        }

        private func flushPendingHeightWorkSynchronously() {
            guard let work = pendingHeightWork else { return }
            work.cancel()
            pendingHeightWork = nil
            let ids = pendingHeightIDs
            pendingHeightIDs.removeAll()
            noteHeightsChanged(forIDs: ids)
        }

        private func captureScrollAnchor() -> ScrollAnchor? {
            guard let tableView, let scrollView else { return nil }
            let originY = scrollView.contentView.bounds.origin.y
            let row = tableView.row(at: NSPoint(x: 0, y: originY))
            guard row >= 0, row < orderedIDs.count else { return nil }
            let rowRect = tableView.rect(ofRow: row)
            return ScrollAnchor(id: orderedIDs[row], offsetFromRowTop: originY - rowRect.minY)
        }

        private func restoreScrollAnchorIfNeeded(_ anchor: ScrollAnchor?) {
            guard let anchor, let tableView, let scrollView,
                  let row = orderedIDs.firstIndex(of: anchor.id),
                  row >= 0, row < tableView.numberOfRows,
                  let documentView = scrollView.documentView else { return }
            let rowRect = tableView.rect(ofRow: row)
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let targetY = min(max(0, rowRect.minY + anchor.offsetFromRowTop), maxY)
            guard abs(scrollView.contentView.bounds.origin.y - targetY) > 1 else { return }
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
        }

        private func handleScrollAfterUpdate(isSessionSwitch: Bool, explicitScroll: Bool, wasPinned: Bool) {
            guard let scrollView else { return }
            if isSessionSwitch || explicitScroll {
                scrollToBottom(settle: true)
            } else if wasPinned {
                scrollToBottom(settle: false)
            } else {
                publishPinnedState(isPinnedToBottom(scrollView))
            }
        }

        private func scrollToBottom(settle: Bool) {
            pendingScrollSettle = pendingScrollSettle || settle
            guard pendingScrollWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                let shouldSettle = self.pendingScrollSettle
                self.pendingScrollWork = nil
                self.pendingScrollSettle = false
                self.performScrollToBottom(scrollView)
                guard shouldSettle else { return }
                self.pendingSettleScrollWork?.cancel()
                let settleWork = DispatchWorkItem { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    self.pendingSettleScrollWork = nil
                    // Don't force a re-measure here — pre-measurement and the synchronous
                    // height-work flush inside performScrollToBottom mean heights are already
                    // accurate. Re-measuring would risk a small secondary scroll jump.
                    self.performScrollToBottom(scrollView)
                }
                self.pendingSettleScrollWork = settleWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settleWork)
            }
            pendingScrollWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func performScrollToBottom(_ scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            // Flush any debounced height work and force a layout pass so the documentView's
            // bounds reflect current row heights. Without this, the math below uses stale
            // heights and ends up scrolling short of the true bottom — which crops the last
            // assistant message during streaming.
            flushPendingHeightWorkSynchronously()
            documentView.layoutSubtreeIfNeeded()
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let clipView = scrollView.contentView
            guard abs(clipView.bounds.origin.y - maxY) > 1 else {
                publishPinnedState(true)
                return
            }
            isProgrammaticScroll = true
            clipView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clipView)
            isProgrammaticScroll = false
            publishPinnedState(true)
        }

        private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            return maxY - scrollView.contentView.bounds.origin.y < 80
        }

        private func publishPinnedState(_ pinned: Bool) {
            guard pinned != lastPinnedState else { return }
            lastPinnedState = pinned
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
                self?.onPinnedToBottomChange(pinned)
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            TranscriptTableRowView()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < orderedIDs.count else { return estimatedRowHeight }
            let id = orderedIDs[row]
            if let cached = heightByID[id] { return cached }
            // No measurement yet — use the item's fast estimator so the table can lay
            // the row out close to its natural size without triggering a SwiftUI pass.
            // The cell will measure precisely as it renders and report back via
            // reportMeasuredHeight, at which point this row gets re-tiled.
            if let item = itemByID[id] {
                let est = item.estimatedHeight(contentWidth)
                heightByID[id] = est
                return est
            }
            return estimatedRowHeight
        }
    }

    final class TranscriptTableRowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { false }
            set { }
        }

        override func drawSelection(in dirtyRect: NSRect) { }
        override func drawBackground(in dirtyRect: NSRect) { }
    }

    final class TranscriptTableCellView: NSTableCellView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("PiAgentTranscriptTableCell")
        private var hostingView: NSHostingView<AnyView>?
        private var configuredItemID: String?
        private var configuredRevision: Int?
        private var configuredWidth: CGFloat = 0
        private var lastReportedHeight: CGFloat = -1
        // Re-entry guard. reportNaturalHeightIfChanged mutates the cell's frame, which
        // can trigger another `layout()` pass; without this flag the measurement
        // would recurse and saturate the runloop.
        private var isMeasuring = false

        /// Callback the cell invokes after measuring its natural height. Wired by
        /// the Coordinator at cell-vend time. Posts `(itemID, height)` so the
        /// coordinator can update its height cache and tell the table to re-tile.
        var onHeightChanged: ((String, CGFloat) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        @discardableResult
        func configure(item: PiAgentAppKitTranscriptItem, width: CGFloat) -> Bool {
            let widthChanged = abs(configuredWidth - width) > 0.5
            let itemChanged = configuredItemID != item.id
            let revisionChanged = configuredRevision != item.contentRevision
            guard itemChanged || revisionChanged || widthChanged else { return false }

            // Reset the reported-height tracker if the *item* changed — when the cell
            // is reused for a new row, the previous lastReportedHeight is meaningless
            // and would suppress the new row's first measurement.
            if itemChanged { lastReportedHeight = -1 }

            configuredItemID = item.id
            configuredRevision = item.contentRevision
            configuredWidth = width

            let root = AnyView(item.view.frame(width: width, alignment: .topLeading))
            if let hostingView {
                hostingView.rootView = root
            } else {
                let hostingView = NSHostingView(rootView: root)
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
                hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                addSubview(hostingView)
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                    hostingView.topAnchor.constraint(equalTo: topAnchor),
                    hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
                self.hostingView = hostingView
            }
            reportNaturalHeightIfChanged(width: width, itemID: item.id)
            return true
        }

        /// Called after every Auto Layout pass on the hosted content (image loads,
        /// markdown TextKit measurement settling, etc.). Re-measures in case the
        /// natural size has changed for a reason other than revision turnover.
        override func layout() {
            super.layout()
            guard !isMeasuring, let itemID = configuredItemID, configuredWidth > 1 else { return }
            reportNaturalHeightIfChanged(width: configuredWidth, itemID: itemID)
        }

        private func reportNaturalHeightIfChanged(width: CGFloat, itemID: String) {
            guard !isMeasuring, let hostingView, width > 1 else { return }
            isMeasuring = true
            defer { isMeasuring = false }
            // Use a measurement frame tall enough that SwiftUI's required-bottom
            // constraint doesn't compress the content into a truncated fittingSize.
            // We restore the frame before returning so the cell never paints at the
            // inflated height — NSTableView's actual frame is reapplied immediately
            // after the synchronous measurement.
            let originalFrame = frame
            let measuringFrame = CGRect(x: 0, y: 0, width: width, height: 100_000)
            if frame != measuringFrame { frame = measuringFrame }
            hostingView.invalidateIntrinsicContentSize()
            layoutSubtreeIfNeeded()
            let natural = hostingView.fittingSize.height
            if frame != originalFrame { frame = originalFrame }
            guard natural.isFinite, natural > 0 else { return }
            let rounded = ceil(natural)
            if abs(rounded - lastReportedHeight) > 0.5 {
                lastReportedHeight = rounded
                onHeightChanged?(itemID, rounded)
            }
        }
    }
}

private extension PiAgentTranscriptThread {
    var timelineTimestamp: Date {
        let activityEntries = activities.compactMap(\.representativeEntry)
        let candidates = [question].compactMap { $0 }
            + steeringMessages
            + thinkingParts
            + assistantMessages
            + activityEntries
            + statuses
            + errors
        return candidates.map(\.timestamp).min() ?? .distantPast
    }
}

struct PiAgentScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @Binding var sessionSearchText: String
    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var selectedSessionTitleDraft = ""
    @State private var renamingSessionID: UUID?
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var lastSelectedSessionID: UUID?
    @State private var pendingDeleteSessionIDs: Set<UUID> = []
    @State private var pendingDeleteIsClearAll = false
    @State private var pendingDeleteClearAllProjects = false
    @State private var pendingDeleteProjectName: String?
    @State private var isDeleteSessionsAlertPresented = false
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var composerHistoryIndex: Int?
    @State private var composerHistoryDraft = ""
    @State private var selectedSubagentTranscriptRunID: UUID?
    @State private var selectedSubagentGraphRunID: UUID?
    @StateObject private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var transcriptBottomScrollRequest = 0
    @State private var transcriptIsPinnedToBottom = true
    @State private var startupResourcesLayoutRevision = 0
    @State private var showArchivedPreCompactionTranscript = false
    @State private var isEarlierTranscriptSheetPresented = false
    @State private var cachedVisibleSessions: [PiAgentSessionRecord] = []
    @State private var hasBuiltVisibleSessions = false
    @State private var isUIRequestSheetPresented = false
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?
    @State private var stabilizedProcessingMessage: String?
    @State private var processingMessageUpdateTask: Task<Void, Never>?

    // Keep long sessions cheap to relayout when side panels open; older visible items remain accessible separately.
    private let recentTranscriptTimelineItemLimit = 50

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                sessionsColumn
                    .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)

                activeSessionColumn
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            syncRuntimeFooterSnapshot()
            syncSelectedSessionTitleDraft()
            isUIRequestSheetPresented = store.selectedUIRequest != nil
            rebuildVisibleSessions()
            resetTranscriptAutoScroll()
            // Kick the load synchronously on appear so `isSelectedTranscriptLoading`
            // flips to true before the first render — otherwise the transcript area
            // is briefly blank (no loading card, no content) until the deferred task
            // runs after Task.yield.
            store.requestSelectedTranscriptLoad()
            requestSelectedTranscriptLoadAfterViewUpdate()
            updateStabilizedProcessingMessage(selectedSessionProcessingMessage)
            Task { @MainActor in
                await Task.yield()
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
                scheduleTranscriptCacheUpdate()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onReceive(store.$sessions) { _ in rebuildVisibleSessions() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessions() }
        .onDisappear {
            processingMessageUpdateTask?.cancel()
            processingMessageUpdateTask = nil
        }
        .sheet(isPresented: uiRequestSheetBinding) {
            if let request = store.selectedUIRequest {
                PiAgentUIRequestSheet(
                    request: request,
                    onSubmitValue: { value in viewModel.respondToPiAgentUIRequest(request, value: value) },
                    onSubmitFreeform: { sentinel, value in viewModel.respondToPiAgentFreeformUIRequest(request, sentinel: sentinel, value: value) },
                    onConfirm: { confirmed in viewModel.confirmPiAgentUIRequest(request, confirmed: confirmed) },
                    onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                )
            }
        }
        .onChange(of: store.selectedUIRequest?.id) { _, newID in
            isUIRequestSheetPresented = newID != nil
        }
        .onChange(of: store.selectedSession?.id) { oldID, newID in
            renamingSessionID = nil
            syncSelectedSessionTitleDraft()
            if let newID, !selectedSessionIDs.contains(newID) {
                syncMultiSelectionToSelectedSession()
            } else if newID == nil {
                selectedSessionIDs = []
                lastSelectedSessionID = nil
            }
            resetTranscriptAutoScroll()
            showArchivedPreCompactionTranscript = false
            isEarlierTranscriptSheetPresented = false
            syncRuntimeFooterSnapshot()
            requestSelectedTranscriptLoadAfterViewUpdate()
            Task { @MainActor in
                await Task.yield()
                scheduleTranscriptCacheUpdate()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
        .onChange(of: store.selectedSession?.title) { _, _ in syncSelectedSessionTitleDraft() }
        .onChange(of: visibleSessionIDs) { _, _ in
            syncVisibleSessionSelection()
            pruneMultiSelectionToVisibleSessions()
        }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            rebuildVisibleSessions()
            syncVisibleSessionSelection()
            Task { @MainActor in
                await Task.yield()
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
            }
        }
        .task(id: store.selectedTranscriptRevision) {
            await Task.yield()
            scheduleTranscriptCacheUpdate()
        }
        .sheet(item: selectedSubagentTranscriptBinding) { run in
            PiNativeSubagentTranscriptSheet(
                run: run,
                entries: store.cachedSubagentTranscript(for: run.id),
                visibility: viewModel.appSettings.piAgentTranscriptVisibility
            )
            .onAppear {
                requestSubagentTranscriptLoadAfterViewUpdate(runID: run.id)
            }
        }
        .sheet(isPresented: $isEarlierTranscriptSheetPresented) {
            earlierTranscriptSheet
        }
        .sheet(item: selectedSubagentGraphBinding) { run in
            PiNativeSubagentGraphSheet(
                run: run,
                onStopGraph: { viewModel.stopNativeSubagentGraph(runID: run.id, parentSessionID: run.parentSessionID) },
                onStopChild: { child in viewModel.stopNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onRetryChild: { child in viewModel.retryNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onOpenChildArtifacts: { child in if let path = child.artifactDirectory { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            )
        }
        .alert(deleteSessionsAlertTitle, isPresented: $isDeleteSessionsAlertPresented) {
            Button(pendingDeleteIsClearAll ? "Clear" : "Delete", role: .destructive, action: deletePendingSessions)
            Button("Cancel", role: .cancel) {
                resetPendingSessionDelete()
            }
        } message: {
            Text(deleteSessionsAlertMessage)
        }
    }

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var sessionScopePath: String? {
        viewModel.selectedProjectPath
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        guard let sessionScopePath else { return store.sessions }
        return store.sessions.filter { $0.projectPath == sessionScopePath }
    }

    private var visibleSessions: [PiAgentSessionRecord] {
        hasBuiltVisibleSessions ? cachedVisibleSessions : computedVisibleSessions()
    }

    private func rebuildVisibleSessions() {
        cachedVisibleSessions = computedVisibleSessions()
        hasBuiltVisibleSessions = true
    }

    private func computedVisibleSessions() -> [PiAgentSessionRecord] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = viewModel.showPiAgentAttentionOnly ? scopedSessions.filter(\.needsAttention) : scopedSessions
        let filtered = query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
        return sortedSessions(filtered)
    }

    private var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    private var deleteSessionsAlertTitle: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects { return "Clear all Pi Agent sessions?" }
            let projectName = pendingDeleteProjectName ?? "this project"
            return "Clear Pi Agent sessions for \(projectName)?"
        }
        return pendingDeleteSessionIDs.count == 1 ? "Delete Pi Agent session?" : "Delete \(pendingDeleteSessionIDs.count) Pi Agent sessions?"
    }

    private var deleteSessionsAlertMessage: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects {
                return "This removes all Pi Agent sessions and their local transcripts for every project from \(AppBrand.displayName)."
            }
            let projectName = pendingDeleteProjectName ?? "the current project"
            return "This removes all Pi Agent sessions and their local transcripts for \(projectName) from \(AppBrand.displayName). Other projects are not affected."
        }
        return pendingDeleteSessionIDs.count == 1
            ? "This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName)."
            : "This removes the selected Pi Agent sessions and their local transcripts from \(AppBrand.displayName)."
    }

    private var sessionDeleteTargets: Set<UUID> {
        if !selectedSessionIDs.isEmpty {
            return selectedSessionIDs
        }
        if let selectedID = store.selectedSession?.id {
            return [selectedID]
        }
        return []
    }

    private var uiRequestSheetBinding: Binding<Bool> {
        Binding(
            get: { isUIRequestSheetPresented && store.selectedUIRequest != nil },
            set: { isPresented in
                if isPresented {
                    isUIRequestSheetPresented = true
                } else {
                    isUIRequestSheetPresented = false
                }
            }
        )
    }


    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Sessions")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer()
                    if selectedSessionIDs.count > 1 {
                        Button(role: .destructive) {
                            requestDeleteSessions(selectedSessionIDs)
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.red)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.red.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Delete selected sessions")
                        .accessibilityLabel("Delete selected sessions")
                    }
                    if !scopedSessions.isEmpty {
                        Button(role: .destructive) {
                            requestDeleteSessions(Set(scopedSessions.map(\.id)), isClearAll: true)
                        } label: {
                            Image(systemName: "eraser")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.red.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.red)
                        .help(viewModel.selectedProjectPath == nil ? "Clear all sessions and transcripts" : "Clear sessions and transcripts for this project")
                        .accessibilityLabel(viewModel.selectedProjectPath == nil ? "Clear all sessions and transcripts" : "Clear sessions and transcripts for this project")
                    }
                    if viewModel.selectedDiscoveredProject == nil {
                        PiAgentAddSessionMenuButton(
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            action: { viewModel.createPiAgentDraftForSelectedProject() }
                        ) { project in
                            viewModel.createPiAgentDraft(for: project)
                        }
                        .help(piAgentNewSessionProjects.isEmpty ? "New projectless Pi Agent session" : "Choose a project for the new Pi Agent session")
                    } else {
                        PiAgentAddSessionButton {
                            viewModel.createPiAgentDraftForSelectedProject()
                        }
                        .help(viewModel.selectedDiscoveredProject == nil ? "New projectless Pi Agent session" : "New Pi Agent session")
                    }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 18)

            if scopedSessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image("pi")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                    Text("No sessions yet")
                        .font(.headline)
                    Text(emptySessionsMessage)
                        .foregroundStyle(AppTheme.mutedText)
                }
                .padding(18)
                Spacer()
            } else {
                VStack(spacing: 10) {
                    if visibleSessions.isEmpty {
                        ContentUnavailableView("No sessions found", systemImage: "magnifyingglass", description: Text("Try another search."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selectedSessionIDs) {
                            ForEach(visibleSessions) { session in
                                sessionListRow(session)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .animation(.snappy(duration: 0.24), value: visibleSessionIDs)
                    }
                }
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func sessionListRow(_ session: PiAgentSessionRecord) -> some View {
        let isWorking = viewModel.piAgentSessionIsWorking(session)

        PiAgentSessionRow(
            session: session,
            project: viewModel.discoveredProjects.first(where: { $0.path == session.projectPath }),
            isSelected: selectedSessionIDs.contains(session.id),
            isRunning: isWorking,
            isRenaming: renamingSessionID == session.id,
            isGeneratingTitle: viewModel.piAgentTitleGeneratingSessionIDs.contains(session.id),
            onSelect: {
                renamingSessionID = nil
                selectSessionFromList(session)
            },
            onBeginRename: {
                selectSessionFromList(session, forceSingle: true)
                renamingSessionID = session.id
            },
            onEndRename: { renamingSessionID = nil },
            onRename: { viewModel.renamePiAgentSession(session.id, title: $0) },
            onTogglePinned: { viewModel.togglePiAgentSessionPinned(session.id) }
        )
        .tag(session.id)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.automatic)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                viewModel.togglePiAgentSessionPinned(session.id)
            } label: {
                Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            .tint(AppTheme.brandAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteSessionsImmediately(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? selectedSessionIDs : [session.id])
            } label: {
                Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected" : "Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                viewModel.togglePiAgentSessionPinned(session.id)
            } label: {
                Label(session.isPinned ? "Unpin Session" : "Pin Session", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                requestDeleteSessions(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? selectedSessionIDs : [session.id])
            } label: {
                Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected Sessions" : "Delete Session", systemImage: "trash")
            }
        }
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .transcriptEdgeFade()

            PiAgentProcessingIndicatorBar(message: stabilizedProcessingMessage)

            Divider()

            VStack(spacing: 12) {
                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                }

                PiAgentComposerPanel(
                    viewModel: viewModel,
                    store: store,
                    onWillSend: beginTranscriptAutoScrollTurn,
                    onDidSend: requestTranscriptBottomScroll
                )
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: session.kind == .issue ? .purple : .blue)
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                TextField("Session name", text: $selectedSessionTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .onSubmit(commitSelectedSessionRename)
                    .onDisappear(perform: commitSelectedSessionRename)

                if let error = session.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: "No Session Selected") {
                Text("Select a session from the left, or create a new draft for the selected project.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var transcript: some View {
        PiAgentAppKitTranscriptView(
            items: appKitTranscriptItems,
            sessionID: store.selectedSession?.id,
            renderRevision: transcriptCache.renderRevision,
            streamingRevision: transcriptCache.streamingRevision,
            autoScrollTurnRevision: transcriptCache.autoScrollTurnRevision,
            bottomScrollRequest: transcriptBottomScrollRequest,
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptIsPinnedToBottom = isPinnedToBottom
            }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptIsPinnedToBottom else { return }
            requestTranscriptBottomScroll()
        }
    }

    private var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
        let timelineSnapshot = transcriptTimelineSnapshot
        let timelineItems = timelineSnapshot.mainVisibleItems
        let chromeRevision = appKitTranscriptChromeRevision(snapshot: timelineSnapshot)
        let threadContextRevision = appKitTranscriptThreadContextRevision(snapshot: timelineSnapshot)
        var items: [PiAgentAppKitTranscriptItem] = []

        if let session = store.selectedSession {
            items.append(PiAgentAppKitTranscriptItem(
                id: "startup-resources-\(session.id.uuidString)",
                view: AnyView(PiAgentStartupResourcesCard(viewModel: viewModel, session: session) {
                    startupResourcesLayoutRevision &+= 1
                }),
                contentRevision: chromeRevision &+ startupResourcesLayoutRevision,
                estimatedHeight: { _ in 110 }
            ))
            if let finalSystemPrompt = session.finalSystemPrompt {
                items.append(PiAgentAppKitTranscriptItem(
                    id: "system-prompt-\(session.id.uuidString)",
                    view: AnyView(PiAgentSystemPromptAuditCard(title: "Final System Prompt", subtitle: "", prompt: finalSystemPrompt)),
                    contentRevision: finalSystemPrompt.hashValue,
                    estimatedHeight: { _ in 80 }
                ))
            }
            for request in store.supervisorRequests(for: session.id).filter({ $0.status == .pending }) {
                items.append(PiAgentAppKitTranscriptItem(
                    id: "supervisor-request-\(request.id)",
                    view: AnyView(PiSubagentSupervisorRequestCard(
                        request: request,
                        onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: session.id, response: response) },
                        onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: session.id) }
                    )),
                    contentRevision: request.hashValue,
                    estimatedHeight: { _ in 180 }
                ))
            }
        }

        if let archive = timelineSnapshot.preCompactionArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.compactedAt)
            items.append(PiAgentAppKitTranscriptItem(
                id: "pre-compaction-archive",
                view: AnyView(preCompactionArchiveCard(archive)),
                contentRevision: hasher.finalize(),
                estimatedHeight: { _ in 60 }
            ))
        }
        if let archive = timelineSnapshot.recentWindowArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.limit)
            items.append(PiAgentAppKitTranscriptItem(
                id: "recent-window-archive",
                view: AnyView(recentWindowArchiveCard(archive)),
                contentRevision: hasher.finalize(),
                estimatedHeight: { _ in 60 }
            ))
        }
        if store.isSelectedTranscriptLoading && timelineItems.isEmpty {
            items.append(PiAgentAppKitTranscriptItem(
                id: "pi-agent-transcript-state-card",
                view: AnyView(loadingTranscriptCard),
                contentRevision: chromeRevision,
                estimatedHeight: { _ in 80 }
            ))
        } else if timelineItems.isEmpty && items.isEmpty {
            items.append(PiAgentAppKitTranscriptItem(
                id: "pi-agent-transcript-state-card",
                view: AnyView(emptyTranscriptCard),
                contentRevision: chromeRevision,
                estimatedHeight: { _ in 120 }
            ))
        } else {
            for item in timelineItems {
                items.append(PiAgentAppKitTranscriptItem(
                    id: item.id,
                    view: AnyView(transcriptTimelineItemView(item, snapshot: timelineSnapshot)),
                    contentRevision: appKitTranscriptContentRevision(for: item, snapshot: timelineSnapshot, contextRevision: threadContextRevision),
                    estimatedHeight: { width in
                        Self.estimatedHeight(for: item, snapshot: timelineSnapshot, width: width)
                    }
                ))
            }
        }
        items.append(PiAgentAppKitTranscriptItem(
            id: "pi-agent-bottom-anchor",
            view: AnyView(Color.clear.frame(height: 1)),
            contentRevision: 0,
            estimatedHeight: { _ in 1 }
        ))
        return items
    }

    /// Fast height estimator for a transcript timeline item. Uses character-count
    /// math (no SwiftUI invocation) — close enough so the row lands near its final
    /// position on first paint; the cell reports its precise height immediately
    /// after rendering and the row re-tiles to match.
    private static func estimatedHeight(
        for item: PiAgentTranscriptTimelineItem,
        snapshot: PiAgentTranscriptTimelineSnapshot,
        width: CGFloat
    ) -> CGFloat {
        switch item.kind {
        case let .thread(thread):
            let cardWidth = max(width - 32, 200)
            let charsPerLine = max(Int(cardWidth / 7), 20)
            var total: CGFloat = 0
            if let q = thread.question {
                let lines = max(1, (q.text.count + charsPerLine - 1) / charsPerLine)
                total += CGFloat(lines) * 18 + 56  // bubble paddings + author label
            }
            for child in thread.children {
                switch child {
                case let .assistant(entry), let .steering(entry), let .thinking(entry):
                    let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
                    total += CGFloat(min(lines, 40)) * 18 + 48
                case .toolGroup:
                    total += 48
                case .status, .error:
                    total += 56
                }
            }
            return max(total, 80)
        case .plan:
            return 120
        }
    }

    private func appKitTranscriptChromeRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(store.selectedSession?.id)
        hasher.combine(String(describing: store.selectedSession?.status))
        hasher.combine(store.isSelectedTranscriptLoading)
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        return hasher.finalize()
    }

    private func appKitTranscriptThreadContextRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(store.selectedSession.map { $0.worktreePath ?? $0.projectPath })
        if let sessionID = store.selectedSession?.id {
            hasher.combine(store.subagentRuns(for: sessionID).map { "\($0.id):\($0.status):\($0.updatedAt)" })
        }
        return hasher.finalize()
    }

    private func appKitTranscriptContentRevision(
        for item: PiAgentTranscriptTimelineItem,
        snapshot: PiAgentTranscriptTimelineSnapshot,
        contextRevision: Int
    ) -> Int {
        switch item.kind {
        case let .thread(thread):
            let planEvents = snapshot.planEventsByThreadID[thread.id] ?? []
            let signature = cheapThreadSignature(thread, contextRevision: contextRevision, planEvents: planEvents)
            return transcriptCache.cachedThreadRevision(for: thread.id, signature: signature) {
                var hasher = Hasher()
                hasher.combine(contextRevision)
                hashThreadRevision(thread, into: &hasher)
                for event in planEvents {
                    hashPlanEventRevision(event, into: &hasher)
                }
                return hasher.finalize()
            }
        case let .plan(event):
            var hasher = Hasher()
            hasher.combine(contextRevision)
            hashPlanEventRevision(event, into: &hasher)
            return hasher.finalize()
        }
    }

    // Cache key for a thread's content revision. Hashes only (id, text.count) per entry —
    // about 3× cheaper than the full revision hash. Covers any mutation upsert/updateEntry
    // can make to a known entry, not just append-only streaming growth, so reusing the
    // cached full hash is safe whenever this signature is unchanged.
    private func cheapThreadSignature(
        _ thread: PiAgentTranscriptThread,
        contextRevision: Int,
        planEvents: [PiSessionPlanEventRecord]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hasher.combine(thread.id)
        inlineEntrySignature(thread.question, into: &hasher)
        hasher.combine(thread.steeringMessages.count)
        for entry in thread.steeringMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.thinkingParts.count)
        for entry in thread.thinkingParts { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.assistantMessages.count)
        for entry in thread.assistantMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.activities.count)
        for activity in thread.activities {
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            inlineEntrySignature(activity.representativeEntry, into: &hasher)
        }
        hasher.combine(thread.statuses.count)
        for entry in thread.statuses { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.errors.count)
        for entry in thread.errors { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(planEvents.count)
        for event in planEvents { hasher.combine(event.id) }
        return hasher.finalize()
    }

    private func inlineEntrySignature(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
    }

    private func hashThreadRevision(_ thread: PiAgentTranscriptThread, into hasher: inout Hasher) {
        hasher.combine(thread.id)
        hashEntryRevision(thread.question, into: &hasher)
        thread.steeringMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.thinkingParts.forEach { hashEntryRevision($0, into: &hasher) }
        thread.assistantMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.activities.forEach { activity in
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            hashEntryRevision(activity.representativeEntry, into: &hasher)
        }
        thread.statuses.forEach { hashEntryRevision($0, into: &hasher) }
        thread.errors.forEach { hashEntryRevision($0, into: &hasher) }
    }

    private func hashEntryRevision(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.title)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.timestamp)
    }

    private func hashPlanEventRevision(_ event: PiSessionPlanEventRecord, into hasher: inout Hasher) {
        hasher.combine(event.id)
        hasher.combine(event.planID)
        hasher.combine(event.kind)
        hasher.combine(event.timestamp)
        hasher.combine(event.items.count)
        for item in event.items {
            hasher.combine(item.id)
            hasher.combine(item.title.count)
            hasher.combine(item.status)
            hasher.combine(item.updatedAt)
        }
    }

    private var loadingTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loading transcript")
                        .font(.headline)
                    Text("Restoring the selected chat from disk.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private var emptyTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No transcript yet")
                        .font(.headline)
                    Text("Send a message below to launch Pi Agent for this session.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private var transcriptTimelineSnapshot: PiAgentTranscriptTimelineSnapshot {
        let items = transcriptTimelineItems
        let archiveRange = preCompactionArchiveRange(in: items)
        let archiveNotice = archiveRange.flatMap { archive -> (hiddenCount: Int, compactedAt: Date)? in
            archive.visibleStartIndex > 0 ? (archive.visibleStartIndex, archive.compactedAt) : nil
        }
        let visibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript, let archiveRange {
            visibleItems = Array(items[archiveRange.visibleStartIndex...])
        } else {
            visibleItems = items
        }
        let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
        let mainVisibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript && visibleItems.count > recentTranscriptTimelineItemLimit {
            earlierVisibleItems = Array(visibleItems.dropLast(recentTranscriptTimelineItemLimit))
            mainVisibleItems = Array(visibleItems.suffix(recentTranscriptTimelineItemLimit))
        } else {
            earlierVisibleItems = []
            mainVisibleItems = visibleItems
        }
        let recentWindowArchive = earlierVisibleItems.isEmpty
            ? nil
            : (hiddenCount: earlierVisibleItems.count, limit: recentTranscriptTimelineItemLimit)
        return PiAgentTranscriptTimelineSnapshot(
            allItems: items,
            visibleItems: visibleItems,
            mainVisibleItems: mainVisibleItems,
            earlierVisibleItems: earlierVisibleItems,
            preCompactionArchive: archiveNotice,
            recentWindowArchive: recentWindowArchive,
            planEventsByThreadID: planEventsByThreadID(in: items)
        )
    }

    private var transcriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        let items = transcriptCache.threads.map { thread in
            PiAgentTranscriptTimelineItem(
                id: "thread-\(thread.id.uuidString)",
                timestamp: thread.timelineTimestamp,
                kind: .thread(thread)
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private var visibleTranscriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        transcriptTimelineSnapshot.mainVisibleItems
    }

    private var preCompactionArchiveNotice: (hiddenCount: Int, compactedAt: Date)? {
        transcriptTimelineSnapshot.preCompactionArchive
    }

    private func preCompactionArchiveRange(in items: [PiAgentTranscriptTimelineItem]) -> (visibleStartIndex: Int, compactedAt: Date)? {
        guard let index = items.indices.last(where: { index in
            guard case let .thread(thread) = items[index].kind else { return false }
            return thread.statuses.contains(where: isCompletedCompactionEntry)
        }) else { return nil }
        return (index, items[index].timestamp)
    }

    private func isCompletedCompactionEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        guard entry.title == "Compaction" else { return false }
        let text = entry.text.localizedLowercase
        return (text.contains("context compacted") || text.contains("compaction complete") || text.contains("compaction finished"))
            && !text.contains("nothing to compact")
            && !text.contains("compacting")
    }

    @ViewBuilder
    private func preCompactionArchiveCard(_ archive: (hiddenCount: Int, compactedAt: Date)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: showArchivedPreCompactionTranscript ? "tray.and.arrow.up" : "archivebox")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(showArchivedPreCompactionTranscript ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden")
                .font(.caption.weight(.semibold))
            Text("\(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") before \(archive.compactedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
            Button(showArchivedPreCompactionTranscript ? "Hide" : "Load Earlier") {
                withAnimation(.snappy(duration: 0.18)) {
                    showArchivedPreCompactionTranscript.toggle()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func recentWindowArchiveCard(_ archive: (hiddenCount: Int, limit: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Earlier transcript hidden")
                    .font(.caption.weight(.semibold))
                Text("Showing the latest \(archive.limit) items to keep this chat responsive. \(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") are available.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer(minLength: 0)
            Button("Open Earlier Transcript") {
                isEarlierTranscriptSheetPresented = true
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var earlierTranscriptSheet: some View {
        let snapshot = transcriptTimelineSnapshot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Earlier Transcript")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("Messages before the latest \(recentTranscriptTimelineItemLimit) visible items.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button("Done") {
                    isEarlierTranscriptSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView(showsIndicators: true) {
                PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.earlierVisibleItems) { item in
                        transcriptTimelineItemView(item, snapshot: snapshot)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .background(AppTheme.windowBackground)
    }

    @ViewBuilder
    private func transcriptTimelineItemView(_ item: PiAgentTranscriptTimelineItem, snapshot: PiAgentTranscriptTimelineSnapshot) -> some View {
        switch item.kind {
        case let .thread(thread):
            PiAgentTranscriptThreadCard(
                thread: thread,
                visibility: viewModel.appSettings.piAgentTranscriptVisibility,
                skills: visibleSkillsForSelectedSession,
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                planEvents: snapshot.planEventsByThreadID[thread.id] ?? [],
                nativeSubagentRunsByID: nativeSubagentRunsByID,
                nativeSubagentCard: nativeSubagentCard
            )
            .id(item.id)
        case let .plan(event):
            PiAgentCurrentPlanCard(event: event)
                .id(item.id)
        }
    }

    private func planEventsByThreadID(in timelineItems: [PiAgentTranscriptTimelineItem]) -> [UUID: [PiSessionPlanEventRecord]] {
        guard viewModel.appSettings.piAgentTranscriptVisibility.showPlans,
              let sessionID = store.selectedSession?.id else { return [:] }

        let threadBoundaries: [(id: UUID, timestamp: Date)] = timelineItems.compactMap { item in
            guard case let .thread(thread) = item.kind else { return nil }
            return (thread.id, thread.timelineTimestamp)
        }
        guard !threadBoundaries.isEmpty else { return [:] }

        let events = store.sessionPlanEvents(for: sessionID)
            .filter { $0.kind != .cleared }
            .sorted { $0.timestamp < $1.timestamp }
        guard !events.isEmpty else { return [:] }

        var output: [UUID: [PiSessionPlanEventRecord]] = [:]
        var threadIndex = 0
        for event in events {
            while threadIndex + 1 < threadBoundaries.count,
                  threadBoundaries[threadIndex + 1].timestamp <= event.timestamp {
                threadIndex += 1
            }
            guard event.timestamp >= threadBoundaries[threadIndex].timestamp else { continue }
            output[threadBoundaries[threadIndex].id, default: []].append(event)
        }
        return output
    }

    private func updateStabilizedProcessingMessage(_ message: String?) {
        processingMessageUpdateTask?.cancel()
        processingMessageUpdateTask = nil

        guard let message else {
            stabilizedProcessingMessage = nil
            return
        }

        guard stabilizedProcessingMessage != nil else {
            stabilizedProcessingMessage = message
            return
        }

        processingMessageUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            stabilizedProcessingMessage = message
            processingMessageUpdateTask = nil
        }
    }

    private var selectedSessionProcessingMessage: String? {
        guard let session = store.selectedSession,
              session.status.isActive,
              store.selectedUIRequest == nil else { return nil }

        if session.status == .starting { return "Starting Pi" }
        if session.isCompacting { return "Compacting context" }
        if let subagentMessage = runningSubagentsProcessingMessage(for: session) {
            return subagentMessage
        }

        if let lastEntry = store.selectedTranscript.last {
            return processingMessage(after: lastEntry)
        }
        return "Pi is working"
    }

    private func processingMessage(after entry: PiAgentTranscriptEntry) -> String? {
        switch entry.role {
        case .assistant:
            return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing response" : "Writing response"
        case .error, .stderr:
            return "Pi is working"
        case .tool:
            if entry.text.localizedCaseInsensitiveContains("waiting for user input") { return nil }
            return toolProcessingMessage(for: entry)
        case .status:
            return statusProcessingMessage(for: entry)
        case .user:
            switch entry.title {
            case "Steering": return "Applying your steering"
            case "Queued follow-up": return "Queued follow-up"
            default: return "Processing your message"
            }
        case .thinking:
            return "Reasoning"
        case .raw:
            return "Pi is working"
        }
    }

    private func statusProcessingMessage(for entry: PiAgentTranscriptEntry) -> String? {
        switch entry.title {
        case "Input Sent": return "Processing your response"
        case "Input Needed": return nil
        case "Retry": return "Retrying request"
        case "Compaction": return "Compacting context"
        case "Native Subagent Requested": return "Starting subagent"
        case "Native Parallel Requested": return "Starting parallel run"
        case "Supervisor Response Routed": return "Routing response"
        case "System Prompt Captured": return "Preparing context"
        case "Process Ended", "Stopped": return nil
        default: return "Processing update"
        }
    }

    private func toolProcessingMessage(for entry: PiAgentTranscriptEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.hasPrefix("Tool:") else { return "Running tool" }
        let toolName = title.dropFirst("Tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch toolName {
        case "managed_subagent": return "Starting subagent"
        case "managed_parallel": return "Starting parallel agents"
        default: return toolName.isEmpty ? "Running tool" : "Running \(toolName)"
        }
    }

    private func runningSubagentsProcessingMessage(for session: PiAgentSessionRecord) -> String? {
        let agentNames = runningSubagentNames(for: session)
        guard !agentNames.isEmpty else { return nil }
        let prefix = agentNames.count == 1 ? "Running agent" : "Running agents"
        return "\(prefix): \(formattedRunningAgentList(agentNames))"
    }

    private func runningSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        var names: [String] = []
        for run in store.subagentRuns(for: session.id) where run.status.isActive {
            if run.mode == .parallel, let children = run.children, !children.isEmpty {
                names.append(contentsOf: children
                    .filter { $0.status.isActive }
                    .sorted { $0.index < $1.index }
                    .map(\.agentName))
            } else if let child = run.child, child.status.isActive {
                names.append(child.agentName)
            } else {
                names.append(run.agentName)
            }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func formattedRunningAgentList(_ names: [String]) -> String {
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        guard uniqueNames.count > 3 else { return uniqueNames.joined(separator: ", ") }
        return uniqueNames.prefix(3).joined(separator: ", ") + " +\(uniqueNames.count - 3) more"
    }

    private func scheduleTranscriptCacheUpdate() {
        guard let session = store.selectedSession else {
            transcriptCache.scheduleUpdate(sessionID: nil, revision: 0, rawEntries: [])
            return
        }

        // Hydrate the selected transcript before updating the render cache. With lazy
        // loading, selectedTranscript can briefly be empty during a session switch;
        // publishing that empty snapshot is what produces the intermittent blank pane.
        let entries = store.transcript(for: session.id)
        transcriptCache.scheduleUpdate(
            sessionID: session.id,
            revision: store.selectedTranscriptRevision,
            rawEntries: entries
        )
    }

    private func requestSelectedTranscriptLoadAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            store.requestSelectedTranscriptLoad()
        }
    }

    private func requestSubagentTranscriptLoadAfterViewUpdate(runID: UUID) {
        Task { @MainActor in
            await Task.yield()
            store.requestSubagentTranscriptLoad(for: runID)
        }
    }

    private func resetTranscriptAutoScroll() {
        transcriptIsPinnedToBottom = true
    }

    private func beginTranscriptAutoScrollTurn() {
        resetTranscriptAutoScroll()
    }

    private func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }

    @ViewBuilder
    private var composer: some View {
        let isRunning = store.selectedSession?.status.isActive == true
        let isCompacting = store.selectedSession?.isCompacting == true
        let hasSelectedSession = store.selectedSession != nil
        PiAgentComposerBox(
                text: $composerText,
                pasteAttachments: $composerPasteAttachments,
                nextPasteID: $nextComposerPasteID,
                images: $composerImages,
                files: $composerFiles,
                folders: $composerFolders,
                attachmentError: $composerAttachmentError,
                inputMode: $inputMode,
                isRunning: isRunning,
                isDisabled: isCompacting,
                placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Ask Pi to implement, inspect, explain, or fix…")),
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty),
                canCreateSession: !isCompacting && store.selectedSession == nil,
                createSessionProjects: viewModel.selectedDiscoveredProject == nil ? piAgentNewSessionProjects : [],
                path: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                onFiles: addFileAttachments,
                onFolders: addFolderAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                transcript: store.selectedTranscript,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
            onSend: hasSelectedSession ? sendComposerMessage : createSessionFromComposer,
            onStop: { viewModel.stopSelectedPiAgentSession() },
            onCreateSession: createSessionFromComposer,
            onCreateSessionForProject: createSessionFromComposer,
            onClear: clearComposerInput
        )
        .popover(
            isPresented: Binding(
                get: { hasComposerSuggestions },
                set: { _ in }
            ),
            attachmentAnchor: .point(UnitPoint(x: 0.04, y: 0.12)),
            arrowEdge: .top
        ) {
            PiAgentCommandSuggestions(
                commands: slashSuggestions,
                skills: skillSlashSuggestions,
                fileSuggestions: fileSuggestions,
                onSelectFile: insertFileSuggestion,
                onSelectCommand: insertSlashSuggestion
            )
            .padding(6)
        }
        .zIndex(hasComposerSuggestions ? 20 : 0)
    }

    private var activeSuggestionToken: (token: String, range: Range<String.Index>)? {
        guard !composerText.isEmpty else { return nil }
        let nsText = composerText as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: composerText) else {
            return nil
        }
        let token = String(composerText[range])
        guard !token.isEmpty else { return nil }
        return (token: token, range: range)
    }

    private enum ComposerSuggestionTrigger {
        case slash(query: String)
        case file(query: String)
    }

    private var composerSuggestionTrigger: ComposerSuggestionTrigger? {
        guard let active = activeSuggestionToken,
              let first = active.token.first else { return nil }

        switch first {
        case "/":
            // Pi only dispatches slash commands/templates when the prompt starts with `/`.
            // Keep file mentions available anywhere, but only suggest/action slash commands
            // when this token is the first non-whitespace content in the composer.
            let prefix = composerText[..<active.range.lowerBound]
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .slash(query: String(active.token.dropFirst()).lowercased())
        case "@":
            return .file(query: String(active.token.dropFirst()).lowercased())
        default:
            return nil
        }
    }

    private var hasComposerSuggestions: Bool {
        !slashSuggestions.isEmpty || !skillSlashSuggestions.isEmpty || !fileSuggestions.isEmpty
    }

    private var slashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        guard !query.hasPrefix("skill:") else { return [] }
        let all = runtimeCommandInvocations(excludingSkills: true) ?? fallbackCommandInvocations
        return all.filter { query.isEmpty || $0.dropFirst().lowercased().hasPrefix(query) }.prefix(8).map { $0 }
    }

    private var skillSlashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        let normalizedQuery = query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
        let all = runtimeCommandInvocations(onlySkills: true) ?? fallbackSkillInvocations
        return all
            .filter { invocation in
                let name = invocation.replacingOccurrences(of: "/skill:", with: "")
                return normalizedQuery.isEmpty || name.lowercased().hasPrefix(normalizedQuery)
            }
            .prefix(8)
            .map { $0 }
    }

    private func runtimeCommandInvocations(onlySkills: Bool = false, excludingSkills: Bool = false) -> [String]? {
        guard let commands = store.selectedSession?.commandInvocations else { return nil }
        let filtered = commands.filter { invocation in
            let isSkill = invocation.hasPrefix("/skill:")
            if onlySkills { return isSkill }
            if excludingSkills { return !isSkill }
            return true
        }
        return Array(Set(filtered)).sorted()
    }

    private var fallbackCommandInvocations: [String] {
        let configuredCommands = PiInjectedCommandCatalog.all
            .filter { PiInjectedCommandCatalog.isEnabled($0, settings: viewModel.appSettings) }
            .map(\.slashName)
        return Array(Set(snapshotForSelectedSession.promptTemplates.map(\.invocation) + configuredCommands + ["/compact"]))
            .sorted()
    }

    private var fallbackSkillInvocations: [String] {
        // Runtime RPC is authoritative. Before it responds, use active skills only;
        // External/catalog-only skills are management records, not guaranteed runtime commands.
        var seen = Set<String>()
        return snapshotForSelectedSession.skills
            .filter { seen.insert($0.name).inserted }
            .map { "/skill:\($0.name)" }
            .sorted()
    }

    private var snapshotForSelectedSession: ScanSnapshot {
        let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
        return projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
    }

    private var visibleSkillsForSelectedSession: [SkillRecord] {
        let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
        let snapshot = projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
        var seen = Set<String>()
        return (snapshot.skills + snapshot.librarySkills)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var fileSuggestions: [PiAgentFileSuggestion] {
        guard let session = store.selectedSession else { return [] }
        guard case let .file(query) = composerSuggestionTrigger else { return [] }
        return PiAgentFileSuggestion.scan(rootPath: session.worktreePath ?? session.projectPath, query: query)
    }

    private func insertFileSuggestion(_ suggestion: PiAgentFileSuggestion) {
        replaceCurrentSuggestionToken(with: "@\(suggestion.relativePath)")
    }

    private func insertSlashSuggestion(_ command: String) {
        replaceCurrentSuggestionToken(with: command)
    }

    private var nativeSubagentRunsByID: [UUID: PiSubagentRunRecord] {
        guard let session = store.selectedSession else { return [:] }
        return Dictionary(uniqueKeysWithValues: store.subagentRuns(for: session.id).map { ($0.id, $0) })
    }

    private func nativeSubagentCard(for run: PiSubagentRunRecord) -> PiNativeSubagentRunCard {
        PiNativeSubagentRunCard(
            run: run,
            onStop: { viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
            onOpenTranscript: { selectedSubagentTranscriptRunID = run.id },
            onReveal: { revealSubagentRun(run) },
            onOpenGraph: { selectedSubagentGraphRunID = run.id },
            onOpenChildTranscript: { selectedSubagentTranscriptRunID = $0 },
            onStopChild: { viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) },
            imageStore: viewModel.agentImageStore
        )
    }

    private var selectedSubagentTranscriptBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentTranscriptRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentTranscriptRunID = newValue?.id }
        )
    }

    private var selectedSubagentGraphBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentGraphRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentGraphRunID = newValue?.id }
        )
    }

    private func revealSubagentRun(_ run: PiSubagentRunRecord) {
        let target = run.outputPath ?? run.artifactDirectory
        guard !target.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    private func replaceCurrentSuggestionToken(with replacement: String) {
        guard let active = activeSuggestionToken else { return }
        composerText.replaceSubrange(active.range, with: replacement)
        composerText += " "
    }

    private func addFileAttachments(_ urls: [URL]) {
        let attachments = urls.filter { !$0.hasDirectoryPath }.compactMap { PiAgentFileAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        for attachment in attachments where !composerFiles.contains(where: { $0.url == attachment.url }) {
            composerFiles.append(attachment)
        }
    }

    private func addFolderAttachments(_ urls: [URL]) {
        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        for attachment in attachments where !composerFolders.contains(where: { $0.url == attachment.url }) {
            composerFolders.append(attachment)
        }
    }

    private func loadComposerDraft(for sessionID: UUID?) {
        resetComposerHistoryNavigation()
        if let pending = viewModel.consumePendingPiAgentComposerText() {
            composerText = pending
            composerPasteAttachments = []
            nextComposerPasteID = 1
            composerImages = []
            composerFiles = []
            composerFolders = []
            composerAttachmentError = nil
            saveComposerDraft(for: sessionID)
            return
        }

        guard let sessionID else {
            clearComposerInput()
            return
        }
        let draft = store.composerDraft(for: sessionID)
        composerText = draft.text
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = draft.images
        composerFiles = draft.files
        composerFolders = draft.folders
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        let draftText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        store.saveComposerDraft(text: draftText, images: composerImages, files: composerFiles, folders: composerFolders, for: sessionID)
    }

    private func clearComposerInput() {
        resetComposerHistoryNavigation()
        composerText = ""
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = []
        composerFiles = []
        composerFolders = []
        composerAttachmentError = nil
    }

    private func resetComposerHistoryNavigation(keepDraft: Bool = false) {
        composerHistoryIndex = nil
        if !keepDraft {
            composerHistoryDraft = ""
        }
    }

    private func createSessionFromComposer() {
        createSessionFromComposer(for: nil)
    }

    private func createSessionFromComposer(for project: DiscoveredProject?) {
        guard store.selectedSession == nil else { return }
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        let shouldSend = !expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty
        if let project {
            viewModel.createPiAgentDraft(for: project)
        } else {
            viewModel.createPiAgentDraftForSelectedProject()
        }
        if shouldSend {
            sendComposerMessage()
        }
    }

    private func sendComposerMessage() {
        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: composerText, attachments: composerPasteAttachments)
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: activePasteAttachments)
        let message = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptMessage = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        beginTranscriptAutoScrollTurn()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, images: composerImages, pasteAttachments: activePasteAttachments)
        requestTranscriptBottomScroll()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        return message
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { part in
                guard part.hasPrefix("@"), part.count > 1 else { return String(part) }
                let relative = String(part.dropFirst())
                let url = rootURL.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else { return String(part) }
                return fileTag(for: url)
            }
            .joined(separator: " ")
    }

    private func attachedFilePayload() -> String? {
        var tags: [String] = []
        for file in composerFiles {
            tags.append(fileTag(for: file.url))
        }
        for folder in composerFolders {
            tags.append(folderReference(for: folder.url))
        }
        return tags.joined(separator: "\n")
    }

    private func folderReference(for url: URL) -> String {
        "folder: `\(url.path)`"
    }

    private func fileTag(for url: URL) -> String {
        "<file name=\"\(url.path)\"></file>"
    }

    private var runningCount: Int {
        scopedSessions.filter { viewModel.piAgentSessionIsWorking($0) }.count
    }

    private var emptySessionsMessage: String {
        if let project = viewModel.selectedDiscoveredProject {
            return "Use + to create a draft for \(project.name), or open from a GitHub issue."
        }
        return "Use + to create a draft, or select a project to narrow the list."
    }

    private func supportedThinkingLevels(for session: PiAgentSessionRecord) -> [String] {
        let defaultModel = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? defaultModel?.provider
        let modelID = session.modelOverrideID ?? session.model ?? defaultModel?.model
        if let provider, let modelID {
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? [] : ["off"]) : cached.supportedThinkingLevels
            }
        }
        return []
    }

    private func syncVisibleSessionSelection() {
        if let selectedID = store.selectedSession?.id,
           visibleSessions.contains(where: { $0.id == selectedID }) {
            return
        }

        if let firstVisible = visibleSessions.first {
            store.select(firstVisible.id)
        } else {
            store.clearSelection()
        }
    }

    private func syncMultiSelectionToSelectedSession() {
        if let selectedID = store.selectedSession?.id {
            selectedSessionIDs = [selectedID]
        } else {
            selectedSessionIDs = []
        }
        lastSelectedSessionID = store.selectedSession?.id
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        selectedSessionIDs.formIntersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) {
            selectedSessionIDs.insert(selectedID)
        }
        if let lastSelectedSessionID, !visibleIDs.contains(lastSelectedSessionID) {
            self.lastSelectedSessionID = store.selectedSession?.id
        }
    }

    private func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if forceSingle || modifiers.isEmpty {
            selectedSessionIDs = [session.id]
        } else if modifiers.contains(.shift), let anchorID = lastSelectedSessionID, let anchorIndex = visibleSessionIDs.firstIndex(of: anchorID), let targetIndex = visibleSessionIDs.firstIndex(of: session.id) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedSessionIDs.formUnion(visibleSessionIDs[range])
        } else if modifiers.contains(.command) {
            if selectedSessionIDs.contains(session.id), selectedSessionIDs.count > 1 {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
        }
        lastSelectedSessionID = session.id
        viewModel.selectPiAgentSession(session.id)
    }

    private func requestDeleteSessions(_ ids: Set<UUID>, isClearAll: Bool = false) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        pendingDeleteSessionIDs = deleteIDs
        pendingDeleteIsClearAll = isClearAll
        pendingDeleteClearAllProjects = isClearAll && viewModel.selectedProjectPath == nil
        pendingDeleteProjectName = isClearAll && viewModel.selectedProjectPath != nil ? (viewModel.selectedDiscoveredProject?.name ?? "the current project") : nil
        isDeleteSessionsAlertPresented = true
    }

    private func resetPendingSessionDelete() {
        pendingDeleteSessionIDs = []
        pendingDeleteIsClearAll = false
        pendingDeleteClearAllProjects = false
        pendingDeleteProjectName = nil
    }

    private func deleteSessionsImmediately(_ ids: Set<UUID>) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        selectedSessionIDs.subtract(deleteIDs)
        withAnimation(.snappy(duration: 0.18)) {
            cachedVisibleSessions.removeAll { deleteIDs.contains($0.id) }
            hasBuiltVisibleSessions = true
        }
        viewModel.deletePiAgentSessions(deleteIDs)
        rebuildVisibleSessions()
        syncMultiSelectionToSelectedSession()
        syncRuntimeFooterSnapshot()
    }

    private func deletePendingSessions() {
        let ids = pendingDeleteSessionIDs
        resetPendingSessionDelete()
        deleteSessionsImmediately(ids)
    }

    private func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    private func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }

    private func syncSelectedSessionTitleDraft() {
        selectedSessionTitleDraft = store.selectedSession?.title ?? ""
    }

    private func commitSelectedSessionRename() {
        guard let session = store.selectedSession else { return }
        let trimmedTitle = selectedSessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            selectedSessionTitleDraft = session.title
        } else if trimmedTitle != session.title {
            viewModel.renamePiAgentSession(session.id, title: trimmedTitle)
            selectedSessionTitleDraft = trimmedTitle
        }
    }

    private func sortedSessions(_ sessions: [PiAgentSessionRecord]) -> [PiAgentSessionRecord] {
        sessions.sorted { PiAgentSessionRecord.sessionListPrecedes($0, $1) }
    }

    private func sessionMatchesSearch(_ session: PiAgentSessionRecord, query: String) -> Bool {
        let haystack = [
            session.title,
            session.projectName,
            session.projectPath,
            session.repository ?? "",
            session.issueNumber.map(String.init) ?? "",
            session.lastSummary ?? ""
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func effectiveStatus(for session: PiAgentSessionRecord) -> String {
        session.status.rawValue
    }

    private func effectiveStatusColor(for session: PiAgentSessionRecord) -> Color {
        switch session.status {
        case .running, .starting: return .orange
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}

private struct PiAgentComposerPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    let onWillSend: () -> Void
    let onDidSend: () -> Void

    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let isRunning = store.selectedSession?.status.isActive == true
        let isCompacting = store.selectedSession?.isCompacting == true
        let hasSelectedSession = store.selectedSession != nil

        PiAgentComposerBox(
            text: $composerText,
            pasteAttachments: $composerPasteAttachments,
            nextPasteID: $nextComposerPasteID,
            images: $composerImages,
            files: $composerFiles,
            folders: $composerFolders,
            attachmentError: $composerAttachmentError,
            inputMode: $inputMode,
            isRunning: isRunning,
            isDisabled: isCompacting,
            placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Ask Pi to implement, inspect, explain, or fix…")),
            canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty),
            canCreateSession: !isCompacting && store.selectedSession == nil,
            createSessionProjects: viewModel.selectedDiscoveredProject == nil ? piAgentNewSessionProjects : [],
            path: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
            onFiles: addFileAttachments,
            onFolders: addFolderAttachments,
            viewModel: viewModel,
            footerSession: store.selectedSession,
            transcript: store.selectedTranscript,
            supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
            metricsSession: runtimeFooterSession(isRunning: isRunning),
            onSend: hasSelectedSession ? sendComposerMessage : createSessionFromComposer,
            onStop: { viewModel.stopSelectedPiAgentSession() },
            onCreateSession: createSessionFromComposer,
            onCreateSessionForProject: createSessionFromComposer,
            onClear: clearComposerInput
        )
        .popover(
            isPresented: Binding(get: { hasComposerSuggestions }, set: { _ in }),
            attachmentAnchor: .point(UnitPoint(x: 0.04, y: 0.12)),
            arrowEdge: .top
        ) {
            PiAgentCommandSuggestions(
                commands: slashSuggestions,
                skills: skillSlashSuggestions,
                fileSuggestions: fileSuggestions,
                onSelectFile: insertFileSuggestion,
                onSelectCommand: insertSlashSuggestion
            )
            .padding(6)
        }
        .zIndex(hasComposerSuggestions ? 20 : 0)
        .onAppear {
            syncRuntimeFooterSnapshot()
            loadComposerDraft(for: store.selectedSession?.id)
        }
        .onDisappear {
            saveComposerDraft(for: store.selectedSession?.id)
        }
        .onChange(of: store.selectedSession?.id) { oldID, newID in
            saveComposerDraft(for: oldID)
            loadComposerDraft(for: newID)
            syncRuntimeFooterSnapshot()
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
    }

    private var activeSuggestionToken: (token: String, range: Range<String.Index>)? {
        guard !composerText.isEmpty else { return nil }
        let nsText = composerText as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: composerText) else { return nil }
        let token = String(composerText[range])
        guard !token.isEmpty else { return nil }
        return (token, range)
    }

    private enum ComposerSuggestionTrigger {
        case slash(query: String)
        case file(query: String)
    }

    private var composerSuggestionTrigger: ComposerSuggestionTrigger? {
        guard let active = activeSuggestionToken,
              let first = active.token.first else { return nil }
        switch first {
        case "/":
            let prefix = composerText[..<active.range.lowerBound]
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .slash(query: String(active.token.dropFirst()).lowercased())
        case "@":
            return .file(query: String(active.token.dropFirst()).lowercased())
        default:
            return nil
        }
    }

    private var hasComposerSuggestions: Bool {
        !slashSuggestions.isEmpty || !skillSlashSuggestions.isEmpty || !fileSuggestions.isEmpty
    }

    private var slashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        guard !query.hasPrefix("skill:") else { return [] }
        let all = runtimeCommandInvocations(excludingSkills: true) ?? fallbackCommandInvocations
        return all.filter { query.isEmpty || $0.dropFirst().lowercased().hasPrefix(query) }.prefix(8).map { $0 }
    }

    private var skillSlashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        let normalizedQuery = query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
        let all = runtimeCommandInvocations(onlySkills: true) ?? fallbackSkillInvocations
        return all
            .filter { invocation in
                let name = invocation.replacingOccurrences(of: "/skill:", with: "")
                return normalizedQuery.isEmpty || name.lowercased().hasPrefix(normalizedQuery)
            }
            .prefix(8)
            .map { $0 }
    }

    private func runtimeCommandInvocations(onlySkills: Bool = false, excludingSkills: Bool = false) -> [String]? {
        guard let commands = store.selectedSession?.commandInvocations else { return nil }
        let filtered = commands.filter { invocation in
            let isSkill = invocation.hasPrefix("/skill:")
            if onlySkills { return isSkill }
            if excludingSkills { return !isSkill }
            return true
        }
        return Array(Set(filtered)).sorted()
    }

    private var fallbackCommandInvocations: [String] {
        let configuredCommands = PiInjectedCommandCatalog.all
            .filter { PiInjectedCommandCatalog.isEnabled($0, settings: viewModel.appSettings) }
            .map(\.slashName)
        return Array(Set(snapshotForSelectedSession.promptTemplates.map(\.invocation) + configuredCommands + ["/compact"]))
            .sorted()
    }

    private var fallbackSkillInvocations: [String] {
        var seen = Set<String>()
        return snapshotForSelectedSession.skills
            .filter { seen.insert($0.name).inserted }
            .map { "/skill:\($0.name)" }
            .sorted()
    }

    private var snapshotForSelectedSession: ScanSnapshot {
        let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
        return projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
    }

    private var fileSuggestions: [PiAgentFileSuggestion] {
        guard let session = store.selectedSession else { return [] }
        guard case let .file(query) = composerSuggestionTrigger else { return [] }
        return PiAgentFileSuggestion.scan(rootPath: session.worktreePath ?? session.projectPath, query: query)
    }

    private func insertFileSuggestion(_ suggestion: PiAgentFileSuggestion) {
        replaceCurrentSuggestionToken(with: "@\(suggestion.relativePath)")
    }

    private func insertSlashSuggestion(_ command: String) {
        replaceCurrentSuggestionToken(with: command)
    }

    private func replaceCurrentSuggestionToken(with replacement: String) {
        guard let active = activeSuggestionToken else { return }
        composerText.replaceSubrange(active.range, with: replacement)
        composerText += " "
    }

    private func addFileAttachments(_ urls: [URL]) {
        let attachments = urls.filter { !$0.hasDirectoryPath }.compactMap { PiAgentFileAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        for attachment in attachments where !composerFiles.contains(where: { $0.url == attachment.url }) {
            composerFiles.append(attachment)
        }
    }

    private func addFolderAttachments(_ urls: [URL]) {
        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        for attachment in attachments where !composerFolders.contains(where: { $0.url == attachment.url }) {
            composerFolders.append(attachment)
        }
    }

    private func loadComposerDraft(for sessionID: UUID?) {
        if let pending = viewModel.consumePendingPiAgentComposerText() {
            composerText = pending
            composerPasteAttachments = []
            nextComposerPasteID = 1
            composerImages = []
            composerFiles = []
            composerFolders = []
            composerAttachmentError = nil
            saveComposerDraft(for: sessionID)
            return
        }

        guard let sessionID else {
            clearComposerInput()
            return
        }
        let draft = store.composerDraft(for: sessionID)
        composerText = draft.text
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = draft.images
        composerFiles = draft.files
        composerFolders = draft.folders
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        let draftText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        store.saveComposerDraft(text: draftText, images: composerImages, files: composerFiles, folders: composerFolders, for: sessionID)
    }

    private func clearComposerInput() {
        composerText = ""
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = []
        composerFiles = []
        composerFolders = []
        composerAttachmentError = nil
    }

    private func createSessionFromComposer() {
        createSessionFromComposer(for: nil)
    }

    private func createSessionFromComposer(for project: DiscoveredProject?) {
        guard store.selectedSession == nil else { return }
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        let shouldSend = !expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty
        if let project {
            viewModel.createPiAgentDraft(for: project)
        } else {
            viewModel.createPiAgentDraftForSelectedProject()
        }
        if shouldSend {
            sendComposerMessage()
        }
    }

    private func sendComposerMessage() {
        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: composerText, attachments: composerPasteAttachments)
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: activePasteAttachments)
        let message = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptMessage = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        onWillSend()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, images: composerImages, pasteAttachments: activePasteAttachments)
        onDidSend()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        return message
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { part in
                guard part.hasPrefix("@"), part.count > 1 else { return String(part) }
                let relative = String(part.dropFirst())
                let url = rootURL.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else { return String(part) }
                return fileTag(for: url)
            }
            .joined(separator: " ")
    }

    private func attachedFilePayload() -> String? {
        var tags: [String] = []
        for file in composerFiles { tags.append(fileTag(for: file.url)) }
        for folder in composerFolders { tags.append(folderReference(for: folder.url)) }
        return tags.joined(separator: "\n")
    }

    private func folderReference(for url: URL) -> String {
        "folder: `\(url.path)`"
    }

    private func fileTag(for url: URL) -> String {
        "<file name=\"\(url.path)\"></file>"
    }

    private func supportedThinkingLevels(for session: PiAgentSessionRecord) -> [String] {
        let defaultModel = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? defaultModel?.provider
        let modelID = session.modelOverrideID ?? session.model ?? defaultModel?.model
        if let provider, let modelID {
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? [] : ["off"]) : cached.supportedThinkingLevels
            }
        }
        return []
    }

    private func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    private func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }
}
