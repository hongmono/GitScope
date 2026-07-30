import XCTest

/// rebase · fast-forward pull · publish · 삭제에 대한 통합 테스트.
///
/// 파싱만 검증하는 다른 테스트와 달리 임시 디렉터리에 실제 git 저장소를 만들어 명령을
/// 그대로 돌린다. 이 기능들의 위험한 부분(충돌 시 저장소가 중간 상태로 남는지, `-d` 가
/// 미병합을 어떻게 알리는지)은 git 의 실제 동작에 달려 있어 흉내로는 확인할 수 없다.
final class GitBranchOperationsTests: XCTestCase {
    private var sandboxURL: URL!
    private var branchService: GitBranchService!
    private var remoteService: GitRemoteService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitscope-branch-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
        branchService = GitBranchService()
        remoteService = GitRemoteService()
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
        sandboxURL = nil
        branchService = nil
        remoteService = nil
        try super.tearDownWithError()
    }

    // MARK: - rebase

    func testRebaseReplaysCurrentBranchOntoTarget() async throws {
        let repository = try makeRepository("solo")
        try commitFile("base.txt", contents: "base", in: repository)
        try git(["branch", "topic"], in: repository)
        try commitFile("main-only.txt", contents: "main", in: repository)
        try git(["checkout", "topic"], in: repository)
        try commitFile("topic-only.txt", contents: "topic", in: repository)

        try await branchService.rebase(
            repository: repository,
            ontoReference: localReference("main", in: repository)
        )

        // rebase 뒤 topic 은 main 을 조상으로 갖고, 자기 커밋은 그 위에 다시 얹힌다.
        try assertAncestor("main", of: "topic", in: repository)
        XCTAssertEqual(
            try gitOutput(["log", "--format=%s", "-1"], in: repository),
            "add topic-only.txt"
        )
        XCTAssertFalse(try isRebaseDirectoryPresent(in: repository))
    }

    func testRebaseConflictAbortsAndLeavesRepositoryClean() async throws {
        let repository = try makeRepository("conflict")
        try commitFile("shared.txt", contents: "base\n", in: repository)
        try git(["branch", "topic"], in: repository)
        try commitFile("shared.txt", contents: "main side\n", in: repository)
        try git(["checkout", "topic"], in: repository)
        try commitFile("shared.txt", contents: "topic side\n", in: repository)
        let topicHeadBeforeRebase = try gitOutput(["rev-parse", "HEAD"], in: repository)

        do {
            try await branchService.rebase(
                repository: repository,
                ontoReference: localReference("main", in: repository)
            )
            XCTFail("충돌하는 rebase 가 성공해서는 안 된다")
        } catch let error as GitBranchServiceError {
            guard case .rebaseAborted = error else {
                return XCTFail("rebaseAborted 를 기대했지만 \(error) 를 받았다")
            }
        }

        // 저장소가 rebase 중간 상태로 남지 않는 것이 이 기능의 핵심 제약이다.
        XCTAssertFalse(try isRebaseDirectoryPresent(in: repository))
        XCTAssertEqual(
            try gitOutput(["symbolic-ref", "--short", "HEAD"], in: repository),
            "topic"
        )
        XCTAssertEqual(
            try gitOutput(["rev-parse", "HEAD"], in: repository),
            topicHeadBeforeRebase
        )
        XCTAssertEqual(try gitOutput(["status", "--porcelain"], in: repository), "")
        XCTAssertEqual(
            try String(contentsOf: repository.rootURL.appendingPathComponent("shared.txt")),
            "topic side\n"
        )
    }

    func testRebaseRejectsDetachedHead() async throws {
        let repository = try makeRepository("detached")
        try commitFile("base.txt", contents: "base", in: repository)
        try git(["branch", "topic"], in: repository)
        try commitFile("main-only.txt", contents: "main", in: repository)
        try git(["checkout", "--detach", "HEAD"], in: repository)

        do {
            try await branchService.rebase(
                repository: repository,
                ontoReference: localReference("topic", in: repository)
            )
            XCTFail("detached HEAD 에서 rebase 가 성공해서는 안 된다")
        } catch let error as GitBranchServiceError {
            guard case .detachedHead = error else {
                return XCTFail("detachedHead 를 기대했지만 \(error) 를 받았다")
            }
        }
    }

    func testRebaseRejectsCurrentBranchAsTarget() async throws {
        let repository = try makeRepository("self-rebase")
        try commitFile("base.txt", contents: "base", in: repository)

        do {
            try await branchService.rebase(
                repository: repository,
                ontoReference: localReference("main", in: repository, isCurrent: true)
            )
            XCTFail("자기 자신 위로 rebase 가 성공해서는 안 된다")
        } catch let error as GitBranchServiceError {
            guard case .rebaseOntoCurrentBranch = error else {
                return XCTFail("rebaseOntoCurrentBranch 를 기대했지만 \(error) 를 받았다")
            }
        }
    }

    // MARK: - fast-forward pull

    func testFastForwardFetchAdvancesBranchThatIsOnlyBehind() async throws {
        let world = try makeRemoteWorld("ff")
        try git(["checkout", "feature"], in: world.publisher)
        try commitFile("feature.txt", contents: "second", in: world.publisher)
        try git(["push", "origin", "feature"], in: world.publisher)
        try git(["fetch", "origin"], in: world.clone)
        let behindOID = try gitOutput(["rev-parse", "feature"], in: world.clone)
        let upstreamOID = try gitOutput(["rev-parse", "origin/feature"], in: world.clone)
        XCTAssertNotEqual(behindOID, upstreamOID)

        try await remoteService.fastForwardFetch(
            repository: world.clone,
            reference: trackedReference("feature", in: world.clone)
        )

        XCTAssertEqual(try gitOutput(["rev-parse", "feature"], in: world.clone), upstreamOID)
    }

    func testFastForwardFetchRejectsDivergedBranch() async throws {
        let world = try makeRemoteWorld("diverged")
        try git(["checkout", "feature"], in: world.publisher)
        try commitFile("feature.txt", contents: "remote side", in: world.publisher)
        try git(["push", "origin", "feature"], in: world.publisher)
        try git(["fetch", "origin"], in: world.clone)
        // 로컬 feature 에도 자기만의 커밋을 얹어 갈라놓는다.
        try git(["checkout", "feature"], in: world.clone)
        try commitFile("local-only.txt", contents: "local", in: world.clone)
        try git(["checkout", "main"], in: world.clone)
        let localOID = try gitOutput(["rev-parse", "feature"], in: world.clone)

        do {
            try await remoteService.fastForwardFetch(
                repository: world.clone,
                reference: trackedReference("feature", in: world.clone)
            )
            XCTFail("갈라진 브랜치의 fast-forward 가 성공해서는 안 된다")
        } catch let error as GitRemoteServiceError {
            guard case .fastForwardUnavailable = error else {
                return XCTFail("fastForwardUnavailable 을 기대했지만 \(error) 를 받았다")
            }
            XCTAssertEqual(
                error.errorDescription?.contains("체크아웃 후 Pull(Rebase)"),
                true
            )
        }

        // 실패해도 로컬 브랜치는 그대로다.
        XCTAssertEqual(try gitOutput(["rev-parse", "feature"], in: world.clone), localOID)
    }

    func testFastForwardFetchRejectsCheckedOutBranch() async throws {
        let world = try makeRemoteWorld("ff-current")
        try git(["checkout", "feature"], in: world.clone)

        do {
            try await remoteService.fastForwardFetch(
                repository: world.clone,
                reference: trackedReference("feature", in: world.clone, isCurrent: true)
            )
            XCTFail("체크아웃된 브랜치의 fast-forward 가 성공해서는 안 된다")
        } catch let error as GitRemoteServiceError {
            guard case .checkedOutBranchNotFastForwardable = error else {
                return XCTFail("checkedOutBranchNotFastForwardable 을 기대했지만 \(error) 를 받았다")
            }
        }
    }

    // MARK: - publish

    func testPublishPushesBranchAndSetsUpstream() async throws {
        let world = try makeRemoteWorld("publish")
        try git(["checkout", "-b", "solo"], in: world.clone)
        try commitFile("solo.txt", contents: "solo", in: world.clone)
        try git(["checkout", "main"], in: world.clone)

        try await remoteService.publish(
            repository: world.clone,
            reference: localReference("solo", in: world.clone)
        )

        XCTAssertEqual(
            try gitOutput(["rev-parse", "--abbrev-ref", "solo@{upstream}"], in: world.clone),
            "origin/solo"
        )
        XCTAssertEqual(
            try gitOutput(["rev-parse", "refs/heads/solo"], in: world.bare),
            try gitOutput(["rev-parse", "refs/heads/solo"], in: world.clone)
        )
    }

    func testPublishRejectsBranchThatAlreadyHasUpstream() async throws {
        let world = try makeRemoteWorld("publish-twice")

        do {
            try await remoteService.publish(
                repository: world.clone,
                reference: trackedReference("feature", in: world.clone)
            )
            XCTFail("이미 upstream 이 있는 브랜치의 게시가 성공해서는 안 된다")
        } catch let error as GitRemoteServiceError {
            guard case .upstreamAlreadySet = error else {
                return XCTFail("upstreamAlreadySet 을 기대했지만 \(error) 를 받았다")
            }
        }
    }

    // MARK: - 로컬 브랜치·태그 삭제

    func testDeleteLocalBranchReportsUnmergedBeforeForceDeleting() async throws {
        let repository = try makeRepository("delete-unmerged")
        try commitFile("base.txt", contents: "base", in: repository)
        try git(["checkout", "-b", "topic"], in: repository)
        try commitFile("topic.txt", contents: "topic", in: repository)
        try git(["checkout", "main"], in: repository)

        // `-d` 는 미병합 브랜치를 거절한다. UI 는 이 에러를 받아 재확인 다이얼로그를 띄운다.
        do {
            try await branchService.deleteLocalBranch(
                repository: repository,
                reference: localReference("topic", in: repository),
                force: false
            )
            XCTFail("미병합 브랜치의 `-d` 삭제가 성공해서는 안 된다")
        } catch let error as GitBranchServiceError {
            guard case .branchNotMerged(let name) = error else {
                return XCTFail("branchNotMerged 를 기대했지만 \(error) 를 받았다")
            }
            XCTAssertEqual(name, "topic")
        }
        XCTAssertTrue(try branchExists("topic", in: repository))

        // 재확인을 거친 뒤에야 `-D` 로 넘어간다.
        try await branchService.deleteLocalBranch(
            repository: repository,
            reference: localReference("topic", in: repository),
            force: true
        )
        XCTAssertFalse(try branchExists("topic", in: repository))
    }

    func testDeleteLocalBranchRemovesMergedBranchWithoutForce() async throws {
        let repository = try makeRepository("delete-merged")
        try commitFile("base.txt", contents: "base", in: repository)
        try git(["branch", "merged"], in: repository)

        try await branchService.deleteLocalBranch(
            repository: repository,
            reference: localReference("merged", in: repository),
            force: false
        )

        XCTAssertFalse(try branchExists("merged", in: repository))
    }

    func testDeleteLocalBranchRejectsCurrentBranch() async throws {
        let repository = try makeRepository("delete-current")
        try commitFile("base.txt", contents: "base", in: repository)

        do {
            try await branchService.deleteLocalBranch(
                repository: repository,
                reference: localReference("main", in: repository, isCurrent: true),
                force: true
            )
            XCTFail("체크아웃된 브랜치의 삭제가 성공해서는 안 된다")
        } catch let error as GitBranchServiceError {
            guard case .currentBranchNotDeletable = error else {
                return XCTFail("currentBranchNotDeletable 을 기대했지만 \(error) 를 받았다")
            }
        }
        XCTAssertTrue(try branchExists("main", in: repository))
    }

    func testDeleteLocalTagRemovesOnlyLocalTag() async throws {
        let world = try makeRemoteWorld("tag-local")
        try git(["tag", "v1.0"], in: world.clone)
        try git(["push", "origin", "refs/tags/v1.0"], in: world.clone)

        try await branchService.deleteLocalTag(
            repository: world.clone,
            reference: tagReference("v1.0", in: world.clone)
        )

        XCTAssertEqual(try gitOutput(["tag", "--list", "v1.0"], in: world.clone), "")
        // 원격 태그는 그대로 남아야 한다.
        XCTAssertEqual(
            try gitOutput(["tag", "--list", "v1.0"], in: world.bare),
            "v1.0"
        )
    }

    // MARK: - 원격 삭제

    func testDeleteRemoteBranchRemovesBranchFromRemote() async throws {
        let world = try makeRemoteWorld("delete-remote")
        XCTAssertTrue(try branchExists("feature", in: world.bare))

        try await remoteService.deleteRemoteBranch(
            repository: world.clone,
            reference: remoteReference("origin/feature", in: world.clone)
        )

        XCTAssertFalse(try branchExists("feature", in: world.bare))
        // 로컬 브랜치는 건드리지 않는다.
        XCTAssertTrue(try branchExists("feature", in: world.clone))
    }

    func testDeleteRemoteBranchSplitsRemoteNameAtFirstSlashOnly() async throws {
        let world = try makeRemoteWorld("delete-remote-nested")
        try git(["checkout", "-b", "release/deep/name"], in: world.clone)
        try git(["push", "-u", "origin", "release/deep/name"], in: world.clone)
        try git(["checkout", "main"], in: world.clone)

        try await remoteService.deleteRemoteBranch(
            repository: world.clone,
            reference: remoteReference("origin/release/deep/name", in: world.clone)
        )

        XCTAssertFalse(try branchExists("release/deep/name", in: world.bare))
    }

    func testDeleteRemoteBranchRejectsNameWithoutRemotePrefix() async throws {
        let world = try makeRemoteWorld("delete-remote-flat")

        do {
            try await remoteService.deleteRemoteBranch(
                repository: world.clone,
                reference: remoteReference("feature", in: world.clone)
            )
            XCTFail("원격 이름을 알 수 없는 참조의 삭제가 성공해서는 안 된다")
        } catch let error as GitRemoteServiceError {
            guard case .unsupportedRemoteBranchName = error else {
                return XCTFail("unsupportedRemoteBranchName 을 기대했지만 \(error) 를 받았다")
            }
        }
        XCTAssertTrue(try branchExists("feature", in: world.bare))
    }

    func testDeleteRemoteTagRemovesTagFromRemoteOnly() async throws {
        let world = try makeRemoteWorld("tag-remote")
        try git(["tag", "v2.0"], in: world.clone)
        try git(["push", "origin", "refs/tags/v2.0"], in: world.clone)

        try await remoteService.deleteRemoteTag(repository: world.clone, tagName: "v2.0")

        XCTAssertEqual(try gitOutput(["tag", "--list", "v2.0"], in: world.bare), "")
        XCTAssertEqual(try gitOutput(["tag", "--list", "v2.0"], in: world.clone), "v2.0")
    }

    // MARK: - 저장소 만들기

    /// bare 원격 하나와, 그것을 복제한 작업 저장소 두 개.
    ///
    /// `publisher` 는 원격에 커밋을 밀어 넣어 `clone` 을 뒤처지게 만드는 데 쓴다.
    /// 두 복제본 모두 `main` 을 체크아웃한 채로 시작하고 `feature` 브랜치가 추적 설정과
    /// 함께 준비돼 있다.
    private struct RemoteWorld {
        let bare: GitRepository
        let clone: GitRepository
        let publisher: GitRepository
    }

    private func makeRemoteWorld(_ name: String) throws -> RemoteWorld {
        let bareURL = sandboxURL.appendingPathComponent("\(name)-remote.git")
        try runGit(["init", "--bare", "--initial-branch=main", bareURL.path], in: sandboxURL)
        let bare = makeRepositoryValue(name: "\(name)-remote", rootURL: bareURL)

        let seed = try makeRepository("\(name)-seed")
        try commitFile("base.txt", contents: "base", in: seed)
        try git(["remote", "add", "origin", bareURL.path], in: seed)
        try git(["push", "-u", "origin", "main"], in: seed)
        try git(["checkout", "-b", "feature"], in: seed)
        try commitFile("feature.txt", contents: "first", in: seed)
        try git(["push", "-u", "origin", "feature"], in: seed)

        return RemoteWorld(
            bare: bare,
            clone: try cloneRepository(bareURL, named: "\(name)-clone"),
            publisher: try cloneRepository(bareURL, named: "\(name)-publisher")
        )
    }

    /// 두 브랜치를 모두 추적하도록 복제하고, `main` 을 체크아웃한 채로 돌려준다.
    private func cloneRepository(_ remoteURL: URL, named name: String) throws -> GitRepository {
        let rootURL = sandboxURL.appendingPathComponent(name)
        try runGit(["clone", remoteURL.path, rootURL.path], in: sandboxURL)
        let repository = makeRepositoryValue(name: name, rootURL: rootURL)
        try configureIdentity(in: repository)
        try git(["checkout", "feature"], in: repository)
        try git(["checkout", "main"], in: repository)
        return repository
    }

    private func makeRepository(_ name: String) throws -> GitRepository {
        let rootURL = sandboxURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let repository = makeRepositoryValue(name: name, rootURL: rootURL)
        try git(["init", "--initial-branch=main"], in: repository)
        try configureIdentity(in: repository)
        return repository
    }

    private func makeRepositoryValue(name: String, rootURL: URL) -> GitRepository {
        GitRepository(
            id: RepositoryID(rawValue: rootURL.path),
            name: name,
            rootURL: rootURL,
            colorIndex: 0,
            githubRepository: nil
        )
    }

    /// 실행 환경의 전역 git 설정에 기대지 않도록 저장소마다 신원과 서명 설정을 박아 둔다.
    private func configureIdentity(in repository: GitRepository) throws {
        try git(["config", "user.name", "GitScope Tester"], in: repository)
        try git(["config", "user.email", "tester@example.com"], in: repository)
        try git(["config", "commit.gpgsign", "false"], in: repository)
    }

    private func commitFile(
        _ path: String,
        contents: String,
        in repository: GitRepository
    ) throws {
        try contents.write(
            to: repository.rootURL.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", path], in: repository)
        try git(["commit", "-m", "add \(path)"], in: repository)
    }

    // MARK: - 참조 만들기

    private func localReference(
        _ shortName: String,
        in repository: GitRepository,
        isCurrent: Bool = false
    ) -> GitReference {
        GitReference(
            repositoryID: repository.id,
            fullName: "refs/heads/\(shortName)",
            shortName: shortName,
            targetOID: "",
            kind: .local,
            isCurrent: isCurrent,
            tracking: nil
        )
    }

    private func trackedReference(
        _ shortName: String,
        in repository: GitRepository,
        isCurrent: Bool = false
    ) -> GitReference {
        GitReference(
            repositoryID: repository.id,
            fullName: "refs/heads/\(shortName)",
            shortName: shortName,
            targetOID: "",
            kind: .local,
            isCurrent: isCurrent,
            tracking: GitBranchTracking(
                upstreamFullName: "refs/remotes/origin/\(shortName)",
                upstreamShortName: "origin/\(shortName)",
                remoteName: "origin",
                remoteRef: "refs/heads/\(shortName)",
                aheadCount: 0,
                behindCount: 1,
                isGone: false
            )
        )
    }

    private func remoteReference(
        _ shortName: String,
        in repository: GitRepository
    ) -> GitReference {
        GitReference(
            repositoryID: repository.id,
            fullName: "refs/remotes/\(shortName)",
            shortName: shortName,
            targetOID: "",
            kind: .remote,
            isCurrent: false,
            tracking: nil
        )
    }

    private func tagReference(
        _ shortName: String,
        in repository: GitRepository
    ) -> GitReference {
        GitReference(
            repositoryID: repository.id,
            fullName: "refs/tags/\(shortName)",
            shortName: shortName,
            targetOID: "",
            kind: .tag,
            isCurrent: false,
            tracking: nil
        )
    }

    // MARK: - 저장소 들여다보기

    private func branchExists(_ name: String, in repository: GitRepository) throws -> Bool {
        try gitOutput(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads/\(name)"],
            in: repository
        ) == name
    }

    private func assertAncestor(
        _ ancestor: String,
        of descendant: String,
        in repository: GitRepository,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNoThrow(
            try git(["merge-base", "--is-ancestor", ancestor, descendant], in: repository),
            "\(ancestor) 이 \(descendant) 의 조상이어야 한다",
            file: file,
            line: line
        )
    }

    /// rebase 중간 상태 디렉터리가 남아 있는지. 서비스와 같은 기준으로 본다.
    private func isRebaseDirectoryPresent(in repository: GitRepository) throws -> Bool {
        try ["rebase-merge", "rebase-apply"].contains { stateDirectory in
            let path = try gitOutput(["rev-parse", "--git-path", stateDirectory], in: repository)
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : repository.rootURL.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    // MARK: - git 실행

    @discardableResult
    private func git(_ arguments: [String], in repository: GitRepository) throws -> String {
        try runGit(arguments, in: repository.rootURL)
    }

    private func gitOutput(_ arguments: [String], in repository: GitRepository) throws -> String {
        try runGit(arguments, in: repository.rootURL)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directoryURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directoryURL
        process.arguments = ["--no-pager", "-C", directoryURL.path] + arguments

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
            throw GitFixtureError(
                command: arguments.joined(separator: " "),
                message: message.isEmpty ? output : message
            )
        }
        return output
    }
}

/// 테스트가 저장소를 준비하다 실패했을 때 어떤 명령이 왜 실패했는지 남긴다.
private struct GitFixtureError: LocalizedError {
    let command: String
    let message: String

    var errorDescription: String? {
        "git \(command) 실패: \(message)"
    }
}
