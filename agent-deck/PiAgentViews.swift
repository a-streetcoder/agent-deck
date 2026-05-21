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
}

private struct PiAgentAppKitTranscriptItem {
    let id: String
    let view: AnyView
    let contentRevision: Int
    /// Vertical spacing baked into the row, applied as padding inside the cell.
    /// `NSTableView.intercellSpacing` is uniform, but the transcript needs
    /// different gaps (question↔reply, sibling, thread↔thread) — so each gap is
    /// split in half across the two adjacent rows' facing insets. Folded into
    /// `contentRevision` so an inset change re-tiles the row.
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Fast height estimate used by `heightOfRow` before the cell renders.
    /// Closer estimates produce smoother first paint — the cell self-measures
    /// after it renders and reports its actual height back via callback.
    /// Includes the row insets so the estimate matches the measured height.
    let estimatedHeight: (CGFloat) -> CGFloat

    init(
        id: String,
        view: AnyView,
        contentRevision: Int = 0,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        estimatedHeight: @escaping (CGFloat) -> CGFloat = { _ in 120 }
    ) {
        self.id = id
        self.view = view
        self.contentRevision = contentRevision
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.estimatedHeight = estimatedHeight
    }
}

private enum PiAgentTranscriptTableSection: Hashable {
    case main
}

/// Floating "scroll to latest" affordance shown when the transcript is not
/// pinned to the bottom — tapping it scrolls to the newest content and
/// re-engages streaming auto-follow.
private struct JumpToLatestPill: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .offset(x: 0.5, y: 0.5)
        }
        .foregroundStyle(AppTheme.brandAccent)
        .frame(width: 32, height: 32)
        .glassEffect(.regular.tint(AppTheme.brandAccent.opacity(0.16)), in: Circle())
        .contentShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .scaleEffect(isHovering ? 1.07 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Jump to latest")
        .accessibilityLabel("Jump to latest message")
    }
}

/// Intermediate per-block descriptor used while flattening threads into rows.
/// Insets are filled in a second pass from row adjacency, then folded into the
/// final `PiAgentAppKitTranscriptItem` (`contentRevision` + `estimatedHeight`).
private struct PiAgentTranscriptBlockDescriptor {
    let id: String
    let view: AnyView
    /// Content hash WITHOUT insets — insets are folded in at materialize time.
    let baseRevision: Int
    /// Height estimate for the block content alone (insets added separately).
    let estimatedContentHeight: (CGFloat) -> CGFloat
    /// Thread id this block belongs to, or nil for chrome / plan / anchor rows.
    let threadID: String?
    /// True only for a thread's user-question block (drives the 10pt q↔reply gap).
    let isThreadQuestion: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
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
        // Rows are block-granular; inter-row spacing varies (question↔reply,
        // sibling, thread↔thread), so it's baked into each row as padding
        // rather than this uniform value. See `PiAgentAppKitTranscriptItem`.
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
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
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        // Pin the clip view to x = 0 so the transcript can never be panned
        // horizontally, even if a width desync transiently makes the document
        // view wider than the clip view during a resize or split-divider drag.
        let clipView = TranscriptClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
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
        // Persisted across session switches. Item IDs (thread UUIDs etc.) are
        // globally unique, so a revision recorded for one session never collides
        // with another. Keeping this means a revisited session detects content
        // that changed while it was off-screen and re-measures only those rows.
        private var contentRevisionByID: [String: Int] = [:]
        // Heights live in two caches:
        //  1. `measuredHeightByID` — precise heights reported by the OFFSCREEN
        //     measurement cell. Persisted across session switches (keyed by the
        //     stable item ID) so revisiting a session lays its rows out at exact
        //     heights with no reflow. Wiped wholesale on a width change; a single
        //     entry is dropped when that item's content revision changes.
        //  2. `estimateByID` — fast char-count estimates, used only until a row
        //     has a real measurement. Transient: dropped freely.
        // The offscreen measurement cell never touches live in-table cells, so it
        // can't be observed at the wrong size. `noteHeightOfRows` runs debounced
        // ~16ms when a measured height differs.
        private var measuredHeightByID: [String: CGFloat] = [:]
        private var estimateByID: [String: CGFloat] = [:]
        // LRU of live hosting views keyed by block id. Reattaching a warm host
        // when a block scrolls back into view skips the SwiftUI graph rebuild.
        // Bounded so a long transcript can't grow memory without limit. The
        // offscreen measurement cell keeps its OWN host, never from this cache.
        private var hostCache: [String: CachedHost] = [:]
        private var hostLRU: [String] = []
        private let hostCacheCapacity = 64
        private var pendingHeightIDs = Set<String>()
        private var pendingHeightWork: DispatchWorkItem?
        private var pendingScrollWork: DispatchWorkItem?
        private var pendingSettleScrollWork: DispatchWorkItem?
        private var pendingRemeasureWork: DispatchWorkItem?
        private var pendingScrollSettle = false
        private var pendingWidthWork: DispatchWorkItem?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var lastPinnedState = true
        private var isProgrammaticScroll = false
        // True while the user is actively scrolling — or just finished, within
        // the `liveScrollSettleDelay` window. Passive auto-follow and anchor
        // restoration are suppressed during this window so a streaming update
        // can never yank the viewport out from under a user gesture.
        private var isUserScrollingRecently = false
        private var liveScrollEndWork: DispatchWorkItem?
        private let liveScrollSettleDelay: TimeInterval = 0.35
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

