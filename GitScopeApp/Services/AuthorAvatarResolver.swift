import Foundation

actor AuthorAvatarResolver {
    static let shared = AuthorAvatarResolver()

    private var resolvedURLs: [String: URL] = [:]
    private var resolvedImageData: [String: Data] = [:]
    private var imageCacheKeys: [String] = []
    private var missingCommitIDs: Set<CommitID> = []
    private var pendingTasks: [String: Task<URL?, Never>] = [:]
    private var pendingImageTasks: [String: Task<Data?, Never>] = [:]
    private let imageCacheLimit = 256
    private let imageCacheCostLimit = 16 * 1_024 * 1_024
    private let individualImageLimit = 1_024 * 1_024
    private var imageCacheCost = 0

    func imageData(for commit: GitCommit) async -> Data? {
        guard AppSettings.isAuthorAvatarLookupEnabled else { return nil }
        let key = avatarKey(for: commit)
        guard !key.isEmpty else { return nil }
        if let cached = resolvedImageData[key] {
            return cached
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
        if missingCommitIDs.contains(commit.id) {
            return nil
        }
        if let pendingTask = pendingTasks[key] {
            return await pendingTask.value
        }

        let repositoryPath = commit.id.repositoryID.rawValue
        let commitOID = commit.id.oid
        let task = Task.detached(priority: .utility) {
            await AvatarLookupGate.shared.acquire()
            let url = Self.resolveURL(
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
            missingCommitIDs.insert(commit.id)
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

        while imageCacheKeys.count > imageCacheLimit
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
    ) -> URL? {
        if let username = gitHubUsername(from: email) {
            return URL(string: "https://github.com/\(username).png?size=64")
        }

        guard run(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repositoryPath,
                "branch", "-r", "--contains", commitOID,
                "--format=%(refname)"
            ]
        ) != nil else {
            return nil
        }

        if let repository = gitHubRepository(path: repositoryPath),
           let ghPath = ghExecutablePath(),
           let avatar = run(
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
        return username.isEmpty ? nil : username
    }

    private nonisolated static func gitHubRepository(path: String) -> String? {
        guard let remote = run(
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

        return repository.hasSuffix(".git")
            ? String(repository.dropLast(4))
            : repository
    }

    private nonisolated static func ghExecutablePath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private nonisolated static func run(
        executable: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeout = Date().addingTimeInterval(4)
        while process.isRunning, Date() < timeout {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
