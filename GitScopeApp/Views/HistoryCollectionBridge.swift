import AppKit
import QuartzCore
import SwiftUI

private extension NSUserInterfaceItemIdentifier {
    static let historyRow = NSUserInterfaceItemIdentifier("HistoryRow")
}

private final class ResizeAwareCollectionView: NSCollectionView {
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)

        guard widthChanged else { return }
        onWidthChange?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onWidthChange?()
    }
}

struct VirtualizedHistoryCollection: NSViewRepresentable {
    let rows: [CommitRow]
    let selectedCommitID: CommitID?
    let graphColumnWidth: CGFloat
    let laneSpacing: CGFloat
    let repositoryColorIndices: [RepositoryID: Int]
    let githubActionsByCommit: [CommitID: GitHubActionsSummary]
    let visibility: HistoryColumnVisibility
    let showsRemoteAvatars: Bool
    let onSelect: (GitCommit) -> Void
    let onClearSelection: () -> Void
    let onVisibleGraphLaneCountChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = VisibleRowsCollectionLayout()
        layout.rowHeight = HistoryColumnMetrics.rowHeight
        layout.topInset = HistoryColumnMetrics.topContentInset

        let collectionView = ResizeAwareCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.prefetchDataSource = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            HistoryCollectionItem.self,
            forItemWithIdentifier: .historyRow
        )

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        collectionView.frame = scrollView.contentView.bounds
        collectionView.autoresizingMask = [.width]
        collectionView.onWidthChange = { [weak coordinator = context.coordinator] in
            coordinator?.refreshVisibleRowsAfterResize()
        }

        let graphOverlayView = VisibleCommitGraphView()
        scrollView.contentView.addSubview(
            graphOverlayView,
            positioned: .above,
            relativeTo: collectionView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visibleBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.graphOverlayView = graphOverlayView
        context.coordinator.apply(
            rows: rows,
            selectedCommitID: selectedCommitID,
            graphColumnWidth: graphColumnWidth,
            laneSpacing: laneSpacing,
            repositoryColorIndices: repositoryColorIndices,
            githubActionsByCommit: githubActionsByCommit,
            visibility: visibility,
            showsRemoteAvatars: showsRemoteAvatars,
            onSelect: onSelect,
            onClearSelection: onClearSelection,
            onVisibleGraphLaneCountChange: onVisibleGraphLaneCountChange
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(
            rows: rows,
            selectedCommitID: selectedCommitID,
            graphColumnWidth: graphColumnWidth,
            laneSpacing: laneSpacing,
            repositoryColorIndices: repositoryColorIndices,
            githubActionsByCommit: githubActionsByCommit,
            visibility: visibility,
            showsRemoteAvatars: showsRemoteAvatars,
            onSelect: onSelect,
            onClearSelection: onClearSelection,
            onVisibleGraphLaneCountChange: onVisibleGraphLaneCountChange
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        coordinator.graphOverlayView?.cancelPendingAvatarLoads()
    }

    @MainActor
    final class Coordinator: NSObject,
        NSCollectionViewDataSource,
        NSCollectionViewDelegate,
        NSCollectionViewPrefetching {
        weak var collectionView: NSCollectionView?
        weak var graphOverlayView: VisibleCommitGraphView?

        private var rows: [CommitRow] = []
        /// 선택 동기화의 `firstIndex(of:)` O(n) 탐색을 대신하는 역색인.
        /// 행 목록이 실제로 바뀔 때만 다시 만든다.
        private var rowIndicesByID: [CommitID: Int] = [:]
        private var selectedCommitID: CommitID?
        private var graphColumnWidth: CGFloat = 112
        private var laneSpacing: CGFloat = 18
        private var repositoryColorIndices: [RepositoryID: Int] = [:]
        private var githubActionsByCommit: [CommitID: GitHubActionsSummary] = [:]
        private var visibility = HistoryColumnVisibility(
            availableWidth: .greatestFiniteMagnitude,
            graphColumnWidth: 112,
            graphLaneCount: 1,
            showsRepository: true
        )
        private var showsRemoteAvatars = AppSettings.isAuthorAvatarLookupEnabled
        private var onSelect: ((GitCommit) -> Void)?
        private var onClearSelection: (() -> Void)?
        private var onVisibleGraphLaneCountChange: ((Int) -> Void)?
        private var visibleGraphLaneCount = 0
        /// 아바타 프리페치에 필요한 최소 정보. 큐가 `GitCommit` 전체(본문·참조 포함)를
        /// 붙잡지 않도록 리졸버가 실제로 읽는 필드만 담는다.
        private struct AvatarPrefetchRequest {
            let commitID: CommitID
            let authorEmail: String
            let avatarKey: String
        }
        private var pendingPrefetchRequests: [AvatarPrefetchRequest] = []
        /// 큐에 들어 있으나 아직 소비되지 않은 항목의 키. O(1) 중복 검사와 취소 처리에 쓴다.
        private var queuedPrefetchKeys: Set<String> = []
        /// `removeFirst()` 의 O(n) 이동을 피하는 소비 커서. 배열 끝까지 소비하면 함께 비운다.
        private var prefetchCursor = 0
        private var prefetchTask: Task<Void, Never>?
        private var isSynchronizingSelection = false

        func apply(
            rows: [CommitRow],
            selectedCommitID: CommitID?,
            graphColumnWidth: CGFloat,
            laneSpacing: CGFloat,
            repositoryColorIndices: [RepositoryID: Int],
            githubActionsByCommit: [CommitID: GitHubActionsSummary],
            visibility: HistoryColumnVisibility,
            showsRemoteAvatars: Bool,
            onSelect: @escaping (GitCommit) -> Void,
            onClearSelection: @escaping () -> Void,
            onVisibleGraphLaneCountChange: @escaping (Int) -> Void
        ) {
            // 배열 버퍼가 같으면 `==` 가 O(1) 로 끝나므로, 매 updateNSView 마다 `map(\.id)`
            // 배열을 새로 만들지 않고 내용이 실제로 바뀐 경우에만 ID 열을 비교한다.
            let rowContentChanged = self.rows != rows
            let rowsChanged = rowContentChanged
                && (self.rows.count != rows.count
                    || zip(self.rows, rows).contains { $0.id != $1.id })
            let presentationChanged = rowContentChanged
                || self.selectedCommitID != selectedCommitID
                || self.graphColumnWidth != graphColumnWidth
                || self.laneSpacing != laneSpacing
                || self.repositoryColorIndices != repositoryColorIndices
                || self.githubActionsByCommit != githubActionsByCommit
                || self.visibility != visibility

            self.rows = rows
            self.repositoryColorIndices = repositoryColorIndices
            self.githubActionsByCommit = githubActionsByCommit
            self.selectedCommitID = selectedCommitID
            self.graphColumnWidth = graphColumnWidth
            self.laneSpacing = laneSpacing
            self.visibility = visibility
            self.showsRemoteAvatars = showsRemoteAvatars
            self.onSelect = onSelect
            self.onClearSelection = onClearSelection
            self.onVisibleGraphLaneCountChange = onVisibleGraphLaneCountChange

            if rowsChanged {
                var indices = [CommitID: Int](minimumCapacity: rows.count)
                for (index, row) in rows.enumerated() where indices[row.id] == nil {
                    indices[row.id] = index
                }
                rowIndicesByID = indices
                pendingPrefetchRequests.removeAll(keepingCapacity: false)
                queuedPrefetchKeys.removeAll(keepingCapacity: false)
                prefetchCursor = 0
                prefetchTask?.cancel()
                collectionView?.reloadData()
            } else if presentationChanged {
                updateVisibleItems()
            }
            synchronizeSelection()
            updateVisibleGraphLaneCount()
            updateGraphOverlay()
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            rows.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            guard indexPath.item < rows.count,
                  let item = collectionView.makeItem(
                    withIdentifier: .historyRow,
                    for: indexPath
                  ) as? HistoryCollectionItem else {
                return NSCollectionViewItem()
            }

            configure(item, at: indexPath.item)
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard !isSynchronizingSelection,
                  let index = indexPaths.first?.item,
                  index < rows.count else {
                return
            }
            onSelect?(rows[index].commit)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didDeselectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard !isSynchronizingSelection,
                  collectionView.selectionIndexPaths.isEmpty else {
                return
            }
            onClearSelection?()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths {
                guard indexPath.item < rows.count else { continue }
                let commit = rows[indexPath.item].commit
                // 보이는 행 경로(`scheduleVisibleAvatarLoads`)와 같은 가드를 둔다. 실패가
                // 확정된 작성자를 거르지 않으면 아바타 없는 저장소에서 끝없이 재조회한다.
                guard !commit.isWorkingTree,
                      let key = historyAvatarKey(
                        repositoryID: commit.id.repositoryID,
                        authorEmail: commit.authorEmail
                      ),
                      graphOverlayView?.isAvatarUnavailable(forKey: key) != true,
                      queuedPrefetchKeys.insert(key).inserted else {
                    continue
                }
                pendingPrefetchRequests.append(
                    AvatarPrefetchRequest(
                        commitID: commit.id,
                        authorEmail: commit.authorEmail,
                        avatarKey: key
                    )
                )
            }
            startPrefetchingIfNeeded()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            // 배열에서 지우는 대신 키만 빼 둔다. 소비 루프가 키 없는 항목을 건너뛴다.
            for indexPath in indexPaths {
                guard indexPath.item < rows.count else { continue }
                let commit = rows[indexPath.item].commit
                guard let key = historyAvatarKey(
                    repositoryID: commit.id.repositoryID,
                    authorEmail: commit.authorEmail
                ) else {
                    continue
                }
                queuedPrefetchKeys.remove(key)
            }
        }

        private func startPrefetchingIfNeeded() {
            guard prefetchTask == nil,
                  prefetchCursor < pendingPrefetchRequests.count else {
                return
            }
            prefetchTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    guard self.prefetchCursor < self.pendingPrefetchRequests.count else {
                        self.pendingPrefetchRequests.removeAll(keepingCapacity: false)
                        self.prefetchCursor = 0
                        break
                    }
                    let request = self.pendingPrefetchRequests[self.prefetchCursor]
                    self.prefetchCursor += 1
                    // 키가 빠져 있으면 취소된 항목이다. 실패 확정 작성자도 건너뛴다.
                    guard self.queuedPrefetchKeys.remove(request.avatarKey) != nil,
                          self.graphOverlayView?.isAvatarUnavailable(
                            forKey: request.avatarKey
                          ) != true else {
                        continue
                    }
                    let showsRemoteAvatars = self.showsRemoteAvatars
                    let data = await AuthorAvatarResolver.shared.imageData(
                        for: Self.prefetchCommit(for: request)
                    )
                    // 실패를 기록해 같은 작성자를 다시 조회하지 않는다. 취소나 토글 꺼짐으로
                    // nil 이 돌아온 것을 실패로 남기지 않는 조건은 보이는 행 경로와 같다.
                    if data == nil, showsRemoteAvatars, !Task.isCancelled {
                        self.graphOverlayView?.markAvatarUnavailable(
                            forKey: request.avatarKey
                        )
                    }
                }

                guard let self else { return }
                self.prefetchTask = nil
                self.startPrefetchingIfNeeded()
            }
        }

        /// 리졸버(`AuthorAvatarResolver`)는 `id`(저장소·OID)와 `authorEmail` 만 읽으므로
        /// 나머지 필드는 비워 전달한다.
        private static func prefetchCommit(
            for request: AvatarPrefetchRequest
        ) -> GitCommit {
            GitCommit(
                id: request.commitID,
                parentOIDs: [],
                subject: "",
                body: "",
                authorName: "",
                authorEmail: request.authorEmail,
                authorDate: .distantPast,
                committerDate: .distantPast,
                references: [],
                isHead: false,
                isWorkingTree: false
            )
        }

        private func updateVisibleItems() {
            guard let collectionView else { return }
            for case let item as HistoryCollectionItem in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: item),
                      indexPath.item < rows.count else {
                    continue
                }
                configure(item, at: indexPath.item)
            }
        }

        func refreshVisibleRowsAfterResize() {
            guard let collectionView else { return }
            collectionView.collectionViewLayout?.invalidateLayout()
            updateVisibleItems()
            updateVisibleGraphLaneCount()
            updateGraphOverlay()
            collectionView.needsLayout = true
        }

        @objc func visibleBoundsDidChange(_ notification: Notification) {
            updateVisibleGraphLaneCount()
            updateGraphOverlay()
        }

        private func updateGraphOverlay() {
            guard let collectionView,
                  let scrollView = collectionView.enclosingScrollView,
                  let graphOverlayView else {
                return
            }

            let visibleRect = scrollView.contentView.bounds
            let graphOriginX = visibility.showsRepository
                ? HistoryColumnMetrics.repositoryWidth + 1
                : HistoryColumnMetrics.singleRepositoryLeadingInset
            graphOverlayView.frame = NSRect(
                x: graphOriginX,
                y: visibleRect.minY,
                width: graphColumnWidth,
                height: visibleRect.height
            )
            graphOverlayView.configure(
                rows: rows,
                selectedCommitID: selectedCommitID,
                laneSpacing: laneSpacing,
                contentOffsetY: visibleRect.minY,
                showsRemoteAvatars: showsRemoteAvatars
            )
        }

        private func updateVisibleGraphLaneCount() {
            guard let scrollView = collectionView?.enclosingScrollView,
                  !rows.isEmpty else {
                reportVisibleGraphLaneCount(1)
                return
            }

            let visibleRect = scrollView.contentView.bounds
            let rowHeight = HistoryColumnMetrics.rowHeight
            let firstVisibleY = max(
                0,
                visibleRect.minY - HistoryColumnMetrics.topContentInset
            )
            let lastVisibleY = max(
                firstVisibleY,
                visibleRect.maxY - HistoryColumnMetrics.topContentInset
            )
            let firstIndex = min(
                rows.count - 1,
                max(0, Int(floor(firstVisibleY / rowHeight)))
            )
            let lastIndex = min(
                rows.count - 1,
                max(firstIndex, Int(ceil(lastVisibleY / rowHeight)) - 1)
            )
            let laneCount = rows[firstIndex...lastIndex]
                .lazy
                .map(\.graph.laneCount)
                .max() ?? 1
            reportVisibleGraphLaneCount(laneCount)
        }

        private func reportVisibleGraphLaneCount(_ laneCount: Int) {
            guard laneCount != visibleGraphLaneCount else { return }
            visibleGraphLaneCount = laneCount
            onVisibleGraphLaneCountChange?(laneCount)
        }

        private func configure(_ item: HistoryCollectionItem, at index: Int) {
            let row = rows[index]
            let repositoryID = row.commit.id.repositoryID
            item.configure(
                row: row,
                rowIndex: index,
                graphColumnWidth: graphColumnWidth,
                laneSpacing: laneSpacing,
                isSelected: selectedCommitID == row.id,
                repositoryColorIndex: repositoryColorIndices[repositoryID] ?? 0,
                githubActionsSummary: githubActionsByCommit[row.id],
                visibility: visibility
            )
        }

        private func synchronizeSelection() {
            guard let collectionView else { return }
            let selection: Set<IndexPath>
            if let selectedCommitID,
               let index = rowIndicesByID[selectedCommitID] {
                selection = [IndexPath(item: index, section: 0)]
            } else {
                selection = []
            }

            guard collectionView.selectionIndexPaths != selection else { return }
            isSynchronizingSelection = true
            collectionView.selectionIndexPaths = selection
            isSynchronizingSelection = false
        }
    }
}

