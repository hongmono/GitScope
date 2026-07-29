import Foundation
import SwiftUI

struct WorkspaceTab: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let paths: [String]
    /// 사용자가 저장소 필터에서 숨긴 저장소의 경로.
    ///
    /// 보이는 쪽이 아니라 숨긴 쪽을 기억한다. 그래야 워크스페이스에 저장소가 새로 생겼을 때
    /// 기본으로 보인다.
    var hiddenRepositoryPaths: [String]
    /// 이 탭의 브랜치 범위.
    ///
    /// 저장소 필터와 방향이 반대로, 숨긴 쪽이 아니라 **체크한 쪽**을 기억한다. 기본값이
    /// "필터 꺼짐"이기 때문이다.
    var branchScope: BranchScope

    init(
        id: UUID = UUID(),
        paths: [String],
        hiddenRepositoryPaths: [String] = [],
        branchScope: BranchScope = .empty
    ) {
        self.id = id
        self.paths = paths
        self.hiddenRepositoryPaths = hiddenRepositoryPaths
        self.branchScope = branchScope
    }

    /// 이 필드들이 없던 시절에 저장된 탭도 그대로 읽어야 하므로 직접 디코딩한다.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        paths = try container.decode([String].self, forKey: .paths)
        hiddenRepositoryPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .hiddenRepositoryPaths
        ) ?? []
        branchScope = try container.decodeIfPresent(
            BranchScope.self,
            forKey: .branchScope
        ) ?? .empty
    }

    var title: String {
        guard let firstPath = paths.first else { return "워크스페이스" }
        let firstName = URL(fileURLWithPath: firstPath).lastPathComponent
        return paths.count == 1 ? firstName : "\(firstName) 외 \(paths.count - 1)"
    }

    var subtitle: String {
        paths.joined(separator: "\n")
    }
}

struct RepositoryID: Hashable, Sendable, Codable, Identifiable {
    let rawValue: String
    var id: String { rawValue }
}

struct CommitID: Hashable, Sendable, Codable, Identifiable {
    let repositoryID: RepositoryID
    let oid: String

    var id: String { "\(repositoryID.rawValue)::\(oid)" }
}

struct GitRepository: Identifiable, Hashable, Sendable {
    let id: RepositoryID
    let name: String
    let rootURL: URL
    let colorIndex: Int
    let githubRepository: GitHubRepository?
}

struct GitReference: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case local
        case remote
        case tag
    }

    let repositoryID: RepositoryID
    let fullName: String
    let shortName: String
    let targetOID: String
    let kind: Kind
    let isCurrent: Bool
    let tracking: GitBranchTracking?

    var id: String { "\(repositoryID.rawValue)::\(fullName)" }
}

extension GitReference.Kind {
    /// 필터 메뉴·메타데이터 행처럼 자리가 좁은 곳에서 쓰는 짧은 이름.
    var displayName: String {
        switch self {
        case .local: return "로컬"
        case .remote: return "원격"
        case .tag: return "태그"
        }
    }

    /// 참조 팝오버처럼 종류를 온전히 밝혀야 하는 곳에서 쓰는 이름.
    var longDisplayName: String {
        switch self {
        case .local: return "로컬 브랜치"
        case .remote: return "원격 브랜치"
        case .tag: return "태그"
        }
    }

    /// 종류를 늘어놓는 순서. 사이드바 섹션 차례와 같은 로컬 → 원격 → 태그다.
    var sortOrder: Int {
        switch self {
        case .local: return 0
        case .remote: return 1
        case .tag: return 2
        }
    }
}

extension GitReference {
    /// upstream 이 설정돼 있고 원격에서 사라지지도 않은 상태.
    ///
    /// upstream 이 없거나 `isGone` 이면 pull/push 가 향할 곳이 없다.
    var hasLivingUpstream: Bool {
        guard let tracking else { return false }
        return !tracking.isGone
    }

