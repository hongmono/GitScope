import Foundation

/// 워크스페이스 로드 중 저장소 하나가 실패한 기록.
///
/// 원본이 사라진 worktree 처럼 저장소 하나가 망가져도 나머지는 그대로 보여주기 위해,
/// 실패를 던지는 대신 이 값으로 모아서 돌려준다.
struct RepositoryLoadFailure: Identifiable, Sendable, LocalizedError {
    let rootURL: URL
    let message: String

    var id: String { rootURL.path }
    var errorDescription: String? { message }
}

/// 로드 결과와 실패 목록을 함께 담은 보고서.
struct WorkspaceLoadReport: Sendable {
    let snapshot: WorkspaceSnapshot
    let failures: [RepositoryLoadFailure]
}

actor GitRepositoryLoader {
    private let runner = GitCommandRunner()
    private let scanner = RepositoryScanner()
    private let isoFormatter = ISO8601DateFormatter()
    private let gregorianCalendar = Calendar(identifier: .gregorian)

    init() {
        // git 이 내는 `%aI` 에는 소수점 초가 없다. `.withFractionalSeconds` 를 켜면 모든
        // 파싱이 실패해 폴백만 타게 된다.
        isoFormatter.formatOptions = [.withInternetDateTime]
    }

    func loadWorkspace(
        at rootURL: URL,
        commitLimit: Int = 2_000,
        pathFilter: String? = nil
    ) async throws -> WorkspaceSnapshot {
        try await loadWorkspaces(
            at: [rootURL],
            commitLimit: commitLimit,
            pathFilter: pathFilter
        )
    }

    func loadWorkspaces(
        at rootURLs: [URL],
        commitLimit: Int = 2_000,
        pathFilter: String? = nil
    ) async throws -> WorkspaceSnapshot {
        try await loadWorkspacesReport(
            at: rootURLs,
            commitLimit: commitLimit,
            pathFilter: pathFilter
        ).snapshot
    }

    /// 저장소별로 나눠 읽고, 실패한 저장소는 목록으로만 남긴 채 나머지를 돌려준다.
    ///
    /// 저장소 하나가 망가져도(원본이 사라진 worktree 등) 워크스페이스 전체가 빈 화면이
    /// 되지 않게 하는 것이 목적이다. 저장소가 하나도 없거나 전부 실패한 경우에만 던진다.
    func loadWorkspacesReport(
        at rootURLs: [URL],
        commitLimit: Int = 2_000,
        pathFilter: String? = nil
    ) async throws -> WorkspaceLoadReport {
        let repositoryURLs = Array(
            Set(
                rootURLs.flatMap { scanner.scan(rootURL: $0) }
                    .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            )
        ).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !repositoryURLs.isEmpty else {
            throw GitCommandError.launchFailed("선택한 위치에서 Git 저장소를 찾지 못했습니다.")
        }

        // 저장소별로 자식 태스크를 띄운다. 자식이 이 actor 의 메서드를 호출해도 git 실행을
        // 기다리는 동안에는 actor 를 비워주므로(재진입) 저장소끼리는 실제로 겹쳐 돈다.
        let outcomes = await withTaskGroup(
            of: (index: Int, outcome: RepositoryLoadOutcome).self
        ) { group in
            for (index, repositoryURL) in repositoryURLs.enumerated() {
                group.addTask {
                    do {
                        let snapshot = try await self.loadRepositorySnapshot(
                            url: repositoryURL,
                            colorIndex: index,
                            commitLimit: commitLimit,
                            pathFilter: pathFilter
                        )
                        return (index, .loaded(snapshot))
                    } catch {
                        return (index, .failed(error.localizedDescription))
                    }
                }
            }

            var collected: [(index: Int, outcome: RepositoryLoadOutcome)] = []
            collected.reserveCapacity(repositoryURLs.count)
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // 취소로 자식이 줄줄이 실패한 것을 저장소 오류로 보고하지 않는다.
        try Task.checkCancellation()

        var snapshots: [RepositorySnapshot] = []
        var failures: [RepositoryLoadFailure] = []
        var seenRepositoryIDs = Set<RepositoryID>()
        for result in outcomes.sorted(by: { $0.index < $1.index }) {
            switch result.outcome {
            case .loaded(let snapshot):
                guard seenRepositoryIDs.insert(snapshot.repository.id).inserted else { continue }
                snapshots.append(snapshot)
            case .failed(let message):
                failures.append(
                    RepositoryLoadFailure(
                        rootURL: repositoryURLs[result.index],
                        message: message
                    )
                )
            }
        }

        // 전부 실패했다면 빈 화면으로 조용히 끝내지 않고 첫 오류를 그대로 알린다.
        if snapshots.isEmpty, let firstFailure = failures.first {
            throw firstFailure
        }

        let commits = mergeTopologicalStreams(snapshots.map(\.commits))
        return WorkspaceLoadReport(
            snapshot: WorkspaceSnapshot(
                repositories: snapshots.map(\.repository),
                referencesByRepository: Dictionary(
                    uniqueKeysWithValues: snapshots.map { ($0.repository.id, $0.references) }
                ),
                commits: commits
            ),
            failures: failures
        )
    }

    /// 저장소 하나의 로드 결과. 자식 태스크 사이로 넘겨야 해서 오류는 문구로만 담는다.
    private enum RepositoryLoadOutcome: Sendable {
        case loaded(RepositorySnapshot)
        case failed(String)
    }

    private func loadRepositorySnapshot(
        url: URL,
        colorIndex: Int,
        commitLimit: Int,
        pathFilter: String?
    ) async throws -> RepositorySnapshot {
        try Task.checkCancellation()
        let repository = try await makeRepository(url: url, colorIndex: colorIndex)

        try Task.checkCancellation()
        let references = try await loadReferences(repository: repository)

        try Task.checkCancellation()
        let headOID = try? await loadHeadOID(repository: repository)
        var commits = try await loadCommits(
            repository: repository,
            references: references,
            headOID: headOID,
            revision: "--all",
            commitLimit: commitLimit,
            pathFilter: pathFilter
        )

        try Task.checkCancellation()
        if let workingTreeCommit = try await loadWorkingTreeCommit(
            repository: repository,
            headOID: headOID.flatMap { oid in
                commits.contains { $0.id.oid == oid } ? oid : nil
            },
            pathFilter: pathFilter
        ) {
            commits.insert(workingTreeCommit, at: 0)
        }

        return RepositorySnapshot(
            repository: repository,
            references: references,
            commits: commits
        )
    }

    func loadReachableCommitIDs(
        repository: GitRepository,
        reference: GitReference,
        limit: Int = 50_000
    ) async throws -> Set<CommitID> {
        try await loadReachableCommitIDs(
            repository: repository,
            revision: reference.fullName,
            limit: limit
        )
    }

    func loadReachableCommitIDs(
        repository: GitRepository,
        revision: String,
        limit: Int = 50_000
    ) async throws -> Set<CommitID> {
        try await loadReachableCommitIDs(
            repository: repository,
            revisions: [revision],
            includesAllLocalBranches: false,
            limit: limit
        )
    }

    /// 여러 revision 의 합집합을 한 번의 `rev-list` 로 읽는다.
    ///
    /// 브랜치 범위가 쓰는 경로다. `includesAllLocalBranches` 는 `--branches` 로 옮겨지므로
    /// 로컬 브랜치가 200개여도 저장소당 호출은 1회다.
    func loadReachableCommitIDs(
        repository: GitRepository,
        revisions: [String],
        includesAllLocalBranches: Bool,
        limit: Int = 50_000
    ) async throws -> Set<CommitID> {
        guard includesAllLocalBranches || !revisions.isEmpty else { return [] }

        let text = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: Self.revListArguments(
                revisions: revisions,
                includesAllLocalBranches: includesAllLocalBranches,
                limit: limit
            )
        )
        return parseReachableCommitIDs(text, repositoryID: repository.id)
    }

    /// `rev-list` 인자를 조립한다.
    ///
    /// 마지막 `--` 는 ref 이름과 같은 경로가 저장소에 있을 때 나는 "ambiguous argument" 를
    /// 막는다. 여러 ref 를 한 번에 넘기는 이 경로에서는 그럴 확률이 그만큼 높아진다.
    static func revListArguments(
        revisions: [String],
        includesAllLocalBranches: Bool,
        limit: Int
    ) -> [String] {
        var arguments = ["-c", "color.ui=false", "rev-list", "--max-count=\(limit)"]
        if includesAllLocalBranches {
            arguments.append("--branches")
        }
        arguments.append(contentsOf: revisions)
        arguments.append("--")
        return arguments
    }

    func parseReachableCommitIDs(
        _ text: String,
        repositoryID: RepositoryID
    ) -> Set<CommitID> {
        Set(
            text.split(whereSeparator: \.isNewline).map {
                CommitID(repositoryID: repositoryID, oid: String($0))
            }
        )
    }

    func loadDetails(commit: GitCommit, repository: GitRepository) async throws -> CommitDetails {
        if commit.isWorkingTree {
            return CommitDetails(
                commit: commit,
                files: try await loadWorkingTreeFiles(repository: repository, pathFilter: nil)
            )
        }

        let arguments: [String]
        if let firstParent = mergeFirstParent(of: commit) {
            // 머지 커밋의 `show --name-status` 는 combined diff 라 대개 빈 출력이 된다.
            // 첫 부모와의 diff 로 바꿔 변경 파일을 보여준다.
            arguments = [
                "-c", "color.ui=false",
                "diff", "--name-status", "-z",
                "--find-renames", "--find-copies",
                "--no-ext-diff", "--no-textconv",
                firstParent, commit.id.oid
            ]
        } else {
            arguments = [
                "-c", "color.ui=false",
                "show", "--format=", "--name-status", "-z",
                "--find-renames", "--find-copies",
                "--no-ext-diff", "--no-textconv", commit.id.oid
            ]
        }

        let fileData = try await runner.runData(
            repositoryURL: repository.rootURL,
            arguments: arguments,
            maximumBytes: 2_000_000
        )

        let files = parseChangedFiles(fileData)
        return CommitDetails(commit: commit, files: files)
    }

    func loadPatch(
        commit: GitCommit,
        repository: GitRepository,
        file: ChangedFile
    ) async throws -> String {
        // 잘못된 UTF-8 경로는 U+FFFD 로 치환돼 있어 pathspec 으로 되돌려 쓸 수 없다.
        // 그대로 넘기면 git 이 성공(exit 0)하며 빈 diff 를 내 무음 실패가 된다.
        if file.diffPaths.contains(where: { $0.contains("\u{FFFD}") }) {
            throw GitCommandError.invalidPath(file.path)
        }

        if commit.isWorkingTree {
            if file.status == "??" {
                return "추적되지 않은 파일입니다. Git에 추가한 뒤 전체 diff를 확인할 수 있습니다.\n\n\(file.path)"
            }

            return try await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: [
                    "-c", "color.ui=false",
                    "--literal-pathspecs",
                    "diff", "HEAD", "--patch",
                    "--find-renames", "--find-copies", "--unified=3",
                    "--no-ext-diff", "--no-textconv", "--"
                ] + file.diffPaths,
                maximumBytes: 8_000_000
            )
        }

        if let firstParent = mergeFirstParent(of: commit) {
            // 파일 목록을 첫 부모 기준으로 뽑았으므로 패치도 같은 기준으로 맞춘다.
            // `show` 의 combined diff 는 이 목록과 어긋나 빈 패치가 되기 쉽다.
            return try await runner.runText(
                repositoryURL: repository.rootURL,
                arguments: [
                    "-c", "color.ui=false",
                    "--literal-pathspecs",
                    "diff", "--patch",
                    "--find-renames", "--find-copies", "--unified=3",
                    "--no-ext-diff", "--no-textconv",
                    firstParent, commit.id.oid, "--"
                ] + file.diffPaths,
                maximumBytes: 8_000_000
            )
        }

        return try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "--literal-pathspecs",
                "show", "--format=", "--patch",
                "--find-renames", "--find-copies", "--unified=3",
                "--no-ext-diff", "--no-textconv", commit.id.oid, "--"
            ] + file.diffPaths,
            maximumBytes: 8_000_000
        )
    }

    /// 머지 커밋이면 첫 부모 OID 를, 아니면 nil 을 준다.
    private func mergeFirstParent(of commit: GitCommit) -> String? {
        guard commit.parentOIDs.count > 1 else { return nil }
        return commit.parentOIDs.first
    }

    private func makeRepository(url: URL, colorIndex: Int) async throws -> GitRepository {
        let topLevel = try await runner.runText(
            repositoryURL: url,
            arguments: ["rev-parse", "--show-toplevel"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedURL = URL(fileURLWithPath: topLevel)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let originURL = try? await runner.runText(
            repositoryURL: normalizedURL,
            arguments: ["remote", "get-url", "origin"],
            maximumBytes: 16_384
        )
        return GitRepository(
            id: RepositoryID(rawValue: normalizedURL.path),
            name: normalizedURL.lastPathComponent,
            rootURL: normalizedURL,
            colorIndex: colorIndex,
            githubRepository: originURL.flatMap(GitHubRepository.init(remoteURL:))
        )
    }

    private func loadHeadOID(repository: GitRepository) async throws -> String {
        try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["rev-parse", "--verify", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadWorkingTreeCommit(
        repository: GitRepository,
        headOID: String?,
        pathFilter: String?
    ) async throws -> GitCommit? {
        let files = try await loadWorkingTreeFiles(
            repository: repository,
            pathFilter: pathFilter
        )
        guard !files.isEmpty else { return nil }

        let authorName = (try? await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["config", "--get", "user.name"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "작업 트리"
        let authorEmail = (try? await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: ["config", "--get", "user.email"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        return GitCommit(
            id: CommitID(repositoryID: repository.id, oid: "WORKTREE"),
            parentOIDs: headOID.map { [$0] } ?? [],
            subject: "커밋되지 않은 변경 사항",
            body: "현재 작업 트리에서 변경된 파일입니다.",
            authorName: authorName.isEmpty ? "작업 트리" : authorName,
            authorEmail: authorEmail,
            authorDate: .now,
            committerDate: .now,
            references: [],
            isHead: false,
            isWorkingTree: true
        )
    }

    private func loadWorkingTreeFiles(
        repository: GitRepository,
        pathFilter: String?
    ) async throws -> [ChangedFile] {
        var arguments = [
            "-c", "color.ui=false",
            "status", "--porcelain=v1", "-z", "--untracked-files=all"
        ]
        if let pathFilter, !pathFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append("--")
            arguments.append(pathFilter)
        }
        let data = try await runner.runData(
            repositoryURL: repository.rootURL,
            arguments: arguments,
            maximumBytes: 4_000_000
        )
        return parseWorkingTreeFiles(data)
    }

    private func loadReferences(repository: GitRepository) async throws -> [GitReference] {
        let data = try await runner.runData(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "for-each-ref",
                "--count=50000",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(HEAD)%00%(upstream)%00%(upstream:short)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream:track,nobracket)%00",
                "refs/heads", "refs/remotes", "refs/tags"
            ],
            // ref 가 많은 저장소에서 한도에 걸려 저장소 전체를 못 읽는 일이 없도록 넉넉히 둔다.
            maximumBytes: 32_000_000
        )

        let fields = splitNullTerminated(data)
        var references: [GitReference] = []
        var index = 0
        while index + 8 < fields.count {
            let fullName = fields[index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let objectOID = cleanField(fields[index + 1])
            let peeledOID = cleanField(fields[index + 2])
            let oid = peeledOID.isEmpty ? objectOID : peeledOID
            let headMarker = fields[index + 3]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let upstreamFullName = cleanField(fields[index + 4])
            let upstreamShortName = cleanField(fields[index + 5])
            let upstreamRemoteName = cleanField(fields[index + 6])
            let upstreamRemoteRef = cleanField(fields[index + 7])
            let upstreamTrack = cleanField(fields[index + 8])
            index += 9

            guard let kind = referenceKind(fullName), !oid.isEmpty else { continue }
            references.append(
                GitReference(
                    repositoryID: repository.id,
                    fullName: fullName,
                    shortName: shortReferenceName(fullName, kind: kind),
                    targetOID: oid,
                    kind: kind,
                    isCurrent: headMarker == "*",
                    tracking: branchTracking(
                        kind: kind,
                        upstreamFullName: upstreamFullName,
                        upstreamShortName: upstreamShortName,
                        remoteName: upstreamRemoteName,
                        remoteRef: upstreamRemoteRef,
                        track: upstreamTrack
                    )
                )
            )
        }

        return references.sorted {
            if $0.kind != $1.kind {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            if $0.isCurrent != $1.isCurrent {
                return $0.isCurrent
            }
            return $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
        }
    }

    private func branchTracking(
        kind: GitReference.Kind,
        upstreamFullName: String,
        upstreamShortName: String,
        remoteName: String,
        remoteRef: String,
        track: String
    ) -> GitBranchTracking? {
        guard kind == .local, !upstreamFullName.isEmpty else { return nil }

        var aheadCount = 0
        var behindCount = 0
        for component in track.split(separator: ",") {
            let fields = component.split(whereSeparator: \.isWhitespace)
            guard let label = fields.first,
                  let value = fields.last.flatMap({ Int($0) }) else {
                continue
            }
            switch label {
            case "ahead": aheadCount = value
            case "behind": behindCount = value
            default: break
            }
        }

        return GitBranchTracking(
            upstreamFullName: upstreamFullName,
            upstreamShortName: upstreamShortName,
            remoteName: remoteName,
            remoteRef: remoteRef,
            aheadCount: aheadCount,
            behindCount: behindCount,
            isGone: track == "gone"
        )
    }

    private func loadCommits(
        repository: GitRepository,
        references: [GitReference],
        headOID: String?,
        revision: String,
        commitLimit: Int,
        pathFilter: String?
    ) async throws -> [GitCommit] {
        var arguments = [
            "-c", "color.ui=false",
            "log", revision, "--topo-order", "--parents", "--no-show-signature",
            "--max-count=\(commitLimit)",
            "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%cI%x00%s%x00%B%x00"
        ]
        if let pathFilter, !pathFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append("--")
            arguments.append(pathFilter)
        }

        let data = try await runner.runData(
            repositoryURL: repository.rootURL,
            arguments: arguments,
            maximumBytes: 24_000_000
        )
        let fields = splitNullTerminated(data)
        let referencesByOID = Dictionary(grouping: references, by: \.targetOID)
        var commits: [GitCommit] = []
        var index = 0

        while index + 7 < fields.count {
            let oid = cleanField(fields[index])
            let parents = cleanField(fields[index + 1])
                .split(separator: " ")
                .map(String.init)
            let authorName = fields[index + 2]
            let authorEmail = fields[index + 3]
            let authorDate = parseISODate(cleanField(fields[index + 4]))
            let committerDate = parseISODate(cleanField(fields[index + 5]))
            let subject = fields[index + 6]
            let body = fields[index + 7]
            index += 8

            guard !oid.isEmpty else { continue }
            commits.append(
                GitCommit(
                    id: CommitID(repositoryID: repository.id, oid: oid),
                    parentOIDs: parents,
                    subject: subject,
                    body: body,
                    authorName: authorName,
                    authorEmail: authorEmail,
                    authorDate: authorDate,
                    committerDate: committerDate,
                    references: referencesByOID[oid] ?? [],
                    isHead: oid == headOID,
                    isWorkingTree: false
                )
            )
        }

        return commits
    }

    func mergeTopologicalStreams(_ streams: [[GitCommit]]) -> [GitCommit] {
        var indices = Array(repeating: 0, count: streams.count)
        var result: [GitCommit] = []
        result.reserveCapacity(streams.reduce(0) { $0 + $1.count })

        while true {
            var selectedStream: Int?
            var selectedDate = Date.distantPast

            for streamIndex in streams.indices {
                let commitIndex = indices[streamIndex]
                guard commitIndex < streams[streamIndex].count else { continue }
                let candidate = streams[streamIndex][commitIndex]
                if selectedStream == nil || candidate.committerDate > selectedDate {
                    selectedStream = streamIndex
                    selectedDate = candidate.committerDate
                }
            }

            guard let selectedStream else { break }
            result.append(streams[selectedStream][indices[selectedStream]])
            indices[selectedStream] += 1
        }

        return result
    }

    func parseChangedFiles(_ data: Data) -> [ChangedFile] {
        let fields = splitNullTerminated(data)
        var files: [ChangedFile] = []
        var index = 0

        while index < fields.count {
            let status = cleanField(fields[index])
            index += 1
            guard !status.isEmpty, index < fields.count else { continue }

            let firstPath = fields[index]
            index += 1
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index < fields.count else { break }
                let secondPath = fields[index]
                index += 1
                files.append(
                    ChangedFile(
                        status: status,
                        path: "\(firstPath) → \(secondPath)",
                        diffPaths: [firstPath, secondPath]
                    )
                )
            } else {
                files.append(
                    ChangedFile(status: status, path: firstPath, diffPaths: [firstPath])
                )
            }
        }

        return files
    }

    func parseWorkingTreeFiles(_ data: Data) -> [ChangedFile] {
        let fields = splitNullTerminated(data)
        var files: [ChangedFile] = []
        var index = 0

        while index < fields.count {
            let record = fields[index]
            index += 1
            guard record.count >= 3 else { continue }

            let statusEnd = record.index(record.startIndex, offsetBy: 2)
            let pathStart = record.index(after: statusEnd)
            let status = String(record[..<statusEnd])
                .trimmingCharacters(in: .whitespaces)
            let currentPath = String(record[pathStart...])
            guard !status.isEmpty, !currentPath.isEmpty else { continue }

            if status.contains("R") || status.contains("C") {
                guard index < fields.count else { break }
                let originalPath = fields[index]
                index += 1
                files.append(
                    ChangedFile(
                        status: status,
                        path: "\(originalPath) → \(currentPath)",
                        diffPaths: [originalPath, currentPath]
                    )
                )
            } else {
                files.append(
                    ChangedFile(status: status, path: currentPath, diffPaths: [currentPath])
                )
            }
        }

        return files
    }

    private func splitNullTerminated(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    private func cleanField(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git 의 `%aI`·`%cI` 는 `2026-07-27T11:34:39+09:00` 고정 폭이라 직접 잘라 읽는다.
    ///
    /// `ISO8601DateFormatter` 로 같은 일을 하면 열 배 넘게 느리고, 커밋 수만큼 반복되므로
    /// 워크스페이스 로딩 시간의 대부분을 차지한다. 형식이 어긋나면 포매터에 맡긴다.
    func parseISODate(_ value: String) -> Date {
        if let date = fixedWidthISODate(value) {
            return date
        }
        return isoFormatter.date(from: value) ?? .distantPast
    }

    private func fixedWidthISODate(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 25,
              bytes[4] == UInt8(ascii: "-"),
              bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"),
              bytes[22] == UInt8(ascii: ":") else {
            return nil
        }

        let sign: Int
        switch bytes[19] {
        case UInt8(ascii: "+"): sign = 1
        case UInt8(ascii: "-"): sign = -1
        default: return nil
        }

        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let digit = bytes[index]
                guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
                result = result * 10 + Int(digit - UInt8(ascii: "0"))
            }
            return result
        }

        guard let year = number(0..<4),
              let month = number(5..<7),
              let day = number(8..<10),
              let hour = number(11..<13),
              let minute = number(14..<16),
              let second = number(17..<19),
              let offsetHour = number(20..<22),
              let offsetMinute = number(23..<25) else {
            return nil
        }

        // `Calendar.date(from:)` 은 2월 31일을 3월로 넘겨 없는 날짜에서도 값을 만들어 낸다.
        // 폴백 포매터는 그런 입력을 거절하므로, 같은 문자열이 어느 경로를 타느냐에 따라
        // 결과가 갈리지 않도록 여기서 먼저 걸러 포매터에 넘긴다. git 이 이런 날짜를 내지는
        // 않지만, 손상된 입력이 조용히 그럴듯한 날짜로 둔갑하는 편보다 낫다.
        guard month >= 1, month <= 12,
              day >= 1, day <= Self.daysInMonth(year: year, month: month),
              hour <= 23,
              minute <= 59,
              second <= 59,
              offsetHour <= 23,
              offsetMinute <= 59 else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let timeZone = TimeZone(
            secondsFromGMT: sign * (offsetHour * 3_600 + offsetMinute * 60)
        ) else {
            return nil
        }
        components.timeZone = timeZone
        return gregorianCalendar.date(from: components)
    }

    /// 그레고리력의 달 길이. 커밋 수만큼 불리는 자리라 `Calendar` 를 거치지 않고 계산한다.
    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private func referenceKind(_ fullName: String) -> GitReference.Kind? {
        if fullName.hasPrefix("refs/heads/") { return .local }
        if fullName.hasPrefix("refs/remotes/") { return .remote }
        if fullName.hasPrefix("refs/tags/") { return .tag }
        return nil
    }

    private func shortReferenceName(_ fullName: String, kind: GitReference.Kind) -> String {
        switch kind {
        case .local:
            return String(fullName.dropFirst("refs/heads/".count))
        case .remote:
            return String(fullName.dropFirst("refs/remotes/".count))
        case .tag:
            return String(fullName.dropFirst("refs/tags/".count))
        }
    }
}
