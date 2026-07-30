import XCTest

/// 사이드바와 브랜치 범위 필터가 함께 쓰는 참조 모델 규칙에 대한 테스트.
///
/// 폴더 트리 구성과 pull/push 대상 판단은 뷰에서 모델로 올라온 뒤로 뷰를 띄우지 않고
/// 검증할 수 있다.
final class ReferenceModelTests: XCTestCase {

    // MARK: - ReferenceFolder.make

    func testTreeKeepsFlatNamesAtRoot() {
        let folder = ReferenceFolder.make(groups: [
            localGroup("main"),
            localGroup("develop")
        ])

        XCTAssertTrue(folder.children.isEmpty)
        XCTAssertEqual(folder.references.map(\.shortName), ["develop", "main"])
    }

    func testTreeNestsBySlashComponents() {
        let folder = ReferenceFolder.make(groups: [
            remoteGroup("origin/feature/login"),
            remoteGroup("origin/main")
        ])

        XCTAssertTrue(folder.references.isEmpty)
        XCTAssertEqual(folder.children.map(\.name), ["origin"])

        let origin = folder.children[0]
        XCTAssertEqual(origin.path, "origin")
        XCTAssertEqual(origin.references.map(\.shortName), ["origin/main"])
        XCTAssertEqual(origin.children.map(\.name), ["feature"])

        let feature = origin.children[0]
        XCTAssertEqual(feature.path, "origin/feature")
        XCTAssertEqual(feature.references.map(\.shortName), ["origin/feature/login"])
        XCTAssertTrue(feature.children.isEmpty)
    }

    func testTreeSortsFoldersAndReferencesByLocalizedStandardOrder() {
        let folder = ReferenceFolder.make(groups: [
            localGroup("release/v10"),
            localGroup("release/v9"),
            localGroup("feature/b"),
            localGroup("feature/a")
        ])

        XCTAssertEqual(folder.children.map(\.name), ["feature", "release"])
        XCTAssertEqual(
            folder.children[0].references.map(\.shortName),
            ["feature/a", "feature/b"]
        )
        // localizedStandardCompare 는 숫자를 자릿수가 아니라 값으로 견준다.
        XCTAssertEqual(
            folder.children[1].references.map(\.shortName),
            ["release/v9", "release/v10"]
        )
    }

    func testEmptyTreeReportsItself() {
        XCTAssertTrue(ReferenceFolder.make(groups: []).isEmpty)
        XCTAssertTrue(ReferenceFolder.empty.isEmpty)
        XCTAssertFalse(ReferenceFolder.make(groups: [localGroup("main")]).isEmpty)
    }

    // MARK: - pull/push 대상

    func testPullTargetsRequireCurrentBranchWithLivingUpstream() {
        let group = MergedReferenceGroup(
            kind: .local,
            shortName: "main",
            references: [
                reference("main", repositoryPath: "/a", isCurrent: true, upstream: "origin/main"),
                reference("main", repositoryPath: "/b", isCurrent: false, upstream: "origin/main"),
                reference("main", repositoryPath: "/c", isCurrent: true, upstream: nil),
                reference(
                    "main",
                    repositoryPath: "/d",
                    isCurrent: true,
                    upstream: "origin/main",
                    isGone: true
                )
            ]
        )

        XCTAssertEqual(
            group.pullTargets.map(\.repositoryID.rawValue),
            ["/a"]
        )
        // push 는 체크아웃 여부를 따지지 않으므로 upstream 만 살아 있으면 대상이다.
        XCTAssertEqual(
            group.pushTargets.map(\.repositoryID.rawValue),
            ["/a", "/b"]
        )
    }

    func testFastForwardPullTargetsExcludeCurrentAndUpToDateBranches() {
        let group = MergedReferenceGroup(
            kind: .local,
            shortName: "main",
            references: [
                // 뒤처져 있고 체크아웃도 안 됐다 — 유일한 대상.
                reference("main", repositoryPath: "/a", upstream: "origin/main", behind: 2),
                // 체크아웃돼 있으면 git 이 이 refspec 을 거부한다.
                reference(
                    "main",
                    repositoryPath: "/b",
                    isCurrent: true,
                    upstream: "origin/main",
                    behind: 2
                ),
                // 이미 최신이라 당겨 올 것이 없다.
                reference("main", repositoryPath: "/c", upstream: "origin/main"),
                // upstream 이 없거나 사라졌으면 향할 곳이 없다.
                reference("main", repositoryPath: "/d"),
                reference(
                    "main",
                    repositoryPath: "/e",
                    upstream: "origin/main",
                    isGone: true,
                    behind: 2
                )
            ]
        )

        XCTAssertEqual(group.fastForwardPullTargets.map(\.repositoryID.rawValue), ["/a"])
    }

    func testPublishTargetsRequireNoUpstreamAtAll() {
        let group = MergedReferenceGroup(
            kind: .local,
            shortName: "main",
            references: [
                reference("main", repositoryPath: "/a"),
                reference("main", repositoryPath: "/b", upstream: "origin/main"),
                // upstream 이 사라진 브랜치는 새로 게시할 것이 아니라 정리할 대상이다.
                reference("main", repositoryPath: "/c", upstream: "origin/main", isGone: true)
            ]
        )

        XCTAssertEqual(group.publishTargets.map(\.repositoryID.rawValue), ["/a"])
    }

