import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Render cache, stack, slash key, picker stress helpers

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
