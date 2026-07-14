import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers


let piAgentLeakedToolNames: Set<String> = ["bash", "read", "edit", "write", "find", "grep", "subagent", "web_search", "fetch_content", "get_search_content", "web_fetch"]

private struct SlashSuggestionRowsCacheKey: Equatable {
    let universeRevision: Int
    let screen: SlashSuggestionState.Screen
    let query: String
}

#if DEBUG
@MainActor
final class PickerStressCardAcknowledgements {
    var sessionID: UUID?
    var mounted = false
    var expanded = false
    var rowCount = 0
    var isCompact = false
    var cardSize = CGSize.zero
    var catalogSize = CGSize.zero

    func reset(for sessionID: UUID) {
        self.sessionID = sessionID
        mounted = false
        expanded = false
        rowCount = 0
        isCompact = false
        cardSize = .zero
        catalogSize = .zero
    }
}
#endif

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
    // NOT @Published: the transcript host re-evaluates off the revision counters
    // below (which bump in lockstep with content in `publish`), so publishing these
    // too is a redundant 30Hz re-eval trigger — and it would defeat the streaming
    // pulse deferral (a held pulse updates these but intentionally does NOT bump a
    // revision, so the host must not observe them directly). `makeItems` reads
    // `threads` directly, which is a value read, not an observation.
    private(set) var entries: [PiAgentTranscriptEntry] = []
    private(set) var threads: [PiAgentTranscriptThread] = []
    @Published private(set) var renderRevision = 0
    @Published private(set) var streamingRevision = 0
    @Published private(set) var autoScrollTurnRevision = 0
    @Published private(set) var lastThreadID: UUID?

    // Memo for `PiAgentScreen.appKitTranscriptItems` (the 20-37ms O(N) items build).
    // Deliberately NOT @Published: written from the items getter during a body pass,
    // and publishing it would re-invalidate the host on every build. Lives here only
    // because this cache object is the screen's stable `@State` companion. Keyed by a
    // signature of every input the build reads — `renderRevision`/`streamingRevision`
    // cover all transcript content, the rest are settings/skills/subagent/session.
    fileprivate var memoizedTranscriptItems: [PiAgentAppKitTranscriptItem] = []
    fileprivate var memoizedTranscriptItemsSignature: Int?
#if DEBUG
    // Last itemsBuild signature inputs, labeled — lets the rebuild-trigger
    // diagnostic name exactly which input invalidated the memo. Not @Published
    // (written during a body pass, same contract as the memo fields above).
    fileprivate var lastItemsBuildComponents: [String: Int] = [:]
#endif

    private var lastSessionID: UUID?
    /// The session whose entries the cache currently holds. The transcript host
    /// stamps this onto the items it builds, so the coordinator can refuse to
    /// apply content built from one session to a table targeting another (the
    /// "new title, old transcript" pass SwiftUI produces on every switch,
    /// because onChange handlers run after the first re-render).
    var contentSessionID: UUID? { lastSessionID }
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

    // Per-block cached render kind, keyed by the block's `baseRevision` — the
    // exact value the cell-reconfigure path treats as authoritative. During
    // streaming the whole items array rebuilds ~30Hz, but only the streaming
    // tail's revision changes; every stable row reuses its cached kind instead
    // of re-running the payload build (chip/skill matching, native-kind
    // assembly). Safe by construction: a freshly built kind is only ever
    // consumed when a cell reconfigures, which happens only on a revision change
    // (a cache miss → fresh build), so a revision-match reuse is byte-identical.
    private var blockKindCache: [String: (revision: Int, kind: PiAgentTranscriptCellKind)] = [:]

    func cachedBlockKind(
        id: String,
        revision: Int,
        make: () -> PiAgentTranscriptCellKind
    ) -> PiAgentTranscriptCellKind {
        if let cached = blockKindCache[id], cached.revision == revision {
            return cached.kind
        }
        let kind = make()
        blockKindCache[id] = (revision, kind)
        return kind
    }

    /// Drop cached kinds for blocks no longer present (session switch, compaction,
    /// thread removal) so the cache stays bounded to the visible transcript.
    func pruneBlockKindCache(keeping ids: Set<String>) {
        if blockKindCache.count > ids.count {
            blockKindCache = blockKindCache.filter { ids.contains($0.key) }
        }
    }

    func scheduleUpdate(sessionID: UUID?, revision: Int, rawEntries: [PiAgentTranscriptEntry]) {
        guard let sessionID else {
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

        if isSessionSwitch {
            publish(rawEntries)
            return
        }

        // First content for an empty transcript — the lazy decode landing right
        // after a session switch. The coordinator is holding the previous
        // session's rows until this publish, so it must not sit out the
        // streaming coalesce window below; land it now.
        if entries.isEmpty, !rawEntries.isEmpty {
            publish(rawEntries)
            return
        }

        // The runner and selected-session revision now provide the sole visible
        // streaming cadence. Publish this already-paced update immediately rather
        // than adding another same-session 33 ms delay.
        publish(rawEntries)
    }

    private func publish(_ rawEntries: [PiAgentTranscriptEntry]) {
        let normalized = normalizeThinkingOrder(
            coalescedCompactionEntries(
                rawEntries.compactMap(normalizedTranscriptEntry).filter(isValuableTranscriptEntry)
            )
        )
        // A store-revision bump from a re-read (file watcher, eviction reload)
        // frequently yields byte-identical content. Publishing it anyway bumps
        // streamingRevision, which pulses every transcript consumer — itemsBuild,
        // updateNSView, apply — and nudges auto-follow on a session where nothing
        // happened. Identical content must be invisible to the UI. (During real
        // streaming the tail differs, so this compare exits on first mismatch.)
        if normalized == entries { return }
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
            bumpStreamingRevisionOrDefer()
        }
#if DEBUG
        streamSimArmIfEnabled()
#endif
    }

    /// Bump the streaming pulse — UNLESS the reader has scrolled away from the
    /// bottom. There the growing row is off-screen, so showing it is pointless, but
    /// the pulse would re-evaluate the SwiftUI transcript host and force the whole
    /// screen scaffold to re-lay-out (StackLayout / FlexFrame `sizeThatFits`, up to
    /// ~166ms) on EVERY token — the "scrolling during a stream hitches/jumps" bug.
    /// Hold it and flush one bump when they return to the bottom (`setUserScrolling`).
    private func bumpStreamingRevisionOrDefer() {
        var defer_ = userScrolling
#if DEBUG
        if UserDefaults.standard.bool(forKey: "StreamDeferDisabled_AB") { defer_ = false }
#endif
        if defer_ {
            hasDeferredStreamingPulse = true
        } else {
            streamingRevision += 1
        }
    }

    /// Set by the transcript coordinator (via the host) while a user scroll gesture
    /// is in flight. While true, streaming pulses are deferred (see `publish`).
    private var userScrolling = false
    private var hasDeferredStreamingPulse = false
    func setUserScrolling(_ scrolling: Bool) {
        guard scrolling != userScrolling else { return }
        userScrolling = scrolling
        if !scrolling, hasDeferredStreamingPulse {
            // Scroll settled — flush the held streaming growth in one pulse so the
            // transcript catches up (off-screen below, or in view if they returned
            // to the bottom) with a single relayout instead of one per token.
            hasDeferredStreamingPulse = false
            streamingRevision += 1
        }
    }

#if DEBUG
    // MARK: - Streaming pulse simulator (perf harness)
    //
    // Reproduces a live response WITHOUT a model: appends a token to the last
    // assistant message at 30Hz, rebuilding threads + bumping streamingRevision
    // exactly like real streaming, so the full pipeline runs — per-token reconcile
    // + row re-tile (regime A) AND the SwiftUI scaffold relayout the pulse triggers
    // (regime B). The 33ms timer's *lateness* measures how congested the main
    // thread is each frame: low avgLate/maxLate = smooth. Bracketed by STREAMSIM
    // markers so HangWatchdog HITCH/HANG lines in the window are attributable.
    //
    //   defaults write streetcoding.agent-deck StreamSimEnabled -bool YES
    //   (StreamSimRounds=3, StreamSimSeconds=6 overridable)
    //   log stream --predicate 'subsystem == "streetcoding.agent-deck" AND (category == "StreamSim" OR category == "HangWatchdog" OR category == "ScrollPerf")' --info
    private static let streamSimLog = Logger(subsystem: "streetcoding.agent-deck", category: "StreamSim")
    private var streamSimTimer: Timer?
    private var streamSimArmed = false
    private var streamSimRoundsLeft = 0
    private var streamSimPulses = 0
    private var streamSimDeadline: CFTimeInterval = 0
    private var streamSimTargetIndex: Int?
    private var streamSimOriginalEntries: [PiAgentTranscriptEntry]?
    private var streamSimHitchAtStart = 0
    private var streamSimHangAtStart = 0
    private var streamSimHangMsAtStart = 0
    private var streamSimRoundNo = 0

    /// Markdown chunk that mimics a real assistant message: heading, prose, a
    /// bullet list and a fenced code block — i.e. a multi-block message whose cell
    /// build is a genuine FULL-REBUILD of many block views (the dominant cost).
    private static let streamSimRichChunks: [String] = [
        "## Plan\nHere's the approach I'd take, broken into a few concrete steps that build on each other.\n\n- Parse the input and validate the shape\n- Walk the tree and collect the candidate nodes\n- Apply the transform and re-measure\n\n```swift\nfunc transform(_ nodes: [Node]) -> [Node] {\n    nodes.map { node in\n        var copy = node\n        copy.resolved = true\n        return copy\n    }\n}\n```\n",
        "### Detail\nThe tricky part is the ordering: each item must be processed before its dependents, otherwise the resolved flag is stale.\n\n1. Topologically sort the graph\n2. Process in dependency order\n3. Verify no cycle remains\n\n```text\nA -> B -> C\nA -> C\n```\nThat means `C` is visited last regardless of the path taken.\n",
    ]

    private func streamSimArmIfEnabled() {
        guard !streamSimArmed,
              UserDefaults.standard.bool(forKey: "StreamSimEnabled"),
              entries.contains(where: { $0.role == .assistant }) else { return }
        streamSimArmed = true
        streamSimRoundsLeft = max(1, UserDefaults.standard.object(forKey: "StreamSimRounds") as? Int ?? 3)
        streamSimOriginalEntries = entries
        Self.streamSimLog.error("STREAMSIM armed — \(self.streamSimRoundsLeft) round(s) on session \(self.lastSessionID?.uuidString.prefix(8) ?? "?", privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.streamSimStartRound() }
    }

    private func streamSimStartRound() {
        guard streamSimRoundsLeft > 0 else {
            streamSimRestore()
            Self.streamSimLog.error("STREAMSIM COMPLETE")
            TranscriptScrollProfiler.fileLog("STREAMSIM COMPLETE")
            return
        }
        guard let idx = entries.lastIndex(where: { $0.role == .assistant }) else {
            Self.streamSimLog.error("STREAMSIM aborted — no assistant entry"); return
        }
        streamSimRoundNo += 1
        streamSimTargetIndex = idx
        let seconds = max(1.0, UserDefaults.standard.object(forKey: "StreamSimSeconds") as? Double ?? 6.0)
        streamSimDeadline = CACurrentMediaTime() + seconds
        streamSimPulses = 0
        streamSimHitchAtStart = HangWatchdog.hitchCount
        streamSimHangAtStart = HangWatchdog.hangCount
        streamSimHangMsAtStart = HangWatchdog.hangMsTotal
        Self.streamSimLog.error("STREAMSIM round \(self.streamSimRoundNo) START (\(seconds, format: .fixed(precision: 0))s @30Hz) ──────────")
        TranscriptScrollProfiler.fileLog("STREAMSIM round \(streamSimRoundNo) START")
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.streamSimTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        streamSimTimer = t
    }

    private func streamSimTick() {
        if CACurrentMediaTime() >= streamSimDeadline { streamSimEndRound(); return }
        guard let idx = streamSimTargetIndex, idx < entries.count else { streamSimEndRound(); return }
        // Every ~22 pulses, append a NEW rich assistant row (a fresh cell build —
        // the dominant real streaming cost). Otherwise grow the active message,
        // which drives per-token reconcile + row re-tile + the follow glide.
        if streamSimPulses % 22 == 21, let sid = entries[idx].sessionID as UUID? {
            let chunk = Self.streamSimRichChunks[streamSimPulses % Self.streamSimRichChunks.count]
            entries.append(PiAgentTranscriptEntry(sessionID: sid, role: .assistant, title: "Assistant", text: chunk))
            streamSimTargetIndex = entries.count - 1
        } else {
            entries[idx].text += (streamSimPulses % 9 == 8) ? "\n\nNext, a fresh paragraph that adds another line or two of streamed prose. " : "token "
        }
        threads = PiAgentTranscriptThread.make(from: entries)
        bumpStreamingRevisionOrDefer()   // honor scroll-away deferral, like real streaming
        streamSimPulses += 1
    }

    private func streamSimEndRound() {
        streamSimTimer?.invalidate(); streamSimTimer = nil
        let hitches = HangWatchdog.hitchCount - streamSimHitchAtStart
        let hangs = HangWatchdog.hangCount - streamSimHangAtStart
        let hangMs = HangWatchdog.hangMsTotal - streamSimHangMsAtStart
        let summary = "STREAMSIM round \(streamSimRoundNo) END pulses=\(streamSimPulses) hitches=\(hitches) hangs=\(hangs) hangMs=\(hangMs) worstHitch=\(HangWatchdog.worstHitchMs)ms"
        Self.streamSimLog.error("\(summary, privacy: .public) ──────────")
        TranscriptScrollProfiler.fileLog(summary)
        streamSimRoundsLeft -= 1
        // Reset the worst-hitch high-water mark between rounds for a per-round read.
        HangWatchdog.worstHitchMs = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.streamSimStartRound() }
    }

    private func streamSimRestore() {
        guard let original = streamSimOriginalEntries else { return }
        entries = original
        threads = PiAgentTranscriptThread.make(from: entries)
        renderRevision += 1
    }
#endif

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
                || entry.isLoopRecapEntry
                || LoopIterationSeparatorCodec.decode(from: entry) != nil
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
        guard !text.isEmpty else { return false }
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
        .native(.of(PiAgentNativeBubbleView.self, prewarmPolicy: .extendedIdle) { view, width in
            view.configure(payload: payload, width: width)
        })
    }
}

/// Resolves a reported row height without allowing a streaming row to shrink
/// below a real measurement at its current width. Tiled estimates deliberately
/// do not participate: a row's first real measurement must be able to replace
/// its initial estimate.
enum TranscriptMeasuredHeightResolver {
    static func resolvedHeight(
        _ measuredHeight: CGFloat,
        priorMeasuredHeight: CGFloat?,
        isStreaming: Bool
    ) -> CGFloat {
        guard isStreaming, let priorMeasuredHeight else { return measuredHeight }
        return max(measuredHeight, priorMeasuredHeight)
    }
}

private struct PiAgentAppKitTranscriptItem {
    let id: String
    let kind: PiAgentTranscriptCellKind
    let contentRevision: Int
    /// Non-nil only for top-level user question rows (`q-<threadID>`). Used by
    /// the transcript-side navigation rail without affecting row layout.
    let questionNavigationTitle: String?
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
        questionNavigationTitle: String? = nil,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        estimatedHeight: @escaping (CGFloat) -> CGFloat = { _ in 120 }
    ) {
        self.id = id
        self.kind = kind
        self.contentRevision = contentRevision
        self.questionNavigationTitle = questionNavigationTitle
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.estimatedHeight = estimatedHeight
    }
}


private enum PiAgentTranscriptTableSection: Hashable {
    case main
}

private struct UserQuestionNavigationRailItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isActive: Bool
    /// Vertical px offset from the rail's center, used only in sliding-window
    /// mode (many questions). 0 = rail center; negative = older (up), positive
    /// = newer (down), mirroring the transcript so marks track their messages.
    var centerOffset: CGFloat = 0
}

private enum TranscriptFloatingControlGeometry {
    static let transcriptHorizontalPadding: CGFloat = 18
    static let jumpToLatestTrailingPadding: CGFloat = 22
    static let questionRailCollapsedWidth: CGFloat = 22
    static let questionRailRowHeight: CGFloat = 22
    static let questionRailRowSpacing: CGFloat = 6
    static let questionRailVerticalPadding: CGFloat = 16
    static let questionScrollTopPadding: CGFloat = 12

    /// The rail is hosted inside the AppKit scroll view, while the scroll-to-bottom
    /// FAB is hosted by the surrounding SwiftUI ZStack. Compensate for the transcript
    /// SwiftUI horizontal padding so both trailing strokes land on the same screen x.
    static var questionRailTrailingInsetInsideScrollView: CGFloat {
        max(0, jumpToLatestTrailingPadding - transcriptHorizontalPadding)
    }
}

struct QuestionRailVisibilityPolicy {
    func shouldShow(questionCount: Int, evenStackedHeight: CGFloat, railHeight: CGFloat) -> Bool {
        questionCount >= 2 && railHeight >= 44
    }
}

struct QuestionRailActiveQuestionResolver {
    let landingOffset: CGFloat
    let visibleHeight: CGFloat
    let bottomTolerance: CGFloat

    init(landingOffset: CGFloat, visibleHeight: CGFloat, bottomTolerance: CGFloat = 2) {
        self.landingOffset = landingOffset
        self.visibleHeight = visibleHeight
        self.bottomTolerance = bottomTolerance
    }

    func activeID(questions: [(id: String, minY: CGFloat)], viewportY: CGFloat, documentHeight: CGFloat) -> String? {
        guard !questions.isEmpty else { return nil }
        let maxY = max(0, documentHeight - visibleHeight)
        if maxY - viewportY < bottomTolerance {
            return questions.last?.id
        }

        let anchorY = viewportY + landingOffset
        return questions.last(where: { $0.minY <= anchorY })?.id ?? questions.first?.id
    }
}

struct QuestionRailScrollLandingResolver {
    let landingOffset: CGFloat
    let visibleHeight: CGFloat
    let tolerance: CGFloat
    let maxCorrections: Int

    init(landingOffset: CGFloat, visibleHeight: CGFloat, tolerance: CGFloat = 1, maxCorrections: Int = 6) {
        self.landingOffset = landingOffset
        self.visibleHeight = visibleHeight
        self.tolerance = tolerance
        self.maxCorrections = maxCorrections
    }

    func targetY(rowMinY: CGFloat, documentHeight: CGFloat) -> CGFloat {
        let maxY = max(0, documentHeight - visibleHeight)
        return min(max(0, rowMinY - landingOffset), maxY)
    }

    func needsCorrection(currentY: CGFloat, rowMinY: CGFloat, documentHeight: CGFloat) -> CGFloat? {
        let nextY = targetY(rowMinY: rowMinY, documentHeight: documentHeight)
        return abs(nextY - currentY) > tolerance ? nextY : nil
    }
}

enum QuestionRailKeyboardDirection {
    case previous
    case next
}

struct QuestionRailKeyboardNavigator {
    func targetID(questionIDs: [String], activeID: String?, direction: QuestionRailKeyboardDirection) -> String? {
        guard questionIDs.count >= 2 else { return nil }
        guard let activeID, let currentIndex = questionIDs.firstIndex(of: activeID) else {
            return direction == .previous ? questionIDs.last : questionIDs.first
        }

        switch direction {
        case .previous:
            guard currentIndex > questionIDs.startIndex else { return nil }
            return questionIDs[questionIDs.index(before: currentIndex)]
        case .next:
            let nextIndex = questionIDs.index(after: currentIndex)
            guard nextIndex < questionIDs.endIndex else { return nil }
            return questionIDs[nextIndex]
        }
    }
}

@MainActor
private protocol QuestionRailKeyboardNavigationHandling: AnyObject {
    func handleQuestionRailKeyboardShortcut(_ event: NSEvent) -> Bool
}

@MainActor
private final class PiAgentTranscriptTableView: NSTableView {
    weak var questionNavigationHandler: QuestionRailKeyboardNavigationHandling?

