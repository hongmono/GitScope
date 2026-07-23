import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaceTabs: [WorkspaceTab] = []
    @Published private(set) var activeWorkspaceTabID: WorkspaceTab.ID?
    @Published private(set) var workspaceURLs: [URL] = []
    @Published private(set) var repositories: [GitRepository] = []
    @Published private(set) var referencesByRepository: [RepositoryID: [GitReference]] = [:]
    @Published private(set) var visibleRepositoryIDs: Set<RepositoryID> = []
    @Published private(set) var rows: [CommitRow] = []
    @Published private(set) var selectedCommit: GitCommit?
    @Published private(set) var selectedDetails: CommitDetails?
    @Published private(set) var selectedFile: ChangedFile?
    @Published private(set) var selectedPatch: String?
    @Published private(set) var githubActionsByCommit: [CommitID: GitHubActionsSummary] = [:]
    @Published private(set) var selectedGitHubChecks: [GitHubCheckRun] = []
    @Published private(set) var isLoadingSelectedGitHubChecks = false
    @Published private(set) var githubActionsNotice: String?
    @Published private(set) var isLoadingWorkspace = false
    @Published private(set) var isLoadingReference = false
    @Published private(set) var isLoadingDetails = false
    @Published private(set) var isLoadingPatch = false
    @Published private(set) var remoteOperation: GitRemoteOperation?
    @Published var errorMessage: String?

    @Published var query = "" {
        didSet { scheduleQueryRebuild() }
    }
    @Published var branchSearch = ""
    @Published var pathFilter = ""
    @Published var authorFilter: String? {
        didSet { rebuildRows() }
    }
    @Published var dateScope: HistoryDateScope = .all {
        didSet { rebuildRows() }
    }
    @Published private(set) var repositoryScope: RepositoryID? {
        didSet { rebuildRows() }
    }
    @Published private(set) var selectedReference: GitReference?
    @Published private(set) var selectedReferenceGroupID: String?
    @Published private(set) var isCurrentBranchesSelected = false

    private let loader = GitRepositoryLoader()
    private let remoteService = GitRemoteService()
    private let githubActionsService = GitHubActionsService.shared
    private var allCommits: [GitCommit] = []
    private var branchMembership: Set<CommitID>?
    private var workspaceTask: Task<Void, Never>?
    private var referenceTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var patchTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var githubActionsMonitorTask: Task<Void, Never>?
    private var selectedGitHubChecksTask: Task<Void, Never>?
    private var githubActionsFastPollUntil: Date?
    private var selectedGitHubChecksCommitID: CommitID?
    private var hasRestoredWorkspace = false
    private static let workspaceTabsDefaultsKey = "workspaceTabs.v1"
    private static let activeWorkspaceTabDefaultsKey = "activeWorkspaceTabID.v1"

    var availableAuthors: [String] {
        Array(Set(allCommits.filter { !$0.isWorkingTree }.map(\.authorName))).sorted()
    }

    var mergedReferenceGroups: [MergedReferenceGroup] {
        let references = referencesByRepository.values.flatMap { $0 }
        let grouped = Dictionary(grouping: references) { reference in
            "\(reference.kind.rawValue)::\(reference.shortName)"
        }
        return grouped.values
            .compactMap { references in
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
                    return referenceKindOrder($0.kind) < referenceKindOrder($1.kind)
                }
                return $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
            }
    }

    var workspaceURL: URL? {
        workspaceURLs.first
    }

    var activeWorkspaceTab: WorkspaceTab? {
        workspaceTabs.first { $0.id == activeWorkspaceTabID }
    }

    var isLoading: Bool {
        isLoadingWorkspace || isLoadingReference || remoteOperation != nil
    }

    func pullRebase(_ references: [GitReference]) {
        let targets = references.filter {
            $0.kind == .local
                && $0.isCurrent
                && $0.tracking != nil
                && $0.tracking?.isGone != true
        }
        runRemoteOperation(.pull, references: targets)
    }

    func push(_ references: [GitReference]) {
        let targets = references.filter {
            $0.kind == .local
                && $0.tracking != nil
                && $0.tracking?.isGone != true
        }
        runRemoteOperation(.push, references: targets)
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
        loadWorkspaces(
            workspaceURLs,
            pathFilter: normalizedPathFilter,
            preserveRepositoryVisibility: true
        )
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
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n\n")
            }
        }
    }

    func refreshGitHubActions() {
        githubActionsFastPollUntil = .now.addingTimeInterval(30)
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
                isCurrentBranchesSelected = false
                branchMembership = nil
                isLoadingReference = false
                rebuildRows()
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled, isCurrentBranchesSelected {
                isLoadingReference = false
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
                if selectedReferenceGroupID == selectionID {
                    selectedReference = nil
                    selectedReferenceGroupID = nil
                    branchMembership = nil
                    isLoadingReference = false
                    rebuildRows()
                }
                errorMessage = error.localizedDescription
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
        rebuildRows()
    }

    func showAllRepositories() {
        visibleRepositoryIDs = Set(repositories.map(\.id))
        repositoryScope = nil
        rebuildRows()
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

    private func loadWorkspaces(
        _ urls: [URL],
        pathFilter: String? = nil,
        preserveRepositoryVisibility: Bool = false
    ) {
        guard remoteOperation == nil else { return }
        let uniqueURLs = uniqueWorkspaceURLs(urls)
        guard !uniqueURLs.isEmpty else { return }
        let previousRepositoryIDs = Set(repositories.map(\.id))
        let previouslyHiddenRepositoryIDs = previousRepositoryIDs
            .subtracting(visibleRepositoryIDs)

        isLoadingWorkspace = true
        errorMessage = nil
        githubActionsMonitorTask?.cancel()
        githubActionsMonitorTask = nil
        clearSelection()
        workspaceTask?.cancel()
        referenceTask?.cancel()
        isLoadingReference = false

        workspaceTask = Task {
            do {
                let snapshot = try await loader.loadWorkspaces(at: uniqueURLs, pathFilter: pathFilter)
                guard !Task.isCancelled else { return }
                referenceTask?.cancel()
                isLoadingReference = false
                clearSelection()
                workspaceURLs = uniqueURLs
                repositories = snapshot.repositories
                referencesByRepository = snapshot.referencesByRepository
                let loadedRepositoryIDs = Set(snapshot.repositories.map(\.id))
                visibleRepositoryIDs = preserveRepositoryVisibility
                    ? loadedRepositoryIDs.subtracting(previouslyHiddenRepositoryIDs)
                    : loadedRepositoryIDs
                allCommits = snapshot.commits
                repositoryScope = nil
                selectedReference = nil
                selectedReferenceGroupID = nil
                isCurrentBranchesSelected = false
                branchMembership = nil
                rebuildRows()
                startGitHubActionsMonitoring()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled {
                isLoadingWorkspace = false
            }
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
        workspaceTask?.cancel()
        referenceTask?.cancel()
        detailsTask?.cancel()
        patchTask?.cancel()
        queryTask?.cancel()
        githubActionsMonitorTask?.cancel()
        selectedGitHubChecksTask?.cancel()
        workspaceTask = nil
        referenceTask = nil
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
        isLoadingDetails = false
        isLoadingPatch = false
        isLoadingSelectedGitHubChecks = false
        errorMessage = nil
        githubActionsNotice = nil
        githubActionsFastPollUntil = nil

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
            return paths.isEmpty ? nil : WorkspaceTab(id: tab.id, paths: paths)
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

    private func rebuildRows() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        let filtered = allCommits.filter { commit in
            if !visibleRepositoryIDs.contains(commit.id.repositoryID) { return false }
            if let repositoryScope, commit.id.repositoryID != repositoryScope { return false }
            if let branchMembership, !branchMembership.contains(commit.id) { return false }
            if let authorFilter, commit.authorName != authorFilter { return false }
            if !dateScope.includes(commit.committerDate) { return false }
            if normalizedQuery.isEmpty { return true }
            return commit.subject.localizedLowercase.contains(normalizedQuery)
                || commit.authorName.localizedLowercase.contains(normalizedQuery)
                || commit.id.oid.localizedLowercase.hasPrefix(normalizedQuery)
        }
        rows = CommitGraphLayout.makeRows(commits: filtered)
        if let selectedCommit, !rows.contains(where: { $0.id == selectedCommit.id }) {
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
                await self.loadGitHubActionsOnce(
                    repositories: monitoredRepositories,
                    expectedRepositoryIDs: repositoryIDs
                )
                guard !Task.isCancelled else { return }

                let hasActiveRun = self.githubActionsByCommit.values.contains {
                    $0.state.isActive
                }
                let isFastPolling = hasActiveRun
                    || (self.githubActionsFastPollUntil.map { $0 > .now } ?? false)
                let interval: Duration = if isAuthenticated {
                    isFastPolling ? .seconds(6) : .seconds(60)
                } else {
                    isFastPolling ? .seconds(15) : .seconds(300)
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func loadGitHubActionsOnce(
        repositories: [GitRepository],
        expectedRepositoryIDs: Set<RepositoryID>
    ) async {
        var updatedSummaries = githubActionsByCommit
        var notices: [String] = []

        for repository in repositories {
            guard !Task.isCancelled else { return }
            do {
                let summaries = try await githubActionsService.loadWorkflowSummaries(
                    repository: repository
                )
                guard Set(
                    self.repositories.filter { $0.githubRepository != nil }.map(\.id)
                ) == expectedRepositoryIDs else {
                    return
                }
                updatedSummaries = updatedSummaries.filter {
                    $0.key.repositoryID != repository.id
                }
                updatedSummaries.merge(summaries) { _, new in new }
            } catch {
                notices.append("\(repository.name): \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled,
              Set(
                  self.repositories.filter { $0.githubRepository != nil }.map(\.id)
              ) == expectedRepositoryIDs else {
            return
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

    private func referenceKindOrder(_ kind: GitReference.Kind) -> Int {
        switch kind {
        case .local: return 0
        case .remote: return 1
        case .tag: return 2
        }
    }
}
