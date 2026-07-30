import AppKit
import Foundation
import UniformTypeIdentifiers

/// Disk-backed user profile avatar used by transcript user bubbles.
@MainActor
enum UserAvatarStore {
    private static let fileManager = FileManager.default

    /// Exported avatar pixel edge length (square PNG).
    static let exportPixelSize: CGFloat = 256

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

    /// Persist a cropped square avatar as PNG and return the relative file name.
    ///
    /// - Parameter image: Square (or any) `NSImage` already cropped for display. Required.
    /// - Returns: Relative file name under the profile directory.
    /// - Throws: Write failures.
    static func saveCroppedImage(_ image: NSImage) throws -> String {
        try fileManager.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
        let edge = exportPixelSize
        let size = NSSize(width: edge, height: edge)
        let output = NSImage(size: size)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // Fill transparent then draw aspect-filled into the square.
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            output.unlockFocus()
            throw CocoaError(.fileWriteUnknown)
        }
        let scale = max(edge / srcSize.width, edge / srcSize.height)
        let drawW = srcSize.width * scale
        let drawH = srcSize.height * scale
        let drawRect = NSRect(
            x: (edge - drawW) / 2,
            y: (edge - drawH) / 2,
            width: drawW,
            height: drawH
        )
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = "avatar-\(UUID().uuidString).png"
        let destination = profileDirectoryURL.appendingPathComponent(fileName)
        try png.write(to: destination, options: .atomic)
        return fileName
    }

    /// Render a circular-crop region from `image` into a square bitmap.
    ///
    /// Crop is expressed in **view coordinates** relative to a square viewport of
    /// `viewportSize`, where the image is drawn with `scale` and `offset` (top-left
    /// of the image in view space, y-down). Output is a square `NSImage`.
    ///
    /// - Parameters:
    ///   - image: Source photo. Required.
    ///   - scale: Image display scale in the cropper (view pixels per image pixel unit).
    ///   - offset: Image origin in the square viewport (y-down). Required.
    ///   - viewportSize: Side length of the circular crop viewport. Required.
    /// - Returns: Square cropped `NSImage` of `exportPixelSize`.
    static func renderCrop(
        image: NSImage,
        scale: CGFloat,
        offset: CGSize,
        viewportSize: CGFloat
    ) -> NSImage? {
        guard scale > 0, viewportSize > 0 else { return nil }
        let edge = exportPixelSize
        let outSize = NSSize(width: edge, height: edge)
        let output = NSImage(size: outSize)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: outSize).fill()

        // Map viewport → export pixels.
        let unit = edge / viewportSize
        // Image rect in viewport coords (y-down): origin = offset, size = image.size * scale
        let imgW = image.size.width * scale
        let imgH = image.size.height * scale
        // In AppKit focus, y is up. Flip: viewY -> exportY from bottom.
        // view point (vx, vy) maps to export (vx * unit, (viewportSize - vy) * unit) for bottom-left of a 1px box —
        // for drawing the image: top-left of image in view is (offset.width, offset.height).
        let destX = offset.width * unit
        let destY = (viewportSize - offset.height - imgH) * unit
        let destRect = NSRect(x: destX, y: destY, width: imgW * unit, height: imgH * unit)
        image.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        output.unlockFocus()
        return output
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