    override func keyDown(with event: NSEvent) {
        if questionNavigationHandler?.handleQuestionRailKeyboardShortcut(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class PiAgentTranscriptScrollView: NSScrollView {
    weak var questionNavigationHandler: QuestionRailKeyboardNavigationHandling?

    override func keyDown(with event: NSEvent) {
        if questionNavigationHandler?.handleQuestionRailKeyboardShortcut(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Observable rail data. Mutated by the transcript coordinator on scroll/apply;
/// the hosted rail view is created ONCE and never replaced, so SwiftUI `@State`
/// (hover) survives every scroll/update tick instead of being reset — replacing
/// the hosted view every scroll tick was the root cause of the hover buzz.
@MainActor
private final class QuestionRailModel: ObservableObject {
    @Published var items: [UserQuestionNavigationRailItem] = []
    @Published var availableWidth: CGFloat = 0
    /// Host (visible) rail height in px. Used by the overflow view's scroll frame.
    @Published var railHeight: CGFloat = 0
    /// True when the questions no longer fit as an evenly-spaced stack — the view
    /// then switches to a compact vertical scroller with edge fades.
    @Published var isSliding = false
}

private struct UserQuestionNavigationRail: View {
    @ObservedObject var model: QuestionRailModel
    let onSelect: (String) -> Void

    @State private var hoveredID: String?

    private let expandAnimation = Animation.interpolatingSpring(mass: 0.75, stiffness: 320, damping: 30)
    private let fadeAnimation = Animation.easeOut(duration: 0.14)
    private let collapsedMarkWidth = TranscriptFloatingControlGeometry.questionRailCollapsedWidth

    private var expandedRowWidth: CGFloat {
        Self.expandedWidth(for: model.availableWidth)
    }

    private var activeOverflowItemID: String? {
        model.items.first(where: { $0.isActive })?.id
    }

    static func expandedWidth(for availableWidth: CGFloat) -> CGFloat {
        let desiredWidth = max(168, availableWidth * 0.22)
        let availableEdgeWidth = max(96, availableWidth - 112)
        return min(248, desiredWidth, availableEdgeWidth)
    }

    var body: some View {
        // Two layouts share the same rows and hover/opacity behavior:
        //  - stack (default): evenly-spaced marks, the look already approved.
        //  - overflow: when questions don't fit, keep every question reachable in
        //    a compact vertical scroller instead of hiding the rail.
        Group {
            if model.isSliding {
                overflowBody
            } else {
                stackedBody
            }
        }
        .opacity(hoveredID == nil ? 0.72 : 1)
        .animation(expandAnimation, value: hoveredID)
        .animation(fadeAnimation, value: hoveredID == nil)
        .onHover { hovering in
            // Nothing reacts until a mark is actually under the pointer. We only
            // use the container hover to clear when the pointer leaves the rail
            // entirely, so the expanded preview stays interactive while reading.
            if !hovering { hoveredID = nil }
        }
    }

    private var stackedBody: some View {
        // Container is FIXED at the expanded width. Collapsed rows occupy only
        // their trailing mark strip; the empty left region has no hit shape, so
        // clicks pass straight through to the transcript. Only the hovered row
        // grows left to reveal its preview.
        VStack(alignment: .trailing, spacing: TranscriptFloatingControlGeometry.questionRailRowSpacing) {
            ForEach(model.items) { item in
                row(for: item)
            }
        }
        .frame(width: expandedRowWidth, alignment: .trailing)
        .padding(.vertical, 8)
    }

    private var overflowBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: TranscriptFloatingControlGeometry.questionRailRowSpacing) {
                    ForEach(model.items) { item in
                        row(for: item)
                            .id(item.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 8)
            }
            .frame(width: expandedRowWidth, height: max(1, model.railHeight), alignment: .trailing)
            .transcriptEdgeFade(height: 16)
            .onAppear { scrollOverflowActive(proxy) }
            .onChange(of: activeOverflowItemID) { _, _ in scrollOverflowActive(proxy) }
            .onChange(of: model.items) { _, _ in scrollOverflowActive(proxy) }
        }
    }

    private func scrollOverflowActive(_ proxy: ScrollViewProxy) {
        guard model.isSliding, let activeOverflowItemID else { return }
        withTransaction(Transaction(animation: nil)) {
            proxy.scrollTo(activeOverflowItemID, anchor: .center)
        }
    }

    private func row(for item: UserQuestionNavigationRailItem) -> some View {
        let isActive = item.isActive
        let isHovered = item.id == hoveredID

        return Button {
            onSelect(item.id)
        } label: {
            HStack(spacing: 8) {
                if isHovered {
                    Text(displayText(for: item))
                        .font(AppTheme.Font.caption.weight(.medium))
                        .foregroundStyle(textColor(isActive: isActive, isHovered: isHovered))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: expandedRowWidth - 44, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: false)
                }

                mark(isActive: isActive, isHovered: isHovered, isRailHovered: hoveredID != nil)
            }
            // The host remains fixed-width to avoid hover/layout feedback loops,
            // but the visible hover pill hugs its content inside that stable host.
            .frame(maxWidth: isHovered ? expandedRowWidth : collapsedMarkWidth, alignment: .trailing)
            .frame(height: TranscriptFloatingControlGeometry.questionRailRowHeight)
            .padding(.leading, isHovered ? 11 : 0)
            .padding(.trailing, isHovered ? 7 : 0)
            .background(rowBackground(isActive: isActive, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(displayText(for: item))
        .accessibilityLabel(displayText(for: item))
        .accessibilityHint("Scroll to this question")
        .onHover { hovering in
            if hovering { hoveredID = item.id }
        }
    }

    private func mark(isActive: Bool, isHovered: Bool, isRailHovered: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(markColor(isActive: isActive, isHovered: isHovered, isRailHovered: isRailHovered))
            .frame(width: isActive ? 14 : (isHovered ? 14 : 7), height: isActive || isHovered ? 3 : 2)
    }

    private func markColor(isActive: Bool, isHovered: Bool, isRailHovered: Bool) -> Color {
        if isActive { return AppTheme.brandAccent }
        if isHovered { return .primary }
        return Color.secondary.opacity(isRailHovered ? 0.68 : 0.50)
    }

    private func textColor(isActive: Bool, isHovered: Bool) -> Color {
        if isActive { return AppTheme.brandAccent }
        if isHovered { return .primary }
        return .secondary
    }

    @ViewBuilder
    private func rowBackground(isActive: Bool, isHovered: Bool) -> some View {
        if isHovered {
            let fill = isActive ? AppTheme.brandAccent.opacity(0.16) : Color.secondary.opacity(0.10)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
                .glassEffect(.regular.tint(AppTheme.glassTint.opacity(0.14)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 1)
        } else {
            Color.clear
        }
    }

    private func displayText(for item: UserQuestionNavigationRailItem) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty message)" }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}

private final class UserQuestionNavigationRailHostView: NSHostingView<UserQuestionNavigationRail> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating "scroll to latest" affordance shown when the transcript is not
/// pinned to the bottom — tapping it scrolls to the newest content and
/// re-engages streaming auto-follow.
private struct JumpToLatestPill: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // Fill the full 32pt circle inside the button label so the whole pill
            // is the hit target — not just the glyph. The frame/contentShape must
            // live on the label (the button's interactive region), not outside it.
            Image(systemName: "chevron.down")
                .font(AppTheme.Font.footnote.weight(.bold))
                .offset(x: 0.5, y: 0.5)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .foregroundStyle(AppTheme.brandAccent)
        .glassEffect(.regular.tint(AppTheme.brandAccent.opacity(0.16)), in: Circle())
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

/// Holds the transcript's pinned-to-bottom flag in a reference type so the screen
/// can keep it in `@State` (which watches identity only). Scrolling flips this
/// constantly; only `JumpToLatestOverlay` observes it, so flips don't invalidate
/// the screen body or re-run the transcript items build.
private final class TranscriptPinnedState: ObservableObject {
    @Published var isPinned = true
}

/// The "jump to latest" pill, isolated so that toggling pinned-to-bottom on scroll
/// re-renders only this small view — never the screen body / transcript host.
private struct JumpToLatestOverlay: View {
    @ObservedObject var pinnedState: TranscriptPinnedState
    let onJump: () -> Void

    var body: some View {
        ZStack {
            if !pinnedState.isPinned {
                JumpToLatestPill(action: onJump)
                    .padding(.trailing, TranscriptFloatingControlGeometry.jumpToLatestTrailingPadding)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: pinnedState.isPinned)
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
    /// Truncated navigation title for top-level user-question rows.
    var questionNavigationTitle: String? = nil
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
    /// Read LIVE (like `makeItems`), never captured as a value: the host
    /// re-evaluates on render-cache pulses without the parent re-running, and a
    /// stale captured flag kept the switch "hold" active one SwiftUI round-trip
    /// after the transcript had already decoded — a visible lag on every switch.
    let isTranscriptLoading: () -> Bool
    let bottomScrollRequest: Int
    let makeItems: () -> [PiAgentAppKitTranscriptItem]
    let onPinnedToBottomChange: (Bool) -> Void
    let onBenchAdvanceSession: () -> Void
    let benchSessionCount: () -> Int

    var body: some View {
        PiAgentAppKitTranscriptView(
            items: makeItems(),
            sessionID: sessionID,
            itemsSessionID: cache.contentSessionID,
            isTranscriptLoading: isTranscriptLoading(),
            renderRevision: cache.renderRevision,
            streamingRevision: cache.streamingRevision,
            autoScrollTurnRevision: cache.autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest,
            onPinnedToBottomChange: onPinnedToBottomChange,
            onScrollingChange: { [cache] scrolling in cache.setUserScrolling(scrolling) },
            onBenchAdvanceSession: onBenchAdvanceSession,
            benchSessionCount: benchSessionCount
        )
    }
}

private struct PiAgentAppKitTranscriptView: NSViewRepresentable {
    let items: [PiAgentAppKitTranscriptItem]
    let sessionID: UUID?
    /// Which session the render cache's content belonged to when `items` were
    /// built. Differs from `sessionID` during the switch transition passes.
    let itemsSessionID: UUID?
    let isTranscriptLoading: Bool
    let renderRevision: Int
    let streamingRevision: Int
    let autoScrollTurnRevision: Int
    let bottomScrollRequest: Int
    let onPinnedToBottomChange: (Bool) -> Void
    /// Called as the user starts/stops scrolling history; the cache uses it to
    /// defer streaming pulses (and the scaffold relayout they cause) until settle.
    let onScrollingChange: (Bool) -> Void
    /// Advance selection to the next session (the ⌘] action). Used only by the
    /// scroll benchmark to sweep multiple chats; nil disables multi-session.
    var onBenchAdvanceSession: (() -> Void)?
    var benchSessionCount: (() -> Int)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPinnedToBottomChange: onPinnedToBottomChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = PiAgentTranscriptTableView()
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

        let scrollView = PiAgentTranscriptScrollView()
        // Layer-backed so row-removal reflows (re-run rewind, visibility toggles)
        // can crossfade via a CATransition on this layer.
        scrollView.wantsLayer = true
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
        // Keep AppKit insets at zero. The top fade compensation is a real table
        // spacer row, so the first visible row starts in the same precise place
        // on the initial layout, before any scroll event reconciles NSScrollView
        // contentInsets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let coordinator = context.coordinator
        let questionRailModel = QuestionRailModel()
        let questionRail = UserQuestionNavigationRailHostView(
            rootView: UserQuestionNavigationRail(model: questionRailModel) { [weak coordinator] id in
                coordinator?.scrollToUserQuestion(id: id)
            }
        )
        questionRail.translatesAutoresizingMaskIntoConstraints = true
        questionRail.autoresizingMask = [.minXMargin, .height]
        questionRail.setFrameSize(.zero)
        // The rail floats over the transcript. Its frame is fixed at the expanded
        // width; transparent regions pass clicks through to the transcript because
        // the SwiftUI content has no hit shape there.
        scrollView.addSubview(questionRail)

        tableView.questionNavigationHandler = context.coordinator
        scrollView.questionNavigationHandler = context.coordinator
        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.questionRail = questionRail
        context.coordinator.questionRailModel = questionRailModel
        context.coordinator.onBenchAdvanceSession = onBenchAdvanceSession
        context.coordinator.benchSessionCount = benchSessionCount
        context.coordinator.onScrollingChange = onScrollingChange
        context.coordinator.setupDataSource(for: tableView)
        context.coordinator.setupScrollObservation(scrollView)
        context.coordinator.updateColumnWidthIfNeeded()
        do {
            // The initial apply can publish rail state through its hosted SwiftUI
            // view, just like updateNSView; defer those model writes until this
            // representable lifecycle pass has completed.
            context.coordinator.isInsideNSViewUpdate = true
            defer { context.coordinator.isInsideNSViewUpdate = false }
            context.coordinator.apply(
                items: items,
                sessionID: sessionID,
                itemsSessionID: itemsSessionID,
                isTranscriptLoading: isTranscriptLoading,
                renderRevision: renderRevision,
                streamingRevision: streamingRevision,
                autoScrollTurnRevision: autoScrollTurnRevision,
                bottomScrollRequest: bottomScrollRequest
            )
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        TranscriptScrollProfiler.measureBody("updateNSView") {
            let coordinator = context.coordinator
            TranscriptScrollProfiler.measurePhase("updateNSView.prep") {
                coordinator.onPinnedToBottomChange = onPinnedToBottomChange
                coordinator.onBenchAdvanceSession = onBenchAdvanceSession
                coordinator.benchSessionCount = benchSessionCount
                coordinator.onScrollingChange = onScrollingChange
                coordinator.updateColumnWidthIfNeeded()
            }
            coordinator.isInsideNSViewUpdate = true
            defer { coordinator.isInsideNSViewUpdate = false }
            coordinator.apply(
                items: items,
                sessionID: sessionID,
                itemsSessionID: itemsSessionID,
                isTranscriptLoading: isTranscriptLoading,
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
    final class Coordinator: NSObject, NSTableViewDelegate, QuestionRailKeyboardNavigationHandling {
        weak var scrollView: NSScrollView?
        weak var tableView: NSTableView?
        weak var questionRail: UserQuestionNavigationRailHostView?
        var questionRailModel: QuestionRailModel?
        private var dataSource: NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>?

        // Render-product cache: one persistent cell per item id, returned to the
        // diffable data source instead of recycling an arbitrary pooled cell. The
        // expensive part of a vend is building the cell's content (markdown blocks,
        // tool sections); `measuredHeightByID` already caches the *height*, but the
        // built *views* were rebuilt every time a recycled cell took on a new item.
        // Pinning a cell to its item means scrolling back re-hosts the finished cell
        // and `configure(...)` is a no-op (same id/revision/width) — no rebuild — and
        // a cell only ever renders one item, so there is no content bleed. Bounded
        // LRU (offscreen entries evicted; re-vending just rebuilds them) and purged
        // for items dropped from the transcript in `apply(...)`.
        private var cellCache: [String: TranscriptTableCellView] = [:]
        private var cellCacheLRU: [String] = []        // least-recent first, MRU at end
        // A cache miss is a full native rebuild (view tree + markdown parse +
        // text layout, 5-60ms per row) landing synchronously in a scroll-time
        // vend — the dominant dropped-frame cost when sweeping a long session
        // (sampled: AutoSizingMarkdownTextView.intrinsicContentSize + fullRebuild
        // dominate the hitch stacks). LRU order is vend order, so the cap is the
        // span of rows that scroll up-and-down without thrashing; 160 sat just
        // under a real reading session's working set. Worst case adds memory for
        // ~224 more retained rows, traded deliberately for hitch-free reversal.
        private let cellCacheLimit = 384

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
        private let benchShortDuration: CFTimeInterval = UserDefaults.standard.object(forKey: "BenchShortSec") as? Double ?? 2.5
        private let benchLongDuration: CFTimeInterval = UserDefaults.standard.object(forKey: "BenchLongSec") as? Double ?? 7
        /// Long full-sweeps run back-to-back per session: repeated traversals are
        /// far more likely to surface a hang/hitch than a single pass (the first
        /// pass warms caches; a stall that survives into passes 2–3 is the real
        /// jank). Each pass is its own profiler gesture, so each gets a summary
        /// and can trip the hitch backtrace independently.
        private let benchLongRepeats = UserDefaults.standard.object(forKey: "BenchLongRepeats") as? Int ?? 3

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
        private var pendingGlideLandingSettleWork: DispatchWorkItem?
        private var pendingSessionSwitchSettleWork: DispatchWorkItem?
        private var sessionSwitchSettleGeneration = 0
        private var pendingRemeasureWork: DispatchWorkItem?
        private var pendingRemeasureIDs = Set<String>()
        private var pendingScrollSettle = false
        private var pendingWidthWork: DispatchWorkItem?
        private var widthReconfigureGeneration = 0
        private var lastWidthChangeTime: CFTimeInterval = 0
        private let widthChangeSettleWindow: CFTimeInterval = 0.30
        // Smooth auto-follow. The streaming follow doesn't snap to the bottom each
        // batch (that reads as a step every ~130ms); instead a 60fps timer eases
        // the clip origin toward the *current* bottom each frame, continuously
        // chasing the growing document so the motion is a glide. It disengages the
        // instant the user scrolls (checked per tick + on live-scroll start + on
        // any user-driven bounds change). Explicit scrolls (send, jump-to-latest,
        // session switch) still snap — see `performScrollToBottom(_:animated:forceLayout:)`.
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
        private var isAutoFollowing = true {
            didSet {
                guard isAutoFollowing != oldValue else { return }
                // Scrolled away from the bottom → tell the cache to DEFER streaming
                // pulses (the off-screen growing row would otherwise force a full
                // SwiftUI scaffold relayout — up to ~166ms — every token). Returned
                // to the bottom → resume + flush. This is what makes scrolling /
                // reading history during a live stream smooth.
                onScrollingChange?(!isAutoFollowing)
            }
        }
        private var isProgrammaticScroll = false
        private var forcedActiveQuestionID: String?
        /// True only while SwiftUI's `NSViewRepresentable.makeNSView` or
        /// `updateNSView` lifecycle pass is on the stack. Mutating the rail's
        /// `ObservableObject` during either pass emits "Publishing changes from
        /// within view updates is not allowed", so model writes are deferred to
        /// the next runloop when this is set.
        var isInsideNSViewUpdate = false
        /// Increments for every rail state calculation, so a queued lifecycle
        /// write cannot replace a newer synchronous scroll update.
        private var railModelUpdateGeneration = 0
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
            let rowIndex: Int
            let offsetFromRowTop: CGFloat
        }

        init(onPinnedToBottomChange: @escaping (Bool) -> Void) {
            self.onPinnedToBottomChange = onPinnedToBottomChange
        }

        func setupDataSource(for tableView: NSTableView) {
            dataSource = makeDataSource(for: tableView)
            tableView.delegate = self
        }

        /// AppKit's table diffable data source has no
        /// `applySnapshotUsingReloadData` counterpart. Replacing the source gives
        /// a session switch a clean snapshot baseline, avoiding reconciliation of
        /// the previous session's unrelated identifiers.
        private func makeDataSource(for tableView: NSTableView) -> NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String> {
            NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>(tableView: tableView) { [weak self] _, _, row, id in
                guard let self, let item = self.itemByID[id] else { return NSView() }
                let cell = self.cachedCell(for: id)
                self.configure(cell, with: item, row: row)
                return cell
            }
        }

        /// The persistent cell for `id` — reused across vends so its built content
        /// survives scrolling off and back. Created on first use, then cached.
        private func cachedCell(for id: String) -> TranscriptTableCellView {
            if let cached = cellCache[id] {
                touchCell(id)
                return cached
            }
            let cell = TranscriptTableCellView(frame: .zero)
            cell.identifier = TranscriptTableCellView.reuseIdentifier
            // The live cell reports its own height once it has laid out — the
            // coordinator caches it and re-tiles the row. No offscreen render: the
            // cell had to lay out for display anyway.
            cell.onMeasuredHeight = { [weak self] itemID, height in
                self?.reportMeasuredHeight(height, forItemID: itemID)
            }
            cellCache[id] = cell
            cellCacheLRU.append(id)
            evictCellsIfNeeded()
            return cell
        }

        private func touchCell(_ id: String) {
            if let idx = cellCacheLRU.firstIndex(of: id) { cellCacheLRU.remove(at: idx) }
            cellCacheLRU.append(id)
        }

        // MARK: - Idle pre-warm
        //
        // Building a transcript cell (markdown block stack, or a tool-group /
        // subagent card) costs 10-46ms for a heavy row, and a long session has
        // dozens. Doing it lazily on the scroll path is the dominant scroll hitch
        // (a 130-row session = ~458ms of construction). Instead, after a session
        // settles, build the off-screen cells during idle in small time-budgeted
        // slices, so by the time the user scrolls the cells are already cached and
        // the vend is a no-op configure. Yields to the user: paused while a scroll
        // gesture or streaming is in flight, resumed when idle.
        private var prewarmQueue: [String] = []
        private var prewarmScheduled = false
        /// IDs blocked from prewarm because a single build exceeded the per-row
        /// cost cap — a heavy row that eats the whole slice budget would otherwise
        /// be retried every idle tick and starve the rows behind it. Cleared on
        /// session switch and width change (geometry/content invalidate the
        /// block — the row may be cheaper to build at the new width or not exist).
        private var prewarmBlockedIDs: Set<String> = []
        /// Hard per-row cost cap: if a single prewarm build exceeds roughly one
        /// 120Hz frame, the row is blocked from future prewarm attempts so the
        /// budget goes to cheaper rows instead.
        private let prewarmPerRowCostCapMs: Double = 8.0
        /// Speculative offscreen prewarm is enabled by default for cheap/medium rows:
        /// current hitch samples convict fresh visible cell vend (`FRESH-VIEW` builds)
        /// during scroll, while heavy rows and offscreen height measurement remain
        /// blocked below to avoid the old prewarm TextKit hang signature. Keep a
        /// defaults kill switch for A/B without changing visible-row rendering.
        /// Disable with: `defaults write streetcoding.agent-deck TranscriptPrewarmDisabled -bool YES`.
        private static let prewarmDisabled: Bool = {
            guard let value = UserDefaults.standard.object(forKey: "TranscriptPrewarmDisabled") as? Bool else { return false }
            return value
        }()
        /// Per-runloop-slice main-thread budget. Kept under half a 120Hz frame so a
        /// slice never itself drops a frame; construction is spread across ticks.
        private let prewarmSliceBudgetMs: Double = 4.0
        /// Kill switch for the old offscreen height-measurement path. Keeping this
        /// off by default avoids surprise main-thread TextKit/layout stalls while
        /// preserving visible-row rendering and measurement behavior.
        private static let prewarmMeasuresHeights: Bool = {
            UserDefaults.standard.bool(forKey: "TranscriptPrewarmMeasureHeightsEnabled")
        }()
        private let prewarmWidthChangeCooldown: CFTimeInterval = 0.35
        /// Prewarm is speculative, so it stays farther behind user/display work than
        /// normal scroll handling. The regular user-scroll grace protects visible
        /// behaviors; this longer prewarm-only grace keeps idle cell construction out
        /// of the post-gesture layout/display tail that still showed up in hitch
        /// samples as `prewarmStep → configure → installNativeRow`.
        private let prewarmUserScrollGraceWindow: CFTimeInterval = 0.9
        private let prewarmExtendedIdleWindow: CFTimeInterval = 2.5
        private let prewarmRetryDelay: CFTimeInterval = 0.25
        private let prewarmInterSliceDelay: CFTimeInterval = 0.05
        private let prewarmMaxEstimatedHeight: CGFloat = 340
        private var lastPrewarmBlockingActivityTime: CFTimeInterval = CACurrentMediaTime()

        private func extendedPrewarmIdleReady(now: CFTimeInterval) -> Bool {
            let lastBlockingActivity = max(lastPrewarmBlockingActivityTime, max(lastUserScrollTime, lastWidthChangeTime))
            return now - lastBlockingActivity >= prewarmExtendedIdleWindow
        }

        private func isPrewarmEligible(_ item: PiAgentAppKitTranscriptItem, extendedIdleReady: Bool) -> Bool {
            guard case .native(let spec) = item.kind else { return false }
            switch spec.prewarmPolicy {
            case .immediate:
                break
            case .extendedIdle:
                guard extendedIdleReady else { return false }
            case .disabled:
                return false
            }
            return item.estimatedHeight(contentWidth) <= prewarmMaxEstimatedHeight
        }

        func schedulePrewarm() {
            guard !Self.prewarmDisabled, let tableView else { return }
            let now = CACurrentMediaTime()
            let widthSettlesIn = prewarmWidthChangeCooldown - (now - lastWidthChangeTime)
            if widthSettlesIn > 0 {
                guard !prewarmScheduled else { return }
                prewarmScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + widthSettlesIn) { [weak self] in
                    guard let self else { return }
                    self.prewarmScheduled = false
                    self.schedulePrewarm()
                }
                return
            }
            // While scrolling, keep speculative pre-warm completely off the path:
            // an already-active profiler window covers both real gestures and the
            // autonomous programmatic scroll bench, and any fresh cell build inside
            // it shows up as scroll-vend/prewarm hitch stack contention. While
            // streaming AND still pinned to the bottom, skip too: new rows arrive
            // every pulse and the visible streaming row owns the main thread, so a
            // heavy pre-warm build would hitch what the reader is watching. But once
            // the reader has scrolled UP to read history (auto-follow off), the
            // stream is off-screen — pre-warm the history they're scrolling toward so
            // those rows are already built (no construction stutter) once idle.
            if profiler.isScrollWindowActive || (profiler.isStreamingRecently && isAutoFollowing) {
                lastPrewarmBlockingActivityTime = now
                guard !prewarmScheduled else { return }
                prewarmScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { return }
                    self.prewarmScheduled = false
                    self.schedulePrewarm()
                }
                return
            }
            // Build the work list: every row without a live cached cell, in document
            // order, capped to the cache limit (pre-warming past it would just evict
            // what we built). Streaming/following and active-scroll periods defer
            // above so the visible path takes priority.
            let extendedIdleReady = extendedPrewarmIdleReady(now: now)
            let pending = orderedIDs.filter { id in
                guard cellCache[id] == nil, !prewarmBlockedIDs.contains(id) else { return false }
                guard let item = itemByID[id] else { return false }
                return isPrewarmEligible(item, extendedIdleReady: extendedIdleReady)
            }
            guard !pending.isEmpty, cellCache.count < cellCacheLimit else {
                let hasDeferredCandidate = !extendedIdleReady && cellCache.count < cellCacheLimit && orderedIDs.contains { id in
                    guard cellCache[id] == nil, !prewarmBlockedIDs.contains(id), let item = itemByID[id] else { return false }
                    return isPrewarmEligible(item, extendedIdleReady: true)
                }
                guard hasDeferredCandidate, !prewarmScheduled else { return }
                prewarmScheduled = true
                let delay = max(prewarmRetryDelay, prewarmExtendedIdleWindow - (now - max(lastPrewarmBlockingActivityTime, max(lastUserScrollTime, lastWidthChangeTime))))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.prewarmScheduled = false
                    self.schedulePrewarm()
                }
                return
            }
            // Build outward from the viewport: the user scrolls away from where they
            // are (the view opens pinned to the bottom), so rows nearest the visible
            // range should be ready first. Order pending ids by row distance from the
            // current visible window's centre.
            let visible = tableView.rows(in: tableView.visibleRect)
            let anchorRow = visible.length > 0 ? visible.location + visible.length / 2 : orderedIDs.count - 1
            let indexByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
            let ordered = pending.sorted { (indexByID[$0] ?? 0) - anchorRow == 0 ? false :
                abs((indexByID[$0] ?? 0) - anchorRow) < abs((indexByID[$1] ?? 0) - anchorRow) }
            prewarmQueue = Array(ordered.prefix(cellCacheLimit - cellCache.count))
            guard !prewarmScheduled else { return }
            prewarmScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prewarmStep() }
        }

        private func prewarmStep() {
            prewarmScheduled = false
            guard !Self.prewarmDisabled, tableView != nil else { prewarmQueue.removeAll(); return }
            // Don't compete with an active scroll gesture, live streaming, or a
            // settling width change — retry shortly. (Streaming re-tiles + the
            // follow glide own the main thread; width changes reconfigure visible
            // cells and can otherwise cascade into speculative offscreen work.)
            let now = CACurrentMediaTime()
            let widthSettlesIn = prewarmWidthChangeCooldown - (now - lastWidthChangeTime)
            let prewarmScrollGraceActive = isLiveScrolling || now - lastUserScrollTime < prewarmUserScrollGraceWindow
            let displayOrLayoutWorkPending = pendingHeightWork != nil
                || pendingScrollWork != nil
                || pendingSettleScrollWork != nil
                || pendingGlideLandingSettleWork != nil
                || pendingRemeasureWork != nil
            if prewarmScrollGraceActive || profiler.isScrollWindowActive || profiler.isStreamingRecently || widthSettlesIn > 0 || displayOrLayoutWorkPending {
                lastPrewarmBlockingActivityTime = now
                prewarmScheduled = true
                let delay = max(prewarmRetryDelay, widthSettlesIn)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.prewarmStep() }
                return
            }
            let extendedIdleReady = extendedPrewarmIdleReady(now: now)
            if !extendedIdleReady {
                let hasOnlyDeferredRows = prewarmQueue.contains { id in
                    guard let item = itemByID[id] else { return false }
                    return isPrewarmEligible(item, extendedIdleReady: true)
                        && !isPrewarmEligible(item, extendedIdleReady: false)
                }
                if hasOnlyDeferredRows {
                    prewarmScheduled = true
                    let delay = max(prewarmRetryDelay, prewarmExtendedIdleWindow - (now - max(lastPrewarmBlockingActivityTime, max(lastUserScrollTime, lastWidthChangeTime))))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.prewarmStep() }
                    return
                }
            }
            prewarmQueue.removeAll { id in
                guard let item = itemByID[id] else { return true }
                return !isPrewarmEligible(item, extendedIdleReady: extendedIdleReady)
            }
            let start = CACurrentMediaTime()
#if DEBUG
            var builtThisSlice = 0
#endif
            while !prewarmQueue.isEmpty {
                let id = prewarmQueue.removeFirst()
                // Skip rows that scrolled into view (already built), vanished, or
                // are not on the cheap prewarm allow-list. Native tool-group/diff
                // rows can build deep AppKit trees in one configure call, before
                // the slice budget can yield; leave them to the visible path.
                guard cellCache[id] == nil, !prewarmBlockedIDs.contains(id),
                      let item = itemByID[id], isPrewarmEligible(item, extendedIdleReady: extendedIdleReady),
                      let row = orderedIDs.firstIndex(of: id) else { continue }
                let cell = cachedCell(for: id)
                let rowStart = CACurrentMediaTime()
                configure(cell, with: item, row: row, via: "prewarm")
                // Hard per-row cap: if this single build exceeded the cost
                // threshold, block it from future prewarm so a pathological row
                // can't starve the budget every idle tick. The row will still
                // build on the scroll path when actually needed.
                let rowCostMs = (CACurrentMediaTime() - rowStart) * 1000
                if rowCostMs >= prewarmPerRowCostCapMs {
                    prewarmBlockedIDs.insert(id)
#if DEBUG
                    TranscriptScrollProfiler.fileLog("PREWARM blocked id=\(id.suffix(6)) cost=\(String(format: "%.1f", rowCostMs))ms")
#endif
                }
                // Do not force an offscreen layout by default. The old path called
                // `forcedIntrinsicHeight()` here, which is good for future scroll
                // stability but can spend hundreds of milliseconds in TextKit/AppKit
                // on the main thread after a sidebar/window width change. Visible
                // rows still measure themselves through the normal on-layout path.
                if Self.prewarmMeasuresHeights {
                    let h = cell.forcedIntrinsicHeight()
                    if h > 0 {
                        let height = ceil(h)
                        measuredHeightByID[id, default: [:]][widthBucket] = height
                        lastNotedHeight[id] = height
                    }
                }
#if DEBUG
                builtThisSlice += 1
#endif
                if (CACurrentMediaTime() - start) * 1000 >= prewarmSliceBudgetMs { break }
            }
            if prewarmQueue.isEmpty {
#if DEBUG
                if builtThisSlice > 0 {
                    TranscriptScrollProfiler.fileLog("PREWARM done cached=\(cellCache.count)/\(orderedIDs.count)")
                }
#endif
            } else {
                prewarmScheduled = true
                // Yield beyond one runloop turn between slices. A zero-delay async
                // chain can still monopolize the main actor during AppKit's post-
                // scroll display/layout tail; a short idle gap keeps speculative
                // construction from piling onto the same frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + prewarmInterSliceDelay) { [weak self] in self?.prewarmStep() }
            }
        }

        /// Drop least-recently-vended cached cells over the cap. Never evicts a row
        /// that's currently on screen (its cell is live), so eviction only releases
        /// offscreen views — which simply rebuild when scrolled back to.
        private func evictCellsIfNeeded() {
            guard cellCacheLRU.count > cellCacheLimit else { return }
            let visible = visibleIDs()
            var i = 0
            while cellCacheLRU.count > cellCacheLimit, i < cellCacheLRU.count {
                let id = cellCacheLRU[i]
                if visible.contains(id) { i += 1; continue }
                cellCacheLRU.remove(at: i)
                cellCache.removeValue(forKey: id)
            }
        }

        /// Forget cached cells for items no longer in the transcript. Called from
        /// `apply(...)` so a removed/replaced message doesn't pin its view forever.
        private func purgeCellCache(keeping ids: Set<String>) {
            guard !cellCache.isEmpty else { return }
            for id in cellCache.keys where !ids.contains(id) {
                cellCache.removeValue(forKey: id)
            }
            cellCacheLRU.removeAll { !ids.contains($0) }
        }

        private func visibleIDs() -> Set<String> {
            guard let tableView else { return [] }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return [] }
            var result = Set<String>()
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                result.insert(orderedIDs[row])
            }
            return result
        }

        private func updateQuestionRail() {
            guard let scrollView, let tableView, questionRailModel != nil else { return }
            let questionRows = currentQuestionRows()
            let stackedHeight = evenStackedHeight(questionCount: questionRows.count)
            let railHeight = questionRailHeight(scrollView: scrollView, questionCount: questionRows.count)
            updateQuestionRailFrame(for: scrollView, railHeight: railHeight)

            let shouldShowRail = QuestionRailVisibilityPolicy().shouldShow(
                questionCount: questionRows.count,
                evenStackedHeight: stackedHeight,
                railHeight: railHeight
            )
            guard shouldShowRail else {
                forcedActiveQuestionID = nil
                questionRail?.isHidden = true
                applyRailModel(items: [], width: scrollView.bounds.width, railHeight: railHeight, isSliding: false)
                return
            }

            questionRail?.isHidden = false
            let rowIDs = Set(questionRows.map { $0.id })
            if let forcedActiveQuestionID, !rowIDs.contains(forcedActiveQuestionID) {
                self.forcedActiveQuestionID = nil
            }
            let activeID = self.forcedActiveQuestionID ?? activeQuestionID(in: questionRows, scrollView: scrollView, tableView: tableView)

            let isOverflowing = stackedHeight > railHeight
            let items = questionRows.map { _, id, title in
                UserQuestionNavigationRailItem(id: id, title: title, isActive: id == activeID)
            }
            applyRailModel(items: items, width: scrollView.bounds.width, railHeight: railHeight, isSliding: isOverflowing)
        }

        private func evenStackedHeight(questionCount: Int) -> CGFloat {
            let rowHeight = TranscriptFloatingControlGeometry.questionRailRowHeight
            let rowSpacing = TranscriptFloatingControlGeometry.questionRailRowSpacing
            let verticalPadding = TranscriptFloatingControlGeometry.questionRailVerticalPadding
            return CGFloat(questionCount) * rowHeight + CGFloat(max(0, questionCount - 1)) * rowSpacing + verticalPadding
        }

        private func questionRailHeight(scrollView: NSScrollView, questionCount: Int) -> CGFloat {
            let desired = evenStackedHeight(questionCount: questionCount)
            return min(max(54, scrollView.bounds.height - 32), max(44, desired))
        }

        /// Push rail data to the hosted view. `updateQuestionRail()` runs both on
        /// scroll (synchronous is fine) and inside `makeNSView`/`updateNSView` ->
        /// `apply` (NOT fine: SwiftUI holds its view-update lock there, and mutating
        /// the `ObservableObject` synchronously emits "Publishing changes from within
        /// view updates"). Defer to the next runloop when inside either pass.
        private func applyRailModel(items: [UserQuestionNavigationRailItem], width: CGFloat, railHeight: CGFloat, isSliding: Bool) {
            railModelUpdateGeneration &+= 1
            let generation = railModelUpdateGeneration
            if isInsideNSViewUpdate {
                Task { @MainActor [weak self, items] in
                    guard let self,
                          self.railModelUpdateGeneration == generation,
                          let model = self.questionRailModel else { return }
                    self.assignRailModel(model, items: items, width: width, railHeight: railHeight, isSliding: isSliding)
                }
            } else if let model = questionRailModel {
                assignRailModel(model, items: items, width: width, railHeight: railHeight, isSliding: isSliding)
            }
        }

        private func assignRailModel(
            _ model: QuestionRailModel,
            items: [UserQuestionNavigationRailItem],
            width: CGFloat,
            railHeight: CGFloat,
            isSliding: Bool
        ) {
            if model.items != items { model.items = items }
            if model.availableWidth != width { model.availableWidth = width }
            if model.railHeight != railHeight { model.railHeight = railHeight }
            if model.isSliding != isSliding { model.isSliding = isSliding }
        }

        private func updateQuestionRailFrame(for scrollView: NSScrollView, railHeight: CGFloat) {
            guard let rail = questionRail else { return }
            // Host frame is FIXED at the expanded width (trailing-aligned to the
            // scroll-to-bottom FAB). It must NOT resize on hover — resizing the
            // host while the pointer is over it is what caused the hover loop.
            let railWidth = UserQuestionNavigationRail.expandedWidth(for: scrollView.bounds.width)
            let trailingInset = TranscriptFloatingControlGeometry.questionRailTrailingInsetInsideScrollView
            let newFrame = NSRect(
                x: scrollView.bounds.width - railWidth - trailingInset,
                y: (scrollView.bounds.height - railHeight) / 2,
                width: railWidth,
                height: railHeight
            )
            // Skip the assign when unchanged: re-setting the frame every scroll
            // tick would force an NSHostingView re-layout and can stutter hover.
            if rail.frame != newFrame { rail.frame = newFrame }
        }

        private func questionRailLandingOffset(for visibleHeight: CGFloat) -> CGFloat {
            TranscriptFloatingControlGeometry.questionScrollTopPadding
        }

        private func activeQuestionID(
            in questionRows: [(row: Int, id: String, title: String)],
            scrollView: NSScrollView,
            tableView: NSTableView
        ) -> String? {
            guard !questionRows.isEmpty else { return nil }
            let clipBounds = scrollView.contentView.bounds
            let documentHeight = max(scrollView.documentView?.frame.height ?? tableView.bounds.height, clipBounds.height)
            let maxY = max(0, documentHeight - clipBounds.height)
            if maxY - clipBounds.origin.y < 2 {
                return questionRows.last?.id
            }

            let resolver = QuestionRailActiveQuestionResolver(
                landingOffset: questionRailLandingOffset(for: clipBounds.height),
                visibleHeight: clipBounds.height
            )
            let questions = questionRows.map { row, id, _ in
                (id: id, minY: tableView.rect(ofRow: row).minY)
            }
            return resolver.activeID(
                questions: questions,
                viewportY: clipBounds.origin.y,
                documentHeight: documentHeight
            )
        }

        private func currentQuestionRows() -> [(row: Int, id: String, title: String)] {
            guard let tableView, let dataSource else { return [] }
            return (0 ..< tableView.numberOfRows).compactMap { row in
                guard let id = dataSource.itemIdentifier(forRow: row),
                      let title = itemByID[id]?.questionNavigationTitle else { return nil }
                return (row, id, title)
            }
        }

        private func tableRow(forItemID id: String) -> Int? {
            guard let tableView, let dataSource else { return nil }
            return (0 ..< tableView.numberOfRows).first { row in
                dataSource.itemIdentifier(forRow: row) == id
            }
        }

        func handleQuestionRailKeyboardShortcut(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            guard modifiers == .shift else { return false }

            let direction: QuestionRailKeyboardDirection
            switch event.keyCode {
            case 126: direction = .previous // Shift-Up
            case 125: direction = .next     // Shift-Down
            default: return false
            }

            guard let scrollView, let tableView else { return true }
            let questionRows = currentQuestionRows()
            guard questionRows.count >= 2 else { return true }
            let activeID = forcedActiveQuestionID ?? activeQuestionID(in: questionRows, scrollView: scrollView, tableView: tableView)
            let questionIDs = questionRows.map(\.id)
            if let targetID = QuestionRailKeyboardNavigator().targetID(questionIDs: questionIDs, activeID: activeID, direction: direction) {
                scrollToUserQuestion(id: targetID)
            }
            return true
        }

        func scrollToUserQuestion(id: String) {
            guard let scrollView, let tableView, let row = tableRow(forItemID: id), row >= 0, row < tableView.numberOfRows else { return }
            stopFollowGlide()
            isAutoFollowing = false
            publishPinnedState(false)
            forcedActiveQuestionID = id
            updateQuestionRail()
            isProgrammaticScroll = true
            let clipView = scrollView.contentView
            let landingOffset = questionRailLandingOffset(for: clipView.bounds.height)
            let resolver = QuestionRailScrollLandingResolver(landingOffset: landingOffset, visibleHeight: clipView.bounds.height)
            let targetY = resolver.targetY(
                rowMinY: tableView.rect(ofRow: row).minY,
                documentHeight: max(scrollView.documentView?.frame.height ?? tableView.bounds.height, clipView.bounds.height)
            )

            // NSTableView measures row heights lazily as rows scroll into view, so
            // `rect(ofRow:)` for a far-offscreen target is computed from ESTIMATED
            // heights. A single correction was not enough when each landing revealed
            // more real row heights; users had to click the same rail item again.
            // Keep correcting until the measured row position stabilizes.
            animateQuestionRailLanding(to: targetY, row: row, resolver: resolver, correction: 0, duration: 0.32)
        }

        private func animateQuestionRailLanding(
            to targetY: CGFloat,
            row: Int,
            resolver: QuestionRailScrollLandingResolver,
            correction: Int,
            duration: TimeInterval
        ) {
            guard let scrollView, let tableView else {
                isProgrammaticScroll = false
                updateQuestionRail()
                return
            }
            let clipView = scrollView.contentView
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.0, 0.0, 1.0)
                clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
            } completionHandler: { [weak self, weak scrollView, weak clipView, weak tableView] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let tableView, let clipView, let scrollView else {
                        self.isProgrammaticScroll = false
                        self.updateQuestionRail()
                        return
                    }
                    scrollView.reflectScrolledClipView(clipView)
                    let documentHeight = max(scrollView.documentView?.frame.height ?? tableView.bounds.height, clipView.bounds.height)
                    if correction < resolver.maxCorrections,
                       let correctedY = resolver.needsCorrection(
                           currentY: clipView.bounds.origin.y,
                           rowMinY: tableView.rect(ofRow: row).minY,
                           documentHeight: documentHeight
                       ) {
                        self.animateQuestionRailLanding(to: correctedY, row: row, resolver: resolver, correction: correction + 1, duration: 0.10)
                        return
                    }
                    self.isProgrammaticScroll = false
                    self.updateQuestionRail()
                }
            }
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
                        self.forcedActiveQuestionID = nil
                        // Authoritative user-scroll timestamp — covers mouse
                        // wheels and scroller drags that post no live-scroll
                        // notification at all.
                        self.lastUserScrollTime = CACurrentMediaTime()
                        // Let the background project rescan know the transcript is
                        // being scrolled so it defers its observable-churning refresh
                        // until the gesture settles (avoids a mid-scroll itemsBuild).
                        TranscriptInteractionGate.noteInteraction()
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
                        self.pendingGlideLandingSettleWork?.cancel()
                        self.pendingGlideLandingSettleWork = nil
                        self.pendingScrollSettle = false
                    }
                    // Clip-view bounds change before the scrollView frame notification fires,
                    // so resync column width here to avoid a one-frame horizontal overflow
                    // when the inspector slides in or the window resizes.
                    self.updateColumnWidthIfNeeded()
                    self.updateQuestionRail()
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
                    self?.updateQuestionRail()
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
                    self.pendingGlideLandingSettleWork?.cancel()
                    self.pendingGlideLandingSettleWork = nil
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
                    TranscriptInteractionGate.noteInteraction()
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
            pendingGlideLandingSettleWork?.cancel()
            pendingSessionSwitchSettleWork?.cancel()
            pendingRemeasureWork?.cancel()
            pendingRemeasureIDs.removeAll()
            pendingWidthWork?.cancel()
            stopFollowGlide()
        }

