import Foundation
import os

#if DEBUG
/// Focused, low-noise probe for the streaming transcript **wobble** — the
/// vertical up/down jitter of the bottom bubble while tokens stream in.
///
/// Streaming markdown text only ever *grows*: each tick appends characters, so a
/// smooth transcript is one where the bottom row's tiled height increases
/// monotonically and the auto-follow glide eases down to a bottom that only moves
/// further away. Wobble is therefore one of exactly two measurable faults, and
/// this probe is built to name which:
///
///   • **measure instability** — a tick measures the row *shorter* than the
///     previous tile (Δ<0), or the markdown measure took the cold double-pass /
///     full rebuild path (which can return a different height than the cheap
///     single pass for the same text). The row content itself jitters.
///
///   • **glide overshoot** — the row grows monotonically but the scroll glide
///     eased past the true bottom (trueGap<0) and has to pull *back up*, sliding
///     the just-rendered content downward for a frame. The scroll chases a
///     moving/over-estimated target.
///
/// Both faults are surfaced as `.error` lines (so they show in a default console
/// capture) with the full context on ONE line; steady monotonic growth is logged
/// only as a sparse heartbeat so the console stays readable. On row idle a single
/// SUMMARY line reports the verdict for that streamed message.
///
/// ## Reading the logs
/// No sandbox, so `os.Logger` is visible system-wide. While a response streams:
/// ```
/// log stream --predicate 'subsystem == "works.earendil.pi-deck" AND category == "StreamWobble"' --info
/// ```
/// or after the fact:
/// ```
/// log show --last 2m --predicate 'subsystem == "works.earendil.pi-deck" AND category == "StreamWobble"' --info
/// ```
///
/// OFF by default — it must be explicitly enabled while hunting wobble, so it
/// never adds per-token logging to a normal debug session:
/// `defaults write works.earendil.pi-deck StreamWobbleProbe -bool YES`
/// (DEBUG builds only; release compiles every call site to a pass-through.)
@MainActor
final class TranscriptStreamWobbleProbe {
    static let logger = Logger(subsystem: "works.earendil.pi-deck", category: "StreamWobble")

