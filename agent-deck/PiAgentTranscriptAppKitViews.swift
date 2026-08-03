import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers


let piAgentLeakedToolNames: Set<String> = ["bash", "read", "edit", "write", "find", "grep", "subagent", "web_search", "fetch_content", "get_search_content", "web_fetch"]

struct SlashSuggestionRowsCacheKey: Equatable {
    let universeRevision: Int
    let screen: SlashSuggestionState.Screen
    let query: String
}

#if DEBUG
/// DEBUG-only row source for the mounted production picker stress card.
enum PickerStressRowSource: String {
    case synthetic
    case resolved
}

@MainActor
final class PickerStressCardAcknowledgements {
    var sessionID: UUID?
    var mounted = false
    var expanded = false
    var rowCount = 0
    var isCompact = false
    var cardSize = CGSize.zero
    var catalogSize = CGSize.zero
    var rowSource: PickerStressRowSource?
    /// Advances only when the catalog reports a fresh measured geometry.
    var catalogGeometryRevision = 0

    func reset(for sessionID: UUID) {
        self.sessionID = sessionID
        mounted = false
        expanded = false
        rowCount = 0
        isCompact = false
        cardSize = .zero
        catalogSize = .zero
        rowSource = nil
        catalogGeometryRevision = 0
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
    var memoizedTranscriptItems: [PiAgentAppKitTranscriptItem] = []
    var memoizedTranscriptItemsSignature: Int?
#if DEBUG
    // Last itemsBuild signature inputs, labeled — lets the rebuild-trigger
    // diagnostic name exactly which input invalidated the memo. Not @Published
    // (written during a body pass, same contract as the memo fields above).
    var lastItemsBuildComponents: [String: Int] = [:]
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
    //   defaults write works.earendil.pi-deck StreamSimEnabled -bool YES
    //   (StreamSimRounds=3, StreamSimSeconds=6 overridable)
    //   log stream --predicate 'subsystem == "works.earendil.pi-deck" AND (category == "StreamSim" OR category == "HangWatchdog" OR category == "ScrollPerf")' --info
    private static let streamSimLog = Logger(subsystem: "works.earendil.pi-deck", category: "StreamSim")
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
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
            entries.append(PiAgentTranscriptEntry(sessionID: sid, role: .assistant, title: LanguageStore.shared.t("agent.assistant"), text: chunk))
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
        TextSanitizer.sanitizeAnswer(text)
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
                || entry.isSystemNoticeStatus
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

extension PiAgentTranscriptEntry {
    var isNativeSubagentCard: Bool {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return false }
        return type == "agent_deck_subagent_started" || type == "agent_deck_subagent_card"
    }

}

struct PiAgentTranscriptTimelineItem: Identifiable {
    enum Kind {
        case thread(PiAgentTranscriptThread)
    }

    let id: String
    let timestamp: Date
    let kind: Kind
}

struct PiAgentTranscriptTimelineSnapshot {
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

struct PiAgentAppKitTranscriptItem {
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


enum PiAgentTranscriptTableSection: Hashable {
    case main
}

struct UserQuestionNavigationRailItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isActive: Bool
    /// Vertical px offset from the rail's center, used only in sliding-window
    /// mode (many questions). 0 = rail center; negative = older (up), positive
    /// = newer (down), mirroring the transcript so marks track their messages.
    var centerOffset: CGFloat = 0
}

enum TranscriptFloatingControlGeometry {
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
protocol QuestionRailKeyboardNavigationHandling: AnyObject {
    func handleQuestionRailKeyboardShortcut(_ event: NSEvent) -> Bool
}

@MainActor
final class PiAgentTranscriptTableView: NSTableView {
    weak var questionNavigationHandler: QuestionRailKeyboardNavigationHandling?

