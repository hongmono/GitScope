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

struct VirtualizedHistoryList: View {
    let rows: [CommitRow]
    let selectedCommitID: CommitID?
    let graphColumnWidth: CGFloat
    let graphLaneCount: Int
    let showsRepositoryColumn: Bool
    let repositoryColorIndices: [RepositoryID: Int]
    let onSelect: (GitCommit) -> Void
    let onClearSelection: () -> Void
    let onVisibleGraphLaneCountChange: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let visibility = HistoryColumnVisibility(
                availableWidth: proxy.size.width,
                graphColumnWidth: graphColumnWidth,
                graphLaneCount: graphLaneCount,
                showsRepository: showsRepositoryColumn
            )

            VStack(spacing: 0) {
                HistoryColumnHeader(
                    graphColumnWidth: visibility.graphColumnWidth,
                    visibility: visibility
                )
                Divider()
                VirtualizedHistoryCollection(
                    rows: rows,
                    selectedCommitID: selectedCommitID,
                    graphColumnWidth: visibility.graphColumnWidth,
                    laneSpacing: visibility.laneSpacing,
                    repositoryColorIndices: repositoryColorIndices,
                    visibility: visibility,
                    onSelect: onSelect,
                    onClearSelection: onClearSelection,
                    onVisibleGraphLaneCountChange: onVisibleGraphLaneCountChange
                )
            }
        }
    }
}

private enum HistoryColumnMetrics {
    static let repositoryWidth: CGFloat = 132
    static let singleRepositoryLeadingInset: CGFloat = 4
    static let authorWidth: CGFloat = 108
    static let dateWidth: CGFloat = 112
    static let rowHeight: CGFloat = 24
    static let topContentInset: CGFloat = 4
    static let minimumCommitWidth: CGFloat = 80
}

private struct HistoryColumnVisibility: Equatable {
    let graphColumnWidth: CGFloat
    let laneSpacing: CGFloat
    let showsRepository: Bool
    let showsAuthor: Bool
    let showsDate: Bool

    init(
        availableWidth: CGFloat,
        graphColumnWidth: CGFloat,
        graphLaneCount: Int,
        showsRepository: Bool
    ) {
        self.graphColumnWidth = graphColumnWidth
        self.showsRepository = showsRepository
        laneSpacing = graphLaneCount > 1
            ? min(18, (self.graphColumnWidth - 40) / CGFloat(graphLaneCount - 1))
            : 18

        let repositoryWidth = showsRepository
            ? HistoryColumnMetrics.repositoryWidth + 1
            : HistoryColumnMetrics.singleRepositoryLeadingInset
        let coreWidth = repositoryWidth
            + self.graphColumnWidth
            + HistoryColumnMetrics.minimumCommitWidth
            + 1
        let authorThreshold = coreWidth + HistoryColumnMetrics.authorWidth + 1
        let dateThreshold = authorThreshold + HistoryColumnMetrics.dateWidth + 1
        showsAuthor = availableWidth >= authorThreshold
        showsDate = availableWidth >= dateThreshold
    }
}

private struct HistoryColumnHeader: View {
    let graphColumnWidth: CGFloat
    let visibility: HistoryColumnVisibility