        func apply(
            items: [PiAgentAppKitTranscriptItem],
            sessionID: UUID?,
            itemsSessionID: UUID?,
            isTranscriptLoading: Bool,
            renderRevision: Int,
            streamingRevision: Int,
            autoScrollTurnRevision: Int,
            bottomScrollRequest: Int
        ) {
            guard let tableView, scrollView != nil else { return }
            let wasFollowing = isAutoFollowing
            let isSessionSwitch = self.sessionID != sessionID
            // A switch must apply EXACTLY ONCE, with the right content. Two
            // transition passes try to sneak in earlier and each used to render
            // as a visible step:
            //  1. The first re-render after a selection change still carries the
            //     PREVIOUS session's cache content (SwiftUI runs onChange — which
            //     publishes the new session — only after this pass). Items built
            //     from another session never apply to this one.
            //  2. The new transcript may still be decoding off disk; applying
            //     would show the loading placeholder, then the content. Hold the
            //     old rows until the decode lands (cold start, with nothing on
            //     screen yet, still shows the loading card).
            if isSessionSwitch, !orderedIDs.isEmpty {
                if let itemsSessionID, let sessionID, itemsSessionID != sessionID { return }
                if isTranscriptLoading { return }
            }
            let structuralUpdate = lastRenderRevision != renderRevision
            let streamingUpdate = lastStreamingRevision != streamingRevision
            let explicitScroll = lastAutoScrollTurnRevision != autoScrollTurnRevision || lastBottomScrollRequest != bottomScrollRequest

            let prep = TranscriptScrollProfiler.measurePhase("apply.prep") {
                var nextIDs: [String] = []
                nextIDs.reserveCapacity(items.count)
                var revisionChanged = false
                for item in items {
                    nextIDs.append(item.id)
                    // True iff some row's content revision moved (mirrors the
                    // `changedIDs` test below). Catches updates that don't bump
                    // renderRevision/streamingRevision — e.g. skill/visibility/
                    // subagent context folded into per-item revisions during itemsBuild.
                    if contentRevisionByID[item.id] != item.contentRevision {
                        revisionChanged = true
                    }
                }
                return (nextIDs: nextIDs, idsChanged: nextIDs != orderedIDs, revisionChanged: revisionChanged)
            }
            let nextIDs = prep.nextIDs
            let idsChanged = prep.idsChanged
            let revisionChanged = prep.revisionChanged

            // SwiftUI re-runs updateNSView on every screen-body re-evaluation,
            // including ones driven by unrelated state (e.g. sidebar selection).
            // When neither the rows, their revisions, nor any scroll/structural
            // signal moved, there is nothing to do — bail before the O(N)
            // dictionary rebuilds, snapshot diff, reconfigure, scroll handling, and
            // column refit below. (Column width is handled separately in
            // updateNSView via updateColumnWidthIfNeeded.)
            if !isSessionSwitch && !idsChanged && !revisionChanged
                && !structuralUpdate && !streamingUpdate && !explicitScroll {
                return
            }

            // Stamp streaming activity up front so every profiler line emitted by
            // the builds/re-tiles below is tagged [stream] vs [static] — the shared
            // capture mixes "scrolling a finished transcript" with "live generation"
            // and they need opposite fixes.
            if streamingUpdate {
                profiler.noteStreamingActivity()
                TranscriptInteractionGate.noteStreaming()
            }
#if DEBUG
            if streamingUpdate { maybeRunStreamScrollTest() }
#endif

            self.items = items
            let dictionaries = TranscriptScrollProfiler.measurePhase("apply.dictionaries") {
                let nextItemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                let nextRevisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.contentRevision) })
                return (itemByID: nextItemsByID, revisions: nextRevisions)
            }
            itemByID = dictionaries.itemByID
            let nextRevisions = dictionaries.revisions

#if DEBUG
            // Names what woke a real apply(). An idle session should never reach
            // this line; when it does, the trigger identifies the pulse source.
            let trigger = [
                isSessionSwitch ? "sessionSwitch" : nil,
                idsChanged ? "ids" : nil,
                revisionChanged ? "revisions" : nil,
                structuralUpdate ? "structural" : nil,
                streamingUpdate ? "streaming" : nil,
                explicitScroll ? "explicitScroll" : nil
            ].compactMap { $0 }.joined(separator: "+")
            if TranscriptScrollProfiler.verboseTrace {
                TranscriptScrollProfiler.logger.error("apply work — trigger: \(trigger, privacy: .public)")
            }
#endif

            if isSessionSwitch || idsChanged {
                let anchor = (!isSessionSwitch && !explicitScroll && !wasFollowing) ? captureScrollAnchor() : nil
#if DEBUG
                let coldT0 = isSessionSwitch ? CACurrentMediaTime() : 0
                let coldCacheBefore = isSessionSwitch ? cellCache.count : 0
#endif
                if isSessionSwitch {
                    pendingHeightIDs.removeAll()
                    pendingHeightWork?.cancel()
                    pendingHeightWork = nil
                    pendingRemeasureWork?.cancel()
                    pendingRemeasureWork = nil
                    pendingRemeasureIDs.removeAll()
                    pendingSessionSwitchSettleWork?.cancel()
                    pendingSessionSwitchSettleWork = nil
                    sessionSwitchSettleGeneration &+= 1
                    // A new session's rows may have completely different
                    // construction costs; clear the block list so rows that
                    // were too expensive in the previous session get a fresh
                    // evaluation.
                    prewarmBlockedIDs.removeAll()
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
                // Release cached cells for rows the transcript no longer has (removed
                // messages, or every row on a session switch) so their views don't
                // linger pinned to absent ids.
                purgeCellCache(keeping: Set(nextIDs))
                for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
                // In-session row REMOVALS (re-run rewind, visibility toggles)
                // land as a hard cut: rows vanish, content below snaps up, the
                // follow-up rows pop in. Cover that reflow with a brief
                // crossfade. Session switches deliberately do NOT fade: the
                // swap is correct on its first frame (hold-until-loaded +
                // synchronous viewport settle), and an instant swap reads
                // cleaner than a transition — a fade can stall visibly when
                // the switch itself drops frames. Never during streaming.
                if !isSessionSwitch, !streamingUpdate, !removedIDs.isEmpty, let layer = scrollView?.layer {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.28
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(fade, forKey: "transcript-removal-fade")
                }
                applySnapshot(ids: nextIDs, replacingSession: isSessionSwitch) { [weak self] in
                    guard let self else { return }
                    // Visible cells whose content changed (same id, new revision) are NOT
                    // reconfigured automatically by the diffable data source — it only
                    // touches cells whose ids changed. Walk the visible window and
                    // reconfigure those whose item revision has shifted.
                    self.reconfigureChangedVisibleCells()
                    self.restoreScrollAnchorIfNeeded(anchor)
                    // Rows were added/removed (or the session switched) — content
                    // geometry genuinely moved, so passive follow may act on it.
                    self.handleScrollAfterUpdate(isSessionSwitch: isSessionSwitch, explicitScroll: explicitScroll, wasFollowing: wasFollowing, contentAdvanced: true)
#if DEBUG
                    if isSessionSwitch {
                        let ms = (CACurrentMediaTime() - coldT0) * 1000
                        let built = self.cellCache.count - coldCacheBefore
                        TranscriptScrollProfiler.fileLog("COLDSTART session=\(self.sessionID?.uuidString.prefix(8) ?? "?") rows=\(self.orderedIDs.count) builtCells=\(built) ms=\(String(format: "%.0f", ms))")
                    }
#endif
                    // Build off-screen cells during idle so scrolling never pays
                    // the per-row construction cost (the dominant scroll hitch).
                    self.schedulePrewarm()
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
                    let changedIDSet = Set(changedIDs)
                    // The selected transcript is already paced by the runner; configure
                    // each visible changed row in this incoming update rather than
                    // delaying it through a second streaming reconfigure timer.
                    reconfigureVisibleCellsForIDs(changedIDSet)
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
                    //
                    // BUT that forced layout is the dominant cost on screen — a
                    // full `layoutSubtreeIfNeeded` of the streaming cell's subtree
                    // (nested stacks + hosted SwiftUI islands → sizeThatFits),
                    // tens of ms every token, on the main thread. It only earns
                    // its keep while pinned to the bottom, where the squish→snap
                    // would be visible under the reader. Once auto-follow is off
                    // the reader is up in history: the growing bottom row is
                    // offscreen or held by the anchor, so the squish is invisible.
                    // There we skip the forced measure entirely and let the
                    // debounced async path (reportMeasuredHeight → noteHeights
                    // changed) re-tile and anchor-compensate ~16ms later — no
                    // per-token main-thread storm, which is what hangs/wobbles a
                    // not-following stream. `pinnedToBottom` mirrors the
                    // `willAutoFollow` test noteHeightsChanged uses below.
                    //
                    // The forced measure is ALSO restricted to real content
                    // publishes (streaming growth / structure changes). Rows can
                    // report a new revision with no transcript publish at all —
                    // the session-level chrome/context hash (skills, visibility,
                    // subagent summary) folds into every row's contentRevision —
                    // and apply() can be running inside NSHostingView.layout().
                    // Forcing layoutSubtreeIfNeeded there is illegal re-entrancy
                    // (_NSDetectedLayoutRecursion). Those rare chrome reconfigures
                    // re-tile via the debounced async path instead; only the
                    // pinned streaming row needs its height in this same pass.
                    let pinnedToBottom = wasFollowing && !isUserScrollingRecently
                        && (streamingUpdate || structuralUpdate)
                    if pinnedToBottom {
                        let retileIDs = profiler.measureForced {
                            measureChangedCellsSynchronously(
                                changedIDSet,
                                budgetMs: 4,
                                maxRows: 1,
                                deferUnmeasured: true
                            )
                        }
                        if !retileIDs.isEmpty {
                            flushPendingHeightWorkSynchronously()
                            noteHeightsChanged(forIDs: retileIDs)
                        }
                    }
                } else if streamingUpdate || structuralUpdate {
                    publishPinnedState(isAutoFollowing)
                }
                handleScrollAfterUpdate(
                    isSessionSwitch: false,
                    explicitScroll: explicitScroll,
                    wasFollowing: wasFollowing,
                    contentAdvanced: !changedIDs.isEmpty
                )
            }

            self.sessionID = sessionID
            lastRenderRevision = renderRevision
            lastStreamingRevision = streamingRevision
            lastAutoScrollTurnRevision = autoScrollTurnRevision
            lastBottomScrollRequest = bottomScrollRequest
            tableView.sizeLastColumnToFit()
            updateQuestionRail()
            maybeStartScrollBenchmark()
#if DEBUG
            if isSessionSwitch { buildBenchDone = false; scrollProbeDone = false }
            maybeRunBuildBench()
            maybeRunScrollProbe()
#endif
        }

#if DEBUG
        // Reproduces the user's actual scenario: REAL simulated scrolling (the bench
        // scroll driver scrolls the clip view without the programmatic flag, so the
        // bounds observer treats it as a genuine user scroll) WHILE StreamSim streams.
        // Measures (a) HangWatchdog hitches during the stream+scroll window and (b)
        // viewport drift after the scroll stops (glide-yank check).
        //   defaults write streetcoding.agent-deck StreamScrollTestEnabled -bool YES
        private var streamScrollTestDone = false
        private func maybeRunStreamScrollTest() {
            guard !streamScrollTestDone,
                  UserDefaults.standard.bool(forKey: "StreamScrollTestEnabled"),
                  scrollView != nil, orderedIDs.count > 20 else { return }
            streamScrollTestDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                // Scroll UP 600px as a genuine user scroll (no programmatic flag, so
                // the bounds observer registers it and sets isAutoFollowing=false).
                guard let tableView = self.tableView else { return }
                let clip = scrollView.contentView
                let target = max(0, clip.bounds.origin.y - 600)
                clip.scroll(to: NSPoint(x: 0, y: target)); scrollView.reflectScrolledClipView(clip)
                // Record the top-visible ROW + its offset on screen — the true "is the
                // content I'm reading holding still" signal (origin.y alone drifts as
                // the document grows above/below, which is benign).
                let topRow = tableView.row(at: NSPoint(x: 0, y: clip.bounds.origin.y + 4))
                let topID = (topRow >= 0 && topRow < self.orderedIDs.count) ? self.orderedIDs[topRow] : ""
                let topOffset0 = topRow >= 0 ? clip.bounds.origin.y - tableView.rect(ofRow: topRow).minY : 0
                let h0 = HangWatchdog.hitchCount
                HangWatchdog.worstHitchMs = 0
                let upd0 = TranscriptScrollProfiler.bodyCallCount("updateNSView")
                let rev0 = self.lastStreamingRevision
                TranscriptScrollProfiler.fileLog("STREAMSCROLL away topID=\(topID.suffix(6)) following=\(self.isAutoFollowing) — holding 4s while streaming")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    guard let self, let tableView = self.tableView, let clip = self.scrollView?.contentView else { return }
                    let rowNow = self.orderedIDs.firstIndex(of: topID) ?? -1
                    let topOffset1 = rowNow >= 0 ? clip.bounds.origin.y - tableView.rect(ofRow: rowNow).minY : -99999
                    let visualShift = Int(topOffset1 - topOffset0)
                    let updates = TranscriptScrollProfiler.bodyCallCount("updateNSView") - upd0
                    let pulses = self.lastStreamingRevision - rev0
                    TranscriptScrollProfiler.fileLog("STREAMSCROLL end updateNSView-calls=\(updates) streamPulsesSeen=\(pulses) hitches=\(HangWatchdog.hitchCount - h0) worstHitch=\(HangWatchdog.worstHitchMs)ms VISUAL-SHIFT=\(visualShift)px")
                }
            }
        }

        private var scrollProbeDone = false
        /// Deterministic per-session scroll probe: on each session switch, if the
        /// session is big enough to be interesting, wait for pre-warm to settle then
        /// run one scroll pass. The profiler gesture summary (with the rows= finger-
        /// print) captures hitches + hostCreate, so the SAME heavy session can be
        /// compared pre-warm ON vs OFF just by cycling sessions with Cmd-].
        ///   defaults write streetcoding.agent-deck ScrollProbeEnabled -bool YES
        private func maybeRunScrollProbe() {
            guard !scrollProbeDone,
                  UserDefaults.standard.bool(forKey: "ScrollProbeEnabled"),
                  tableView != nil, orderedIDs.count > 25 else { return }
            scrollProbeDone = true
            probeWhenPrewarmed(attempt: 0)
        }

        private func probeWhenPrewarmed(attempt: Int) {
            // Wait for the idle pre-warm to drain (ON case) so the probe scrolls a
            // fully-warmed session; OFF case has nothing pending and proceeds. Cap
            // the wait so a stuck queue can't block the probe forever.
            if !Self.prewarmDisabled, (prewarmScheduled || !prewarmQueue.isEmpty), attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.probeWhenPrewarmed(attempt: attempt + 1)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.orderedIDs.count > 25 else { return }
                self.updateBenchFingerprint()
                self.profiler.setBenchTag("probe")
                self.runScrollPass(duration: 4.0, step: 40) { [weak self] in
                    self?.profiler.setBenchTag(nil)
                }
            }
        }
#endif

