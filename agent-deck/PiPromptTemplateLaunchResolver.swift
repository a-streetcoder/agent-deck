import Foundation

nonisolated enum PiPromptTemplateLaunchResolver {
    struct DuplicatePromptError: LocalizedError, Equatable {
        let name: String
        let paths: [String]

        var errorDescription: String? {
            "Duplicate prompt template name `/\(name)` found at: \(paths.joined(separator: ", ")). Rename one of the prompt templates before launching."
        }
    }

    struct MissingPromptError: LocalizedError, Equatable {
        let name: String

        var errorDescription: String? {
            "Prompt template `/\(name)` is assigned but was not found in the prompt catalog."
        }
    }

    struct Collision: Identifiable, Hashable {
        let name: String
        let prompts: [PromptTemplateRecord]

        var id: String { name }
    }

    static func promptTemplateArguments(for names: some Sequence<String>, catalog: [PromptTemplateRecord]) throws -> [String] {
        let resolved = try resolve(names: normalizedNames(names), catalog: catalog)
        return resolved.flatMap { ["--prompt-template", $0.filePath] }
    }

    static func normalizedNames(_ names: some Sequence<String>) -> [String] {
        Array(Set(names.map { normalizedName($0) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func collisions(in catalog: [PromptTemplateRecord]) -> [Collision] {
        Dictionary(grouping: catalog, by: { normalizedName($0.name) })
            .compactMap { name, prompts in
                let uniqueByPath = unique(prompts)
                guard !name.isEmpty, uniqueByPath.count > 1 else { return nil }
                return Collision(name: name, prompts: uniqueByPath.sorted { $0.filePath < $1.filePath })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func resolve(names: [String], catalog: [PromptTemplateRecord]) throws -> [PromptTemplateRecord] {
        let grouped = Dictionary(grouping: unique(catalog), by: { normalizedName($0.name) })
        return try names.map { name in
            let matches = grouped[name] ?? []
            if matches.isEmpty { throw MissingPromptError(name: name) }
            if matches.count > 1 { throw DuplicatePromptError(name: name, paths: matches.map(\.filePath).sorted()) }
            return matches[0]
        }
    }

    private static func normalizedName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        if trimmed.hasSuffix(".md") { trimmed.removeLast(3) }
        return trimmed
    }

    private static func unique(_ prompts: [PromptTemplateRecord]) -> [PromptTemplateRecord] {
        var seen = Set<String>()
        return prompts.filter { seen.insert($0.filePath).inserted }
    }
}
