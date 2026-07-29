import AppKit
import Combine
import Foundation
import Observation

/// 화면 상태의 단일 원본.
///
/// 프로퍼티 단위로 관찰된다. 뷰는 자기 `body` 에서 실제로 읽은 프로퍼티가 바뀔 때만 다시
/// 그려지므로, 6초마다 도는 Actions 폴링이 `githubActionsByCommit` 만 건드리면 그 값을
/// 읽지 않는 사이드바·툴바·필터 바는 재평가되지 않는다.
///
/// 뷰가 읽지 않는 내부 상태(작업 핸들·검색 키·카운터)는 `@ObservationIgnored` 로 추적에서
/// 뺀다. 관찰 대상으로 두면 아무도 읽지 않는 값 때문에 추적 등록만 쌓인다.
@MainActor
@Observable
final class AppModel {
    private(set) var workspaceTabs: [WorkspaceTab] = []
    private(set) var activeWorkspaceTabID: WorkspaceTab.ID?
    private(set) var workspaceURLs: [URL] = []
    private(set) var repositories: [GitRepository] = [] {
        didSet {
            repositoryNamesByID = Dictionary(
                repositories.map { ($0.id, $0.name) },
                uniquingKeysWith: { name, _ in name }
            )
        }
    }
    /// 저장소 이름을 ID 로 바로 찾는 캐시.
    ///
    /// 행마다 `repositories` 를 선형 탐색하면 사이드바처럼 참조 수백 개를 그리는 화면에서
    /// 탐색이 행 수 × 저장소 수로 늘어나므로, `repositories` 가 바뀔 때 한 번만 만들어 둔다.
    ///
    /// 캐시지만 사이드바 행이 `body` 에서 직접 읽으므로 추적 대상으로 남긴다. 저장소 목록이
    /// 바뀔 때만 갱신되니 과잉 무효화를 만들지도 않는다.
    private(set) var repositoryNamesByID: [RepositoryID: String] = [:]
    private(set) var referencesByRepository: [RepositoryID: [GitReference]] = [:] {
        didSet { rebuildReferenceGroups() }
    }
    private(set) var availableAuthors: [String] = []
    private(set) var mergedReferenceGroups: [MergedReferenceGroup] = []
    /// 사이드바가 섹션마다 전체 목록을 훑지 않도록 종류별로 미리 나눠 둔다.
    private(set) var referenceGroupsByKind: [GitReference.Kind: [MergedReferenceGroup]] = [:]
    /// 종류별 폴더 트리 전체. 브랜치 범위 필터 메뉴가 그린다.
    ///
    /// 뷰 body 에서 만들면 Actions 폴링 같은 무관한 변경마다 참조 전체를 다시 훑게 되므로
    /// 참조 목록이 바뀔 때만 다시 만든다.
    private(set) var referenceFoldersByKind: [GitReference.Kind: ReferenceFolder] = [:]
    /// 사이드바 검색어까지 반영한 폴더 트리. 사이드바가 그대로 그리는 최종 계층이다.
    ///
    /// 히스토리 필터 메뉴는 사이드바 검색과 무관해야 하므로 걸러지지 않은 위 트리를 쓴다.
    private(set) var searchedReferenceFoldersByKind: [GitReference.Kind: ReferenceFolder] = [:]
    private(set) var visibleRepositoryIDs: Set<RepositoryID> = []
    private(set) var rows: [CommitRow] = []
    private(set) var selectedCommit: GitCommit?
    private(set) var selectedDetails: CommitDetails?
    private(set) var selectedFile: ChangedFile?
    private(set) var selectedPatch: String?
    private(set) var githubActionsByCommit: [CommitID: GitHubActionsSummary] = [:]
    private(set) var selectedGitHubChecks: [GitHubCheckRun] = []
    private(set) var isLoadingSelectedGitHubChecks = false
    private(set) var githubActionsNotice: String?
    /// 일부 저장소만 읽지 못했을 때의 안내. 나머지 저장소는 그대로 보여주므로 얼럿 대신
    /// 툴바 아이콘 툴팁으로만 알린다.
    private(set) var repositoryLoadNotice: String?
    /// 자동 fetch 가 연달아 실패할 때만 채워지는 안내. 자격증명 만료처럼 계속 실패하는
    /// 상태를 정상과 구별하기 위한 것이라 역시 툴바 아이콘 툴팁으로만 알린다.
    private(set) var autoFetchFailureNotice: String?
    /// 상한(`commitLoadLimit`)을 채운 저장소가 하나라도 있으면 참. 이력이 잘렸을 수
    /// 있음을 히스토리 목록 하단 안내로 알리는 데 쓴다.
    private(set) var isCommitHistoryTruncated = false
    private(set) var isLoadingWorkspace = false
    private(set) var isLoadingReference = false
    private(set) var isLoadingDetails = false
    private(set) var isLoadingPatch = false
    private(set) var remoteOperation: GitRemoteOperation?
    var errorMessage: String?