#if DEBUG
        private var buildBenchDone = false
        /// Deterministic construction microbenchmark: build EVERY row's cell of the
        /// current session once (into the cache, off the scroll path) and report
        /// total + worst construction cost. Repeatable on the same restored session,
        /// so it isolates the cell-build fix from scroll/session-order noise.
        ///   defaults write streetcoding.agent-deck BuildBenchEnabled -bool YES
        private func maybeRunBuildBench() {
            guard !buildBenchDone,
                  UserDefaults.standard.bool(forKey: "BuildBenchEnabled"),
                  tableView != nil, orderedIDs.count > 5 else { return }
            buildBenchDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runBuildBench() }
        }

        private func runBuildBench() {
            guard let tableView else { return }
            // Drop any cached cells so this measures cold construction of the whole
            // session, not just the rows that haven't been vended yet.
            cellCache.removeAll(); cellCacheLRU.removeAll()
            let ids = orderedIDs
            let t0 = CACurrentMediaTime()
            var total = 0.0
            var built = 0
            for (row, id) in ids.enumerated() {
                guard let item = itemByID[id] else { continue }
                let cell = cachedCell(for: id)
                let s = CACurrentMediaTime()
                configure(cell, with: item, row: row, via: "buildbench")
                total += (CACurrentMediaTime() - s) * 1000
                built += 1
            }
            let wall = (CACurrentMediaTime() - t0) * 1000
            let line = "BUILDBENCH cells=\(built) total=\(String(format: "%.0f", total))ms wall=\(String(format: "%.0f", wall))ms session=\(self.sessionID?.uuidString.prefix(8) ?? "?") rows=\(ids.count)"
            TranscriptScrollProfiler.logger.error("\(line, privacy: .public)")
            TranscriptScrollProfiler.fileLog(line)
            // Force a redisplay so the table isn't left showing stale cached cells.
            tableView.reloadData()
        }
