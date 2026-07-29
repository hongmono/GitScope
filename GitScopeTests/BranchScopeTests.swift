import XCTest

/// 브랜치 범위 필터의 순수 로직 테스트.
///
/// 저장(인코딩/디코딩), 저장소별 revision 해석, 메뉴 항목 구성은 모두 뷰나 git 없이
/// 값만으로 결정되므로 여기서 검증한다.
final class BranchScopeTests: XCTestCase {

    // MARK: - 그룹 ID

    func testGroupIDRoundTripsThroughDecompose() {
        let group = MergedReferenceGroup(
            kind: .remote,
            shortName: "origin/feature/login",
            references: []
        )

        XCTAssertEqual(group.id, "remote::origin/feature/login")
        let decomposed = MergedReferenceGroup.decomposeID(group.id)
        XCTAssertEqual(decomposed?.kind, .remote)
        XCTAssertEqual(decomposed?.shortName, "origin/feature/login")
    }

    func testDecomposeKeepsSeparatorInsideShortName() {
        // 첫 "::" 에서만 잘라야 이름에 "::" 가 들어간 브랜치도 되살아난다.
        let decomposed = MergedReferenceGroup.decomposeID("local::odd::name")
        XCTAssertEqual(decomposed?.kind, .local)
        XCTAssertEqual(decomposed?.shortName, "odd::name")
    }

    func testDecomposeRejectsMalformedIDs() {
        XCTAssertNil(MergedReferenceGroup.decomposeID("local"))
        XCTAssertNil(MergedReferenceGroup.decomposeID("local::"))
        XCTAssertNil(MergedReferenceGroup.decomposeID("branch::main"))
        XCTAssertNil(MergedReferenceGroup.decomposeID(""))
    }

    func testReferenceScopeGroupIDMatchesItsGroup() {
        let reference = TestFixtures.reference("origin/main", kind: .remote)
        let group = MergedReferenceGroup(
            kind: .remote,
            shortName: "origin/main",
            references: [reference]
        )
        XCTAssertEqual(reference.scopeGroupID, group.id)
    }

    // MARK: - 상태

    func testEmptyScopeIsInactive() {
        XCTAssertFalse(BranchScope.empty.isActive)
        XCTAssertEqual(BranchScope.empty.memberCount, 0)
    }

    func testMemberCountCountsAllLocalBranchesAsOne() {
        var scope = BranchScope(
            referenceGroupIDs: ["remote::origin/main", "remote::origin/dev"],
            includesAllLocalBranches: false
        )
        XCTAssertEqual(scope.memberCount, 2)
        XCTAssertTrue(scope.isActive)

        scope.includesAllLocalBranches = true
        XCTAssertEqual(scope.memberCount, 3)
    }

    func testToggleAddsAndRemovesGroup() {
        let group = MergedReferenceGroup(kind: .local, shortName: "main", references: [])
        var scope = BranchScope.empty

        scope.toggle(group)
        XCTAssertTrue(scope.contains(group))
        XCTAssertTrue(scope.isActive)

        scope.toggle(group)
        XCTAssertFalse(scope.contains(group))
        XCTAssertFalse(scope.isActive)
    }

    // MARK: - 저장

    func testBranchScopeCodableRoundTrip() throws {
        let scope = BranchScope(
            referenceGroupIDs: ["remote::origin/main", "tag::v1.0"],
            includesAllLocalBranches: true
        )

        let data = try JSONEncoder().encode(scope)
        let decoded = try JSONDecoder().decode(BranchScope.self, from: data)

        XCTAssertEqual(decoded, scope)
    }

    func testWorkspaceTabRoundTripsBranchScope() throws {
        let tab = WorkspaceTab(
            paths: ["/tmp/repo"],
            hiddenRepositoryPaths: ["/tmp/repo/hidden"],
            branchScope: BranchScope(
                referenceGroupIDs: ["remote::origin/dev"],
                includesAllLocalBranches: true
            )
        )

        let data = try JSONEncoder().encode([tab])
        let decoded = try JSONDecoder().decode([WorkspaceTab].self, from: data)

        XCTAssertEqual(decoded, [tab])
        XCTAssertEqual(decoded.first?.branchScope.referenceGroupIDs, ["remote::origin/dev"])
        XCTAssertEqual(decoded.first?.branchScope.includesAllLocalBranches, true)
    }

    func testWorkspaceTabSavedBeforeBranchScopeExistedStillDecodes() throws {
        // 이 필드가 없던 시절에 저장된 탭도 그대로 열려야 한다.
        let legacyJSON = """
            [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","paths":["/tmp/repo"]}]
            """
        let decoded = try JSONDecoder().decode(
            [WorkspaceTab].self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.branchScope, .empty)
        XCTAssertEqual(decoded.first?.hiddenRepositoryPaths, [])
    }

    // MARK: - resolve(in:)