    func testRebaseAndDeleteTargetsExcludeCheckedOutBranch() {
        let group = MergedReferenceGroup(
            kind: .local,
            shortName: "main",
            references: [
                reference("main", repositoryPath: "/a"),
                reference("main", repositoryPath: "/b", isCurrent: true)
            ]
        )

        XCTAssertEqual(group.rebaseOntoTargets.map(\.repositoryID.rawValue), ["/a"])
        XCTAssertEqual(group.deletableLocalReferences.map(\.repositoryID.rawValue), ["/a"])
    }

    func testRemoteAndTagGroupsAreDeletableInWhole() {
        let remote = MergedReferenceGroup(
            kind: .remote,
            shortName: "origin/main",
            references: [
                reference("origin/main", kind: .remote, repositoryPath: "/a"),
                reference("origin/main", kind: .remote, repositoryPath: "/b")
            ]
        )
        let tag = MergedReferenceGroup(
            kind: .tag,
            shortName: "v1.0",
            references: [reference("v1.0", kind: .tag, repositoryPath: "/a")]
        )
        let local = MergedReferenceGroup(
            kind: .local,
            shortName: "main",
            references: [reference("main", repositoryPath: "/a")]
        )

        XCTAssertEqual(remote.deletableRemoteReferences.count, 2)
        XCTAssertTrue(remote.deletableTagReferences.isEmpty)
        XCTAssertTrue(remote.deletableLocalReferences.isEmpty)
        XCTAssertEqual(tag.deletableTagReferences.count, 1)
        XCTAssertTrue(tag.deletableRemoteReferences.isEmpty)
        XCTAssertTrue(local.deletableRemoteReferences.isEmpty)
        XCTAssertTrue(local.deletableTagReferences.isEmpty)
    }

    func testRemoteAndTagGroupsHaveNoLocalBranchTargets() {
        let remote = MergedReferenceGroup(
            kind: .remote,
            shortName: "origin/main",
            references: [
                reference("origin/main", kind: .remote, repositoryPath: "/a", upstream: nil)
            ]
        )
        let tag = MergedReferenceGroup(
            kind: .tag,
            shortName: "v1.0",
            references: [reference("v1.0", kind: .tag, repositoryPath: "/a")]
        )

        for group in [remote, tag] {
            XCTAssertTrue(group.fastForwardPullTargets.isEmpty)
            XCTAssertTrue(group.publishTargets.isEmpty)
            XCTAssertTrue(group.rebaseOntoTargets.isEmpty)
        }
    }

    func testRemoteAndTagGroupsHaveNoRemoteOperationTargets() {
        let remote = MergedReferenceGroup(
            kind: .remote,
            shortName: "origin/main",
            references: [
                reference(
                    "origin/main",
                    kind: .remote,
                    repositoryPath: "/a",
                    isCurrent: true,
                    upstream: "origin/main"
                )
            ]
        )
        let tag = MergedReferenceGroup(
            kind: .tag,
            shortName: "v1.0",
            references: [reference("v1.0", kind: .tag, repositoryPath: "/a")]
        )

        XCTAssertTrue(remote.pullTargets.isEmpty)
        XCTAssertTrue(remote.pushTargets.isEmpty)
        XCTAssertTrue(tag.pullTargets.isEmpty)
        XCTAssertTrue(tag.pushTargets.isEmpty)
    }

    // MARK: - Kind.sortOrder

    func testKindSortOrderIsLocalThenRemoteThenTag() {
        let sorted = GitReference.Kind.allCases.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sorted, [.local, .remote, .tag])
    }

    // MARK: - 헬퍼

    private func localGroup(_ shortName: String) -> MergedReferenceGroup {
        MergedReferenceGroup(
            kind: .local,
            shortName: shortName,
            references: [reference(shortName)]
        )
    }

    private func remoteGroup(_ shortName: String) -> MergedReferenceGroup {
        MergedReferenceGroup(
            kind: .remote,
            shortName: shortName,
            references: [reference(shortName, kind: .remote)]
        )
    }

    private func reference(
        _ shortName: String,
        kind: GitReference.Kind = .local,
        repositoryPath: String = "/a",
        isCurrent: Bool = false,
        upstream: String? = nil,
        isGone: Bool = false,
        behind: Int = 0
    ) -> GitReference {
        GitReference(
            repositoryID: RepositoryID(rawValue: repositoryPath),
            fullName: "refs/heads/\(shortName)",
            shortName: shortName,
            targetOID: "0123456789",
            kind: kind,
            isCurrent: isCurrent,
            tracking: upstream.map {
                GitBranchTracking(
                    upstreamFullName: "refs/remotes/\($0)",
                    upstreamShortName: $0,
                    remoteName: "origin",
                    remoteRef: "refs/heads/\(shortName)",
                    aheadCount: 0,
                    behindCount: behind,
                    isGone: isGone
                )
            }
        )
    }
}
