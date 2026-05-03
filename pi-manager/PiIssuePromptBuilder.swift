import Foundation

enum PiIssuePromptBuilder {
    static func projectPrompt(project: DiscoveredProject, initialInstruction: String) -> String {
        initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func issuePrompt(detail: GitHubIssueDetail, project: DiscoveredProject) -> String {
        var prompt = """
        Work on GitHub issue #\(detail.item.number): \(detail.item.title)
        \(detail.item.url.absoluteString)
        """

        let body = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            prompt += "\n\n\(body)"
        }

        let relationships = relationshipLines(detail)
        if !relationships.isEmpty {
            prompt += "\n\nRelationships:\n\(relationships.joined(separator: "\n"))"
        }

        let recentComments = detail.comments.suffix(3).map { comment in
            "- \(comment.author): \(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if !recentComments.isEmpty {
            prompt += "\n\nRecent comments:\n\(recentComments.joined(separator: "\n\n"))"
        }

        return prompt
    }

    private static func relationshipLines(_ detail: GitHubIssueDetail) -> [String] {
        [
            detail.parent.map { "- Parent: \($0.repository)#\($0.number) \($0.title)" },
            detail.subIssues.map { "- Sub-issue: \($0.repository)#\($0.number) \($0.title)" }.joinedOrNil(),
            detail.blockedBy.map { "- Blocked by: \($0.repository)#\($0.number) \($0.title)" }.joinedOrNil(),
            detail.blocking.map { "- Blocking: \($0.repository)#\($0.number) \($0.title)" }.joinedOrNil()
        ]
        .compactMap { $0 }
    }
}

private extension Array where Element == String {
    func joinedOrNil() -> String? {
        isEmpty ? nil : joined(separator: "\n")
    }
}
