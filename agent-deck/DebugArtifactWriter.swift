import Foundation

/// DEBUG-only ordered writer for performance-harness artifacts.
///
/// Perf instrumentation is often called from the main thread. Keep its `/tmp`
/// writes off that path while preserving log order and providing a drain seam for
/// consumers that immediately read the artifact (such as AutoPerf's rollup).
#if DEBUG
nonisolated final class DebugArtifactWriter: @unchecked Sendable {
    static let perfLog = DebugArtifactWriter(url: URL(fileURLWithPath: "/tmp/agentdeck-perf.txt"))

    private let url: URL
    private let queue: DispatchQueue

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "works.earendil.pi-deck.debug-artifact-writer", qos: .utility)
    }

    func append(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        queue.async { [url] in
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Calls `completion` on the main queue after every preceding append has
    /// finished, so a subsequent main-thread read observes the complete artifact.
    func flush(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            Task { @MainActor in completion() }
        }
    }
}
#endif
