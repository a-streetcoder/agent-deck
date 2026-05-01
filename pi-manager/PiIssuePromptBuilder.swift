import Foundation

enum PiIssuePromptBuilder {
    static func projectPrompt(project: DiscoveredProject, initialInstruction: String) -> String {
        let instruction = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are working inside this local repository:
        \(project.path)

        Project: \(project.name)
        \(project.gitHubRemote.map { "GitHub repository: \($0.nameWithOwner)" } ?? "")

        Task:
        \(instruction.isEmpty ? "Help with this project. First inspect the repo and ask what to do next if the task is unclear." : instruction)

        Important rules:
        - Respect the existing architecture, code style, and native macOS design system.
        - Keep changes focused and maintainable.
        - Do not commit, push, or close GitHub issues unless I explicitly ask.
        - When done, summarize changed files, validation performed, and any follow-up needed.
        """
    }

    static func issuePrompt(detail: GitHubIssueDetail, project: DiscoveredProject) -> String {
        var sections: [String] = []
        sections.append("""
        I want to work on this GitHub issue in the current repository.

        Repository: \(detail.item.repository)
        Issue: #\(detail.item.number)
        Title: \(detail.item.title)
        State: \(detail.state)
        URL: \(detail.item.url.absoluteString)
        """)

        if !detail.labels.isEmpty {
            sections.append("Labels: \(detail.labels.joined(separator: ", "))")
        }
        if !detail.assignees.isEmpty {
            sections.append("Assignees: \(detail.assignees.joined(separator: ", "))")
        }
        if let author = detail.author {
            sections.append("Author: \(author)")
        }
        if !detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("""
            Issue description:
            \(detail.body)
            """)
        }

        let relationships = relationshipLines(detail)
        if !relationships.isEmpty {
            sections.append("""
            Relationships:
            \(relationships.joined(separator: "\n"))
            """)
        }

        if !detail.comments.isEmpty {
            let comments = detail.comments.suffix(8).map { comment in
                "- \(comment.author) at \(comment.updatedAt.formatted(date: .abbreviated, time: .shortened)):\n\(comment.body)"
            }.joined(separator: "\n\n")
            sections.append("""
            Recent comments:
            \(comments)
            """)
        }

        sections.append("""
        Please inspect the repository, implement the issue, run appropriate checks if available, and summarize the changes.
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func relationshipLines(_ detail: GitHubIssueDetail) -> [String] {
        var lines: [String] = []
        if let parent = detail.parent {
            lines.append("- Parent: \(parent.repository)#\(parent.number) \(parent.title)")
        }
        lines.append(contentsOf: detail.subIssues.map { "- Sub-issue: \($0.repository)#\($0.number) \($0.title)" })
        lines.append(contentsOf: detail.blockedBy.map { "- Blocked by: \($0.repository)#\($0.number) \($0.title)" })
        lines.append(contentsOf: detail.blocking.map { "- Blocking: \($0.repository)#\($0.number) \($0.title)" })
        return lines
    }
}
