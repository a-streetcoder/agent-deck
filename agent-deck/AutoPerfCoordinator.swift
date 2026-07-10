import AppKit
import Foundation

#if DEBUG
/// Autonomous performance collection mode for the perf-fix loop.
///
/// Launched with `AGENTDECK_AUTOPERF=1`, the app runs as an accessory
/// (no Dock icon, no menu bar, does not steal focus) with its main window moved
/// offscreen unless `AGENTDECK_AUTOPERF_VISIBLE=1` is set, then arms the built-in `ScrollBench` (sweeps sessions, short +
/// long top↔bottom scrolls), `STREAMSIM` (streams into the loaded transcript),
/// and `SIDEBAR_EXPANDBENCH` (toggles compact↔expanded session sidebar while
/// PiAgentTranscript remains visible) journeys — self-driven programmatically
/// against the REAL transcript, reproducing the layout/cell-vend/height-resolution hitches the HangWatchdog
/// auto-samples to `/tmp/agentdeck-hang-*.txt` while `TranscriptScrollProfiler`
/// writes per-gesture summaries to `/tmp/agentdeck-perf.txt`.
///
/// When the requested journeys finish it writes a rollup to
/// `/tmp/agentdeck-autoperf-rollup.md` and terminates, so the loop can invoke it
/// as a one-shot: `AGENTDECK_AUTOPERF=1 "Agent Deck.app/Contents/MacOS/Agent Deck"`.
/// Add `AGENTDECK_AUTOPERF_JOURNEY=scroll|stream|sidebar` to isolate one journey
/// per clean launch for comparable aggregate results.
///
/// Runs against the REAL data roots. The journeys are non-destructive (ScrollBench
/// only scrolls; STREAMSIM mutates in-memory entries and restores them), but the
/// app's normal launch still touches the shared session store/settings — so do
/// NOT run this concurrently with your live Agent Deck (shared session store).
/// The offscreen/accessory window reproduces the dominant layout/vend/sizing
/// hitches but may under-represent pure GPU/compositing hitches; user-felt
/// confirmation still comes from using the live app.
extension Notification.Name {
    static let sidebarExpandBenchShouldStart = Notification.Name("AgentDeckSidebarExpandBenchShouldStart")
}

/// The requested subset for one clean AutoPerf launch. Kept independent of the
/// process environment so the harness contract is deterministic and testable.
struct AutoPerfJourneySelection: Equatable {
    let scroll: Bool
    let stream: Bool
    let sidebar: Bool

    static func resolve(journey: String?, legacySidebarOnly: Bool) -> Self {
        switch journey?.lowercased() {
        case "scroll": return Self(scroll: true, stream: false, sidebar: false)
        case "stream": return Self(scroll: false, stream: true, sidebar: false)
        case "sidebar": return Self(scroll: false, stream: false, sidebar: true)
        default:
            return legacySidebarOnly
                ? Self(scroll: false, stream: false, sidebar: true)
                : Self(scroll: true, stream: true, sidebar: true)
        }
    }
}

