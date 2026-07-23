import Foundation

enum GitHubActionsServiceError: LocalizedError {
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub에서 올바르지 않은 응답을 받았습니다."
        case let .requestFailed(status, message):
            if status == 404 {
                return "GitHub Actions 정보를 찾지 못했습니다. 비공개 저장소라면 `gh auth login`으로 로그인해주세요."
            }
            if status == 401 {
                return "GitHub 인증이 만료되었습니다. `gh auth login`으로 다시 로그인해주세요."
            }
            if status == 403 {
                return "GitHub API 요청 권한 또는 호출 한도를 확인해주세요."
            }
            return message.isEmpty
                ? "GitHub API 요청에 실패했습니다. (HTTP \(status))"
                : message
        }
    }
}

actor GitHubActionsService {
    static let shared = GitHubActionsService()

    private struct WorkflowRunsEnvelope: Decodable {
        let workflowRuns: [WorkflowRunResponse]

        enum CodingKeys: String, CodingKey {
            case workflowRuns = "workflow_runs"
        }
    }

    private struct WorkflowRunResponse: Decodable {
        struct PullRequestResponse: Decodable {
            struct HeadResponse: Decodable {
                let sha: String
            }

            let head: HeadResponse
        }

        let id: Int64
        let name: String?
        let displayTitle: String?
        let headSHA: String
        let pullRequests: [PullRequestResponse]?
        let headBranch: String?
        let event: String
        let status: String
        let conclusion: String?
        let htmlURL: URL
        let runNumber: Int
        let runAttempt: Int?
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, event, status, conclusion
            case displayTitle = "display_title"
            case headSHA = "head_sha"
            case pullRequests = "pull_requests"
            case headBranch = "head_branch"
            case htmlURL = "html_url"
            case runNumber = "run_number"
            case runAttempt = "run_attempt"
            case updatedAt = "updated_at"
        }
    }

    private struct CheckRunsEnvelope: Decodable {
        let checkRuns: [CheckRunResponse]

        enum CodingKeys: String, CodingKey {
            case checkRuns = "check_runs"
        }
    }

    private struct CheckRunResponse: Decodable {
        struct AppResponse: Decodable {
            let name: String
        }

        let id: Int64
        let name: String
        let status: String
        let conclusion: String?
        let detailsURL: URL?
        let app: AppResponse?
        let startedAt: Date?
        let completedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion, app
            case detailsURL = "details_url"
            case startedAt = "started_at"
            case completedAt = "completed_at"
        }
    }

    private struct ErrorEnvelope: Decodable {
        let message: String
    }

    private struct WorkflowCache {
        let eTag: String?
        let runs: [GitHubWorkflowRun]
    }

    private let credentialProvider = GitHubCredentialProvider()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var workflowCache: [GitHubRepository: WorkflowCache] = [:]

    func isAuthenticated() async -> Bool {
        await credentialProvider.token() != nil
    }

    func reloadAuthentication() async {
        await credentialProvider.reset()
    }

    func loadWorkflowSummaries(
        repository: GitRepository
    ) async throws -> [CommitID: GitHubActionsSummary] {
        guard let githubRepository = repository.githubRepository else { return [:] }

        var components = URLComponents(
            url: githubRepository.apiURL.appending(path: "actions/runs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "exclude_pull_requests", value: "false")
        ]
        guard let url = components?.url else {
            throw GitHubActionsServiceError.invalidResponse
        }

        let cache = workflowCache[githubRepository]
        let response = try await request(url: url, eTag: cache?.eTag)
        let runs: [GitHubWorkflowRun]

        if response.statusCode == 304, let cache {
            runs = cache.runs
        } else {
            try validate(response: response, data: response.data)
            let decoded = try decoder.decode(WorkflowRunsEnvelope.self, from: response.data)
            runs = decoded.workflowRuns.map { run in
                GitHubWorkflowRun(
                    id: run.id,
                    name: run.name ?? "GitHub Actions",
                    displayTitle: run.displayTitle ?? run.name ?? "Workflow 실행",
                    headSHA: run.headSHA,
                    pullRequestHeadSHAs: run.pullRequests?.map(\.head.sha) ?? [],
                    headBranch: run.headBranch,
                    event: run.event,
                    status: run.status,
                    conclusion: run.conclusion,
                    webURL: run.htmlURL,
                    runNumber: run.runNumber,
                    runAttempt: run.runAttempt ?? 1,
                    updatedAt: run.updatedAt
                )
            }
            workflowCache[githubRepository] = WorkflowCache(
                eTag: response.eTag,
                runs: runs
            )
        }

        var groupedRuns: [String: [GitHubWorkflowRun]] = [:]
        for run in runs {
            let associatedSHAs = Set(
                ([run.headSHA] + run.pullRequestHeadSHAs).map { $0.lowercased() }
            )
            for sha in associatedSHAs where !sha.isEmpty {
                groupedRuns[sha, default: []].append(run)
            }
        }
        return Dictionary(
            uniqueKeysWithValues: groupedRuns.map { sha, runs in
                let commitID = CommitID(repositoryID: repository.id, oid: sha)
                let sortedRuns = runs.sorted { $0.updatedAt > $1.updatedAt }
                return (
                    commitID,
                    GitHubActionsSummary(
                        commitID: commitID,
                        repository: githubRepository,
                        runs: sortedRuns
                    )
                )
            }
        )
    }

    func loadCheckRuns(
        repository: GitRepository,
        commitSHA: String
    ) async throws -> [GitHubCheckRun] {
        guard let githubRepository = repository.githubRepository else { return [] }
        return try await loadCheckRuns(
            repository: githubRepository,
            commitSHA: commitSHA
        )
    }

    func loadCheckRuns(
        repository githubRepository: GitHubRepository,
        commitSHA: String
    ) async throws -> [GitHubCheckRun] {
        var components = URLComponents(
            url: githubRepository.apiURL
                .appending(path: "commits")
                .appending(path: commitSHA)
                .appending(path: "check-runs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "filter", value: "latest")
        ]
        guard let url = components?.url else {
            throw GitHubActionsServiceError.invalidResponse
        }

        let response = try await request(url: url)
        try validate(response: response, data: response.data)
        let decoded = try decoder.decode(CheckRunsEnvelope.self, from: response.data)
        return decoded.checkRuns.map { check in
            GitHubCheckRun(
                id: check.id,
                name: check.name,
                status: check.status,
                conclusion: check.conclusion,
                webURL: check.detailsURL,
                appName: check.app?.name,
                startedAt: check.startedAt,
                completedAt: check.completedAt
            )
        }
        .sorted {
            if $0.state != $1.state {
                return githubActionsStateOrder($0.state) < githubActionsStateOrder($1.state)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func request(
        url: URL,
        eTag: String? = nil
    ) async throws -> (data: Data, statusCode: Int, eTag: String?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitScope", forHTTPHeaderField: "User-Agent")
        if let eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let token = await credentialProvider.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else {
            throw GitHubActionsServiceError.invalidResponse
        }
        return (
            data,
            response.statusCode,
            response.value(forHTTPHeaderField: "ETag")
        )
    }

    private func validate(
        response: (data: Data, statusCode: Int, eTag: String?),
        data: Data
    ) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data))?.message ?? ""
            throw GitHubActionsServiceError.requestFailed(
                status: response.statusCode,
                message: message
            )
        }
    }

    private func githubActionsStateOrder(_ state: GitHubActionsState) -> Int {
        switch state {
        case .inProgress: return 0
        case .queued: return 1
        case .failure: return 2
        case .cancelled: return 3
        case .unknown: return 4
        case .success: return 5
        case .neutral: return 6
        }
    }
}

private actor GitHubCredentialProvider {
    private var hasLoadedToken = false
    private var cachedToken: String?

    func token() -> String? {
        if hasLoadedToken { return cachedToken }
        hasLoadedToken = true

        let environment = ProcessInfo.processInfo.environment
        if let token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"],
           !token.isEmpty {
            cachedToken = token
            return token
        }

        for executableURL in githubCLIExecutableURLs() {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path),
                  let token = runGitHubCLIToken(executableURL: executableURL),
                  !token.isEmpty else {
                continue
            }
            cachedToken = token
            return token
        }
        return nil
    }

    func reset() {
        hasLoadedToken = false
        cachedToken = nil
    }

    private func githubCLIExecutableURLs() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
            URL(fileURLWithPath: "/usr/local/bin/gh")
        ]
    }

    private func runGitHubCLIToken(executableURL: URL) -> String? {
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