    var query = "" {
        didSet { scheduleQueryRebuild() }
    }
    var branchSearch = "" {
        didSet {
            normalizedBranchSearch = branchSearch
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedLowercase
            rebuildSearchedReferenceFolders()
        }
    }
    /// 비교용으로 다듬은 브랜치 검색어. 트리 캐시와 사이드바가 같은 기준을 쓰도록 한 곳에 둔다.
    private(set) var normalizedBranchSearch = ""
    var expandedReferenceGroups: Set<GitReference.Kind> = [.local]
    var collapsedReferenceFolders: Set<String> = []
    var pathFilter = ""
    var authorFilter: String? {
        didSet { rebuildRows() }
    }
    var dateScope: HistoryDateScope = .all {
        didSet { rebuildRows() }
    }
    /// didSet 재빌드를 두지 않는다. 이 값을 바꾸는 경로는 `branchMembership` 등 동반 상태를
    /// 함께 바꾼 뒤 명시적으로 `rebuildRows()` 를 부르는데, didSet 이 있으면 동반 상태가
    /// 갱신되기 전의 틀린 중간 결과를 한 번 더 계산해 만들고 버리게 된다.
    private(set) var repositoryScope: RepositoryID?
    private(set) var selectedReference: GitReference?
    private(set) var selectedReferenceGroupID: String?
    private(set) var isCurrentBranchesSelected = false
    /// 탭에 저장되는 넓은 쪽 브랜치 축. 사이드바 선택이 없을 때만 히스토리에 적용된다.
    private(set) var branchScope: BranchScope = .empty
    /// 범위에 체크된 항목을 필터 메뉴 상단에 평평하게 그리기 위한 목록.
    ///
    /// 뷰에서 계산하면 필터 바를 그릴 때마다 참조 전체에서 ID 를 모으게 되므로, 범위나
    /// 참조 목록이 바뀔 때 한 번만 만들어 둔다.
    private(set) var branchScopeMenuItems: [BranchScopeMenuItem] = []
    private(set) var isLoadingBranchScope = false
    var isBranchSidebarVisible =
        UserDefaults.standard.object(
            forKey: AppModel.branchSidebarVisibleDefaultsKey
        ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                isBranchSidebarVisible,
                forKey: Self.branchSidebarVisibleDefaultsKey
            )
        }
    }
    var isCommitDetailsVisible =
        UserDefaults.standard.object(
            forKey: AppModel.commitDetailsVisibleDefaultsKey
        ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                isCommitDetailsVisible,
                forKey: Self.commitDetailsVisibleDefaultsKey
            )
        }
    }

    /// 저장소당 읽어 오는 최근 커밋 수 상한. 이 값을 채운 저장소는 이력이 잘렸다고 보고
    /// 히스토리 목록 하단에 안내를 띄운다.
    static let commitLoadLimit = 2_000

    /// 이 횟수만큼 연속으로 자동 fetch 가 전부 실패하면 안내를 띄운다.
    private static let autoFetchFailureNoticeThreshold = 3

    /// 실행 중인 워크플로 때문에 빠른 폴링을 유지하는 최대 시간.
    private static let githubActionsActiveRunFastPollWindow: TimeInterval = 600

    private let loader = GitRepositoryLoader()
    private let remoteService = GitRemoteService()
    private let githubActionsService = GitHubActionsService.shared
    // 아래는 전부 뷰가 읽지 않는 내부 상태다. 관찰 대상으로 두면 화면과 무관한 쓰기가
    // 추적 등록만 만들어 내므로 `@ObservationIgnored` 로 뺀다. 이 값들이 바뀌어 화면이
    // 달라져야 하는 경우에는 항상 위쪽의 관찰 대상 프로퍼티도 함께 쓰인다.
    @ObservationIgnored
    private var allCommits: [GitCommit] = [] {
        didSet {
            rebuildAvailableAuthors()
            rebuildCommitHistoryTruncation()
            rebuildSearchKeys()
        }
    }
    /// 커밋당 미리 소문자화해 둔 검색 키.
    ///
    /// 필터가 키 입력마다 커밋 전체의 `localizedLowercase` 를 재계산하지 않도록 적재 시 한 번만
    /// 만든다. body 는 커서 소문자 사본을 통째로 캐시하면 메모리가 배로 늘 수 있어 제외하고,
    /// 필터에서 무할당 대소문자 무시 검색으로 처리한다.
    @ObservationIgnored
    private var searchKeys: [CommitID: CommitSearchKey] = [:]
    @ObservationIgnored
    private var branchMembership: Set<CommitID>?
    /// 브랜치 범위가 남기는 커밋 집합. `branchMembership` 이 없을 때만 필터로 쓰인다.
    @ObservationIgnored
    private var branchScopeMembership: Set<CommitID>?
    @ObservationIgnored
    private var branchScopeTask: Task<Void, Never>?
    @ObservationIgnored
    private var rowsTask: Task<Void, Never>?
    /// 백그라운드 행 재빌드의 세대 번호. 반영 시점에 번호가 다르면 이미 뒤이은 요청이 있었던
    /// 것이므로 그 결과는 버린다.
    @ObservationIgnored
    private var rowsGeneration = 0
    @ObservationIgnored
    private var workspaceTask: Task<Void, Never>?
    @ObservationIgnored
    private var referenceTask: Task<Void, Never>?
    @ObservationIgnored
    private var detailsTask: Task<Void, Never>?
    @ObservationIgnored
    private var patchTask: Task<Void, Never>?
    @ObservationIgnored
    private var queryTask: Task<Void, Never>?
    @ObservationIgnored
    private var remoteTask: Task<Void, Never>?
    @ObservationIgnored
    private var githubActionsMonitorTask: Task<Void, Never>?
    @ObservationIgnored
    private var selectedGitHubChecksTask: Task<Void, Never>?
    @ObservationIgnored
    private var githubActionsFastPollUntil: Date?
    /// 실행 중인 워크플로 때문에 켜진 빠른 폴링이 끝나는 시각.
    ///
    /// 오래 도는 워크플로나 영영 끝나지 않는 것으로 보고된 실행 하나 때문에 6초 폴링이
    /// 무기한 이어지지 않도록 상한을 둔다.
    @ObservationIgnored
    private var githubActionsActiveRunFastPollDeadline: Date?
    @ObservationIgnored
    private var selectedGitHubChecksCommitID: CommitID?
    @ObservationIgnored
    private var hasRestoredWorkspace = false
    @ObservationIgnored
    private var isAutoFetching = false
    /// 모든 저장소의 자동 fetch 가 연달아 실패한 횟수.
    @ObservationIgnored
    private var autoFetchFailureStreak = 0
    @ObservationIgnored
    private var appliedAutoFetchIntervalMinutes: Int?
    @ObservationIgnored
    private var settingsObserver: AnyCancellable?
    /// `lazy` 는 매크로가 만드는 저장소 변환과 함께 쓸 수 없어 반드시 추적에서 빼야 한다.
    @ObservationIgnored
    private lazy var autoFetchScheduler = AutoFetchScheduler { [weak self] in
        await self?.performAutoFetch()
    }
    private static let workspaceTabsDefaultsKey = "workspaceTabs.v1"
    private static let activeWorkspaceTabDefaultsKey = "activeWorkspaceTabID.v1"
    private static let branchSidebarVisibleDefaultsKey = "branchSidebarVisible.v1"
    private static let commitDetailsVisibleDefaultsKey = "commitDetailsVisible.v1"

    init() {
        // 설정 창에서 자동 fetch 를 켜거나 주기를 바꾸면 곧바로 반영한다.
        // `didChangeNotification` 은 어떤 키가 바뀌었는지 알려주지 않으므로 무관한 쓰기도
        // 깨우지만, 실제 값 비교는 `syncAutoFetchScheduler()` 의 가드가 걸러 낸다.
        // `AnyCancellable` 이라 AppModel 이 해제되면 구독도 함께 풀려, 재생성된 인스턴스와
        // 이전 인스턴스의 블록이 겹쳐 실행되는 일이 없다.
        settingsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncAutoFetchScheduler()
                }
            }
    }

    /// 작성자 필터 메뉴에 쓰는 이름 목록.
    ///
    /// 계산해서 돌려주면 필터 바를 그릴 때마다 커밋 전체를 훑게 되므로, 커밋 목록이 바뀔 때
    /// 한 번만 만들어 둔다.
    private func rebuildAvailableAuthors() {
        availableAuthors = Array(
            Set(allCommits.lazy.filter { !$0.isWorkingTree }.map(\.authorName))
        ).sorted()
    }

    /// 검색 키 캐시를 커밋 목록과 함께 다시 만든다. `allCommits` 의 didSet 에서만 부르므로
    /// 캐시와 커밋 목록은 항상 같은 세대다.
    private func rebuildSearchKeys() {
        searchKeys = Dictionary(
            allCommits.map { commit in
                (
                    commit.id,
                    CommitSearchKey(
                        subject: commit.subject.localizedLowercase,
                        authorName: commit.authorName.localizedLowercase,
                        // oid 는 16진수(ASCII)라 로케일 소문자 변환이 필요 없다.
                        oid: commit.id.oid.lowercased()
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 저장소마다 최근 `commitLoadLimit`개까지만 읽으므로, 그 수를 채운 저장소는 이력이
    /// 잘렸을 가능성이 높다. 커밋 수가 정확히 상한과 같은 저장소도 안내가 뜨지만,
    /// "최근 N개 커밋만 표시" 문구 자체는 그때도 참이라 허용한다.
    private func rebuildCommitHistoryTruncation() {
        var counts: [RepositoryID: Int] = [:]
        for commit in allCommits where !commit.isWorkingTree {
            counts[commit.id.repositoryID, default: 0] += 1
        }
        isCommitHistoryTruncated = counts.values.contains { $0 >= Self.commitLoadLimit }
    }

    /// 저장소별 ref 를 이름 단위로 묶은 목록.
    ///
    /// 사이드바 `body` 는 로컬·원격·태그 섹션마다 이 값을 읽는다. 계산해서 돌려주면 ref 수백
    /// 개를 그룹핑하고 `localizedStandardCompare` 로 정렬하는 일이 화면을 그릴 때마다 반복되므로,
    /// `referencesByRepository` 가 바뀔 때 한 번만 만들어 둔다.
    private func rebuildReferenceGroups() {
        let references = referencesByRepository.values.flatMap { $0 }
        let groups = Dictionary(grouping: references) { reference in
            "\(reference.kind.rawValue)::\(reference.shortName)"
        }
        .values
        .compactMap { references -> MergedReferenceGroup? in
            guard let first = references.first else { return nil }
            return MergedReferenceGroup(
                kind: first.kind,
                shortName: first.shortName,
                references: references.sorted {
                    $0.repositoryID.rawValue < $1.repositoryID.rawValue
                }
            )
        }
        .sorted {
            if $0.kind != $1.kind {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
        }

        mergedReferenceGroups = groups
        referenceGroupsByKind = Dictionary(grouping: groups, by: \.kind)
        rebuildReferenceFolders()
        rebuildBranchScopeMenuItems()
    }

    /// 참조 목록이 바뀔 때 폴더 트리를 다시 만든다. 검색 트리도 함께 새로 세운다.
    private func rebuildReferenceFolders() {
        referenceFoldersByKind = Dictionary(
            uniqueKeysWithValues: GitReference.Kind.allCases.map { kind in
                (kind, ReferenceFolder.make(groups: referenceGroupsByKind[kind] ?? []))
            }
        )
        rebuildSearchedReferenceFolders()
    }

    /// 사이드바가 그리는 폴더 트리를 다시 만든다.
    ///
    /// 검색 결과를 트리에 이미 반영해 두므로 뷰는 걸러 낼 것도, 계층을 세울 것도 없다.
    /// 검색어가 비어 있으면 전체 트리를 그대로 쓴다.
    private func rebuildSearchedReferenceFolders() {
        let search = normalizedBranchSearch
        guard !search.isEmpty else {
            searchedReferenceFoldersByKind = referenceFoldersByKind
            return
        }
        searchedReferenceFoldersByKind = Dictionary(
            uniqueKeysWithValues: GitReference.Kind.allCases.map { kind in
                let matching = (referenceGroupsByKind[kind] ?? []).filter {
                    matchesBranchSearch($0, search: search)
                }
                return (kind, ReferenceFolder.make(groups: matching))
            }
        )
    }

    /// 브랜치 이름이나, 그 브랜치를 가진 저장소 이름 어느 쪽이든 걸리면 검색에 남긴다.
    private func matchesBranchSearch(
        _ group: MergedReferenceGroup,
        search: String
    ) -> Bool {
        if group.shortName.localizedLowercase.contains(search) { return true }
        return group.references.contains { reference in
            repositoryNamesByID[reference.repositoryID]?
                .localizedLowercase
                .contains(search) == true
        }
    }

    var workspaceURL: URL? {
        workspaceURLs.first
    }

    var activeWorkspaceTab: WorkspaceTab? {
        workspaceTabs.first { $0.id == activeWorkspaceTabID }
    }

    var isLoading: Bool {
        isLoadingWorkspace
            || isLoadingReference
            || isLoadingBranchScope
            || remoteOperation != nil
    }

    /// 대상 판단은 `MergedReferenceGroup` 이 갖는다. 메뉴의 활성화 조건과 실제 실행 대상이
    /// 같은 규칙을 쓰도록 그룹을 통째로 받는다.
    func pullRebase(_ group: MergedReferenceGroup) {
        runRemoteOperation(.pull, references: group.pullTargets)
    }

    func push(_ group: MergedReferenceGroup) {
        runRemoteOperation(.push, references: group.pushTargets)
    }

    func restoreWorkspaceIfNeeded() {
        guard !hasRestoredWorkspace else { return }
        hasRestoredWorkspace = true
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let restoredTabs = defaults.data(forKey: Self.workspaceTabsDefaultsKey)
            .flatMap { try? decoder.decode([WorkspaceTab].self, from: $0) }
            .map(validTabs(_:))
            ?? []

        if !restoredTabs.isEmpty {
            workspaceTabs = restoredTabs
            let restoredActiveID = defaults.string(
                forKey: Self.activeWorkspaceTabDefaultsKey
            ).flatMap(UUID.init(uuidString:))
            let activeID = restoredTabs.contains { $0.id == restoredActiveID }
                ? restoredActiveID
                : restoredTabs.first?.id
            if let activeID {
                activateWorkspaceTab(activeID)
            }
            return
        }

        let legacyPaths = defaults.stringArray(forKey: "lastWorkspacePaths")
            ?? defaults.string(forKey: "lastWorkspacePath").map { [$0] }
            ?? []
        let validLegacyPaths = validPaths(legacyPaths)
        guard !validLegacyPaths.isEmpty else { return }
        let legacyTab = WorkspaceTab(paths: validLegacyPaths)
        workspaceTabs = [legacyTab]
        persistWorkspaceTabs()
        activateWorkspaceTab(legacyTab.id)
    }

    func openWorkspace() {
        guard remoteOperation == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Git 저장소 또는 워크스페이스를 새 탭으로 열기"
        panel.prompt = "새 탭으로 열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addWorkspaceTabs(panel.urls)
    }

    func activateWorkspaceTab(_ id: WorkspaceTab.ID) {
        guard remoteOperation == nil,
              let tab = workspaceTabs.first(where: { $0.id == id }) else {
            return
        }
        if activeWorkspaceTabID == id {
            if workspaceURLs.isEmpty, !isLoadingWorkspace {
                loadWorkspaces(
                    tab.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                )
            }
            return
        }

        unloadCurrentWorkspace()
        activeWorkspaceTabID = id
        persistWorkspaceTabs()
        loadWorkspaces(
            tab.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    func activateWorkspaceTab(at index: Int) {
        guard workspaceTabs.indices.contains(index) else { return }
        activateWorkspaceTab(workspaceTabs[index].id)
    }

    func closeWorkspaceTab(_ id: WorkspaceTab.ID) {
        guard remoteOperation == nil,
              let closingIndex = workspaceTabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        let isClosingActiveTab = activeWorkspaceTabID == id
        let nextTabID: WorkspaceTab.ID? = if workspaceTabs.count > 1 {
            closingIndex == workspaceTabs.count - 1
                ? workspaceTabs[closingIndex - 1].id
                : workspaceTabs[closingIndex + 1].id
        } else {
            nil
        }

        if isClosingActiveTab {
            unloadCurrentWorkspace()
            activeWorkspaceTabID = nil
        }
        workspaceTabs.remove(at: closingIndex)
        persistWorkspaceTabs()

        if isClosingActiveTab, let nextTabID {
            activateWorkspaceTab(nextTabID)
        }
    }

    func refresh() {
        guard !workspaceURLs.isEmpty else { return }
        loadWorkspaces(workspaceURLs, pathFilter: normalizedPathFilter)
    }

    func fetchAll() {
        guard remoteOperation == nil, let firstRepository = repositories.first else { return }

        let operation = GitRemoteOperation(
            repositoryID: firstRepository.id,
            referenceID: repositories.map(\.id.rawValue).sorted().joined(separator: "::"),
            kind: .fetch
        )
        remoteOperation = operation
        errorMessage = nil
        remoteTask = Task {
            var failures: [String] = []
            for repository in repositories {
                do {
                    try await remoteService.fetchAll(repository: repository)
                } catch {
                    failures.append("\(repository.name): \(error.localizedDescription)")
                }
            }
            guard remoteOperation == operation else { return }
            remoteOperation = nil
            remoteTask = nil
            refresh()
            if failures.isEmpty {
                // 수동 fetch 가 통했다면 자동 fetch 가 실패하던 원인도 풀린 것으로 본다.
                clearAutoFetchFailureState()
            } else {
                errorMessage = failures.joined(separator: "\n\n")
            }
        }
    }

    /// 설정과 워크스페이스 상태에 맞춰 자동 fetch 스케줄러를 켜고 끈다.
    private func syncAutoFetchScheduler() {
        guard AppSettings.isAutoFetchEnabled, !workspaceURLs.isEmpty else {
            appliedAutoFetchIntervalMinutes = nil
            autoFetchScheduler.stop()
            return
        }

        let intervalMinutes = AppSettings.autoFetchIntervalMinutes
        guard appliedAutoFetchIntervalMinutes != intervalMinutes
                || !autoFetchScheduler.isRunning else {
            return
        }
        appliedAutoFetchIntervalMinutes = intervalMinutes
        autoFetchScheduler.start(intervalMinutes: intervalMinutes)
    }

    /// 자동 fetch 한 차례.
    ///
    /// 수동 원격 작업과 달리 `remoteOperation` 을 세우지 않아 툴바·탭 전환을 막지 않는다.
    /// git 잠금 충돌은 `GitRepositoryCommandGate` 가 저장소 단위로 쓰기 명령을 한 줄로
    /// 세워 주므로 수동 작업과 겹쳐도 생기지 않는다. 한 차례의 실패는 알리지 않고 다음
    /// 차례에 다시 시도하되, 연속 실패는 `autoFetchFailureNotice` 로 조용히 알린다.
    private func performAutoFetch() async {
        guard AppSettings.isAutoFetchEnabled,
              !isAutoFetching,
              remoteOperation == nil,
              !isLoadingWorkspace,
              !repositories.isEmpty else {
            return
        }

        isAutoFetching = true
        let targetRepositories = repositories
        var hasRemoteChanges = false
        var failureMessages: [String] = []
        for repository in targetRepositories {
            do {
                let hasChanges = try await remoteService.fetchAllDetectingChanges(
                    repository: repository
                )
                hasRemoteChanges = hasRemoteChanges || hasChanges
            } catch {
                failureMessages.append(
                    "\(repository.name): \(error.localizedDescription)"
                )
            }
        }
        isAutoFetching = false

        // fetch 도중 탭이 바뀌었으면 지금 화면과 무관한 결과이므로 갱신도, 실패 기록도 하지
        // 않는다. 사라진 탭의 저장소 이름으로 만든 안내가 새 탭에 뜨면 안 된다.
        guard remoteOperation == nil,
              !isLoadingWorkspace,
              repositories.map(\.id) == targetRepositories.map(\.id) else {
            return
        }
        recordAutoFetchOutcome(
            failureMessages: failureMessages,
            attemptedCount: targetRepositories.count
        )

        guard hasRemoteChanges else { return }
        loadWorkspaces(
            workspaceURLs,
            pathFilter: normalizedPathFilter,
            isQuiet: true
        )
    }

    /// 자동 fetch 한 차례의 결과를 연속 실패 상태에 반영한다.
    ///
    /// 저장소 하나라도 성공했다면 자격증명이 아니라 그 저장소의 사정이므로 연속 실패로 세지
    /// 않는다. 잠깐의 네트워크 단절로 안내가 뜨지 않도록 `autoFetchFailureNoticeThreshold`
    /// 번 연속으로 전부 실패한 뒤에야 표시한다.
    private func recordAutoFetchOutcome(
        failureMessages: [String],
        attemptedCount: Int
    ) {
        guard attemptedCount > 0, failureMessages.count == attemptedCount else {
            clearAutoFetchFailureState()
            return
        }

        autoFetchFailureStreak += 1
        guard autoFetchFailureStreak >= Self.autoFetchFailureNoticeThreshold else { return }
        let cause = failureMessages.first ?? "알 수 없는 오류"
        autoFetchFailureNotice = """
            자동 가져오기가 \(autoFetchFailureStreak)회 연속 실패했습니다. \
            원격 접근 권한이나 자격증명을 확인해주세요.
            마지막 오류 — \(cause)
            """
    }

    private func clearAutoFetchFailureState() {
        autoFetchFailureStreak = 0
        autoFetchFailureNotice = nil
    }

    func refreshGitHubActions() {
        githubActionsFastPollUntil = .now.addingTimeInterval(30)
        // 사용자가 직접 요청한 새로고침이므로 빠른 폴링 상한도 처음부터 다시 센다.
        githubActionsActiveRunFastPollDeadline = nil
        startGitHubActionsMonitoring(reloadAuthentication: true)
    }

    func applyPathFilter() {
        refresh()
    }

    func selectRepository(_ repository: GitRepository?) {
        referenceTask?.cancel()
        isLoadingReference = false
        repositoryScope = repository?.id
        selectedReference = nil
        selectedReferenceGroupID = nil
        isCurrentBranchesSelected = false
        branchMembership = nil
        rebuildRows()
    }

    func selectCurrentBranches() {
        referenceTask?.cancel()
        repositoryScope = nil
        selectedReference = nil
        selectedReferenceGroupID = nil
        isCurrentBranchesSelected = true
        branchMembership = nil
        isLoadingReference = true
        errorMessage = nil
        rebuildRows()

        referenceTask = Task {
            do {
                var membership = Set<CommitID>()
                for repository in repositories {
                    let currentReference = referencesByRepository[repository.id]?.first {
                        $0.kind == .local && $0.isCurrent
                    }
                    membership.formUnion(
                        try await loader.loadReachableCommitIDs(
                            repository: repository,
                            revision: currentReference?.fullName ?? "HEAD"
                        )
                    )
                    membership.insert(
                        CommitID(repositoryID: repository.id, oid: "WORKTREE")
                    )
                }
                guard !Task.isCancelled, isCurrentBranchesSelected else { return }
                branchMembership = membership
                rebuildRows()
            } catch {
                guard !Task.isCancelled else { return }
                // 그 사이 다른 선택으로 넘어갔다면 버려진 선택의 실패이므로 얼럿도 띄우지 않는다.
                if isCurrentBranchesSelected {
                    isCurrentBranchesSelected = false
                    branchMembership = nil
                    isLoadingReference = false
                    rebuildRows()
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled, isCurrentBranchesSelected {
                isLoadingReference = false
            }
        }
    }

    // MARK: - 브랜치 범위

    /// 개별 ref 그룹을 범위에 넣거나 뺀다.
    func toggleBranchScopeMember(_ group: MergedReferenceGroup) {
        var updated = branchScope
        updated.toggle(group)
        applyBranchScope(updated)
    }

    /// 지금 워크스페이스에 없는 브랜치를 해제하는 경로.
    ///
    /// 사라진 브랜치도 메뉴에 `(없음)` 으로 남겨 두므로, 그룹 객체 없이 ID 만으로 뺄 수 있어야 한다.
    func removeBranchScopeMember(id: String) {
        var updated = branchScope
        updated.referenceGroupIDs.remove(id)
        applyBranchScope(updated)
    }

    func toggleAllLocalBranchesInScope() {
        var updated = branchScope
        updated.includesAllLocalBranches.toggle()
        applyBranchScope(updated)
    }

    /// 범위만 비운다. 사이드바 선택은 건드리지 않는다.
    func clearBranchScope() {
        guard branchScope.isActive else { return }
        resetBranchScopeState()
        persistBranchScope()
        rebuildRows()
    }

    /// 사이드바 선택만 푼다. 저장해 둔 범위는 그대로여서 화면이 곧바로 범위로 돌아온다.
    ///
    /// 선택 해제 경로가 "모든 브랜치" 하나뿐이면 범위까지 함께 지워져, 잠깐 다른 브랜치를
    /// 들여다본 뒤 범위로 복귀할 방법이 없어진다.
    func clearBranchSelection() {
        selectRepository(nil)
    }

    /// 사이드바에서 브랜치나 HEAD 를 골라 둔 상태인지.
    var hasBranchSelection: Bool {
        selectedReferenceGroupID != nil || isCurrentBranchesSelected
    }

    /// 필터 메뉴의 "모든 브랜치". 넓은 축과 좁은 축을 함께 초기화한다.
    ///
    /// 범위 정리와 선택 해제가 각각 행을 재빌드하면 방금 만든 결과를 곧바로 버리게 되므로,
    /// 상태만 먼저 비우고 재빌드는 `selectRepository(nil)` 에서 한 번만 돌게 한다.
    func clearBranchFilters() {
        if branchScope.isActive {
            resetBranchScopeState()
            persistBranchScope()
        }
        selectRepository(nil)
    }

    /// 범위 상태를 비운다. 행 재빌드는 하지 않으므로 호출자가 이어서 한 번만 돌린다.
    private func resetBranchScopeState() {
        branchScopeTask?.cancel()
        branchScopeTask = nil
        branchScopeMembership = nil
        isLoadingBranchScope = false
        branchScope = .empty
        rebuildBranchScopeMenuItems()
    }

    /// 범위를 바꾸고 파생 상태·탭 저장·멤버십 재계산까지 한 번에 처리한다.
    private func applyBranchScope(_ newScope: BranchScope) {
        guard branchScope != newScope else { return }
        branchScope = newScope
        rebuildBranchScopeMenuItems()
        persistBranchScope()
        reloadBranchScopeMembership()
    }

    private func rebuildBranchScopeMenuItems() {
        branchScopeMenuItems = branchScope.menuItems(
            existingGroupIDs: Set(mergedReferenceGroups.map(\.id))
        )
    }

    /// 현재 탭에 브랜치 범위를 기록해 다음 실행과 탭 전환에서도 남게 한다.
    private func persistBranchScope() {
        guard let activeWorkspaceTabID,
              let index = workspaceTabs.firstIndex(where: { $0.id == activeWorkspaceTabID }) else {
            return
        }
        guard workspaceTabs[index].branchScope != branchScope else { return }
        workspaceTabs[index].branchScope = branchScope
        persistWorkspaceTabs()
    }

    /// 범위에 걸리는 커밋 집합을 다시 계산한다.
    ///
    /// 저장소마다 `rev-list` 한 번씩만 돌린다. 일부 저장소가 실패하면 그 저장소만 건너뛰고,
    /// 전부 실패했을 때만 오류를 알린다(`selectReferenceGroup` 과 같은 규칙).
    private func reloadBranchScopeMembership() {
        branchScopeTask?.cancel()
        branchScopeTask = nil

        guard branchScope.isActive else {
            branchScopeMembership = nil
            isLoadingBranchScope = false
            rebuildRows()
            return
        }

        let scope = branchScope
        let targets = repositories.compactMap { repository -> (GitRepository, ResolvedBranchScope)? in
            let resolved = scope.resolve(in: referencesByRepository[repository.id] ?? [])
            return resolved.isEmpty ? nil : (repository, resolved)
        }
        guard !targets.isEmpty else {
            // 범위는 켜져 있는데 해당하는 ref 가 이 워크스페이스에 하나도 없다. 필터를 조용히
            // 풀어 버리면 사용자가 켜 둔 것과 화면이 어긋나므로 빈 결과로 남긴다.
            branchScopeMembership = []
            isLoadingBranchScope = false
            rebuildRows()
            return
        }

        isLoadingBranchScope = true
        branchScopeTask = Task {
            do {
                var membership = Set<CommitID>()
                var successfulLoadCount = 0
                var lastError: Error?
                for (repository, resolved) in targets {
                    do {
                        membership.formUnion(
                            try await loader.loadReachableCommitIDs(
                                repository: repository,
                                revisions: resolved.revisions,
                                includesAllLocalBranches: resolved.includesAllLocalBranches
                            )
                        )
                        if resolved.includesWorkingTree {
                            membership.insert(
                                CommitID(repositoryID: repository.id, oid: "WORKTREE")
                            )
                        }
                        successfulLoadCount += 1
                    } catch {
                        lastError = error
                    }
                }
                if successfulLoadCount == 0, let lastError {
                    throw lastError
                }
                guard !Task.isCancelled, branchScope == scope else { return }
                branchScopeMembership = membership
                rebuildRows()
            } catch {
                guard !Task.isCancelled, branchScope == scope else { return }
                branchScopeMembership = nil
                rebuildRows()
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled, branchScope == scope {
                isLoadingBranchScope = false
            }
        }
    }

    func selectReference(_ reference: GitReference) {
        let matching = mergedReferenceGroups.first {
            $0.kind == reference.kind && $0.shortName == reference.shortName
        }
        selectReferenceGroup(
            matching ?? MergedReferenceGroup(
                kind: reference.kind,
                shortName: reference.shortName,
                references: [reference]
            )
        )
    }

    func selectReferenceGroup(_ group: MergedReferenceGroup) {
        let selectionID = group.id
        selectedReference = group.references.first
        selectedReferenceGroupID = selectionID
        isCurrentBranchesSelected = false
        repositoryScope = nil
        branchMembership = nil
        isLoadingReference = true
        errorMessage = nil
        referenceTask?.cancel()
        rebuildRows()

        referenceTask = Task {
            do {
                var membership = Set<CommitID>()
                var successfulLoadCount = 0
                var lastError: Error?
                for reference in group.references {
                    guard let repository = repositories.first(where: {
                        $0.id == reference.repositoryID
                    }) else {
                        continue
                    }
                    do {
                        membership.formUnion(
                            try await loader.loadReachableCommitIDs(
                                repository: repository,
                                reference: reference
                            )
                        )
                        if reference.isCurrent {
                            membership.insert(
                                CommitID(repositoryID: repository.id, oid: "WORKTREE")
                            )
                        }
                        successfulLoadCount += 1
                    } catch {
                        lastError = error
                    }
                }
                if successfulLoadCount == 0, let lastError {
                    throw lastError
                }
                guard !Task.isCancelled,
                      selectedReferenceGroupID == selectionID else {
                    return
                }
                branchMembership = membership
                rebuildRows()
            } catch {
                guard !Task.isCancelled else { return }
                // 다른 브랜치를 이미 골랐다면 버려진 선택의 실패이므로 얼럿도 띄우지 않는다.
                if selectedReferenceGroupID == selectionID {
                    selectedReference = nil
                    selectedReferenceGroupID = nil
                    branchMembership = nil
                    isLoadingReference = false
                    rebuildRows()
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled, selectedReferenceGroupID == selectionID {
                isLoadingReference = false
            }
        }
    }

    func toggleRepositoryVisibility(_ repository: GitRepository) {
        if visibleRepositoryIDs.contains(repository.id) {
            visibleRepositoryIDs.remove(repository.id)
        } else {
            visibleRepositoryIDs.insert(repository.id)
        }
        repositoryScope = nil
        persistRepositoryVisibility()
        rebuildRows()
    }

    func showAllRepositories() {
        visibleRepositoryIDs = Set(repositories.map(\.id))
        repositoryScope = nil
        persistRepositoryVisibility()
        rebuildRows()
    }

    /// 현재 탭에 숨긴 저장소를 기록해 다음 실행과 탭 전환에서도 필터가 남게 한다.
    private func persistRepositoryVisibility() {
        guard let activeWorkspaceTabID,
              let index = workspaceTabs.firstIndex(where: { $0.id == activeWorkspaceTabID }) else {
            return
        }
        let hiddenPaths = repositories
            .map(\.id)
            .filter { !visibleRepositoryIDs.contains($0) }
            .map(\.rawValue)
            .sorted()
        guard workspaceTabs[index].hiddenRepositoryPaths != hiddenPaths else { return }
        workspaceTabs[index].hiddenRepositoryPaths = hiddenPaths
        persistWorkspaceTabs()
    }

    func selectCommit(_ commit: GitCommit) {
        guard selectedCommit?.id != commit.id else { return }
        selectedCommit = commit
        selectedDetails = nil
        selectedFile = nil
        selectedPatch = nil
        detailsTask?.cancel()
        patchTask?.cancel()
        isLoadingPatch = false
        loadSelectedGitHubChecks(for: commit)

        guard let repository = repositories.first(where: { $0.id == commit.id.repositoryID }) else { return }
        isLoadingDetails = true
        detailsTask = Task {
            do {
                let details = try await loader.loadDetails(commit: commit, repository: repository)
                guard !Task.isCancelled else { return }
                selectedDetails = details
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled {
                isLoadingDetails = false
            }
        }
    }

    func selectChangedFile(_ file: ChangedFile) {
        guard let commit = selectedCommit,
              let repository = repositories.first(where: { $0.id == commit.id.repositoryID }) else {
            return
        }
        guard selectedFile?.id != file.id || selectedPatch == nil else { return }

        selectedFile = file
        selectedPatch = nil
        isLoadingPatch = true
        patchTask?.cancel()

        patchTask = Task {
            do {
                let patch = try await loader.loadPatch(
                    commit: commit,
                    repository: repository,
                    file: file
                )
                guard !Task.isCancelled,
                      selectedCommit?.id == commit.id,
                      selectedFile?.id == file.id else {
                    return
                }
                selectedPatch = patch
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled,
               selectedCommit?.id == commit.id,
               selectedFile?.id == file.id {
                isLoadingPatch = false
            }
        }
    }

    func clearSelection() {
        selectedCommit = nil
        selectedDetails = nil
        selectedFile = nil
        selectedPatch = nil
        detailsTask?.cancel()
        patchTask?.cancel()
        selectedGitHubChecksTask?.cancel()
        selectedGitHubChecksTask = nil
        selectedGitHubChecks.removeAll(keepingCapacity: false)
        selectedGitHubChecksCommitID = nil
        isLoadingDetails = false
        isLoadingPatch = false
        isLoadingSelectedGitHubChecks = false
    }

    private var normalizedPathFilter: String? {
        let value = pathFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func runRemoteOperation(
        _ kind: GitRemoteOperationKind,
        references: [GitReference]
    ) {
        guard remoteOperation == nil else { return }
        let targets = references.compactMap { reference -> (GitRepository, GitReference)? in
            guard let repository = repositories.first(where: {
                $0.id == reference.repositoryID
            }) else {
                return nil
            }
            return (repository, reference)
        }
        guard let firstTarget = targets.first else { return }

        let operation = GitRemoteOperation(
            repositoryID: firstTarget.0.id,
            referenceID: targets.map { $0.1.id }.sorted().joined(separator: "::"),
            kind: kind
        )
        remoteOperation = operation
        errorMessage = nil
        remoteTask = Task {
            var failures: [String] = []
            var completedPush = false
            for (repository, reference) in targets {
                do {
                    switch kind {
                    case .fetch:
                        break
                    case .pull:
                        try await remoteService.pullRebase(
                            repository: repository,
                            reference: reference
                        )
                    case .push:
                        try await remoteService.push(
                            repository: repository,
                            reference: reference
                        )
                        completedPush = true
                    }
                } catch {
                    failures.append(
                        "\(repository.name) · \(reference.shortName): \(error.localizedDescription)"
                    )
                }
            }
            guard remoteOperation == operation else { return }
            remoteOperation = nil
            remoteTask = nil
            if completedPush {
                githubActionsFastPollUntil = .now.addingTimeInterval(60)
            }
            refresh()
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n\n")
            }
        }
    }

    /// - Parameter isQuiet: 자동 fetch 가 부르는 갱신 경로. 로딩 화면을 띄우지 않고,
    ///   사용자가 보고 있던 선택 커밋과 브랜치 필터를 로드 후 되살린다.
    private func loadWorkspaces(
        _ urls: [URL],
        pathFilter: String? = nil,
        isQuiet: Bool = false
    ) {
        guard remoteOperation == nil else { return }
        let uniqueURLs = uniqueWorkspaceURLs(urls)
        guard !uniqueURLs.isEmpty else { return }
        let preservedSelection: QuietSelection? = isQuiet
            ? QuietSelection(
                commitID: selectedCommit?.id,
                referenceGroupID: selectedReferenceGroupID,
                repositoryScope: repositoryScope,
                isCurrentBranchesSelected: isCurrentBranchesSelected
            )
            : nil

        if !isQuiet {
            isLoadingWorkspace = true
            errorMessage = nil
            clearSelection()
        }
        githubActionsMonitorTask?.cancel()
        githubActionsMonitorTask = nil
        workspaceTask?.cancel()
        referenceTask?.cancel()
        isLoadingReference = false

        workspaceTask = Task {
            do {
                // 저장소 하나가 망가져도(원본이 사라진 worktree, 권한 문제 등) 나머지는 그대로
                // 보여주고, 읽지 못한 저장소만 따로 안내한다. 전부 실패하면 여기서 던진다.
                let report = try await loader.loadWorkspacesReport(
                    at: uniqueURLs,
                    commitLimit: Self.commitLoadLimit,
                    pathFilter: pathFilter
                )
                let snapshot = report.snapshot
                guard !Task.isCancelled else { return }
                repositoryLoadNotice = Self.makeRepositoryLoadNotice(report.failures)
                referenceTask?.cancel()
                isLoadingReference = false
                if !isQuiet {
                    clearSelection()
                }
                workspaceURLs = uniqueURLs
                repositories = snapshot.repositories
                referencesByRepository = snapshot.referencesByRepository
                let hiddenPaths = Set(activeWorkspaceTab?.hiddenRepositoryPaths ?? [])
                visibleRepositoryIDs = Set(
                    snapshot.repositories
                        .map(\.id)
                        .filter { !hiddenPaths.contains($0.rawValue) }
                )
                // 탭에 저장해 둔 범위를 되살린다. 조용한 갱신에서는 이미 같은 값이지만,
                // 아래 재계산은 그때도 돌아야 한다(새 커밋이 범위 안 브랜치에 들어왔을 수 있다).
                branchScope = activeWorkspaceTab?.branchScope ?? .empty
                rebuildBranchScopeMenuItems()
                allCommits = snapshot.commits
                repositoryScope = nil
                selectedReference = nil
                selectedReferenceGroupID = nil
                isCurrentBranchesSelected = false
                branchMembership = nil
                rebuildRowsImmediately()
                if let preservedSelection {
                    restoreQuietSelection(preservedSelection)
                }
                reloadBranchScopeMembership()
                startGitHubActionsMonitoring()
                syncAutoFetchScheduler()
            } catch {
                guard !Task.isCancelled else { return }
                if !isQuiet {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isLoadingWorkspace = false
            }
        }
    }

    /// 읽지 못한 저장소를 경로와 원인으로 한 줄씩 정리한다. 얼럿이 아니라 툴바 툴팁으로
    /// 보여주므로 목록이 길어져도 화면을 가리지 않는다.
    private static func makeRepositoryLoadNotice(
        _ failures: [RepositoryLoadFailure]
    ) -> String? {
        guard !failures.isEmpty else { return nil }
        let lines = failures.map { "\($0.rootURL.path) — \($0.message)" }
        return (["저장소 \(failures.count)개를 읽지 못했습니다."] + lines)
            .joined(separator: "\n")
    }

    /// 조용한 갱신 전에 붙잡아 두는, 사용자가 보고 있던 선택 상태.
    private struct QuietSelection {
        let commitID: CommitID?
        let referenceGroupID: String?
        let repositoryScope: RepositoryID?
        let isCurrentBranchesSelected: Bool
    }

    /// 조용한 갱신 뒤 선택 상태를 되살린다.
    ///
    /// 선택 커밋이 새 목록에 남아 있는지는 `rebuildRowsImmediately()` 가 이미 판단했으므로
    /// 그 결과를 존중하고, 커밋 인스턴스만 새로 읽은 것으로 바꿔 브랜치·태그 배지를 최신화한다.
    private func restoreQuietSelection(_ selection: QuietSelection) {
        if let commitID = selection.commitID,
           selectedCommit?.id == commitID,
           let refreshedCommit = allCommits.first(where: { $0.id == commitID }) {
            selectedCommit = refreshedCommit
        }

        if selection.isCurrentBranchesSelected {
            selectCurrentBranches()
        } else if let referenceGroupID = selection.referenceGroupID,
                  let group = mergedReferenceGroups.first(where: { $0.id == referenceGroupID }) {
            selectReferenceGroup(group)
        } else if let scope = selection.repositoryScope,
                  repositories.contains(where: { $0.id == scope }) {
            repositoryScope = scope
            rebuildRows()
        }
    }

    private func uniqueWorkspaceURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.compactMap { url in
            let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            return seenPaths.insert(normalizedURL.path).inserted ? normalizedURL : nil
        }
    }

    private func addWorkspaceTabs(_ urls: [URL]) {
        let normalizedURLs = uniqueWorkspaceURLs(urls)
        guard !normalizedURLs.isEmpty else { return }

        var firstSelectedTabID: WorkspaceTab.ID?
        for url in normalizedURLs {
            let path = url.path
            if let existingTab = workspaceTabs.first(where: { $0.paths == [path] }) {
                firstSelectedTabID = firstSelectedTabID ?? existingTab.id
                continue
            }
            let tab = WorkspaceTab(paths: [path])
            workspaceTabs.append(tab)
            firstSelectedTabID = firstSelectedTabID ?? tab.id
        }
        persistWorkspaceTabs()

        if let firstSelectedTabID {
            activateWorkspaceTab(firstSelectedTabID)
        }
    }

    private func unloadCurrentWorkspace() {
        autoFetchScheduler.stop()
        appliedAutoFetchIntervalMinutes = nil
        isAutoFetching = false
        workspaceTask?.cancel()
        referenceTask?.cancel()
        branchScopeTask?.cancel()
        detailsTask?.cancel()
        patchTask?.cancel()
        queryTask?.cancel()
        githubActionsMonitorTask?.cancel()
        selectedGitHubChecksTask?.cancel()
        // 진행 중이던 백그라운드 재빌드가 비운 목록 위에 이전 워크스페이스의 행을 되살리지
        // 않도록 세대를 넘겨 무효화한다.
        rowsGeneration += 1
        rowsTask?.cancel()
        rowsTask = nil
        workspaceTask = nil
        referenceTask = nil
        branchScopeTask = nil
        detailsTask = nil
        patchTask = nil
        queryTask = nil
        githubActionsMonitorTask = nil
        selectedGitHubChecksTask = nil

        workspaceURLs.removeAll(keepingCapacity: false)
        repositories.removeAll(keepingCapacity: false)
        referencesByRepository.removeAll(keepingCapacity: false)
        visibleRepositoryIDs.removeAll(keepingCapacity: false)
        rows.removeAll(keepingCapacity: false)
        allCommits.removeAll(keepingCapacity: false)
        githubActionsByCommit.removeAll(keepingCapacity: false)
        selectedGitHubChecks.removeAll(keepingCapacity: false)
        selectedGitHubChecksCommitID = nil
        branchMembership = nil
        branchScopeMembership = nil
        // 탭에 저장된 범위는 그대로 두고 화면 상태만 비운다. 다음 탭 로드가 그 탭의 범위로
        // 다시 채운다.
        branchScope = .empty
        branchScopeMenuItems.removeAll(keepingCapacity: false)
        selectedCommit = nil
        selectedDetails = nil
        selectedFile = nil
        selectedPatch = nil
        selectedReference = nil
        selectedReferenceGroupID = nil
        repositoryScope = nil
        isCurrentBranchesSelected = false

        isLoadingWorkspace = false
        isLoadingReference = false
        isLoadingBranchScope = false
        isLoadingDetails = false
        isLoadingPatch = false
        isLoadingSelectedGitHubChecks = false
        errorMessage = nil
        githubActionsNotice = nil
        githubActionsFastPollUntil = nil
        githubActionsActiveRunFastPollDeadline = nil
        repositoryLoadNotice = nil
        clearAutoFetchFailureState()

        query = ""
        branchSearch = ""
        pathFilter = ""
        authorFilter = nil
        dateScope = .all
        queryTask?.cancel()
        queryTask = nil
    }

    private func validTabs(_ tabs: [WorkspaceTab]) -> [WorkspaceTab] {
        tabs.compactMap { tab in
            let paths = validPaths(tab.paths)
            return paths.isEmpty ? nil : WorkspaceTab(
                id: tab.id,
                paths: paths,
                hiddenRepositoryPaths: tab.hiddenRepositoryPaths,
                branchScope: tab.branchScope
            )
        }
    }

    private func validPaths(_ paths: [String]) -> [String] {
        var seenPaths = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path),
                  seenPaths.insert(url.path).inserted else {
                return nil
            }
            return url.path
        }
    }

    private func persistWorkspaceTabs() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(workspaceTabs) {
            defaults.set(data, forKey: Self.workspaceTabsDefaultsKey)
        }
        if let activeWorkspaceTabID {
            defaults.set(
                activeWorkspaceTabID.uuidString,
                forKey: Self.activeWorkspaceTabDefaultsKey
            )
        } else {
            defaults.removeObject(forKey: Self.activeWorkspaceTabDefaultsKey)
        }
        defaults.removeObject(forKey: "lastWorkspacePaths")
        defaults.removeObject(forKey: "lastWorkspacePath")
    }

    /// 필터링과 그래프 레이아웃 계산을 백그라운드로 보낸다.
    ///
    /// 큰 워크스페이스에서는 `CommitGraphLayout.makeRows` 가 수천 행을 훑으므로 메인에서
    /// 돌리면 필터를 바꿀 때마다 UI가 멈춘다. 입력을 값으로 스냅샷해 백그라운드에서 계산하고,
    /// 반영 시점에 세대 번호가 그대로일 때만(=마지막 요청일 때만) 결과를 쓴다. 계산 중에도
    /// 기존 `rows` 는 그대로 둬 목록이 비었다 차는 깜빡임을 막는다.
    private func rebuildRows() {
        rowsGeneration += 1
        let generation = rowsGeneration
        let input = makeRowComputationInput()
        rowsTask?.cancel()
        rowsTask = Task.detached(priority: .userInitiated) { [weak self] in
            let newRows = computeCommitRows(input)
            guard !Task.isCancelled else { return }
            await self?.applyComputedRows(newRows, generation: generation)
        }
    }

    /// 워크스페이스 적재 직후처럼 보여 줄 기존 `rows` 가 없는 시점 전용 동기 재빌드.
    ///
    /// 이 경로까지 백그라운드로 보내면 로딩이 끝난 화면에 빈 목록이 잠깐 비쳤다 채워지고,
    /// 조용한 갱신에서는 `restoreQuietSelection` 이 "선택 커밋이 새 목록에 남아 있는가"를
    /// 재빌드가 이미 판단했다고 전제하는 순서가 깨진다.
    private func rebuildRowsImmediately() {
        rowsGeneration += 1
        rowsTask?.cancel()
        rowsTask = nil
        applyComputedRows(
            computeCommitRows(makeRowComputationInput()),
            generation: rowsGeneration
        )
    }

    private func makeRowComputationInput() -> CommitRowComputationInput {
        CommitRowComputationInput(
            commits: allCommits,
            searchKeys: searchKeys,
            visibleRepositoryIDs: visibleRepositoryIDs,
            repositoryScope: repositoryScope,
            branchMembership: branchMembership,
            branchScopeMembership: branchScopeMembership,
            authorFilter: authorFilter,
            dateBounds: dateScope.bounds(),
            normalizedQuery: query.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedLowercase
        )
    }

    private func applyComputedRows(_ newRows: [CommitRow], generation: Int) {
        guard generation == rowsGeneration else { return }
        rowsTask = nil
        rows = newRows
        if let selectedCommit, !newRows.contains(where: { $0.id == selectedCommit.id }) {
            clearSelection()
        }
    }

    private func scheduleQueryRebuild() {
        queryTask?.cancel()
        queryTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            rebuildRows()
        }
    }

    private func startGitHubActionsMonitoring(
        reloadAuthentication: Bool = false
    ) {
        githubActionsMonitorTask?.cancel()
        githubActionsMonitorTask = nil

        let monitoredRepositories = repositories.filter { $0.githubRepository != nil }
        guard !monitoredRepositories.isEmpty else {
            githubActionsByCommit.removeAll(keepingCapacity: false)
            githubActionsNotice = nil
            return
        }

        let repositoryIDs = Set(monitoredRepositories.map(\.id))
        githubActionsMonitorTask = Task { [weak self] in
            guard let self else { return }
            if reloadAuthentication {
                await self.githubActionsService.reloadAuthentication()
            }
            let isAuthenticated = await self.githubActionsService.isAuthenticated()
            while !Task.isCancelled {
                let rateLimitRetryAt = await self.loadGitHubActionsOnce(
                    repositories: monitoredRepositories,
                    expectedRepositoryIDs: repositoryIDs
                )
                guard !Task.isCancelled else { return }

                do {
                    try await Task.sleep(
                        for: self.nextGitHubActionsPollInterval(
                            isAuthenticated: isAuthenticated,
                            rateLimitRetryAt: rateLimitRetryAt
                        )
                    )
                } catch {
                    return
                }
            }
        }
    }

    /// 다음 폴링까지 쉴 시간.
    ///
    /// - 레이트리밋에 걸렸으면 어떤 경우에도 `retryAt` 전에는 다시 부르지 않는다. 한도를
    ///   넘긴 채로 6초마다 두드려 봐야 같은 거절만 돌아온다.
    /// - 실행 중인 워크플로가 있으면 주기를 6초로 좁히되, 오래 도는(또는 상태가 끝내
    ///   갱신되지 않는) 실행 하나 때문에 빠른 폴링이 무기한 이어지지 않도록
    ///   `githubActionsActiveRunFastPollWindow` 를 넘기면 기본 주기로 돌아간다.
    private func nextGitHubActionsPollInterval(
        isAuthenticated: Bool,
        rateLimitRetryAt: Date?
    ) -> Duration {
        let hasActiveRun = githubActionsByCommit.values.contains { $0.state.isActive }
        if hasActiveRun {
            if githubActionsActiveRunFastPollDeadline == nil {
                githubActionsActiveRunFastPollDeadline = .now.addingTimeInterval(
                    Self.githubActionsActiveRunFastPollWindow
                )
            }
        } else {
            githubActionsActiveRunFastPollDeadline = nil
        }

        let isFastPolling = (githubActionsActiveRunFastPollDeadline.map { $0 > .now } ?? false)
            || (githubActionsFastPollUntil.map { $0 > .now } ?? false)
        let interval: Duration = if isAuthenticated {
            isFastPolling ? .seconds(6) : .seconds(60)
        } else {
            isFastPolling ? .seconds(15) : .seconds(300)
        }

        guard let rateLimitRetryAt else { return interval }
        return max(interval, .seconds(max(0, rateLimitRetryAt.timeIntervalSinceNow)))
    }

    /// - Returns: 레이트리밋에 걸렸다면 다시 시도할 수 있는 시각. 아니면 `nil`.
    private func loadGitHubActionsOnce(
        repositories: [GitRepository],
        expectedRepositoryIDs: Set<RepositoryID>
    ) async -> Date? {
        var updatedSummaries = githubActionsByCommit
        var notices: [String] = []
        var rateLimitRetryAt: Date?

        for repository in repositories {
            guard !Task.isCancelled else { return nil }
            do {
                let summaries = try await githubActionsService.loadWorkflowSummaries(
                    repository: repository
                )
                guard Set(
                    self.repositories.filter { $0.githubRepository != nil }.map(\.id)
                ) == expectedRepositoryIDs else {
                    return nil
                }
                updatedSummaries = updatedSummaries.filter {
                    $0.key.repositoryID != repository.id
                }
                updatedSummaries.merge(summaries) { _, new in new }
            } catch {
                notices.append("\(repository.name): \(error.localizedDescription)")
                if case let GitHubActionsServiceError.rateLimited(status) = error {
                    // 한도는 계정 단위라 남은 저장소를 더 물어봐야 같은 거절만 받는다.
                    rateLimitRetryAt = status.retryAt
                    break
                }
            }
        }

        guard !Task.isCancelled,
              Set(
                  self.repositories.filter { $0.githubRepository != nil }.map(\.id)
              ) == expectedRepositoryIDs else {
            return nil
        }
        githubActionsByCommit = updatedSummaries
        githubActionsNotice = notices.isEmpty
            ? nil
            : notices.joined(separator: "\n")

        if let selectedCommit,
           githubActionsByCommit[selectedCommit.id] != nil,
           (selectedGitHubChecksCommitID != selectedCommit.id
               || githubActionsByCommit[selectedCommit.id]?.state.isActive == true) {
            loadSelectedGitHubChecks(for: selectedCommit, preserveExisting: true)
        }
        return rateLimitRetryAt
    }

    private func loadSelectedGitHubChecks(
        for commit: GitCommit,
        preserveExisting: Bool = false
    ) {
        selectedGitHubChecksTask?.cancel()
        selectedGitHubChecksTask = nil
        if !preserveExisting {
            selectedGitHubChecks.removeAll(keepingCapacity: false)
            selectedGitHubChecksCommitID = nil
        }
        isLoadingSelectedGitHubChecks = false

        guard !commit.isWorkingTree,
              githubActionsByCommit[commit.id] != nil,
              let repository = repositories.first(where: {
                  $0.id == commit.id.repositoryID
              }),
              repository.githubRepository != nil else {
            return
        }

        isLoadingSelectedGitHubChecks = true
        selectedGitHubChecksTask = Task {
            do {
                let checks = try await githubActionsService.loadCheckRuns(
                    repository: repository,
                    commitSHA: commit.id.oid
                )
                guard !Task.isCancelled, selectedCommit?.id == commit.id else { return }
                selectedGitHubChecks = checks
                selectedGitHubChecksCommitID = commit.id
            } catch {
                guard !Task.isCancelled, selectedCommit?.id == commit.id else { return }
                githubActionsNotice = "\(repository.name): \(error.localizedDescription)"
            }
            if !Task.isCancelled, selectedCommit?.id == commit.id {
                isLoadingSelectedGitHubChecks = false
                selectedGitHubChecksTask = nil
            }
        }
    }
}

/// 커밋당 미리 소문자화해 둔 검색 키. body 는 커서 캐시하지 않고 필터에서 무할당
/// 대소문자 무시 검색으로 처리한다.
private struct CommitSearchKey: Sendable {
    let subject: String
    let authorName: String
    let oid: String
}

/// 행 재빌드에 넘기는 필터 입력 스냅샷.
///
/// 백그라운드 계산이 MainActor 상태를 직접 읽지 않도록 재빌드 요청 시점의 값을 복사해 간다.
/// AppModel 안에 두면 클래스의 MainActor 격리를 물려받을 수 있어 파일 스코프에 둔다.
private struct CommitRowComputationInput: Sendable {
    let commits: [GitCommit]
    let searchKeys: [CommitID: CommitSearchKey]
    let visibleRepositoryIDs: Set<RepositoryID>
    let repositoryScope: RepositoryID?
    let branchMembership: Set<CommitID>?
    let branchScopeMembership: Set<CommitID>?
    let authorFilter: String?
    let dateBounds: HistoryDateScope.Bounds
    let normalizedQuery: String
}

/// 필터링과 그래프 레이아웃 계산. 입력·출력이 모두 값이라 어느 스레드에서든 안전하다.
private func computeCommitRows(_ input: CommitRowComputationInput) -> [CommitRow] {
    let filtered = input.commits.filter { commit in
        if !input.visibleRepositoryIDs.contains(commit.id.repositoryID) { return false }
        if let scope = input.repositoryScope, commit.id.repositoryID != scope { return false }
        // 브랜치 축은 두 층이고 교집합이 아니라 덮어쓰기다. 사이드바 선택이 있으면 그쪽이
        // 이기고, 없을 때만 저장해 둔 범위가 적용된다.
        if let membership = input.branchMembership {
            if !membership.contains(commit.id) { return false }
        } else if let scopeMembership = input.branchScopeMembership {
            if !scopeMembership.contains(commit.id) { return false }
        }
        if let author = input.authorFilter, commit.authorName != author { return false }
        if !input.dateBounds.contains(commit.committerDate) { return false }
        if input.normalizedQuery.isEmpty { return true }
        guard let key = input.searchKeys[commit.id] else { return false }
        // body 검색이 가장 비싸므로 마지막에 둔다.
        return key.subject.contains(input.normalizedQuery)
            || key.authorName.contains(input.normalizedQuery)
            || key.oid.hasPrefix(input.normalizedQuery)
            || commit.body.range(of: input.normalizedQuery, options: .caseInsensitive) != nil
    }
    return CommitGraphLayout.makeRows(commits: filtered)
}

private extension HistoryDateScope {
    /// 재빌드 진입 시 한 번 계산해 두는 포함 범위 경계.
    ///
    /// `includes(_:)` 는 호출마다 `Calendar.current` 에 접근하므로 커밋 수천 개를 거르는 필터
    /// 안에서 커밋당 부르기엔 비싸다. 경계 Date 만 미리 뽑아 단순 비교로 같은 판정을 내린다.
    enum Bounds: Sendable {
        case all
        case range(Range<Date>)
        case since(Date)

        func contains(_ date: Date) -> Bool {
            switch self {
            case .all: return true
            case .range(let range): return range.contains(date)
            case .since(let start): return date >= start
            }
        }
    }

    func bounds(now: Date = .now) -> Bounds {
        let calendar = Calendar.current
        switch self {
        case .all:
            return .all
        case .today:
            let start = calendar.startOfDay(for: now)
            return .range(start..<calendar.date(byAdding: .day, value: 1, to: start)!)
        case .sevenDays:
            return .since(calendar.date(byAdding: .day, value: -7, to: now)!)
        case .thirtyDays:
            return .since(calendar.date(byAdding: .day, value: -30, to: now)!)
        }
    }
}