        /// A cached live hosting view plus the (revision, width) its rootView
        /// was last built for — so `hostFor` only rebuilds when something changed.
        private struct CachedHost {
            let host: NSHostingView<AnyView>
            var revision: Int
            var width: CGFloat
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
                // The live cell reports its own height once it has laid out —
                // the coordinator caches it and re-tiles the row. No offscreen
                // render: the cell had to lay out for display anyway.
                cell.onMeasuredHeight = { [weak self] itemID, height in
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
                    // Clip-view bounds change before the scrollView frame notification fires,
                    // so resync column width here to avoid a one-frame horizontal overflow
                    // when the inspector slides in or the window resizes.
                    self.updateColumnWidthIfNeeded()
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

            // Live-scroll notifications are the authoritative "user is driving
            // the scroll" signal — cleaner than inferring it from bounds
            // changes. While the user scrolls (and for a short settle window
            // after), auto-follow stays out of the way.
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveScrollEndWork?.cancel()
                    self.liveScrollEndWork = nil
                    self.isUserScrollingRecently = true
                }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveScrollEndWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        self?.liveScrollEndWork = nil
                        self?.isUserScrollingRecently = false
                    }
                    self.liveScrollEndWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.liveScrollSettleDelay, execute: work)
                }
            }
        }

        func invalidate() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
            if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
            pendingHeightWork?.cancel()
            pendingScrollWork?.cancel()
            pendingSettleScrollWork?.cancel()
            pendingRemeasureWork?.cancel()
            pendingWidthWork?.cancel()
            liveScrollEndWork?.cancel()
            hostCache.removeAll()
            hostLRU.removeAll()
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
                    // Measured heights and revisions are intentionally NOT dropped
                    // here — they persist so a return visit to this session reuses
                    // exact heights. Only the transient estimate and any in-flight
                    // height work for the now-absent row are cleared.
                    estimateByID.removeValue(forKey: id)
                    pendingHeightIDs.remove(id)
                }
                // Existing rows whose contentRevision changed need their cached heights
                // invalidated — heightOfRow falls back to the estimator until the cell
                // re-measures and reports back. The persisted revision map makes this
                // fire correctly for a session whose content changed while off-screen.
                for id in nextIDs {
                    if contentRevisionByID[id] != nil, contentRevisionByID[id] != nextRevisions[id] {
                        measuredHeightByID.removeValue(forKey: id)
                        estimateByID.removeValue(forKey: id)
                    }
                }
                orderedIDs = nextIDs
                for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
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
                for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
                if !changedIDs.isEmpty {
                    for id in changedIDs {
                        measuredHeightByID.removeValue(forKey: id)
                        estimateByID.removeValue(forKey: id)
                    }
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
            // Re-fit the table to the clip view so the document view shrinks
            // with it. Setting only the column width leaves the table's own
            // frame stale and wider than the visible area, which lets the
            // transcript be panned/cropped horizontally after a resize.
            tableView.sizeLastColumnToFit()

            // Heights are width-specific. Wipe both caches so heightOfRow falls back
            // to the estimator until cells re-measure for the new width.
            measuredHeightByID.removeAll()
            estimateByID.removeAll()

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
                measuredHeightByID.removeValue(forKey: id)
                estimateByID.removeValue(forKey: id)
                configure(cell, with: item, row: row)
            }
        }

        private func configure(_ cell: TranscriptTableCellView, with item: PiAgentAppKitTranscriptItem, row: Int) {
            let width = max(contentWidth, tableView?.tableColumns.first?.width ?? 200)
            // Hand the cell a coordinator-owned host — warm if this block was
            // seen recently, so scroll-back skips the SwiftUI graph rebuild.
            // The live cell never inflates; height comes from the offscreen cell.
            cell.install(host: hostFor(item, width: width), itemID: item.id, revision: item.contentRevision, width: width)
            // No measurement here — the cell reports its real height via
            // `onMeasuredHeight` once it lays out. Until then `heightOfRow`
            // serves the char-count estimate (or a cached real height).
        }

        /// Returns the (warm if cached) hosting view for a block, refreshing its
        /// rootView only when the revision or width actually changed.
        private func hostFor(_ item: PiAgentAppKitTranscriptItem, width: CGFloat) -> NSHostingView<AnyView> {
            if let index = hostLRU.firstIndex(of: item.id) {
                hostLRU.remove(at: index)
            }
            hostLRU.append(item.id)
            if var cached = hostCache[item.id] {
                if cached.revision != item.contentRevision || abs(cached.width - width) > 0.5 {
                    cached.host.rootView = TranscriptTableCellView.makeRoot(item: item, width: width)
                    cached.revision = item.contentRevision
                    cached.width = width
                    hostCache[item.id] = cached
                }
                return cached.host
            }
            let host = NSHostingView(rootView: TranscriptTableCellView.makeRoot(item: item, width: width))
            hostCache[item.id] = CachedHost(host: host, revision: item.contentRevision, width: width)
            evictHostsIfNeeded()
            return host
        }

        /// Drop least-recently-used hosts past capacity. The LRU front is the
        /// oldest — far off-screen — so evicting it can't blank a visible row
        /// (capacity ≫ visible row count).
        private func evictHostsIfNeeded() {
            while hostLRU.count > hostCacheCapacity {
                let evicted = hostLRU.removeFirst()
                hostCache[evicted]?.host.removeFromSuperview()
                hostCache.removeValue(forKey: evicted)
            }
        }

        /// Called by a live cell once it has laid out, with the SwiftUI
        /// content's intrinsic height. Updates the cache and (debounced) tells
        /// the table to re-tile the row when the height actually changed.
        func reportMeasuredHeight(_ rawHeight: CGFloat, forItemID itemID: String) {
            let height = ceil(rawHeight)
            let existing = measuredHeightByID[itemID]
            measuredHeightByID[itemID] = height
            estimateByID.removeValue(forKey: itemID)
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
            // Suppress implicit Core Animation actions so a streaming row's
            // height change re-tiles instantly with no per-token animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            CATransaction.commit()
            NSAnimationContext.endGrouping()
            if wasPinned && !isUserScrollingRecently {
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
            // Don't restore over a live user gesture — let their scroll stand.
            guard !isUserScrollingRecently else { return }
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
                // An explicit request (send, jump-to-latest) or a session
                // switch always wins — the user isn't fighting it.
                scrollToBottom(settle: true)
            } else if wasPinned && !isUserScrollingRecently {
                // Passive streaming follow — but never while the user is
                // actively scrolling, or it would yank the viewport.
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
            // Prefer a real measurement — it survives session switches, so a
            // revisited row lays out at its exact height with no reflow.
            if let measured = measuredHeightByID[id] { return measured }
            if let estimate = estimateByID[id] { return estimate }
            // No measurement yet — use the item's fast estimator so the table can lay
            // the row out close to its natural size without triggering a SwiftUI pass.
            // The cell measures precisely as it renders and reports back via
            // reportMeasuredHeight, at which point this row gets re-tiled.
            if let item = itemByID[id] {
                let est = item.estimatedHeight(contentWidth)
                estimateByID[id] = est
                return est
            }
            return estimatedRowHeight
        }
    }

    /// Clip view for the transcript scroll view. The transcript never scrolls
    /// horizontally, so the bounds origin is pinned to x = 0 — this guarantees
    /// the content can't be panned sideways even if the document view is
    /// transiently wider than the clip view during a resize or divider drag.
    final class TranscriptClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            rect.origin.x = 0
            return rect
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
        fileprivate var hostingView: NSHostingView<AnyView>?
        fileprivate var configuredItemID: String?
        private var configuredRevision: Int?
        fileprivate var configuredWidth: CGFloat = 0
        fileprivate var lastIntrinsicHeight: CGFloat = -1

        /// Wired by the coordinator at cell-vend time. Reports this row's true
        /// height — the hosted SwiftUI content's intrinsic size — whenever it
        /// changes. The cell already laid out to display, so reading its size
        /// is essentially free; there is no second offscreen render.
        var onMeasuredHeight: ((String, CGFloat) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Builds the SwiftUI root for an item at a width. Row spacing is baked
        /// in as padding here — the card view itself stays byte-identical, and
        /// `fittingSize` picks the inset up so `heightOfRow` stays consistent.
        /// Shared by the live host cache and the offscreen measurement path.
        static func makeRoot(item: PiAgentAppKitTranscriptItem, width: CGFloat) -> AnyView {
            AnyView(
                item.view
                    .frame(width: width, alignment: .topLeading)
                    .padding(.top, item.topInset)
                    .padding(.bottom, item.bottomInset)
                    .environment(\.transcriptContentWidth, width)
            )
        }

        private func pinToEdges(_ host: NSHostingView<AnyView>) {
            host.translatesAutoresizingMaskIntoConstraints = false
            host.setContentHuggingPriority(.defaultLow, for: .horizontal)
            host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        /// Live-cell path: display a coordinator-owned (often warm) hosting
        /// view. Reattaching a cached host skips the whole SwiftUI graph
        /// rebuild — that's what makes scroll-back cheap. A given block id is
        /// shown by at most one cell at a time, so a host is never contended.
        func install(host: NSHostingView<AnyView>, itemID: String, revision: Int, width: CGFloat) {
            if hostingView !== host {
                hostingView?.removeFromSuperview()
                host.removeFromSuperview()   // defensive: detach from any prior cell
                pinToEdges(host)
                hostingView = host
                lastIntrinsicHeight = -1
            } else if configuredItemID != itemID {
                lastIntrinsicHeight = -1
            }
            configuredItemID = itemID
            configuredRevision = revision
            configuredWidth = width
        }

        /// AppKit's per-pass layout hook — also where the row reports its
        /// height. The cell already laid out to display, so reading the hosted
        /// content's intrinsic size costs nothing extra; whenever it drifts we
        /// hand the coordinator the new height and it re-tiles the row. This is
        /// the only measurement path — there is no separate offscreen render.
        override func layout() {
            super.layout()
            guard let itemID = configuredItemID,
                  let hostingView,
                  configuredWidth > 1 else { return }
            let intrinsic = hostingView.intrinsicContentSize.height
            guard intrinsic > 0, intrinsic.isFinite,
                  abs(intrinsic - lastIntrinsicHeight) > 0.5 else { return }
            lastIntrinsicHeight = intrinsic
            onMeasuredHeight?(itemID, intrinsic)
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
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
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
    @State private var composerIssueAttachment: PiAgentIssueAttachment?
    @State private var composerAttachmentError: String?
    @State private var composerHistoryIndex: Int?
    @State private var composerHistoryDraft = ""
    @State private var selectedSubagentTranscriptRunID: UUID?
    @State private var selectedSubagentGraphRunID: UUID?
    @StateObject private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var transcriptBottomScrollRequest = 0
    @State private var transcriptIsPinnedToBottom = true
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
                        .scrollIndicators(.never)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .hideNativeScrollers()
                        .animation(.snappy(duration: 0.24), value: visibleSessionIDs)
                        .bottomEdgeFade(height: 34)
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
            ZStack(alignment: .bottomTrailing) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .transcriptEdgeFade()

                // Sits ON TOP of the edge fade (added after it) so the pill
                // itself is never faded out.
                if !transcriptIsPinnedToBottom {
                    JumpToLatestPill { requestTranscriptBottomScroll() }
                        .padding(.trailing, 22)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: transcriptIsPinnedToBottom)

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
        let contextRevision = appKitTranscriptThreadContextRevision(snapshot: timelineSnapshot)
        let visibility = viewModel.appSettings.piAgentTranscriptVisibility
        let skills = visibleSkillsForSelectedSession
        let projectPath = store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
        let subagentRuns = nativeSubagentRunsByID

        var descriptors: [PiAgentTranscriptBlockDescriptor] = []

        // --- Chrome rows (each its own revision) ---
        if let session = store.selectedSession {
            if visibility.showShortcutsStrip {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "shortcuts-strip-\(session.id.uuidString)",
                    view: AnyView(PiAgentShortcutsStrip()),
                    baseRevision: 0,
                    estimatedContentHeight: { _ in 40 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            if let finalSystemPrompt = session.finalSystemPrompt {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "system-prompt-\(session.id.uuidString)",
                    view: AnyView(PiAgentSystemPromptAuditCard(title: "Final System Prompt", subtitle: "", prompt: finalSystemPrompt)),
                    baseRevision: finalSystemPrompt.hashValue,
                    estimatedContentHeight: { _ in 80 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            for request in store.supervisorRequests(for: session.id).filter({ $0.status == .pending }) {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "supervisor-request-\(request.id)",
                    view: AnyView(PiSubagentSupervisorRequestCard(
                        request: request,
                        onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: session.id, response: response) },
                        onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: session.id) }
                    )),
                    baseRevision: request.hashValue,
                    estimatedContentHeight: { _ in 180 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
        }

        if let archive = timelineSnapshot.preCompactionArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.compactedAt)
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pre-compaction-archive",
                view: AnyView(preCompactionArchiveCard(archive)),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }
        if let archive = timelineSnapshot.recentWindowArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.limit)
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "recent-window-archive",
                view: AnyView(recentWindowArchiveCard(archive)),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }

        // --- Timeline rows: each thread flattens into one row per block ---
        if store.isSelectedTranscriptLoading && timelineItems.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: AnyView(loadingTranscriptCard),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 80 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else if timelineItems.isEmpty && descriptors.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: AnyView(emptyTranscriptCard),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 120 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else {
            for item in timelineItems {
                switch item.kind {
                case let .thread(thread):
                    if let question = thread.question {
                        let blockID = "q-\(item.id)"
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: blockID,
                            view: AnyView(threadBlockCard(
                                thread: thread, visibility: visibility, skills: skills,
                                projectPath: projectPath, subagentRuns: subagentRuns,
                                renderMode: .question, blockID: blockID
                            )),
                            baseRevision: appKitQuestionBlockRevision(question, contextRevision: contextRevision),
                            estimatedContentHeight: { Self.estimatedQuestionHeight(question, width: $0) },
                            threadID: item.id,
                            isThreadQuestion: true
                        ))
                    }
                    for child in PiAgentTranscriptThreadCard.visibleChildren(
                        of: thread, visibility: visibility, nativeSubagentRunsByID: subagentRuns
                    ) {
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: child.id,
                            view: AnyView(threadBlockCard(
                                thread: thread, visibility: visibility, skills: skills,
                                projectPath: projectPath, subagentRuns: subagentRuns,
                                renderMode: .child(child), blockID: child.id
                            )),
                            baseRevision: appKitChildBlockRevision(child, contextRevision: contextRevision),
                            estimatedContentHeight: { Self.estimatedChildHeight(child, width: $0) },
                            threadID: item.id,
                            isThreadQuestion: false
                        ))
                    }
                case let .plan(event):
                    descriptors.append(PiAgentTranscriptBlockDescriptor(
                        id: item.id,
                        view: AnyView(PiAgentCurrentPlanCard(event: event).id(item.id)),
                        baseRevision: appKitTranscriptContentRevision(for: item, snapshot: timelineSnapshot, contextRevision: contextRevision),
                        estimatedContentHeight: { _ in 120 },
                        threadID: nil,
                        isThreadQuestion: false
                    ))
                }
            }
        }

        // Bottom anchor — a 1pt row scrollToBottom can always land on.
        descriptors.append(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-bottom-anchor",
            view: AnyView(Color.clear.frame(height: 1)),
            baseRevision: 0,
            estimatedContentHeight: { _ in 1 },
            threadID: nil,
            isThreadQuestion: false
        ))

        // --- Inset pass: NSTableView intercell spacing is uniform, so split
        // each inter-row gap in half across the two adjacent rows. Gaps:
        // question↔reply 10, sibling children 8, everything else 12. ---
        if descriptors.count > 1 {
            for i in 0 ..< descriptors.count - 1 {
                let gap: CGFloat
                if let tid = descriptors[i].threadID, tid == descriptors[i + 1].threadID {
                    gap = descriptors[i].isThreadQuestion ? 10 : 8
                } else {
                    gap = 12
                }
                descriptors[i].bottomInset += gap / 2
                descriptors[i + 1].topInset += gap / 2
            }
        }

        // --- Materialize: fold insets into the revision (so an inset change
        // re-tiles the row) and into the height estimate. ---
        return descriptors.map { descriptor in
            var revisionHasher = Hasher()
            revisionHasher.combine(descriptor.baseRevision)
            revisionHasher.combine(descriptor.topInset)
            revisionHasher.combine(descriptor.bottomInset)
            let topInset = descriptor.topInset
            let bottomInset = descriptor.bottomInset
            let contentEstimate = descriptor.estimatedContentHeight
            return PiAgentAppKitTranscriptItem(
                id: descriptor.id,
                view: descriptor.view,
                contentRevision: revisionHasher.finalize(),
                topInset: topInset,
                bottomInset: bottomInset,
                estimatedHeight: { width in contentEstimate(width) + topInset + bottomInset }
            )
        }
    }

    /// Builds one block of a thread (question or a single child) as its own
    /// row view, via `PiAgentTranscriptThreadCard`'s `renderMode` — the card
    /// view is byte-identical to the full-thread rendering, just sliced to one
    /// `ThreadMessageRow`.
    private func threadBlockCard(
        thread: PiAgentTranscriptThread,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        projectPath: String?,
        subagentRuns: [UUID: PiSubagentRunRecord],
        renderMode: PiAgentTranscriptThreadCard.RenderMode,
        blockID: String
    ) -> some View {
        PiAgentTranscriptThreadCard(
            thread: thread,
            visibility: visibility,
            skills: skills,
            projectPath: projectPath,
            nativeSubagentRunsByID: subagentRuns,
            nativeSubagentCard: nativeSubagentCard,
            renderMode: renderMode
        )
        .id(blockID)
    }

    /// Per-block height estimators — character-count math, no SwiftUI pass.
    /// Mirror the heights the old per-thread estimator summed per child.
    private static func estimatedQuestionHeight(_ entry: PiAgentTranscriptEntry, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
        return CGFloat(lines) * 18 + 56
    }

    private static func estimatedChildHeight(_ child: PiAgentThreadChild, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        switch child {
        case let .assistant(entry), let .steering(entry), let .thinking(entry):
            let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
            return CGFloat(min(lines, 40)) * 18 + 48
        case .toolGroup:
            return 48
        case .status, .error, .retry:
            return 56
        }
    }

    /// Content revision for a question block — only that entry + context.
    private func appKitQuestionBlockRevision(_ entry: PiAgentTranscriptEntry, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hashEntryRevision(entry, into: &hasher)
        return hasher.finalize()
    }

    /// Content revision for a child block — only that child's entry/entries +
    /// context. A sibling streaming does not bump this, so only the streaming
    /// block's row reconfigures.
    private func appKitChildBlockRevision(_ child: PiAgentThreadChild, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        switch child {
        case let .steering(entry), let .thinking(entry), let .assistant(entry),
             let .status(entry), let .error(entry):
            hashEntryRevision(entry, into: &hasher)
        case let .retry(entry, _):
            hashEntryRevision(entry, into: &hasher)
        case let .toolGroup(group):
            hasher.combine(group.id)
            for entry in group.entries { hashEntryRevision(entry, into: &hasher) }
            for activity in group.activities {
                hasher.combine(activity.id)
                hasher.combine(activity.entries.count)
                hashEntryRevision(activity.representativeEntry, into: &hasher)
            }
        }
        return hasher.finalize()
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
            let signature = cheapThreadSignature(thread, contextRevision: contextRevision)
            return transcriptCache.cachedThreadRevision(for: thread.id, signature: signature) {
                var hasher = Hasher()
                hasher.combine(contextRevision)
                hashThreadRevision(thread, into: &hasher)
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
        contextRevision: Int
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
            recentWindowArchive: recentWindowArchive
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

            ScrollView(showsIndicators: false) {
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
                nativeSubagentRunsByID: nativeSubagentRunsByID,
                nativeSubagentCard: nativeSubagentCard
            )
            .id(item.id)
        case let .plan(event):
            PiAgentCurrentPlanCard(event: event)
                .id(item.id)
        }
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

        // The RPC-derived activity knows exactly what Pi is doing this instant —
        // it distinguishes a running tool from a finished one and reasoning from
        // an empty turn-start placeholder, neither of which the transcript can.
        if let activity = store.processingActivity(for: session.id) {
            return processingMessage(for: activity)
        }

        // Fallback for a session that is active but has no live activity yet
        // (e.g. just reattached): infer from the last transcript entry.
        if let lastEntry = store.selectedTranscript.last {
            return processingMessage(after: lastEntry)
        }
        return "Working"
    }

    private func processingMessage(for activity: PiAgentProcessingActivity) -> String {
        switch activity {
        case .preparing: return "Preparing response"
        case .reasoning: return "Reasoning"
        case .responding: return "Writing response"
        case let .runningTool(toolName, detail): return toolProcessingMessage(forToolName: toolName, detail: detail)
        case .awaitingModel: return "Working"
        }
    }

    private func processingMessage(after entry: PiAgentTranscriptEntry) -> String? {
        switch entry.role {
        case .assistant:
            return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing response" : "Writing response"
        case .error, .stderr:
            return "Working"
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
            return "Working"
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
        return toolProcessingMessage(forToolName: toolName)
    }

    /// Turns a raw Pi tool name (and, when available, its target) into a
    /// human phrase: `edit` + `PiAgentViews.swift` → "Editing PiAgentViews.swift".
    /// Unknown tools fall back to their de-underscored name so a new Pi tool
    /// still reads acceptably without a code change.
    private func toolProcessingMessage(forToolName toolName: String, detail: String? = nil) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        switch name {
        case "bash": return target.map { "Running \($0)" } ?? "Running a command"
        case "read": return target.map { "Reading \($0)" } ?? "Reading a file"
        case "edit": return target.map { "Editing \($0)" } ?? "Editing a file"
        case "write": return target.map { "Writing \($0)" } ?? "Writing a file"
        case "web_search": return target.map { "Searching the web for \($0)" } ?? "Searching the web"
        case "code_search": return target.map { "Searching the code for \($0)" } ?? "Searching the code"
        case "get_search_content", "fetch_content": return "Fetching a page"
        case "update_session_plan", "set_session_plan": return "Updating the plan"
        case "managed_subagent": return "Starting subagent"
        case "managed_parallel": return "Starting parallel agents"
        case "ask_user": return "Waiting for your input"
        case "agent_deck_memory_write", "agent_deck_memory_mark_stale": return "Updating memory"
        case "list_supervisor_requests", "answer_supervisor_request": return "Coordinating subagents"
        case "": return "Running tool"
        default: return "Running \(name.replacingOccurrences(of: "_", with: " "))"
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

        // Hydrate the selected transcript before updating the render cache. Small
        // transcripts decode synchronously here (instant, no spinner); large ones are
        // handed to the background loader and return an empty snapshot so the
        // "Loading transcript" card shows instead of hitching the main thread.
        let entries = store.transcriptForCacheUpdate(session.id)
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
        VStack(spacing: 6) {
            if hasComposerSuggestions {
                PiAgentCommandSuggestions(
                    items: composerSuggestionItems,
                    selectedIndex: composerSuggestionIndex,
                    scrollTick: composerSuggestionScrollTick,
                    onSelect: { item in insertComposerSuggestion(item.insertion) },
                    onHover: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil else { return }
                        composerSuggestionIndex = index
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            PiAgentComposerBox(
                text: $composerText,
                pasteAttachments: $composerPasteAttachments,
                nextPasteID: $nextComposerPasteID,
                images: $composerImages,
                files: $composerFiles,
                folders: $composerFolders,
                issueAttachment: $composerIssueAttachment,
                attachmentError: $composerAttachmentError,
                inputMode: $inputMode,
                isRunning: isRunning,
                isDisabled: isCompacting,
                placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Ask Pi to implement, inspect, explain, or fix…")),
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil),
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
                onClear: clearComposerInput,
                suggestionKeyBridge: composerSuggestionKeyBridge
            )
        }
        .animation(.easeOut(duration: 0.12), value: hasComposerSuggestions)
        .onChange(of: composerText) { _, _ in
            composerSuggestionIndex = 0
            composerSuggestionsDismissed = false
            composerSuggestionScrollTick += 1
            composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            refreshFileSuggestions()
        }
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

    private var composerSuggestionItems: [ComposerSuggestionItem] {
        ComposerSuggestionItem.build(commands: slashSuggestions, skills: skillSlashSuggestions, files: fileSuggestions)
    }

    private var hasComposerSuggestions: Bool {
        !composerSuggestionsDismissed && !composerSuggestionItems.isEmpty
    }

    private var composerSuggestionKeyBridge: ComposerSuggestionKeyBridge {
        ComposerSuggestionKeyBridge(
            isActive: hasComposerSuggestions,
            onMove: { delta in
                let count = composerSuggestionItems.count
                guard count > 0 else { return }
                composerSuggestionIndex = min(max(composerSuggestionIndex + delta, 0), count - 1)
                composerSuggestionScrollTick += 1
                // Ignore hover briefly so the scroll sliding rows under a
                // stationary pointer can't hijack the keyboard selection.
                composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            },
            onAccept: { acceptComposerSuggestion() },
            onDismiss: { composerSuggestionsDismissed = true }
        )
    }

    private func acceptComposerSuggestion() -> Bool {
        let items = composerSuggestionItems
        guard items.indices.contains(composerSuggestionIndex) else { return false }
        insertComposerSuggestion(items[composerSuggestionIndex].insertion)
        return true
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
        guard case .file = composerSuggestionTrigger else { return [] }
        return fileSuggestionResults
    }

    /// Re-scans `@`-file suggestions off the main thread, debounced. Called only
    /// when the composer text changes — never on hover or arrow-key navigation —
    /// so the filesystem walk never blocks typing or moving the highlight.
    private func refreshFileSuggestions() {
        fileScanTask?.cancel()
        guard let session = store.selectedSession,
              case let .file(query) = composerSuggestionTrigger else {
            fileScanTask = nil
            if !fileSuggestionResults.isEmpty { fileSuggestionResults = [] }
            return
        }
        let rootPath = session.worktreePath ?? session.projectPath
        fileScanTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                PiAgentFileSuggestion.scan(rootPath: rootPath, query: query)
            }.value
            guard !Task.isCancelled else { return }
            fileSuggestionResults = results
        }
    }

    private func insertComposerSuggestion(_ text: String) {
        replaceCurrentSuggestionToken(with: text)
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
            composerIssueAttachment = viewModel.consumePendingPiAgentIssueAttachment()
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
        composerIssueAttachment = nil
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
        composerIssueAttachment = nil
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
        let shouldSend = !expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil
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
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        beginTranscriptAutoScrollTurn()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, images: composerImages, pasteAttachments: activePasteAttachments, issueAttachment: composerIssueAttachment)
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
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerIssueAttachment: PiAgentIssueAttachment?
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

        VStack(spacing: 6) {
            if hasComposerSuggestions {
                PiAgentCommandSuggestions(
                    items: composerSuggestionItems,
                    selectedIndex: composerSuggestionIndex,
                    scrollTick: composerSuggestionScrollTick,
                    onSelect: { item in insertComposerSuggestion(item.insertion) },
                    onHover: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil else { return }
                        composerSuggestionIndex = index
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            PiAgentComposerBox(
                text: $composerText,
                pasteAttachments: $composerPasteAttachments,
                nextPasteID: $nextComposerPasteID,
                images: $composerImages,
                files: $composerFiles,
                folders: $composerFolders,
                issueAttachment: $composerIssueAttachment,
                attachmentError: $composerAttachmentError,
                inputMode: $inputMode,
                isRunning: isRunning,
                isDisabled: isCompacting,
                placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Ask Pi to implement, inspect, explain, or fix…")),
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil),
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
                onClear: clearComposerInput,
                suggestionKeyBridge: composerSuggestionKeyBridge
            )
        }
        .animation(.easeOut(duration: 0.12), value: hasComposerSuggestions)
        .onChange(of: composerText) { _, _ in
            composerSuggestionIndex = 0
            composerSuggestionsDismissed = false
            composerSuggestionScrollTick += 1
            composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            refreshFileSuggestions()
        }
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

    private var composerSuggestionItems: [ComposerSuggestionItem] {
        ComposerSuggestionItem.build(commands: slashSuggestions, skills: skillSlashSuggestions, files: fileSuggestions)
    }

    private var hasComposerSuggestions: Bool {
        !composerSuggestionsDismissed && !composerSuggestionItems.isEmpty
    }

    private var composerSuggestionKeyBridge: ComposerSuggestionKeyBridge {
        ComposerSuggestionKeyBridge(
            isActive: hasComposerSuggestions,
            onMove: { delta in
                let count = composerSuggestionItems.count
                guard count > 0 else { return }
                composerSuggestionIndex = min(max(composerSuggestionIndex + delta, 0), count - 1)
                composerSuggestionScrollTick += 1
                // Ignore hover briefly so the scroll sliding rows under a
                // stationary pointer can't hijack the keyboard selection.
                composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            },
            onAccept: { acceptComposerSuggestion() },
            onDismiss: { composerSuggestionsDismissed = true }
        )
    }

    private func acceptComposerSuggestion() -> Bool {
        let items = composerSuggestionItems
        guard items.indices.contains(composerSuggestionIndex) else { return false }
        insertComposerSuggestion(items[composerSuggestionIndex].insertion)
        return true
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
        guard case .file = composerSuggestionTrigger else { return [] }
        return fileSuggestionResults
    }

    /// Re-scans `@`-file suggestions off the main thread, debounced. Called only
    /// when the composer text changes — never on hover or arrow-key navigation —
    /// so the filesystem walk never blocks typing or moving the highlight.
    private func refreshFileSuggestions() {
        fileScanTask?.cancel()
        guard let session = store.selectedSession,
              case let .file(query) = composerSuggestionTrigger else {
            fileScanTask = nil
            if !fileSuggestionResults.isEmpty { fileSuggestionResults = [] }
            return
        }
        let rootPath = session.worktreePath ?? session.projectPath
        fileScanTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                PiAgentFileSuggestion.scan(rootPath: rootPath, query: query)
            }.value
            guard !Task.isCancelled else { return }
            fileSuggestionResults = results
        }
    }

    private func insertComposerSuggestion(_ text: String) {
        replaceCurrentSuggestionToken(with: text)
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
            composerIssueAttachment = viewModel.consumePendingPiAgentIssueAttachment()
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
        composerIssueAttachment = nil
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
        composerIssueAttachment = nil
        composerAttachmentError = nil
    }

    private func createSessionFromComposer() {
        createSessionFromComposer(for: nil)
    }

    private func createSessionFromComposer(for project: DiscoveredProject?) {
        guard store.selectedSession == nil else { return }
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        let shouldSend = !expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil
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
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        onWillSend()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, images: composerImages, pasteAttachments: activePasteAttachments, issueAttachment: composerIssueAttachment)
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