    var body: some View {
        HStack(spacing: 0) {
            if visibility.showsRepository {
                headerCell("저장소", width: HistoryColumnMetrics.repositoryWidth)
                columnDivider
            } else {
                Color.clear
                    .frame(width: HistoryColumnMetrics.singleRepositoryLeadingInset)
            }
            headerCell("그래프", width: graphColumnWidth)
            columnDivider
            Text("커밋")
                .padding(.horizontal, 8)
                .frame(
                    minWidth: HistoryColumnMetrics.minimumCommitWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            if visibility.showsAuthor {
                columnDivider
                headerCell("작성자", width: HistoryColumnMetrics.authorWidth)
            }
            if visibility.showsDate {
                columnDivider
                headerCell("날짜", width: HistoryColumnMetrics.dateWidth)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(width: 1)
    }
}

private struct VirtualizedHistoryCollection: NSViewRepresentable {
    let rows: [CommitRow]
    let selectedCommitID: CommitID?
    let graphColumnWidth: CGFloat
    let laneSpacing: CGFloat
    let repositoryColorIndices: [RepositoryID: Int]
    let visibility: HistoryColumnVisibility
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visibleBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.apply(
            rows: rows,
            selectedCommitID: selectedCommitID,
            graphColumnWidth: graphColumnWidth,
            laneSpacing: laneSpacing,
            repositoryColorIndices: repositoryColorIndices,
            visibility: visibility,
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
            visibility: visibility,
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
    }

    @MainActor
    final class Coordinator: NSObject,
        NSCollectionViewDataSource,
        NSCollectionViewDelegate,
        NSCollectionViewPrefetching {
        weak var collectionView: NSCollectionView?

        private var rows: [CommitRow] = []
        private var rowIDs: [CommitID] = []
        private var selectedCommitID: CommitID?
        private var graphColumnWidth: CGFloat = 112
        private var laneSpacing: CGFloat = 18
        private var repositoryColorIndices: [RepositoryID: Int] = [:]
        private var visibility = HistoryColumnVisibility(
            availableWidth: .greatestFiniteMagnitude,
            graphColumnWidth: 112,
            graphLaneCount: 1,
            showsRepository: true
        )
        private var onSelect: ((GitCommit) -> Void)?
        private var onClearSelection: (() -> Void)?
        private var onVisibleGraphLaneCountChange: ((Int) -> Void)?
        private var visibleGraphLaneCount = 0
        private var pendingPrefetchCommits: [GitCommit] = []
        private var prefetchTask: Task<Void, Never>?
        private var isSynchronizingSelection = false

        func apply(
            rows: [CommitRow],
            selectedCommitID: CommitID?,
            graphColumnWidth: CGFloat,
            laneSpacing: CGFloat,
            repositoryColorIndices: [RepositoryID: Int],
            visibility: HistoryColumnVisibility,
            onSelect: @escaping (GitCommit) -> Void,
            onClearSelection: @escaping () -> Void,
            onVisibleGraphLaneCountChange: @escaping (Int) -> Void
        ) {
            let newRowIDs = rows.map(\.id)
            let rowsChanged = rowIDs != newRowIDs
            let rowContentChanged = self.rows != rows
            let presentationChanged = rowContentChanged
                || self.selectedCommitID != selectedCommitID
                || self.graphColumnWidth != graphColumnWidth
                || self.laneSpacing != laneSpacing
                || self.repositoryColorIndices != repositoryColorIndices
                || self.visibility != visibility

            self.rows = rows
            rowIDs = newRowIDs
            self.repositoryColorIndices = repositoryColorIndices
            self.selectedCommitID = selectedCommitID
            self.graphColumnWidth = graphColumnWidth
            self.laneSpacing = laneSpacing
            self.visibility = visibility
            self.onSelect = onSelect
            self.onClearSelection = onClearSelection
            self.onVisibleGraphLaneCountChange = onVisibleGraphLaneCountChange

            if rowsChanged {
                pendingPrefetchCommits.removeAll()
                prefetchTask?.cancel()
                collectionView?.reloadData()
            } else if presentationChanged {
                updateVisibleItems()
            }
            synchronizeSelection()
            updateVisibleGraphLaneCount()
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
            let commits = indexPaths.compactMap { indexPath in
                indexPath.item < rows.count ? rows[indexPath.item].commit : nil
            }
            let queuedIDs = Set(pendingPrefetchCommits.map(\.id))
            pendingPrefetchCommits.append(
                contentsOf: commits.filter { !queuedIDs.contains($0.id) }
            )
            startPrefetchingIfNeeded()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            let cancelledIDs = Set(indexPaths.compactMap { indexPath in
                indexPath.item < rows.count ? rows[indexPath.item].id : nil
            })
            pendingPrefetchCommits.removeAll { cancelledIDs.contains($0.id) }
        }

        private func startPrefetchingIfNeeded() {
            guard prefetchTask == nil, !pendingPrefetchCommits.isEmpty else { return }
            prefetchTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let self,
                          !self.pendingPrefetchCommits.isEmpty else {
                        break
                    }
                    let commit = self.pendingPrefetchCommits.removeFirst()
                    _ = await AuthorAvatarResolver.shared.imageData(for: commit)
                }

                guard let self else { return }
                self.prefetchTask = nil
                self.startPrefetchingIfNeeded()
            }
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
            collectionView.needsLayout = true
        }

        @objc func visibleBoundsDidChange(_ notification: Notification) {
            updateVisibleGraphLaneCount()
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
            let startsRepositoryRun = index == 0
                || rows[index - 1].commit.id.repositoryID != repositoryID
            item.configure(
                row: row,
                rowIndex: index,
                graphColumnWidth: graphColumnWidth,
                laneSpacing: laneSpacing,
                isSelected: selectedCommitID == row.id,
                repositoryColorIndex: repositoryColorIndices[repositoryID] ?? 0,
                showsRepositoryName: startsRepositoryRun,
                visibility: visibility
            )
        }

        private func synchronizeSelection() {
            guard let collectionView else { return }
            let selection: Set<IndexPath>
            if let selectedCommitID,
               let index = rowIDs.firstIndex(of: selectedCommitID) {
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
    private var hostingView: NSHostingView<AnyView>?
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
        showsRepositoryName: Bool,
        visibility: HistoryColumnVisibility
    ) {
        if displayedCommit != row.commit {
            cancelReferencesPopover()
            displayedCommit = row.commit
        }

        let rootView = AnyView(
            VirtualizedHistoryRow(
                row: row,
                rowIndex: rowIndex,
                graphColumnWidth: graphColumnWidth,
                laneSpacing: laneSpacing,
                isSelected: isSelected,
                repositoryColorIndex: repositoryColorIndex,
                showsRepositoryName: showsRepositoryName,
                visibility: visibility
            )
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

private struct VirtualizedHistoryRow: View {
    let row: CommitRow
    let rowIndex: Int
    let graphColumnWidth: CGFloat
    let laneSpacing: CGFloat
    let isSelected: Bool
    let repositoryColorIndex: Int
    let showsRepositoryName: Bool
    let visibility: HistoryColumnVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if visibility.showsRepository {
                RepositoryHistoryCell(
                    commit: row.commit,
                    colorIndex: repositoryColorIndex,
                    showsName: showsRepositoryName,
                    isSelected: isSelected
                )
                .frame(width: HistoryColumnMetrics.repositoryWidth)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(3)
                columnDivider
            } else {
                Color.clear
                    .frame(width: HistoryColumnMetrics.singleRepositoryLeadingInset)
            }
            CommitGraphView(
                layout: row.graph,
                commit: row.commit,
                isSelected: isSelected,
                laneSpacing: laneSpacing
            )
            .frame(width: graphColumnWidth)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, -3)
            .layoutPriority(3)
            columnDivider
            CommitMessageHistoryCell(commit: row.commit, isSelected: isSelected)
                .padding(.horizontal, 8)
                .frame(
                    minWidth: HistoryColumnMetrics.minimumCommitWidth,
                    maxWidth: .infinity
                )
            if visibility.showsAuthor {
                columnDivider
                Text(row.commit.authorName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: HistoryColumnMetrics.authorWidth, alignment: .leading)
            }
            if visibility.showsDate {
                columnDivider
                Text(CommitDateFormatter.string(from: row.commit.committerDate))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: HistoryColumnMetrics.dateWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: HistoryColumnMetrics.rowHeight, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isSelected
        )
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if rowIndex.isMultiple(of: 2) {
            return Color(nsColor: .controlBackgroundColor).opacity(0.58)
        }
        return .clear
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(width: 1)
    }
}

private struct RepositoryHistoryCell: View {
    let commit: GitCommit
    let colorIndex: Int
    let showsName: Bool
    let isSelected: Bool

    private var repositoryColor: Color {
        AppPalette.repositoryBackgrounds[colorIndex]
    }

    private var repositoryName: String {
        URL(fileURLWithPath: commit.id.repositoryID.rawValue).lastPathComponent
    }

    var body: some View {
        Text(showsName ? repositoryName : "")
            .font(.system(size: 11))
            .foregroundStyle(Color.black.opacity(0.82))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(repositoryColor)
            .overlay(isSelected ? Color.accentColor.opacity(0.13) : .clear)
            .accessibilityLabel(repositoryName)
    }
}

private struct CommitMessageHistoryCell: View {
    let commit: GitCommit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(commit.subject.isEmpty ? "(메시지 없음)" : commit.subject)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if commit.isWorkingTree {
                CommitLocationBadge(
                    title: "작업 중",
                    systemImage: "hammer.fill",
                    color: .orange,
                    isSelected: isSelected
                )
            }

            if commit.isHead {
                CommitLocationBadge(
                    title: "HEAD",
                    systemImage: "location.fill",
                    color: .accentColor,
                    isSelected: isSelected
                )
            }

            ForEach(commit.references.prefix(3)) { reference in
                ReferenceBadge(reference: reference, isSelected: isSelected)
            }

            if commit.references.count > 3 {
                Text("+\(commit.references.count - 3)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommitLocationBadge: View {
    let title: String
    let systemImage: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(isSelected ? Color.primary : color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(isSelected ? 0.22 : 0.12))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.45), lineWidth: 0.5)
        )
    }
}

private struct ReferenceBadge: View {
    let reference: GitReference
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: reference.kind == .tag ? "tag" : "point.3.connected.trianglepath.dotted")
            Text(reference.shortName)
                .lineLimit(1)
        }
        .font(.system(size: 9))
        .foregroundStyle(
            isSelected
                ? Color.primary
                : reference.kind == .remote ? Color.purple : Color.green
        )
    }
}

