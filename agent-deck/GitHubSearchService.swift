import Foundation

struct GitHubSearchService {
    private let apiClient: GitHubAPIClient

    init(apiClient: GitHubAPIClient) {
        self.apiClient = apiClient
    }

    func fetchAggregateIssues(
        repos: [GitHubRemote],
        state: GitHubIssueStateFilter,
        closeReason: GitHubIssueCloseReason? = nil,
        bypassCache: Bool = false
    ) async throws -> GitHubBoardSnapshot {
        guard !repos.isEmpty else {
            return GitHubBoardSnapshot(
                columns: [],
                totalCount: 0,
                shownCount: 0,
                incompleteResults: false,
                queryDescription: "No GitHub repositories discovered.",
                rateLimitRemaining: nil,
                rateLimitResetAt: nil
            )
        }

        let query = buildIssuesQuery(repos: repos, state: state, closeReason: closeReason)
        return try await fetchBoard(query: query, description: queryDescription(state: state, closeReason: closeReason), bypassCache: bypassCache)
    }

    func fetchRepositoryIssues(
        repo: GitHubRemote,
        state: GitHubIssueStateFilter,
        closeReason: GitHubIssueCloseReason? = nil,
        bypassCache: Bool = false
    ) async throws -> GitHubBoardSnapshot {
        let query = buildIssuesQuery(repos: [repo], state: state, closeReason: closeReason)
        return try await fetchBoard(query: query, description: "\(queryDescription(state: state, closeReason: closeReason)) · \(repo.nameWithOwner)", bypassCache: bypassCache)
    }

    private func queryDescription(state: GitHubIssueStateFilter, closeReason: GitHubIssueCloseReason?) -> String {
        if let closeReason {
            return "Issues · \(state.rawValue) · \(closeReason.title)"
        }
        return "Issues · \(state.rawValue)"
    }

    private func fetchBoard(query: String, description: String, bypassCache: Bool) async throws -> GitHubBoardSnapshot {
        let (data, response) = try await apiClient.get(
            path: "/search/issues",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: "100")
            ],
            bypassCache: bypassCache
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GitHubSearchResponse.self, from: data)
        let items = payload.items.map { item in
            GitHubWorkItem(
                id: "\(item.repositoryURL)-\(item.number)",
                number: item.number,
                title: item.title,
                repository: item.repositoryName,
                url: item.htmlURL,
                isPullRequest: item.pullRequest != nil,
                state: item.state,
                stateReason: item.stateReason,
                type: item.type?.name,
                labels: item.labels.map { GitHubLabel(name: $0.name, color: $0.color) },
                assignees: item.assignees.map(\.login),
                author: item.user?.login,
                body: item.body ?? item.bodyText ?? "",
                commentCount: item.comments,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                closedAt: item.closedAt,
                subIssuesSummary: item.subIssuesSummary.map {
                    GitHubSubIssuesSummary(total: $0.total, completed: $0.completed, percentCompleted: $0.percentCompleted)
                },
                issueDependenciesSummary: item.issueDependenciesSummary.map {
                    GitHubIssueRelationshipSummary(
                        blockedBy: $0.blockedBy,
                        totalBlockedBy: $0.totalBlockedBy,
                        blocking: $0.blocking,
                        totalBlocking: $0.totalBlocking
                    )
                }
            )
        }

        return GitHubBoardSnapshot(
            columns: makeColumns(for: items),
            totalCount: payload.totalCount,
            shownCount: items.count,
            incompleteResults: payload.incompleteResults,
            queryDescription: description,
            rateLimitRemaining: response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
            rateLimitResetAt: response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        )
    }

    private func makeColumns(for items: [GitHubWorkItem]) -> [GitHubBoardColumn] {
        let grouped = Dictionary(grouping: items, by: { normalizedColumnTitle(for: $0.state) })
        let preferredOrder = ["Open", "Closed"]

        return grouped
            .map { title, groupedItems in
                GitHubBoardColumn(
                    title: title,
                    items: groupedItems.sorted { $0.updatedAt > $1.updatedAt }
                )
            }
            .sorted { lhs, rhs in
                let lhsIndex = preferredOrder.firstIndex(of: lhs.title) ?? Int.max
                let rhsIndex = preferredOrder.firstIndex(of: rhs.title) ?? Int.max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func normalizedColumnTitle(for state: String) -> String {
        switch state.lowercased() {
        case "open":
            return "Open"
        case "closed":
            return "Closed"
        default:
            return state.capitalized
        }
    }

    private func buildIssuesQuery(repos: [GitHubRemote], state: GitHubIssueStateFilter, closeReason: GitHubIssueCloseReason?) -> String {
        var parts: [String] = ["is:issue"]
        if let stateQualifier = state.searchQualifier {
            parts.append(stateQualifier)
        }
        if let closeReason {
            parts.append(closeReason.searchQualifier)
        }

        let uniqueRepos = Array(Set(repos.map(\.nameWithOwner))).sorted()
        parts.append(contentsOf: uniqueRepos.map { "repo:\($0)" })
        return parts.joined(separator: " ")
    }
}

private struct GitHubSearchResponse: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [GitHubSearchItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case incompleteResults = "incomplete_results"
        case items
    }
}

private struct GitHubSearchItem: Decodable {
    struct Label: Decodable {
        let name: String
        let color: String?
    }

    struct User: Decodable {
        let login: String
    }

    struct PullRequestMarker: Decodable {}

    struct TypeInfo: Decodable {
        let name: String
    }

    struct SubIssuesSummary: Decodable {
        let total: Int
        let completed: Int
        let percentCompleted: Int

        enum CodingKeys: String, CodingKey {
            case total
            case completed
            case percentCompleted = "percent_completed"
        }
    }

    struct IssueDependenciesSummary: Decodable {
        let blockedBy: Int
        let totalBlockedBy: Int
        let blocking: Int
        let totalBlocking: Int

        enum CodingKeys: String, CodingKey {
            case blockedBy = "blocked_by"
            case totalBlockedBy = "total_blocked_by"
            case blocking
            case totalBlocking = "total_blocking"
        }
    }

    let number: Int
    let title: String
    let htmlURL: URL
    let repositoryURL: String
    let state: String
    let stateReason: String?
    let type: TypeInfo?
    let labels: [Label]
    let assignees: [User]
    let user: User?
    let body: String?
    let bodyText: String?
    let comments: Int
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let subIssuesSummary: SubIssuesSummary?
    let issueDependenciesSummary: IssueDependenciesSummary?
    let pullRequest: PullRequestMarker?

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
        case state
        case stateReason = "state_reason"
        case type
        case labels
        case assignees
        case user
        case body
        case bodyText = "body_text"
        case comments
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case subIssuesSummary = "sub_issues_summary"
        case issueDependenciesSummary = "issue_dependencies_summary"
        case pullRequest = "pull_request"
    }

    var repositoryName: String {
        repositoryURL.replacingOccurrences(of: "https://api.github.com/repos/", with: "")
    }
}
