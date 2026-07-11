import Foundation
import QuartzCore
import os

/// Crash-proof main-thread hang detector + auto-profiler.
///
/// A background thread watches a main-thread heartbeat. When the main thread
/// stops beating for longer than `threshold` (i.e. it's hung mid-frame during a
/// janky scroll), the watchdog spawns the OS `/usr/bin/sample` tool **on this
/// process from the outside** and dumps the hung main thread's exact backtrace
/// to a file. Nothing in-process is suspended, walked, or signalled — so unlike
/// a hand-rolled stack sampler this cannot crash the app. The captured file
/// names the precise calculation that hung the frame.
///
/// On by default; disable with
///   `defaults write streetcoding.agent-deck HangWatchdogEnabled -bool NO`
/// Read the watchdog log live with:
///   log stream --predicate 'subsystem == "streetcoding.agent-deck" AND category == "HangWatchdog"' --info
/// Hang backtraces are written to `/tmp/agentdeck-hang-<n>.txt`.
nonisolated final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()
    static let logger = Logger(subsystem: "streetcoding.agent-deck", category: "HangWatchdog")

#if DEBUG
    /// Running tallies (main-thread heartbeat only writes these) so a harness can
    /// snapshot a delta over a window without parsing logs. `hitchCount` = frames
    /// 33-150ms; `hangMsTotal` = summed duration of full hangs (>150ms). DEBUG only.
    // Written only from the main-thread heartbeat timer, read from the main-thread
    // StreamSim — effectively main-thread-confined, so unchecked is safe here.
    nonisolated(unsafe) static var hitchCount = 0
    nonisolated(unsafe) static var hangCount = 0
    nonisolated(unsafe) static var hangMsTotal = 0
    nonisolated(unsafe) static var worstHitchMs = 0
    /// Per-scene hang counts let an in-app journey reject only stalls it owns,
    /// rather than unrelated launch/background work in the same process.
    nonisolated(unsafe) private static var hangCountsByScene: [String: Int] = [:]

    static func hangCount(forScene scene: String) -> Int {
        hangCountsByScene[scene, default: 0]
    }

    /// Mirror hang/hitch events to the shared ordered DEBUG artifact writer.
    /// The heartbeat must never synchronously append to disk.
    static func fileLog(_ line: String) {
        DebugArtifactWriter.perfLog.append(line: line)
    }
