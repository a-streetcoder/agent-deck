import Foundation

struct GitHubAPIClient {
    enum APIError: LocalizedError {
        case invalidResponse
        case requestFailed(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "GitHub returned an invalid response."
            case let .requestFailed(statusCode, message):
                return message.isEmpty ? "GitHub request failed with status \(statusCode)." : "GitHub request failed with status \(statusCode): \(message)"
            }
        }
    }

    let session: GitHubSession
    var urlSession: URLSession = .shared

    func get(path: String, queryItems: [URLQueryItem], bypassCache: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try await request(path: path, method: "GET", queryItems: queryItems, body: nil, bypassCache: bypassCache)
    }

    func post(path: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        try await request(path: path, method: "POST", queryItems: [], body: body)
    }

    func patch(path: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        try await request(path: path, method: "PATCH", queryItems: [], body: body)
    }

    private func request(path: String, method: String, queryItems: [URLQueryItem], body: Data?, bypassCache: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        // GitHub serves authenticated GETs with `Cache-Control: private, max-age=60`,
        // so URLSession's shared cache can return stale issue/comment data for up to
        // a minute. Routine reads happily use that cache; explicit user actions
        // (the Refresh button, posting a comment) pass `bypassCache` to force a
        // fresh fetch — e.g. so a freshly posted comment appears immediately.
        if bypassCache {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw APIError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        return (data, httpResponse)
    }

    private var apiHost: String {
        session.account.host.caseInsensitiveCompare("github.com") == .orderedSame ? "api.github.com" : session.account.host
    }
}
