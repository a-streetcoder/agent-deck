import Foundation

enum SlashCommandCatalog {
    nonisolated static func normalizePackageReference(_ reference: String) -> String {
        if let value = reference.split(separator: "/").last, reference.hasPrefix("/") {
            return String(value)
        }
        if reference.hasPrefix("npm:") {
            return String(reference.dropFirst(4))
        }
        return reference
    }
}
