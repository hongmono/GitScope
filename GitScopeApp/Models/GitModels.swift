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
    /// 현재 브랜치를 다른 브랜치 위로 rebase. 로컬 작업이지만 진행 중 중복 실행 차단과
    /// 메뉴 비활성화는 원격 작업과 같은 상태로 관리한다.
    case rebase
    case fastForwardPull
    case publish
    case deleteLocalBranch
    case deleteRemoteBranch
    case deleteLocalTag
    case deleteRemoteTag

    /// 진행 중 메뉴에 띄우는 문구. 없으면 원래 항목 이름을 그대로 쓴다.
    var progressTitle: String {
        switch self {
        case .fetch: return "가져오는 중…"
        case .pull, .fastForwardPull: return "Pull 중…"
        case .push, .publish: return "Push 중…"
        case .rebase: return "Rebase 중…"
        case .deleteLocalBranch, .deleteRemoteBranch, .deleteLocalTag, .deleteRemoteTag:
            return "삭제 중…"
        }
    }
}

/// 확인 다이얼로그를 기다리는 삭제 작업.
///
/// 삭제는 확인을 받기 전에 어떤 git 명령도 실행하지 않는다. 미병합 판정만은 `-d` 를
/// 실제로 시도해야 알 수 있으므로, 그 실패를 받으면 `force: true` 로 이 상태를 다시 세워
/// 재확인을 거친 뒤에야 `-D` 로 넘어간다.
struct PendingBranchAction: Identifiable {
    enum Kind: Equatable, Sendable {
        case deleteLocalBranch(force: Bool)
        case deleteRemoteBranch
        case deleteLocalTag
        case deleteRemoteTag
    }

    let kind: Kind
    let group: MergedReferenceGroup
    /// 확인을 받으면 실제로 지울 참조.
    ///
    /// 그룹에서 매번 다시 뽑지 않고 확정해 둔다. `-d` 가 일부 저장소에서만 미병합으로
    /// 실패했을 때, 재확인은 실패한 저장소만 다시 겨냥해야 하기 때문이다.
    let targets: [GitReference]
    /// 이 작업이 실제로 닿는 저장소 이름. 여러 저장소에 걸친 그룹에서 어디가 바뀌는지 밝힌다.
    let repositoryNames: [String]
    let id = UUID()

    var title: String {
        switch kind {
        case .deleteLocalBranch(let force):
            return force
                ? "'\(group.shortName)'에 병합되지 않은 커밋이 있습니다"
                : "'\(group.shortName)' 브랜치를 삭제할까요?"
        case .deleteRemoteBranch:
            return "원격 브랜치 '\(group.shortName)'을 삭제할까요?"
        case .deleteLocalTag:
            return "태그 '\(group.shortName)'을 삭제할까요?"
        case .deleteRemoteTag:
            return "원격에서 태그 '\(group.shortName)'을 삭제할까요?"
        }
    }

    var message: String {
        switch kind {
        case .deleteLocalBranch(let force):
            return force
                ? "그래도 삭제하면 이 브랜치에만 있는 커밋이 사라집니다.\(scopeSuffix)"
                : "로컬 브랜치를 삭제합니다.\(scopeSuffix)"
        case .deleteRemoteBranch:
            return "원격에서 브랜치를 지웁니다. 되돌릴 수 없습니다.\(scopeSuffix)"
        case .deleteLocalTag:
            return "로컬 태그를 삭제합니다. 원격에 올라간 태그는 그대로 남습니다.\(scopeSuffix)"
        case .deleteRemoteTag:
            return "원격에서 태그를 지웁니다. 되돌릴 수 없습니다.\(scopeSuffix)"
        }
    }

    var confirmTitle: String {
        if case .deleteLocalBranch(force: true) = kind { return "강제 삭제" }
        return "삭제"
    }

    /// 대상 저장소를 밝히는 꼬리말. 저장소가 하나뿐이면 굳이 이름을 붙이지 않는다.
    private var scopeSuffix: String {
        guard repositoryNames.count > 1 else { return "" }
        return "\n\n대상 저장소 \(repositoryNames.count)개 — \(repositoryNames.joined(separator: ", "))"
    }
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

    /// Fast-Forward Pull 을 실행할 수 있는 참조.
    ///
    /// `git fetch <remote> <remoteRef>:<localRef>` 는 체크아웃된 브랜치를 대상으로 거부되므로
    /// 현재 브랜치는 빠진다(그쪽은 `pullTargets` 다). 뒤처진 커밋이 없으면 할 일이 없으므로
    /// 메뉴도 켜지 않는다.
    var fastForwardPullTargets: [GitReference] {
        guard kind == .local else { return [] }
        return references.filter {
            !$0.isCurrent && $0.hasLivingUpstream && ($0.tracking?.behindCount ?? 0) > 0
        }
    }

