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
        isGone: Bool = false
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
                    behindCount: 0,
                    isGone: isGone
                )
            }
        )
    }
}
