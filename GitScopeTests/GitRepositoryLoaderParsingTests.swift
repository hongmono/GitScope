import XCTest

/// `GitRepositoryLoader` 의 순수 파싱/병합 로직에 대한 특성화 테스트.
///
/// git 프로세스를 실행하지 않고, git 이 실제로 내는 형태의 데이터를 만들어
/// 파서에 직접 넣는다.
final class GitRepositoryLoaderParsingTests: XCTestCase {
    private var loader: GitRepositoryLoader!

    override func setUp() {
        super.setUp()
        loader = GitRepositoryLoader()
    }

    override func tearDown() {
        loader = nil
        super.tearDown()
    }

    // MARK: - parseChangedFiles (git show --name-status -z)

    func testParseChangedFilesReadsSimpleStatuses() async {
        let data = TestFixtures.nulSeparatedData([
            "M", "Sources/modified.swift",
            "A", "Sources/added.swift",
            "D", "Sources/deleted.swift"
        ])

        let files = await loader.parseChangedFiles(data)

        XCTAssertEqual(files.map(\.status), ["M", "A", "D"])
        XCTAssertEqual(
            files.map(\.path),
            ["Sources/modified.swift", "Sources/added.swift", "Sources/deleted.swift"]
        )
        XCTAssertEqual(files.map(\.diffPaths), [
            ["Sources/modified.swift"],
            ["Sources/added.swift"],
            ["Sources/deleted.swift"]
        ])
    }

