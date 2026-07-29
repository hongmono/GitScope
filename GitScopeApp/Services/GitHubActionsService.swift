import Foundation

/// GitHub API 레이트리밋 상태. 403/429 응답의 `Retry-After` /
/// `X-RateLimit-Remaining` / `X-RateLimit-Reset` 헤더로 만들어진다.
/// 폴링 주기를 조정하려는 쪽은 `retryAt` 이후에 다시 시도하면 된다.
struct GitHubRateLimitStatus: Equatable, Sendable {
    /// 남은 허용 요청 수 (`X-RateLimit-Remaining`, 헤더가 없으면 nil).
    let remainingRequests: Int?
    /// 이 시각 이후에 다시 시도할 수 있다.
    let retryAt: Date
}

enum GitHubActionsServiceError: LocalizedError {
    case invalidResponse
    case requestFailed(status: Int, message: String)
    case rateLimited(GitHubRateLimitStatus)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub에서 올바르지 않은 응답을 받았습니다."
        case let .rateLimited(status):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let retryTime = formatter.string(from: status.retryAt)
            return "GitHub API 호출 한도를 초과했습니다. \(retryTime) 이후 다시 시도해주세요."
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

    /// 마지막 요청에서 관측한 레이트리밋 상태. 레이트리밋이 아닌 응답을
    /// 받으면 nil 로 돌아간다. 폴링 간격을 조정하려는 소비자가 읽는다.
    private(set) var lastRateLimitStatus: GitHubRateLimitStatus?

    func isAuthenticated() async -> Bool {
        await credentialProvider.token() != nil
    }

    func reloadAuthentication() async {
        await credentialProvider.reset()
    }

    func loadWorkflowSummaries(
        repository: GitRepository
    ) async throws -> [CommitID: GitHubActionsSummary] {
        guard AppSettings.isGitHubActionsEnabled else { return [:] }
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
        guard AppSettings.isGitHubActionsEnabled else { return [] }
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
        if let rateLimit = Self.rateLimitStatus(from: response) {
            lastRateLimitStatus = rateLimit
            throw GitHubActionsServiceError.rateLimited(rateLimit)
        }
        if (200..<300).contains(response.statusCode) || response.statusCode == 304 {
            lastRateLimitStatus = nil
        }
        return (
            data,
            response.statusCode,
            response.value(forHTTPHeaderField: "ETag")
        )
    }

    /// 403/429 중 실제 레이트리밋 응답만 골라낸다. `Retry-After` 가 있으면
    /// (2차 한도) 그 값을 쓰고, 아니면 `X-RateLimit-Remaining` 이 0 이하일 때
    /// `X-RateLimit-Reset`(epoch 초)을 재시도 시각으로 삼는다. 권한 문제로 온
    /// 403 은 nil 을 돌려줘 기존 requestFailed 경로로 처리되게 한다.
    private static func rateLimitStatus(
        from response: HTTPURLResponse
    ) -> GitHubRateLimitStatus? {
        guard response.statusCode == 403 || response.statusCode == 429 else {
            return nil
        }

        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            .flatMap(Int.init)
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init) {
            return GitHubRateLimitStatus(
                remainingRequests: remaining,
                retryAt: Date(timeIntervalSinceNow: max(0, retryAfter))
            )
        }

        guard let remaining, remaining <= 0 else { return nil }
        let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        return GitHubRateLimitStatus(
            remainingRequests: remaining,
            retryAt: resetAt ?? Date(timeIntervalSinceNow: 60)
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
    private var loadTask: Task<String?, Never>?
    private var generation = 0

    func token() async -> String? {
        if hasLoadedToken { return cachedToken }
        if let loadTask { return await loadTask.value }

        let task = Task { await Self.loadToken() }
        loadTask = task
        // 로딩 중 reset() 이 끼어들면 낡은 결과를 캐시하지 않는다.
        let startedGeneration = generation
        let token = await task.value
        if generation == startedGeneration {
            loadTask = nil
            hasLoadedToken = true
            cachedToken = token
        }
        return token
    }

    func reset() {
        generation += 1
        loadTask = nil
        hasLoadedToken = false
        cachedToken = nil
    }

    private static func loadToken() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"],
           !token.isEmpty {
            return token
        }

        for executableURL in githubCLIExecutableURLs() {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path),
                  let token = await runGitHubCLIToken(executableURL: executableURL),
                  !token.isEmpty else {
                continue
            }
            return token
        }
        return nil
    }

    private static func githubCLIExecutableURLs() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
            URL(fileURLWithPath: "/usr/local/bin/gh")
        ]
    }

    private static let tokenTimeout: TimeInterval = 10

    private static func runGitHubCLIToken(executableURL: URL) async -> String? {
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        process.standardOutput = output
        // stderr 를 파이프로 받아 놓고 읽지 않으면 64KB 를 넘는 순간
        // 자식이 쓰기에서 막혀 영영 종료하지 않는다. 쓰지 않으므로 버린다.
        process.standardError = FileHandle.nullDevice

        // stdout 도 종료를 기다리기 전에 비동기로 읽는다.
        let completion = TokenSubprocessCompletion()
        let outputHandle = output.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                completion.finishOutput()
            } else {
                completion.appendOutput(chunk)
            }
        }
        process.terminationHandler = {
            completion.finishProcess(status: $0.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            return nil
        }

        let result = await withCheckedContinuation { continuation in
            completion.install(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + tokenTimeout
            ) {
                completion.expire()
            }
        }

        guard let result else {
            outputHandle.readabilityHandler = nil
            process.terminate()
            return nil
        }
        guard result.status == 0 else { return nil }
        let token = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

/// `gh auth token` 서브프로세스의 종료와 stdout EOF 를 모두 기다렸다가
/// 정확히 한 번만 continuation 을 재개한다. readabilityHandler /
/// terminationHandler / 타임아웃이 서로 다른 스레드에서 호출되므로 락으로
/// 보호한다.
private final class TokenSubprocessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var terminationStatus: Int32?
    private var isOutputComplete = false
    private var didResume = false
    private var continuation: CheckedContinuation<(status: Int32, output: Data)?, Never>?

    func appendOutput(_ chunk: Data) {
        lock.lock()
        outputData.append(chunk)
        lock.unlock()
    }

    func finishOutput() {
        lock.lock()
        isOutputComplete = true
        let resume = resumeActionLocked()
        lock.unlock()
        resume?()
    }

    func finishProcess(status: Int32) {
        lock.lock()
        terminationStatus = status
        let resume = resumeActionLocked()
        lock.unlock()
        resume?()
    }

    func install(
        _ continuation: CheckedContinuation<(status: Int32, output: Data)?, Never>
    ) {
        lock.lock()
        self.continuation = continuation
        let resume = resumeActionLocked()
        lock.unlock()
        resume?()
    }

    /// 타임아웃: 아직 재개되지 않았다면 nil 로 재개한다.
    func expire() {
        lock.lock()
        guard !didResume, let continuation else {
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: nil)
    }

    private func resumeActionLocked() -> (() -> Void)? {
        guard !didResume,
              let continuation,
              let status = terminationStatus,
              isOutputComplete else {
            return nil
        }
        didResume = true
        self.continuation = nil
        let output = outputData
        return { continuation.resume(returning: (status, output)) }
    }
}