    func testInactiveScopeResolvesToNothing() {
        let resolved = BranchScope.empty.resolve(in: [
            TestFixtures.reference("main", kind: .local, isCurrent: true)
        ])

        XCTAssertEqual(resolved, .empty)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testResolveTakesOnlyCheckedReferencesPresentInTheRepository() {
        let scope = BranchScope(
            referenceGroupIDs: ["remote::origin/main", "remote::origin/prod"],
            includesAllLocalBranches: false
        )
        let references = [
            TestFixtures.reference("origin/main", kind: .remote),
            TestFixtures.reference("origin/dev", kind: .remote),
            TestFixtures.reference("main", kind: .local, isCurrent: true)
        ]

        let resolved = scope.resolve(in: references)

        // origin/prod 는 이 저장소에 없으므로 그냥 빠진다(저장 목록에서는 지우지 않는다).
        XCTAssertEqual(resolved.revisions, ["refs/remotes/origin/main"])
        XCTAssertFalse(resolved.includesAllLocalBranches)
        // 체크된 것 중 체크아웃된 브랜치가 없으므로 워킹 트리 행은 넣지 않는다.
        XCTAssertFalse(resolved.includesWorkingTree)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testResolveIncludesWorkingTreeWhenCheckedBranchIsCurrent() {
        let scope = BranchScope(
            referenceGroupIDs: ["local::main"],
            includesAllLocalBranches: false
        )
        let resolved = scope.resolve(in: [
            TestFixtures.reference("main", kind: .local, isCurrent: true),
            TestFixtures.reference("develop", kind: .local)
        ])

        XCTAssertEqual(resolved.revisions, ["refs/heads/main"])
        XCTAssertTrue(resolved.includesWorkingTree)
    }

    func testAllLocalBranchesUsesFlagInsteadOfListingLocalRefs() {
        let scope = BranchScope(
            referenceGroupIDs: ["local::main", "remote::origin/dev"],
            includesAllLocalBranches: true
        )
        let resolved = scope.resolve(in: [
            TestFixtures.reference("main", kind: .local, isCurrent: true),
            TestFixtures.reference("origin/dev", kind: .remote)
        ])

        // 로컬은 `--branches` 가 대신하므로 개별 ref 로 다시 넘기지 않는다.
        XCTAssertEqual(resolved.revisions, ["refs/remotes/origin/dev"])
        XCTAssertTrue(resolved.includesAllLocalBranches)
        // "로컬 브랜치 전부" 는 체크아웃된 브랜치를 반드시 품으므로 워킹 트리도 함께 남는다.
        XCTAssertTrue(resolved.includesWorkingTree)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testAllLocalBranchesAloneIsNotEmptyEvenWithoutMatchingRefs() {
        let scope = BranchScope(referenceGroupIDs: [], includesAllLocalBranches: true)
        let resolved = scope.resolve(in: [])

        XCTAssertTrue(resolved.revisions.isEmpty)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testResolveIsEmptyWhenNoCheckedReferenceExistsHere() {
        let scope = BranchScope(
            referenceGroupIDs: ["remote::origin/prod"],
            includesAllLocalBranches: false
        )
        let resolved = scope.resolve(in: [
            TestFixtures.reference("main", kind: .local, isCurrent: true)
        ])

        XCTAssertTrue(resolved.isEmpty)
    }

    func testResolveSortsRevisionsForStableCommands() {
        let scope = BranchScope(
            referenceGroupIDs: ["remote::origin/z", "remote::origin/a"],
            includesAllLocalBranches: false
        )
        let resolved = scope.resolve(in: [
            TestFixtures.reference("origin/z", kind: .remote),
            TestFixtures.reference("origin/a", kind: .remote)
        ])

        XCTAssertEqual(
            resolved.revisions,
            ["refs/remotes/origin/a", "refs/remotes/origin/z"]
        )
    }

    // MARK: - menuItems(existingGroupIDs:)

    func testMenuItemsSortByKindThenName() {
        let scope = BranchScope(
            referenceGroupIDs: [
                "tag::v1.0",
                "remote::origin/main",
                "local::main",
                "remote::origin/dev"
            ],
            includesAllLocalBranches: true
        )

        let items = scope.menuItems(
            existingGroupIDs: [
                "tag::v1.0", "remote::origin/main", "local::main", "remote::origin/dev"
            ]
        )

        XCTAssertEqual(
            items.map(\.id),
            ["local::main", "remote::origin/dev", "remote::origin/main", "tag::v1.0"]
        )
        XCTAssertTrue(items.allSatisfy { !$0.isMissing })
        XCTAssertEqual(items.map(\.menuTitle), ["main", "origin/dev", "origin/main", "v1.0"])
    }

    func testMenuItemsMarkBranchesMissingFromTheWorkspace() {
        let scope = BranchScope(
            referenceGroupIDs: ["remote::origin/main", "remote::origin/prod"],
            includesAllLocalBranches: false
        )

        let items = scope.menuItems(existingGroupIDs: ["remote::origin/main"])

        XCTAssertEqual(items.map(\.isMissing), [false, true])
        XCTAssertEqual(items.map(\.menuTitle), ["origin/main", "origin/prod (없음)"])
    }

    func testMenuItemsDropUnreadableIDs() {
        let scope = BranchScope(
            referenceGroupIDs: ["remote::origin/main", "garbage"],
            includesAllLocalBranches: false
        )

        let items = scope.menuItems(existingGroupIDs: [])

        XCTAssertEqual(items.map(\.id), ["remote::origin/main"])
    }
}
