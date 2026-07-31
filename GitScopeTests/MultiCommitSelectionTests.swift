import XCTest

/// 커밋 다중 선택의 순수 로직 — 변경 파일 합집합 병합과 선택 정규화.
final class MultiCommitSelectionTests: XCTestCase {
    private let otherRepositoryID = RepositoryID(rawValue: "/tmp/fixture-other")

    // MARK: - 합집합 병합

    func testMergeTakesUnionOfChangedFiles() {
        let merged = MergedChangedFile.merge([
            details(commit("aaa", at: 100), files: [file("M", "a.swift")]),
            details(commit("bbb", at: 200), files: [file("A", "b.swift")])
        ])

        XCTAssertEqual(merged.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(merged.map(\.commits.count), [1, 1])
    }

    func testMergeCombinesSameFileFromMultipleCommitsInOldestFirstOrder() {
        // 입력은 히스토리 순서(최신 먼저)로 넣어도 커밋은 오래된 순으로 정렬돼야 한다.
        let merged = MergedChangedFile.merge([
            details(commit("new", at: 300), files: [file("M", "shared.swift")]),
            details(commit("old", at: 100), files: [file("A", "shared.swift")]),
            details(commit("mid", at: 200), files: [file("M", "shared.swift")])
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].commits.map(\.id.oid), ["old", "mid", "new"])
    }

    func testMergeFallsBackToListOrderForCommitsSharingATimestamp() {
        // 빠르게 이어진 커밋은 초 단위가 같아진다. 그때는 목록 순서(최신이 위)를 뒤집어 쓴다.
        let merged = MergedChangedFile.merge([
            details(commit("newer", at: 100), files: [file("M", "shared.swift")]),
            details(commit("older", at: 100), files: [file("A", "shared.swift")])
        ])

        XCTAssertEqual(merged[0].commits.map(\.id.oid), ["older", "newer"])
        XCTAssertEqual(merged[0].statuses, ["A", "M"])
        XCTAssertEqual(merged[0].representativeStatus, "M")
    }

    func testMergeKeepsDistinctStatusesAndUsesLastCommitStatusAsRepresentative() {
        let merged = MergedChangedFile.merge([
            details(commit("old", at: 100), files: [file("M", "shared.swift")]),
            details(commit("mid", at: 200), files: [file("D", "shared.swift")]),
            details(commit("new", at: 300), files: [file("M", "shared.swift")])
        ])

        XCTAssertEqual(merged.count, 1)
        // 중복은 지우되 처음 나온 차례를 지킨다. 대표 상태는 그 목록의 마지막이 아니라
        // 마지막 커밋의 상태다.
        XCTAssertEqual(merged[0].statuses, ["M", "D"])
        XCTAssertEqual(merged[0].representativeStatus, "M")
        XCTAssertEqual(merged[0].statusTooltip, "커밋별 상태 — M, D")
    }

    func testMergeHidesStatusTooltipWhenStatusNeverChanges() {
        let merged = MergedChangedFile.merge([
            details(commit("old", at: 100), files: [file("M", "shared.swift")]),
            details(commit("new", at: 200), files: [file("M", "shared.swift")])
        ])

        XCTAssertNil(merged[0].statusTooltip)
        XCTAssertEqual(merged[0].representativeStatus, "M")
    }

    func testMergeGroupsFilesByRepositoryInSelectionOrder() {
        let merged = MergedChangedFile.merge([
            details(
                commit("other", at: 100, repositoryID: otherRepositoryID),
                files: [file("M", "z.swift"), file("A", "a.swift")]
            ),
            details(commit("main", at: 200), files: [file("M", "m.swift")])
        ])

        // 저장소는 처음 나온 차례를 지키고, 저장소 안에서는 경로 이름순이다.
        XCTAssertEqual(merged.map(\.repositoryID), [
            otherRepositoryID, otherRepositoryID, TestFixtures.repositoryID
        ])
        XCTAssertEqual(merged.map(\.path), ["a.swift", "z.swift", "m.swift"])
    }

    func testMergeKeepsPerCommitChangedFileForPatchLoading() {
        // rename 은 커밋마다 diff 경로가 다르므로 커밋별 원본 항목을 그대로 들고 있어야 한다.
        let renamed = ChangedFile(
            status: "R100",
            path: "new.swift",
            diffPaths: ["old.swift", "new.swift"]
        )
        let merged = MergedChangedFile.merge([
            details(commit("old", at: 100), files: [renamed]),
            details(commit("new", at: 200), files: [file("M", "new.swift")])
        ])

        XCTAssertEqual(merged.count, 1)
        let first = commitID("old")
        XCTAssertEqual(merged[0].changedFilesByCommit[first]?.diffPaths, ["old.swift", "new.swift"])
        XCTAssertEqual(merged[0].changedFilesByCommit[commitID("new")]?.diffPaths, ["new.swift"])
    }

    func testMergeReturnsEmptyForEmptySelection() {
        XCTAssertTrue(MergedChangedFile.merge([]).isEmpty)
    }

    // MARK: - 선택 정규화

    func testNormalizeOrdersSelectionByRowOrder() {
        let first = commit("aaa", at: 300)
        let second = commit("bbb", at: 200)
        let third = commit("ccc", at: 100)

        let normalized = CommitSelection.normalize(
            [third, first, second],
            rowOrder: [first.id, second.id, third.id]
        )

        XCTAssertEqual(normalized.map(\.id.oid), ["aaa", "bbb", "ccc"])
    }

    func testNormalizeCollapsesToWorkingTreeCommitWhenIncluded() {
        let working = workingTreeCommit()
        let regular = commit("aaa", at: 100)

        XCTAssertEqual(
            CommitSelection.normalize([regular, working], rowOrder: [working.id, regular.id])
                .map(\.id.oid),
            ["WORKTREE"]
        )
        XCTAssertEqual(
            CommitSelection.normalize([working, regular], rowOrder: [working.id, regular.id])
                .map(\.id.oid),
            ["WORKTREE"]
        )
    }

    func testNormalizeReturnsEmptyForEmptySelection() {
        XCTAssertTrue(CommitSelection.normalize([], rowOrder: [CommitID]()).isEmpty)
    }

    func testNormalizeKeepsCommitsMissingFromRowOrderAtTheEnd() {
        let visible = commit("aaa", at: 200)
        let filtered = commit("zzz", at: 100)

        let normalized = CommitSelection.normalize(
            [filtered, visible],
            rowOrder: [visible.id]
        )

        XCTAssertEqual(normalized.map(\.id.oid), ["aaa", "zzz"])
    }

    func testNormalizeRemovesDuplicateCommits() {
        let duplicated = commit("aaa", at: 100)

        XCTAssertEqual(
            CommitSelection.normalize(
                [duplicated, duplicated],
                rowOrder: [duplicated.id]
            ).count,
            1
        )
    }

    // MARK: - 조용한 갱신 뒤 선택 복원

    func testRestorableKeepsOnlySurvivingCommitsInOriginalOrder() {
        let kept = commit("aaa", at: 300)
        let disappeared = commit("bbb", at: 200)
        let alsoKept = commit("ccc", at: 100)

        let restored = CommitSelection.restorable(
            commitIDs: [kept.id, disappeared.id, alsoKept.id],
            survivingIDs: [kept.id, alsoKept.id],
            in: [alsoKept, kept]
        )

        XCTAssertEqual(restored.map(\.id.oid), ["aaa", "ccc"])
    }

    func testRestorableUsesFreshlyLoadedCommitInstances() {
        let stale = commit("aaa", at: 100)
        let refreshed = GitCommit(
            id: stale.id,
            parentOIDs: stale.parentOIDs,
            subject: stale.subject,
            body: stale.body,
            authorName: stale.authorName,
            authorEmail: stale.authorEmail,
            authorDate: stale.authorDate,
            committerDate: stale.committerDate,
            references: [TestFixtures.reference("main")],
            isHead: true,
            isWorkingTree: false
        )

        let restored = CommitSelection.restorable(
            commitIDs: [stale.id],
            survivingIDs: [stale.id],
            in: [refreshed]
        )

        XCTAssertEqual(restored.first?.references.map(\.shortName), ["main"])
        XCTAssertEqual(restored.first?.isHead, true)
    }

    func testRestorableReturnsEmptyWhenEveryCommitDisappeared() {
        let gone = commit("aaa", at: 100)

        XCTAssertTrue(
            CommitSelection.restorable(
                commitIDs: [gone.id],
                survivingIDs: [],
                in: [gone]
            ).isEmpty
        )
    }

    // MARK: - patch 이어붙이기

    func testJoinAddsCommitHeaderBeforeEachPatch() {
        let older = commit("aaa", at: 100)
        let newer = commit("bbb", at: 200)

        let joined = CommitPatchSection.join(
            [
                CommitPatchSection(commit: older, patch: "@@ -0,0 +1 @@\n+one"),
                CommitPatchSection(commit: newer, patch: "@@ -1 +1,2 @@\n one\n+two")
            ],
            showsCommitHeaders: true
        )

        XCTAssertEqual(joined, """
            ― \(older.shortOID) commit aaa
            @@ -0,0 +1 @@
            +one
            ― \(newer.shortOID) commit bbb
            @@ -1 +1,2 @@
             one
            +two
            """)
    }

    func testJoinKeepsSinglePatchUntouched() {
        let only = commit("aaa", at: 100)
        let patch = "@@ -0,0 +1 @@\n+one"

        XCTAssertEqual(
            CommitPatchSection.join(
                [CommitPatchSection(commit: only, patch: patch)],
                showsCommitHeaders: false
            ),
            patch
        )
    }

    // MARK: - 고정 데이터

    private func commit(
        _ oid: String,
        at timestamp: TimeInterval,
        repositoryID: RepositoryID = TestFixtures.repositoryID
    ) -> GitCommit {
        TestFixtures.commit(
            oid,
            repositoryID: repositoryID,
            committerDate: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func workingTreeCommit() -> GitCommit {
        GitCommit(
            id: CommitID(repositoryID: TestFixtures.repositoryID, oid: "WORKTREE"),
            parentOIDs: [],
            subject: "커밋되지 않은 변경",
            body: "",
            authorName: "",
            authorEmail: "",
            authorDate: Date(timeIntervalSince1970: 400),
            committerDate: Date(timeIntervalSince1970: 400),
            references: [],
            isHead: false,
            isWorkingTree: true
        )
    }

    private func commitID(
        _ oid: String,
        repositoryID: RepositoryID = TestFixtures.repositoryID
    ) -> CommitID {
        CommitID(repositoryID: repositoryID, oid: oid)
    }

    private func file(_ status: String, _ path: String) -> ChangedFile {
        ChangedFile(status: status, path: path, diffPaths: [path])
    }

    private func details(_ commit: GitCommit, files: [ChangedFile]) -> CommitDetails {
        CommitDetails(commit: commit, files: files)
    }
}