final class AutoPerfCoordinator: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.environment["AGENTDECK_AUTOPERF"] != nil
    static let shared = AutoPerfCoordinator()

    private static let perfLogPath = "/tmp/agentdeck-perf.txt"
    private static let rollupPath = "/tmp/agentdeck-autoperf-rollup.md"
    private static let timeout: TimeInterval = 330      // ScrollBench(≤6 sessions) + STREAMSIM + SidebarExpandBench ≈ 3–4 min
    private static let hidePollInterval: TimeInterval = 0.05

    private let startedAt = CACurrentMediaTime()
    private var pollTimer: Timer?
    private var windowHiddenIDs = Set<NSWindow>()
    private var runScrollBench = true
    private var runStreamSim = true
    private var runSidebarExpandBench = true
    private var keepWindowVisible = false
    private var scrolledDone = false
    private var streamedDone = false
    private var sidebarExpandedDone = false
    private var finished = false
    private var runStartByteOffset: Int64 = 0

    private init() {}

    /// Called from `applicationDidFinishLaunching` when `AGENTDECK_AUTOPERF` is set.
    func start() {
        guard Self.enabled else { return }

        let env = ProcessInfo.processInfo.environment
        keepWindowVisible = env["AGENTDECK_AUTOPERF_VISIBLE"] != nil
        if !keepWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }

        // Enable the built-in benches for this run only. They are DEBUG-gated
        // inside PiAgentViews/ContentView, so a Release build is unaffected.
        let defaults = UserDefaults.standard
        // A clean AutoPerf launch can select exactly one journey, so aggregate
        // results never mix static scrolling, streaming, and sidebar work:
        // `AGENTDECK_AUTOPERF_JOURNEY=scroll|stream|sidebar`.
        // Keep the earlier sidebar-only flag as a compatibility alias.
        let selection = AutoPerfJourneySelection.resolve(
            journey: env["AGENTDECK_AUTOPERF_JOURNEY"],
            legacySidebarOnly: env["AGENTDECK_AUTOPERF_SIDEBAR_ONLY"] != nil || defaults.bool(forKey: "AutoPerfSidebarOnly")
        )
        runScrollBench = selection.scroll
        runStreamSim = selection.stream
        runSidebarExpandBench = selection.sidebar
        if runScrollBench { defaults.set(true, forKey: "ScrollBenchEnabled") }
        else { defaults.removeObject(forKey: "ScrollBenchEnabled") }
        if runStreamSim { defaults.set(true, forKey: "StreamSimEnabled") }
        else { defaults.removeObject(forKey: "StreamSimEnabled") }
        if runSidebarExpandBench {
            defaults.set(true, forKey: "SidebarExpandBenchEnabled")
            NotificationCenter.default.post(name: .sidebarExpandBenchShouldStart, object: nil)
        } else {
            defaults.removeObject(forKey: "SidebarExpandBenchEnabled")
        }

        // Snapshot the current perf-log size so the rollup reflects only this run,
        // and clear stale hang/hitch backtraces so they aren't double-counted.
        runStartByteOffset = currentPerfLogSize()
        clearBacktraces()

        TranscriptScrollProfiler.fileLog("AUTOPERF START scroll=\(runScrollBench) stream=\(runStreamSim) sidebarExpand=\(runSidebarExpandBench) visible=\(keepWindowVisible)")

        let timer = Timer(timeInterval: Self.hidePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        if !keepWindowVisible {
            hideWindowsOffscreen()
        }

        guard !finished else { return }
        let log = currentPerfLogSuffix()
        if log.contains("SCROLLBENCH COMPLETE") { scrolledDone = true }
        if log.contains("STREAMSIM COMPLETE") { streamedDone = true }
        if log.contains("SIDEBAR_EXPANDBENCH COMPLETE") { sidebarExpandedDone = true }
        if runSidebarExpandBench
            && !log.contains("SIDEBAR_EXPANDBENCH PREPARE")
            && !log.contains("SIDEBAR_EXPANDBENCH START_READY") {
            NotificationCenter.default.post(name: .sidebarExpandBenchShouldStart, object: nil)
        }

        let timedOut = CACurrentMediaTime() - startedAt > Self.timeout
        let allRequestedDone = (!runScrollBench || scrolledDone)
            && (!runStreamSim || streamedDone)
            && (!runSidebarExpandBench || sidebarExpandedDone)
        if allRequestedDone || timedOut {
            finish(timedOut: timedOut)
        }
    }

    /// Move every on-screen app window offscreen once, so it lays out + renders
    /// (benches need a real rendering transcript) but isn't visible while you work.
    private func hideWindowsOffscreen() {
        for window in NSApp.windows where window.isVisible && !windowHiddenIDs.contains(window) {
            // Keep it ordered in (so it stays key/main-able and content loads) but
            // parked far off the desktop.
            var frame = window.frame
            frame.origin = NSPoint(x: -40_000, y: -40_000)
            window.setFrame(frame, display: false)
            windowHiddenIDs.insert(window)
        }
    }

    private func finish(timedOut: Bool) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil

        // Restore defaults so a later normal launch never unexpectedly benches.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "ScrollBenchEnabled")
        defaults.removeObject(forKey: "StreamSimEnabled")
        defaults.removeObject(forKey: "SidebarExpandBenchEnabled")

        TranscriptScrollProfiler.fileLog("AUTOPERF COMPLETE scroll=\(scrolledDone) stream=\(streamedDone) sidebarExpand=\(sidebarExpandedDone) timedOut=\(timedOut)")
        // The rollup reads the perf artifact. Drain the ordered writer first so
        // its raw-log section includes every event emitted before completion.
        TranscriptScrollProfiler.flushFileLog { [weak self] in
            guard let self else { return }
            let rollup = self.buildRollup(timedOut: timedOut)
            do {
                try rollup.write(toFile: Self.rollupPath, atomically: true, encoding: .utf8)
                TranscriptScrollProfiler.fileLog("AUTOPERF ROLLUP \(Self.rollupPath)")
            } catch {
                TranscriptScrollProfiler.fileLog("AUTOPERF ROLLUP WRITE FAILED \(error.localizedDescription)")
            }

            // Give the final log lines a moment to flush, then quit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Perf-log parsing

    private func currentPerfLogSize() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.perfLogPath)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func currentPerfLogSuffix() -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: Self.perfLogPath)) else { return "" }
        defer { try? handle.close() }
        if runStartByteOffset > 0 {
            try? handle.seek(toOffset: UInt64(runStartByteOffset))
        }
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }

    private func clearBacktraces() {
        let tmp = FileManager.default.temporaryDirectory.path
        for prefix in ["/tmp/agentdeck-hang-", "/tmp/agentdeck-hitch-"] {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
                for name in names where name.hasPrefix("agentdeck-hang-") || name.hasPrefix("agentdeck-hitch-") {
                    try? FileManager.default.removeItem(atPath: "/tmp/\(name)")
                }
            }
            _ = tmp; _ = prefix
        }
    }

    private func buildRollup(timedOut: Bool) -> String {
        let log = currentPerfLogSuffix()
        var hangCount = 0, hitchCount = 0, hangMsTotal = 0, worstHitchMs = 0
        var perSceneHang: [String: Int] = [:]
        var perSceneHitch: [String: Int] = [:]

        func intBeforeMs(_ s: String, prefix: String) -> Int? {
            guard s.hasPrefix(prefix) else { return nil }
            let rest = s.dropFirst(prefix.count)
            var digits = ""
            for ch in rest {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            return Int(digits)
        }
        for line in log.split(separator: "\n") {
            let s = String(line)
            if let ms = intBeforeMs(s, prefix: "HANG ") {
                hangCount += 1; hangMsTotal += ms
                if let scene = sceneTag(in: s) { perSceneHang[scene, default: 0] += 1 }
            } else if let ms = intBeforeMs(s, prefix: "HITCH ") {
                hitchCount += 1; worstHitchMs = max(worstHitchMs, ms)
                if let scene = sceneTag(in: s) { perSceneHitch[scene, default: 0] += 1 }
            }
        }

        let hangFiles = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp"))?.filter {
            $0.hasPrefix("agentdeck-hang-")
        }.sorted() ?? []
        let hitchFiles = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp"))?.filter {
            $0.hasPrefix("agentdeck-hitch-")
        }.sorted() ?? []

        var out: [String] = []
        out.append("# Agent Deck AutoPerf Rollup")
        out.append("")
        out.append("- ScrollBench: \(runScrollBench ? (scrolledDone ? "completed" : "did not complete") : "skipped")")
        out.append("- STREAMSIM: \(runStreamSim ? (streamedDone ? "completed" : "did not complete") : "skipped")")
        out.append("- SidebarExpandBench: \(runSidebarExpandBench ? (sidebarExpandedDone ? "completed" : "did not complete") : "skipped")")
        out.append("- Timed out: \(timedOut)")
        out.append("")
        out.append("## Totals (this run)")
        out.append("- Hangs (>150ms): **\(hangCount)** (\(hangMsTotal)ms total)")
        out.append("- Hitches (33–150ms): **\(hitchCount)** — worst \(worstHitchMs)ms")
        out.append("")
        out.append("## By scene")
        let scenes = Set(perSceneHang.keys).union(perSceneHitch.keys).sorted()
        for scene in scenes {
            out.append("- \(scene): \(perSceneHang[scene] ?? 0) hangs, \(perSceneHitch[scene] ?? 0) hitches")
        }
        out.append("")
        out.append("## Hang backtraces (\(hangFiles.count))")
        for f in hangFiles { out.append("- /tmp/\(f)") }
        out.append("")
        out.append("## Hitch backtraces (\(hitchFiles.count))")
        for f in hitchFiles { out.append("- /tmp/\(f)") }
        out.append("")
        out.append("## Raw perf log (this run)")
        out.append("```")
        out.append(log.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("```")
        return out.joined(separator: "\n")
    }

    private func sceneTag(in line: String) -> String? {
        guard let range = line.range(of: "scene=") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
#endif
