import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

@MainActor
final class AgentImageStore: ObservableObject {
    @Published private(set) var assignments: [String: String] = [:]

    private let fileManager: FileManager
    private let assignmentsURL: URL
    private let imagesDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = URL.applicationSupportDirectory
        let root = appSupport.appendingPathComponent("Agent Deck", isDirectory: true)
        self.imagesDirectory = root.appendingPathComponent("Agent Images", isDirectory: true)
        self.assignmentsURL = root.appendingPathComponent("agent-image-assignments.json")
        // Async load so AppViewModel.init returns immediately. Views see an
        // empty `assignments` for one frame, then the avatar mappings animate
        // in via @Published. Same pattern as AgentMemoryStore (audit-02 P0-1)
        // and PiAgentSessionStore (audit-02 P0-2).
        let url = self.assignmentsURL
        Task { @MainActor [weak self] in
            let loaded = await Self.loadAssignmentsAsync(from: url)
            guard let self else { return }
            self.assignments = loaded
            self.prewarmImageCache()
        }
    }

    nonisolated private static func loadAssignmentsAsync(from url: URL) async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            Self.loadAssignments(from: url)
        }.value
    }

    /// Decodes every already-assigned avatar into `AgentImageLoader`'s cache on
    /// a background task, so avatars are cache hits by the time any view shows
    /// them — no blocking disk decode on the main thread. No visible change:
    /// an uncached lookup still works, it just decodes once inline.
    private func prewarmImageCache() {
        let urls = assignments.values.map { imagesDirectory.appendingPathComponent($0) }
        guard !urls.isEmpty else { return }
        // `.background` + a yield per image (see `prewarm`): this is a pure
        // optimization (pre-decode so the first display is a cache hit), so it must
        // never compete with the UI. Run at higher QoS as one tight loop it
        // saturated a core and contributed to a launch-time scroll hang.
        Task.detached(priority: .background) {
            await AgentImageLoader.prewarm(urls: urls)
        }
    }

    func imageURL(for agentName: String) -> URL? {
        guard let fileName = assignments[Self.key(forAgentName: agentName)] else { return nil }
        let url = imagesDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func assignGeneratedImage(from sourceURL: URL, to agentName: String) throws {
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let extensionName = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let fileName = "\(UUID().uuidString).\(extensionName)"
        let destination = imagesDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try assignImageFile(named: fileName, to: agentName)
    }

    func assignGeneratedImage(_ cgImage: CGImage, to agentName: String) throws {
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).png"
        let destination = imagesDirectory.appendingPathComponent(fileName)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: destination, options: .atomic)
        try assignImageFile(named: fileName, to: agentName)
    }

    private func assignImageFile(named fileName: String, to agentName: String) throws {
        let key = Self.key(forAgentName: agentName)
        if let oldFileName = assignments[key], oldFileName != fileName {
            try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(oldFileName))
        }
        assignments[key] = fileName
        try saveAssignments()
    }

    func removeImage(for agentName: String) throws {
        let key = Self.key(forAgentName: agentName)
        guard let fileName = assignments.removeValue(forKey: key) else { return }
        try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(fileName))
        try saveAssignments()
    }

    private static func key(forAgentName agentName: String) -> String {
        "agent-name:\(agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    nonisolated private static func loadAssignments(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [:] }
        return envelope.assignments
    }

    private func saveAssignments() throws {
        try fileManager.createDirectory(at: assignmentsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(Envelope(assignments: assignments))
        try data.write(to: assignmentsURL, options: .atomic)
    }

    nonisolated private struct Envelope: Codable, Sendable {
        var assignments: [String: String]
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct TranscriptImageLoader {
    private nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    nonisolated static func image(at url: URL?, maxPixelSize: Int) -> NSImage? {
        guard let url else { return nil }
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = decodeImage(at: url, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated static func previewImage(at url: URL?) -> NSImage? {
        // Popovers can be ~760pt wide on Retina displays, so keep substantially
        // more pixels than the thumbnail path without decoding unbounded originals.
        image(at: url, maxPixelSize: 2400)
    }

    nonisolated static func thumbnailImage(at url: URL?) -> NSImage? {
        image(at: url, maxPixelSize: 512)
    }

    nonisolated private static func decodeImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return NSImage(contentsOf: url)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct AgentImageLoader {
    /// Disk-loaded agent images, keyed by URL. `AgentImageStore` names every
    /// saved image with a fresh UUID and deletes the old file on reassignment,
    /// so a URL maps to immutable content — this cache never goes stale.
    /// Without it `image(at:)` ran `NSImage(contentsOf:)` (a disk read + decode)
    /// on every SwiftUI body eval that displays an agent avatar. `NSCache` is
    /// thread-safe and evicts under memory pressure.
    private nonisolated(unsafe) static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Decodes `urls` and inserts them into the cache off the main thread, so
    /// the first `image(at:)` for each avatar is a cache hit instead of a
    /// blocking disk read + decode. Safe to call from any thread — `NSCache`
    /// is thread-safe, and a concurrent `image(at:)` miss simply decodes once.
    nonisolated static func prewarm(urls: [URL]) async {
        for url in urls {
            let key = url as NSURL
            guard cache.object(forKey: key) == nil else { continue }
            if let image = downsampledImage(at: url) {
                cache.setObject(image, forKey: key)
            }
            // Cooperative break between decodes so a long prewarm can't monopolize
            // a core — the scheduler can interleave higher-priority work.
            await Task.yield()
        }
    }

    static func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let image = downsampledImage(at: url) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        return nil
    }

    /// Avatars render at most ~64pt; decode a 192px thumbnail rather than caching the
    /// full-resolution source (often 512-1024px). Scrolling the agent list re-renders
    /// each avatar, and downscaling a huge cached image per row was the list's main
    /// scroll cost — a small thumbnail is crisp at every avatar size and far lighter.
    nonisolated private static let maxPixelSize = 192

    /// On-disk store of already-downsampled 192px thumbnails. Agent avatars are
    /// immutable per URL (UUID-named, see `cache` above), so a thumbnail decoded
    /// once can be reloaded on every later launch instead of re-running a
    /// CGImageSource thumbnail pass over the full 512-1024px source — the decode
    /// that showed up as a launch-time CPU storm in prewarm. Reads are inline
    /// (loading a tiny pre-sized PNG is cheaper than today's full-source decode);
    /// the write is dispatched off-thread so it never lands on a caller's path.
    nonisolated private static let thumbnailCacheDirectory: URL? = {
        let fileManager = FileManager.default
        guard let caches = try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = caches.appendingPathComponent("AgentAvatarThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    nonisolated private static func thumbnailCacheURL(for sourceURL: URL) -> URL? {
        guard let directory = thumbnailCacheDirectory else { return nil }
        // Stable across launches (unlike `Hasher`, which is seeded per-process).
        let digest = SHA256.hash(data: Data(sourceURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }

    nonisolated private static func writeThumbnail(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    nonisolated private static func downsampledImage(at url: URL) -> NSImage? {
        if let cacheURL = thumbnailCacheURL(for: url),
           let cached = NSImage(contentsOf: cacheURL) {
            return cached
        }
        guard let image = decodeDownsampledImage(at: url) else { return nil }
        if let cacheURL = thumbnailCacheURL(for: url) {
            DispatchQueue.global(qos: .utility).async { writeThumbnail(image, to: cacheURL) }
        }
        return image
    }

    nonisolated private static func decodeDownsampledImage(at url: URL) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return NSImage(contentsOf: url)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
