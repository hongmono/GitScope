import XCTest

/// `CommitGraphLayout.makeRows(commits:)` 의 현재 동작을 고정하는 특성화 테스트.
///
/// 최근 회귀(레인 안정화, 왼쪽 클리핑, 레인 전환 모서리)가 전부 이 레이아웃에서
/// 발생했으므로, 핵심 성질(부모-자식 레인 연속성, 레인 재사용, 머지/분기 지점)을
/// 구체적인 기대값과 행 간 불변식으로 못 박는다.
final class CommitGraphLayoutTests: XCTestCase {

    // MARK: - 직선 히스토리

    func testLinearChainStaysOnLaneZero() {
        let rows = CommitGraphLayout.makeRows(commits: [
            TestFixtures.commit("c", parents: ["b"]),
            TestFixtures.commit("b", parents: ["a"]),
            TestFixtures.commit("a")
        ])

        XCTAssertEqual(rows.map(\.commit.id.oid), ["c", "b", "a"])
        XCTAssertEqual(rows.map(\.graph.nodeLane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.graph.nodeColorIndex), [0, 0, 0])
        XCTAssertEqual(rows.map(\.graph.laneCount), [1, 1, 1])

        XCTAssertEqual(rows[0].graph.incomingLanes, [])
        XCTAssertEqual(rows[0].graph.parentLanes, [0])
        XCTAssertEqual(rows[1].graph.incomingLanes, [0])
        XCTAssertEqual(rows[1].graph.parentLanes, [0])
        XCTAssertEqual(rows[2].graph.incomingLanes, [0])
        XCTAssertEqual(rows[2].graph.parentLanes, [])
        assertLaneColorContinuity(rows)
    }

    // MARK: - 머지 커밋

    func testMergeCommitOpensSecondLaneAndKeepsFirstParentColor() {
        let rows = CommitGraphLayout.makeRows(commits: [
            TestFixtures.commit("m", parents: ["a", "b"]),
            TestFixtures.commit("b", parents: ["a"]),
            TestFixtures.commit("a")
        ])

        let merge = rows[0].graph
        XCTAssertEqual(merge.nodeLane, 0)
        XCTAssertEqual(merge.nodeColorIndex, 0)
        XCTAssertEqual(merge.parentLanes, [0, 1])
        // 첫 번째 부모는 노드 색을 이어받고, 두 번째 부모는 새 색을 받는다.
        XCTAssertEqual(merge.parentColorIndices, [0, 1])
        XCTAssertEqual(merge.laneCount, 2)

        let second = rows[1].graph
        XCTAssertEqual(second.nodeLane, 1)
        XCTAssertEqual(second.nodeColorIndex, 1)
        XCTAssertEqual(second.incomingLanes, [1])
        XCTAssertEqual(second.incomingColorIndices, [1])
        // 레인 0 의 경로는 그대로 통과한다.
        XCTAssertEqual(
            second.passThroughConnections,
            [GraphLaneConnection(incomingLane: 0, outgoingLane: 0, colorIndex: 0)]
        )
        // 두 번째 부모 가지가 공통 조상으로 향할 때는 자기 레인을 유지한다.
        XCTAssertEqual(second.parentLanes, [1])
        XCTAssertEqual(second.laneCount, 2)

        let base = rows[2].graph
        // 두 경로가 공통 조상에서 합류한다.
        XCTAssertEqual(base.incomingLanes, [0, 1])
        XCTAssertEqual(base.incomingColorIndices, [0, 1])
        XCTAssertEqual(base.nodeLane, 0)
        XCTAssertEqual(base.nodeColorIndex, 0)
        XCTAssertTrue(base.isBranchPoint)
        XCTAssertEqual(base.laneCount, 2)
        assertLaneColorContinuity(rows)
    }

    // MARK: - 분기 지점과 레인 재사용

    func testBranchPointJoinsOnLaneZeroAndFreesSecondLane() {
        let rows = CommitGraphLayout.makeRows(commits: [
            TestFixtures.commit("d", parents: ["b"]),
            TestFixtures.commit("c", parents: ["b"]),
            TestFixtures.commit("b", parents: ["a"]),
            TestFixtures.commit("a")
        ])

        // 아직 대상 커밋이 나오지 않은 형제 커밋은 새 레인을 연다.
        let sibling = rows[1].graph
        XCTAssertEqual(sibling.nodeLane, 1)
        XCTAssertEqual(sibling.parentLanes, [1])
        XCTAssertEqual(sibling.laneCount, 2)

        // 분기 지점: 두 자식 경로가 모이고, 노드는 가장 왼쪽 레인을 이어받는다.
        let branchPoint = rows[2].graph
        XCTAssertEqual(branchPoint.incomingLanes, [0, 1])
        XCTAssertTrue(branchPoint.isBranchPoint)
        XCTAssertEqual(branchPoint.nodeLane, 0)
        XCTAssertEqual(branchPoint.nodeColorIndex, 0)
        XCTAssertEqual(branchPoint.parentLanes, [0])
        XCTAssertEqual(branchPoint.laneCount, 2)

        // 분기 지점 아래에서는 레인 1 이 해제되어 폭이 다시 1 이 된다.
        let base = rows[3].graph
        XCTAssertEqual(base.incomingLanes, [0])
        XCTAssertEqual(base.nodeLane, 0)
        XCTAssertEqual(base.laneCount, 1)
        assertLaneColorContinuity(rows)
    }

    // MARK: - 보이지 않는 부모

