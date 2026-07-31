import XCTest

/// 다중 선택 patch 이어붙이기에 대한 통합 테스트.
///
/// 임시 디렉터리에 실제 저장소를 만들어 `GitRepositoryLoader` 로 커밋과 patch 를 그대로
/// 읽는다. 병합·이어붙이기 규칙이 실제 git 출력(헝크 헤더, rename 경로) 위에서도 성립하는지는
/// 흉내 낸 문자열로는 확인할 수 없다.
final class MultiCommitPatchIntegrationTests: XCTestCase {
    private var sandboxURL: URL!
    private var loader: GitRepositoryLoader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitscope-multi-select-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
        loader = GitRepositoryLoader()
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
        sandboxURL = nil
        loader = nil
        try super.tearDownWithError()
    }

    func testJoinedPatchSeparatesCommitsWithHeadersInOldestFirstOrder() async throws {
        let repository = try makeRepository("joined")
        try commitFile("shared.txt", contents: "one\n", message: "첫 변경", in: repository)
        try commitFile("other.txt", contents: "other\n", message: "무관한 변경", in: repository)
        try commitFile("shared.txt", contents: "one\ntwo\n", message: "두 번째 변경", in: repository)

        let commits = try await loadCommits(in: repository)
        let first = try XCTUnwrap(commits.first { $0.subject == "첫 변경" })
        let second = try XCTUnwrap(commits.first { $0.subject == "두 번째 변경" })

        // 선택 순서는 목록 순서(최신 먼저)로 넣어도 합집합은 오래된 순으로 정렬돼야 한다.
        let merged = MergedChangedFile.merge([
            try await loader.loadDetails(commit: second, repository: repository),
            try await loader.loadDetails(commit: first, repository: repository)
        ])

        let sharedFile = try XCTUnwrap(merged.first { $0.path == "shared.txt" })
        XCTAssertEqual(sharedFile.commits.map(\.id.oid), [first.id.oid, second.id.oid])
        XCTAssertEqual(sharedFile.statuses, ["A", "M"])
        XCTAssertEqual(sharedFile.representativeStatus, "M")
        // 두 커밋 사이의 무관한 커밋은 합집합에 들어오지 않는다(범위 diff 가 아니다).
        XCTAssertEqual(merged.map(\.path), ["shared.txt"])

        let joined = CommitPatchSection.join(
            try await patchSections(for: sharedFile, in: repository),
            showsCommitHeaders: true
        )
        let lines = DiffLine.parse(joined)
        let headers = lines.filter { $0.kind == .commitHeader }
        XCTAssertEqual(headers.map(\.text), [
            "― \(first.shortOID) 첫 변경",
            "― \(second.shortOID) 두 번째 변경"
        ])
        // 각 patch 는 자기 헤더 뒤에 온다. 첫 커밋은 파일 생성, 두 번째는 한 줄 추가다.
        let firstHeaderIndex = try XCTUnwrap(lines.firstIndex { $0.kind == .commitHeader })
        let secondHeaderIndex = try XCTUnwrap(lines.lastIndex { $0.kind == .commitHeader })
        let firstSection = lines[firstHeaderIndex..<secondHeaderIndex]
        let secondSection = lines[secondHeaderIndex...]
        XCTAssertTrue(firstSection.contains { $0.kind == .addition && $0.text == "+one" })
        XCTAssertFalse(firstSection.contains { $0.kind == .addition && $0.text == "+two" })
        XCTAssertTrue(secondSection.contains { $0.kind == .addition && $0.text == "+two" })
    }

    func testSingleCommitPatchKeepsNoCommitHeader() async throws {
        let repository = try makeRepository("single")
        try commitFile("only.txt", contents: "one\n", message: "단일 커밋", in: repository)

        let commits = try await loadCommits(in: repository)
        let only = try XCTUnwrap(commits.first { $0.subject == "단일 커밋" })
        let merged = MergedChangedFile.merge([
            try await loader.loadDetails(commit: only, repository: repository)
        ])
        let file = try XCTUnwrap(merged.first)

        let sections = try await patchSections(for: file, in: repository)
        let joined = CommitPatchSection.join(sections, showsCommitHeaders: false)

        XCTAssertEqual(joined, sections[0].patch)
        XCTAssertFalse(DiffLine.parse(joined).contains { $0.kind == .commitHeader })
    }

    /// rename 은 경로 자체가 바뀌는 변경이라 "old → new" 라는 한 항목으로 남는다.
    ///
    /// 합집합의 키는 표시 경로이므로 rename 뒤의 수정과 같은 항목으로 합쳐지지 않는다.
    /// 커밋을 가로질러 rename 을 추적하는 것은 이 기능의 범위 밖이고, 항목이 갈려도
    /// 커밋별 diff 경로가 그대로 남아 patch 는 정상적으로 뽑힌다.
    func testMergeKeepsRenameAsItsOwnEntryWithBothDiffPaths() async throws {
        let repository = try makeRepository("rename")
        try commitFile("old.txt", contents: renameSafeContents, message: "원본 추가", in: repository)
        try git(["mv", "old.txt", "new.txt"], in: repository)
        try git(["commit", "-m", "이름 변경"], in: repository)
        try commitFile(
            "new.txt",
            contents: renameSafeContents + "tail\n",
            message: "이름 변경 뒤 수정",
            in: repository
        )

        let commits = try await loadCommits(in: repository)
        let renamed = try XCTUnwrap(commits.first { $0.subject == "이름 변경" })
        let edited = try XCTUnwrap(commits.first { $0.subject == "이름 변경 뒤 수정" })

        let merged = MergedChangedFile.merge([
            try await loader.loadDetails(commit: renamed, repository: repository),
            try await loader.loadDetails(commit: edited, repository: repository)
        ])

        XCTAssertEqual(merged.map(\.path), ["new.txt", "old.txt → new.txt"])

        let renameFile = try XCTUnwrap(merged.first { $0.path == "old.txt → new.txt" })
        XCTAssertEqual(renameFile.commits.map(\.id.oid), [renamed.id.oid])
        // rename 커밋은 diff 경로가 둘(원본·대상)이라 커밋별 원본 항목을 그대로 들고 있어야 한다.
        XCTAssertEqual(
            renameFile.changedFilesByCommit[renamed.id]?.diffPaths,
            ["old.txt", "new.txt"]
        )

        let editFile = try XCTUnwrap(merged.first { $0.path == "new.txt" })
        XCTAssertEqual(editFile.commits.map(\.id.oid), [edited.id.oid])

        // 커밋별 경로로 뽑으므로 어느 쪽도 빈 patch 가 되지 않는다.
        for file in [renameFile, editFile] {
            let sections = try await patchSections(for: file, in: repository)
            XCTAssertEqual(sections.count, 1)
            XCTAssertFalse(sections[0].patch.isEmpty)
        }
    }

    // MARK: - 도우미

    /// 앱과 같은 경로로 patch 를 뽑는다(커밋별 원본 항목 + 오래된 순).
    private func patchSections(
        for file: MergedChangedFile,
        in repository: GitRepository
    ) async throws -> [CommitPatchSection] {
        var sections: [CommitPatchSection] = []
        for commit in file.commits {
            let changedFile = try XCTUnwrap(file.changedFilesByCommit[commit.id])
            sections.append(
                CommitPatchSection(
                    commit: commit,
                    patch: try await loader.loadPatch(
                        commit: commit,
                        repository: repository,
                        file: changedFile
                    )
                )
            )
        }
        return sections
    }

    private func loadCommits(in repository: GitRepository) async throws -> [GitCommit] {
        try await loader.loadWorkspacesReport(at: [repository.rootURL]).snapshot.commits
    }

    /// rename 판정(`--find-renames`)이 걸리도록 내용이 어느 정도 있는 파일을 쓴다.
    private var renameSafeContents: String {
        (1...20).map { "line \($0)\n" }.joined()
    }

    // MARK: - 저장소 만들기

    private func makeRepository(_ name: String) throws -> GitRepository {
        let rootURL = sandboxURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let repository = GitRepository(
            id: RepositoryID(rawValue: rootURL.path),
            name: name,
            rootURL: rootURL,
            colorIndex: 0,
            githubRepository: nil
        )
        try git(["init", "--initial-branch=main"], in: repository)
        try git(["config", "user.name", "GitScope Tester"], in: repository)
        try git(["config", "user.email", "tester@example.com"], in: repository)
        try git(["config", "commit.gpgsign", "false"], in: repository)
        return repository
    }

    private func commitFile(
        _ path: String,
        contents: String,
        message: String,
        in repository: GitRepository
    ) throws {
        try contents.write(
            to: repository.rootURL.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", path], in: repository)
        try git(["commit", "-m", message], in: repository)
    }

    @discardableResult
    private func git(_ arguments: [String], in repository: GitRepository) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = repository.rootURL
        process.arguments = ["--no-pager", "-C", repository.rootURL.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        // 검사자의 전역 설정(템플릿, 훅, 기본 브랜치 이름)이 결과를 흔들지 않게 한다.
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw MultiCommitFixtureError(
                command: arguments.joined(separator: " "),
                message: message.isEmpty ? output : message
            )
        }
        return output
    }
}

private struct MultiCommitFixtureError: LocalizedError {
    let command: String
    let message: String

    var errorDescription: String? {
        "git \(command) 실패: \(message)"
    }
}
