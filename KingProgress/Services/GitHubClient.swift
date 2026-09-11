import Foundation

struct GitHubError: LocalizedError {
    enum Kind {
        case badCredentials
        case notFound
        case http(Int)
        case badResponse
    }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }

    var status: Int? {
        switch kind {
        case .badCredentials: 401
        case .notFound: 404
        case .http(let status): status
        case .badResponse: nil
        }
    }
}

/// A conditional GET: `nil` body means GitHub answered 304 Not Modified.
struct ConditionalResponse<T> {
    let value: T?
    let etag: String?
}

/// The thinnest possible client for the handful of endpoints KingProgress
/// uses. URLSession's own cache is switched off so our If-None-Match
/// bookkeeping sees the real 304s, which is what makes watching idle
/// repositories free.
final class GitHubClient {
    static let userAgent = "KingProgress/\(Bundle.main.shortVersion)"

    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(token: String) {
        self.token = token

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Requests

    private func request(_ path: String, query: [String: String] = [:], etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: "https://api.github.com\(path)")!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(kind: .badResponse, message: "GitHub returned an unexpected response.")
        }

        return (data, http)
    }

    private func check(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200 ..< 300, 304:
            return
        case 401:
            throw GitHubError(kind: .badCredentials, message: "GitHub does not recognise that token.")
        case 404:
            throw GitHubError(kind: .notFound, message: "Not found.")
        default:
            let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubError(kind: .http(http.statusCode), message: "GitHub replied \(http.statusCode) \(reason).")
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, http) = try await request(path, query: query)
        try check(http)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError(kind: .badResponse, message: "GitHub returned an unexpected response.")
        }
    }

    // MARK: - Endpoints

    /// Who the token belongs to. The granted scopes come back in a response
    /// header, which is the only way to tell the user up front that they
    /// ticked the wrong boxes.
    func validateToken() async throws -> Account {
        let (data, http) = try await request("/user")
        try check(http)

        guard let user = try? decoder.decode(GitHubUser.self, from: data) else {
            throw GitHubError(kind: .badResponse, message: "GitHub returned an unexpected response.")
        }

        // Fine-grained tokens send no scope header at all; treat that as
        // "unknown" rather than "missing", because we cannot tell from here.
        let scopeHeader = http.value(forHTTPHeaderField: "x-oauth-scopes")
        let scopes = scopeHeader?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        return Account(login: user.login, name: user.name, avatarUrl: user.avatarUrl ?? "", scopes: scopes)
    }

    /// Every repository the token can see, most recently updated first.
    func listRepositories() async throws -> [RepoSummary] {
        var summaries: [RepoSummary] = []
        var page = 1

        while true {
            let (data, http) = try await request("/user/repos", query: [
                "per_page": "100",
                "sort": "updated",
                "direction": "desc",
                "page": String(page),
            ])
            try check(http)

            let repos = (try? decoder.decode([Repository].self, from: data)) ?? []
            summaries += repos.map {
                RepoSummary(
                    fullName: $0.fullName,
                    owner: $0.owner.login,
                    name: $0.name,
                    isPrivate: $0.private ?? false,
                    isFork: $0.fork ?? false,
                    updatedAt: $0.updatedAt ?? ""
                )
            }

            let link = http.value(forHTTPHeaderField: "Link") ?? ""
            if repos.isEmpty || !link.contains("rel=\"next\"") || page >= 20 {
                break
            }
            page += 1
        }

        return summaries
    }

    /// Recent runs for one repository, as a conditional request. GitHub does
    /// not charge rate limit for a 304, so a repository where nothing happened
    /// is free to watch.
    func recentRuns(owner: String, repo: String, perPage: Int, etag: String?) async throws -> ConditionalResponse<[WorkflowRun]> {
        let (data, http) = try await request("/repos/\(owner)/\(repo)/actions/runs", query: ["per_page": String(perPage)], etag: etag)
        try check(http)

        if http.statusCode == 304 {
            return ConditionalResponse(value: nil, etag: etag)
        }

        let list = try decoder.decode(WorkflowRunList.self, from: data)
        return ConditionalResponse(value: list.workflowRuns, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    func run(owner: String, repo: String, runId: Int) async throws -> WorkflowRun {
        try await get(WorkflowRun.self, "/repos/\(owner)/\(repo)/actions/runs/\(runId)")
    }

    func successfulRuns(owner: String, repo: String, workflowId: Int, count: Int) async throws -> [WorkflowRun] {
        try await get(WorkflowRunList.self, "/repos/\(owner)/\(repo)/actions/workflows/\(workflowId)/runs", query: [
            "status": "success",
            "per_page": String(count),
        ]).workflowRuns
    }

    /// The jobs of a run, steps included.
    func jobs(owner: String, repo: String, runId: Int) async throws -> [Job] {
        try await get(JobList.self, "/repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs", query: ["per_page": "100"]).jobs
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