    /// 이 참조가 속한 ref 그룹의 ID. 브랜치 범위에 체크된 ID 와 대조하는 데 쓴다.
    var scopeGroupID: String {
        MergedReferenceGroup.makeID(kind: kind, shortName: shortName)
    }
}

struct GitBranchTracking: Hashable, Sendable {
    let upstreamFullName: String
    let upstreamShortName: String
    let remoteName: String
    let remoteRef: String
    let aheadCount: Int
    let behindCount: Int
    let isGone: Bool
}

enum GitRemoteOperationKind: String, Sendable {
    case fetch
    case pull
    case push
}

struct GitRemoteOperation: Equatable, Sendable {
    let repositoryID: RepositoryID
    let referenceID: String
    let kind: GitRemoteOperationKind
}

struct MergedReferenceGroup: Identifiable, Hashable, Sendable {
    let kind: GitReference.Kind
    let shortName: String
    let references: [GitReference]

    var id: String { Self.makeID(kind: kind, shortName: shortName) }
    var isCurrent: Bool { references.contains(where: \.isCurrent) }

    /// 그룹 ID 를 만드는 유일한 자리.
    ///
    /// 브랜치 범위는 이 ID 를 탭에 저장하고 참조 하나하나와도 대조하므로, 만드는 규칙이
    /// 여러 곳에 흩어지면 저장된 범위가 조용히 안 맞기 시작한다.
    static func makeID(kind: GitReference.Kind, shortName: String) -> String {
        "\(kind.rawValue)::\(shortName)"
    }

    /// 저장된 그룹 ID 를 종류와 이름으로 되돌린다.
    ///
    /// 워크스페이스에 지금 없는 브랜치도 메뉴에 이름으로 남겨야 해제할 수 있기 때문에,
    /// 그룹 객체 없이 ID 만으로 표시 정보를 얻는 경로가 필요하다.
    static func decomposeID(
        _ id: String
    ) -> (kind: GitReference.Kind, shortName: String)? {
        // `shortName` 에도 "::" 가 들어갈 수 있으므로 첫 구분자에서만 자른다.
        guard let separator = id.range(of: "::"),
              let kind = GitReference.Kind(rawValue: String(id[..<separator.lowerBound]))
        else {
            return nil
        }
        let shortName = String(id[separator.upperBound...])
        return shortName.isEmpty ? nil : (kind, shortName)
    }

    /// Pull(rebase) 을 실행할 수 있는 참조.
    ///
    /// git 은 체크아웃된 브랜치로만 rebase 할 수 있고, upstream 이 없거나 원격에서 지워진
    /// 브랜치는 당겨 올 곳이 없다. 메뉴의 활성화 판단과 실제 실행 대상이 어긋나지 않도록
    /// 이 규칙은 여기 한 곳에만 둔다.
    var pullTargets: [GitReference] {
        guard kind == .local else { return [] }
        return references.filter { $0.isCurrent && $0.hasLivingUpstream }
    }

    /// Push 를 실행할 수 있는 참조. pull 과 달리 체크아웃 여부는 따지지 않는다.
    var pushTargets: [GitReference] {
        guard kind == .local else { return [] }
        return references.filter(\.hasLivingUpstream)
    }
}

/// 히스토리에 남길 브랜치 집합.
///
/// 사이드바의 단일 선택(좁고 임시)보다 넓은 축으로, 탭에 저장돼 앱을 다시 켜도 남는다.
/// 두 축은 교집합이 아니라 덮어쓰기 관계다 — 사이드바 선택이 있으면 그쪽이 이기고,
/// 선택을 풀면 이 범위로 돌아온다.
///
/// 저장소 경로가 아니라 **이름**(`MergedReferenceGroup.id`)을 기억한다. 워크스페이스에
/// 저장소가 여러 개면 같은 이름의 브랜치가 함께 잡힌다.
struct BranchScope: Equatable, Codable, Sendable {
    /// 체크한 ref 그룹의 ID. `MergedReferenceGroup.id` 와 같은 "kind::shortName" 형태.
    var referenceGroupIDs: Set<String>
    /// "로컬 브랜치 전부" 동적 그룹. 새로 만든 로컬 브랜치도 별도 조작 없이 들어온다.
    var includesAllLocalBranches: Bool