#endif

    private let lock = NSLock()
    private var lastBeat: CFTimeInterval = 0
    private var mainTimer: Timer?
    private var bgTimer: DispatchSourceTimer?
    private var sampling = false
    private var sampleIndex = 0
    private var hangActive = false
    private var hangStartBeat: CFTimeInterval = 0

    // MARK: Hitch capture (scroll jank that never reaches the hang threshold)
    private var hitchSampling = false
    private var hitchIndex = 0
    private var lastHitchCapture: CFTimeInterval = 0
    /// Throttle: at most one hitch backtrace this often, so a sustained-jank
    /// scroll produces a handful of captures, not hundreds.
    private let hitchThrottle: CFTimeInterval = 3
    /// `sample` only accepts whole seconds; 1s during a stuttering scroll still
    /// lands dozens of samples on the hot stack.
    private let hitchSampleSeconds = 1

    /// A frame longer than this (ms) counts as a hang worth capturing. 60fps is
    /// 16.7ms; 150ms is ~9 dropped frames — a clear stall, not normal churn.
    /// Override with `defaults write streetcoding.agent-deck HangWatchdogThresholdMs -int 50`.
    private var threshold: CFTimeInterval = 0.15
    /// How long `sample` profiles once a hang is detected.
    private let sampleSeconds = 2
    /// A main-thread gap above this (but below the hang threshold) is a "hitch" —
    /// a dropped-frame stutter, logged app-wide with the active scene. ~33ms ≈ two
    /// dropped 60fps frames. Override with `HangWatchdogHitchMs`.
    private var hitchThreshold: CFTimeInterval = 0.033
    /// Hitches at/above this also fire a throttled external `sample` (sustained
    /// jank), reusing `captureHitch`.
    private var hitchCaptureThreshold: CFTimeInterval = 0.045
    /// The active scene tag, snapshotted from `PerfScene.current` on the heartbeat
    /// so the background watcher can read it without touching main-thread state.
    private var scene: String = "app"

    /// Start the app-wide hang + hitch monitor. DEBUG builds only — in release this
    /// is a no-op so no heartbeat runs, no `sample` is spawned, and nothing logs.
    func start() {
#if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "HangWatchdogEnabled") != nil,
           defaults.bool(forKey: "HangWatchdogEnabled") == false {
            return
        }
        if let override = defaults.object(forKey: "HangWatchdogThresholdMs") as? NSNumber,
           override.doubleValue >= 16 {
            threshold = override.doubleValue / 1000
        }
        if let override = defaults.object(forKey: "HangWatchdogHitchMs") as? NSNumber,
           override.doubleValue >= 16 {
            hitchThreshold = override.doubleValue / 1000
        }
        lastBeat = CACurrentMediaTime()

        // Heartbeat on the main runloop at ~60Hz — stops the instant the main
        // thread hangs. On each beat, the gap to the previous beat reveals a hang
        // that just ended OR a hitch (a brief stutter), attributed to the scene.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.lock.lock()
            let gap = now - self.lastBeat
            self.lastBeat = now
            self.scene = PerfScene.current
            let endedHang = self.hangActive ? (now - self.hangStartBeat) : nil
            if self.hangActive { self.hangActive = false }
            let scene = self.scene
            self.lock.unlock()

            if let hung = endedHang {
                Self.logger.error("HANG ENDED — main thread blocked ~\(Int(hung * 1000))ms · scene=\(scene, privacy: .public)")
                Self.fileLog("HANG \(Int(hung * 1000))ms scene=\(scene)")
                Self.hangCount += 1
                Self.hangMsTotal += Int(hung * 1000)
                Self.hangCountsByScene[scene, default: 0] += 1
            } else if gap > self.hitchThreshold && gap < self.threshold {
                Self.logger.error("HITCH Δ=\(Int(gap * 1000))ms · scene=\(scene, privacy: .public)")
                Self.fileLog("HITCH \(Int(gap * 1000))ms scene=\(scene)")
                Self.hitchCount += 1
                Self.worstHitchMs = max(Self.worstHitchMs, Int(gap * 1000))
                if gap >= self.hitchCaptureThreshold { self.captureHitch(gapMs: Int(gap * 1000)) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        mainTimer = t

        // Background watcher — catches a hang *while it's still happening* so the
        // external sampler grabs the blocked stack.
        let q = DispatchQueue(label: "streetcoding.agent-deck.hangwatchdog", qos: .userInitiated)
        let bg = DispatchSource.makeTimerSource(queue: q)
        bg.schedule(deadline: .now() + 0.1, repeating: 1.0 / 120.0)
        bg.setEventHandler { [weak self] in self?.check() }
        bg.resume()
        bgTimer = bg

        Self.logger.info("HangWatchdog started (hang \(Int(self.threshold * 1000))ms · hitch \(Int(self.hitchThreshold * 1000))ms)")
#endif
    }

    private func check() {
        let now = CACurrentMediaTime()
        lock.lock()
        let gap = now - lastBeat
        if gap <= threshold { lock.unlock(); return }
        if !hangActive { hangActive = true; hangStartBeat = lastBeat }
        if sampling { lock.unlock(); return }   // already capturing this stall
        sampling = true
        sampleIndex += 1
        let index = sampleIndex
        let scene = self.scene
        lock.unlock()
        captureSample(index: index, blockedMs: Int(gap * 1000), scene: scene)
    }

    private func captureSample(index: Int, blockedMs: Int, scene: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = "/tmp/agentdeck-hang-\(index).txt"
        Self.logger.error("HANG detected (~\(blockedMs)ms blocked) · scene=\(scene, privacy: .public) — capturing main-thread backtrace → \(path, privacy: .public)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        proc.arguments = ["\(pid)", "\(sampleSeconds)", "-file", path, "-mayDie"]
        proc.standardOutput = nil
        proc.standardError = nil
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.sampling = false; self.lock.unlock()
            Self.logger.error("HANG sample #\(index) ready → \(path, privacy: .public)")
        }
        do {
            try proc.run()
        } catch {
            lock.lock(); sampling = false; lock.unlock()
            Self.logger.error("HANG sample spawn failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Capture a short, throttled backtrace for a *hitch* — a dropped scroll
    /// frame that's too brief to trip the hang threshold but is exactly the
    /// sustained "feels slow" jank we're hunting. Called from the scroll
    /// profiler when a frame gap exceeds its backtrace threshold. Crash-proof
    /// for the same reason as the hang path: it shells out to `/usr/bin/sample`
    /// rather than walking the stack in-process. Writes `/tmp/agentdeck-hitch-<n>.txt`.
    func captureHitch(gapMs: Int) {
        let now = CACurrentMediaTime()
        lock.lock()
        if hitchSampling || now - lastHitchCapture < hitchThrottle { lock.unlock(); return }
        hitchSampling = true
        lastHitchCapture = now
        hitchIndex += 1
        let index = hitchIndex
        lock.unlock()

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = "/tmp/agentdeck-hitch-\(index).txt"
        Self.logger.error("HITCH (~\(gapMs)ms dropped frame) — sampling hot stack → \(path, privacy: .public)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // Fine sampling interval (1ms) so a 1s window over a stuttering scroll
        // still resolves the dominant frame-blocking call.
        proc.arguments = ["\(pid)", "\(hitchSampleSeconds)", "1", "-file", path, "-mayDie"]
        proc.standardOutput = nil
        proc.standardError = nil
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.hitchSampling = false; self.lock.unlock()
            Self.logger.error("HITCH sample #\(index) ready → \(path, privacy: .public)")
        }
        do {
            try proc.run()
        } catch {
            lock.lock(); hitchSampling = false; lock.unlock()
            Self.logger.error("HITCH sample spawn failed: \(String(describing: error), privacy: .public)")
        }
    }
}