#endif

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
                // .error so it shows in default console captures — this run drives
                // session switches + programmatic scrolls and MUST be unmissable
                // (an enabled flag once masqueraded as idle-session scroll glitches).
                TranscriptScrollProfiler.logger.error("SCROLLBENCH armed (ScrollBenchEnabled defaults flag) — sweeping up to \(self.benchTargetSessions) of \(self.benchScopedCount) session(s); disable: defaults delete streetcoding.agent-deck ScrollBenchEnabled")
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
            TranscriptScrollProfiler.logger.error("SCROLLBENCH \(label, privacy: .public) rows=\(tableView.numberOfRows)")

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
                TranscriptScrollProfiler.fileLog("SCROLLBENCH COMPLETE tested=\(benchSessionsTested)")
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

        private func applySnapshot(
            ids: [String],
            replacingSession: Bool = false,
            completion: @escaping () -> Void
        ) {
            let snapshot = TranscriptScrollProfiler.measurePhase("apply.snapshotBuild") {
                var snapshot = NSDiffableDataSourceSnapshot<PiAgentTranscriptTableSection, String>()
                snapshot.appendSections([.main])
                snapshot.appendItems(ids, toSection: .main)
                return snapshot
            }
            TranscriptScrollProfiler.measurePhase("apply.snapshotSubmit") {
                if replacingSession, let tableView {
                    // AppKit does not expose UIKit's
                    // `applySnapshotUsingReloadData`. Start a fresh data source
                    // instead, so this wholesale session replacement has an empty
                    // snapshot baseline rather than diffing unrelated old IDs.
                    dataSource = makeDataSource(for: tableView)
                    dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
                } else {
                    // Current-session changes stay incremental so their existing
                    // visible-cell reconciliation and follow behavior are intact.
                    dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
                }
            }
        }

        func updateColumnWidthIfNeeded() {
            guard let tableView else { return }
            let width = currentViewportWidth()
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            lastWidthChangeTime = CACurrentMediaTime()
            prewarmQueue.removeAll()
            // Width changes can alter which rows are expensive to build (text
            // reflow changes block count), so clear the block list and let
            // rows be re-evaluated at the new width.
            prewarmBlockedIDs.removeAll()
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

            scheduleVisibleWidthReconfigure()
        }

        private func scheduleVisibleWidthReconfigure() {
            pendingWidthWork?.cancel()
            widthReconfigureGeneration += 1
            let generation = widthReconfigureGeneration
            let scheduledWidth = contentWidth
            let scheduledChangeTime = lastWidthChangeTime
            let delay = max(0, widthChangeSettleWindow - (CACurrentMediaTime() - scheduledChangeTime))
#if DEBUG
            if TranscriptScrollProfiler.verboseTrace {
                TranscriptScrollProfiler.fileLog("WIDTH reconfig scheduled width=\(String(format: "%.0f", scheduledWidth)) delay=\(String(format: "%.0f", delay * 1000))ms")
            }
#endif
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard generation == self.widthReconfigureGeneration else { return }
                self.pendingWidthWork = nil
                let widthChangedAgain = abs(self.contentWidth - scheduledWidth) > 0.5 || self.lastWidthChangeTime != scheduledChangeTime
                let quietFor = CACurrentMediaTime() - self.lastWidthChangeTime
                guard !widthChangedAgain, quietFor >= self.widthChangeSettleWindow else {
#if DEBUG
                    if TranscriptScrollProfiler.verboseTrace {
                        TranscriptScrollProfiler.fileLog("WIDTH reconfig reschedule quietFor=\(String(format: "%.0f", quietFor * 1000))ms")
                    }
#endif
                    self.scheduleVisibleWidthReconfigure()
                    return
                }
#if DEBUG
                if TranscriptScrollProfiler.verboseTrace {
                    TranscriptScrollProfiler.fileLog("WIDTH reconfig visible width=\(String(format: "%.0f", self.contentWidth))")
                }
#endif
                self.reconfigureAllVisibleCells()
            }
            pendingWidthWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
                configure(cell, with: item, row: row, via: "snapshot-reconfig")
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
                configure(cell, with: item, row: row, via: "stream-reconfig")
            }
        }

        private func canPerformSynchronousTranscriptLayout() -> Bool {
            guard tableView?.window?.inLiveResize != true else { return false }
            // Only suppress forced layout in states known to be unsafe/re-entrant.
            // Active scrolling/streaming still need same-turn anchor compensation;
            // skipping it causes visible jumps when rows above the viewport settle.
            return !isInsideNSViewUpdate
        }

        /// Force-lay-out freshly-reconfigured visible cells for `ids` and write
        /// their true heights into `measuredHeightByID` synchronously, so a re-tile
        /// issued in this same pass uses the new content height. The pinned
        /// streaming path passes a tiny budget and bottom-first ordering: measure
        /// the newest visible changed row to preserve anti-wobble, then let any
        /// remaining rows settle through the normal async height-report path.
        /// Returns the ids whose tiled height actually needs to change.
        private func measureChangedCellsSynchronously(
            _ ids: Set<String>,
            budgetMs: Double? = nil,
            maxRows: Int? = nil,
            deferUnmeasured: Bool = false
        ) -> Set<String> {
            guard let tableView, !ids.isEmpty else { return [] }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return [] }
            let visibleRows = (visible.location ..< visible.location + visible.length)
                .filter { $0 < orderedIDs.count && ids.contains(orderedIDs[$0]) }
                .sorted(by: >)
            guard !visibleRows.isEmpty else { return [] }

            var needRetile = Set<String>()
            var deferredIDs = Set<String>()
            let streaming = profiler.isStreamingRecently
            let start = CACurrentMediaTime()
            var measuredCount = 0

            for row in visibleRows {
                let id = orderedIDs[row]
                if let maxRows, measuredCount >= maxRows {
                    deferredIDs.insert(id)
                    continue
                }
                if measuredCount > 0, let budgetMs,
                   (CACurrentMediaTime() - start) * 1000 >= budgetMs {
                    deferredIDs.insert(id)
                    continue
                }
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                let h = cell.forcedIntrinsicHeight()
                measuredCount += 1
                guard h > 0 else { continue }
                let priorMeasured = measuredHeightByID[id]?[widthBucket]
                let height = TranscriptMeasuredHeightResolver.resolvedHeight(
                    ceil(h),
                    priorMeasuredHeight: priorMeasured,
                    isStreaming: streaming
                )
                // `lastNotedHeight` tracks AppKit's current tile exclusively for
                // deciding whether this fresh measurement requires a re-tile.
                let previousTiled = lastNotedHeight[id] ?? -1
#if DEBUG
                // Smoking-gun: the streaming row's tiled height per token, folded
                // with the measure path that produced it (set inside forcedIntrinsic
                // → markdown measureHeight just above). A Δ<0 here = visible wobble.
                TranscriptStreamWobbleProbe.shared.noteTile(
                    id: id, height: height, previousTiled: previousTiled,
                    width: contentWidth, pinned: true, gliding: followGlideTimer != nil, source: "sync")
#endif
                measuredHeightByID[id, default: [:]][widthBucket] = height
                if abs(previousTiled - height) > heightChangeEpsilon {
                    needRetile.insert(id)
                }
            }

            if deferUnmeasured, !deferredIDs.isEmpty {
                scheduleVisibleHeightRemeasure(forIDs: deferredIDs)
            }
            return needRetile
        }

        private func scheduleVisibleHeightRemeasure(forIDs ids: Set<String>) {
            guard !ids.isEmpty else { return }
            pendingRemeasureIDs.formUnion(ids)
            guard pendingRemeasureWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let ids = self.pendingRemeasureIDs
                self.pendingRemeasureIDs.removeAll()
                self.pendingRemeasureWork = nil
                guard !self.isUserScrollingRecently else {
                    self.scheduleVisibleHeightRemeasure(forIDs: ids)
                    return
                }
                let retileIDs = self.measureChangedCellsSynchronously(ids, budgetMs: 5, deferUnmeasured: true)
                guard !retileIDs.isEmpty else { return }
                self.flushPendingHeightWorkSynchronously()
                self.noteHeightsChanged(forIDs: retileIDs)
            }
            pendingRemeasureWork = work
            let delay = isUserScrollingRecently ? 0.05 : heightReportInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
                configure(cell, with: item, row: row, via: "width-reconfig")
            }
        }

        private func configure(_ cell: TranscriptTableCellView, with item: PiAgentAppKitTranscriptItem, row: Int, via: String = "scroll-vend") {
            let width = currentViewportWidth()
            // Each cell owns its own NSHostingView for its lifetime. Recycling
            // a cell for a new item just swaps the host's rootView — never
            // detaches the host. That's what keeps multiple visible cells from
            // ever contending for a single shared host (the bug fixed here).
            profiler.noteConfigure()
            let deferWidthOnlySettle = CACurrentMediaTime() - lastWidthChangeTime < widthChangeSettleWindow
            cell.installRootView(item: item, width: width, profiler: profiler, via: via, deferWidthOnlySettle: deferWidthOnlySettle)
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
            // Reports can land from cells queued before a session switch or a
            // structural apply — for an item the transcript no longer has. Caching
            // that height would poison the entry for the id's NEXT appearance
            // (captured: a transient status-row report under a subagent card's id
            // wrote ~56 over the card's real 157 during a switch). Drop them; the
            // id's next live cell re-reports through this same path.
            guard itemByID[itemID] != nil else { return }
            var height = ceil(rawHeight)
            let bucket = widthBucket
            let priorMeasured = measuredHeightByID[itemID]?[bucket]
            // Re-tile only when AppKit's *laid-out* height is genuinely stale.
            // The baseline is what the table currently has tiled (lastNotedHeight),
            // not the cache — falling back to the prior measurement, then the
            // rough row estimate. Comparing against the cache would fire a
            // spurious noteHeightOfRows whenever the cache shifted without the
            // laid-out height actually changing.
            let baseline = lastNotedHeight[itemID] ?? priorMeasured ?? estimatedRowHeight
            // Streaming content only grows; clamp only to a prior real measurement
            // at this width. `lastNotedHeight` may be an initial tiled estimate, so
            // it must not prevent the first real measurement from shrinking to fit.
            height = TranscriptMeasuredHeightResolver.resolvedHeight(
                height,
                priorMeasuredHeight: priorMeasured,
                isStreaming: profiler.isStreamingRecently
            )
            measuredHeightByID[itemID, default: [:]][bucket] = height
            estimateByID.removeValue(forKey: itemID)
#if DEBUG
            // Same smoking-gun line for the debounced async path (rows that aren't
            // force-measured while pinned, e.g. when not auto-following).
            TranscriptStreamWobbleProbe.shared.noteTile(
                id: itemID, height: height, previousTiled: baseline,
                width: contentWidth, pinned: isAutoFollowing, gliding: followGlideTimer != nil, source: "async")
#endif
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
            let safeToForceTableLayout = canPerformSynchronousTranscriptLayout()
            if let anchor, let changedRowAboveAnchor = rows.min(), changedRowAboveAnchor < anchor.rowIndex {
                // rect(ofRow:) must see the new heights before we re-anchor. If
                // every changed row is at/below the anchor, the anchor's minY is
                // unchanged, so avoid the synchronous full subtree layout entirely.
                if safeToForceTableLayout {
                    tableView.layoutSubtreeIfNeeded()
                    restoreScrollAnchor(anchor)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.restoreScrollAnchorIfNeeded(anchor)
                    }
                }
            } else if willAutoFollow, let scrollView,
                      let bottomMostChangedRow = rows.max(),
                      tableView.rect(ofRow: bottomMostChangedRow).maxY < scrollView.contentView.bounds.minY + 1 {
                // Pinned to the bottom while rows ABOVE the viewport corrected
                // (estimate → real heights after a session switch into a large
                // transcript). The re-tile just shifted the content under the
                // viewport; prefer a deferred re-pin when layout/stream/scroll
                // state makes synchronous full-table layout unsafe.
                if safeToForceTableLayout {
                    tableView.layoutSubtreeIfNeeded()
                    if let documentView = scrollView.documentView {
                        let clipView = scrollView.contentView
                        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
                        clipView.scroll(to: NSPoint(x: 0, y: maxY))
                        scrollView.reflectScrolledClipView(clipView)
                    }
                } else {
                    scrollToBottom(settle: false)
                }
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

        /// A session switch pins to a bottom computed from estimate heights. The
        /// old path immediately forced table layout, measured every newly visible
        /// row, re-tiled them, then forced another bottom layout in the same main-
        /// thread turn. Cold-start samples showed that synchronous settle as the
        /// session-switch hang signature (`layoutSubtreeIfNeeded` +
        /// `noteHeightOfRowsWithIndexesChanged` + anchor/bottom restore). Keep the
        /// same eventual geometry, but slice the visible-row settle over run-loop
        /// turns: one already-vended row per turn, then a cheap bottom re-pin that
        /// does not force a full document layout. Cells that are not live yet settle
        /// through their normal async height report path.
        private func scheduleVisibleRowsSettleAfterSessionSwitch() {
            pendingSessionSwitchSettleWork?.cancel()
            let generation = sessionSwitchSettleGeneration
            scheduleVisibleRowsSettleAfterSessionSwitch(generation: generation, remainingPasses: 8, delay: 0)
        }

        private func scheduleVisibleRowsSettleAfterSessionSwitch(
            generation: Int,
            remainingPasses: Int,
            delay: TimeInterval
        ) {
            guard remainingPasses > 0 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, generation == self.sessionSwitchSettleGeneration else { return }
                self.pendingSessionSwitchSettleWork = nil
                guard let tableView = self.tableView, let scrollView = self.scrollView else { return }
                let visible = tableView.rows(in: tableView.visibleRect)
                guard visible.length > 0 else { return }
                var ids = Set<String>()
                for row in visible.location ..< visible.location + visible.length where row < self.orderedIDs.count {
                    let id = self.orderedIDs[row]
                    if self.measuredHeightByID[id]?[self.widthBucket] == nil {
                        ids.insert(id)
                    }
                }
                guard !ids.isEmpty else { return }
                let retileIDs = self.measureChangedCellsSynchronously(
                    ids,
                    budgetMs: 4,
                    maxRows: 1,
                    deferUnmeasured: true
                )
                if !retileIDs.isEmpty {
                    self.flushPendingHeightWorkSynchronously()
                    self.noteHeightsChanged(forIDs: retileIDs)
                    self.performScrollToBottom(scrollView, animated: false, forceLayout: false)
                }
                self.scheduleVisibleRowsSettleAfterSessionSwitch(
                    generation: generation,
                    remainingPasses: remainingPasses - 1,
                    delay: self.heightReportInterval
                )
            }
            pendingSessionSwitchSettleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func captureScrollAnchor() -> ScrollAnchor? {
            guard let tableView, let scrollView else { return nil }
            let originY = scrollView.contentView.bounds.origin.y
            let row = tableView.row(at: NSPoint(x: 0, y: originY))
            guard row >= 0, row < orderedIDs.count else { return nil }
            let rowRect = tableView.rect(ofRow: row)
            return ScrollAnchor(id: orderedIDs[row], rowIndex: row, offsetFromRowTop: originY - rowRect.minY)
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

        private func handleScrollAfterUpdate(isSessionSwitch: Bool, explicitScroll: Bool, wasFollowing: Bool, contentAdvanced: Bool) {
            guard let scrollView else { return }
            if isSessionSwitch {
                // Session selection should open already pinned to the latest row,
                // not visibly animate from the top after the table appears.
                isAutoFollowing = true
                pendingScrollWork?.cancel()
                pendingScrollWork = nil
                pendingGlideLandingSettleWork?.cancel()
                pendingGlideLandingSettleWork = nil
                pendingScrollSettle = false
                performScrollToBottom(scrollView, animated: false)
                scheduleVisibleRowsSettleAfterSessionSwitch()
            } else if explicitScroll {
                // User-requested jumps (send, jump-to-latest) re-arm follow intent.
                isAutoFollowing = true
                scrollToBottom(settle: true)
            } else if wasFollowing && !isUserScrollingRecently && contentAdvanced {
                // Passive streaming follow — but never while the user is
                // actively scrolling, or it would yank the viewport. And only
                // when this update actually changed row content/geometry: an
                // update can reach here with nothing changed on screen (e.g. a
                // revision pulse), and gliding on it both yanks an idle session
                // the user is reading and pays performScrollToBottom's
                // full-document layout for nothing.
                scrollToBottom(settle: false)
            } else {
                publishPinnedState(isAutoFollowing)
            }
        }

        private func scrollToBottom(settle: Bool) {
            if settle {
                pendingGlideLandingSettleWork?.cancel()
                pendingGlideLandingSettleWork = nil
            }
            pendingScrollSettle = pendingScrollSettle || settle
            // While the passive streaming glide is already following, additional
            // non-settle requests do not need even a runloop-hop work item. The
            // timer re-reads the current document height each frame, so new tokens
            // are naturally coalesced into that in-flight glide. Explicit settle
            // requests still pierce through and snap to the authoritative bottom.
            if !settle, followGlideTimer != nil { return }
            guard pendingScrollWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                let shouldSettle = self.pendingScrollSettle
                self.pendingScrollWork = nil
                self.pendingScrollSettle = false
                // Re-check at fire time: this item runs a runloop hop after it
                // was scheduled, and the user may have grabbed the scroll in
                // between. Explicit jumps (settle) still win; the passive follow
                // yields without paying a synchronous height flush or full-document
                // layout mid-gesture.
                if !shouldSettle, self.isUserScrollingRecently { return }
                // Streaming follow (settle == false) glides using current geometry;
                // explicit settle/session-switch paths snap after an authoritative
                // height flush + layout.
                self.performScrollToBottom(scrollView, animated: !shouldSettle, forceLayout: shouldSettle)
                guard shouldSettle else { return }
                self.pendingSettleScrollWork?.cancel()
                let settleWork = DispatchWorkItem { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    self.pendingSettleScrollWork = nil
                    // The delayed settle is explicit: pay the synchronous flush once
                    // here so jump-to-latest/send lands on the true bottom after any
                    // pending cell measurements have arrived.
                    self.performScrollToBottom(scrollView, animated: false, forceLayout: true)
                }
                self.pendingSettleScrollWork = settleWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settleWork)
            }
            pendingScrollWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func performScrollToBottom(_ scrollView: NSScrollView, animated: Bool, forceLayout: Bool = true) {
            guard let documentView = scrollView.documentView else { return }
            // An auto-follow glide already eases toward the (growing) bottom every
            // frame and re-reads the document height as it goes, so repeated
            // streaming requests should collapse into that in-flight timer instead
            // of flushing heights or forcing full-document layout.
            if animated, followGlideTimer != nil { return }
            let clipView = scrollView.contentView
            if forceLayout {
                // Explicit settle/session-switch paths need authoritative geometry.
                // Keep this synchronous work out of normal streaming auto-follow,
                // where samples showed it repeatedly forcing full document layout.
                flushPendingHeightWorkSynchronously()
                documentView.layoutSubtreeIfNeeded()
            }
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            guard abs(clipView.bounds.origin.y - maxY) > 1 else {
                if !animated { stopFollowGlide() }
                publishPinnedState(true)
                return
            }
            // Streaming follow: hand off to the glide timer, which eases toward the
            // current bottom and picks up future height changes on later ticks.
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
            // Never start a glide when auto-follow is disengaged — the caller's
            // intent check and this guard together ensure the glide can only run
            // while the reader is actually pinned to the bottom.
            guard followGlideTimer == nil, isAutoFollowing else { return }
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
            // Auto-follow is disengaged (the user scrolled away from the bottom) —
            // the glide must NEVER move the viewport, even if a stale timer is still
            // ticking or the user paused long enough for the scroll grace window to
            // lapse. Without this, a streaming re-tile lets the glide ease back to
            // the bottom and yanks the reader down: the "scroll against the stream
            // makes it jump" bug.
            guard isAutoFollowing else {
                stopFollowGlide()
                return
            }
            let clipView = scrollView.contentView
            // Cheap path: ease using the current (possibly slightly stale during a
            // streaming re-tile) document height. The authoritative confirm below
            // only runs once, at the moment the glide believes it has arrived.
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            let current = clipView.bounds.origin.y
            let gap = maxY - current
            if abs(gap) > 0.5 {
                let nextY = current + gap * followGlideFactor
                isProgrammaticScroll = true
                clipView.scroll(to: NSPoint(x: 0, y: nextY))
                scrollView.reflectScrolledClipView(clipView)
                isProgrammaticScroll = false
                return
            }
            // Looks settled against the geometry AppKit has already produced.
            // Do not force pending height work or document layout here: during
            // streaming this landing check can happen for every token batch, and
            // samples showed that synchronous full-document layout dominating the
            // main thread. If height work is still pending, schedule one deferred
            // authoritative snap after streaming goes quiet so the glide cannot
            // remain permanently short of the final measured bottom.
#if DEBUG
            TranscriptStreamWobbleProbe.shared.noteGlideLanding(
                trueGap: gap, docHeight: documentView.bounds.height, clipHeight: clipView.bounds.height)
#endif
            scheduleGlideLandingSettleIfNeeded()
            stopFollowGlide()
            publishPinnedState(true)
            return
        }

        private func scheduleGlideLandingSettleIfNeeded(
            delay: TimeInterval = 0.12,
            requirePendingHeightWork: Bool = true
        ) {
            guard pendingGlideLandingSettleWork == nil,
                  !requirePendingHeightWork || pendingHeightWork != nil || !pendingHeightIDs.isEmpty else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingGlideLandingSettleWork = nil
                guard self.isAutoFollowing, !self.isUserScrollingRecently else { return }
                // While tokens are still arriving, keep deferring instead of
                // turning the landing check back into a per-token forced layout.
                // Preserve the one requested settle even if the original pending
                // height work drained meanwhile; the point is to confirm the final
                // measured bottom after the stream goes quiet.
                if self.profiler.isStreamingRecently {
                    self.scheduleGlideLandingSettleIfNeeded(delay: 0.2, requirePendingHeightWork: false)
                    return
                }
                guard let scrollView = self.scrollView else { return }
                self.performScrollToBottom(scrollView, animated: false, forceLayout: true)
            }
            pendingGlideLandingSettleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        /// Forwarded to the render cache (via the host) to gate streaming pulses
        /// while the reader is scrolled away from the bottom. Set in `updateNSView`.
        /// Driven entirely by the `isAutoFollowing` didSet, so every transition
        /// (user scroll away, return to bottom, send, session switch) is covered.
        var onScrollingChange: ((Bool) -> Void)?

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
            // Whatever this method returns IS what AppKit tiles the row at, so it
            // is the one true baseline for "does a fresh measurement need a
            // re-tile". Recording it here keeps `lastNotedHeight` honest across
            // session switches and snapshot applies, where AppKit re-tiles every
            // row through this path without going near `noteHeightsChanged`.
            // (Captured failure: switch away + back left lastNotedHeight at the
            // old 157 while the table re-tiled from a poisoned 56 cache entry —
            // the cell's correct 157 report then matched the stale baseline and
            // was swallowed, leaving the subagent card cropped for the whole run.)
            // Prefer a real measurement for the current width — it survives
            // width changes and session switches, so a revisited row lays out at
            // its exact height with no reflow.
            if let measured = measuredHeightByID[id]?[widthBucket] {
                lastNotedHeight[id] = measured
                return measured
            }
            if let estimate = estimateByID[id] {
                lastNotedHeight[id] = estimate
                return estimate
            }
            // No measurement yet — use the item's fast estimator so the table can lay
            // the row out close to its natural size without triggering a SwiftUI pass.
            // The cell measures precisely as it renders and reports back via
            // reportMeasuredHeight, at which point this row gets re-tiled.
            if let item = itemByID[id] {
                let est = item.estimatedHeight(contentWidth)
                estimateByID[id] = est
                lastNotedHeight[id] = est
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
        func installRootView(
            item: PiAgentAppKitTranscriptItem,
            width: CGFloat,
            profiler: TranscriptScrollProfiler? = nil,
            via: String = "scroll-vend",
            deferWidthOnlySettle: Bool = false
        ) {
            self.profiler = profiler
            guard case .native(let spec) = item.kind else { return }
            installNativeRow(spec: spec, item: item, width: width, via: via, deferWidthOnlySettle: deferWidthOnlySettle)
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
        private func installNativeRow(
            spec: NativeRowSpec,
            item: PiAgentAppKitTranscriptItem,
            width: CGFloat,
            via: String = "scroll-vend",
            deferWidthOnlySettle: Bool = false
        ) {
            // A recycled cell holding a different native view type must rebuild it.
            if let existingType = nativeRowTypeID, existingType != spec.typeID {
                teardownNativeRow()
            }
            let row: NSView
            let createdNow: Bool
#if DEBUG
            var makeMs = 0.0
#endif
            if let existing = nativeRow {
                row = existing
                createdNow = false
            } else {
                createdNow = true
#if DEBUG
                let t0 = CACurrentMediaTime()
                row = spec.make()
                makeMs = (CACurrentMediaTime() - t0) * 1000
#else
                row = spec.make()
#endif
                row.translatesAutoresizingMaskIntoConstraints = false
                addSubview(row)
                // Full-width row; the view sizes/positions its own content.
                let top = row.topAnchor.constraint(equalTo: topAnchor, constant: item.topInset)
                let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -item.bottomInset)
                // During a diffable `apply`, AppKit briefly sets each row to its
                // default 17pt height (its `NSView-Encapsulated-Layout-Height`)
                // before it consults `heightOfRow`. A row whose content has firm
                // internal pins — e.g. a tool-group card pinned top+bottom — can't
                // fit 17pt, so a REQUIRED bottom pin makes AppKit break-and-log a
                // constraint every apply. Drop the bottom pin just below required so
                // it silently yields during that transient and is satisfied exactly
                // once the real row height lands (measurement is unaffected — height
                // comes from `spec.measure`, not these pins).
                bottom.priority = .required - 1
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

            let itemChanged = configuredItemID != item.id
            let revisionChanged = itemChanged || configuredRevision != item.contentRevision
            let widthChanged = abs(configuredWidth - width) > 0.5
            if revisionChanged || widthChanged {
#if DEBUG
                // DEBUG-only attribution of the build cost — fresh-view construction
                // + the markdown configure (reconcile vs full rebuild). This is the
                // scroll/stream hitch the other profiler hooks never wrapped (it runs
                // inside the table's cell-provider closure). Compiled out of release.
                if let profiler {
                    profiler.measureCellBuild(id: item.id, fresh: createdNow, makeMs: makeMs, via: via) {
                        let seqBefore = NativeMarkdownTextContainer.configureSeq
                        spec.configure(row, width)
                        // Only trust the markdown attribution if a build actually
                        // ran this vend (seq advanced) — a non-markdown row leaves
                        // the statics stale, so report nil instead of mislabeling.
                        guard NativeMarkdownTextContainer.configureSeq != seqBefore else { return nil }
                        return (NativeMarkdownTextContainer.lastConfigureWasRebuild,
                                NativeMarkdownTextContainer.lastConfigureBlockCount)
                    }
                } else {
                    spec.configure(row, width)
                }
#else
                spec.configure(row, width)
#endif
                lastIntrinsicHeight = -1
            }
            // `settle` is the immediate layout pass that stops a recycled,
            // layer-backed row from painting its prior geometry. A freshly-created
            // non-markdown row has no presentation state to correct, and AppKit's
            // normal cell layout immediately follows installation; forcing a second
            // subtree layout here was redundant in the sampled fresh card vends.
            // Keep the initial settle for markdown-bearing bubbles/questions, whose
            // first paint includes a richer nested content tree. Spacers have no
            // visible geometry to correct.
            // Skip for offscreen prewarm: the row is not on screen so there is no
            // stale paint to correct, and the layout cost (up to 60ms for heavy rows)
            // is wasted work that stalls the main thread during idle pre-warm slices.
            // The cell will lay out naturally when it scrolls into view.
            let hasVisibleNativeGeometry = spec.typeID != ObjectIdentifier(PiAgentNativeSpacerView.self)
            let isMarkdownBearingRow = spec.typeID == ObjectIdentifier(PiAgentNativeBubbleView.self)
                || spec.typeID == ObjectIdentifier(PiAgentNativeQuestionView.self)
            let needsInitialSettle = hasVisibleNativeGeometry && ((!createdNow && itemChanged) || (createdNow && isMarkdownBearingRow))
            let isWidthOnlySettle = !createdNow && !needsInitialSettle && widthChanged && !insetChanged
            if via != "prewarm", needsInitialSettle || (!createdNow && (widthChanged || insetChanged)) {
                if deferWidthOnlySettle && isWidthOnlySettle {
#if DEBUG
                    if TranscriptScrollProfiler.verboseTrace {
                        TranscriptScrollProfiler.fileLog("WIDTH settle skipped row=\(row) via=\(via)")
                    }
#endif
                } else {
                    spec.settle(row)
                }
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
/// activity) is passed in as resolved values and compared in `==`, so the
/// list can never go stale: a real change to any of them differs the inputs and
/// forces a rebuild. Bindings and callbacks are intentionally excluded from `==`.
private struct SessionListContent: View, Equatable {
    let sections: [PiAgentSessionListSection]
    /// Render per-project group headers. False for the single-project scoped
    /// view, which renders one anonymous section identical to the pre-grouping
    /// flat layout.
    let isGrouped: Bool
    let selectedSessionIDs: Set<UUID>
    let renamingSessionID: UUID?
    let workingSessionIDs: Set<UUID>
    let uiRequestSessionIDs: Set<UUID>
    let generatingTitleIDs: Set<UUID>
    let activeLoopSessionIDs: Set<UUID>
    let activityByID: [UUID: PiAgentSessionGitActivity]
    /// Snapshot of `scrollRequest`'s value at construction, compared in `==`.
    /// The binding itself can't be compared: both sides read the same live
    /// state storage, so old-vs-new is always equal and the gate would
    /// swallow the request.
    var scrollRequestID: UUID? = nil
    /// Forwarded to `AppList` so the owner can bring the selected session back
    /// into view when this list becomes the visible one (panel expand).
    var scrollRequest: Binding<UUID?> = .constant(nil)

    @Binding var selection: Set<UUID>
    let onSelect: (PiAgentSessionRecord) -> Void
    let onBeginRename: (PiAgentSessionRecord) -> Void
    let onEndRename: () -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    /// Toggle a project group's "Show more/less" state.
    let onToggleExpand: (String) -> Void
    /// Toggle a project group's disclosure collapse (header-only / expanded).
    let onToggleCollapse: (String) -> Void
    /// Start a new session scoped to the given project/group id. Handles real
    /// project groups and the dedicated General Chat group; no-op for "Other".
    let onCreateSessionForProject: (String) -> Void
    /// Arrow-key navigation (↑/↓), routed through the same view-model path as
    /// ⌘]/⌘[ so both follow the grouped list with auto-reveal. `nil` disables
    /// arrows (lists that don't need keyboard nav).
    var onArrowNavigate: ((MoveCommandDirection) -> Void)? = nil

    static func == (lhs: SessionListContent, rhs: SessionListContent) -> Bool {
        let diff: String?
        if lhs.sections != rhs.sections { diff = "sections" }
        else if lhs.selectedSessionIDs != rhs.selectedSessionIDs { diff = "selectedSessionIDs" }
        else if lhs.renamingSessionID != rhs.renamingSessionID { diff = "renamingSessionID" }
        else if lhs.workingSessionIDs != rhs.workingSessionIDs { diff = "workingSessionIDs" }
        else if lhs.uiRequestSessionIDs != rhs.uiRequestSessionIDs { diff = "uiRequestSessionIDs" }
        else if lhs.generatingTitleIDs != rhs.generatingTitleIDs { diff = "generatingTitleIDs" }
        else if lhs.activeLoopSessionIDs != rhs.activeLoopSessionIDs { diff = "activeLoopSessionIDs" }
        else if lhs.activityByID != rhs.activityByID { diff = "activityByID" }
        // A pending scroll request must defeat the equatable gate, or the
        // inner AppList's onChange never sees the new value and the jump to
        // the selected row silently doesn't happen.
        else if lhs.scrollRequestID != rhs.scrollRequestID { diff = "scrollRequest" }
        else { diff = nil }
#if DEBUG
        if let diff, TranscriptScrollProfiler.verboseTrace {
            if diff == "selectedSessionIDs" {
                // Selection churn with no user click has shown up in scroll
                // traces; print the actual delta so the mutator can be named.
                let old = lhs.selectedSessionIDs.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ",")
                let new = rhs.selectedSessionIDs.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ",")
                SessionListContent.perfLog.error("SessionListContent re-eval — selectedSessionIDs changed: [\(old, privacy: .public)] -> [\(new, privacy: .public)]")
            } else {
                SessionListContent.perfLog.error("SessionListContent re-eval — input changed: \(diff, privacy: .public)")
            }
        }
#endif
        return diff == nil
    }

#if DEBUG
    private static let perfLog = Logger(subsystem: "streetcoding.agent-deck", category: "SessionListPerf")
#endif

    var body: some View {
        AppList(
            sections: appSections,
            selection: .multi($selection),
            keyboardNavigation: onArrowNavigate != nil,
            onArrowNavigate: onArrowNavigate,
            cornerRadius: AppTheme.Chat.subCardCornerRadius,
            rowHorizontalPadding: 0,
            rowVerticalPadding: 0,
            listHorizontalInset: 6,
            // Past the 34pt fade below, so the last session can scroll clear
            // of the gradient instead of always sitting dimmed in it.
            bottomContentInset: 36,
            scrollRequest: scrollRequest
        ) { session in
            row(session)
        }
        .animation(.snappy(duration: 0.24), value: sections.flatMap(\.items).map(\.id))
        .bottomEdgeFade(height: 34)
    }

    /// Map the value-type `PiAgentSessionListSection`s to `AppListSection`s,
    /// attaching a custom project-group header to any section that needs one.
    private var appSections: [AppListSection<PiAgentSessionRecord>] {
        sections.map { section in
            AppListSection(
                id: section.id,
                header: shouldShowHeader(for: section)
                    ? AnyView(PiAgentSessionGroupHeader(
                        section: section,
                        onToggleCollapse: { onToggleCollapse(section.id) },
                        onCreateSession: { onCreateSessionForProject(section.id) }
                    ))
                    : nil,
                footer: shouldShowFooter(for: section)
                    ? AnyView(PiAgentSessionGroupFooter(
                        section: section,
                        onToggleShowMore: { onToggleExpand(section.id) }
                    ))
                    : nil,
                items: section.items
            )
        }
    }

    /// A header renders whenever the list is grouped — every group needs a
    /// disclosure + identity, now that groups can collapse to just their
    /// header. A single-project scoped view (`isGrouped == false`) stays
    /// headerless, identical to the pre-grouping flat layout.
    private func shouldShowHeader(for section: PiAgentSessionListSection) -> Bool {
        isGrouped
    }

    private func shouldShowFooter(for section: PiAgentSessionListSection) -> Bool {
        isGrouped && !section.isCollapsed && (section.hiddenCount > 0 || section.isShowMoreActive)
    }

    @ViewBuilder
    private func row(_ session: PiAgentSessionRecord) -> some View {
        PiAgentSessionRow(
            session: session,
            isSelected: selectedSessionIDs.contains(session.id),
            isRunning: workingSessionIDs.contains(session.id),
            hasUIRequest: uiRequestSessionIDs.contains(session.id),
            isRenaming: renamingSessionID == session.id,
            isGeneratingTitle: generatingTitleIDs.contains(session.id),
            hasActiveLoop: activeLoopSessionIDs.contains(session.id),
            gitActivity: activityByID[session.id] ?? .none,
            onSelect: { onSelect(session) },
            onBeginRename: { onBeginRename(session) },
            onEndRename: onEndRename,
            onRename: { onRename(session.id, $0) },
            onDelete: { onDelete(session.id) }
        )
        .equatable()
        .contextMenu {
            Button(role: .destructive) {
                onDelete(session.id)
            } label: {
                Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected Sessions" : "Delete Session", systemImage: "trash")
            }
        }
    }
}

/// Per-project group header for the All-Projects session list: a disclosure
/// project icon, repo name (primary) + owner (muted), an inline disclosure
/// chevron that collapses the group to its header, a "Show N more / Show less"
/// affordance when the group has capped content, and a trailing `+` that
/// starts a new session in that project. Rendered through
/// `AppListSection.header`, so it inherits `AppList`'s section spacing.
private struct PiAgentSessionGroupHeader: View {
    let section: PiAgentSessionListSection
    let onToggleCollapse: () -> Void
    let onCreateSession: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(alignment: .center, spacing: 8) {
                    ProjectIconView(
                        imageURL: section.iconFileURL,
                        symbolName: section.fallbackSymbolName,
                        size: 30,
                        assetName: section.assetName
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 5) {
                            Text(section.title)
                                .font(AppTheme.Font.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppTheme.mutedText)
                                .frame(width: 11, height: 11, alignment: .center)
                                .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                                .animation(.snappy(duration: 0.22), value: section.isCollapsed)
                        }
                        if let subtitle = section.subtitle {
                            Text(subtitle)
                                .font(AppTheme.Font.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: 30, alignment: .center)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(section.isCollapsed ? "Expand" : "Collapse")

            if section.canCreateSession {
                Button(action: onCreateSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(isHovering ? AppTheme.contentSubtleFill : Color.clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30, alignment: .center)
                .help(section.id == PiAgentSessionGrouping.noProjectSectionID ? "New General Chat" : (section.id == PiAgentSessionGrouping.agentDeckBuilderSectionID ? "New Agent Deck Builder" : "New session in \(section.title)"))
                .accessibilityLabel(section.id == PiAgentSessionGrouping.noProjectSectionID ? "New General Chat" : (section.id == PiAgentSessionGrouping.agentDeckBuilderSectionID ? "New Agent Deck Builder" : "New session in \(section.title)"))
            }
        }
        // Aligns the icon's leading edge with the session row title (row text
        // sits at listHorizontalInset 6 + the row's own 8pt padding = 14pt).
        .padding(.horizontal, 8)
        .frame(minHeight: 34, alignment: .center)
        .onHover { isHovering = $0 }
    }
}

private struct PiAgentSessionGroupFooter: View {
    let section: PiAgentSessionListSection
    let onToggleShowMore: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggleShowMore) {
            Text(section.isShowMoreActive ? "Show less" : "Show more")
                .font(AppTheme.Font.footnote.weight(.semibold))
                .foregroundStyle(isHovering ? AppTheme.brandAccentBright : AppTheme.brandAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? AppTheme.brandAccent.opacity(0.10) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .help(section.isShowMoreActive ? "Show fewer" : "Show \(section.hiddenCount) hidden session\(section.hiddenCount == 1 ? "" : "s")")
    }
}

/// Expanded state of the Coding Agent pull-up panel: the full searchable
/// session list that overlays the upper nav sections when the panel is pulled
/// up (see `mainContent`'s sidebar ZStack).
struct CodingAgentExpandedPanel: View {
    let viewModel: AppViewModel
    let store: PiAgentSessionStore
    @Binding var sessionSearchText: String
    /// True only while the panel is expanded. Both panel states are kept
    /// permanently mounted (ZStack in `mainContent`) so the pull-up is a cheap
    /// opacity/offset animation rather than a teardown/rebuild — but that means
    /// this view also stays alive while collapsed. `isActive` gates the only
    /// per-streaming-tick work (the git-activity parse) so the hidden panel
    /// costs nothing during a streaming run.
    let isActive: Bool
    let onCollapse: () -> Void

    @State private var cachedSections: [PiAgentSessionListSection] = []
    @State private var hasBuiltVisibleSessions = false
    // Cached so `body` never reads `store.sessions` directly: `touchSession`
    // mutates that array many times per second during streaming, and a live read
    // here would re-evaluate the whole body at ~30Hz (visible or not). Recomputed
    // only on the non-streaming triggers that actually change the list.
    @State private var hasAnyScopedSessions = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var lastSelectedSessionID: UUID?
    @State private var renamingSessionID: UUID?
    @State private var pendingDeleteSessionIDs: Set<UUID> = []
    @State private var isDeleteSessionsAlertPresented = false
    @State private var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
    @State private var postExpandTask: Task<Void, Never>?
    /// Per-session memo of the last activity parse, keyed by the store's
    /// `gitActivityRevision` it was computed at. That revision bumps exactly
    /// when a commit/push/merge entry lands, so a memo entry parsed at the
    /// current revision can never be stale. `rebuildSessionActivityCache`
    /// re-parses only on actual git events — without this, every panel expand
    /// re-scanned every visible transcript synchronously on the main thread,
    /// right as the expand animation's first frames rendered.
    @State private var activityParseMemo: [UUID: (revision: Int, activity: PiAgentSessionGitActivity)] = [:]
    /// Set when the panel becomes the visible one so the list jumps to the
    /// current session (which may have been picked from the collapsed recents
    /// while this list sat hidden at a stale scroll offset).
    @State private var sessionScrollRequest: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle()
                .fill(AppTheme.contentStroke)
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if isActive && !hasBuiltVisibleSessions {
                // Lightweight placeholder during the expand animation's first
                // frames: computing visibleSections (grouping) or even reading
                // hasAnyScopedSessions here would force synchronous work that
                // competes with the spring animation. After the deferred
                // schedulePostExpandWork rebuild lands, this branch disappears.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAnyScopedSessions {
                AppEmptyState("No sessions yet", systemImage: "square.and.pencil", description: emptySessionsMessage, layout: .fill)
            } else if visibleSections.isEmpty {
                AppEmptyState("No sessions found", systemImage: "magnifyingglass", description: "Try another search.", layout: .fill)
            } else {
                SessionListContent(
                    sections: visibleSections,
                    isGrouped: isAllProjects,
                    selectedSessionIDs: selectedSessionIDs,
                    renamingSessionID: renamingSessionID,
                    workingSessionIDs: workingVisibleSessionIDs,
                    uiRequestSessionIDs: uiRequestVisibleSessionIDs,
                    generatingTitleIDs: viewModel.piAgentTitleGeneratingSessionIDs,
                    activeLoopSessionIDs: activeLoopSessionIDs,
                    activityByID: visibleSessionActivityByID,
                    scrollRequestID: sessionScrollRequest,
                    scrollRequest: $sessionScrollRequest,
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
                    onDelete: { id in requestDeleteSessions(selectedSessionIDs.contains(id) && selectedSessionIDs.count > 1 ? selectedSessionIDs : [id]) },
                    onToggleExpand: { projectID in
                        if viewModel.expandedProjects.contains(projectID) { viewModel.expandedProjects.remove(projectID) }
                        else { viewModel.expandedProjects.insert(projectID) }
                    },
                    onToggleCollapse: { projectID in
                        if viewModel.collapsedProjects.contains(projectID) { viewModel.collapsedProjects.remove(projectID) }
                        else { viewModel.collapsedProjects.insert(projectID) }
                    },
                    onCreateSessionForProject: { projectPath in
                        if projectPath == PiAgentSessionGrouping.noProjectSectionID {
                            viewModel.createNoProjectPiAgentDraft()
                        } else if projectPath == PiAgentSessionGrouping.agentDeckBuilderSectionID {
                            viewModel.createAgentDeckBuilderDraft()
                        } else if let project = viewModel.projectByPath[projectPath] {
                            viewModel.createPiAgentDraft(for: project)
                        }
                    },
                    onArrowNavigate: { direction in
                        viewModel.selectAdjacentPiAgentSession(offset: direction == .down ? 1 : -1, wrap: false)
                    }
                )
                .equatable()
            }
        }
        // Full-bleed: the card chrome belongs to the collapsed state only —
        // expanding sheds the container so the list gets the whole sidebar.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            if isActive {
                // Defer the initial rebuild/sync past the expand animation's
                // first frames so grouping, selection reconciliation, and git
                // activity parsing don't fight the spring for main-thread time.
                // The placeholder branch above covers the gap.
                schedulePostExpandWork()
            } else {
                // Background prebuild while hidden — no animation to compete
                // with, so the next expand shows the list immediately.
                rebuildVisibleSessions()
                syncVisibleSessionSelection()
                syncMultiSelectionToSelectedSession()
            }
        }
        .onDisappear {
            postExpandTask?.cancel()
            postExpandTask = nil
        }
        .onChange(of: isActive) { _, active in
            if active {
                schedulePostExpandWork()
            } else {
                postExpandTask?.cancel()
                postExpandTask = nil
            }
        }
        .onChange(of: store.sessionListRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.showPiAgentActiveOnly) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.uiRequestsBySessionID) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.subagentRunsRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.loopRunsRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.expandedProjects) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.collapsedProjects) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        // Projects load asynchronously after sessions on first launch; without
        // this trigger the cached sections stayed grouped under "Other" until a
        // later rebuild (the original first-launch "all Other" symptom).
        .onChange(of: viewModel.discoveredProjectsRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.selectedSession?.id) { _, _ in
            syncMultiSelectionToSelectedSession()
            // Keep the selected row in view for both click selection and keyboard
            // navigation. While hidden, this still pre-positions the list before
            // the next expand; while active, it tracks ↑/↓ and ⌘]/⌘[ jumps.
            sessionScrollRequest = store.selectedSession?.id
        }
        .onChange(of: visibleSessionIDs) { _, _ in
            syncVisibleSessionSelection()
            pruneMultiSelectionToVisibleSessions()
            rebuildSessionActivityCache()
        }
        // Git activity is derived by scanning visible transcripts. Do not run it
        // on the first expand frame: that frame is already resizing/laying out the
        // sidebar and `ScrollViewReader.scrollTo` can realize many lazy rows.
        .onChange(of: store.gitActivityRevision) { _, _ in
            if isActive { rebuildSessionActivityCache() }
        }
        .alert(deleteSessionsAlertTitle, isPresented: $isDeleteSessionsAlertPresented) {
            Button("Delete", role: .destructive) {
                let deleteIDs = pendingDeleteSessionIDs
                let nextID = PiAgentSessionGrouping.nextSelectionAfterDeletion(
                    visibleSessions: visibleSessions,
                    deletedIDs: deleteIDs,
                    selectedID: store.selectedSession?.id
                )
                viewModel.deletePiAgentSessions(deleteIDs, fallbackSelectionID: nextID)
                pendingDeleteSessionIDs = []
            }
            Button("Cancel", role: .cancel) { pendingDeleteSessionIDs = [] }
        } message: {
            Text(deleteSessionsAlertMessage)
        }
    }

    private var header: some View {
        CodingAgentPanelHeader(
            isExpanded: true,
            onToggle: onCollapse
        ) {
            if selectedSessionIDs.count > 1 {
                Button(role: .destructive) { requestDeleteSessions(selectedSessionIDs) } label: {
                    Image(systemName: "trash.fill")
                        .font(AppTheme.Font.body.weight(.semibold))
                        .foregroundStyle(Color.red)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Delete selected sessions")
            }
            PiAgentActiveSessionsFilterButton(isOn: expandedPanelActiveFilterBinding)
            CodingAgentNewSessionControls(viewModel: viewModel)
        }
    }

    private var expandedPanelActiveFilterBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showPiAgentActiveOnly },
            set: { viewModel.showPiAgentActiveOnly = $0 }
        )
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        store.sessions
    }

    private var isAllProjects: Bool { true }

    private var visibleSections: [PiAgentSessionListSection] {
        // When active and not yet built, the placeholder branch is rendering —
        // return [] so `.onChange(of: visibleSessionIDs)` and other getters
        // referencing visibleSections don't compute grouping synchronously
        // during the expand animation. When inactive, allow computedSections()
        // for the background prebuild path (no animation to compete with).
        if !hasBuiltVisibleSessions { return isActive ? [] : computedSections() }
        return cachedSections
    }

    /// Flattened rendered sessions (preview sets only) for helpers that still
    /// think in terms of a flat list — selection sync, working set, activity
    /// cache. Hidden sessions are intentionally excluded.
    private var visibleSessions: [PiAgentSessionRecord] { visibleSections.flatMap(\.items) }

    private var visibleSessionIDs: [UUID] { visibleSessions.map(\.id) }

    private func schedulePostExpandWork() {
        postExpandTask?.cancel()
        postExpandTask = Task { @MainActor in
            // Let the panel's expand animation and first layout pass get on
            // screen before forcing a ScrollViewReader jump or parsing transcript
            // git activity. Doing both synchronously on activation caused the
            // expanded sidebar to hitch and could trip AppKit layout recursion.
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, isActive else { return }
            rebuildVisibleSessions()
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            sessionScrollRequest = store.selectedSession?.id
            rebuildSessionActivityCache()
            postExpandTask = nil
        }
    }

    /// Guarded rebuild for reactive `.onChange` triggers: during the deferred
    /// first-expand window (`isActive && !hasBuiltVisibleSessions`), reschedule
    /// `schedulePostExpandWork` instead of rebuilding immediately — a reactive
    /// rebuild would set `hasBuiltVisibleSessions = true` and kill the
    /// placeholder before the expand animation finishes. Once the initial build
    /// has landed, rebuilds happen immediately as before.
    private func rebuildVisibleSessionsDeferredIfNeeded() {
        if isActive && !hasBuiltVisibleSessions {
            schedulePostExpandWork()
        } else {
            rebuildVisibleSessions()
        }
    }

    private func rebuildVisibleSessions() {
        let scoped = scopedSessions
        if hasAnyScopedSessions != !scoped.isEmpty { hasAnyScopedSessions = !scoped.isEmpty }
        let computed = computedSections(from: scoped)
        // Pragmatic hybrid freeze: while any visible session is actively
        // working, preserve the existing visible row order so a streaming
        // `updatedAt` bump doesn't reshuffle rows live. Only newly-present
        // rows (typically just-created or this-run-touched sessions surfacing
        // from the cap) may join the visible list; they're appended in their
        // natural computed order without re-sorting the frozen rows. Once no
        // session is working, the next rebuild re-sorts via the exact rule.
        let next = freezeVisibleOrderDuringActiveWork(computed) ?? computed
        if !hasBuiltVisibleSessions || next != cachedSections {
            cachedSections = next
        }
        hasBuiltVisibleSessions = true
        // Publish the visible row snapshot to the view model so keyboard
        // navigation (⌘]/⌘[ and in-list ↑/↓) operates on rendered rows only —
        // no navigation into hidden preview/collapsed rows, no auto-reveal.
        // Only the active panel reports in, so the collapsed strip's flat
        // list isn't overwritten while the expanded panel is hidden.
        if isActive {
            viewModel.piAgentVisibleSessionsForNavigation = visibleSessions
        }
    }

    /// Returns a frozen copy of `computed` preserving the prior visible row
    /// order, or `nil` when no freeze should apply (no working session, or the
    /// cache isn't populated yet). Frozen sections keep the cached `items`
    /// order with two adjustments per section: drop rows that are no longer
    /// present, and append newly-present rows (newly visible this rebuild).
    /// Structural changes (collapse / Show more toggle) bypass the freeze so
    /// those user actions take effect immediately.
    private func freezeVisibleOrderDuringActiveWork(_ computed: [PiAgentSessionListSection]) -> [PiAgentSessionListSection]? {
        let anyWorking = computed.flatMap(\.items).contains { viewModel.piAgentSessionIsWorking($0) }
        guard anyWorking, hasBuiltVisibleSessions, !cachedSections.isEmpty else { return nil }
        var frozeAny = false
        let frozen = computed.map { newSection -> PiAgentSessionListSection in
            guard let oldSection = cachedSections.first(where: { $0.id == newSection.id }),
                  // Skip the freeze when the user's collapse / Show-more state
                  // changed between rebuilds — let the new section win so the
                  // structural action takes effect immediately.
                  oldSection.isCollapsed == newSection.isCollapsed,
                  oldSection.isShowMoreActive == newSection.isShowMoreActive else {
                return newSection
            }
            let newByID = Dictionary(uniqueKeysWithValues: newSection.items.map { ($0.id, $0) })
            let oldIDs = Set(oldSection.items.map(\.id))
            // Preserve prior order, refreshing payloads of rows still present.
            var merged = oldSection.items.compactMap { newByID[$0.id] }
            // Insert newly-present rows at their natural computed position
            // relative to the frozen rows. Appending them made a freshly-created
            // draft appear at the bottom whenever another session was working,
            // even though the list sorts newest-first.
            for newItem in newSection.items where !oldIDs.contains(newItem.id) {
                let newIndex = newSection.items.firstIndex(where: { item in item.id == newItem.id })
                let followingFrozenID = newIndex.flatMap { index in
                    newSection.items[(index + 1)...].first(where: { item in oldIDs.contains(item.id) })?.id
                }
                if let followingFrozenID,
                   let insertIndex = merged.firstIndex(where: { item in item.id == followingFrozenID }) {
                    merged.insert(newItem, at: insertIndex)
                } else {
                    merged.append(newItem)
                }
            }
            if merged == newSection.items { return newSection }
            frozeAny = true
            return newSection.withItems(merged)
        }
        return frozeAny ? frozen : nil
    }

    private func computedSections(from scoped: [PiAgentSessionRecord]? = nil) -> [PiAgentSessionListSection] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedSource = scoped ?? scopedSessions
        var source = viewModel.showPiAgentAttentionOnly ? scopedSource.filter(\.needsAttention) : scopedSource
        if viewModel.showPiAgentActiveOnly {
            let now = Date()
            let pendingUIRequestSessionIDs = Set(store.uiRequestsBySessionID.keys)
            let activeLoopSessionIDs = activeLoopSessionIDs(in: source)
            source = source.filter {
                $0.matchesActiveSessionsFilter(
                    referenceDate: now,
                    isWorking: viewModel.piAgentSessionIsWorking($0),
                    hasActiveLoop: activeLoopSessionIDs.contains($0.id),
                    hasPendingUIRequest: pendingUIRequestSessionIDs.contains($0.id)
                )
            }
        }
        let filtered = query.isEmpty ? source : source.filter { $0.matchesSessionSearch(query) }
        // Cap previews only in All-Projects browsing — searching or filtering by
        // attention/active bypasses the cap (the user is hunting), and a scoped
        // project keeps its full flat list exactly as before.
        let capPreviews = isAllProjects && query.isEmpty && !viewModel.showPiAgentAttentionOnly && !viewModel.showPiAgentActiveOnly
        return PiAgentSessionGrouping.sections(
            from: filtered,
            projectByPath: viewModel.projectByPath,
            expandedProjectIDs: viewModel.expandedProjects,
            collapsedProjectIDs: viewModel.collapsedProjects,
            capPreviews: capPreviews,
            isWorking: { viewModel.piAgentSessionIsWorking($0) },
            selectedSessionID: store.selectedSession?.id,
            // Expanded/full sidebar uses the strict exact-`updatedAt` comparator
            // so the most-recently-touched chat leads its project group within
            // the same day. The hybrid freeze in `rebuildVisibleSessions` keeps
            // a streaming pulse from reshuffling rows live.
            exactSort: true,
            // Surface sessions created or touched during this app run above
            // the top-N cap, so a freshly-jostled older chat stays reachable.
            touchedThisRunSessionIDs: viewModel.piAgentSessionsTouchedThisRunIDs
        )
    }

    private var workingVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    private var uiRequestVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.compactMap { session in
            store.uiRequestsBySessionID[session.id] == nil ? nil : session.id
        })
    }

    private var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        Dictionary(uniqueKeysWithValues: visibleSessions.compactMap { session in
            sessionActivityCache[session.id].map { (session.id, $0) }
        })
    }

    private var activeLoopSessionIDs: Set<UUID> {
        activeLoopSessionIDs(in: visibleSessions)
    }

    private func activeLoopSessionIDs(in sessions: [PiAgentSessionRecord]) -> Set<UUID> {
        let sessionIDs = Set(sessions.map(\.id))
        return Set(store.loopRunsBySessionID.compactMap { sessionID, runs in
            sessionIDs.contains(sessionID) && runs.contains(where: \.isActive) ? sessionID : nil
        })
    }

    private var emptySessionsMessage: String {
        if let project = viewModel.selectedDiscoveredProject {
            return "Use + to create a draft for \(project.name), or open from a GitHub issue."
        }
        return "Use + to create a draft, or select a project to narrow the list."
    }

    private var deleteSessionsAlertTitle: String {
        pendingDeleteSessionIDs.count == 1 ? "Delete Pi Agent session?" : "Delete \(pendingDeleteSessionIDs.count) Pi Agent sessions?"
    }

    private var deleteSessionsAlertMessage: String {
        pendingDeleteSessionIDs.count == 1
            ? "This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName)."
            : "This removes the selected Pi Agent sessions and their local transcripts from \(AppBrand.displayName)."
    }

    private func requestDeleteSessions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteSessionIDs = ids
        isDeleteSessionsAlertPresented = true
    }

    private func syncVisibleSessionSelection() {
        // Selection validity is owned by ONE canonical rule on the view model
        // (project scope only — never this panel's search/attention filters).
        // Panels asserting selection from their own filtered scope fought each
        // other and ping-ponged the transcript through session switches.
        viewModel.reconcileSelectedSessionWithProjectScope()
    }

    private func syncMultiSelectionToSelectedSession() {
        guard let selectedID = store.selectedSession?.id else {
            if !selectedSessionIDs.isEmpty { selectedSessionIDs = [] }
            lastSelectedSessionID = nil
            return
        }
        // A list click has already written the (possibly multi) selection,
        // including the session it just made current — collapsing to a single
        // here was what killed ⌘/⇧ multi-select the instant it was made. Only
        // reset when the current session jumped OUTSIDE the set (keyboard
        // shortcuts, notification taps, new drafts).
        if !selectedSessionIDs.contains(selectedID) {
            selectedSessionIDs = [selectedID]
        }
        lastSelectedSessionID = selectedID
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        var next = selectedSessionIDs.intersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) { next.insert(selectedID) }
        if next != selectedSessionIDs { selectedSessionIDs = next }
    }

    private func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if forceSingle || modifiers.isEmpty {
            selectedSessionIDs = [session.id]
        } else if modifiers.contains(.shift), let anchorID = lastSelectedSessionID, let anchorIndex = visibleSessionIDs.firstIndex(of: anchorID), let targetIndex = visibleSessionIDs.firstIndex(of: session.id) {
            selectedSessionIDs.formUnion(visibleSessionIDs[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)])
        } else if modifiers.contains(.command) {
            if selectedSessionIDs.contains(session.id), selectedSessionIDs.count > 1 {
                selectedSessionIDs.remove(session.id)
                // Hand the store a session that's still selected — re-selecting
                // the one just deselected would make the sync re-add it.
                let fallbackID = selectedSessionIDs.first
                lastSelectedSessionID = fallbackID
                if let fallbackID { viewModel.selectPiAgentSession(fallbackID) }
                return
            }
            selectedSessionIDs.insert(session.id)
        }
        lastSelectedSessionID = session.id
        viewModel.selectPiAgentSession(session.id)
    }

    private func rebuildSessionActivityCache() {
        // Only ever called while visible: `activityRevisionToken` is constant while
        // hidden so the driving `.onChange` doesn't fire. The guard is belt-and-
        // suspenders against the `visibleSessionIDs` trigger firing while hidden.
        guard isActive else { return }
        var fresh: [UUID: PiAgentSessionGitActivity] = [:]
        var memo = activityParseMemo
        var memoChanged = false
        let revision = store.gitActivityRevision
        for session in visibleSessions {
            let activity: PiAgentSessionGitActivity
            if let cached = memo[session.id], cached.revision == revision {
                activity = cached.activity
            } else {
                activity = piAgentSessionGitActivity(from: store.transcriptsBySessionID[session.id] ?? [])
                memo[session.id] = (revision, activity)
                memoChanged = true
            }
            if activity.hasCommit || activity.hasPush || activity.hasMerge { fresh[session.id] = activity }
        }
        // Drop memo entries for sessions no longer visible so the dictionary
        // can't grow unboundedly across project/search switches.
        if memo.count > visibleSessions.count * 2 {
            let visibleIDs = Set(visibleSessions.map(\.id))
            memo = memo.filter { visibleIDs.contains($0.key) }
            memoChanged = true
        }
        if memoChanged { activityParseMemo = memo }
        if fresh != sessionActivityCache { sessionActivityCache = fresh }
    }
}