private struct CommitReferencesPopover: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("브랜치 및 태그")
                .font(.system(size: 12, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(GitReference.Kind.allCases, id: \.rawValue) { kind in
                        let references = commit.references.filter { $0.kind == kind }
                        if !references.isEmpty {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: kind == .tag ? "tag" : "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(kind == .remote ? Color.purple : Color.green)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(referenceKindTitle(kind))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    ForEach(references) { reference in
                                        Text(reference.shortName)
                                            .font(.system(size: 11))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if commit.references.isEmpty {
                        Text("연결된 브랜치 또는 태그가 없습니다.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 12) {
                if !commit.isWorkingTree {
                    Button("커밋 해시 복사") {
                        copyToPasteboard(commit.id.oid)
                    }
                }
                Button("커밋 메시지 복사") {
                    copyToPasteboard(commit.subject)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    private func referenceKindTitle(_ kind: GitReference.Kind) -> String {
        switch kind {
        case .local: return "로컬 브랜치"
        case .remote: return "원격 브랜치"
        case .tag: return "태그"
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum CommitDateFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        return formatter
    }()

    static func string(from date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "오늘 \(timeFormatter.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "어제 \(timeFormatter.string(from: date))"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dateFormatter.string(from: date)
        }
        return date.formatted(.dateTime.year().month().day())
    }
}