    func testParentOutsideVisibleSetProducesNoPath() {
        let rows = CommitGraphLayout.makeRows(commits: [
            TestFixtures.commit("x", parents: ["missing"])
        ])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].graph.nodeLane, 0)
        XCTAssertEqual(rows[0].graph.parentLanes, [])
        XCTAssertEqual(rows[0].graph.laneCount, 1)
    }

    // MARK: - 경로 종료 후 레인 압축과 저장소 분리

    func testPathEndCompactsLanesAndKeepsRepositoriesSeparate() {
        let repoA = RepositoryID(rawValue: "/tmp/repo-a")
        let repoB = RepositoryID(rawValue: "/tmp/repo-b")
        // 두 저장소가 같은 "a" oid 를 갖지만 CommitID 는 저장소 단위로 구분된다.
        let rows = CommitGraphLayout.makeRows(commits: [
            TestFixtures.commit("x", parents: ["a"], repositoryID: repoA),
            TestFixtures.commit("y", parents: ["a"], repositoryID: repoB),
            TestFixtures.commit("a", repositoryID: repoA),
            TestFixtures.commit("a", repositoryID: repoB)
        ])

        // repoB 의 "y" 는 repoA 의 "a" 를 부모로 삼지 못하고 새 레인을 연다.
        XCTAssertEqual(rows[1].graph.nodeLane, 1)
        XCTAssertEqual(rows[1].graph.parentLanes, [1])

        // repoA 의 "a" 에서 레인 0 경로가 끝나면, 레인 1 경로는 왼쪽으로 압축된다.
        let firstRoot = rows[2].graph
        XCTAssertEqual(firstRoot.incomingLanes, [0])
        XCTAssertEqual(firstRoot.incomingColorIndices, [0])
        XCTAssertEqual(firstRoot.parentLanes, [])
        XCTAssertEqual(
            firstRoot.passThroughConnections,
            [GraphLaneConnection(incomingLane: 1, outgoingLane: 0, colorIndex: 1)]
        )
        XCTAssertEqual(firstRoot.laneCount, 2)

        // repoB 의 "a" 는 압축된 레인 0 으로 들어오며 원래 색(1)을 유지한다.
        let secondRoot = rows[3].graph
        XCTAssertEqual(secondRoot.incomingLanes, [0])
        XCTAssertEqual(secondRoot.incomingColorIndices, [1])
        XCTAssertEqual(secondRoot.nodeColorIndex, 1)
        XCTAssertEqual(secondRoot.laneCount, 1)
        assertLaneColorContinuity(rows)
    }

    // MARK: - 행 간 불변식

    func testComplexHistoryKeepsLaneColorContinuity() {
        // 머지 두 번, 분기 한 번이 섞인 히스토리에서 행 사이 레인 연속성을 검사한다.
        let rows = CommitGraphLayout.makeRows(commits: [
            TestFixtures.commit("g", parents: ["f", "e"]),
            TestFixtures.commit("f", parents: ["d"]),
            TestFixtures.commit("e", parents: ["c"]),
            TestFixtures.commit("d", parents: ["b", "c"]),
            TestFixtures.commit("c", parents: ["a"]),
            TestFixtures.commit("b", parents: ["a"]),
            TestFixtures.commit("a")
        ])

        XCTAssertEqual(rows.count, 7)
        assertLaneColorContinuity(rows)
    }

    /// 한 행의 아래쪽 경로(부모 레인 + 통과 레인)와 다음 행의 위쪽 경로(들어오는
    /// 레인 + 통과 레인)는 같은 활성 경로 집합을 두 시점에서 본 것이므로,
    /// 레인 → 색 매핑이 정확히 일치해야 한다. 이 성질이 깨지면 그래프 선이 행
    /// 경계에서 끊기거나 색이 바뀌어 보인다.
    private func assertLaneColorContinuity(
        _ rows: [CommitRow],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in rows.indices.dropLast() {
            let bottom = rows[index].graph
            let top = rows[index + 1].graph

            var bottomColorsByLane: [Int: Int] = [:]
            for (lane, color) in zip(bottom.parentLanes, bottom.parentColorIndices) {
                XCTAssertNil(
                    bottomColorsByLane.updateValue(color, forKey: lane),
                    "행 \(index) 아래쪽 레인 \(lane) 이 중복 사용됐습니다.",
                    file: file,
                    line: line
                )
            }
            for connection in bottom.passThroughConnections {
                XCTAssertNil(
                    bottomColorsByLane.updateValue(
                        connection.colorIndex,
                        forKey: connection.outgoingLane
                    ),
                    "행 \(index) 아래쪽 레인 \(connection.outgoingLane) 이 중복 사용됐습니다.",
                    file: file,
                    line: line
                )
            }

            var topColorsByLane: [Int: Int] = [:]
            for (lane, color) in zip(top.incomingLanes, top.incomingColorIndices) {
                XCTAssertNil(
                    topColorsByLane.updateValue(color, forKey: lane),
                    "행 \(index + 1) 위쪽 레인 \(lane) 이 중복 사용됐습니다.",
                    file: file,
                    line: line
                )
            }
            for connection in top.passThroughConnections {
                XCTAssertNil(
                    topColorsByLane.updateValue(
                        connection.colorIndex,
                        forKey: connection.incomingLane
                    ),
                    "행 \(index + 1) 위쪽 레인 \(connection.incomingLane) 이 중복 사용됐습니다.",
                    file: file,
                    line: line
                )
            }

            XCTAssertEqual(
                bottomColorsByLane,
                topColorsByLane,
                "행 \(index) → \(index + 1) 경계에서 레인/색 연속성이 깨졌습니다.",
                file: file,
                line: line
            )
        }
    }
}
