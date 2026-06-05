import AppKit
import Combine
import os
import QuartzCore
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
                || entry.agentMemoryEvent != nil
                || entry.title == "Compaction"
                || entry.title == "Retry"
                || entry.title == "Subagent Started"
                || PiAgentGitEventKind.from(title: entry.title) != nil
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

/// How a transcript row is rendered. Every row is now fully native AppKit (no
/// per-row SwiftUI / `NSHostingView`); the spec knows how to build/configure/
/// measure the concrete view.
enum PiAgentTranscriptCellKind {
    case native(NativeRowSpec)
}

extension PiAgentTranscriptCellKind {
    /// Convenience for a native message bubble.
    static func bubble(_ payload: NativeBubblePayload) -> PiAgentTranscriptCellKind {
        .native(.of(PiAgentNativeBubbleView.self) { view, width in
            view.configure(payload: payload, width: width)
        })
    }
}

private struct PiAgentAppKitTranscriptItem {
    let id: String
    let kind: PiAgentTranscriptCellKind
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
        kind: PiAgentTranscriptCellKind,
        contentRevision: Int = 0,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        estimatedHeight: @escaping (CGFloat) -> CGFloat = { _ in 120 }
    ) {
        self.id = id
        self.kind = kind
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
                .font(AppTheme.Font.footnote.weight(.bold))
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
    /// Legacy SwiftUI content for hosted rows. `nil` when `kind` is native.
    let view: AnyView?
    /// Native render kind; `nil` falls back to hosting `view`.
    var kind: PiAgentTranscriptCellKind? = nil
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

/// The transcript-rendering unit, deliberately split out from `PiAgentScreen` so
/// that it — and only it — observes `PiAgentTranscriptRenderCache`. The render
/// cache pulses `streamingRevision` ~30Hz during streaming; isolating the
/// subscription here keeps that pulse from re-evaluating the screen's session
/// list and composer (see the `@State transcriptCache` note in `PiAgentScreen`).
///
/// `makeItems` is supplied by the parent and re-run on every pulse. It reads the
/// live cache (`threads`) and parent references (`store`/`viewModel`), so the
/// rebuilt items reflect the latest streamed content even though the parent view
/// struct captured in the closure isn't itself re-evaluated between pulses.
private struct PiAgentTranscriptHost: View {
    @ObservedObject var cache: PiAgentTranscriptRenderCache
    let sessionID: UUID?
    let bottomScrollRequest: Int
    let makeItems: () -> [PiAgentAppKitTranscriptItem]
    let onPinnedToBottomChange: (Bool) -> Void
    let onBenchAdvanceSession: () -> Void
    let benchSessionCount: () -> Int

    var body: some View {
        PiAgentAppKitTranscriptView(
            items: makeItems(),
            sessionID: sessionID,
            renderRevision: cache.renderRevision,
            streamingRevision: cache.streamingRevision,
            autoScrollTurnRevision: cache.autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest,
            onPinnedToBottomChange: onPinnedToBottomChange,
            onBenchAdvanceSession: onBenchAdvanceSession,
            benchSessionCount: benchSessionCount
        )
    }
}

private struct PiAgentAppKitTranscriptView: NSViewRepresentable {
    let items: [PiAgentAppKitTranscriptItem]
    let sessionID: UUID?
    let renderRevision: Int
    let streamingRevision: Int
    let autoScrollTurnRevision: Int
    let bottomScrollRequest: Int
    let onPinnedToBottomChange: (Bool) -> Void
    /// Advance selection to the next session (the ⌘] action). Used only by the
    /// scroll benchmark to sweep multiple chats; nil disables multi-session.
    var onBenchAdvanceSession: (() -> Void)?
    var benchSessionCount: (() -> Int)?

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
        // The default `.automatic` style resolves to `.inset`, which adds a
        // system horizontal margin (~16pt) to every cell. That pushed all rows
        // inboard of the composer (which lives outside the table). `.plain`
        // removes the inset so a cell pinned at x=0 lines up with the composer's
        // container edge. Row-internal padding is handled per-block instead.
        tableView.style = .plain

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
        // Inset the resting content just into the tail of the top edge fade so
        // the first row — the shortcuts strip, or the earliest message — lands
        // where the gradient has already gone (near-)opaque, instead of half-
        // dissolved into it. A touch less than the full 28pt fade height keeps
        // the row snug to the fade's end with no dead gap. Content still fades
        // normally as it scrolls up under the toolbar; a top inset leaves the
        // bottom-pinning math (documentHeight − clipHeight) untouched.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 18, left: 0, bottom: 0, right: 0)

        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.onBenchAdvanceSession = onBenchAdvanceSession
        context.coordinator.benchSessionCount = benchSessionCount
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
        TranscriptScrollProfiler.measureBody("updateNSView") {
            let coordinator = context.coordinator
            coordinator.onPinnedToBottomChange = onPinnedToBottomChange
            coordinator.onBenchAdvanceSession = onBenchAdvanceSession
            coordinator.benchSessionCount = benchSessionCount
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
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {
        weak var scrollView: NSScrollView?
        weak var tableView: NSTableView?
        private var dataSource: NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>?

        let profiler = TranscriptScrollProfiler()

        // MARK: Scroll benchmark (autonomous, multi-session validation)
        // Gated by `defaults write streetcoding.agent-deck ScrollBenchEnabled -bool YES`.
        // When on, it sweeps several content-bearing chats in turn — for each it
        // runs a SHORT scroll burst (local up/down) then a LONG full top↔bottom
        // sweep, then advances to the next session via the same path as the ⌘]
        // shortcut. Each pass is bracketed as a profiler "gesture" tagged with the
        // session + phase, so one run produces a comparable per-session report you
        // can diff across builds to see when the jank fix actually lands. Programmatic
        // scrolls exercise the real cell-vend + sizeThatFits + layout path (synthetic
        // OS scroll events are blocked by TCC).
        private var benchTimer: Timer?
        private var benchStart: CFTimeInterval = 0
        private var benchDir: CGFloat = -1
        private let benchStepPoints: CGFloat = 36

        /// Switch selection to the next session (wired by the screen to
        /// `viewModel.selectNextPiAgentSession()` — the ⌘] action). Returns
        /// selection control to SwiftUI, which re-vends the transcript and lands
        /// back in `apply()`, where the bench state machine resumes.
        var onBenchAdvanceSession: (() -> Void)?
        /// Total sessions in the current project's scope — sizes the run.
        var benchSessionCount: (() -> Int)?

        private enum BenchPhase { case idle, settling, shortScroll, longScroll, advancing }
        private var benchActive = false
        private var benchStarted = false
        private var benchPhase: BenchPhase = .idle
        private var benchTargetSessions = 0
        private var benchScopedCount = 0
        private var benchSessionsTested = 0
        private var benchVisitedSessionIDs: Set<UUID> = []
        /// Every session the sweep has landed on (tested or skipped) — lets the
        /// run stop after one full lap of the list even if some are empty drafts.
        private var benchSeenIDs: Set<UUID> = []
        /// Hard stop on advances so a project with fewer content-bearing sessions
        /// than the target can never loop forever wrapping the list.
        private var benchAdvanceBudget = 0
        private let benchMaxSessions = 6
        private let benchShortDuration: CFTimeInterval = 2.5
        private let benchLongDuration: CFTimeInterval = 7
        /// Long full-sweeps run back-to-back per session: repeated traversals are
        /// far more likely to surface a hang/hitch than a single pass (the first
        /// pass warms caches; a stall that survives into passes 2–3 is the real
        /// jank). Each pass is its own profiler gesture, so each gets a summary
        /// and can trip the hitch backtrace independently.
        private let benchLongRepeats = 3

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
        //  1. `measuredHeightByID` — precise heights reported by a live cell once
        //     it has laid out, keyed [block id → width bucket → height]. The
        //     width key means a width change just
        //     selects a different bucket instead of wiping every height — so a
        //     row measured once at a given width keeps its exact height forever,
        //     across width changes and session switches. A single block's entry
        //     is dropped when its content revision changes.
        //  2. `estimateByID` — fast char-count estimates, used only until a row
        //     has a real measurement. Transient: dropped freely.
        // `noteHeightOfRows` runs debounced ~16ms when a measured height differs.
        private var measuredHeightByID: [String: [Int: CGFloat]] = [:]
        private var estimateByID: [String: CGFloat] = [:]
        // What AppKit currently has each row laid out at — the baseline a fresh
        // measurement is compared against to decide whether a re-tile is needed.
        // Tracked separately from `measuredHeightByID` so a cache change that
        // doesn't actually change the laid-out height can't trigger a spurious
        private var lastNotedHeight: [String: CGFloat] = [:]
        private var pendingHeightIDs = Set<String>()
        private var pendingHeightWork: DispatchWorkItem?
        private var pendingScrollWork: DispatchWorkItem?
        private var pendingSettleScrollWork: DispatchWorkItem?
        private var pendingRemeasureWork: DispatchWorkItem?
        private var pendingScrollSettle = false
        private var pendingWidthWork: DispatchWorkItem?
        // Smooth auto-follow. The streaming follow doesn't snap to the bottom each
        // batch (that reads as a step every ~130ms); instead a 60fps timer eases
        // the clip origin toward the *current* bottom each frame, continuously
        // chasing the growing document so the motion is a glide. It disengages the
        // instant the user scrolls (checked per tick + on live-scroll start + on
        // any user-driven bounds change). Explicit scrolls (send, jump-to-latest,
        // session switch) still snap — see `performScrollToBottom(_:animated:)`.
        private var followGlideTimer: Timer?
        // Fraction of the remaining gap consumed per frame. Higher = snappier /
        // smaller trailing gap during fast streaming; lower = softer glide.
        private let followGlideFactor: CGFloat = 0.5
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var lastPinnedState = true
        // Auto-follow *intent*, distinct from the position-based `isPinnedToBottom`.
        // True = stick to the bottom as content streams. Only a user scroll changes
        // it (set from the resulting position) or an explicit jump/send/session
        // switch (set true). The follow decisions read this, NOT the live position,
        // so the smooth-glide trailing a little behind the bottom never causes the
        // follow to give up and leave the view parked below the latest content.
        private var isAutoFollowing = true
        private var isProgrammaticScroll = false
        // True between willStartLiveScroll / didEndLiveScroll — an authoritative
        // "user is driving the scroll" signal, but it only fires for trackpad
        // gestures and scroller-knob drags, not discrete mouse wheels.
        private var isLiveScrolling = false
        // CACurrentMediaTime of the most recent *user-driven* clip-bounds change,
        // stamped on every non-programmatic boundsDidChange. Bridges the gap left
        // by devices that post no live-scroll notification (mouse wheels) and
        // covers debounced cell measurements that land just after a gesture ends.
        private var lastUserScrollTime: CFTimeInterval = 0
        private let userScrollGraceWindow: CFTimeInterval = 0.35
        // True while the user is actively scrolling — or did within the grace
        // window. Passive auto-follow and anchor restoration stay out of the way
        // while this holds, so a streaming update can't yank the viewport out
        // from under a user gesture.
        private var isUserScrollingRecently: Bool {
            if isLiveScrolling { return true }
            return CACurrentMediaTime() - lastUserScrollTime < userScrollGraceWindow
        }
        private var contentWidth: CGFloat = 0
        // Bucket key for `measuredHeightByID`. Rounding to a whole point keeps
        // sub-pixel width jitter during a scroll from spilling into a new bucket.
        private var widthBucket: Int { Int(contentWidth.rounded()) }
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
            // queue: nil — synchronous delivery on the posting (main) thread.
            // Required so `isProgrammaticScroll` still reads true when the
            // notification for our own scroll mutation arrives: with queue:.main
            // the block runs a runloop tick later, after the flag is cleared,
            // and our self-induced bounds change would be mis-stamped as a user
            // scroll — pinning `isUserScrollingRecently` true and killing
            // streaming auto-follow.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView = self.scrollView else { return }
                    self.profiler.measureBoundsCallback {
                    if !self.isProgrammaticScroll {
                        // Authoritative user-scroll timestamp — covers mouse
                        // wheels and scroller drags that post no live-scroll
                        // notification at all.
                        self.lastUserScrollTime = CACurrentMediaTime()
                        self.profiler.userScrollTick()
                        // A genuine user-driven bounds change ends the auto-follow
                        // glide immediately (the glide's own scrolls set the
                        // programmatic flag, so they don't reach here).
                        self.stopFollowGlide()
                        // Re-evaluate follow intent from where the *user* left the
                        // viewport: at the bottom → keep following, scrolled away →
                        // stop. This is the ONLY place position decides intent —
                        // the auto-glide's own trailing never flips it, so a glide
                        // running a little behind the bottom can't disengage itself.
                        self.isAutoFollowing = self.isPinnedToBottom(scrollView)
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
                    self.publishPinnedState(self.isAutoFollowing)
                    }
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

            // Live-scroll notifications bracket trackpad gestures / scroller
            // drags. They miss discrete mouse wheels entirely — the timestamp
            // stamped in the bounds observer covers those, and the grace window
            // in `isUserScrollingRecently` covers the tail after a gesture ends.
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = true
                    self.profiler.gestureStart()
                    self.stopFollowGlide()
                    // The user grabbed the scroll — drop follow intent until they
                    // either land back at the bottom or jump to latest.
                    self.isAutoFollowing = false
                    self.publishPinnedState(false)
                }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = false
                    self.profiler.gestureEnd()
                    // Start the grace window from gesture end so a streaming
                    // update arriving right after release can't snap the view.
                    self.lastUserScrollTime = CACurrentMediaTime()
                }
            }
        }

        /// Removes the four NotificationCenter observers and cancels in-flight
        /// DispatchWorkItems. SwiftUI calls `dismantleNSView(_:coordinator:)`
        /// (defined above at `:501-503`) when the representable goes away,
        /// which invokes this — that is the documented teardown contract for
        /// `NSViewRepresentable`. We can't add a defensive `deinit` here under
        /// Swift 6 because `Coordinator` is MainActor-isolated and `deinit`
        /// runs in a nonisolated context.
        func invalidate() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
            if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
            boundsObserver = nil
            frameObserver = nil
            liveScrollStartObserver = nil
            liveScrollEndObserver = nil
            pendingHeightWork?.cancel()
            pendingScrollWork?.cancel()
            pendingSettleScrollWork?.cancel()
            pendingRemeasureWork?.cancel()
            pendingWidthWork?.cancel()
            stopFollowGlide()
        }

        func apply(
            items: [PiAgentAppKitTranscriptItem],
            sessionID: UUID?,
            renderRevision: Int,
            streamingRevision: Int,
            autoScrollTurnRevision: Int,
            bottomScrollRequest: Int
        ) {
            guard let tableView, scrollView != nil else { return }
            let wasFollowing = isAutoFollowing
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
                let anchor = (!isSessionSwitch && !explicitScroll && !wasFollowing) ? captureScrollAnchor() : nil
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
                // A changed row KEEPS its last measured height — the cell
                // re-renders and reports the new one via onMeasuredHeight.
                // heightOfRow must never drop a measured row back to the rough
                // char-count estimate, or every streaming token would jump the
                // row estimate↔measured (and a short estimate compounds the gap
                // to the bottom until auto-follow disengages). Only the
                // transient estimate is cleared, for never-measured rows.
                for id in nextIDs {
                    if contentRevisionByID[id] != nil, contentRevisionByID[id] != nextRevisions[id] {
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
                    self.handleScrollAfterUpdate(isSessionSwitch: isSessionSwitch, explicitScroll: explicitScroll, wasFollowing: wasFollowing)
                }
            } else {
                let changedIDs = nextIDs.filter { contentRevisionByID[$0] != nextRevisions[$0] }
                for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
                if !changedIDs.isEmpty {
                    // Keep the last measured height (see the idsChanged branch):
                    // the cell re-renders and reports the new height, so the
                    // streaming row grows real→real with no estimate jump.
                    for id in changedIDs {
                        estimateByID.removeValue(forKey: id)
                    }
                    reconfigureVisibleCellsForIDs(Set(changedIDs))
                    // Re-tile the changed rows synchronously, in this same pass.
                    // The cell was just handed taller content; if we wait for the
                    // debounced async measurement (~16ms) the row stays tiled at
                    // the old, shorter height in the meantime and the host —
                    // pinned to the cell — renders the new content squished into
                    // the old frame, then snaps when the re-tile lands. That
                    // squish→snap every token is the streaming bubble's up/down
                    // wobble. Measuring now and routing through the existing
                    // noteHeightsChanged keeps the follow/anchor behaviour intact;
                    // the later async report sees no height change and no-ops.
                    let retileIDs = profiler.measureForced { measureChangedCellsSynchronously(Set(changedIDs)) }
                    if !retileIDs.isEmpty {
                        flushPendingHeightWorkSynchronously()
                        noteHeightsChanged(forIDs: retileIDs)
                    }
                } else if streamingUpdate || structuralUpdate {
                    publishPinnedState(isAutoFollowing)
                }
                handleScrollAfterUpdate(isSessionSwitch: false, explicitScroll: explicitScroll, wasFollowing: wasFollowing)
            }

            self.sessionID = sessionID
            lastRenderRevision = renderRevision
            lastStreamingRevision = streamingRevision
            lastAutoScrollTurnRevision = autoScrollTurnRevision
            lastBottomScrollRequest = bottomScrollRequest
            tableView.sizeLastColumnToFit()
            maybeStartScrollBenchmark()
        }

        // MARK: - Scroll benchmark (multi-session)

        /// Entry point, called at the end of every `apply()`. Arms the run the
        /// first time a content-bearing transcript appears, and — once armed —
        /// drives the per-session continuation after each programmatic advance.
        private func maybeStartScrollBenchmark() {
#if DEBUG
            guard UserDefaults.standard.bool(forKey: "ScrollBenchEnabled") else { return }
            guard let tableView else { return }

            if !benchStarted {
                guard tableView.numberOfRows > 5 else { return }   // wait for real content
                benchStarted = true
                benchActive = true
                // Target the scoped session list (not just already-loaded ones —
                // selecting a session lazy-loads its transcript). Empty drafts are
                // skipped at runtime via the row-count guard below; `benchScopedCount`
                // + the advance budget guarantee the sweep terminates after one lap.
                benchScopedCount = benchSessionCount?() ?? 1
                benchTargetSessions = min(benchMaxSessions, max(1, benchScopedCount))
                benchAdvanceBudget = benchScopedCount + benchMaxSessions + 4
                if let id = sessionID { benchSeenIDs.insert(id) }
                TranscriptScrollProfiler.logger.info("SCROLLBENCH armed — sweeping up to \(self.benchTargetSessions) of \(self.benchScopedCount) session(s)")
                scheduleSessionRoutine()
                return
            }

            // Continuation: we just advanced and a new transcript settled in.
            guard benchActive, benchPhase == .advancing else { return }
            if let sessionID = self.sessionID { benchSeenIDs.insert(sessionID) }
            if let sessionID = self.sessionID,
               tableView.numberOfRows > 5,
               !benchVisitedSessionIDs.contains(sessionID) {
                scheduleSessionRoutine()
            } else {
                // Empty/draft or already-tested session — skip straight on.
                advanceOrFinish()
            }
#endif
        }

        /// Let the freshly-shown transcript settle (initial auto-scroll + first
        /// measures), then run its short+long routine.
        private func scheduleSessionRoutine() {
            benchPhase = .settling
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runSessionRoutine()
            }
        }

        private func runSessionRoutine() {
            guard benchActive, let sessionID = self.sessionID, let tableView else { return }
            benchVisitedSessionIDs.insert(sessionID)
            benchSessionsTested += 1
            let label = "S\(benchSessionsTested)/\(benchTargetSessions):\(sessionID.uuidString.prefix(8))"
            updateBenchFingerprint()
            TranscriptScrollProfiler.logger.info("SCROLLBENCH \(label, privacy: .public) rows=\(tableView.numberOfRows)")

            // Short burst: small local oscillation near current position.
            benchPhase = .shortScroll
            profiler.setBenchTag("\(label) short")
            runScrollPass(duration: benchShortDuration, step: 22) { [weak self] in
                guard let self, self.benchActive else { return }
                // Then several full top↔bottom sweeps back-to-back.
                self.benchPhase = .longScroll
                self.runLongPasses(label: label, remaining: self.benchLongRepeats) { [weak self] in
                    self?.profiler.setBenchTag(nil)
                    self?.advanceOrFinish()
                }
            }
        }

        /// Run `remaining` full top↔bottom sweeps back-to-back, each its own
        /// profiler gesture, then call `completion`.
        private func runLongPasses(label: String, remaining: Int, completion: @escaping @MainActor () -> Void) {
            guard benchActive, remaining > 0 else { completion(); return }
            let idx = benchLongRepeats - remaining + 1
            profiler.setBenchTag("\(label) long \(idx)/\(benchLongRepeats)")
            runScrollPass(duration: benchLongDuration, step: 48) { [weak self] in
                guard let self else { return }
                self.runLongPasses(label: label, remaining: remaining - 1, completion: completion)
            }
        }

        private func advanceOrFinish() {
            benchAdvanceBudget -= 1
            let sweptWholeList = benchSeenIDs.count >= benchScopedCount && benchScopedCount > 0
            if benchSessionsTested >= benchTargetSessions || sweptWholeList || benchAdvanceBudget <= 0 {
                benchActive = false
                benchPhase = .idle
                TranscriptScrollProfiler.logger.info("SCROLLBENCH COMPLETE — tested \(self.benchSessionsTested) session(s); see per-gesture summaries above")
                return
            }
            benchPhase = .advancing
            // Hand off to SwiftUI; the next session's transcript settles into
            // `apply()`, where `maybeStartScrollBenchmark` resumes the machine.
            onBenchAdvanceSession?()
        }

        /// Drive a programmatic scroll for `duration`, stepping `step` points per
        /// frame at ~120Hz and bouncing at the ends, then call `completion`. The
        /// whole pass is bracketed as one profiler gesture (its bounds changes are
        /// non-programmatic here, so they tick the profiler exactly like a real
        /// scroll, and a full SwiftUI cell layout is forced each frame).
        private func runScrollPass(duration: CFTimeInterval, step: CGFloat, completion: @escaping @MainActor () -> Void) {
            guard let scrollView, scrollView.documentView != nil else { completion(); return }
            benchTimer?.invalidate()
            benchStart = CACurrentMediaTime()
            benchDir = -1
            profiler.gestureStart()
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let sv = self.scrollView, let dv = sv.documentView else { return }
                    let now = CACurrentMediaTime()
                    let clip = sv.contentView
                    let maxY = max(0, dv.bounds.height - clip.bounds.height)
                    var y = clip.bounds.origin.y + self.benchDir * step
                    if y <= 0 { y = 0; self.benchDir = 1 }
                    else if y >= maxY { y = maxY; self.benchDir = -1 }
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(clip)
                    // Live scroll re-lays-out visible cells each frame; emulate that
                    // so the per-frame measure path is exercised, not just a reposition.
                    self.tableView?.layoutSubtreeIfNeeded()
                    if now - self.benchStart > duration {
                        self.benchTimer?.invalidate()
                        self.benchTimer = nil
                        self.profiler.gestureEnd()
                        completion()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            benchTimer = timer
        }

        /// Feed the profiler a coarse content fingerprint for the current session
        /// so each gesture summary records what was on screen (row count + how many
        /// rows are tall markdown/code) — the "why is *this* chat slow" signal.
        private func updateBenchFingerprint() {
            let width = currentViewportWidth()
            var tall = 0
            var totalEst: CGFloat = 0
            for item in items {
                let h = item.estimatedHeight(width)
                totalEst += h
                if h > 200 { tall += 1 }
            }
            profiler.setContentFingerprint(rows: items.count, tallRows: tall, totalEstHeight: totalEst)
        }

        private func applySnapshot(ids: [String], completion: @escaping () -> Void) {
            var snapshot = NSDiffableDataSourceSnapshot<PiAgentTranscriptTableSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(ids, toSection: .main)
            dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
        }

        func updateColumnWidthIfNeeded() {
            guard let tableView else { return }
            let width = currentViewportWidth()
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            tableView.tableColumns.first?.width = width
            // Re-fit the table to the clip view so the document view shrinks
            // with it. Setting only the column width leaves the table's own
            // frame stale and wider than the visible area, which lets the
            // transcript be panned/cropped horizontally after a resize.
            tableView.sizeLastColumnToFit()

            // Heights are width-specific, but `measuredHeightByID` is keyed by
            // width bucket — the new width simply selects (or starts) its own
            // bucket, so nothing is wiped. This is the fix for the scroll shake:
            // this method runs from the bounds observer on every scroll, and the
            // old `measuredHeightByID.removeAll()` meant any width recompute
            // (panel toggle, sub-pixel jitter) nuked every measured height and
            // forced a full estimate→measure→re-tile cascade. Only the transient
            // char-count estimates (not bucketed) are dropped.
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

        /// Force-lay-out the freshly-reconfigured visible cells for `ids` and
        /// write their true heights into `measuredHeightByID` synchronously, so a
        /// re-tile issued in this same pass uses the new content height. Returns
        /// the ids whose tiled height actually needs to change.
        private func measureChangedCellsSynchronously(_ ids: Set<String>) -> Set<String> {
            guard let tableView, !ids.isEmpty else { return [] }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return [] }
            var needRetile = Set<String>()
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard ids.contains(id),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                let h = cell.forcedIntrinsicHeight()
                guard h > 0 else { continue }
                let height = ceil(h)
                measuredHeightByID[id, default: [:]][widthBucket] = height
                if abs((lastNotedHeight[id] ?? -1) - height) > heightChangeEpsilon {
                    needRetile.insert(id)
                }
            }
            return needRetile
        }

        private func reconfigureAllVisibleCells() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                // Don't drop the measured height — it's width-bucketed, so the
                // new width's bucket fills in on its own as the cell re-measures
                // and reports. Only the transient estimate is cleared.
                estimateByID.removeValue(forKey: id)
                configure(cell, with: item, row: row)
            }
        }

        private func configure(_ cell: TranscriptTableCellView, with item: PiAgentAppKitTranscriptItem, row: Int) {
            let width = currentViewportWidth()
            // Each cell owns its own NSHostingView for its lifetime. Recycling
            // a cell for a new item just swaps the host's rootView — never
            // detaches the host. That's what keeps multiple visible cells from
            // ever contending for a single shared host (the bug fixed here).
            profiler.noteConfigure()
            cell.installRootView(item: item, width: width, profiler: profiler)
            // No measurement here — the cell reports its real height via
            // `onMeasuredHeight` once it lays out. Until then `heightOfRow`
            // serves the char-count estimate (or a cached real height).
        }

        private func currentViewportWidth() -> CGFloat {
            let viewportCandidates = [
                scrollView?.bounds.width,
                scrollView?.contentView.bounds.width,
                tableView?.enclosingScrollView?.bounds.width,
                tableView?.enclosingScrollView?.contentView.bounds.width
            ].compactMap { $0 }.filter { $0.isFinite && $0 > 1 }
            if let width = viewportCandidates.max() {
                return max(200, width)
            }

            let tableCandidates = [
                tableView?.visibleRect.width,
                tableView?.bounds.width,
                tableView?.tableColumns.first?.width
            ].compactMap { $0 }.filter { $0.isFinite && $0 > 1 }
            return max(200, tableCandidates.max() ?? contentWidth)
        }

        /// Called by a live cell once it has laid out, with the SwiftUI
        /// content's intrinsic height. Updates the cache and (debounced) tells
        /// the table to re-tile the row when the height actually changed.
        func reportMeasuredHeight(_ rawHeight: CGFloat, forItemID itemID: String) {
            let height = ceil(rawHeight)
            let bucket = widthBucket
            let priorMeasured = measuredHeightByID[itemID]?[bucket]
            measuredHeightByID[itemID, default: [:]][bucket] = height
            estimateByID.removeValue(forKey: itemID)
            // Re-tile only when AppKit's *laid-out* height is genuinely stale.
            // The baseline is what the table currently has tiled (lastNotedHeight),
            // not the cache — falling back to the prior measurement, then the
            // rough row estimate. Comparing against the cache would fire a
            // spurious noteHeightOfRows whenever the cache shifted without the
            // laid-out height actually changing.
            let baseline = lastNotedHeight[itemID] ?? priorMeasured ?? estimatedRowHeight
            let delta = abs(baseline - height)
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
            guard let tableView, scrollView != nil, !ids.isEmpty else { return }
            let wasFollowing = isAutoFollowing
            var rows = IndexSet()
            for id in ids {
                if let row = orderedIDs.firstIndex(of: id), row < tableView.numberOfRows {
                    rows.insert(row)
                    // Record what AppKit is about to lay this row out at — the
                    // baseline future measurements are compared against.
                    // reportMeasuredHeight already wrote the fresh height into
                    // measuredHeightByID before scheduling this call.
                    if let h = measuredHeightByID[id]?[widthBucket] { lastNotedHeight[id] = h }
                }
            }
            guard !rows.isEmpty else { return }
            // A row re-tiling to its true height shifts everything below it.
            // NSTableView pins row 0 to the document top, so a correction to any
            // row above the viewport yanks visible content out from under the
            // reader. Capture the top-visible row and restore its on-screen
            // offset right after the re-tile so the shift is absorbed silently.
            //
            // Preserve the anchor whenever we're not pinned — INCLUDING while the
            // user is actively scrolling. Scrolling up through history is exactly
            // when never-measured rows above the viewport first resolve from their
            // rough estimate to a real height (a +1000pt correction is common for a
            // long reply), and leaving those uncompensated is what makes the
            // transcript lurch under the reader. Restoring the top-visible row's
            // on-screen offset does NOT fight the gesture: capture and restore run
            // synchronously around `noteHeightOfRows` here (no stale anchor), and
            // `restoreScrollAnchor` self-guards — when the changed rows are at or
            // below the anchor row its minY is unchanged, so the target equals the
            // current origin and no scroll happens. The viewport only moves when a
            // row *above* the anchor reflowed, which is precisely the shift we want
            // to absorb. (Was previously gated on `!isUserScrollingRecently`, which
            // disabled compensation during the one gesture that needs it most.)
            // Every re-tile must compensate one way or the other: follow to the
            // bottom when auto-following, otherwise hold the top-visible anchor. The
            // one case that must NOT be left bare is "following but the user just
            // started scrolling" (wasFollowing && isUserScrollingRecently): autoFollow
            // is off (we don't yank a scrolling user to the bottom) so the anchor must
            // carry it, or the streaming row grows with nothing holding position.
            let willAutoFollow = wasFollowing && !isUserScrollingRecently
            let preserveAnchor = !willAutoFollow
            let anchor = preserveAnchor ? captureScrollAnchor() : nil
            profiler.measureRetile(rows: rows.count) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            // Suppress implicit Core Animation actions so a streaming row's
            // height change re-tiles instantly with no per-token animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Flag the whole re-tile as programmatic. `noteHeightOfRows` /
            // `layoutSubtreeIfNeeded` can nudge the clip origin by a sub-pixel as
            // AppKit re-lays the rows; that nudge posts a boundsDidChange, and if
            // the flag isn't set the observer mistakes it for a *user* scroll. On a
            // streaming row that fires every token, re-stamping `lastUserScrollTime`
            // continuously — which pins `isUserScrollingRecently` true and the
            // auto-follow off until the stream ends (a stray touch could leave the
            // view parked below the latest content for the rest of the response).
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            if let anchor {
                // rect(ofRow:) must see the new heights before we re-anchor.
                tableView.layoutSubtreeIfNeeded()
                restoreScrollAnchor(anchor)
            }
            isProgrammaticScroll = wasProgrammatic
            CATransaction.commit()
            NSAnimationContext.endGrouping()
            }
            if willAutoFollow {
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
            // (The height-change compensation path uses `restoreScrollAnchor`
            // directly, since there it must run *during* the gesture.)
            guard !isUserScrollingRecently, let anchor else { return }
            restoreScrollAnchor(anchor)
        }

        /// Re-scroll so `anchor`'s row sits at the same on-screen offset it had
        /// when the anchor was captured. Unlike `restoreScrollAnchorIfNeeded`,
        /// this runs even mid-gesture — it is the height-change compensation
        /// that keeps a row re-tile from shifting content under the user.
        private func restoreScrollAnchor(_ anchor: ScrollAnchor) {
            guard let tableView, let scrollView,
                  let row = orderedIDs.firstIndex(of: anchor.id),
                  row >= 0, row < tableView.numberOfRows,
                  let documentView = scrollView.documentView else { return }
            let rowRect = tableView.rect(ofRow: row)
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let targetY = min(max(0, rowRect.minY + anchor.offsetFromRowTop), maxY)
            let originY = scrollView.contentView.bounds.origin.y
            guard abs(originY - targetY) > 0.5 else { return }
            // Save/restore rather than force-false: this runs nested inside the
            // `noteHeightsChanged` re-tile, which holds the flag true around the
            // whole transaction. Clearing it here would unflag the rest of that
            // transaction's AppKit-driven origin nudges.
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = wasProgrammatic
        }

        private func handleScrollAfterUpdate(isSessionSwitch: Bool, explicitScroll: Bool, wasFollowing: Bool) {
            guard scrollView != nil else { return }
            if isSessionSwitch || explicitScroll {
                // An explicit request (send, jump-to-latest) or a session
                // switch always wins — the user isn't fighting it. Re-arm
                // follow intent so streaming after the jump keeps tracking.
                isAutoFollowing = true
                scrollToBottom(settle: true)
            } else if wasFollowing && !isUserScrollingRecently {
                // Passive streaming follow — but never while the user is
                // actively scrolling, or it would yank the viewport.
                scrollToBottom(settle: false)
            } else {
                publishPinnedState(isAutoFollowing)
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
                // Streaming follow (settle == false) glides; explicit / session
                // switch (settle == true) snaps.
                self.performScrollToBottom(scrollView, animated: !shouldSettle)
                guard shouldSettle else { return }
                self.pendingSettleScrollWork?.cancel()
                let settleWork = DispatchWorkItem { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    self.pendingSettleScrollWork = nil
                    // Don't force a re-measure here — pre-measurement and the synchronous
                    // height-work flush inside performScrollToBottom mean heights are already
                    // accurate. Re-measuring would risk a small secondary scroll jump.
                    self.performScrollToBottom(scrollView, animated: false)
                }
                self.pendingSettleScrollWork = settleWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settleWork)
            }
            pendingScrollWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func performScrollToBottom(_ scrollView: NSScrollView, animated: Bool) {
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
                stopFollowGlide()
                publishPinnedState(true)
                return
            }
            // Streaming follow: hand off to the glide timer, which eases toward the
            // (still-growing) bottom over the next frames instead of snapping.
            if animated {
                startFollowGlide()
                return
            }
            // Explicit / settle: snap immediately.
            stopFollowGlide()
            isProgrammaticScroll = true
            clipView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clipView)
            isProgrammaticScroll = false
            publishPinnedState(true)
        }

        /// Begin (or keep) easing the clip origin toward the document bottom each
        /// frame. Idempotent — if a glide is already running it simply continues
        /// and naturally picks up the new, larger bottom on its next tick.
        private func startFollowGlide() {
            guard followGlideTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    // self is nil only after the coordinator tore down, which
                    // invalidates this timer in `invalidate()`; nothing to do here.
                    self?.stepFollowGlide()
                }
            }
            // .common so the glide keeps ticking during resize / tracking runloop modes.
            RunLoop.main.add(timer, forMode: .common)
            followGlideTimer = timer
        }

        private func stepFollowGlide() {
            guard let scrollView, let documentView = scrollView.documentView else {
                stopFollowGlide()
                return
            }
            // The user's scroll is authoritative — disengage and let it stand.
            if isUserScrollingRecently {
                stopFollowGlide()
                return
            }
            let clipView = scrollView.contentView
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            let current = clipView.bounds.origin.y
            let gap = maxY - current
            // Within a frame's worth of the bottom — land exactly and stop.
            guard abs(gap) > 0.5 else {
                if abs(gap) > 0.01 {
                    isProgrammaticScroll = true
                    clipView.scroll(to: NSPoint(x: 0, y: maxY))
                    scrollView.reflectScrolledClipView(clipView)
                    isProgrammaticScroll = false
                }
                stopFollowGlide()
                publishPinnedState(true)
                return
            }
            let nextY = current + gap * followGlideFactor
            isProgrammaticScroll = true
            clipView.scroll(to: NSPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(clipView)
            isProgrammaticScroll = false
        }

        private func stopFollowGlide() {
            followGlideTimer?.invalidate()
            followGlideTimer = nil
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
            // Prefer a real measurement for the current width — it survives
            // width changes and session switches, so a revisited row lays out at
            // its exact height with no reflow.
            if let measured = measuredHeightByID[id]?[widthBucket] { return measured }
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
        // Native render path (no SwiftUI / NSHostingView). `nativeRow` is the
        // concrete view; `nativeRowTypeID`/`nativeRowSpec` track which kind it is
        // so a recycled cell reuses a same-typed view and reads the row height
        // through the spec's measure closure.
        fileprivate var nativeRow: NSView?
        private var nativeRowTypeID: ObjectIdentifier?
        private var nativeRowSpec: NativeRowSpec?
        private var nativeTopC: NSLayoutConstraint?
        private var nativeBottomC: NSLayoutConstraint?
        private var configuredTopInset: CGFloat = 0
        private var configuredBottomInset: CGFloat = 0
        fileprivate var configuredItemID: String?
        private var configuredRevision: Int?
        fileprivate var configuredWidth: CGFloat = 0
        fileprivate var lastIntrinsicHeight: CGFloat = -1
        fileprivate weak var profiler: TranscriptScrollProfiler?

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

        /// Configure the cell for an item. Every row is native; the spec's view is
        /// built/reused and pinned to the cell with the row insets.
        func installRootView(item: PiAgentAppKitTranscriptItem, width: CGFloat, profiler: TranscriptScrollProfiler? = nil) {
            self.profiler = profiler
            guard case .native(let spec) = item.kind else { return }
            installNativeRow(spec: spec, item: item, width: width)
        }

        /// Tear down the native row view (when a recycled cell switches to a
        /// different native view type).
        private func teardownNativeRow() {
            guard let row = nativeRow else { return }
            nativeRowSpec?.reset(row)
            row.removeFromSuperview()
            nativeRow = nil
            nativeRowTypeID = nil
            nativeRowSpec = nil
            nativeTopC = nil
            nativeBottomC = nil
            lastIntrinsicHeight = -1
        }

        /// Native render path: build/configure the spec's view pinned to the cell
        /// with the row insets, rebuilding if the recycled cell held a different
        /// view type.
        private func installNativeRow(spec: NativeRowSpec, item: PiAgentAppKitTranscriptItem, width: CGFloat) {
            // A recycled cell holding a different native view type must rebuild it.
            if let existingType = nativeRowTypeID, existingType != spec.typeID {
                teardownNativeRow()
            }
            let row: NSView
            if let existing = nativeRow {
                row = existing
            } else {
                row = spec.make()
                row.translatesAutoresizingMaskIntoConstraints = false
                addSubview(row)
                // Full-width row; the view sizes/positions its own content.
                let top = row.topAnchor.constraint(equalTo: topAnchor, constant: item.topInset)
                let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -item.bottomInset)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: trailingAnchor),
                    top, bottom
                ])
                nativeTopC = top
                nativeBottomC = bottom
                nativeRow = row
                nativeRowTypeID = spec.typeID
                lastIntrinsicHeight = -1
            }
            nativeRowSpec = spec
            // Let an interactive native row (e.g. expanding a list) ask the cell to
            // re-measure and the table to re-tile when its content height changes.
            spec.setHeightCallback(row) { [weak self] in
                guard let self, let itemID = self.configuredItemID, self.configuredWidth > 1 else { return }
                let h = self.forcedIntrinsicHeight()
                if h > 0 { self.onMeasuredHeight?(itemID, h) }
            }
            let insetChanged = configuredTopInset != item.topInset || configuredBottomInset != item.bottomInset
            if insetChanged {
                nativeTopC?.constant = item.topInset
                nativeBottomC?.constant = -item.bottomInset
            }

            let revisionChanged = configuredItemID != item.id || configuredRevision != item.contentRevision
            let widthChanged = abs(configuredWidth - width) > 0.5
            if revisionChanged || widthChanged {
                spec.configure(row, width)
                lastIntrinsicHeight = -1
            }
            if revisionChanged || widthChanged || insetChanged {
                spec.settle(row)
            }
            configuredItemID = item.id
            configuredRevision = item.contentRevision
            configuredWidth = width
            configuredTopInset = item.topInset
            configuredBottomInset = item.bottomInset
        }

        private var pendingLayoutHeightReport = false

        /// AppKit's per-pass layout hook, and where the row reports height drift.
        override func layout() {
            if let profiler {
                profiler.measureCellLayout { super.layout() }
            } else {
                super.layout()
            }
            guard nativeRow != nil, nativeRowSpec != nil, configuredItemID != nil, configuredWidth > 1 else { return }
            // Reporting height means MEASURING the row, which forces its subtree to
            // lay out. AppKit recurses into that subtree only AFTER this `layout()`
            // returns, so forcing it here is illegal re-entrancy — it logs
            // `_NSDetectedLayoutRecursion` (captured: cell.layout → spec.measure →
            // NativeMarkdownTextContainer.measureHeight → stackView.layoutSubtreeIfNeeded
            // inside `_layoutSubtreeWithOldSize`). Hop out of the pass and measure
            // once it has completed; coalesced so streaming's many passes don't
            // stack up. Until it lands, `heightOfRow` keeps the row's estimate, and
            // freshly-streamed rows already report synchronously via
            // `forcedIntrinsicHeight()` — this path only catches later drift.
            scheduleLayoutHeightReport()
        }

        private func scheduleLayoutHeightReport() {
            guard !pendingLayoutHeightReport else { return }
            pendingLayoutHeightReport = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingLayoutHeightReport = false
                guard let row = self.nativeRow, let spec = self.nativeRowSpec,
                      let itemID = self.configuredItemID, self.configuredWidth > 1 else { return }
                let h = self.configuredTopInset + spec.measure(row, self.configuredWidth) + self.configuredBottomInset
                guard h > 0, h.isFinite, abs(h - self.lastIntrinsicHeight) > 0.5 else { return }
                self.lastIntrinsicHeight = h
                self.onMeasuredHeight?(itemID, h)
            }
        }

        /// Force the native row to lay out *now* and return its height, instead of
        /// waiting for AppKit's async `layout()` pass to report it. Used right after
        /// installing new streaming content so the coordinator can re-tile the row
        /// in the same pass. Records `lastIntrinsicHeight` so the subsequent async
        /// `layout()` sees no change and doesn't redundantly re-report.
        func forcedIntrinsicHeight() -> CGFloat {
            guard let row = nativeRow, let spec = nativeRowSpec, configuredWidth > 1 else { return -1 }
            row.layoutSubtreeIfNeeded()
            let h = configuredTopInset + spec.measure(row, configuredWidth) + configuredBottomInset
            guard h > 0, h.isFinite else { return -1 }
            lastIntrinsicHeight = h
            return h
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

/// The session list, isolated as an `Equatable` view so it can be wrapped in
/// `.equatable()`. It lives next to the transcript inside `PiAgentScreen.body`,
/// which re-runs at the streaming cadence (the transcript render cache is an
/// ObservableObject, so any of its published changes invalidates the whole body).
/// A SwiftUI `List` re-measures every row whenever its enclosing view updates —
/// even when the rows themselves are unchanged — so those pulses were re-laying
/// out the entire list ~30×/sec (the dominant `sizeThatFits` cost in the scroll
/// profiles). Comparing the value inputs lets SwiftUI skip the list entirely on a
/// pulse and rebuild it only when something it actually shows changed.
///
/// All per-row dynamic state (selection, running, renaming, title-generating, git
/// activity, project) is passed in as resolved values and compared in `==`, so the
/// list can never go stale: a real change to any of them differs the inputs and
/// forces a rebuild. Bindings and callbacks are intentionally excluded from `==`.
private struct SessionListContent: View, Equatable {
    let visibleSessions: [PiAgentSessionRecord]
    let selectedSessionIDs: Set<UUID>
    let renamingSessionID: UUID?
    let workingSessionIDs: Set<UUID>
    let generatingTitleIDs: Set<UUID>
    let activityByID: [UUID: PiAgentSessionGitActivity]
    let projectsByID: [UUID: DiscoveredProject?]

    @Binding var selection: Set<UUID>
    let onSelect: (PiAgentSessionRecord) -> Void
    let onBeginRename: (PiAgentSessionRecord) -> Void
    let onEndRename: () -> Void
    let onRename: (UUID, String) -> Void
    let onTogglePinned: (UUID) -> Void
    let onDelete: (UUID) -> Void

    static func == (lhs: SessionListContent, rhs: SessionListContent) -> Bool {
        let diff: String?
        if lhs.visibleSessions != rhs.visibleSessions { diff = "visibleSessions" }
        else if lhs.selectedSessionIDs != rhs.selectedSessionIDs { diff = "selectedSessionIDs" }
        else if lhs.renamingSessionID != rhs.renamingSessionID { diff = "renamingSessionID" }
        else if lhs.workingSessionIDs != rhs.workingSessionIDs { diff = "workingSessionIDs" }
        else if lhs.generatingTitleIDs != rhs.generatingTitleIDs { diff = "generatingTitleIDs" }
        else if lhs.activityByID != rhs.activityByID { diff = "activityByID" }
        else if !Self.projectsVisuallyEqual(lhs.projectsByID, rhs.projectsByID) { diff = "projectsByID" }
        else { diff = nil }
#if DEBUG
        if let diff {
            SessionListContent.perfLog.error("SessionListContent re-eval — input changed: \(diff, privacy: .public)")
        }
#endif
        return diff == nil
    }

    /// Compare the project map by ONLY what a row's icon actually shows — the
    /// project identity (path) and its icon file — not the whole DiscoveredProject.
    /// `viewModel.projectByPath` is reassigned wholesale on every project
    /// re-discovery, which fires constantly while an agent writes files; the
    /// re-derived projects differ in volatile fields (e.g. gitHubRemote resolving)
    /// that the session row never displays. Comparing the full value made the list
    /// re-evaluate ~30Hz (the dominant scroll-profile cost); this keeps it stable
    /// while still reacting to a project being added/removed or its icon changing.
    private static func projectsVisuallyEqual(_ lhs: [UUID: DiscoveredProject?], _ rhs: [UUID: DiscoveredProject?]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (id, lProject) in lhs {
            guard let rProject = rhs[id] else { return false }
            if lProject?.id != rProject?.id || lProject?.iconFileURL != rProject?.iconFileURL {
                return false
            }
        }
        return true
    }

#if DEBUG
    private static let perfLog = Logger(subsystem: "streetcoding.agent-deck", category: "SessionListPerf")
#endif

    var body: some View {
        AppList(
            sections: [AppListSection(id: "sessions", title: nil, items: visibleSessions)],
            selection: .multi($selection),
            cornerRadius: AppTheme.Chat.subCardCornerRadius,
            rowHorizontalPadding: 0,
            rowVerticalPadding: 0,
            listHorizontalInset: 6
        ) { session in
            row(session)
        }
        .animation(.snappy(duration: 0.24), value: visibleSessions.map(\.id))
        .bottomEdgeFade(height: 34)
    }

    @ViewBuilder
    private func row(_ session: PiAgentSessionRecord) -> some View {
        PiAgentSessionRow(
            session: session,
            project: projectsByID[session.id] ?? nil,
            isSelected: selectedSessionIDs.contains(session.id),
            isRunning: workingSessionIDs.contains(session.id),
            isRenaming: renamingSessionID == session.id,
            isGeneratingTitle: generatingTitleIDs.contains(session.id),
            gitActivity: activityByID[session.id] ?? .none,
            onSelect: { onSelect(session) },
            onBeginRename: { onBeginRename(session) },
            onEndRename: onEndRename,
            onRename: { onRename(session.id, $0) },
            onTogglePinned: { onTogglePinned(session.id) },
            onDelete: { onDelete(session.id) }
        )
        .equatable()
        .contextMenu {
            Button {
                onTogglePinned(session.id)
            } label: {
                Label(session.isPinned ? "Unpin Session" : "Pin Session", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                onDelete(session.id)
            } label: {
                Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected Sessions" : "Delete Session", systemImage: "trash")
            }
        }
    }
}

struct PiAgentScreen: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    @Binding var sessionSearchText: String
    @State private var composerText = ""
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
    /// Cached slash universe. Built once when the `/` panel opens (off the body
    /// hot path, in `.onChange`) and reused for the whole interaction so neither
    /// typing nor scrolling re-walks the catalog.
    @State private var slashUniverse: SlashUniverse = .empty
    @State private var slashState = SlashSuggestionState()
    /// The picked slash item — when non-nil, the composer shows it as a glass
    /// capsule chip above the editor and includes it in the send payload.
    @State private var slashSelection: SlashItem?
    @State private var lastSlashTriggerActive = false
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
    // Owned but NOT observed: `@State` (not `@StateObject`) holds the cache for the
    // view's lifetime without subscribing `PiAgentScreen.body` to its
    // `objectWillChange`. The cache pulses `streamingRevision` ~30Hz while a session
    // streams; subscribing the whole screen re-evaluated the session list + composer
    // on every pulse (the SessionListContent re-eval storm). Only the extracted
    // `PiAgentTranscriptHost` child takes the cache as `@ObservedObject`, so the
    // pulse now re-renders the transcript table alone. The cache is driven entirely
    // by `store.*`-keyed `.task`/`.onChange` triggers, which the parent still
    // observes — so dropping the subscription doesn't miss any update.
    @State private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var transcriptBottomScrollRequest = 0
    @State private var transcriptIsPinnedToBottom = true
    @State private var showArchivedPreCompactionTranscript = false
    @State private var isEarlierTranscriptSheetPresented = false
    @State private var cachedVisibleSessions: [PiAgentSessionRecord] = []
    @State private var hasBuiltVisibleSessions = false
    /// Per-session derived git activity (commit/push/merge timestamps), keyed by
    /// session.id. Rebuilt off the body hot path on transcript-revision or
    /// visible-set changes — never recomputed inline in row `body` to avoid
    /// jank (see `[[feedback_performance_sensitive]]`).
    @State private var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
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
        .onChange(of: store.sessionListRevision) { _, _ in rebuildVisibleSessions() }
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
            rebuildSessionActivityCache()
        }
        .onChange(of: store.transcriptRevisionsBySessionID) { _, _ in
            rebuildSessionActivityCache()
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

    private func rebuildSessionActivityCache() {
        var fresh: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions {
            let entries = store.transcriptsBySessionID[session.id] ?? []
            let activity = piAgentSessionGitActivity(from: entries)
            if activity.hasCommit || activity.hasPush || activity.hasMerge {
                fresh[session.id] = activity
            }
        }
        if fresh != sessionActivityCache {
            sessionActivityCache = fresh
        }
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
                                .font(AppTheme.Font.body.weight(.semibold))
                                .foregroundStyle(Color.red)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.red.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Delete selected sessions")
                        .accessibilityLabel("Delete selected sessions")
                    }
                    if viewModel.appSettings.nativeSubagentsEnabledForNewSessions {
                        PiAgentChatWithAgentButton(viewModel: viewModel)
                    }
                    if viewModel.selectedDiscoveredProject == nil {
                        PiAgentAddSessionMenuButton(
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            action: { viewModel.createPiAgentDraftForSelectedProject() },
                            onSelectProject: { project in
                                viewModel.createPiAgentDraft(for: project)
                            }
                        )
                    } else {
                        PiAgentAddSessionButton(
                            action: { viewModel.createPiAgentDraftForSelectedProject() }
                        )
                    }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 18)

            if scopedSessions.isEmpty {
                AppEmptyState(
                    "No sessions yet",
                    systemImage: "square.and.pencil",
                    description: emptySessionsMessage,
                    layout: .fill
                )
            } else {
                VStack(spacing: 10) {
                    if visibleSessions.isEmpty {
                        AppEmptyState("No sessions found", systemImage: "magnifyingglass", description: "Try another search.", layout: .fill)
                    } else {
                        SessionListContent(
                            visibleSessions: visibleSessions,
                            selectedSessionIDs: selectedSessionIDs,
                            renamingSessionID: renamingSessionID,
                            workingSessionIDs: workingVisibleSessionIDs,
                            generatingTitleIDs: viewModel.piAgentTitleGeneratingSessionIDs,
                            activityByID: visibleSessionActivityByID,
                            projectsByID: visibleSessionProjectsByID,
                            selection: $selectedSessionIDs,
                            onSelect: { session in
                                renamingSessionID = nil
                                selectSessionFromList(session)
                            },
                            onBeginRename: { session in
                                selectSessionFromList(session, forceSingle: true)
                                renamingSessionID = session.id
                            },
                            onEndRename: { renamingSessionID = nil },
                            onRename: { viewModel.renamePiAgentSession($0, title: $1) },
                            onTogglePinned: { viewModel.togglePiAgentSessionPinned($0) },
                            onDelete: { id in
                                requestDeleteSessions(
                                    selectedSessionIDs.contains(id) && selectedSessionIDs.count > 1
                                        ? selectedSessionIDs
                                        : [id]
                                )
                            }
                        )
                        .equatable()
                    }
                }
            }
        }
        .background(Color.clear)
    }

    // Per-row dynamic state resolved up front so the session list can be an
    // Equatable view (see SessionListContent): comparing these resolved values is
    // what lets a streaming-cadence body re-eval skip the list unless a row's
    // contents actually changed. Each iterates only the (cached) visible sessions.
    private var workingVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    private var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        var map: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions where sessionActivityCache[session.id] != nil {
            map[session.id] = sessionActivityCache[session.id]
        }
        return map
    }

    private var visibleSessionProjectsByID: [UUID: DiscoveredProject?] {
        var map: [UUID: DiscoveredProject?] = [:]
        for session in visibleSessions {
            map[session.id] = viewModel.projectByPath[session.projectPath]
        }
        return map
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
                if let session = store.selectedSession,
                   session.status == .draft,
                   session.subagentsEnabled {
                    PiAgentSessionSubagentPickerCard(viewModel: viewModel, session: session)
                        .id(session.id)
                }

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
                .equatable()
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: sessionKindTagColor(session.kind))
                    if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                            Text("Chat with \(agentName)")
                                .font(AppTheme.Font.footnote.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.12)))
                    }
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.Font.footnote)
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
                        .font(AppTheme.Font.footnote)
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
        // `PiAgentTranscriptHost` is the ONLY view that observes `transcriptCache`,
        // so the ~30Hz streaming pulse re-renders the transcript table alone and no
        // longer invalidates this screen's session list / composer. `makeItems` is
        // re-run inside the host on each pulse; it reads the live cache + parent
        // references (store/viewModel), so the items stay correct even though the
        // parent struct it captured isn't re-evaluated between pulses.
        PiAgentTranscriptHost(
            cache: transcriptCache,
            sessionID: store.selectedSession?.id,
            bottomScrollRequest: transcriptBottomScrollRequest,
            makeItems: { appKitTranscriptItems },
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptIsPinnedToBottom = isPinnedToBottom
            },
            onBenchAdvanceSession: { viewModel.selectNextPiAgentSession() },
            benchSessionCount: { viewModel.scopedPiAgentSessionsInOrder().count }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptIsPinnedToBottom else { return }
            requestTranscriptBottomScroll()
        }
        .perfScene("PiAgentTranscript")
    }

    private var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
        TranscriptScrollProfiler.measureBody("itemsBuild") { appKitTranscriptItemsBuild }
    }

    private var appKitTranscriptItemsBuild: [PiAgentAppKitTranscriptItem] {
        let timelineSnapshot = transcriptTimelineSnapshot
        let timelineItems = timelineSnapshot.mainVisibleItems
        let chromeRevision = appKitTranscriptChromeRevision(snapshot: timelineSnapshot)
        let contextRevision = appKitTranscriptThreadContextRevision(snapshot: timelineSnapshot)
        let visibility = viewModel.appSettings.piAgentTranscriptVisibility
        let skills = visibleSkillsForSelectedSession
        let commandSlashNames = Set((store.selectedSession?.commandInvocations ?? []).map { name in
            name.hasPrefix("/") ? String(name.dropFirst()) : name
        })
        let subagentRuns = nativeSubagentRunsByID

        var descriptors: [PiAgentTranscriptBlockDescriptor] = []

        // --- Chrome rows (each its own revision) ---
        if let session = store.selectedSession {
            if visibility.showShortcutsStrip {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "shortcuts-strip-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeShortcutsStripView.self) { view, width in view.configure(width: width) }),
                    baseRevision: 0,
                    estimatedContentHeight: { _ in 40 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            if let parentTitle = session.forkedFromParentTitle, !parentTitle.isEmpty {
                let parentID = session.forkedFromSessionID
                let snapshot = session.forkedFromTranscriptSnapshot
                let storeRef = store
                let onSelect: (UUID) -> Void = { parentSessionID in
                    storeRef.select(parentSessionID)
                }
                var hasher = Hasher()
                hasher.combine(parentTitle)
                hasher.combine(parentID)
                hasher.combine(snapshot)
                let forkPayload = NativeForkOriginPayload.make(
                    parentTitle: parentTitle, parentSessionID: parentID,
                    transcriptSnapshot: snapshot, onSelectParent: onSelect)
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "fork-origin-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeForkOriginCardView.self) { view, width in
                        view.configure(payload: forkPayload, width: width)
                    }),
                    baseRevision: hasher.finalize(),
                    estimatedContentHeight: { _ in 70 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            // The final system prompt is no longer a transcript card — it's a
            // toolbar button (next to Plan / Session Resources / Transcript Display)
            // that opens the same text popover. See `piAgentPrimaryToolbarContent`.
            for request in store.supervisorRequests(for: session.id).filter({ $0.status == .pending }) {
                let supervisorPayload = NativeSupervisorPayload.make(
                    request: request,
                    onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: session.id, response: response) },
                    onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: session.id) }
                )
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "supervisor-request-\(request.id)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeSupervisorCardView.self) { view, width in
                        view.configure(payload: supervisorPayload, width: width)
                    }),
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
            let isShowing = showArchivedPreCompactionTranscript
            let archivePayload = NativeArchiveNoticePayload.preCompaction(
                hiddenCount: archive.hiddenCount, compactedAt: archive.compactedAt,
                isShowing: isShowing, onToggle: { showArchivedPreCompactionTranscript.toggle() })
            hasher.combine(isShowing)
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pre-compaction-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: archivePayload, width: width)
                }),
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
            let recentPayload = NativeArchiveNoticePayload.recentWindow(
                hiddenCount: archive.hiddenCount, limit: archive.limit,
                onOpen: { isEarlierTranscriptSheetPresented = true })
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "recent-window-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: recentPayload, width: width)
                }),
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
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .loading(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 80 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else if timelineItems.isEmpty && descriptors.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .empty(), width: width)
                }),
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
                        // Native fast path for plain-text questions (no attachment
                        // Chip-bearing questions use the dedicated chip-aware card;
                        // plain questions use the lighter bubble.
                        let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                            for: question, skills: skills, commandSlashNames: commandSlashNames) > 0
                        let questionKind = hasChips
                            ? nativeChipQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                            : nativeQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: blockID,
                            view: nil,
                            kind: questionKind,
                            baseRevision: appKitQuestionBlockRevision(question, contextRevision: contextRevision),
                            estimatedContentHeight: { Self.estimatedQuestionHeight(question, width: $0) },
                            threadID: item.id,
                            isThreadQuestion: true
                        ))
                    }
                    for child in PiAgentTranscriptThreadCard.visibleChildren(
                        of: thread, visibility: visibility, nativeSubagentRunsByID: subagentRuns
                    ) {
                        // Native rendering for the supported child types; the
                        // rest (tool groups, subagent/memory cards) still hosted.
                        let nativeKind = nativeChildKind(
                            for: child, visibility: visibility, skills: skills,
                            commandSlashNames: commandSlashNames, subagentRuns: subagentRuns)
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: child.id,
                            view: nil,
                            kind: nativeKind ?? Self.nativeEmptyKind,
                            baseRevision: appKitChildBlockRevision(child, contextRevision: contextRevision),
                            estimatedContentHeight: { Self.estimatedChildHeight(child, width: $0) },
                            threadID: item.id,
                            isThreadQuestion: false
                        ))
                    }
                }
            }
        }

        // Bottom anchor — a 1pt row scrollToBottom can always land on.
        descriptors.append(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-bottom-anchor",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { _, _ in }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 1 },
            threadID: nil,
            isThreadQuestion: false
        ))

        // --- Inset pass: NSTableView intercell spacing is uniform, so split
        // each inter-row gap in half across the two adjacent rows. Gaps come from
        // the design system: question↔reply (threadSpacing), sibling children
        // (childSpacing), everything else (rowSpacing). ---
        if descriptors.count > 1 {
            for i in 0 ..< descriptors.count - 1 {
                let gap: CGFloat
                if let tid = descriptors[i].threadID, tid == descriptors[i + 1].threadID {
                    gap = descriptors[i].isThreadQuestion ? AppTheme.Chat.threadSpacing : AppTheme.Chat.childSpacing
                } else {
                    gap = AppTheme.Chat.rowSpacing
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
            let kind = descriptor.kind ?? Self.nativeEmptyKind
            return PiAgentAppKitTranscriptItem(
                id: descriptor.id,
                kind: kind,
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
        commandSlashNames: Set<String>,
        projectPath: String?,
        subagentRuns: [UUID: PiSubagentRunRecord],
        renderMode: PiAgentTranscriptThreadCard.RenderMode,
        blockID: String
    ) -> some View {
        let viewModel = viewModel
        return PiAgentTranscriptThreadCard(
            thread: thread,
            visibility: visibility,
            skills: skills,
            commandSlashNames: commandSlashNames,
            projectPath: projectPath,
            nativeSubagentRunsByID: subagentRuns,
            nativeSubagentCard: nativeSubagentCard,
            renderMode: renderMode,
            onFork: { entry in viewModel.forkPiAgentSession(from: entry) },
            forkAgentChoices: forkAgentChoicesForSelectedSession,
            onForkAsAgentChat: { entry, agent in
                viewModel.forkPiAgentSessionAsAgentChat(from: entry, agent: agent)
            }
        )
        .id(blockID)
    }

    /// Native payload for a plain-text user question (no attachment chips):
    /// hugged-width right-aligned bubble with leading copy + fork affordance.
    /// Instance method because the fork actions capture `viewModel`.
    /// The fork affordance for a user-question row (Pi session + per-agent chat).
    private func questionForkModel(_ question: PiAgentTranscriptEntry) -> ForkModel {
        let agentOptions: [ForkAgentOption] = (forkAgentChoicesForSelectedSession ?? []).map { agent in
            ForkAgentOption(
                title: agent.name,
                isDisabled: agent.resolved.disabled == true,
                action: { [viewModel] in viewModel.forkPiAgentSessionAsAgentChat(from: question, agent: agent) }
            )
        }
        return ForkModel(
            onForkSession: { [viewModel] in viewModel.forkPiAgentSession(from: question) },
            agentOptions: agentOptions
        )
    }

    /// Native render kind for a chip-bearing user question (skill/command/
    /// attachment chips) — the dedicated chip-aware question card.
    private func nativeChipQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> PiAgentTranscriptCellKind {
        let payload = NativeQuestionPayload.make(
            entry: question, skills: skills, commandSlashNames: commandSlashNames,
            fork: questionForkModel(question))
        return .native(.of(PiAgentNativeQuestionView.self) { view, width in
            view.configure(payload: payload, width: width)
        })
    }

    private func nativeQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> PiAgentTranscriptCellKind {
        let text = PiAgentUserMessageContent.displayMessageText(
            for: question, skills: skills, commandSlashNames: commandSlashNames)
        let fork = questionForkModel(question)
        return .bubble(NativeBubblePayload(
            role: .user,
            headerTitle: "You",
            iconSymbol: "person.crop.circle",
            markdownSource: text,
            bodyPrefix: nil,
            copyText: question.text,
            copySide: .leading,
            isThreadChild: false,
            isUserHugged: true,
            fork: fork
        ))
    }

    /// Per-block height estimators — character-count math, no SwiftUI pass.
    /// Mirror the heights the old per-thread estimator summed per child.
    private static func estimatedQuestionHeight(_ entry: PiAgentTranscriptEntry, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
        return CGFloat(lines) * 18 + 56
    }

    /// Native render kind for a thread child, or nil to fall back to the hosted
    /// SwiftUI path. Tool groups and subagent/memory status cards stay hosted
    /// (later stages); everything else renders natively.
    /// A native 0-height empty row — the safety fallback now that every descriptor
    /// is native (no `.hosted` path remains).
    private static let nativeEmptyKind: PiAgentTranscriptCellKind =
        .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })

    private func nativeChildKind(
        for child: PiAgentThreadChild,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        subagentRuns: [UUID: PiSubagentRunRecord]
    ) -> PiAgentTranscriptCellKind? {
        switch child {
        case .assistant(let entry):
            if let summary = PiAgentSubagentSummary.cached(for: entry) {
                let payload = NativeSubagentSummaryPayload.make(summary: summary)
                return .native(.of(PiAgentNativeSubagentSummaryView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            return Self.nativeReplyPayload(for: child).map { .bubble($0) }
        case .thinking:
            return Self.nativeReplyPayload(for: child).map { .bubble($0) }
        case .steering(let entry):
            // Chip-bearing steering messages use the native chip-question card,
            // re-labeled as "Steering".
            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                for: entry, skills: skills, commandSlashNames: commandSlashNames) > 0
            if hasChips {
                var payload = NativeQuestionPayload.make(
                    entry: entry, skills: skills, commandSlashNames: commandSlashNames, fork: nil)
                payload.headerTitle = "Steering"
                payload.headerIcon = "arrowshape.turn.up.forward.circle"
                return .native(.of(PiAgentNativeQuestionView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let text = PiAgentUserMessageContent.displayMessageText(
                for: entry, skills: skills, commandSlashNames: commandSlashNames)
            return .bubble(NativeBubblePayload(
                role: .user,
                headerTitle: "Steering",
                iconSymbol: "arrowshape.turn.up.forward.circle",
                markdownSource: text,
                bodyPrefix: nil,
                copyText: entry.text,
                copySide: .trailing,
                isThreadChild: true
            ))
        case .status(let entry):
            if let memoryEvent = entry.agentMemoryEvent {
                let payload = NativeMemoryCardPayload.make(event: memoryEvent)
                return .native(.of(PiAgentNativeMemoryCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                if NativeSubagentFactory.isParallel(run) {
                    let payload = NativeSubagentParallelPayload.make(
                        run: run,
                        imageStore: viewModel.agentImageStore,
                        onOpenChildTranscript: { [self] in selectedSubagentTranscriptRunID = $0 },
                        onStopChild: { [viewModel] in viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) }
                    )
                    return .native(.of(PiAgentNativeSubagentParallelCardView.self) { view, width in
                        view.configure(payload: payload, width: width)
                    })
                }
                let payload = NativeAgentBlockPayload.makeSingle(
                    run: run,
                    imageStore: viewModel.agentImageStore,
                    onStop: { [viewModel] in viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
                    onTranscript: { [self] in selectedSubagentTranscriptRunID = run.id },
                    onReveal: { [self] in revealSubagentRun(run) }
                )
                return .native(.of(PiAgentNativeSubagentRunCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            // "System Prompt Captured" / "Subagent Started" render as a native
            // status row with prompt-audit buttons (computed in make(for:)).
            if entry.isDividerStatus {
                let payload = NativeDividerPayload.make(for: entry)
                return .native(.of(PiAgentNativeStatusDividerView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .error(let entry):
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .retry(let entry, let info):
            let payload = NativeRetryPayload.make(info: info, timestamp: entry.timestamp)
            return .native(.of(PiAgentNativeRetryRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .toolGroup(let group):
            guard let model = NativeToolGroupModel.make(
                group: group, visibility: visibility, projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
            ) else {
                // Tool sections all hidden by visibility → an empty 0-height row.
                return .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })
            }
            return .native(.of(PiAgentNativeToolGroupView.self) { view, width in
                view.configure(model: model, width: width)
            })
        }
    }

    /// Maps a thread child to a native bubble payload for the plain-text reply
    /// rows (assistant / thinking). Returns nil for anything that still renders
    /// through the hosted SwiftUI path (subagent summaries, tool groups, status,
    /// errors, retries, steering — handled in later stages).
    private static func nativeReplyPayload(for child: PiAgentThreadChild) -> NativeBubblePayload? {
        switch child {
        case .assistant(let entry):
            if PiAgentSubagentSummary.cached(for: entry) != nil { return nil }
            let text = entry.text
            return NativeBubblePayload(
                role: .assistant,
                headerTitle: "Coding Agent",
                iconSymbol: nil,
                markdownSource: text,
                bodyPrefix: nil,
                copyText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                copySide: .trailing,
                isThreadChild: true
            )
        case .thinking(let entry):
            let display = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return NativeBubblePayload(
                role: .thinking,
                headerTitle: entry.title,
                iconSymbol: "brain.head.profile",
                markdownSource: display.isEmpty ? "Pi has not emitted reasoning text yet." : display,
                bodyPrefix: "Reasoning",
                copyText: display,
                copySide: .trailing,
                isThreadChild: true
            )
        default:
            return nil
        }
    }

    private static func estimatedChildHeight(_ child: PiAgentThreadChild, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        switch child {
        case let .assistant(entry), let .steering(entry), let .thinking(entry):
            let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
            return CGFloat(min(lines, 40)) * 18 + 48
        case let .toolGroup(group):
            // One row per activity — a flat estimate made a multi-tool group
            // pop hard the first time it appeared (before the cell re-measures).
            return CGFloat(max(group.activities.count, 1)) * 40 + 16
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


    private var loadingTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                AppSpinner()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loading transcript")
                        .font(AppTheme.Font.headline)
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
                        .font(AppTheme.Font.headline)
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
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(showArchivedPreCompactionTranscript ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden")
                .font(AppTheme.Font.caption.weight(.semibold))
            Text("\(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") before \(archive.compactedAt.formatted(date: .omitted, time: .shortened))")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
            Button(showArchivedPreCompactionTranscript ? "Hide" : "Load Earlier") {
                withAnimation(.snappy(duration: 0.18)) {
                    showArchivedPreCompactionTranscript.toggle()
                }
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func recentWindowArchiveCard(_ archive: (hiddenCount: Int, limit: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Earlier transcript hidden")
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text("Showing the latest \(archive.limit) items to keep this chat responsive. \(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") are available.")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer(minLength: 0)
            Button("Open Earlier Transcript") {
                isEarlierTranscriptSheetPresented = true
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
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
                commandSlashNames: Set((store.selectedSession?.commandInvocations ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }),
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                nativeSubagentRunsByID: nativeSubagentRunsByID,
                nativeSubagentCard: nativeSubagentCard
            )
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
        case let .applyingConfigurationChange(summary): return "Changing \(summary)"
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
        case "Deck Agent Requested": return "Starting Deck agent"
        case "Parallel Deck Agents Requested": return "Starting parallel run"
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
        case "managed_subagent": return "Starting Deck agent"
        case "managed_parallel": return "Starting parallel agents"
        case "ask_user": return "Waiting for your input"
        case "agent_deck_memory_write", "agent_deck_memory_mark_stale": return "Updating memory"
        case "list_supervisor_requests", "answer_supervisor_request": return "Coordinating Deck agents"
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
            if hasFileSuggestions {
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
            } else if hasSlashSuggestions {
                PiAgentSlashSuggestions(
                    rows: slashSuggestionRows,
                    highlightedSelectableIndex: slashState.highlightedIndex,
                    scrollTick: slashState.scrollTick,
                    title: slashPanelTitle,
                    onSelect: { row in handleSlashRowSelect(row) },
                    onHoverSelectable: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil else { return }
                        slashState.highlightedIndex = index
                    },
                    onBack: slashCanGoBack ? { popSlashScreen() } : nil
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
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil || slashSelection != nil),
                canCreateSession: !isCompacting && store.selectedSession == nil,
                createSessionProjects: viewModel.selectedDiscoveredProject == nil ? piAgentNewSessionProjects : [],
                onFiles: addFileAttachments,
                onFolders: addFolderAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                transcript: store.selectedTranscript,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
                slashSelection: slashSelection,
                onRemoveSlashSelection: { slashSelection = nil },
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
            refreshSlashUniverseLifecycle()
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
        // Slash mode now uses `PiAgentSlashSuggestions`; this builder is the
        // file-only path. Commands / skills are intentionally empty here.
        ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
    }

    private var slashQueryString: String {
        if case .slash(let query) = composerSuggestionTrigger { return query }
        return ""
    }

    private var slashSuggestionRows: [SlashSuggestionRow] {
        SlashSuggestionRowBuilder.rows(universe: slashUniverse, state: slashState, query: slashQueryString)
    }

    private var slashSelectableCount: Int {
        slashSuggestionRows.lazy.filter(\.isSelectable).count
    }

    private var slashPanelTitle: String? {
        switch slashState.screen {
        case .categoryPicker:
            return slashQueryString.isEmpty ? nil : "Search · \(slashQueryString)"
        case .category(let kind):
            switch kind {
            case .command: return "Commands"
            case .prompt: return "Prompts"
            case .skill: return "Skills"
            }
        }
    }

    private var slashCanGoBack: Bool {
        if case .category = slashState.screen { return true }
        return false
    }

    private var hasFileSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        if case .file = composerSuggestionTrigger { return !fileSuggestionResults.isEmpty }
        return false
    }

    private var hasSlashSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        guard case .slash = composerSuggestionTrigger else { return false }
        return !slashSuggestionRows.isEmpty
    }

    private var hasComposerSuggestions: Bool {
        hasFileSuggestions || hasSlashSuggestions
    }

    private var composerSuggestionKeyBridge: ComposerSuggestionKeyBridge {
        ComposerSuggestionKeyBridge(
            isActive: hasComposerSuggestions,
            onMove: { delta in
                if hasSlashSuggestions {
                    let count = slashSelectableCount
                    guard count > 0 else { return }
                    slashState.highlightedIndex = min(max(slashState.highlightedIndex + delta, 0), count - 1)
                    slashState.scrollTick &+= 1
                } else {
                    let count = composerSuggestionItems.count
                    guard count > 0 else { return }
                    composerSuggestionIndex = min(max(composerSuggestionIndex + delta, 0), count - 1)
                    composerSuggestionScrollTick += 1
                }
                // Ignore hover briefly so the scroll sliding rows under a
                // stationary pointer can't hijack the keyboard selection.
                composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            },
            onAccept: { acceptComposerSuggestion() },
            onDismiss: {
                if slashCanGoBack {
                    popSlashScreen()
                } else {
                    composerSuggestionsDismissed = true
                }
            }
        )
    }

    private func acceptComposerSuggestion() -> Bool {
        if hasSlashSuggestions {
            let selectable = slashSuggestionRows.filter(\.isSelectable)
            guard selectable.indices.contains(slashState.highlightedIndex) else { return false }
            handleSlashRowSelect(selectable[slashState.highlightedIndex])
            return true
        }
        let items = composerSuggestionItems
        guard items.indices.contains(composerSuggestionIndex) else { return false }
        insertComposerSuggestion(items[composerSuggestionIndex].insertion)
        return true
    }

    private func handleSlashRowSelect(_ row: SlashSuggestionRow) {
        switch row.kind {
        case .header:
            return
        case .category(let kind):
            slashState.screen = .category(kind)
            slashState.highlightedIndex = 0
            slashState.scrollTick &+= 1
        case .item(let item):
            commitSlashSelection(item)
        }
    }

    private func popSlashScreen() {
        slashState.screen = .categoryPicker
        slashState.highlightedIndex = 0
        slashState.scrollTick &+= 1
    }

    private func commitSlashSelection(_ item: SlashItem) {
        // Strip the leading `/<typed>` token so the pill alone represents the
        // invocation. Any other composer text the user typed is preserved.
        if let token = activeSuggestionToken, token.token.hasPrefix("/") {
            composerText.replaceSubrange(token.range, with: "")
        }
        composerText = composerText.trimmingCharacters(in: .whitespaces)

        // For prompts, seed the editor with the body so the user can edit
        // before sending. Commands and skills leave the editor alone — any
        // text the user types becomes the args / message body.
        if case .prompt(_, let body) = item.payload {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = composerText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(composerText)"
        }

        slashSelection = item
        slashState = SlashSuggestionState()
        composerSuggestionsDismissed = true
    }

    /// Builds (or releases) the cached slash universe on transitions in/out of
    /// `/` mode. Runs from `.onChange(of: composerText)` — never in `body` — so
    /// the catalog walk and its filesystem lookups stay off the hot render path.
    private func refreshSlashUniverseLifecycle() {
        let isSlashActive: Bool
        if case .slash = composerSuggestionTrigger { isSlashActive = true } else { isSlashActive = false }

        if isSlashActive && !lastSlashTriggerActive {
            let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
            slashUniverse = viewModel.slashUniverse(forProjectPath: projectPath)
            slashState = SlashSuggestionState()
        } else if !isSlashActive && lastSlashTriggerActive {
            slashUniverse = .empty
            slashState = SlashSuggestionState()
        }
        lastSlashTriggerActive = isSlashActive
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

    /// Agents offered in the user-message Fork submenu. Returns `nil` (single
    /// fork action) when the session has no subagents enabled, isn't a normal
    /// project session, or no agents are discovered. Re-evaluated when the
    /// selected session, its subagent toggle, or the agent catalog change.
    private var forkAgentChoicesForSelectedSession: [EffectiveAgentRecord]? {
        guard let session = store.selectedSession,
              session.kind != .agent,
              session.subagentsEnabled else { return nil }
        let agents = viewModel.selectableAgentUniverse(forProjectPath: session.projectPath)
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return agents.isEmpty ? nil : agents
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
        // O(1) membership instead of `contains(where:)` per attachment; the Set
        // also de-dupes within the incoming batch.
        var seenURLs = Set(composerFiles.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
            composerFiles.append(attachment)
        }
    }

    private func addFolderAttachments(_ urls: [URL]) {
        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        var seenURLs = Set(composerFolders.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
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
        slashSelection = nil
        slashState = SlashSuggestionState()
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
        let baseMessage = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTranscript = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = slashSelection?.materialize(userText: baseMessage) ?? baseMessage
        let transcriptMessage = slashSelection?.materialize(userText: baseTranscript) ?? baseTranscript
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
        scopedSessions.count(where: { viewModel.piAgentSessionIsWorking($0) })
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

    private func sessionKindTagColor(_ kind: PiAgentSessionKind) -> Color {
        switch kind {
        case .issue: return .purple
        case .agent: return .teal
        case .project, .changesReview: return .blue
        }
    }
}

private struct PiAgentComposerPanel: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    let onWillSend: () -> Void
    let onDidSend: () -> Void

    @State private var composerText = ""
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
    @State private var slashUniverse: SlashUniverse = .empty
    @State private var slashState = SlashSuggestionState()
    @State private var slashSelection: SlashItem?
    @State private var lastSlashTriggerActive = false
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
            if hasFileSuggestions {
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
            } else if hasSlashSuggestions {
                PiAgentSlashSuggestions(
                    rows: slashSuggestionRows,
                    highlightedSelectableIndex: slashState.highlightedIndex,
                    scrollTick: slashState.scrollTick,
                    title: slashPanelTitle,
                    onSelect: { row in handleSlashRowSelect(row) },
                    onHoverSelectable: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil else { return }
                        slashState.highlightedIndex = index
                    },
                    onBack: slashCanGoBack ? { popSlashScreen() } : nil
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
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil || slashSelection != nil),
                canCreateSession: !isCompacting && store.selectedSession == nil,
                createSessionProjects: viewModel.selectedDiscoveredProject == nil ? piAgentNewSessionProjects : [],
                onFiles: addFileAttachments,
                onFolders: addFolderAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                transcript: store.selectedTranscript,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
                slashSelection: slashSelection,
                onRemoveSlashSelection: { slashSelection = nil },
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
            refreshSlashUniverseLifecycle()
            // Mirror the draft into the session store on every keystroke so an
            // unsent message survives a window re-key (a theme change rebuilds
            // the view tree). `onAppear` below restores it into the new tree.
            saveComposerDraft(for: store.selectedSession?.id)
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
        // Slash mode now uses `PiAgentSlashSuggestions`; this builder is the
        // file-only path. Commands / skills are intentionally empty here.
        ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
    }

    private var slashQueryString: String {
        if case .slash(let query) = composerSuggestionTrigger { return query }
        return ""
    }

    private var slashSuggestionRows: [SlashSuggestionRow] {
        SlashSuggestionRowBuilder.rows(universe: slashUniverse, state: slashState, query: slashQueryString)
    }

    private var slashSelectableCount: Int {
        slashSuggestionRows.lazy.filter(\.isSelectable).count
    }

    private var slashPanelTitle: String? {
        switch slashState.screen {
        case .categoryPicker:
            return slashQueryString.isEmpty ? nil : "Search · \(slashQueryString)"
        case .category(let kind):
            switch kind {
            case .command: return "Commands"
            case .prompt: return "Prompts"
            case .skill: return "Skills"
            }
        }
    }

    private var slashCanGoBack: Bool {
        if case .category = slashState.screen { return true }
        return false
    }

    private var hasFileSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        if case .file = composerSuggestionTrigger { return !fileSuggestionResults.isEmpty }
        return false
    }

    private var hasSlashSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        guard case .slash = composerSuggestionTrigger else { return false }
        return !slashSuggestionRows.isEmpty
    }

    private var hasComposerSuggestions: Bool {
        hasFileSuggestions || hasSlashSuggestions
    }

    private var composerSuggestionKeyBridge: ComposerSuggestionKeyBridge {
        ComposerSuggestionKeyBridge(
            isActive: hasComposerSuggestions,
            onMove: { delta in
                if hasSlashSuggestions {
                    let count = slashSelectableCount
                    guard count > 0 else { return }
                    slashState.highlightedIndex = min(max(slashState.highlightedIndex + delta, 0), count - 1)
                    slashState.scrollTick &+= 1
                } else {
                    let count = composerSuggestionItems.count
                    guard count > 0 else { return }
                    composerSuggestionIndex = min(max(composerSuggestionIndex + delta, 0), count - 1)
                    composerSuggestionScrollTick += 1
                }
                // Ignore hover briefly so the scroll sliding rows under a
                // stationary pointer can't hijack the keyboard selection.
                composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            },
            onAccept: { acceptComposerSuggestion() },
            onDismiss: {
                if slashCanGoBack {
                    popSlashScreen()
                } else {
                    composerSuggestionsDismissed = true
                }
            }
        )
    }

    private func acceptComposerSuggestion() -> Bool {
        if hasSlashSuggestions {
            let selectable = slashSuggestionRows.filter(\.isSelectable)
            guard selectable.indices.contains(slashState.highlightedIndex) else { return false }
            handleSlashRowSelect(selectable[slashState.highlightedIndex])
            return true
        }
        let items = composerSuggestionItems
        guard items.indices.contains(composerSuggestionIndex) else { return false }
        insertComposerSuggestion(items[composerSuggestionIndex].insertion)
        return true
    }

    private func handleSlashRowSelect(_ row: SlashSuggestionRow) {
        switch row.kind {
        case .header:
            return
        case .category(let kind):
            slashState.screen = .category(kind)
            slashState.highlightedIndex = 0
            slashState.scrollTick &+= 1
        case .item(let item):
            commitSlashSelection(item)
        }
    }

    private func popSlashScreen() {
        slashState.screen = .categoryPicker
        slashState.highlightedIndex = 0
        slashState.scrollTick &+= 1
    }

    private func commitSlashSelection(_ item: SlashItem) {
        // Strip the leading `/<typed>` token so the pill alone represents the
        // invocation. Any other composer text the user typed is preserved.
        if let token = activeSuggestionToken, token.token.hasPrefix("/") {
            composerText.replaceSubrange(token.range, with: "")
        }
        composerText = composerText.trimmingCharacters(in: .whitespaces)

        // For prompts, seed the editor with the body so the user can edit
        // before sending. Commands and skills leave the editor alone — any
        // text the user types becomes the args / message body.
        if case .prompt(_, let body) = item.payload {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = composerText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(composerText)"
        }

        slashSelection = item
        slashState = SlashSuggestionState()
        composerSuggestionsDismissed = true
    }

    /// Builds (or releases) the cached slash universe on transitions in/out of
    /// `/` mode. Runs from `.onChange(of: composerText)` — never in `body` — so
    /// the catalog walk and its filesystem lookups stay off the hot render path.
    private func refreshSlashUniverseLifecycle() {
        let isSlashActive: Bool
        if case .slash = composerSuggestionTrigger { isSlashActive = true } else { isSlashActive = false }

        if isSlashActive && !lastSlashTriggerActive {
            let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
            slashUniverse = viewModel.slashUniverse(forProjectPath: projectPath)
            slashState = SlashSuggestionState()
        } else if !isSlashActive && lastSlashTriggerActive {
            slashUniverse = .empty
            slashState = SlashSuggestionState()
        }
        lastSlashTriggerActive = isSlashActive
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
        // O(1) membership instead of `contains(where:)` per attachment; the Set
        // also de-dupes within the incoming batch.
        var seenURLs = Set(composerFiles.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
            composerFiles.append(attachment)
        }
    }

    private func addFolderAttachments(_ urls: [URL]) {
        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        var seenURLs = Set(composerFolders.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
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
        slashSelection = nil
        slashState = SlashSuggestionState()
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
        let baseMessage = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTranscript = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = slashSelection?.materialize(userText: baseMessage) ?? baseMessage
        let transcriptMessage = slashSelection?.materialize(userText: baseTranscript) ?? baseTranscript
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

// Protect the composer — the app's most expensive chrome (glass card, slash
// menu, suggestions) — from the parent transcript view's per-streaming-token
// body churn. The parent re-runs ~30×/sec while tokens arrive (its body reads
// the transcript cache); without this the composer's body re-ran each time even
// though nothing it shows changed. Its only non-`@State` inputs are the two
// reference-type stores and two action closures, and all of its display state
// is driven by `@Observable` reads of those stores — so comparing store identity
// (and ignoring the closures, which are recreated every parent pass) is correct:
// `.equatable()` skips parent-churn re-renders while observation still drives
// every real update (e.g. run/stop transitions).
extension PiAgentComposerPanel: Equatable {
    nonisolated static func == (lhs: PiAgentComposerPanel, rhs: PiAgentComposerPanel) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.store === rhs.store
    }
}
