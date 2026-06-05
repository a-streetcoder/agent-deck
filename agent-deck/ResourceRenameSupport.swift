import SwiftUI

struct ResourceRenamePreview: Hashable {
    let oldName: String
    let newName: String
    var changes: [String]
    var warnings: [String]
    var blockers: [String]

    var canApply: Bool { blockers.isEmpty && oldName != newName }
}

enum ResourceRenameError: LocalizedError, Equatable {
    case unsupportedResource(String)
    case invalidName(String)
    case destinationExists(String)
    case duplicateName(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedResource(message): return message
        case let .invalidName(message): return message
        case let .destinationExists(path): return "A file or folder already exists at \(path)."
        case let .duplicateName(name): return "Another resource already uses the name `\(name)`."
        case let .unsafePath(path): return "Refusing to rename an unsafe path: \(path)"
        }
    }
}

enum ResourceRenameSupport {
    static func normalizedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ResourceRenameError.invalidName("Name cannot be empty.")
        }
        guard name != ".", name != ".." else {
            throw ResourceRenameError.invalidName("Name cannot be `.` or `..`.")
        }
        let forbiddenCharacters = CharacterSet(charactersIn: "/\\:\n\r")
        guard name.rangeOfCharacter(from: forbiddenCharacters) == nil else {
            throw ResourceRenameError.invalidName("Name cannot contain slashes, colons, or line breaks.")
        }
        guard !name.contains("..") else {
            throw ResourceRenameError.invalidName("Name cannot contain `..`.")
        }
        return name
    }

    static func preview(oldName: String, requestedName: String, changes: [String], warnings: [String] = [], blockers: [String] = []) -> ResourceRenamePreview {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ResourceRenamePreview(oldName: oldName, newName: trimmed, changes: changes, warnings: warnings, blockers: blockers)
    }

    static func destinationURL(for sourceURL: URL, newName: String, replacingContainerForSkillFile: Bool = false) -> URL {
        if replacingContainerForSkillFile, sourceURL.lastPathComponent == "SKILL.md" {
            return sourceURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        }
        return sourceURL.deletingLastPathComponent().appendingPathComponent(newName).appendingPathExtension(sourceURL.pathExtension)
    }

    static func replacingFrontmatterValue(in text: String, key: String, value: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let escapedValue = value
        guard normalized.hasPrefix("---") else {
            return "---\n\(key): \(escapedValue)\n---\n\n\(normalized.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }

        let startIndex = normalized.index(normalized.startIndex, offsetBy: 3)
        guard let closingRange = normalized.range(of: "\n---", range: startIndex..<normalized.endIndex) else {
            return "---\n\(key): \(escapedValue)\n---\n\n\(normalized.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }

        let frontmatterStart = normalized.index(after: startIndex)
        let frontmatterText = String(normalized[frontmatterStart..<closingRange.lowerBound])
        let bodyStart = normalized.index(closingRange.lowerBound, offsetBy: 4)
        let body = String(normalized[bodyStart...])
        var replaced = false
        var lines = frontmatterText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            let line = lines[index]
            guard let separator = line.firstIndex(of: ":") else { continue }
            let lineKey = line[..<separator].trimmingCharacters(in: .whitespaces)
            if lineKey == key {
                lines[index] = "\(key): \(escapedValue)"
                replaced = true
                break
            }
        }
        if !replaced {
            lines.insert("\(key): \(escapedValue)", at: 0)
        }
        return "---\n\(lines.joined(separator: "\n"))\n---\(body)"
    }
}

struct RenameResourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let currentName: String
    let resourceLabel: String
    let makePreview: (String) -> ResourceRenamePreview
    let onRename: (String) throws -> Void

    @State private var newName: String
    @State private var preview: ResourceRenamePreview
    @State private var errorMessage: String?

    init(title: String, currentName: String, resourceLabel: String, makePreview: @escaping (String) -> ResourceRenamePreview, onRename: @escaping (String) throws -> Void) {
        self.title = title
        self.currentName = currentName
        self.resourceLabel = resourceLabel
        self.makePreview = makePreview
        self.onRename = onRename
        let initialPreview = makePreview(currentName)
        _newName = State(initialValue: currentName)
        _preview = State(initialValue: initialPreview)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
                .fontWidth(.expanded)

            AppTextField(text: $newName, placeholder: "New name")
                .onChange(of: newName) { _, value in
                    preview = makePreview(value)
                    errorMessage = nil
                }

            VStack(alignment: .leading, spacing: 10) {
                Text("Impact")
                    .font(.headline)
                if preview.changes.isEmpty {
                    Text(newName == currentName ? "Enter a different name to preview changes." : "No file or reference changes detected.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    ForEach(preview.changes, id: \.self) { change in
                        Label(change, systemImage: "checkmark.circle")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }

                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                ForEach(preview.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .appSecondaryButton()
                Button("Rename") {
                    do {
                        try onRename(newName)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                        preview = makePreview(newName)
                    }
                }
                .appPrimaryButton()
                .disabled(!preview.canApply)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}