    func testParseChangedFilesRenameAndCopyConsumeTwoPaths() async {
        let data = TestFixtures.nulSeparatedData([
            "R100", "old/name.swift", "new/name.swift",
            "C75", "source.swift", "copy.swift",
            "M", "unrelated.swift"
        ])

        let files = await loader.parseChangedFiles(data)

        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].status, "R100")
        XCTAssertEqual(files[0].path, "old/name.swift → new/name.swift")
        XCTAssertEqual(files[0].diffPaths, ["old/name.swift", "new/name.swift"])
        XCTAssertEqual(files[1].status, "C75")
        XCTAssertEqual(files[1].path, "source.swift → copy.swift")
        XCTAssertEqual(files[1].diffPaths, ["source.swift", "copy.swift"])
        XCTAssertEqual(files[2].status, "M")
        XCTAssertEqual(files[2].path, "unrelated.swift")
    }

    func testParseChangedFilesKeepsSpacesAndUnicodeInPaths() async {
        let data = TestFixtures.nulSeparatedData([
            "M", "폴더 이름/파일 이름.swift"
        ])

        let files = await loader.parseChangedFiles(data)

        XCTAssertEqual(files.map(\.path), ["폴더 이름/파일 이름.swift"])
    }

    func testParseChangedFilesEmptyDataReturnsNothing() async {
        let files = await loader.parseChangedFiles(Data())
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - parseWorkingTreeFiles (git status --porcelain=v1 -z)

    func testParseWorkingTreeReadsStatusPairsAndTrims() async {
        let data = TestFixtures.nulSeparatedData([
            " M unstaged.swift",
            "M  staged.swift",
            "MM both.swift",
            "?? untracked file.swift"
        ])

        let files = await loader.parseWorkingTreeFiles(data)

        XCTAssertEqual(files.map(\.status), ["M", "M", "MM", "??"])
        XCTAssertEqual(
            files.map(\.path),
            ["unstaged.swift", "staged.swift", "both.swift", "untracked file.swift"]
        )
        XCTAssertEqual(files.map(\.diffPaths), [
            ["unstaged.swift"],
            ["staged.swift"],
            ["both.swift"],
            ["untracked file.swift"]
        ])
    }

    func testParseWorkingTreeRenameAndCopyConsumeOriginalPath() async {
        // porcelain -z 는 "XY 새경로" 레코드 다음 필드로 원래 경로를 붙인다.
        let data = TestFixtures.nulSeparatedData([
            "R  renamed-new.swift", "renamed-old.swift",
            "C  copied-new.swift", "copied-source.swift",
            " M other.swift"
        ])

        let files = await loader.parseWorkingTreeFiles(data)

        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].status, "R")
        XCTAssertEqual(files[0].path, "renamed-old.swift → renamed-new.swift")
        XCTAssertEqual(files[0].diffPaths, ["renamed-old.swift", "renamed-new.swift"])
        XCTAssertEqual(files[1].status, "C")
        XCTAssertEqual(files[1].path, "copied-source.swift → copied-new.swift")
        XCTAssertEqual(files[1].diffPaths, ["copied-source.swift", "copied-new.swift"])
        XCTAssertEqual(files[2].status, "M")
        XCTAssertEqual(files[2].path, "other.swift")
    }

    func testParseWorkingTreeSkipsRecordsTooShortToHoldStatusAndPath() async {
        let data = TestFixtures.nulSeparatedData(["", "??"])
        let files = await loader.parseWorkingTreeFiles(data)
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - parseISODate (git %aI / %cI)

    func testParseISODateReadsFixedWidthPositiveOffset() async {
        let parsed = await loader.parseISODate("2026-07-27T11:34:39+09:00")
        XCTAssertEqual(
            parsed,
            makeDate(2026, 7, 27, 11, 34, 39, offsetSeconds: 9 * 3_600)
        )
    }

    func testParseISODateReadsNegativeHalfHourOffset() async {
        let parsed = await loader.parseISODate("2026-01-02T03:04:05-05:30")
        XCTAssertEqual(
            parsed,
            makeDate(2026, 1, 2, 3, 4, 5, offsetSeconds: -(5 * 3_600 + 30 * 60))
        )
    }

    func testParseISODateFastPathAgreesWithISO8601Formatter() async {
        // fad1aab 성능 수정의 약속: 고정 폭 파서는 기존 포매터와 같은 값을 낸다.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let samples = [
            "2026-07-27T11:34:39+09:00",
            "2000-02-29T23:59:59+00:00",
            "1999-12-31T00:00:00-11:30",
            "2026-12-31T23:59:59+14:00"
        ]

        for sample in samples {
            let parsed = await loader.parseISODate(sample)
            XCTAssertEqual(parsed, formatter.date(from: sample), "입력: \(sample)")
        }
    }

    func testParseISODateNonFixedWidthFormsFallBackToFormatter() async {
        // 25바이트 고정 폭이 아니므로 포매터 폴백을 타지만, 같은 시각으로 읽혀야 한다.
        let reference = await loader.parseISODate("2026-07-27T11:34:39+09:00")
        XCTAssertNotEqual(reference, .distantPast)

        let zulu = await loader.parseISODate("2026-07-27T02:34:39Z")
        XCTAssertEqual(zulu, reference)

        // 콜론 없는 오프셋도 포매터 폴백이 받아들인다.
        let compactOffset = await loader.parseISODate("2026-07-27T11:34:39+0900")
        XCTAssertEqual(compactOffset, reference)
    }

    func testParseISODateInvalidInputReturnsDistantPast() async {
        let invalidInputs = [
            "",
            "not-a-date",
            "2026-07-27",
            "2026-07-27 11:34:39 +0900",
            "2026-07-27T11:34:39.123+09:00"
        ]

        for input in invalidInputs {
            let parsed = await loader.parseISODate(input)
            XCTAssertEqual(parsed, .distantPast, "입력: \(input)")
        }
    }

    func testParseISODateRejectsOutOfRangeFieldsLikeTheFallbackFormatter() async {
        // 고정 폭 파서가 `Calendar` 롤오버로 없는 날짜를 만들어 내면, 같은 문자열을 거절하는
        // 폴백 포매터와 결과가 갈린다. 두 경로가 함께 거절하는지 확인한다.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let outOfRangeInputs = [
            "2026-13-01T00:00:00+09:00",
            "2026-00-10T00:00:00+09:00",
            "2026-07-32T00:00:00+09:00",
            "2026-07-00T00:00:00+09:00",
            "2026-07-27T25:00:00+09:00",
            "2026-07-27T11:60:39+09:00",
            "2026-07-27T11:34:60+09:00"
        ]

        for input in outOfRangeInputs {
            XCTAssertNil(formatter.date(from: input), "포매터도 거절해야 함: \(input)")
            let parsed = await loader.parseISODate(input)
            XCTAssertEqual(parsed, .distantPast, "입력: \(input)")
        }
    }

    func testParseISODateDoesNotInventCalendarInvalidDates() async {
        // 달 길이를 넘는 날짜(2월 31일)는 필드 범위 안에 있어 포매터가 받아들이지만,
        // 고정 폭 파서가 제멋대로 롤오버시키지 않고 포매터에 맡겨 같은 값을 내야 한다.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let calendarInvalidInputs = [
            "2026-02-31T00:00:00+09:00",
            "2025-02-29T00:00:00+09:00",
            "2026-04-31T12:00:00+00:00"
        ]

        for input in calendarInvalidInputs {
            let parsed = await loader.parseISODate(input)
            XCTAssertEqual(parsed, formatter.date(from: input), "입력: \(input)")
        }
    }

    func testParseISODateKeepsLeapDayOnFastPath() async {
        // 윤년 2월 29일은 실재하는 날짜이므로 유효성 검증이 걸러서는 안 된다.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let leapDays = [
            "2024-02-29T10:00:00+09:00",
            "2000-02-29T23:59:59+00:00"
        ]

        for input in leapDays {
            let parsed = await loader.parseISODate(input)
            XCTAssertEqual(parsed, formatter.date(from: input), "입력: \(input)")
            XCTAssertNotEqual(parsed, .distantPast, "입력: \(input)")
        }

        // 평년의 2월 29일은 없는 날이라 같은 검증에 걸린다.
        let commonYear = await loader.parseISODate("2100-02-29T10:00:00+09:00")
        XCTAssertEqual(commonYear, formatter.date(from: "2100-02-29T10:00:00+09:00"))
    }

    // MARK: - rev-list (브랜치 범위)

    func testRevListArgumentsListRevisionsAndEndWithPathspecTerminator() {
        let arguments = GitRepositoryLoader.revListArguments(
            revisions: ["refs/remotes/origin/main", "refs/remotes/origin/dev"],
            includesAllLocalBranches: false,
            limit: 50_000
        )

        XCTAssertEqual(arguments, [
            "-c", "color.ui=false",
            "rev-list", "--max-count=50000",
            "refs/remotes/origin/main", "refs/remotes/origin/dev",
            "--"
        ])
    }

    func testRevListArgumentsUseBranchesFlagForAllLocalBranches() {
        // 로컬 브랜치가 200개여도 `--branches` 하나로 대신하므로 호출은 저장소당 1회다.
        let arguments = GitRepositoryLoader.revListArguments(
            revisions: ["refs/remotes/origin/dev"],
            includesAllLocalBranches: true,
            limit: 10
        )

        XCTAssertEqual(arguments, [
            "-c", "color.ui=false",
            "rev-list", "--max-count=10",
            "--branches",
            "refs/remotes/origin/dev",
            "--"
        ])
    }

    func testParseReachableCommitIDsDeduplicatesAndSkipsBlankLines() async {
        let text = "aaa\nbbb\n\naaa\nccc\n"

        let ids = await loader.parseReachableCommitIDs(
            text,
            repositoryID: TestFixtures.repositoryID
        )

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(
            Set(ids.map(\.oid)),
            ["aaa", "bbb", "ccc"]
        )
        XCTAssertTrue(ids.allSatisfy { $0.repositoryID == TestFixtures.repositoryID })
    }

    func testReachableCommitIDsFromDifferentRepositoriesDoNotCollideWhenMerged() async {
        // 워크스페이스에 저장소가 여러 개면 같은 oid 가 양쪽에 있을 수 있다. 합집합이
        // 저장소를 구분하지 못하면 한쪽 커밋이 다른 저장소 필터에 새어 든다.
        let other = RepositoryID(rawValue: "/tmp/other-repo")
        let first = await loader.parseReachableCommitIDs(
            "aaa\nbbb\n",
            repositoryID: TestFixtures.repositoryID
        )
        let second = await loader.parseReachableCommitIDs("aaa\n", repositoryID: other)

        let merged = first.union(second)

        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains(CommitID(repositoryID: other, oid: "aaa")))
        XCTAssertTrue(
            merged.contains(CommitID(repositoryID: TestFixtures.repositoryID, oid: "aaa"))
        )
    }

    // MARK: - mergeTopologicalStreams

    func testMergeOrdersStreamsByHeadCommitterDate() async {
        let streamA = [
            fixtureCommit("a1", secondsSinceEpoch: 100),
            fixtureCommit("a2", secondsSinceEpoch: 50),
            fixtureCommit("a3", secondsSinceEpoch: 10)
        ]
        let streamB = [
            fixtureCommit("b1", secondsSinceEpoch: 80),
            fixtureCommit("b2", secondsSinceEpoch: 60),
            fixtureCommit("b3", secondsSinceEpoch: 20)
        ]

        let merged = await loader.mergeTopologicalStreams([streamA, streamB])

        XCTAssertEqual(merged.map(\.id.oid), ["a1", "b1", "b2", "a2", "b3", "a3"])
    }

    func testMergeComparesOnlyStreamHeadsAndPreservesStreamOrder() async {
        // 스트림 내부의 날짜 역전(자식이 부모보다 오래된 경우)은 토폴로지 순서를
        // 지키기 위해 그대로 유지되고, 비교는 각 스트림의 머리끼리만 한다.
        let streamA = [
            fixtureCommit("old-child", secondsSinceEpoch: 10),
            fixtureCommit("new-parent", secondsSinceEpoch: 100)
        ]
        let streamB = [
            fixtureCommit("middle", secondsSinceEpoch: 50)
        ]

        let merged = await loader.mergeTopologicalStreams([streamA, streamB])

        XCTAssertEqual(merged.map(\.id.oid), ["middle", "old-child", "new-parent"])
    }

    func testMergeTieBreaksTowardEarlierStream() async {
        let streamA = [fixtureCommit("first", secondsSinceEpoch: 50)]
        let streamB = [fixtureCommit("second", secondsSinceEpoch: 50)]

        let merged = await loader.mergeTopologicalStreams([streamA, streamB])

        XCTAssertEqual(merged.map(\.id.oid), ["first", "second"])
    }

    func testMergeHandlesEmptyStreams() async {
        let onlyStream = [fixtureCommit("solo", secondsSinceEpoch: 1)]

        let mergedWithEmpty = await loader.mergeTopologicalStreams([[], onlyStream, []])
        XCTAssertEqual(mergedWithEmpty.map(\.id.oid), ["solo"])

        let mergedAllEmpty = await loader.mergeTopologicalStreams([[], []])
        XCTAssertTrue(mergedAllEmpty.isEmpty)

        let mergedNoStreams = await loader.mergeTopologicalStreams([])
        XCTAssertTrue(mergedNoStreams.isEmpty)
    }

    // MARK: - 헬퍼

    private func fixtureCommit(_ oid: String, secondsSinceEpoch: TimeInterval) -> GitCommit {
        TestFixtures.commit(
            oid,
            committerDate: Date(timeIntervalSince1970: secondsSinceEpoch)
        )
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int,
        offsetSeconds: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