@MainActor
private final class HistoryCollectionItem: NSCollectionViewItem, NSPopoverDelegate {
    /// `AnyView` 로 지우면 SwiftUI 가 갱신마다 뷰 정체성을 새로 판단한다. 구체 타입을 유지해
    /// 프로퍼티 단위 diff 가 동작하게 한다.
    private var hostingView: NSHostingView<VirtualizedHistoryRow>?
    private var displayedCommit: GitCommit?
    private var referencesPopover: NSPopover?
    private let fadeDuration: TimeInterval = 0.10
    private let initialFadeAlpha: CGFloat = 0.55

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        let rightClickRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(showReferencesForRightClick(_:))
        )
        rightClickRecognizer.buttonMask = 0x2
        view.addGestureRecognizer(rightClickRecognizer)
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        view.layer?.removeAllAnimations()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = 1
            return
        }

        view.alphaValue = initialFadeAlpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        view.layer?.removeAllAnimations()
        view.alphaValue = 1
        cancelReferencesPopover()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        displayedCommit = nil
        cancelReferencesPopover()
    }

    func configure(
        row: CommitRow,
        rowIndex: Int,
        graphColumnWidth: CGFloat,
        laneSpacing: CGFloat,
        isSelected: Bool,
        repositoryColorIndex: Int,
        githubActionsSummary: GitHubActionsSummary?,
        visibility: HistoryColumnVisibility
    ) {
        if displayedCommit != row.commit {
            cancelReferencesPopover()
            displayedCommit = row.commit
        }

        let rootView = VirtualizedHistoryRow(
            row: row,
            rowIndex: rowIndex,
            graphColumnWidth: graphColumnWidth,
            laneSpacing: laneSpacing,
            isSelected: isSelected,
            repositoryColorIndex: repositoryColorIndex,
            githubActionsSummary: githubActionsSummary,
            visibility: visibility
        )

        if let hostingView {
            hostingView.rootView = rootView
            return
        }

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.hostingView = hostingView
    }

    private func showReferencesPopover(for commit: GitCommit) {
        guard view.window != nil else { return }
        cancelReferencesPopover()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let groupCount = GitReference.Kind.allCases.filter { kind in
            commit.references.contains { $0.kind == kind }
        }.count
        popover.contentSize = NSSize(
            width: 360,
            height: max(
                132,
                min(400, 112 + commit.references.count * 22 + groupCount * 18)
            )
        )
        popover.contentViewController = NSHostingController(
            rootView: CommitReferencesPopover(commit: commit)
        )
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        referencesPopover = popover
    }

    @objc private func showReferencesForRightClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, let commit = displayedCommit else { return }
        showReferencesPopover(for: commit)
    }

    func popoverDidClose(_ notification: Notification) {
        referencesPopover = nil
    }

    private func cancelReferencesPopover() {
        referencesPopover?.close()
        referencesPopover = nil
    }
}

