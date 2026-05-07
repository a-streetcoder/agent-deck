import AppKit
import SwiftUI


extension Array where Element == String {
    var nonEmptyJoined: String {
        isEmpty ? "—" : joined(separator: ", ")
    }
}

extension Optional where Wrapped == String {
    nonisolated var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

extension String {
    nonisolated var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
