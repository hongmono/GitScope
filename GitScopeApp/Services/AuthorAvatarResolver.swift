import Foundation

actor AuthorAvatarResolver {
    static let shared = AuthorAvatarResolver()

    private var resolvedURLs: [String: URL] = [:]
    private var resolvedImageData: [String: Data] = [:]
    private var imageCacheKeys: [String] = []
    private var urlFailureTimes: [String: Date] = [:]
    private var imageFailureTimes: [String: Date] = [:]
    private var pendingTasks: [String: Task<URL?, Never>] = [:]
    private var pendingImageTasks: [String: Task<Data?, Never>] = [:]
    private let imageCacheLimit = 256
    private let imageCacheCostLimit = 16 * 1_024 * 1_024
    private let individualImageLimit = 1_024 * 1_024
    // 실패도 성공과 같은 작성자 키(repo::email) 단위로 기억해, 같은 작성자의
    // 커밋마다 서브프로세스/네트워크 재시도가 반복되지 않게 한다. 일시적인
    // 오류에서 회복할 수 있도록 TTL 이 지나면 한 번 다시 시도한다.
    private let failureRetryInterval: TimeInterval = 5 * 60
    private var imageCacheCost = 0

    func imageData(for commit: GitCommit) async -> Data? {
        guard AppSettings.isAuthorAvatarLookupEnabled else { return nil }
        let key = avatarKey(for: commit)
        guard !key.isEmpty else { return nil }
        if let cached = resolvedImageData[key] {
            return cached
        }
        if let failedAt = imageFailureTimes[key] {
            guard Date().timeIntervalSince(failedAt) >= failureRetryInterval else {
                return nil
            }
            imageFailureTimes[key] = nil
        }
        if let pendingTask = pendingImageTasks[key] {
            return await pendingTask.value
        }

        let individualImageLimit = self.individualImageLimit
        let task = Task<Data?, Never>(priority: .utility) {
            guard let url = await self.url(for: commit) else { return nil }
            await AvatarImageDownloadGate.shared.acquire()
            guard !Task.isCancelled else {
                await AvatarImageDownloadGate.shared.release()
                return nil
            }

            let result: Data?
            do {
                let (bytes, response) = try await URLSession.shared.bytes(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    bytes.task.cancel()
                    await AvatarImageDownloadGate.shared.release()
                    return nil
                }

                let expectedSize = httpResponse.expectedContentLength
                guard expectedSize <= 0 || expectedSize <= individualImageLimit else {
                    bytes.task.cancel()
                    await AvatarImageDownloadGate.shared.release()
                    return nil
                }

                var data = Data()
                if expectedSize > 0 {
                    data.reserveCapacity(Int(expectedSize))
                }
                for try await byte in bytes {
                    guard data.count < individualImageLimit else {
                        bytes.task.cancel()
                        await AvatarImageDownloadGate.shared.release()
                        return nil
                    }
                    data.append(byte)
                }
                guard !data.isEmpty else {
                    await AvatarImageDownloadGate.shared.release()
                    return nil
                }
                result = data
            } catch {
                result = nil
            }
            await AvatarImageDownloadGate.shared.release()
            return result
        }
        pendingImageTasks[key] = task

        let data = await task.value
        pendingImageTasks[key] = nil
        if let data {
            cacheImageData(data, for: key)
        } else {
            imageFailureTimes[key] = Date()
        }
        return data
    }

    func url(for commit: GitCommit) async -> URL? {
        guard AppSettings.isAuthorAvatarLookupEnabled else { return nil }
        let email = commit.authorEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return nil }

        let key = avatarKey(for: commit)
        if let cached = resolvedURLs[key] {
            return cached
        }
        if let failedAt = urlFailureTimes[key] {
            guard Date().timeIntervalSince(failedAt) >= failureRetryInterval else {
                return nil
            }
            urlFailureTimes[key] = nil
        }
        if let pendingTask = pendingTasks[key] {
            return await pendingTask.value
        }

        let repositoryPath = commit.id.repositoryID.rawValue
        let commitOID = commit.id.oid
        let task = Task.detached(priority: .utility) {
            await AvatarLookupGate.shared.acquire()
            let url = await Self.resolveURL(
                repositoryPath: repositoryPath,
                commitOID: commitOID,
                email: email
            )
            await AvatarLookupGate.shared.release()
            return url
        }
        pendingTasks[key] = task

        let url = await task.value
        pendingTasks[key] = nil
        if let url {
            resolvedURLs[key] = url
        } else {
            urlFailureTimes[key] = Date()
        }
        return url
    }

    private func avatarKey(for commit: GitCommit) -> String {
        let email = commit.authorEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !email.isEmpty else { return "" }
        return "\(commit.id.repositoryID.rawValue)::\(email)"
    }

    private func cacheImageData(_ data: Data, for key: String) {
        if let previousData = resolvedImageData[key] {
            imageCacheCost -= previousData.count
        } else {
            imageCacheKeys.append(key)
        }
        resolvedImageData[key] = data
        imageCacheCost += data.count

        while !imageCacheKeys.isEmpty,
              imageCacheKeys.count > imageCacheLimit
                  || imageCacheCost > imageCacheCostLimit {
            let evictedKey = imageCacheKeys.removeFirst()
            imageCacheCost -= resolvedImageData[evictedKey]?.count ?? 0
            resolvedImageData[evictedKey] = nil
        }
    }

    private nonisolated static func resolveURL(
        repositoryPath: String,
        commitOID: String,
        email: String
    ) async -> URL? {
        if let username = gitHubUsername(from: email) {
            return URL(string: "https://github.com/\(username).png?size=64")
        }

        guard await run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repositoryPath,
                "branch", "-r", "--contains", commitOID,
                "--format=%(refname)"
            ]
        ) != nil else {
            return nil
        }

        if let repository = await gitHubRepository(path: repositoryPath),
           let ghPath = ghExecutablePath(),
           let avatar = await run(
                executable: ghPath,
                arguments: [
                    "api", "--cache", "1h",
                    "repos/\(repository)/commits/\(commitOID)",
                    "--jq", ".author.avatar_url // empty"
                ]
           ),
           let url = URL(string: avatar) {
            return url
        }
        return nil
    }

    private nonisolated static func gitHubUsername(from email: String) -> String? {
        guard email.hasSuffix("@users.noreply.github.com"),
              let localPart = email.split(separator: "@").first else {
            return nil
        }
        let username = localPart.split(separator: "+").last.map(String.init) ?? ""
        guard isSafeURLPathSegment(username) else { return nil }
        return username
    }

    private nonisolated static func gitHubRepository(path: String) async -> String? {
        guard let remote = await run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "remote", "get-url", "origin"]
        ) else {
            return nil
        }

        let repository: String
        if remote.hasPrefix("git@github.com:") {
            repository = String(remote.dropFirst("git@github.com:".count))
        } else if let url = URL(string: remote), url.host == "github.com" {
            repository = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }

        let normalized = repository.hasSuffix(".git")
            ? String(repository.dropLast(4))
            : repository
        let segments = normalized.split(separator: "/").map(String.init)
        guard segments.count == 2,
              segments.allSatisfy(isSafeURLPathSegment) else {
            return nil
        }
        return segments.joined(separator: "/")
    }

    // 원격 URL·이메일에서 뽑은 값을 URL 경로/`gh api` 경로에 보간하므로,
    // 경로 구분자나 특수문자가 섞인 값은 여기서 걸러낸다.
    private nonisolated static func isSafeURLPathSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || character == "-"
                    || character == "_"
                    || character == ".")
        }
    }

    private nonisolated static func ghExecutablePath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static let subprocessTimeout: TimeInterval = 4

    private nonisolated static func run(
        executable: String,
        arguments: [String]
    ) async -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // 출력은 종료를 기다리기 전에 비동기로 읽는다. 종료 후에 읽기 시작하면
        // 자식이 파이프 버퍼(64KB)를 다 채웠을 때 서로 기다리는 교착이 된다.
        let completion = SubprocessCompletion()
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
                deadline: .now() + subprocessTimeout
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
        let value = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// 서브프로세스의 종료와 stdout EOF 를 모두 기다렸다가 정확히 한 번만
/// continuation 을 재개한다. readabilityHandler / terminationHandler /
/// 타임아웃이 서로 다른 스레드에서 호출되므로 락으로 보호한다.
private final class SubprocessCompletion: @unchecked Sendable {
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

private actor AvatarLookupGate {
    static let shared = AvatarLookupGate(limit: 3)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor AvatarImageDownloadGate {
    static let shared = AvatarImageDownloadGate(limit: 4)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
