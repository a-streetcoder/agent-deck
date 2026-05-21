import AppKit
import Combine
import Foundation

@MainActor
final class AgentImageStore: ObservableObject {
    @Published private(set) var assignments: [String: String] = [:]

    private let fileManager: FileManager
    private let assignmentsURL: URL
    private let imagesDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = appSupport.appendingPathComponent("Agent Deck", isDirectory: true)
        self.imagesDirectory = root.appendingPathComponent("Agent Images", isDirectory: true)
        self.assignmentsURL = root.appendingPathComponent("agent-image-assignments.json")
        self.assignments = Self.loadAssignments(from: assignmentsURL)
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

    private static func loadAssignments(from url: URL) -> [String: String] {
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

    private struct Envelope: Codable {
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

struct AgentImageLoader {
    /// Disk-loaded agent images, keyed by URL. `AgentImageStore` names every
    /// saved image with a fresh UUID and deletes the old file on reassignment,
    /// so a URL maps to immutable content — this cache never goes stale.
    /// Without it `image(at:)` ran `NSImage(contentsOf:)` (a disk read + decode)
    /// on every SwiftUI body eval that displays an agent avatar. `NSCache` is
    /// thread-safe and evicts under memory pressure.
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func image(at url: URL?, bundledImageName: String? = nil) -> NSImage? {
        if let url {
            if let cached = cache.object(forKey: url as NSURL) { return cached }
            if let image = NSImage(contentsOf: url) {
                cache.setObject(image, forKey: url as NSURL)
                return image
            }
        }
        // Bundled (asset-catalog) images are already cached by AppKit.
        if let bundledImageName { return NSImage(named: bundledImageName) }
        return nil
    }
}
