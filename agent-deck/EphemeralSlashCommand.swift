import Foundation

/// Policy for whether a composer turn should be omitted from Deck transcript/disk.
///
/// Pure extension slash commands (`/blackhole-memory status`) are ephemeral UI
/// control surface; skill invocations (`/skill:…`) and free text remain history.
nonisolated enum EphemeralSlashCommand {
    /**
     Returns whether Deck should omit the user bubble from transcript persistence.

     - Parameters:
       - text: Visible or RPC message text. Required.
       - hasAttachments: `true` when images or paste blobs are present. Required.
     - Returns: `true` when every non-empty line is a non-skill slash command and
       there are no attachments.
     */
    static func shouldOmitFromTranscript(text: String, hasAttachments: Bool) -> Bool {
        guard !hasAttachments else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard line.hasPrefix("/") else { return false }
            if line.lowercased().hasPrefix("/skill:") { return false }
            return true
        }
    }
}