struct PiAgentScreen: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    @Binding var sessionSearchText: String
    var showsSessionsColumn = true
    /// False when this screen is kept mounted but hidden (the user is on another
    /// sidebar tab). While inactive the transcript stops rebuilding its rows on
    /// streaming pulses — see `appKitTranscriptItems`.
    var isActive = true
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
    @State private var slashUniverseRevision = 0
    @State private var slashRowsCacheKey: SlashSuggestionRowsCacheKey?
    @State private var cachedSlashRows: [SlashSuggestionRow] = []
    @State private var cachedSlashSelectableRows: [SlashSuggestionRow] = []
    /// Picked slash items — rendered as glass capsule chips above the editor and
    /// included in the send payload. Only skills/skill collections can stack.
    @State private var slashSelections: [SlashItem] = []
    @State private var isLoopLaunchSheetPresented = false
    @State private var loopLaunchDraft = LoopDraft()
    @State private var loopLaunchDefinition: LoopDefinition?
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
    // Pinned-to-bottom lives in its own ObservableObject, held by `@State` so this
    // screen's body watches only the reference identity — NOT `isPinned`. Scrolling
    // flips `isPinned` ~constantly; if the screen body read it directly, every flip
    // would re-evaluate the whole body and re-run the O(N) `appKitTranscriptItems`
    // build (the `itemsBuild` scroll cost). Only `JumpToLatestOverlay` `@ObservedObject`s
    // it, so a flip re-renders just the pill, leaving the transcript host untouched.
    @State private var transcriptPinnedState = TranscriptPinnedState()
    @State private var showArchivedPreCompactionTranscript = false
    @State private var isEarlierTranscriptSheetPresented = false
    @State private var cachedSections: [PiAgentSessionListSection] = []
    @State private var hasBuiltVisibleSessions = false
    /// Per-session derived git activity (commit/push/merge timestamps), keyed by
    /// session.id. Rebuilt off the body hot path on transcript-revision or
    /// visible-set changes — never recomputed inline in row `body` to avoid
    /// jank (see `[[feedback_performance_sensitive]]`).
    @State private var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
    @State private var isUIRequestSheetPresented = false
    @State private var isSupervisorRequestSheetPresented = false
#if DEBUG
    @State private var didStartPickerStress = false
    @State private var pickerStressExpansionRequest = false
    @State private var pickerStressAcknowledgements = PickerStressCardAcknowledgements()
#endif
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?
    @State private var stabilizedProcessingMessage: String?
    @State private var processingMessageUpdateTask: Task<Void, Never>?
    // True briefly after a session switch while the transcript table applies its
    // new rows and snaps to the bottom; drives the opaque settle cover so the
    // top-to-bottom render is never visible. See `activeSessionColumn`.

    // Keep long sessions cheap to relayout when side panels open; older visible items remain accessible separately.
    private let recentTranscriptTimelineItemLimit = 50

    var body: some View {
        HStack(spacing: 0) {
            if showsSessionsColumn {
                HSplitView {
                    sessionsColumn
                        .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)

                    activeSessionColumn
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
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
            isSupervisorRequestSheetPresented = selectedPendingSupervisorRequest != nil && store.selectedUIRequest == nil
            rebuildVisibleSessions()
            resetTranscriptAutoScroll()
            // Transcript loading mutates the observable store's loading set. It
            // must happen after this appearance pass, not while SwiftUI is
            // publishing the selected-session update.
            requestSelectedTranscriptLoadAfterViewUpdate(for: store.selectedSession?.id)
            updateStabilizedProcessingMessage(selectedSessionProcessingMessage)
            Task { @MainActor in
                await Task.yield()
#if DEBUG
                await runPickerStressIfRequested()
#endif
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
                scheduleTranscriptCacheUpdate()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onChange(of: store.sessionListRevision) { _, _ in rebuildVisibleSessions() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.expandedProjects) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.collapsedProjects) { _, _ in rebuildVisibleSessions() }
        // Projects load asynchronously after sessions on first launch; without
        // this trigger the cached sections stayed grouped under "Other" until a
        // later rebuild.
        .onChange(of: viewModel.discoveredProjectsRevision) { _, _ in rebuildVisibleSessions() }
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
        .sheet(isPresented: supervisorRequestSheetBinding) {
            if let request = selectedPendingSupervisorRequest {
                PiSubagentSupervisorRequestSheet(
                    request: request,
                    onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID, response: response) },
                    onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID) }
                )
            }
        }
        .modifier(ComputerUseApprovalPresentation(coordinator: viewModel.computerUseApprovalCoordinator, sessionID: store.selectedSession?.id))
        .sheet(isPresented: $isLoopLaunchSheetPresented) {
            if let session = store.selectedSession,
               let projectPath = session.projectPathForProjectFeatures {
                LoopLaunchSheet(
                    session: session,
                    activeRun: store.activeLoopRun(for: session.id),
                    initialDraft: loopLaunchDraft,
                    sourceDefinition: loopLaunchDefinition,
                    availableAgents: viewModel.allDisplayAgents,
                    projectAgents: viewModel.startupSnapshot(forProjectPath: projectPath).effectiveAgents,
                    onCancel: { isLoopLaunchSheetPresented = false },
                    onAssignMissingAgents: { names in
                        viewModel.assignAgentNames(names, toProjectPath: projectPath)
                    },
                    onEnableDeckAgents: {
                        viewModel.setSubagentsEnabled(true, forSessionID: session.id)
                    },
                    onLaunch: { request in
                        if store.activeLoopRun(for: session.id) != nil && !request.stopExistingActive {
                            store.append(.init(sessionID: session.id, role: .error, title: "Loop Launch Failed", text: "This transcript already has an active loop."))
                            return
                        }
                        if let saveRequest = request.saveRequest {
                            do {
                                try viewModel.saveLoopDefinitionFromDraft(request.draft, request: saveRequest)
                            } catch {
                                store.append(.init(sessionID: session.id, role: .error, title: "Loop Save Failed", text: error.localizedDescription))
                                return
                            }
                        }
                        Task { @MainActor in
                            isLoopLaunchSheetPresented = false
                            let launched = await viewModel.launchLoop(
                                session: session,
                                draft: request.draft,
                                stopExistingActive: request.stopExistingActive
                            )
                            guard launched != nil else {
                                store.append(.init(sessionID: session.id, role: .error, title: "Loop Launch Failed", text: "The loop could not be started."))
                                return
                            }
                        }
                    }
                )
            }
        }
        .onChange(of: store.selectedUIRequest?.id) { _, newID in
            isUIRequestSheetPresented = newID != nil
            if newID == nil, selectedPendingSupervisorRequest != nil {
                isSupervisorRequestSheetPresented = true
            }
        }
        .onChange(of: selectedPendingSupervisorRequest?.id) { _, newID in
            isSupervisorRequestSheetPresented = newID != nil && store.selectedUIRequest == nil
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
            resetSlashComposerState()
            // Loading and cache hydration publish observable state. Schedule the
            // selected identity after this update pass so session selection never
            // triggers "Publishing changes from within view updates". The helper
            // verifies the identity again after yielding, coalescing rapid clicks.
            requestSelectedTranscriptLoadAfterViewUpdate(for: newID)
            Task { @MainActor in
                await Task.yield()
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
        .task(id: store.selectedTranscriptRevision) {
            await handleSelectedTranscriptRevisionTask()
        }
        .sheet(item: selectedSubagentTranscriptBinding) { run in
            PiNativeSubagentTranscriptSheet(
                run: run,
                store: store,
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

    private func handleSelectedTranscriptRevisionTask() async {
        await Task.yield()
        scheduleTranscriptCacheUpdate()
    }

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        store.sessions
    }

    private var isAllProjects: Bool { true }

    private var visibleSections: [PiAgentSessionListSection] {
        hasBuiltVisibleSessions ? cachedSections : computedSections()
    }

    /// Flattened rendered sessions (preview sets only) for helpers that still
    /// think in terms of a flat list — selection sync, working set, activity
    /// cache. Hidden sessions are intentionally excluded.
    private var visibleSessions: [PiAgentSessionRecord] { visibleSections.flatMap(\.items) }

    private func rebuildVisibleSessions() {
        let next = computedSections()
        // Only write @State when the visible list actually changed. A bare
        // `sessionListRevision` bump (e.g. a background re-sort/refresh while the
        // user is just scrolling the transcript) otherwise re-evaluates the whole
        // screen body and re-runs the transcript's updateNSView for nothing.
        if !hasBuiltVisibleSessions || next != cachedSections {
            cachedSections = next
        }
        hasBuiltVisibleSessions = true
    }

    private func computedSections() -> [PiAgentSessionListSection] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var source = viewModel.showPiAgentAttentionOnly ? scopedSessions.filter(\.needsAttention) : scopedSessions
        if viewModel.showPiAgentActiveOnly {
            let now = Date()
            let pendingUIRequestSessionIDs = Set(store.uiRequestsBySessionID.keys)
            let activeLoopSessionIDs = activeLoopSessionIDs(in: source)
            source = source.filter {
                $0.matchesActiveSessionsFilter(
                    referenceDate: now,
                    isWorking: viewModel.piAgentSessionIsWorking($0),
                    hasActiveLoop: activeLoopSessionIDs.contains($0.id),
                    hasPendingUIRequest: pendingUIRequestSessionIDs.contains($0.id)
                )
            }
        }
        let filtered = query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
        // Cap previews only in All-Projects browsing — searching or filtering by
        // attention/active bypasses the cap (the user is hunting), and a scoped project
        // keeps its full flat list exactly as before.
        let capPreviews = isAllProjects && query.isEmpty && !viewModel.showPiAgentAttentionOnly && !viewModel.showPiAgentActiveOnly
        return PiAgentSessionGrouping.sections(
            from: filtered,
            projectByPath: viewModel.projectByPath,
            expandedProjectIDs: viewModel.expandedProjects,
            collapsedProjectIDs: viewModel.collapsedProjects,
            capPreviews: capPreviews,
            isWorking: { viewModel.piAgentSessionIsWorking($0) },
            selectedSessionID: store.selectedSession?.id
        )
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

    private var supervisorRequestSheetBinding: Binding<Bool> {
        Binding(
            get: { isSupervisorRequestSheetPresented && selectedPendingSupervisorRequest != nil && store.selectedUIRequest == nil },
            set: { isPresented in
                if isPresented {
                    isSupervisorRequestSheetPresented = true
                } else {
                    isSupervisorRequestSheetPresented = false
                }
            }
        )
    }

    private var selectedPendingSupervisorRequest: PiSubagentSupervisorRequest? {
        guard let sessionID = store.selectedSession?.id else { return nil }
        return store.supervisorRequests(for: sessionID)
            .filter { $0.status == .pending && $0.kind.isBlocking }
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
            .first
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
                        PiAgentNewSessionSplitButton(
                            viewModel: viewModel,
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            onNewSession: { viewModel.createPiAgentDraftForSelectedProject() },
                            onNewSessionForProject: { viewModel.createPiAgentDraft(for: $0) }
                        )
                    } else if viewModel.selectedDiscoveredProject == nil {
                        PiAgentAddSessionMenuButton(
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            action: { viewModel.createNoProjectPiAgentDraft() },
                            onSelectAgentDeckBuilder: { viewModel.createAgentDeckBuilderDraft() },
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
            // 14 keeps the title flush with the session rows' text (6 AppList
            // inset + 8 row padding).
            .padding(.horizontal, 14)

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
                            sections: visibleSections,
                            isGrouped: isAllProjects,
                            selectedSessionIDs: selectedSessionIDs,
                            renamingSessionID: renamingSessionID,
                            workingSessionIDs: workingVisibleSessionIDs,
                            uiRequestSessionIDs: uiRequestVisibleSessionIDs,
                            generatingTitleIDs: viewModel.piAgentTitleGeneratingSessionIDs,
                            activeLoopSessionIDs: activeLoopSessionIDs,
                            activityByID: visibleSessionActivityByID,
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
                            onDelete: { id in
                                requestDeleteSessions(
                                    selectedSessionIDs.contains(id) && selectedSessionIDs.count > 1
                                        ? selectedSessionIDs
                                        : [id]
                                )
                            },
                            onToggleExpand: { projectID in
                                if viewModel.expandedProjects.contains(projectID) { viewModel.expandedProjects.remove(projectID) }
                                else { viewModel.expandedProjects.insert(projectID) }
                            },
                            onToggleCollapse: { projectID in
                                if viewModel.collapsedProjects.contains(projectID) { viewModel.collapsedProjects.remove(projectID) }
                                else { viewModel.collapsedProjects.insert(projectID) }
                            },
                            onCreateSessionForProject: { projectPath in
                                if projectPath == PiAgentSessionGrouping.noProjectSectionID {
                                    viewModel.createNoProjectPiAgentDraft()
                                } else if projectPath == PiAgentSessionGrouping.agentDeckBuilderSectionID {
                                    viewModel.createAgentDeckBuilderDraft()
                                } else if let project = viewModel.projectByPath[projectPath] {
                                    viewModel.createPiAgentDraft(for: project)
                                }
                            },
                            onArrowNavigate: { direction in
                                viewModel.selectAdjacentPiAgentSession(offset: direction == .down ? 1 : -1, wrap: false)
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

    private var uiRequestVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.compactMap { session in
            store.uiRequestsBySessionID[session.id] == nil ? nil : session.id
        })
    }

#if DEBUG
    private var isPickerStressRequested: Bool {
        ProcessInfo.processInfo.environment["AGENTDECK_PICKER_STRESS"] != nil
    }

    @MainActor
    private func runPickerStressIfRequested() async {
        guard isPickerStressRequested, !didStartPickerStress else { return }
        didStartPickerStress = true

        viewModel.openPiAgentScreen()
        // Let PiAgentScreen finish its on-appear selection restoration before
        // creating the journey draft; otherwise that restoration can select a
        // persisted session over the freshly created one.
        try? await Task.sleep(for: .milliseconds(500))
        // This journey is invalid without a real project-backed draft. Wait for
        // initial discovery, then deterministically use the selected project or
        // the first discovered project; never fall back to General Chat.
        for _ in 0..<20 where viewModel.discoveredProjects.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let project = viewModel.selectedProjectPath.flatMap({ viewModel.projectByPath[$0] })
                ?? viewModel.discoveredProjects.sorted(by: { $0.path < $1.path }).first else {
            pickerStressLog("PICKER_STRESS FAIL no discovered project; cannot create project draft")
            exit(EXIT_FAILURE)
        }
        viewModel.selectedProjectPath = project.path
        let selected = store.selectedSession
        let needsDraft = selected?.status != .draft
            || selected?.isAgentBound == true
            || selected?.projectPathForProjectFeatures != project.path
            || selected.flatMap({ store.activeLoopRun(for: $0.id) }) != nil
        if needsDraft {
            pickerStressLog("PICKER_STRESS PREPARE creating project draft path=\(project.path) selected=\(selected?.id.uuidString ?? "none")")
            viewModel.createPiAgentDraft(for: project)
        } else {
            pickerStressLog("PICKER_STRESS PREPARE reusing project draft path=\(project.path) session=\(selected?.id.uuidString ?? "none")")
        }

        guard let draft = store.selectedSession,
              draft.status == .draft,
              draft.projectPathForProjectFeatures == project.path else {
            pickerStressLog("PICKER_STRESS FAIL selected session is not a project-backed draft")
            exit(EXIT_FAILURE)
        }
        pickerStressAcknowledgements.reset(for: draft.id)

        if store.selectedSession?.subagentsEnabled == false {
            viewModel.setSubagentsEnabledForSelectedDraftAndNewSessions(true)
            pickerStressLog("PICKER_STRESS PREPARE enabled subagents session=\(store.selectedSession?.id.uuidString ?? "none")")
        }

        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            pickerStressLog("PICKER_STRESS FAIL no visible app window")
            NSApp.terminate(nil)
            return
        }

        let sessionID = draft.id.uuidString
        let rounds = 28
        let initialSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let stressScene = "PickerStress"
        let resizeScene = "PickerResizeStress"
        // Only use supported full-window sizes. The app's content/split minima
        // make artificial 620pt requests a clipping test rather than a resize.
        let sizes: [NSSize] = [
            .init(width: 1_346, height: 915),
            .init(width: 900, height: 640),
            .init(width: 1_000, height: 700),
            .init(width: 1_200, height: 800),
            .init(width: 1_600, height: 900),
            .init(width: 1_050, height: 720)
        ]
        pickerStressLog("PICKER_STRESS START session=\(sessionID) rounds=\(rounds) window=\(Int(initialSize.width))x\(Int(initialSize.height))")
        defer {
            PerfScene.current = "app"
            window.setContentSize(initialSize)
        }
        // Let launch-time scanning settle, then demand acknowledgements from
        // the production card before measuring the real resize/toggle cycle.
        try? await Task.sleep(for: .milliseconds(500))
        pickerStressExpansionRequest = true
        guard await waitForPickerStressCard(sessionID: draft.id, expanded: true) else {
            pickerStressLog("PICKER_STRESS FAIL production card did not mount and expand for project path=\(project.path)")
            exit(EXIT_FAILURE)
        }
        pickerStressLog("PICKER_STRESS CARD mounted rows=\(pickerStressAcknowledgements.rowCount) catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize))")
        let initialHangCount = HangWatchdog.hangCount(forScene: stressScene)
        let initialResizeHangCount = HangWatchdog.hangCount(forScene: resizeScene)

        for index in 0..<rounds {
            guard !Task.isCancelled else {
                pickerStressLog("PICKER_STRESS CANCELLED round=\(index)")
                return
            }
            let size = sizes[index % sizes.count]
            PerfScene.current = resizeScene
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            let actualSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
            guard abs(actualSize.width - size.width) <= 2, abs(actualSize.height - size.height) <= 2 else {
                pickerStressLog("PICKER_STRESS FAIL window size requested=\(pickerStressSizeDescription(size)) actual=\(pickerStressSizeDescription(actualSize))")
                exit(EXIT_FAILURE)
            }
            let expanded = index.isMultiple(of: 2)
            PerfScene.current = stressScene
            pickerStressExpansionRequest = expanded
            try? await Task.sleep(for: .milliseconds(180))
            guard await waitForPickerStressCard(sessionID: draft.id, expanded: expanded) else {
                pickerStressLog("PICKER_STRESS FAIL card expansion acknowledgement missing round=\(index + 1)")
                exit(EXIT_FAILURE)
            }
            pickerStressLog("PICKER_STRESS ROUND=\(index + 1)/\(rounds) requested=\(pickerStressSizeDescription(size)) actual=\(pickerStressSizeDescription(actualSize)) expanded=\(expanded) rows=\(pickerStressAcknowledgements.rowCount) catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize))")
        }

        // Include the final layout/animation settle in the measured region,
        // then restore the normal scene before application termination so an
        // unrelated shutdown stall cannot be misattributed to the picker.
        try? await Task.sleep(for: .milliseconds(300))
        let hangs = HangWatchdog.hangCount(forScene: stressScene) - initialHangCount
        let resizeHangs = HangWatchdog.hangCount(forScene: resizeScene) - initialResizeHangCount
        PerfScene.current = "app"
        // Finite Debug-build stalls are reported, but the runner's hard failures
        // are the regression signals for this journey: a nonzero/crash exit,
        // missing round completion, or SwiftUI/AppKit diagnostics in stderr.
        // Sampling itself can extend a >150 ms Debug layout pulse, so treating
        // every watchdog sample as a failed crash regression creates a feedback
        // loop in the harness rather than testing liveness.
        pickerStressLog("PICKER_STRESS COMPLETE rounds=\(rounds) pickerWatchdogHangs=\(hangs) resizeWatchdogHangs=\(resizeHangs)")
        NSApp.terminate(nil)
    }

    private func waitForPickerStressCard(sessionID: UUID, expanded: Bool) async -> Bool {
        for _ in 0..<20 {
            let acknowledgements = pickerStressAcknowledgements
            if acknowledgements.sessionID == sessionID,
               acknowledgements.mounted,
               acknowledgements.rowCount > 0,
               acknowledgements.expanded == expanded,
               acknowledgements.cardSize.width > 0,
               (!expanded || acknowledgements.catalogSize.height > 100) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func pickerStressSizeDescription(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private func pickerStressLog(_ line: String) {
        fputs(line + "\n", stderr)
        TranscriptScrollProfiler.fileLog(line)
    }
#endif

    private var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        var map: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions where sessionActivityCache[session.id] != nil {
            map[session.id] = sessionActivityCache[session.id]
        }
        return map
    }

    private var activeLoopSessionIDs: Set<UUID> {
        activeLoopSessionIDs(in: visibleSessions)
    }

    private func activeLoopSessionIDs(in sessions: [PiAgentSessionRecord]) -> Set<UUID> {
        let sessionIDs = Set(sessions.map(\.id))
        return Set(store.loopRunsBySessionID.compactMap { sessionID, runs in
            sessionIDs.contains(sessionID) && runs.contains(where: \.isActive) ? sessionID : nil
        })
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, TranscriptFloatingControlGeometry.transcriptHorizontalPadding)
                    .transcriptEdgeFade()

                // NOTE: the old opaque "settle cover" (spinner shown over the
                // transcript on every session switch) is gone. The switch is now
                // correct on its first frame — the coordinator holds the previous
                // transcript until the new one is decoded, then measures the
                // visible rows synchronously before pinning — so hiding the table
                // behind a spinner only ADDED a flash of loading state per click.

                // Sits ON TOP of the edge fade (added after it) so the pill
                // itself is never faded out. Isolated in its own view that observes
                // `transcriptPinnedState` so toggling the pill never re-evaluates this
                // screen's body (and never re-runs the transcript items build).
                JumpToLatestOverlay(pinnedState: transcriptPinnedState) {
                    requestTranscriptBottomScroll()
                }
            }
            PiAgentProcessingIndicatorBar(message: stabilizedProcessingMessage)

            Divider()

            VStack(spacing: 12) {
                // Shown for project drafts, including subagents-off — the card
                // renders dimmed with its switch so agents can be turned back
                // on right here instead of from the Agents screen. General Chat
                // never exposes Deck-agent delegation.
                if let session = store.selectedSession,
                   !session.isNoProject,
                   session.status == .draft,
                   store.activeLoopRun(for: session.id) == nil {
#if DEBUG
                    PiAgentSessionSubagentPickerCard(
                        viewModel: viewModel,
                        session: session,
                        stressExpansionRequest: isPickerStressRequested ? pickerStressExpansionRequest : nil,
                        stressAcknowledgements: isPickerStressRequested ? pickerStressAcknowledgements : nil
                    )
                    .id(session.id)
#else
                    PiAgentSessionSubagentPickerCard(viewModel: viewModel, session: session)
                        .id(session.id)
#endif
                }

                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                } else if let request = selectedPendingSupervisorRequest {
                    PiSubagentSupervisorRequestInlineNotice(
                        request: request,
                        onRespond: { isSupervisorRequestSheetPresented = true },
                        onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID) }
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
            isTranscriptLoading: { [store] in store.isSelectedTranscriptLoading },
            bottomScrollRequest: transcriptBottomScrollRequest,
            makeItems: { appKitTranscriptItems },
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptPinnedState.isPinned = isPinnedToBottom
            },
            onBenchAdvanceSession: { viewModel.selectNextPiAgentSession() },
            benchSessionCount: { viewModel.scopedPiAgentSessionsInOrder().count }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptPinnedState.isPinned else { return }
            requestTranscriptBottomScroll()
        }
        .perfScene("PiAgentTranscript")
    }

    private var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
        // Hidden tab: don't rebuild on streaming pulses. The screen stays mounted
        // (so the table is never torn down), but returning the last-built rows means
        // a backgrounded streaming session does no per-tick transcript work. The
        // next pulse after becoming active rebuilds to current content.
        if !isActive { return transcriptCache.memoizedTranscriptItems }
        return TranscriptScrollProfiler.measureBody("itemsBuild") {
            // `makeItems` is re-run on every host body pass — cache pulses, but also
            // scroll-time re-evaluations that don't change the transcript at all.
            // Skip the O(N) rebuild when no input changed: compute a cheap signature
            // and reuse the last array on a match. The signature reads every input the
            // build does, so it can never serve stale content.
            let signature = appKitTranscriptItemsSignature
            if transcriptCache.memoizedTranscriptItemsSignature == signature {
                return transcriptCache.memoizedTranscriptItems
            }
#if DEBUG
            debugLogItemsBuildTrigger()
#endif
            let items = appKitTranscriptItemsBuild
            transcriptCache.memoizedTranscriptItems = items
            transcriptCache.memoizedTranscriptItemsSignature = signature
            return items
        }
    }

    /// COMPLETE signature of every input `appKitTranscriptItemsBuild` reads.
    /// `renderRevision`/`streamingRevision` cover all transcript content (threads).
    /// `appKitTranscript{Chrome,ThreadContext}Revision` are the SAME hashes the build
    /// folds into each row's `contentRevision`, so reusing them here captures the
    /// session-level inputs (status, worktree/project, loading, visibility, skills,
    /// subagent summary) without re-listing them — and can't drift if those helpers
    /// gain a read. The tail adds the few inputs those revisions don't cover.
    private var appKitTranscriptItemsSignature: Int {
        let snapshot = transcriptTimelineSnapshot
        var hasher = Hasher()
        hasher.combine(transcriptCache.renderRevision)
        hasher.combine(transcriptCache.streamingRevision)
        hasher.combine(appKitTranscriptChromeRevision(snapshot: snapshot))
        hasher.combine(appKitTranscriptThreadContextRevision(snapshot: snapshot))
        hasher.combine(showArchivedPreCompactionTranscript)
        if let session = store.selectedSession {
            hasher.combine(session.commandInvocations)         // slash-command chrome
            hasher.combine(session.forkedFromParentTitle)      // fork-origin card
            hasher.combine(session.forkedFromSessionID)
            hasher.combine(session.forkedFromTranscriptSnapshot)
            // Full run/request records can be large (nested child records, output,
            // timestamps). Hashing them on every SwiftUI body pass showed up in
            // itemsBuild hitch stacks. The store revisions are bumped on every
            // mutation, so they keep descriptor memoization correct without the
            // per-pass deep Hashable walk.
            hasher.combine(store.subagentRunsRevision)
            hasher.combine(store.supervisorRequestsRevision)
        }
        return hasher.finalize()
    }