    var isActive: Bool { includesAllLocalBranches || !referenceGroupIDs.isEmpty }

    /// 메뉴 버튼 제목에 쓰는 항목 수. 동적 그룹도 한 개로 센다.
    var memberCount: Int {
        referenceGroupIDs.count + (includesAllLocalBranches ? 1 : 0)
    }

    static let empty = BranchScope(referenceGroupIDs: [], includesAllLocalBranches: false)

    func contains(_ group: MergedReferenceGroup) -> Bool {
        referenceGroupIDs.contains(group.id)
    }

    mutating func toggle(_ group: MergedReferenceGroup) {
        if referenceGroupIDs.contains(group.id) {
            referenceGroupIDs.remove(group.id)
        } else {
            referenceGroupIDs.insert(group.id)
        }
    }

    /// 저장소 하나에서 이 범위가 가리키는 revision 과 워킹 트리 포함 여부.
    ///
    /// 체크해 둔 브랜치가 이 저장소에 없으면 그냥 빠진다(저장 목록에서는 지우지 않는다).
    /// `includesAllLocalBranches` 일 때 로컬 ref 를 따로 넘기지 않는 것은 `--branches` 가
    /// 이미 전부를 뜻하기 때문이다.
    func resolve(in references: [GitReference]) -> ResolvedBranchScope {
        guard isActive else { return .empty }

        var revisions: [String] = []
        var includesWorkingTree = includesAllLocalBranches
        for reference in references where referenceGroupIDs.contains(reference.scopeGroupID) {
            if includesAllLocalBranches, reference.kind == .local { continue }
            revisions.append(reference.fullName)
            if reference.isCurrent {
                includesWorkingTree = true
            }
        }

        return ResolvedBranchScope(
            revisions: revisions.sorted(),
            includesAllLocalBranches: includesAllLocalBranches,
            includesWorkingTree: includesWorkingTree
        )
    }

    /// 메뉴 상단에 평평하게 그릴 체크 항목. "로컬 브랜치 전부" 다음 자리에 온다.
    ///
    /// - Parameter existingGroupIDs: 지금 워크스페이스에 실제로 있는 그룹 ID.
    ///   여기 없는 항목은 `isMissing` 으로 남겨 사용자가 직접 해제할 수 있게 한다.
    func menuItems(existingGroupIDs: Set<String>) -> [BranchScopeMenuItem] {
        referenceGroupIDs
            .compactMap { id in
                guard let decomposed = MergedReferenceGroup.decomposeID(id) else { return nil }
                return BranchScopeMenuItem(
                    id: id,
                    shortName: decomposed.shortName,
                    kind: decomposed.kind,
                    isMissing: !existingGroupIDs.contains(id)
                )
            }
            .sorted {
                if $0.kind != $1.kind {
                    return $0.kind.sortOrder < $1.kind.sortOrder
                }
                return $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
            }
    }
}

/// 저장소 하나에 대해 풀어낸 브랜치 범위. `git rev-list` 인자와 워킹 트리 포함 여부를 담는다.
struct ResolvedBranchScope: Equatable, Sendable {
    let revisions: [String]
    let includesAllLocalBranches: Bool
    /// 범위에 체크아웃된 브랜치가 들어 있으면 참. 커밋되지 않은 변경 행을 함께 남긴다.
    let includesWorkingTree: Bool

    /// 이 저장소에 물어볼 것이 하나도 없는 상태. 이런 저장소는 건너뛴다.
    var isEmpty: Bool { !includesAllLocalBranches && revisions.isEmpty }

    static let empty = ResolvedBranchScope(
        revisions: [],
        includesAllLocalBranches: false,
        includesWorkingTree: false
    )
}

