import AppKit
import Foundation
import UniformTypeIdentifiers

/// Disk-backed user profile avatar used by transcript user bubbles.
@MainActor
enum UserAvatarStore {
    private static let fileManager = FileManager.default

    /// Application Support directory for the user profile avatar.
    static var profileDirectoryURL: URL {
        let root = URL.applicationSupportDirectory
            .appendingPathComponent("Agent Deck", isDirectory: true)
            .appendingPathComponent("User Profile", isDirectory: true)
        return root
    }

    /// Absolute URL for a stored avatar file name, if the file exists.
    ///
    /// - Parameter fileName: Relative file name from settings. Optional.
    /// - Returns: Existing file URL, or nil.
    static func imageURL(fileName: String?) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = profileDirectoryURL.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy a user-chosen image into the profile directory and return the stored file name.
    ///
    /// - Parameter sourceURL: Picked image file. Required.
    /// - Returns: Relative file name to persist in settings.
    static func importImage(from sourceURL: URL) throws -> String {
        try fileManager.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let fileName = "avatar-\(UUID().uuidString).\(ext)"
        let destination = profileDirectoryURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return fileName
    }

    /// Remove a previously stored avatar file if present.
    ///
    /// - Parameter fileName: Relative file name from settings. Optional.
    static func removeImage(fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        let url = profileDirectoryURL.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: url)
    }

    /// Load a displayable `NSImage` for the given file name.
    ///
    /// - Parameter fileName: Relative file name. Optional.
    /// - Returns: Image or nil.
    static func loadImage(fileName: String?) -> NSImage? {
        guard let url = imageURL(fileName: fileName) else { return nil }
        return NSImage(contentsOf: url)
    }
}
