import Foundation

struct GitHubIssueService {
    private let apiClient: GitHubAPIClient

    init(apiClient: GitHubAPIClient) {
        self.apiClient = apiClient
    }

    func fetchDetail(for item: GitHubWorkItem) async throws -> GitHubIssueDetail {
        let repo = try parseRepository(item.repository)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        async let issueTask = apiClient.get(
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)",
            queryItems: []
        )
        async let commentsTask = apiClient.get(
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)/comments",
            queryItems: []
        )
        async let parentTask: GitHubIssueReference? = fetchOptionalReference(
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)/parent",
            decoder: decoder
        )
        async let subIssuesTask = fetchReferences(
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)/sub_issues",
            decoder: decoder
        )
        async let blockedByTask = fetchReferences(
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)/dependencies/blocked_by",
            decoder: decoder
        )
        async let blockingTask = fetchReferences(
            path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)/dependencies/blocking",
            decoder: decoder
        )

        let (issueData, _) = try await issueTask
        let issue = try decoder.decode(GitHubIssuePayload.self, from: issueData)

        let (commentsData, _) = try await commentsTask
        let comments = try decoder.decode([GitHubCommentPayload].self, from: commentsData)

        return GitHubIssueDetail(
            item: item,
            body: issue.body ?? "",
            state: issue.state,
            stateReason: issue.stateReason,
            type: issue.type?.name,
            author: issue.user?.login,
            assignees: issue.assignees.map(\.login),
            labels: issue.labels.map(\.name),
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt,
            closedAt: issue.closedAt,
            parent: try await parentTask,
            subIssues: try await subIssuesTask,
            blockedBy: try await blockedByTask,
            blocking: try await blockingTask,
            comments: comments.map {
                GitHubIssueComment(
                    id: $0.id,
                    author: $0.user.login,
                    body: $0.body,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    url: $0.htmlURL
                )
            }
        )
    }

    func postComment(body: String, for item: GitHubWorkItem) async throws {
        let repo = try parseRepository(item.repository)
        let payload = try JSONEncoder().encode(["body": body])
        _ = try await apiClient.post(path: "/repos/\(repo.owner)/\(repo.name)/issues/\(item.number)/comments", body: payload)
    }

    private func fetchReferences(path: String, decoder: JSONDecoder) async throws -> [GitHubIssueReference] {
        let (data, _) = try await apiClient.get(path: path, queryItems: [])
        let payload = try decoder.decode([GitHubIssueRelationshipPayload].self, from: data)
        return payload.map(relationshipReference(from:))
    }

    private func fetchOptionalReference(path: String, decoder: JSONDecoder) async throws -> GitHubIssueReference? {
        do {
            let (data, _) = try await apiClient.get(path: path, queryItems: [])
            let payload = try decoder.decode(GitHubIssueRelationshipPayload.self, from: data)
            return relationshipReference(from: payload)
        } catch let error as GitHubAPIClient.APIError {
            if case let .requestFailed(statusCode, _) = error, statusCode == 404 {
                return nil
            }
            throw error
        }
    }

    private func relationshipReference(from payload: GitHubIssueRelationshipPayload) -> GitHubIssueReference {
        GitHubIssueReference(
            id: payload.id,
            number: payload.number,
            title: payload.title,
            repository: payload.repositoryName,
            url: payload.htmlURL,
            state: payload.state,
            type: payload.type?.name
        )
    }

    private func parseRepository(_ value: String) throws -> (owner: String, name: String) {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubAPIClient.APIError.requestFailed(statusCode: 0, message: "Invalid repository identifier: \(value)")
        }
        return (parts[0], parts[1])
    }
}

private struct GitHubIssuePayload: Decodable {
    struct User: Decodable { let login: String }
    struct Label: Decodable { let name: String }
    struct TypeInfo: Decodable { let name: String }

    let state: String
    let stateReason: String?
    let type: TypeInfo?
    let body: String?
    let user: User?
    let assignees: [User]
    let labels: [Label]
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?

    enum CodingKeys: String, CodingKey {
        case state
        case stateReason = "state_reason"
        case type
        case body
        case user
        case assignees
        case labels
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
    }
}

private struct GitHubIssueRelationshipPayload: Decodable {
    struct TypeInfo: Decodable { let name: String }

    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let repositoryURL: String
    let state: String
    let type: TypeInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
        case state
        case type
    }

    var repositoryName: String {
        repositoryURL.replacingOccurrences(of: "https://api.github.com/repos/", with: "")
    }
}

private struct GitHubCommentPayload: Decodable {
    struct User: Decodable { let login: String }

    let id: Int
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let htmlURL: URL
    let user: User

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case user
    }
}