/// 브랜치 범위 메뉴 상단에 그리는 체크 항목 하나.
struct BranchScopeMenuItem: Identifiable, Hashable, Sendable {
    let id: String
    let shortName: String
    let kind: GitReference.Kind
    /// 체크는 돼 있지만 지금 워크스페이스에 없는 브랜치.
    let isMissing: Bool

    /// 메뉴에 그릴 제목. 사라진 브랜치는 그렇다고 밝혀 해제할 수 있음을 알린다.
    var menuTitle: String {
        isMissing ? "\(shortName) (없음)" : shortName
    }
}

/// 참조 이름의 `/` 계층을 그대로 옮긴 폴더 트리.
///
/// 사이드바와 브랜치 범위 필터 메뉴가 같은 계층을 그려야 하므로 뷰가 아니라 모델 쪽에 둔다.
struct ReferenceFolder: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let children: [ReferenceFolder]
    let references: [MergedReferenceGroup]

    var id: String { path }

    /// 참조도 하위 폴더도 없는 트리. 검색 결과가 비었는지 판단하는 데 쓴다.
    var isEmpty: Bool { children.isEmpty && references.isEmpty }

    static let empty = ReferenceFolder(name: "", path: "", children: [], references: [])

    /// 그룹의 `shortName` 을 `/` 경계로 나눠 폴더에 담는다.
    ///
    /// 뷰 body 에서 부르면 화면을 그릴 때마다 참조 전체를 다시 훑게 되므로, 참조 목록이
    /// 바뀔 때 한 번만 만들어 캐시하는 쪽에서 부른다.
    static func make(groups: [MergedReferenceGroup]) -> ReferenceFolder {
        let root = MutableReferenceFolder(name: "", path: "")
        for group in groups {
            let components = group.shortName.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                root.references.append(group)
                continue
            }

            var current = root
            for component in components.dropLast() {
                if let child = current.children[component] {
                    current = child
                } else {
                    let path = current.path.isEmpty ? component : "\(current.path)/\(component)"
                    let child = MutableReferenceFolder(name: component, path: path)
                    current.children[component] = child
                    current = child
                }
            }
            current.references.append(group)
        }
        return root.snapshot()
    }
}

/// 트리를 만드는 동안에만 쓰는 가변 노드. 완성되면 `snapshot()` 으로 값 타입이 된다.
private final class MutableReferenceFolder {
    let name: String
    let path: String
    var children: [String: MutableReferenceFolder] = [:]
    var references: [MergedReferenceGroup] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    func snapshot() -> ReferenceFolder {
        ReferenceFolder(
            name: name,
            path: path,
            children: children.values
                .map { $0.snapshot() }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            references: references.sorted {
                $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
            }
        )
    }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let id: CommitID
    let parentOIDs: [String]
    let subject: String
    let body: String
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerDate: Date
    let references: [GitReference]
    let isHead: Bool
    let isWorkingTree: Bool

    var shortOID: String { String(id.oid.prefix(8)) }
}

struct RepositorySnapshot: Sendable {
    let repository: GitRepository
    let references: [GitReference]
    let commits: [GitCommit]
}

struct WorkspaceSnapshot: Sendable {
    let repositories: [GitRepository]
    let referencesByRepository: [RepositoryID: [GitReference]]
    let commits: [GitCommit]
}

struct ChangedFile: Identifiable, Hashable, Sendable {
    let status: String
    let path: String
    let diffPaths: [String]
    var id: String { "\(status)::\(path)" }
}

struct CommitDetails: Sendable {
    let commit: GitCommit
    let files: [ChangedFile]
}

/// 사전 파싱된 diff 패치 한 줄.
///
/// SwiftUI body 는 여러 번 재평가되므로 표시 시점에 패치 문자열을 줄로 분해하면 큰 패치에서
/// 재평가마다 전체 문자열을 다시 훑는다. 패치를 받은 뒤 한 번만 `parse(_:)` 로 만들어 두고
/// 뷰는 이 배열만 소비한다.
struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        /// `+++`/`---` 파일 경로 헤더.
        case fileHeader
        /// `@@` 헝크 헤더.
        case hunkHeader
        case addition
        case deletion
        case context
    }

    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ patch: String) -> [DiffLine] {
        patch.components(separatedBy: .newlines)
            .enumerated()
            .map { DiffLine(id: $0.offset, kind: Kind(classifying: $0.element), text: $0.element) }
    }
}