    static let isEnabled: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "StreamWobbleProbe")
        #else
        return false
        #endif
    }()

    static let shared = TranscriptStreamWobbleProbe()

    // MARK: Measure trace (set by the markdown layer, read by the re-tile)
    //
    // The markdown container computes the row height a layer below the
    // coordinator. These statics let `measureHeight`/`configure` stamp HOW the
    // last height was produced, which the coordinator then folds onto the same
    // re-tile line — so one log entry carries both the visible delta and its
    // cause without threading a return value through three call layers. Valid
    // only for the synchronous span between a forced measure and the tile that
    // reads it (everything here is @MainActor + synchronous), then cleared.

    enum MeasurePath: String { case cacheHit, cheapSingle, coldDouble }
    enum DocPath: String { case reconcile, rebuild, firstBuild, styleRebuild }

    private(set) var lastMeasurePath: MeasurePath?
    /// For the cold double-pass: the height after pass 1 (stale-wide wrap) vs
    /// pass 2 (re-wrapped). A gap between them is the measure disagreeing with
    /// itself within a single tick — the purest wobble fingerprint.
    private(set) var lastColdPass1: CGFloat = 0
    private(set) var lastColdPass2: CGFloat = 0
    private(set) var lastDocPath: DocPath?
    private(set) var lastBailReason: String?

    static func recordMeasure(path: MeasurePath, width: CGFloat, height: CGFloat,
                              coldPass1: CGFloat = 0, coldPass2: CGFloat = 0) {
        guard isEnabled else { return }
        shared.lastMeasurePath = path
        shared.lastColdPass1 = coldPass1
        shared.lastColdPass2 = coldPass2
    }

    static func recordDocPath(_ path: DocPath, bailReason: String? = nil) {
        guard isEnabled else { return }
        shared.lastDocPath = path
        shared.lastBailReason = bailReason
    }

    private func consumeTrace() -> (MeasurePath?, DocPath?, String?, CGFloat, CGFloat) {
        defer {
            lastMeasurePath = nil
            lastDocPath = nil
            lastBailReason = nil
            lastColdPass1 = 0
            lastColdPass2 = 0
        }
        return (lastMeasurePath, lastDocPath, lastBailReason, lastColdPass1, lastColdPass2)
    }

    // MARK: Per-row streaming stats
    private struct RowStat {
        var ticks = 0
        var shrinks = 0          // Δ<0 events: measured shorter than last tile
        var coldMeasures = 0     // measures that took the cold double-pass
        var rebuilds = 0         // markdown full rebuilds (incremental bail)
        var passDisagreements = 0 // cold pass1 != pass2 within one measure
        var minHeight: CGFloat = .greatestFiniteMagnitude
        var maxHeight: CGFloat = 0
        var lastHeight: CGFloat = 0
        var maxShrinkPx: CGFloat = 0
    }
    private var rows: [String: RowStat] = [:]
    private var idleFlush: [String: DispatchWorkItem] = [:]
    private let heartbeatEvery = 12

    private func shortID(_ id: String) -> String { String(id.suffix(6)) }

    /// Record one re-tile of a streaming row: the height AppKit is about to tile
    /// it at (`height`) vs what it was tiled at before (`previousTiled`). Folds in
    /// the measure/doc-path trace stamped by the markdown layer for this same
    /// measurement. Call this at the point the coordinator decides to re-tile a
    /// streaming row (forced sync measure or the async height report).
    func noteTile(id: String, height: CGFloat, previousTiled: CGFloat,
                  width: CGFloat, pinned: Bool, gliding: Bool, source: String) {
        guard Self.isEnabled else { return }
        let (mPath, dPath, bail, cp1, cp2) = consumeTrace()
        let delta = height - previousTiled
        var stat = rows[id] ?? RowStat()
        stat.ticks += 1
        stat.lastHeight = height
        stat.minHeight = min(stat.minHeight, height)
        stat.maxHeight = max(stat.maxHeight, height)
        let shrank = delta < -0.5 && previousTiled > 0
        if shrank { stat.shrinks += 1; stat.maxShrinkPx = max(stat.maxShrinkPx, -delta) }
        if mPath == .coldDouble { stat.coldMeasures += 1 }
        if dPath == .rebuild || dPath == .styleRebuild { stat.rebuilds += 1 }
        let coldDisagree = mPath == .coldDouble && abs(cp1 - cp2) > 0.5
        if coldDisagree { stat.passDisagreements += 1 }
        rows[id] = stat

        let measureTag = mPath?.rawValue ?? "?"
        let docTag = dPath.map { bail != nil ? "\($0.rawValue)(\(bail!))" : $0.rawValue } ?? "-"
        let coldDetail = mPath == .coldDouble ? " p1=\(Int(cp1)) p2=\(Int(cp2))" : ""

        // ⚠️ The two faults: a height that went DOWN, or a cold/rebuild measure
        // (which can return a different height than the cheap path for the same
        // text). Either is a candidate wobble cause — surface loudly.
        let suspect = shrank || mPath == .coldDouble || dPath == .rebuild || coldDisagree
        if suspect {
            let why = [shrank ? "SHRANK" : nil,
                       mPath == .coldDouble ? "COLD" : nil,
                       coldDisagree ? "PASS-DISAGREE" : nil,
                       dPath == .rebuild ? "REBUILD" : nil].compactMap { $0 }.joined(separator: "+")
            Self.logger.error("""
            ⚠️\(why, privacy: .public) id=\(self.shortID(id), privacy: .public) Δ=\(delta, format: .fixed(precision: 1)) \
            h=\(height, format: .fixed(precision: 0)) prev=\(previousTiled, format: .fixed(precision: 0)) \
            w=\(width, format: .fixed(precision: 0)) measure=\(measureTag, privacy: .public)\(coldDetail, privacy: .public) \
            doc=\(docTag, privacy: .public) pin=\(pinned ? "Y" : "N", privacy: .public) glide=\(gliding ? "Y" : "N", privacy: .public) \
            src=\(source, privacy: .public) tick=\(stat.ticks)
            """)
        } else if stat.ticks % heartbeatEvery == 0 {
            // Sparse confirmation that growth is smooth (monotonic, cheap path).
            Self.logger.info("""
            ok id=\(self.shortID(id), privacy: .public) Δ=\(delta, format: .fixed(precision: 1)) \
            h=\(height, format: .fixed(precision: 0)) measure=\(measureTag, privacy: .public) tick=\(stat.ticks)
            """)
        }
        scheduleSummary(id: id)
    }

    // MARK: Glide side

    /// Record an auto-follow glide correction at the moment the glide believed it
    /// had landed. `trueGap` is `trueMaxY - origin` after the authoritative
    /// layout: > 0 means content grew under the glide (a normal chase), < 0 means
    /// the glide had scrolled PAST the true bottom and must pull back UP — that
    /// downward pull of fresh content is the glide-side wobble.
    func noteGlideLanding(trueGap: CGFloat, docHeight: CGFloat, clipHeight: CGFloat) {
        guard Self.isEnabled else { return }
        if trueGap < -0.5 {
            Self.logger.error("""
            ⚠️GLIDE-OVERSHOOT trueGap=\(trueGap, format: .fixed(precision: 1)) (scrolled past bottom, pulling up) \
            docH=\(docHeight, format: .fixed(precision: 0)) clipH=\(clipHeight, format: .fixed(precision: 0))
            """)
        } else if trueGap > 8 {
            // Big surprise jump at landing = the glide eased to a stale (too-short)
            // height for many frames, then snapped. Worth seeing; small gaps are
            // the normal streaming chase and stay silent.
            Self.logger.error("""
            ⚠️GLIDE-CHASE trueGap=\(trueGap, format: .fixed(precision: 1)) (eased to stale bottom, content had grown) \
            docH=\(docHeight, format: .fixed(precision: 0))
            """)
        }
    }

    // MARK: Summary

    /// Debounced: ~400ms after the last tile for a row, emit its verdict and
    /// forget it, so each streamed message produces exactly one summary line.
    private func scheduleSummary(id: String) {
        idleFlush[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSummary(id: id) }
        idleFlush[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushSummary(id: String) {
        idleFlush[id] = nil
        guard let s = rows.removeValue(forKey: id), s.ticks > 0 else { return }
        let smooth = s.shrinks == 0 && s.passDisagreements == 0 && s.rebuilds == 0
        let verdict = smooth ? "SMOOTH" : "WOBBLE"
        Self.logger.log("""
        ── \(verdict, privacy: .public) id=\(self.shortID(id), privacy: .public) ticks=\(s.ticks) \
        shrinks=\(s.shrinks)(maxDown=\(s.maxShrinkPx, format: .fixed(precision: 0))) \
        cold=\(s.coldMeasures) rebuilds=\(s.rebuilds) passDisagree=\(s.passDisagreements) \
        h=[\(s.minHeight == .greatestFiniteMagnitude ? 0 : s.minHeight, format: .fixed(precision: 0))..\(s.maxHeight, format: .fixed(precision: 0))]
        """)
    }
}
#endif