    /// `push -u` 로 새로 게시할 수 있는 참조. upstream 이 아예 없는 브랜치만 해당한다.
    ///
    /// upstream 이 있었는데 원격에서 사라진(`isGone`) 브랜치는 게시가 아니라 삭제된 원격을
    /// 정리해야 하는 상황이므로 여기 넣지 않는다.
    var publishTargets: [GitReference] {
        guard kind == .local else { return [] }
        return references.filter { $0.tracking == nil }
    }

    /// 현재 브랜치를 이 그룹 위로 rebase 할 수 있는 참조.
    ///
    /// 체크아웃된 브랜치를 자기 자신 위로 rebase 할 수는 없으므로 그 저장소는 빠진다.
    /// 대상 브랜치가 있는 저장소만 참조로 잡히므로, "현재 브랜치와 대상이 둘 다 있는
    /// 저장소에서만" 이라는 규칙이 이 필터 하나로 지켜진다.
    var rebaseOntoTargets: [GitReference] {
        guard kind == .local else { return [] }
        return references.filter { !$0.isCurrent }
    }

    /// 삭제할 수 있는 로컬 브랜치. 체크아웃된 브랜치는 git 이 거부하므로 미리 뺀다.
    var deletableLocalReferences: [GitReference] {
        guard kind == .local else { return [] }
        return references.filter { !$0.isCurrent }
    }

    /// 삭제할 수 있는 원격 브랜치. 원격 브랜치 그룹은 참조 전체가 대상이다.
    var deletableRemoteReferences: [GitReference] {
        kind == .remote ? references : []
    }

