import Foundation

/// Parsing of the leading `--- … ---` YAML-ish frontmatter block of a `SKILL.md`.
///
/// Shared by `ExternalSkillDiscovery` (which reads the head of an on-disk file)
/// and `SkillRepositorySyncService` (which parses the output of `git show`).
/// Pure, `nonisolated`, no main-actor coupling.
nonisolated enum SkillFrontmatter {

    /// Parse a leading `--- … ---` frontmatter block into key/value pairs.
    /// Returns an empty dictionary when no frontmatter block is present.
    static func parse(_ text: String) -> [String: String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return [:] }
        let remainder = String(normalized.dropFirst(4))
        guard let closingRange = remainder.range(of: "\n---\n")
            ?? (remainder.hasSuffix("\n---") ? remainder.range(of: "\n---", options: .backwards) : nil)
        else { return [:] }
        let frontmatterText = remainder[..<closingRange.lowerBound]

        var values: [String: String] = [:]
        for rawLine in frontmatterText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[String(key)] = String(value)
            }
        }
        return values
    }

    /// Read only the head of `url` and parse its frontmatter block. Returns
    /// `nil` when the file cannot be read (e.g. it does not exist).
    ///
    /// Frontmatter always sits at the very top of the file, so a bounded read
    /// avoids pulling large skill bodies into memory just for two fields.
    static func fields(atTopOf url: URL, byteLimit: Int = 64 * 1024) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteLimit)) ?? Data()
        guard let text = decodeUTF8Prefix(data) else { return nil }
        return parse(text)
    }

    /// Decode a possibly-truncated UTF-8 byte prefix. A bounded read can slice
    /// through a multi-byte character; dropping up to three trailing bytes
    /// recovers a valid string (a UTF-8 scalar is at most four bytes).
    static func decodeUTF8Prefix(_ data: Data) -> String? {
        for trailingBytesToDrop in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(trailingBytesToDrop), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// Resolve a skill's display name and description from parsed frontmatter,
    /// falling back to the skill folder name when `name` is absent.
    static func nameAndDescription(
        fromFrontmatter frontmatter: [String: String],
        fallbackName: String
    ) -> (name: String, description: String?) {
        let parsedName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedDescription = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (parsedName?.isEmpty == false) ? parsedName! : fallbackName
        let description = (parsedDescription?.isEmpty == false) ? parsedDescription : nil
        return (name, description)
    }
}
