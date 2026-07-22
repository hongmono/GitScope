import Foundation

actor GitRepositoryLoader {
    private let runner = GitCommandRunner()
    private let scanner = RepositoryScanner()
    private let isoFormatter = ISO8601DateFormatter()

    init() {
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
        let repositoryURLs = Array(
            Set(
                rootURLs.flatMap { scanner.scan(rootURL: $0) }
                    .map(\.standardizedFileURL)
            )
        ).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !repositoryURLs.isEmpty else {
            throw GitCommandError.launchFailed("선택한 위치에서 Git 저장소를 찾지 못했습니다.")
        }

        var snapshots: [RepositorySnapshot] = []
        var seenRepositoryIDs = Set<RepositoryID>()
        for repositoryURL in repositoryURLs {
            let repository = try await makeRepository(
                url: repositoryURL,
                colorIndex: snapshots.count
            )
            guard seenRepositoryIDs.insert(repository.id).inserted else { continue }
            let references = try await loadReferences(repository: repository)
            let commits = try await loadCommits(
                repository: repository,
                references: references,
                revision: "--all",
                commitLimit: commitLimit,
                pathFilter: pathFilter
            )
            snapshots.append(
                RepositorySnapshot(
                    repository: repository,
                    references: references,
                    commits: commits
                )
            )
        }

        let commits = mergeTopologicalStreams(snapshots.map(\.commits))
        return WorkspaceSnapshot(
            repositories: snapshots.map(\.repository),
            referencesByRepository: Dictionary(
                uniqueKeysWithValues: snapshots.map { ($0.repository.id, $0.references) }
            ),
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
        let text = try await runner.runText(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "rev-list", "--max-count=\(limit)", revision
            ]
        )

        return Set(
            text.split(whereSeparator: \.isNewline).map {
                CommitID(repositoryID: repository.id, oid: String($0))
            }
        )
    }

    func loadDetails(commit: GitCommit, repository: GitRepository) async throws -> CommitDetails {
        let fileData = try await runner.runData(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "show", "--format=", "--name-status", "-z",
                "--find-renames", "--find-copies",
                "--no-ext-diff", "--no-textconv", commit.id.oid
            ],
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
        try await runner.runText(
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

    private func makeRepository(url: URL, colorIndex: Int) async throws -> GitRepository {
        let topLevel = try await runner.runText(
            repositoryURL: url,
            arguments: ["rev-parse", "--show-toplevel"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedURL = URL(fileURLWithPath: topLevel).standardizedFileURL
        return GitRepository(
            id: RepositoryID(rawValue: normalizedURL.path),
            name: normalizedURL.lastPathComponent,
            rootURL: normalizedURL,
            colorIndex: colorIndex
        )
    }

    private func loadReferences(repository: GitRepository) async throws -> [GitReference] {
        let data = try await runner.runData(
            repositoryURL: repository.rootURL,
            arguments: [
                "-c", "color.ui=false",
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(HEAD)%00",
                "refs/heads", "refs/remotes", "refs/tags"
            ],
            maximumBytes: 3_000_000
        )

        let fields = splitNullTerminated(data)
        var references: [GitReference] = []
        var index = 0
        while index + 3 < fields.count {
            let fullName = fields[index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let objectOID = cleanField(fields[index + 1])
            let peeledOID = cleanField(fields[index + 2])
            let oid = peeledOID.isEmpty ? objectOID : peeledOID
            let headMarker = fields[index + 3]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index += 4

            guard let kind = referenceKind(fullName), !oid.isEmpty else { continue }
            references.append(
                GitReference(
                    repositoryID: repository.id,
                    fullName: fullName,
                    shortName: shortReferenceName(fullName, kind: kind),
                    targetOID: oid,
                    kind: kind,
                    isCurrent: headMarker == "*"
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

    private func loadCommits(
        repository: GitRepository,
        references: [GitReference],
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
                    references: referencesByOID[oid] ?? []
                )
            )
        }

        return commits
    }

    private func mergeTopologicalStreams(_ streams: [[GitCommit]]) -> [GitCommit] {
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

    private func parseChangedFiles(_ data: Data) -> [ChangedFile] {
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

    private func splitNullTerminated(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    private func cleanField(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseISODate(_ value: String) -> Date {
        if let date = isoFormatter.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: value) ?? .distantPast
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