    /// 삭제할 수 있는 태그. 태그 그룹은 참조 전체가 대상이다.
    var deletableTagReferences: [GitReference] {
        kind == .tag ? references : []
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

/// 여러 커밋의 변경 파일을 합집합으로 묶은 항목.
///
/// 같은 저장소의 같은 경로는 커밋이 몇 개든 한 항목이 된다. 뷰에서 조립하면 선택이 바뀔
/// 때마다 화면을 그리며 다시 묶게 되므로 모델 계층에 두고 `merge(_:)` 한 곳에서만 만든다.
struct MergedChangedFile: Identifiable, Hashable, Sendable {
    let repositoryID: RepositoryID
    let path: String
    /// 커밋별 상태를 중복 없이 모은 목록. 순서는 커밋 순서(오래된 순)를 따른다.
    /// 상태가 섞였음을 툴팁으로 알리는 데 쓴다.
    let statuses: [String]
    /// 목록에 배지로 그리는 대표 상태. 마지막(가장 최근) 커밋의 상태다.
    ///
    /// `statuses` 에서 뽑지 않고 따로 둔다. 중복을 지우고 나면 M → D → M 처럼 되돌아온
    /// 경우에 마지막 원소가 마지막 커밋의 상태와 어긋나기 때문이다.
    let representativeStatus: String
    /// 이 파일을 건드린 선택 커밋. 오래된 순이라 patch 를 이 순서로 이어붙이면 된다.
    let commits: [GitCommit]
    /// patch 를 뽑을 때 넘길 커밋별 원본 항목. 커밋마다 상태와 rename 경로가 다르다.
    let changedFilesByCommit: [CommitID: ChangedFile]

    var id: String { "\(repositoryID.rawValue)::\(path)" }

    /// 상태가 커밋마다 다를 때만 전체를 늘어놓는다. 하나뿐이면 배지와 같은 내용이라 숨긴다.
    var statusTooltip: String? {
        guard statuses.count > 1 else { return nil }
        return "커밋별 상태 — \(statuses.joined(separator: ", "))"
    }

    /// 선택한 커밋들의 변경 파일을 합집합으로 묶는다.
    ///
    /// - 같은 경로는 한 항목으로 합치고, 그 파일을 건드린 커밋을 오래된 순으로 모은다.
    /// - 저장소는 `detailsList` 에 처음 나온 차례(=선택 순서)로 두고, 저장소 안에서는
    ///   경로 이름순으로 정렬한다. 저장소별 섹션을 그리는 쪽이 다시 묶지 않아도 되도록
    ///   같은 저장소의 파일은 반드시 붙어 있게 한다.
    ///
    /// - Parameter detailsList: 히스토리 목록 순서(최신 먼저)의 선택 커밋 details.
    static func merge(_ detailsList: [CommitDetails]) -> [MergedChangedFile] {
        // 커밋 정렬은 `committerDate` 기준이다. 다만 스크립트나 빠른 연속 커밋은 초 단위가
        // 같아지는 일이 흔해 시각만으로는 앞뒤가 갈리지 않는다. 그럴 때는 목록 순서를 따른다
        // — 목록은 최신이 위이므로, 뒤에 온 커밋일수록 더 오래된 커밋이다.
        let orderedDetails = detailsList.enumerated().sorted { first, second in
            if first.element.commit.committerDate != second.element.commit.committerDate {
                return first.element.commit.committerDate < second.element.commit.committerDate
            }
            return first.offset > second.offset
        }
        .map(\.element)

        var repositoryOrder: [RepositoryID] = []
        var seenRepositoryIDs = Set<RepositoryID>()
        for details in detailsList where seenRepositoryIDs.insert(details.commit.id.repositoryID).inserted {
            repositoryOrder.append(details.commit.id.repositoryID)
        }

        var accumulators: [String: Accumulator] = [:]
        var keysByRepository: [RepositoryID: [String]] = [:]
        for details in orderedDetails {
            let repositoryID = details.commit.id.repositoryID
            for file in details.files {
                let key = "\(repositoryID.rawValue)::\(file.path)"
                if accumulators[key] == nil {
                    accumulators[key] = Accumulator(
                        repositoryID: repositoryID,
                        path: file.path
                    )
                    keysByRepository[repositoryID, default: []].append(key)
                }
                accumulators[key]?.append(file: file, commit: details.commit)
            }
        }

        return repositoryOrder.flatMap { repositoryID in
            (keysByRepository[repositoryID] ?? [])
                .compactMap { accumulators[$0]?.snapshot() }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// 병합 도중에만 쓰는 누적기. 완성되면 `snapshot()` 으로 값 타입이 된다.
    private struct Accumulator {
        let repositoryID: RepositoryID
        let path: String
        var statuses: [String] = []
        var commits: [GitCommit] = []
        var changedFilesByCommit: [CommitID: ChangedFile] = [:]

        mutating func append(file: ChangedFile, commit: GitCommit) {
            if !statuses.contains(file.status) {
                statuses.append(file.status)
            }
            commits.append(commit)
            changedFilesByCommit[commit.id] = file
        }

        func snapshot() -> MergedChangedFile {
            MergedChangedFile(
                repositoryID: repositoryID,
                path: path,
                statuses: statuses,
                representativeStatus: commits.last
                    .flatMap { changedFilesByCommit[$0.id]?.status } ?? "",
                commits: commits,
                changedFilesByCommit: changedFilesByCommit
            )
        }
    }
}

/// 커밋 다중 선택의 정규화 규칙.
///
/// 작업 중 행 제약과 순서 정렬은 델리게이트가 아니라 여기 한 곳에만 둔다. 뷰가 알려 준
/// 선택을 그대로 믿으면 ⌘클릭 조합마다 같은 규칙을 다시 구현하게 된다.
enum CommitSelection {
    /// 정규화 결과.
    struct Normalized {
        let commits: [GitCommit]
        /// 정규화가 들어온 선택에서 뭔가를 걷어냈는가.
        ///
        /// 참이면 목록(뷰)은 아직 정규화 전 선택을 그리고 있으므로 되돌려 그려야 한다.
        /// 선택 커밋 자체는 그대로일 수 있으니(작업 중 행만 빠지는 경우) 결과 값 비교로는
        /// 이 사실을 알 수 없다.
        let requiresViewSync: Bool
    }

    /// - Parameters:
    ///   - commits: 목록이 알려 준 선택 전체.
    ///   - latest: 이번 조작으로 **방금 선택된** 행. 클릭이 아닌 경로(갱신 뒤 정리 등)는 빈 배열.
    ///   - rowOrder: 히스토리 목록에 지금 보이는 행의 ID. 선택은 이 차례로 정렬된다.
    /// - Returns: 방금 누른 곳이 작업 중 행뿐이면 그 행 하나. 아니면 작업 중 행을 뺀 나머지를
    ///   목록 순서로 정렬한 선택.
    static func normalize<Rows: Sequence>(
        _ commits: [GitCommit],
        latest: [GitCommit],
        rowOrder: Rows
    ) -> Normalized where Rows.Element == CommitID {
        // 작업 중 행은 커밋이 아니라 워킹 트리라 다른 커밋과 합집합을 만들 수 없다.
        // 어느 쪽을 남길지는 방금 누른 곳이 정한다 — 작업 중 행을 눌렀으면 그 행 하나로
        // 접고, 다른 커밋을 눌렀으면 작업 중 행을 뺀다. 늘 작업 중 행을 남기면 작업 중
        // 행이 선택된 상태에서 무엇을 눌러도 화면이 그대로라 클릭이 먹지 않은 것처럼 보인다.
        if !latest.isEmpty, latest.allSatisfy(\.isWorkingTree) {
            let workingTree = Array(latest.prefix(1))
            return Normalized(
                commits: workingTree,
                requiresViewSync: commits.count != workingTree.count
            )
        }

        let selectable = commits.filter { !$0.isWorkingTree }
        // 작업 중 행만 남았다면(단일 선택이거나 다른 행을 전부 해제한 경우) 그 행을 그대로 둔다.
        guard !selectable.isEmpty else {
            let workingTree = Array(commits.prefix(1))
            return Normalized(
                commits: workingTree,
                requiresViewSync: commits.count != workingTree.count
            )
        }

        let requiresViewSync = selectable.count != commits.count
        guard selectable.count > 1 else {
            return Normalized(commits: selectable, requiresViewSync: requiresViewSync)
        }

        var remaining = Dictionary(
            selectable.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordered: [GitCommit] = []
        ordered.reserveCapacity(remaining.count)
        for id in rowOrder {
            guard let commit = remaining.removeValue(forKey: id) else { continue }
            ordered.append(commit)
        }
        // 목록에서 사라진(필터에 걸린) 커밋은 원래 순서대로 뒤에 붙인다.
        ordered.append(contentsOf: selectable.compactMap { remaining.removeValue(forKey: $0.id) })
        return Normalized(
            commits: ordered,
            // 중복이 지워진 것도 뷰와 어긋난 상태다.
            requiresViewSync: requiresViewSync || ordered.count != commits.count
        )
    }

    /// ⇧클릭이 덮는 행 번호.
    ///
    /// 앵커가 위든 아래든 두 행 사이를 모두 포함한다. 목록 밖을 가리키면 빈 배열이다.
    static func rangeIndexes(anchor: Int, clicked: Int, rowCount: Int) -> [Int] {
        let lower = min(anchor, clicked)
        let upper = max(anchor, clicked)
        guard lower >= 0, upper < rowCount else { return [] }
        return Array(lower...upper)
    }

    /// 조용한 갱신 뒤 되살릴 커밋.
    ///
    /// rebase·amend 로 사라진 커밋은 빼고 남은 것만, 갱신 전 선택 순서대로 돌려준다.
    /// 커밋 인스턴스는 새로 읽은 것으로 바꿔 브랜치·태그 배지를 최신화한다.
    ///
    /// - Parameter survivingIDs: 갱신 뒤에도 목록에 남아 있다고 판단된 커밋의 ID.
    static func restorable(
        commitIDs: [CommitID],
        survivingIDs: Set<CommitID>,
        in commits: [GitCommit]
    ) -> [GitCommit] {
        commitIDs.compactMap { commitID in
            guard survivingIDs.contains(commitID) else { return nil }
            return commits.first { $0.id == commitID }
        }
    }
}

/// 이어붙일 커밋 하나의 patch.
struct CommitPatchSection: Sendable {
    let commit: GitCommit
    let patch: String
}

extension CommitPatchSection {
    /// 커밋별 patch 를 넘어온 순서(오래된 순)대로 이어붙인다.
    ///
    /// - Parameter showsCommitHeaders: 커밋이 둘 이상일 때만 참. 단일 커밋에 헤더를 붙이면
    ///   기존 단일 선택 화면과 달라지므로 patch 하나를 그대로 돌려준다.
    static func join(_ sections: [CommitPatchSection], showsCommitHeaders: Bool) -> String {
        sections
            .map { section in
                guard showsCommitHeaders else { return section.patch }
                let subject = section.commit.subject.isEmpty
                    ? "(메시지 없음)"
                    : section.commit.subject
                return """
                    \(DiffLine.Kind.commitHeaderPrefix)\(section.commit.shortOID) \(subject)
                    \(section.patch)
                    """
            }
            .joined(separator: "\n")
    }
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
        /// 다중 선택에서 이어붙인 patch 사이에 끼워 넣는 커밋 구분 헤더.
        case commitHeader
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
    /// 커밋 구분 헤더의 접두사. patch 본문의 어떤 줄과도 겹치지 않도록 git 이 쓰지 않는
    /// 문자를 골랐다. 이어붙이는 쪽과 분류하는 쪽이 같은 값을 쓰도록 여기 한 곳에 둔다.
    static let commitHeaderPrefix = "― "

    /// 파일 헤더를 먼저 본다. `+++`/`---` 는 추가/삭제 접두사와 겹치기 때문이다.
    init(classifying line: String) {
        if line.hasPrefix(Self.commitHeaderPrefix) {
            self = .commitHeader
        } else if line.hasPrefix("+++") || line.hasPrefix("---") {
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