    override func keyDown(with event: NSEvent) {
        if questionNavigationHandler?.handleQuestionRailKeyboardShortcut(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class PiAgentTranscriptScrollView: NSScrollView {
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
final class QuestionRailModel: ObservableObject {
    @Published var items: [UserQuestionNavigationRailItem] = []
    @Published var availableWidth: CGFloat = 0
    /// Host (visible) rail height in px. Used by the overflow view's scroll frame.
    @Published var railHeight: CGFloat = 0
    /// True when the questions no longer fit as an evenly-spaced stack — the view
    /// then switches to a compact vertical scroller with edge fades.
    @Published var isSliding = false
}

struct UserQuestionNavigationRail: View {
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

final class UserQuestionNavigationRailHostView: NSHostingView<UserQuestionNavigationRail> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating "scroll to latest" affordance shown when the transcript is not
/// pinned to the bottom — tapping it scrolls to the newest content and
/// re-engages streaming auto-follow.
struct JumpToLatestPill: View {
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
        .help(LanguageStore.shared.t("agent.jumpLatestShort"))
        .accessibilityLabel(LanguageStore.shared.t("agent.jumpLatestHelp"))
    }
}

/// Holds the transcript's pinned-to-bottom flag in a reference type so the screen
/// can keep it in `@State` (which watches identity only). Scrolling flips this
/// constantly; only `JumpToLatestOverlay` observes it, so flips don't invalidate
/// the screen body or re-run the transcript items build.
final class TranscriptPinnedState: ObservableObject {
    @Published var isPinned = true
}

/// The "jump to latest" pill, isolated so that toggling pinned-to-bottom on scroll
/// re-renders only this small view — never the screen body / transcript host.
struct JumpToLatestOverlay: View {
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
struct PiAgentTranscriptBlockDescriptor {
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
struct PiAgentTranscriptHost: View {
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

struct PiAgentAppKitTranscriptView: NSViewRepresentable {
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
        // Gated by `defaults write works.earendil.pi-deck ScrollBenchEnabled -bool YES`.
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
        /// Cleanup after proactive bubble-width animation (must not share cancel
        /// with `pendingWidthWork` or the flag/settle can be stranded).
        private var pendingWidthAnimationCleanup: DispatchWorkItem?
        private var widthReconfigureGeneration = 0
        private var lastWidthChangeTime: CFTimeInterval = 0
        /// Quiet period before applying a width reconfig. Large jumps (sidebar
        /// open/close) settle briefly then ease bubble widths once — smoother than
        /// per-frame live tracking (which felt choppy).
        private let widthChangeSettleWindow: CFTimeInterval = 0.12
        /// Live width tracking while the Review column animates open/close.
        /// 60fps minimum so bubbles stay in lockstep with the panel spring.
        private let widthTrackInterval: CFTimeInterval = 1.0 / 60.0
        private var lastWidthDelta: CGFloat = 0
        private var lastWidthReconfigTime: CFTimeInterval = 0
        private var lastWidthTrackApplyTime: CFTimeInterval = 0
        /// True while a splitter drag is active. The transcript column width is
        /// FROZEN at its pre-drag value so content doesn't rewrap mid-drag (which
        /// overlaps rows when narrowed) and doesn't reflow every frame (jitter).
        /// On drag end the flag clears and one clean re-layout happens to settle.
        private var isLiveResizing = false
        // (legacy name kept out — large-delta uses trackLive instead of settle)
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
        private var columnWidthAnimateObserver: NSObjectProtocol?
        private var columnResizeActiveObserver: NSObjectProtocol?
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
        /// Disable with: `defaults write works.earendil.pi-deck TranscriptPrewarmDisabled -bool YES`.
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

            // Disabled for the top-level three-column host: predicting a target
            // width before the real viewport settles made bubble chrome and text
            // content appear to scale/move twice. The frame-change observer is the
            // single live width source; it's gated while a splitter drag is active
            // so the transcript stays frozen (no rewrap / overlap / jitter) until
            // the drag ends and it re-lays out once to the settled width.
            columnWidthAnimateObserver = nil

            // Freeze transcript sizing while the user drags a splitter (Review /
            // sidebar); thaw + re-layout when they release (`active: false`).
            columnResizeActiveObserver = NotificationCenter.default.addObserver(
                forName: .transcriptColumnResizeActive,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let active = (note.userInfo?["active"] as? Bool) ?? false
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveResizing = active
                    if !active {
                        // Drag ended: let the frame observer pick up the settled
                        // width and do ONE clean re-layout.
                        self.updateColumnWidthIfNeeded()
                    }
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
            if let columnWidthAnimateObserver { NotificationCenter.default.removeObserver(columnWidthAnimateObserver) }
            if let columnResizeActiveObserver { NotificationCenter.default.removeObserver(columnResizeActiveObserver) }
            boundsObserver = nil
            frameObserver = nil
            liveScrollStartObserver = nil
            liveScrollEndObserver = nil
            columnWidthAnimateObserver = nil
            columnResizeActiveObserver = nil
            pendingHeightWork?.cancel()
            pendingScrollWork?.cancel()
            pendingSettleScrollWork?.cancel()
            pendingGlideLandingSettleWork?.cancel()
            pendingSessionSwitchSettleWork?.cancel()
            pendingRemeasureWork?.cancel()
            pendingRemeasureIDs.removeAll()
            pendingWidthWork?.cancel()
            pendingWidthAnimationCleanup?.cancel()
            pendingWidthAnimationCleanup = nil
            TranscriptLayoutAnimation.animateWidth = false
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
        //   defaults write works.earendil.pi-deck StreamScrollTestEnabled -bool YES
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
        ///   defaults write works.earendil.pi-deck ScrollProbeEnabled -bool YES
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
        ///   defaults write works.earendil.pi-deck BuildBenchEnabled -bool YES
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
                TranscriptScrollProfiler.logger.error("SCROLLBENCH armed (ScrollBenchEnabled defaults flag) — sweeping up to \(self.benchTargetSessions) of \(self.benchScopedCount) session(s); disable: defaults delete works.earendil.pi-deck ScrollBenchEnabled")
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
            let delta = abs(width - contentWidth)
            guard delta > 0.5 else { return }

            // While a splitter drag (or panel-open/close animation freeze)
            // is active, keep the table column width in lock-step with the
            // viewport so the unpack on thaw is ~0 — eliminating the second
            // visible reflow flash. We only update the column + card widths,
            // not the height bucketing; that resolves naturally on settle.
            if isLiveResizing {
                contentWidth = width
                lastWidthChangeTime = CACurrentMediaTime()
                lastWidthDelta = delta
                tableView.tableColumns.first?.width = width
                tableView.sizeLastColumnToFit()
                applyWidthOnlyToVisibleCells(width: width, animated: false, duration: 0)
                return
            }

            lastWidthDelta = delta
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
            // Continuous motion (Review sidebar / window resize): live-track with
            // width-only constraint updates (cheap). Tiny jitter still settles.
            let trackLive = lastWidthDelta > 2
            let delay: CFTimeInterval
            if trackLive {
                delay = max(0, widthTrackInterval - (CACurrentMediaTime() - lastWidthTrackApplyTime))
            } else {
                delay = max(0, widthChangeSettleWindow - (CACurrentMediaTime() - scheduledChangeTime))
            }
#if DEBUG
            if TranscriptScrollProfiler.verboseTrace {
                TranscriptScrollProfiler.fileLog("WIDTH reconfig scheduled width=\(String(format: "%.0f", scheduledWidth)) delay=\(String(format: "%.0f", delay * 1000))ms track=\(trackLive)")
            }
#endif
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard generation == self.widthReconfigureGeneration else { return }
                self.pendingWidthWork = nil

                if trackLive {
                    self.lastWidthTrackApplyTime = CACurrentMediaTime()
                    // Only card width constraints — no markdown rebuild.
                    self.applyWidthOnlyToVisibleCells()
                    let quietFor = CACurrentMediaTime() - self.lastWidthChangeTime
                    let widthMoved = abs(self.contentWidth - scheduledWidth) > 0.5
                        || self.lastWidthChangeTime != scheduledChangeTime
                    if widthMoved || quietFor < self.widthTrackInterval * 2 {
                        self.scheduleVisibleWidthReconfigure()
                    } else {
                        // Final settle: applyRowWidth already re-wrapped each
                        // cell's markdown in place, so heights are already correct.
                        // Sync the table column and let cells report new heights
                        // naturally — avoid reconfigureAllVisibleCells which
                        // rebuilds markdown from scratch and causes a visible flash.
                        TranscriptLayoutAnimation.animateWidth = false
                        self.syncTableColumnAfterWidthSettle()
                    }
                    return
                }

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
                // Prefer immediate width apply + short ease only when not streaming.
                let allowEase = !self.profiler.isStreamingRecently
                TranscriptLayoutAnimation.animateWidth = allowEase
                // Gentle settle: nudge card widths in place, then sync table
                // column + heights without a full markdown rebuild (no flash).
                self.applyWidthOnlyToVisibleCells(width: self.contentWidth, animated: allowEase, duration: TranscriptLayoutAnimation.duration)
                self.syncTableColumnAfterWidthSettle()
                if allowEase {
                    let clearAfter = TranscriptLayoutAnimation.duration + 0.05
                    DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
                        if CACurrentMediaTime() - self.lastWidthReconfigTime >= clearAfter - 0.02 {
                            TranscriptLayoutAnimation.animateWidth = false
                        }
                    }
                } else {
                    TranscriptLayoutAnimation.animateWidth = false
                }
            }
            pendingWidthWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        /// Live sidebar tracking: only nudge bubble/question card widths.
        private func applyWidthOnlyToVisibleCells() {
            applyWidthOnlyToVisibleCells(width: contentWidth, animated: false, duration: 0)
        }

        private func applyWidthOnlyToVisibleCells(width: CGFloat, animated: Bool, duration: TimeInterval) {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView,
                      let native = cell.nativeRow else { continue }
                if let bubble = native as? PiAgentNativeBubbleView {
                    bubble.applyRowWidth(width, animated: animated, duration: duration)
                } else if let question = native as? PiAgentNativeQuestionView {
                    question.applyRowWidth(width, animated: animated, duration: duration)
                }
            }
            tableView.needsLayout = true
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
            // Streaming must never inherit a leftover width-ease flag.
            TranscriptLayoutAnimation.animateWidth = false
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

        /// Gentle post-track settle: sync the table column width and let
        /// cells that already re-wrapped via applyRowWidth report their new
        /// heights naturally. Avoids the full markdown rebuild (flash) that
        /// reconfigureAllVisibleCells would cause.
        private func syncTableColumnAfterWidthSettle() {
            guard let tableView else { return }
            let width = currentViewportWidth()
            let delta = abs(width - contentWidth)
            if delta > 0.5 {
                contentWidth = width
                tableView.tableColumns.first?.width = width
                tableView.sizeLastColumnToFit()
            }
            estimateByID.removeAll()
            lastWidthReconfigTime = CACurrentMediaTime()
            // Let visible cells report their re-wrapped heights. Cells were
            // already nudged to the new width by applyRowWidth; we just trigger
            // a height report for any cell whose height changed.
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            var retileIDs: Set<String> = []
            let bucket = Int(width.rounded())
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                let h = cell.forcedIntrinsicHeight()
                let prior = measuredHeightByID[id]?[bucket] ?? lastNotedHeight[id] ?? estimatedRowHeight
                if h > 0 && abs(h - prior) > heightChangeEpsilon {
                    measuredHeightByID[id, default: [:]][bucket] = h
                    lastNotedHeight[id] = h
                    retileIDs.insert(id)
                }
            }
            if !retileIDs.isEmpty {
                noteHeightsChanged(forIDs: retileIDs)
            }
        }

        private func reconfigureAllVisibleCells() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            lastWidthReconfigTime = CACurrentMediaTime()
            // `TranscriptLayoutAnimation.animateWidth` is set by the caller:
            // live sidebar tracking → false (pixel-follow); quiet settle → true.
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
            // Width reflow (sidebar open/close) may ease heights — but NEVER during
            // streaming. Animating noteHeightOfRows per token kills the stream feel
            // (looks buffered / non-streaming). Also never use a time-window after
            // lastWidthReconfigTime: that kept poisoning stream retiles for ~0.4s.
            let easeWidthReflow = TranscriptLayoutAnimation.animateWidth
                && !profiler.isStreamingRecently
            NSAnimationContext.current.duration = easeWidthReflow ? TranscriptLayoutAnimation.duration : 0
            // Suppress implicit Core Animation actions so a streaming row's
            // height change re-tiles instantly with no per-token animation.
            CATransaction.begin()
            CATransaction.setDisableActions(!easeWidthReflow)
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
        var nativeRow: NSView?
        private var nativeRowTypeID: ObjectIdentifier?
        private var nativeRowSpec: NativeRowSpec?
        private var nativeTopC: NSLayoutConstraint?
        private var nativeBottomC: NSLayoutConstraint?
        private var configuredTopInset: CGFloat = 0
        private var configuredBottomInset: CGFloat = 0
        var configuredItemID: String?
        private var configuredRevision: Int?
        var configuredWidth: CGFloat = 0
        var lastIntrinsicHeight: CGFloat = -1
        weak var profiler: TranscriptScrollProfiler?

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

extension PiAgentTranscriptThread {
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
/// All per-row dynamic state (selection, running, title-generating, git
/// activity) is passed in as resolved values and compared in `==`, so the
/// list can never go stale: a real change to any of them differs the inputs and
/// forces a rebuild. Bindings and callbacks are intentionally excluded from `==`.