#if DEBUG
    /// Names which memo input invalidated `appKitTranscriptItems` — the labels
    /// mirror `appKitTranscriptItemsSignature` (with the chrome/context hashes
    /// split into their fields) so an unexplained rebuild on an idle session can
    /// be attributed straight from the console. Runs only on a memo miss.
    private func debugLogItemsBuildTrigger() {
        var components: [String: Int] = [
            "render": transcriptCache.renderRevision,
            "streaming": transcriptCache.streamingRevision,
            "archived": showArchivedPreCompactionTranscript ? 1 : 0,
            "visibility": String(describing: viewModel.appSettings.piAgentTranscriptVisibility).hashValue,
            "skills": visibleSkillsForSelectedSession.map(\.name).hashValue
        ]
        if let session = store.selectedSession {
            components["sessionID"] = session.id.hashValue
            components["status"] = String(describing: session.status).hashValue
            components["loading"] = store.isSelectedTranscriptLoading ? 1 : 0
            components["path"] = (session.worktreePath ?? session.projectPath).hashValue
            components["command"] = session.commandInvocations.hashValue
            var forkHasher = Hasher()
            forkHasher.combine(session.forkedFromParentTitle)
            forkHasher.combine(session.forkedFromSessionID)
            forkHasher.combine(session.forkedFromTranscriptSnapshot)
            components["fork"] = forkHasher.finalize()
            components["runs"] = store.subagentRunsRevision
            components["requests"] = store.supervisorRequestsRevision
        }
        let previous = transcriptCache.lastItemsBuildComponents
        transcriptCache.lastItemsBuildComponents = components
        guard !previous.isEmpty else { return }
        let changed = Set(components.keys).union(previous.keys).filter { components[$0] != previous[$0] }.sorted()
        guard !changed.isEmpty else { return }
        guard TranscriptScrollProfiler.verboseTrace else { return }
        TranscriptScrollProfiler.logger.error("itemsBuild trigger — changed inputs: \(changed.joined(separator: ","), privacy: .public)")
    }
#endif

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
        // Block ids whose render kind we memoize this pass (the per-N timeline
        // rows). Used to prune the kind cache to the visible transcript below.
        var memoizedBlockIDs: Set<String> = []

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
                        let revision = appKitQuestionBlockRevision(question, contextRevision: contextRevision)
                        memoizedBlockIDs.insert(blockID)
                        // Native fast path for plain-text questions (no attachment
                        // Chip-bearing questions use the dedicated chip-aware card;
                        // plain questions use the lighter bubble.
                        let questionKind = transcriptCache.cachedBlockKind(id: blockID, revision: revision) {
                            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                                for: question, skills: skills, commandSlashNames: commandSlashNames) > 0
                            return hasChips
                                ? nativeChipQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                                : nativeQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames, showImages: visibility.showImages)
                        }
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: blockID,
                            view: nil,
                            kind: questionKind,
                            baseRevision: revision,
                            estimatedContentHeight: { Self.estimatedQuestionHeight(question, width: $0) },
                            threadID: item.id,
                            questionNavigationTitle: Self.questionNavigationTitle(for: question),
                            isThreadQuestion: true
                        ))
                    }
                    let projectPath = store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
                    for child in PiAgentTranscriptThreadCard.visibleChildren(
                        of: thread, visibility: visibility, nativeSubagentRunsByID: subagentRuns,
                        projectPath: projectPath
                    ) {
                        // Native rendering for the supported child types; the
                        // rest (tool groups, subagent/memory cards) still hosted.
                        let revision = appKitChildBlockRevision(child, contextRevision: contextRevision, subagentRuns: subagentRuns)
                        let toolGroupEstimateModel: NativeToolGroupModel? = {
                            guard case let .toolGroup(group) = child else { return nil }
                            return NativeToolGroupModel.make(group: group, visibility: visibility, projectPath: projectPath)
                        }()
                        memoizedBlockIDs.insert(child.id)
                        let nativeKind = transcriptCache.cachedBlockKind(id: child.id, revision: revision) {
                            nativeChildKind(
                                for: child, visibility: visibility, skills: skills,
                                commandSlashNames: commandSlashNames, subagentRuns: subagentRuns) ?? Self.nativeEmptyKind
                        }
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: child.id,
                            view: nil,
                            kind: nativeKind,
                            baseRevision: revision,
                            estimatedContentHeight: { Self.estimatedChildHeight(child, width: $0, toolGroupModel: toolGroupEstimateModel) },
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

        // Match the old NSScrollView top inset as an actual row so new/small
        // transcripts do not start inside the SwiftUI top fade before scrolling.
        // Insert after the inter-row gap pass so this adds exactly 18pt and no
        // extra row spacing before the shortcuts/first message.
        descriptors.insert(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-top-fade-spacer",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 18 }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 18 },
            threadID: nil,
            isThreadQuestion: false
        ), at: 0)

        transcriptCache.pruneBlockKindCache(keeping: memoizedBlockIDs)

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
                questionNavigationTitle: descriptor.questionNavigationTitle,
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
            onRerun: { [viewModel] in viewModel.rerunPiAgentSession(from: question) },
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
        // The ForkModel is cheap (it just wraps closures), so build it eagerly.
        // The payload parse (message text + chip extraction regex + folder
        // existence checks) is deferred into the configure closure so it runs only
        // when a cell actually configures — i.e. for visible rows — instead of for
        // every question on every `itemsBuild` pulse.
        let fork = questionForkModel(question)
        return .native(.of(PiAgentNativeQuestionView.self) { view, width in
            let payload = NativeQuestionPayload.make(
                entry: question, skills: skills, commandSlashNames: commandSlashNames, fork: fork)
            view.configure(payload: payload, width: width)
        })
    }

    private func nativeQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        showImages: Bool
    ) -> PiAgentTranscriptCellKind {
        let text = PiAgentUserMessageContent.displayMessageText(
            for: question, skills: skills, commandSlashNames: commandSlashNames)
        let fork = questionForkModel(question)
        return .bubble(NativeBubblePayload(
            role: .user,
            headerTitle: "You",
            iconSymbol: "person.crop.circle",
            markdownSource: text,
            imageReferences: question.imageReferences,
            showInlineImagePreviews: showImages,
            bodyPrefix: nil,
            copyText: question.text,
            copySide: .leading,
            isThreadChild: false,
            isUserHugged: true,
            fork: fork
        ))
    }

    private static func questionNavigationTitle(for entry: PiAgentTranscriptEntry) -> String {
        let collapsed = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "User message" }
        return collapsed
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

#if DEBUG
    private static let nativeToolGroupLog = Logger(subsystem: "streetcoding.agent-deck", category: "NativeToolGroup")