private final class VisibleRowsCollectionLayout: NSCollectionViewLayout {
    var rowHeight: CGFloat = 24
    var topInset: CGFloat = 0
    private let overscanRatio: CGFloat = 0.10

    override var collectionViewContentSize: NSSize {
        guard let collectionView else { return .zero }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        return NSSize(
            width: collectionView.bounds.width,
            height: topInset + CGFloat(itemCount) * rowHeight
        )
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else { return [] }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard itemCount > 0 else { return [] }
        let visibleRect = collectionView.enclosingScrollView?.contentView.bounds ?? rect
        let contentHeight = topInset + CGFloat(itemCount) * rowHeight
        guard visibleRect.maxY >= topInset, visibleRect.minY < contentHeight else { return [] }

        let firstVisibleY = max(0, visibleRect.minY - topInset)
        let lastVisibleY = max(firstVisibleY, visibleRect.maxY - topInset)
        let firstVisible = max(0, Int(floor(firstVisibleY / rowHeight)))
        let lastVisible = min(
            itemCount - 1,
            max(firstVisible, Int(ceil(lastVisibleY / rowHeight)) - 1)
        )
        let visibleRowCount = max(1, lastVisible - firstVisible + 1)
        let overscanRowCount = max(
            1,
            Int(ceil(CGFloat(visibleRowCount) * overscanRatio))
        )
        let leadingOverscan = overscanRowCount / 2
        let trailingOverscan = overscanRowCount - leadingOverscan
        let firstIndex = max(0, firstVisible - leadingOverscan)
        let lastIndex = min(itemCount - 1, lastVisible + trailingOverscan)
        guard firstIndex <= lastIndex else { return [] }

        return (firstIndex...lastIndex).map { index in
            attributes(for: index, width: collectionView.bounds.width)
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let collectionView else { return nil }
        return attributes(for: indexPath.item, width: collectionView.bounds.width)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        let currentBounds = collectionView.bounds
        return currentBounds.width != newBounds.width
            || currentBounds.height != newBounds.height
            || currentBounds.origin.y != newBounds.origin.y
    }

    private func attributes(for index: Int, width: CGFloat) -> NSCollectionViewLayoutAttributes {
        let indexPath = IndexPath(item: index, section: 0)
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = NSRect(
            x: 0,
            y: topInset + CGFloat(index) * rowHeight,
            width: width,
            height: rowHeight
        )
        return attributes
    }
}