extension DiffLine.Kind {
    /// 파일 헤더를 먼저 본다. `+++`/`---` 는 추가/삭제 접두사와 겹치기 때문이다.
    init(classifying line: String) {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            self = .fileHeader
        } else if line.hasPrefix("@@") {
            self = .hunkHeader
        } else if line.hasPrefix("+") {
            self = .addition
        } else if line.hasPrefix("-") {
            self = .deletion
        } else {
            self = .context
        }
    }
}

struct GitHubRepository: Hashable, Sendable {
    let owner: String
    let name: String

    var webURL: URL {
        URL(string: "https://github.com/\(owner)/\(name)")!
    }

    var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(name)")!
    }

    init?(remoteURL: String) {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path: String
        if let scpSeparator = trimmed.firstIndex(of: ":"),
           !trimmed.contains("://") {
            // scp 형태(`[user@]host:owner/repo`). 사용자 부분은 없을 수 있고, 콜론 뒤에 나오는
            // `@` 는 경로의 일부이므로 호스트 구분자로 보지 않는다.
            let hostStart = trimmed[..<scpSeparator]
                .firstIndex(of: "@")
                .map { trimmed.index(after: $0) } ?? trimmed.startIndex
            let host = trimmed[hostStart..<scpSeparator]
            guard host.caseInsensitiveCompare("github.com") == .orderedSame else {
                return nil
            }
            path = String(trimmed[trimmed.index(after: scpSeparator)...])
        } else {
            guard let components = URLComponents(string: trimmed),
                  components.host?.caseInsensitiveCompare("github.com") == .orderedSame else {
                return nil
            }
            path = components.path
        }

        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let repositoryName = parts[1].hasSuffix(".git")
            ? String(parts[1].dropLast(4))
            : parts[1]
        guard !parts[0].isEmpty, !repositoryName.isEmpty else { return nil }

        owner = parts[0]
        name = repositoryName
    }
}

enum GitHubActionsState: String, Hashable, Sendable {
    case queued
    case inProgress
    case success
    case failure
    case cancelled
    case neutral
    case unknown

    var isActive: Bool {
        self == .queued || self == .inProgress
    }
}

struct GitHubWorkflowRun: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let displayTitle: String
    let headSHA: String
    let pullRequestHeadSHAs: [String]
    let headBranch: String?
    let event: String
    let status: String
    let conclusion: String?
    let webURL: URL
    let runNumber: Int
    let runAttempt: Int
    let updatedAt: Date

    var state: GitHubActionsState {
        GitHubActionsState(status: status, conclusion: conclusion)
    }

    /// 실행 번호·브랜치·이벤트를 한 줄로 잇는 부제. 비어 있는 값은 건너뛴다.
    var detailSummary: String {
        var parts = ["#\(runNumber)"]
        if let headBranch, !headBranch.isEmpty {
            parts.append(headBranch)
        }
        if !event.isEmpty {
            parts.append(event)
        }
        return parts.joined(separator: " · ")
    }
}

struct GitHubActionsSummary: Hashable, Sendable {
    let commitID: CommitID
    let repository: GitHubRepository
    let runs: [GitHubWorkflowRun]

    var state: GitHubActionsState {
        GitHubActionsState.aggregate(runs.map(\.state))
    }

    var primaryURL: URL? {
        runs.first(where: { $0.state.isActive })?.webURL
            ?? runs.first(where: { $0.state == .failure })?.webURL
            ?? runs.first?.webURL
    }
}

struct GitHubCheckRun: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let webURL: URL?
    let appName: String?
    let startedAt: Date?
    let completedAt: Date?

    var state: GitHubActionsState {
        GitHubActionsState(status: status, conclusion: conclusion)
    }
}

