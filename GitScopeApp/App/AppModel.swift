import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaceURLs: [URL] = []
    @Published private(set) var repositories: [GitRepository] = []
    @Published private(set) var referencesByRepository: [RepositoryID: [GitReference]] = [:]
    @Published private(set) var visibleRepositoryIDs: Set<RepositoryID> = []
    @Published private(set) var rows: [CommitRow] = []
    @Published private(set) var selectedCommit: GitCommit?
    @Published private(set) var selectedDetails: CommitDetails?
    @Published private(set) var selectedFile: ChangedFile?
    @Published private(set) var selectedPatch: String?
    @Published private(set) var isLoadingWorkspace = false
    @Published private(set) var isLoadingReference = false
    @Published private(set) var isLoadingDetails = false
    @Published private(set) var isLoadingPatch = false
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
    private var allCommits: [GitCommit] = []
    private var branchMembership: Set<CommitID>?
    private var workspaceTask: Task<Void, Never>?
    private var referenceTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var patchTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var hasRestoredWorkspace = false

    var availableAuthors: [String] {
        Array(Set(allCommits.map(\.authorName))).sorted()
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

    var isLoading: Bool {
        isLoadingWorkspace || isLoadingReference
    }

    func restoreWorkspaceIfNeeded() {
        guard !hasRestoredWorkspace else { return }
        hasRestoredWorkspace = true
        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: "lastWorkspacePaths")
            ?? defaults.string(forKey: "lastWorkspacePath").map { [$0] }
            ?? []
        let urls = paths
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        loadWorkspaces(urls)
    }

    func openWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Git 저장소 또는 워크스페이스 선택"
        panel.prompt = "열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        loadWorkspaces(panel.urls)
    }

    func refresh() {
        guard !workspaceURLs.isEmpty else { return }
        loadWorkspaces(
            workspaceURLs,
            pathFilter: normalizedPathFilter,
            preserveRepositoryVisibility: true
        )
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
        isLoadingDetails = false
        isLoadingPatch = false
    }

    private var normalizedPathFilter: String? {
        let value = pathFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func loadWorkspaces(
        _ urls: [URL],
        pathFilter: String? = nil,
        preserveRepositoryVisibility: Bool = false
    ) {
        let uniqueURLs = uniqueWorkspaceURLs(urls)
        guard !uniqueURLs.isEmpty else { return }
        let previousRepositoryIDs = Set(repositories.map(\.id))
        let previouslyHiddenRepositoryIDs = previousRepositoryIDs
            .subtracting(visibleRepositoryIDs)

        isLoadingWorkspace = true
        errorMessage = nil
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
                UserDefaults.standard.set(uniqueURLs.map(\.path), forKey: "lastWorkspacePaths")
                UserDefaults.standard.removeObject(forKey: "lastWorkspacePath")
                rebuildRows()
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

    private func referenceKindOrder(_ kind: GitReference.Kind) -> Int {
        switch kind {
        case .local: return 0
        case .remote: return 1
        case .tag: return 2
        }
    }
}