#endif

    private func nativeChildKind(
        for child: PiAgentThreadChild,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        subagentRuns: [UUID: PiSubagentRunRecord]
    ) -> PiAgentTranscriptCellKind? {
        switch child {
        case .assistant:
            return nativeReplyPayload(for: child, showImages: visibility.showImages).map { .bubble($0) }
        case .thinking:
            return nativeReplyPayload(for: child, showImages: visibility.showImages).map { .bubble($0) }
        case .steering(let entry):
            // Steering messages are user messages, so they render right-aligned
            // like the initial user question. Chip-bearing ones use the native
            // chip-question card; plain-text ones use the lighter bubble with
            // user-message alignment and visual weight.
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
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: visibility.showImages,
                bodyPrefix: nil,
                copyText: entry.text,
                copySide: .leading,
                isThreadChild: false,
                isUserHugged: true
            ))
        case .status(let entry):
            if let recapMarker = LoopRunRecapCodec.decode(from: entry) {
                let payload = NativeLoopRecapPayload.make(entry: entry, marker: recapMarker)
                return .native(.of(PiAgentNativeLoopRecapCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if LoopRunTranscriptCodec.decode(from: entry) != nil {
                return Self.nativeEmptyKind
            }
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
            // Fatal model/provider errors get the richer error row (fixed "Error"
            // headline + full message as the detail body); per-tool failures keep
            // the compact row.
            if entry.isModelError {
                let payload = NativeErrorPayload.make(for: entry)
                return .native(.of(PiAgentNativeErrorRowView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
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
                group: group,
                visibility: visibility,
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
            ) else {
#if DEBUG
                assertionFailure("Visible native tool group produced no display model: \(group.id)")
                Self.nativeToolGroupLog.error("Visible native tool group produced no display model: \(group.id.uuidString, privacy: .public)")
#endif
                return Self.nativeEmptyKind
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
    private func nativeReplyPayload(for child: PiAgentThreadChild, showImages: Bool) -> NativeBubblePayload? {
        switch child {
        case .assistant(let entry):
            let text = entry.text
            return NativeBubblePayload(
                role: .assistant,
                headerTitle: "Coding Agent",
                iconSymbol: nil,
                markdownSource: text,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: showImages,
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
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: showImages,
                bodyPrefix: nil,
                copyText: display,
                copySide: .trailing,
                isThreadChild: true
            )
        default:
            return nil
        }
    }

    private static func estimatedChildHeight(_ child: PiAgentThreadChild, width: CGFloat, toolGroupModel: NativeToolGroupModel? = nil) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        switch child {
        case let .assistant(entry), let .steering(entry), let .thinking(entry):
            let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
            return CGFloat(min(lines, 40)) * 18 + 48
        case .toolGroup:
            // Estimate from the same capped display model the native tool card
            // renders, not from raw activity count. MCP/web/diff groups can contain
            // many underlying updates while displaying only a compact card.
            return toolGroupModel?.estimatedContentHeight(forWidth: width) ?? 1
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
    private func appKitChildBlockRevision(
        _ child: PiAgentThreadChild,
        contextRevision: Int,
        subagentRuns: [UUID: PiSubagentRunRecord]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        switch child {
        case let .steering(entry), let .thinking(entry), let .assistant(entry),
             let .error(entry):
            hashEntryRevision(entry, into: &hasher)
        case let .status(entry):
            hashEntryRevision(entry, into: &hasher)
            // A status child fronting a Deck agent run renders the whole run
            // record (status, children, durations, results) — fold exactly that
            // run in so ONLY this row re-renders as the run streams. This is the
            // narrow replacement for the all-rows run hash that used to live in
            // the shared context revision above.
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                hasher.combine(run)
            }
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
        // Deliberately NO subagent-run state here: this revision folds into EVERY
        // row, and run records update on every subagent event — hashing them here
        // invalidated the whole transcript (full itemsBuild + visible reconfigure)
        // several times a second for the entire run (steady 40-80ms hitches). The
        // one row that renders a run folds its own record in via
        // `appKitChildBlockRevision`; the itemsBuild memo signature still hashes
        // all runs, so the descriptor list itself can never go stale.
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
        hasher.combine(entry.imageReferences)
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
        hasher.combine(entry.imageReferences)
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
        let detail = mcpToolAddress(from: entry.rawJSON)
        return toolProcessingMessage(forToolName: toolName, detail: detail)
    }

    /// Resolves the `server/tool` address from an MCP proxy entry's raw JSON,
    /// so the live status row can say "Running MCP xcode/ListWindows" instead of
    /// the generic "Running mcp".
    private func mcpToolAddress(from rawJSON: String?) -> String? {
        guard let event = PiAgentRPCEventRenderCache.event(from: rawJSON),
              let args = event.args,
              let rawTool = args["tool"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTool.isEmpty,
              let address = MCPConnectionManager.resolveAddress(rawTool, serverHint: args["server"]?.stringValue)
        else { return nil }
        return "\(address.server)/\(address.tool)"
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
        case "mcp": return target.map { "Running MCP \($0)" } ?? "Running MCP tool"
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

    private func requestSelectedTranscriptLoadAfterViewUpdate(for sessionID: UUID?) {
        Task { @MainActor in
            await Task.yield()
            // A newer selection may have arrived while this view update settled.
            // Never hydrate or publish for an obsolete session.
            guard store.selectedSession?.id == sessionID else { return }
            store.requestSelectedTranscriptLoad()
            scheduleTranscriptCacheUpdate()
            viewModel.rehydratePiAgentTranscriptIfNeeded(sessionID)
        }
    }

    private func requestSubagentTranscriptLoadAfterViewUpdate(runID: UUID) {
        Task { @MainActor in
            await Task.yield()
            store.requestSubagentTranscriptLoad(for: runID)
        }
    }

    private func resetTranscriptAutoScroll() {
        if !transcriptPinnedState.isPinned {
            transcriptPinnedState.isPinned = true
        }
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
        let suggestionTrigger = composerSuggestionTrigger
        let isFileTrigger: Bool = { if case .file = suggestionTrigger { return true }; return false }()
        let isSlashTrigger: Bool = { if case .slash = suggestionTrigger { return true }; return false }()
        let fileItems = ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
        let showsFileSuggestions = !composerSuggestionsDismissed && isFileTrigger && !fileSuggestionResults.isEmpty
        let slashRows = (!composerSuggestionsDismissed && isSlashTrigger) ? cachedSlashRows : []
        let showsSlashSuggestions = !slashRows.isEmpty
        VStack(spacing: 6) {
            if showsFileSuggestions {
                PiAgentCommandSuggestions(
                    items: fileItems,
                    selectedIndex: composerSuggestionIndex,
                    scrollTick: composerSuggestionScrollTick,
                    onSelect: { item in insertComposerSuggestion(item.insertion) },
                    onHover: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil,
                              index != composerSuggestionIndex else { return }
                        composerSuggestionIndex = index
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else if showsSlashSuggestions {
                PiAgentSlashSuggestions(
                    rows: slashRows,
                    highlightedSelectableIndex: slashState.highlightedIndex,
                    scrollTick: slashState.scrollTick,
                    title: slashPanelTitle,
                    onSelect: { row in handleSlashRowSelect(row) },
                    onHoverSelectable: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil,
                              index != slashState.highlightedIndex else { return }
                        slashState.highlightedIndex = index
                    },
                    onBack: slashCanGoBack ? { popSlashScreen() } : nil
                )
#if DEBUG
                .onAppear { SlashDebugLog.panelRender(rows: slashRows, phase: "appear", query: slashQueryString, universe: slashUniverse) }
                .onChange(of: slashRows.count) { _, _ in SlashDebugLog.panelRender(rows: slashRows, phase: "rowsChanged", query: slashQueryString, universe: slashUniverse) }
                .onChange(of: slashQueryString) { _, _ in SlashDebugLog.panelRender(rows: slashRows, phase: "queryChanged", query: slashQueryString, universe: slashUniverse) }
#endif
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
                placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : (store.selectedSession?.isNoProject == true ? "Ask Pi to inspect, explain, or brainstorm…" : "Ask Pi to implement, inspect, explain, or fix… Type / for skills, loops, and prompts."))),
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil || !slashSelections.isEmpty),
                canCreateSession: !isCompacting && store.selectedSession == nil,
                createSessionProjects: piAgentNewSessionProjects,
                onFiles: addFileAttachments,
                onFolders: addFolderAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
                slashSelections: slashSelections,
                onRemoveSlashSelection: { item in slashSelections.removeAll { $0.id == item.id } },
                onSend: hasSelectedSession ? sendComposerMessage : createSessionFromComposer,
                onStop: { viewModel.stopSelectedPiAgentSession() },
                onCreateSession: createSessionFromComposer,
                onCreateSessionForProject: createSessionFromComposer,
                onClear: clearComposerInput,
                suggestionKeyBridge: composerSuggestionKeyBridge
            )
        }
        .animation(.easeOut(duration: 0.12), value: showsFileSuggestions || showsSlashSuggestions)
        .onChange(of: composerText) { oldText, newText in
#if DEBUG
            SlashDebugLog.textChange(oldText: oldText, newText: newText)
#endif
            composerSuggestionIndex = 0
            composerSuggestionsDismissed = false
            composerSuggestionScrollTick += 1
            composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            refreshFileSuggestions()
            refreshSlashUniverseLifecycle()
            rebuildSlashSuggestionCache()
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
            guard store.selectedSession?.isNoProject != true else { return nil }
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
        cachedSlashRows
    }

    private var slashSelectableCount: Int {
        cachedSlashSelectableRows.count
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
            case .loop: return "Loops"
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
        return !cachedSlashRows.isEmpty
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
            guard cachedSlashSelectableRows.indices.contains(slashState.highlightedIndex) else { return false }
            handleSlashRowSelect(cachedSlashSelectableRows[slashState.highlightedIndex])
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
            rebuildSlashSuggestionCache()
        case .item(let itemRow):
            guard let item = slashUniverse.item(withID: itemRow.itemID) else { return }
            commitSlashSelection(item)
        }
    }

    private func popSlashScreen() {
        slashState.screen = .categoryPicker
        slashState.highlightedIndex = 0
        slashState.scrollTick &+= 1
        rebuildSlashSuggestionCache()
    }

    private func commitSlashSelection(_ item: SlashItem) {
        // Strip the leading `/<typed>` token so the pill alone represents the
        // invocation. Any other composer text the user typed is preserved.
        if let token = activeSuggestionToken, token.token.hasPrefix("/") {
            composerText.replaceSubrange(token.range, with: "")
        }
        composerText = composerText.trimmingCharacters(in: .whitespaces)

        let currentItem = viewModel.refreshedSlashItemForUse(item, projectPath: store.selectedSession?.projectPathForProjectFeatures)

        switch currentItem.payload {
        case .loopCreateNew:
            guard store.selectedSession?.projectPathForProjectFeatures != nil else {
                if let sessionID = store.selectedSession?.id {
                    store.append(.init(sessionID: sessionID, role: .error, title: "Loop Unavailable", text: "Loops are not available for General Chat sessions."))
                }
                slashSelections = []
                slashState = SlashSuggestionState()
                slashUniverse = .empty
                composerSuggestionsDismissed = true
                return
            }
            loopLaunchDraft = LoopDraft()
            loopLaunchDefinition = nil
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            composerSuggestionsDismissed = true
            isLoopLaunchSheetPresented = true
            return
        case .loopDefinition(let definition):
            guard store.selectedSession?.projectPathForProjectFeatures != nil else {
                if let sessionID = store.selectedSession?.id {
                    store.append(.init(sessionID: sessionID, role: .error, title: "Loop Unavailable", text: "Loops are not available for General Chat sessions."))
                }
                slashSelections = []
                slashState = SlashSuggestionState()
                slashUniverse = .empty
                composerSuggestionsDismissed = true
                return
            }
            loopLaunchDraft = definition.makeDraft()
            loopLaunchDefinition = definition
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            composerSuggestionsDismissed = true
            isLoopLaunchSheetPresented = true
            return
        default:
            break
        }

        // For prompts, seed the editor with the body so the user can edit
        // before sending. Commands and skills leave the editor alone — any
        // text the user types becomes the args / message body.
        if case .prompt(_, let body, _, _) = currentItem.payload {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = composerText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(composerText)"
        }

        slashSelections = SlashItem.selections(afterAdding: currentItem, to: slashSelections)
        slashState = SlashSuggestionState()
        composerSuggestionsDismissed = true
    }

    private func rebuildSlashSuggestionCache(force: Bool = false) {
        guard !composerSuggestionsDismissed, case .slash = composerSuggestionTrigger else {
            clearSlashSuggestionCache()
            return
        }
        let key = SlashSuggestionRowsCacheKey(
            universeRevision: slashUniverseRevision,
            screen: slashState.screen,
            query: slashQueryString
        )
        guard force || slashRowsCacheKey != key else { return }

        let rows = SlashSuggestionRowBuilder.rows(universe: slashUniverse, state: slashState, query: slashQueryString)
        cachedSlashRows = rows
        cachedSlashSelectableRows = SlashSuggestionRowBuilder.selectableRows(rows)
        slashRowsCacheKey = key

        if cachedSlashSelectableRows.isEmpty {
            slashState.highlightedIndex = 0
        } else if slashState.highlightedIndex >= cachedSlashSelectableRows.count {
            slashState.highlightedIndex = cachedSlashSelectableRows.count - 1
        }
    }

    private func clearSlashSuggestionCache() {
        cachedSlashRows = []
        cachedSlashSelectableRows = []
        slashRowsCacheKey = nil
    }

    private func resetSlashComposerState() {
        slashSelections = []
        slashUniverse = .empty
        slashUniverseRevision &+= 1
        slashState = SlashSuggestionState()
        clearSlashSuggestionCache()
        lastSlashTriggerActive = false
        composerSuggestionsDismissed = false
    }

    /// Builds (or releases) the cached slash universe on transitions in/out of
    /// `/` mode. Runs from `.onChange(of: composerText)` — never in `body` — so
    /// the catalog walk and its filesystem lookups stay off the hot render path.
    private func refreshSlashUniverseLifecycle() {
        let isSlashActive: Bool
        if case .slash = composerSuggestionTrigger { isSlashActive = true } else { isSlashActive = false }

        if isSlashActive && !lastSlashTriggerActive {
            let projectPath: String?
            let useSelectedProjectFallback: Bool
            if let session = store.selectedSession {
                projectPath = session.projectPathForProjectFeatures
                useSelectedProjectFallback = false
            } else {
                projectPath = viewModel.selectedProjectPath
                useSelectedProjectFallback = true
            }
#if DEBUG
            SlashDebugLog.write("slash.lifecycle.enter", [
                "query": slashQueryString,
                "projectPath": projectPath
            ])
            SlashDebugLog.write("slash.universe.build.start", ["projectPath": projectPath])
            let buildStart = Date()
#endif
            slashUniverse = viewModel.slashUniverse(forProjectPath: projectPath, useSelectedProjectFallback: useSelectedProjectFallback)
            slashUniverseRevision &+= 1
#if DEBUG
            let durationMS = Date().timeIntervalSince(buildStart) * 1000
            SlashDebugLog.write("slash.universe.build.end", slashUniverse.debugLogFields(durationMS: durationMS))
#endif
            slashState = SlashSuggestionState()
        } else if !isSlashActive && lastSlashTriggerActive {
#if DEBUG
            SlashDebugLog.write("slash.lifecycle.exit", slashUniverse.debugLogFields(rowCount: slashSuggestionRows.count))
#endif
            slashUniverse = .empty
            slashUniverseRevision &+= 1
            slashState = SlashSuggestionState()
            clearSlashSuggestionCache()
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
        let projectPath: String?
        if let session = store.selectedSession {
            projectPath = session.projectPathForProjectFeatures
        } else {
            projectPath = viewModel.selectedProjectPath
        }
        return projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
    }

    private var visibleSkillsForSelectedSession: [SkillRecord] {
        let projectPath: String?
        if let session = store.selectedSession {
            projectPath = session.projectPathForProjectFeatures
        } else {
            projectPath = viewModel.selectedProjectPath
        }
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
              session.subagentsEnabled,
              let projectPath = session.projectPathForProjectFeatures else { return nil }
        let agents = viewModel.selectableAgentUniverse(forProjectPath: projectPath)
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
        let rootPath = session.launchWorkingDirectory.path
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
        composerPasteAttachments = draft.pasteAttachments
        nextComposerPasteID = (draft.pasteAttachments.map(\.id).max() ?? 0) + 1
        composerImages = draft.images
        composerFiles = draft.files
        composerFolders = draft.folders
        composerIssueAttachment = nil
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        store.saveComposerDraft(text: composerText, pasteAttachments: composerPasteAttachments, images: composerImages, files: composerFiles, folders: composerFolders, for: sessionID)
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
        slashSelections = []
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
        let currentSlashSelections = slashSelections.map { item in
            if case .prompt = item.payload { return item }
            return viewModel.refreshedSlashItemForUse(item, projectPath: store.selectedSession?.projectPathForProjectFeatures)
        }
        let message = SlashItem.materialize(selections: currentSlashSelections, userText: baseMessage)
        let transcriptMessage = SlashItem.materialize(selections: currentSlashSelections, userText: baseTranscript)
        let titleSource = SlashItem.titleGenerationSource(selections: currentSlashSelections, userText: baseTranscript)
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        beginTranscriptAutoScrollTurn()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, titleSource: titleSource, images: composerImages, pasteAttachments: activePasteAttachments, issueAttachment: composerIssueAttachment)
        requestTranscriptBottomScroll()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = session.launchWorkingDirectory
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
        // Selection validity is owned by ONE canonical rule on the view model
        // (project scope only — never this panel's search/attention filters).
        // See the sidebar panel's twin for the ping-pong this replaces.
        viewModel.reconcileSelectedSessionWithProjectScope()
    }

    private func syncMultiSelectionToSelectedSession() {
        // Only write @State when it actually changes — an unconditional assign
        // re-evaluates the whole screen body (and re-runs the transcript's
        // updateNSView) on every sidebar refresh, including streaming pulses.
        guard let selectedID = store.selectedSession?.id else {
            if !selectedSessionIDs.isEmpty { selectedSessionIDs = [] }
            lastSelectedSessionID = nil
            return
        }
        // A list click has already written the (possibly multi) selection —
        // collapsing to a single here was what killed ⌘/⇧ multi-select. Only
        // reset when the current session jumped OUTSIDE the set.
        if !selectedSessionIDs.contains(selectedID) {
            selectedSessionIDs = [selectedID]
        }
        lastSelectedSessionID = selectedID
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        var next = selectedSessionIDs.intersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) {
            next.insert(selectedID)
        }
        // Guard the @State write so a session-list reorder (e.g. streaming bumping
        // a session's activity) doesn't pulse selection and storm the body.
        if next != selectedSessionIDs { selectedSessionIDs = next }
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
                // Hand the store a session that's still selected — re-selecting
                // the one just deselected would make the sync re-add it.
                let fallbackID = selectedSessionIDs.first
                lastSelectedSessionID = fallbackID
                if let fallbackID { viewModel.selectPiAgentSession(fallbackID) }
                return
            }
            selectedSessionIDs.insert(session.id)
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
        // Compute the next session to make current before deleting, in the
        // order the user actually sees (the row below the deleted set; the row
        // above if it ran to the end). `nil` when the current selection survives.
        let nextID = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: visibleSessions,
            deletedIDs: deleteIDs,
            selectedID: store.selectedSession?.id
        )
        selectedSessionIDs.subtract(deleteIDs)
        withAnimation(.snappy(duration: 0.18)) {
            // Optimistically drop deleted rows from the rendered sections so the
            // removal animates; `rebuildVisibleSessions()` below recomputes
            // `hiddenCount` and everything else correctly in the same tick.
            cachedSections = cachedSections.map { section in
                let remaining = section.items.filter { !deleteIDs.contains($0.id) }
                let removedInThisSection = section.items.count - remaining.count
                return PiAgentSessionListSection(
                    id: section.id,
                    title: section.title,
                    subtitle: section.subtitle,
                    iconFileURL: section.iconFileURL,
                    fallbackSymbolName: section.fallbackSymbolName,
                    assetName: section.assetName,
                    items: remaining,
                    hiddenCount: section.hiddenCount,
                    isShowMoreActive: section.isShowMoreActive,
                    isCollapsed: section.isCollapsed,
                    totalCount: max(0, section.totalCount - removedInThisSection),
                    isProjectGroup: section.isProjectGroup
                )
            }
            hasBuiltVisibleSessions = true
        }
        viewModel.deletePiAgentSessions(deleteIDs, fallbackSelectionID: nextID)
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
    @State private var slashUniverseRevision = 0
    @State private var slashRowsCacheKey: SlashSuggestionRowsCacheKey?
    @State private var cachedSlashRows: [SlashSuggestionRow] = []
    @State private var cachedSlashSelectableRows: [SlashSuggestionRow] = []
    @State private var slashSelections: [SlashItem] = []
    @State private var isLoopLaunchSheetPresented = false
    @State private var loopLaunchDraft = LoopDraft()
    @State private var loopLaunchDefinition: LoopDefinition?
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
    @State private var loopDetailsRun: LoopRun?

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let activeLoopRun = store.selectedSession.flatMap { store.activeLoopRun(for: $0.id) }
        let visibleLoopRun = store.selectedSession.flatMap { session in
            activeLoopRun ?? store.loopRuns(for: session.id).last
        }
        let isRunning = store.selectedSession?.status.isActive == true
        let isCompacting = store.selectedSession?.isCompacting == true
        let hasSelectedSession = store.selectedSession != nil
        let suggestionTrigger = composerSuggestionTrigger
        let isFileTrigger: Bool = { if case .file = suggestionTrigger { return true }; return false }()
        let isSlashTrigger: Bool = { if case .slash = suggestionTrigger { return true }; return false }()
        let fileItems = ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
        let showsFileSuggestions = !composerSuggestionsDismissed && isFileTrigger && !fileSuggestionResults.isEmpty
        let slashRows = (!composerSuggestionsDismissed && isSlashTrigger) ? cachedSlashRows : []
        let showsSlashSuggestions = !slashRows.isEmpty

        VStack(spacing: 6) {
            if activeLoopRun == nil {
                if showsFileSuggestions {
                    PiAgentCommandSuggestions(
                        items: fileItems,
                        selectedIndex: composerSuggestionIndex,
                        scrollTick: composerSuggestionScrollTick,
                        onSelect: { item in insertComposerSuggestion(item.insertion) },
                        onHover: { index in
                            guard Date.now >= composerSuggestionHoverSuppressedUntil,
                                  index != composerSuggestionIndex else { return }
                            composerSuggestionIndex = index
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                } else if showsSlashSuggestions {
                    PiAgentSlashSuggestions(
                        rows: slashRows,
                        highlightedSelectableIndex: slashState.highlightedIndex,
                        scrollTick: slashState.scrollTick,
                        title: slashPanelTitle,
                        onSelect: { row in handleSlashRowSelect(row) },
                        onHoverSelectable: { index in
                            guard Date.now >= composerSuggestionHoverSuppressedUntil,
                                  index != slashState.highlightedIndex else { return }
                            slashState.highlightedIndex = index
                        },
                        onBack: slashCanGoBack ? { popSlashScreen() } : nil
                    )
#if DEBUG
                    .onAppear { SlashDebugLog.panelRender(rows: slashRows, phase: "appear", query: slashQueryString, universe: slashUniverse) }
                    .onChange(of: slashRows.count) { _, _ in SlashDebugLog.panelRender(rows: slashRows, phase: "rowsChanged", query: slashQueryString, universe: slashUniverse) }
                    .onChange(of: slashQueryString) { _, _ in SlashDebugLog.panelRender(rows: slashRows, phase: "queryChanged", query: slashQueryString, universe: slashUniverse) }
#endif
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                }
            }
            if let visibleLoopRun {
                PiAgentLoopControlBar(
                    run: visibleLoopRun,
                    onOpenDetails: { loopDetailsRun = visibleLoopRun },
                    onStop: { _ = store.stopLoopRun(visibleLoopRun.id, sessionID: visibleLoopRun.sessionID) },
                    onRetry: { viewModel.retryLoopRun(visibleLoopRun) },
                    onSave: saveLoopAction(for: visibleLoopRun),
                    onRevealArtifacts: revealArtifactsAction(for: visibleLoopRun),
                    onRevealWorktree: revealWorktreeAction(for: visibleLoopRun),
                    onApplyWorktree: { viewModel.applyLoopWorktree(visibleLoopRun) },
                    onDiscardWorktree: discardWorktreeAction(for: visibleLoopRun),
                    onApproveHumanApproval: { _ = store.resolveHumanApprovalLoopRun(visibleLoopRun.id, sessionID: visibleLoopRun.sessionID, approved: true) },
                    onRejectHumanApproval: { _ = store.resolveHumanApprovalLoopRun(visibleLoopRun.id, sessionID: visibleLoopRun.sessionID, approved: false) }
                )
            }
            if activeLoopRun == nil {
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
                    placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : (store.selectedSession?.isNoProject == true ? "Ask Pi to inspect, explain, or brainstorm…" : "Ask Pi to implement, inspect, explain, or fix… Type / for skills, loops, and prompts."))),
                    canSend: !isCompacting && store.selectedSession != nil && activeLoopRun == nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil || !slashSelections.isEmpty),
                    canCreateSession: !isCompacting && store.selectedSession == nil,
                    createSessionProjects: piAgentNewSessionProjects,
                    onFiles: addFileAttachments,
                    onFolders: addFolderAttachments,
                    viewModel: viewModel,
                    footerSession: store.selectedSession,
                    supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                    metricsSession: runtimeFooterSession(isRunning: isRunning),
                    slashSelections: slashSelections,
                    onRemoveSlashSelection: { item in slashSelections.removeAll { $0.id == item.id } },
                    onSend: hasSelectedSession ? sendComposerMessage : createSessionFromComposer,
                    onStop: { viewModel.stopSelectedPiAgentSession() },
                    onCreateSession: createSessionFromComposer,
                    onCreateSessionForProject: createSessionFromComposer,
                    onClear: clearComposerInput,
                    suggestionKeyBridge: composerSuggestionKeyBridge
                )
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsFileSuggestions || showsSlashSuggestions)
        .sheet(item: $loopDetailsRun) { run in
            let canRevealWorktree = canRevealLoopWorktree(run)
            PiAgentLoopDetailsSheet(
                run: run,
                revealActionTitle: canRevealWorktree ? "Reveal Worktree" : "Reveal Artifacts",
                onRevealAction: canRevealWorktree ? revealWorktreeAction(for: run) : revealArtifactsAction(for: run)
            )
        }
        .sheet(isPresented: $isLoopLaunchSheetPresented) {
            if let session = store.selectedSession,
               let projectPath = session.projectPathForProjectFeatures {
                LoopLaunchSheet(
                    session: session,
                    activeRun: store.activeLoopRun(for: session.id),
                    initialDraft: loopLaunchDraft,
                    sourceDefinition: loopLaunchDefinition,
                    availableAgents: viewModel.allDisplayAgents,
                    projectAgents: viewModel.startupSnapshot(forProjectPath: projectPath).effectiveAgents,
                    onCancel: { isLoopLaunchSheetPresented = false },
                    onAssignMissingAgents: { names in
                        viewModel.assignAgentNames(names, toProjectPath: projectPath)
                    },
                    onEnableDeckAgents: {
                        viewModel.setSubagentsEnabled(true, forSessionID: session.id)
                    },
                    onLaunch: { request in
                        if store.activeLoopRun(for: session.id) != nil && !request.stopExistingActive {
                            store.append(.init(sessionID: session.id, role: .error, title: "Loop Launch Failed", text: "This transcript already has an active loop."))
                            return
                        }
                        if let saveRequest = request.saveRequest {
                            do {
                                try viewModel.saveLoopDefinitionFromDraft(request.draft, request: saveRequest)
                            } catch {
                                store.append(.init(sessionID: session.id, role: .error, title: "Loop Save Failed", text: error.localizedDescription))
                                return
                            }
                        }
                        Task { @MainActor in
                            isLoopLaunchSheetPresented = false
                            let launched = await viewModel.launchLoop(
                                session: session,
                                draft: request.draft,
                                stopExistingActive: request.stopExistingActive
                            )
                            guard launched != nil else {
                                store.append(.init(sessionID: session.id, role: .error, title: "Loop Launch Failed", text: "The loop could not be started."))
                                return
                            }
                        }
                    }
                )
            }
        }
        .onChange(of: composerText) { oldText, newText in
#if DEBUG
            SlashDebugLog.textChange(oldText: oldText, newText: newText)
#endif
            composerSuggestionIndex = 0
            composerSuggestionsDismissed = false
            composerSuggestionScrollTick += 1
            composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            refreshFileSuggestions()
            refreshSlashUniverseLifecycle()
            rebuildSlashSuggestionCache()
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
            resetSlashComposerState()
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
    }

    private func revealArtifactsAction(for run: LoopRun) -> (() -> Void)? {
        guard let path = run.artifactDirectoryPath else { return nil }
        return { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    private func revealWorktreeAction(for run: LoopRun) -> (() -> Void)? {
        guard let path = run.artifactDirectoryPath else { return nil }
        return {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: path).appendingPathComponent("worktree", isDirectory: true)
            ])
        }
    }

    private func canRevealLoopWorktree(_ run: LoopRun) -> Bool {
        guard run.writeTarget == .newWorktree,
              let path = run.artifactDirectoryPath else { return false }
        let artifactDirectoryURL = URL(fileURLWithPath: path)
        let hasWorktree = FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree", isDirectory: true).path)
        let hasAppliedMarker = FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree.applied").path)
        let hasDiscardedMarker = FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree.discarded").path)
        let worktreeAlreadyHandled = run.worktreeState == .applied || run.worktreeState == .discarded || hasAppliedMarker || hasDiscardedMarker
        return hasWorktree && !worktreeAlreadyHandled
    }

    private func saveLoopAction(for run: LoopRun) -> () -> Void {
        { [viewModel, store] in
            do {
                _ = try viewModel.saveLoopDefinitionFromRun(run)
                store.append(.init(sessionID: run.sessionID, role: .status, title: "Loop Saved", text: "Saved loop to Loop Bank."))
            } catch {
                store.append(.init(sessionID: run.sessionID, role: .error, title: "Loop Save Failed", text: error.localizedDescription))
            }
        }
    }

    private func discardWorktreeAction(for run: LoopRun) -> () -> Void {
        { [viewModel] in
            let alert = NSAlert()
            alert.messageText = "Discard loop worktree?"
            alert.informativeText = "This removes the loop worktree. Loop artifacts are kept, but unapplied worktree changes will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard Worktree")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            viewModel.discardLoopWorktree(run)
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
            guard store.selectedSession?.isNoProject != true else { return nil }
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
        cachedSlashRows
    }

    private var slashSelectableCount: Int {
        cachedSlashSelectableRows.count
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
            case .loop: return "Loops"
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
        return !cachedSlashRows.isEmpty
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
            guard cachedSlashSelectableRows.indices.contains(slashState.highlightedIndex) else { return false }
            handleSlashRowSelect(cachedSlashSelectableRows[slashState.highlightedIndex])
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
            rebuildSlashSuggestionCache()
        case .item(let itemRow):
            guard let item = slashUniverse.item(withID: itemRow.itemID) else { return }
            commitSlashSelection(item)
        }
    }

    private func popSlashScreen() {
        slashState.screen = .categoryPicker
        slashState.highlightedIndex = 0
        slashState.scrollTick &+= 1
        rebuildSlashSuggestionCache()
    }

    private func commitSlashSelection(_ item: SlashItem) {
        // Strip the leading `/<typed>` token so the pill alone represents the
        // invocation. Any other composer text the user typed is preserved.
        if let token = activeSuggestionToken, token.token.hasPrefix("/") {
            composerText.replaceSubrange(token.range, with: "")
        }
        composerText = composerText.trimmingCharacters(in: .whitespaces)

        let currentItem = viewModel.refreshedSlashItemForUse(item, projectPath: store.selectedSession?.projectPathForProjectFeatures)

        switch currentItem.payload {
        case .loopCreateNew:
            guard store.selectedSession?.projectPathForProjectFeatures != nil else {
                if let sessionID = store.selectedSession?.id {
                    store.append(.init(sessionID: sessionID, role: .error, title: "Loop Unavailable", text: "Loops are not available for General Chat sessions."))
                }
                slashSelections = []
                slashState = SlashSuggestionState()
                slashUniverse = .empty
                composerSuggestionsDismissed = true
                return
            }
            loopLaunchDraft = LoopDraft()
            loopLaunchDefinition = nil
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            composerSuggestionsDismissed = true
            isLoopLaunchSheetPresented = true
            return
        case .loopDefinition(let definition):
            guard store.selectedSession?.projectPathForProjectFeatures != nil else {
                if let sessionID = store.selectedSession?.id {
                    store.append(.init(sessionID: sessionID, role: .error, title: "Loop Unavailable", text: "Loops are not available for General Chat sessions."))
                }
                slashSelections = []
                slashState = SlashSuggestionState()
                slashUniverse = .empty
                composerSuggestionsDismissed = true
                return
            }
            loopLaunchDraft = definition.makeDraft()
            loopLaunchDefinition = definition
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            composerSuggestionsDismissed = true
            isLoopLaunchSheetPresented = true
            return
        default:
            break
        }

        // For prompts, seed the editor with the body so the user can edit
        // before sending. Commands and skills leave the editor alone — any
        // text the user types becomes the args / message body.
        if case .prompt(_, let body, _, _) = currentItem.payload {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = composerText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(composerText)"
        }

        slashSelections = SlashItem.selections(afterAdding: currentItem, to: slashSelections)
        slashState = SlashSuggestionState()
        composerSuggestionsDismissed = true
    }

    private func rebuildSlashSuggestionCache(force: Bool = false) {
        guard !composerSuggestionsDismissed, case .slash = composerSuggestionTrigger else {
            clearSlashSuggestionCache()
            return
        }
        let key = SlashSuggestionRowsCacheKey(
            universeRevision: slashUniverseRevision,
            screen: slashState.screen,
            query: slashQueryString
        )
        guard force || slashRowsCacheKey != key else { return }

        let rows = SlashSuggestionRowBuilder.rows(universe: slashUniverse, state: slashState, query: slashQueryString)
        cachedSlashRows = rows
        cachedSlashSelectableRows = SlashSuggestionRowBuilder.selectableRows(rows)
        slashRowsCacheKey = key

        if cachedSlashSelectableRows.isEmpty {
            slashState.highlightedIndex = 0
        } else if slashState.highlightedIndex >= cachedSlashSelectableRows.count {
            slashState.highlightedIndex = cachedSlashSelectableRows.count - 1
        }
    }

    private func clearSlashSuggestionCache() {
        cachedSlashRows = []
        cachedSlashSelectableRows = []
        slashRowsCacheKey = nil
    }

    private func resetSlashComposerState() {
        slashSelections = []
        slashUniverse = .empty
        slashUniverseRevision &+= 1
        slashState = SlashSuggestionState()
        clearSlashSuggestionCache()
        lastSlashTriggerActive = false
        composerSuggestionsDismissed = false
    }

    /// Builds (or releases) the cached slash universe on transitions in/out of
    /// `/` mode. Runs from `.onChange(of: composerText)` — never in `body` — so
    /// the catalog walk and its filesystem lookups stay off the hot render path.
    private func refreshSlashUniverseLifecycle() {
        let isSlashActive: Bool
        if case .slash = composerSuggestionTrigger { isSlashActive = true } else { isSlashActive = false }

        if isSlashActive && !lastSlashTriggerActive {
            let projectPath: String?
            let useSelectedProjectFallback: Bool
            if let session = store.selectedSession {
                projectPath = session.projectPathForProjectFeatures
                useSelectedProjectFallback = false
            } else {
                projectPath = viewModel.selectedProjectPath
                useSelectedProjectFallback = true
            }
#if DEBUG
            SlashDebugLog.write("slash.lifecycle.enter", [
                "query": slashQueryString,
                "projectPath": projectPath
            ])
            SlashDebugLog.write("slash.universe.build.start", ["projectPath": projectPath])
            let buildStart = Date()
#endif
            slashUniverse = viewModel.slashUniverse(forProjectPath: projectPath, useSelectedProjectFallback: useSelectedProjectFallback)
            slashUniverseRevision &+= 1
#if DEBUG
            let durationMS = Date().timeIntervalSince(buildStart) * 1000
            SlashDebugLog.write("slash.universe.build.end", slashUniverse.debugLogFields(durationMS: durationMS))
#endif
            slashState = SlashSuggestionState()
        } else if !isSlashActive && lastSlashTriggerActive {
#if DEBUG
            SlashDebugLog.write("slash.lifecycle.exit", slashUniverse.debugLogFields(rowCount: slashSuggestionRows.count))
#endif
            slashUniverse = .empty
            slashUniverseRevision &+= 1
            slashState = SlashSuggestionState()
            clearSlashSuggestionCache()
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
        let projectPath: String?
        if let session = store.selectedSession {
            projectPath = session.projectPathForProjectFeatures
        } else {
            projectPath = viewModel.selectedProjectPath
        }
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
        let rootPath = session.launchWorkingDirectory.path
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
        // The slash selection is not part of a persisted composer draft. Drop
        // it whenever a draft is loaded (session switch, window re-key, etc.)
        // so a skill chip from session A never leaks into session B.
        slashSelections = []

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
        composerPasteAttachments = draft.pasteAttachments
        nextComposerPasteID = (draft.pasteAttachments.map(\.id).max() ?? 0) + 1
        composerImages = draft.images
        composerFiles = draft.files
        composerFolders = draft.folders
        composerIssueAttachment = nil
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        store.saveComposerDraft(text: composerText, pasteAttachments: composerPasteAttachments, images: composerImages, files: composerFiles, folders: composerFolders, for: sessionID)
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
        slashSelections = []
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
        if let session = store.selectedSession, store.activeLoopRun(for: session.id) != nil {
            store.append(.init(sessionID: session.id, role: .status, title: "Composer Locked", text: "Loop running — use loop controls."))
            return
        }
        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: composerText, attachments: composerPasteAttachments)
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: activePasteAttachments)
        let baseMessage = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTranscript = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSlashSelections = slashSelections.map { item in
            if case .prompt = item.payload { return item }
            return viewModel.refreshedSlashItemForUse(item, projectPath: store.selectedSession?.projectPathForProjectFeatures)
        }
        let message = SlashItem.materialize(selections: currentSlashSelections, userText: baseMessage)
        let transcriptMessage = SlashItem.materialize(selections: currentSlashSelections, userText: baseTranscript)
        let titleSource = SlashItem.titleGenerationSource(selections: currentSlashSelections, userText: baseTranscript)
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        onWillSend()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, titleSource: titleSource, images: composerImages, pasteAttachments: activePasteAttachments, issueAttachment: composerIssueAttachment)
        onDidSend()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = session.launchWorkingDirectory
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