extension GitHubActionsState {
    init(status: String, conclusion: String?) {
        switch status {
        case "queued", "requested", "waiting", "pending":
            self = .queued
        case "in_progress":
            self = .inProgress
        case "completed":
            switch conclusion {
            case "success":
                self = .success
            case "failure", "timed_out", "action_required", "stale":
                self = .failure
            case "cancelled":
                self = .cancelled
            case "neutral", "skipped":
                self = .neutral
            default:
                self = .unknown
            }
        default:
            self = .unknown
        }
    }

    static func aggregate(_ states: [GitHubActionsState]) -> GitHubActionsState {
        if states.contains(.inProgress) { return .inProgress }
        if states.contains(.queued) { return .queued }
        if states.contains(.failure) { return .failure }
        if states.contains(.cancelled) { return .cancelled }
        if states.contains(.unknown) { return .unknown }
        if states.contains(.success) { return .success }
        if states.contains(.neutral) { return .neutral }
        return .unknown
    }
}

struct GraphLaneConnection: Sendable, Hashable {
    let incomingLane: Int
    let outgoingLane: Int
    let colorIndex: Int
}

struct GraphRowLayout: Sendable, Hashable {
    let nodeLane: Int
    let nodeColorIndex: Int
    let incomingLanes: [Int]
    let incomingColorIndices: [Int]
    let passThroughConnections: [GraphLaneConnection]
    let parentLanes: [Int]
    let parentColorIndices: [Int]
    let laneCount: Int

    var isBranchPoint: Bool { incomingLanes.count > 1 }
}

struct CommitRow: Identifiable, Hashable, Sendable {
    let commit: GitCommit
    let graph: GraphRowLayout
    var id: CommitID { commit.id }
}

enum HistoryDateScope: String, CaseIterable, Identifiable {
    case all = "전체"
    case today = "오늘"
    case sevenDays = "최근 7일"
    case thirtyDays = "최근 30일"

    var id: String { rawValue }

    func includes(_ date: Date, now: Date = .now) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .sevenDays:
            return date >= calendar.date(byAdding: .day, value: -7, to: now)!
        case .thirtyDays:
            return date >= calendar.date(byAdding: .day, value: -30, to: now)!
        }
    }
}

enum AppPalette {
    static let repositoryColors: [Color] = [
        Color(red: 0.35, green: 0.43, blue: 0.90),
        Color(red: 0.25, green: 0.65, blue: 0.45),
        Color(red: 0.92, green: 0.40, blue: 0.46),
        Color(red: 0.30, green: 0.66, blue: 0.78),
        Color(red: 0.65, green: 0.42, blue: 0.86)
    ]

    static let repositoryBackgrounds: [Color] = [
        Color(red: 0.92, green: 0.92, blue: 0.99),
        Color(red: 0.89, green: 0.97, blue: 0.91),
        Color(red: 1.00, green: 0.90, blue: 0.92),
        Color(red: 0.89, green: 0.96, blue: 0.98),
        Color(red: 0.95, green: 0.91, blue: 0.99)
    ]

    static let graphColors: [Color] = [
        Color(red: 0.00, green: 0.72, blue: 0.84),
        Color(red: 0.10, green: 0.47, blue: 0.96),
        Color(red: 0.55, green: 0.20, blue: 0.92),
        Color(red: 0.83, green: 0.13, blue: 0.76),
        Color(red: 0.96, green: 0.45, blue: 0.17),
        Color(red: 0.16, green: 0.72, blue: 0.46)
    ]

    static let avatarColors: [Color] = [
        Color(red: 0.31, green: 0.72, blue: 0.68),
        Color(red: 0.25, green: 0.56, blue: 0.86),
        Color(red: 0.57, green: 0.43, blue: 0.82),
        Color(red: 0.88, green: 0.43, blue: 0.39),
        Color(red: 0.85, green: 0.63, blue: 0.25),
        Color(red: 0.29, green: 0.64, blue: 0.44)
    ]
}
