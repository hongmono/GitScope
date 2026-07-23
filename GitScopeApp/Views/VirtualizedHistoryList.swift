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
    let repositoryColorIndices: [RepositoryID: Int]
    let onSelect: (GitCommit) -> Void
    let onClearSelection: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let visibility = HistoryColumnVisibility(
                availableWidth: proxy.size.width,
                graphColumnWidth: graphColumnWidth,
                graphLaneCount: graphLaneCount
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
                    onClearSelection: onClearSelection
                )
            }
        }
    }
}

private enum HistoryColumnMetrics {
    static let repositoryWidth: CGFloat = 132
    static let authorWidth: CGFloat = 108
    static let dateWidth: CGFloat = 112
    static let rowHeight: CGFloat = 24
    static let minimumCommitWidth: CGFloat = 80
}

private struct HistoryColumnVisibility: Equatable {
    let graphColumnWidth: CGFloat
    let laneSpacing: CGFloat
    let showsAuthor: Bool
    let showsDate: Bool

    init(availableWidth: CGFloat, graphColumnWidth: CGFloat, graphLaneCount: Int) {
        let maximumGraphWidth = max(
            56,
            availableWidth
                - HistoryColumnMetrics.repositoryWidth
                - HistoryColumnMetrics.minimumCommitWidth
                - 2
        )
        self.graphColumnWidth = min(graphColumnWidth, maximumGraphWidth)
        laneSpacing = graphLaneCount > 1
            ? min(18, (self.graphColumnWidth - 40) / CGFloat(graphLaneCount - 1))
            : 18

        let coreWidth = HistoryColumnMetrics.repositoryWidth
            + self.graphColumnWidth
            + HistoryColumnMetrics.minimumCommitWidth
            + 2
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
            headerCell("저장소", width: HistoryColumnMetrics.repositoryWidth)
            columnDivider
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = VisibleRowsCollectionLayout()
        layout.rowHeight = HistoryColumnMetrics.rowHeight

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

        context.coordinator.collectionView = collectionView
        context.coordinator.apply(
            rows: rows,
            selectedCommitID: selectedCommitID,
            graphColumnWidth: graphColumnWidth,
            laneSpacing: laneSpacing,
            repositoryColorIndices: repositoryColorIndices,
            visibility: visibility,
            onSelect: onSelect,
            onClearSelection: onClearSelection
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
            onClearSelection: onClearSelection
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
            graphLaneCount: 1
        )
        private var onSelect: ((GitCommit) -> Void)?
        private var onClearSelection: (() -> Void)?
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
            onClearSelection: @escaping () -> Void
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

            if rowsChanged {
                pendingPrefetchCommits.removeAll()
                prefetchTask?.cancel()
                collectionView?.reloadData()
            } else if presentationChanged {
                updateVisibleItems()
            }
            synchronizeSelection()
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
            collectionView.needsLayout = true
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
private final class HistoryCollectionItem: NSCollectionViewItem {
    private var hostingView: NSHostingView<AnyView>?
    private var displayedCommit: GitCommit?
    private var hoverTask: Task<Void, Never>?
    private var popoverCloseTask: Task<Void, Never>?
    private var referencesPopover: NSPopover?
    private let fadeDuration: TimeInterval = 0.10
    private let initialFadeAlpha: CGFloat = 0.55

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
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

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let commit = displayedCommit, !commit.references.isEmpty else { return }
        popoverCloseTask?.cancel()
        popoverCloseTask = nil
        guard referencesPopover == nil else { return }

        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled,
                  let self,
                  self.displayedCommit?.id == commit.id else {
                return
            }
            self.showReferencesPopover(for: commit)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTask?.cancel()
        hoverTask = nil
        if referencesPopover == nil {
            cancelReferencesPopover()
        } else {
            scheduleReferencesPopoverClose()
        }
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
        guard referencesPopover == nil, view.window != nil else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let groupCount = GitReference.Kind.allCases.filter { kind in
            commit.references.contains { $0.kind == kind }
        }.count
        popover.contentSize = NSSize(
            width: 360,
            height: min(360, 68 + commit.references.count * 22 + groupCount * 18)
        )
        popover.contentViewController = NSHostingController(
            rootView: CommitReferencesPopover(commit: commit) { [weak self] isHovering in
                if isHovering {
                    self?.popoverCloseTask?.cancel()
                    self?.popoverCloseTask = nil
                } else {
                    self?.scheduleReferencesPopoverClose()
                }
            }
        )
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        referencesPopover = popover
    }

    private func cancelReferencesPopover() {
        hoverTask?.cancel()
        hoverTask = nil
        popoverCloseTask?.cancel()
        popoverCloseTask = nil
        referencesPopover?.close()
        referencesPopover = nil
    }

    private func scheduleReferencesPopoverClose() {
        popoverCloseTask?.cancel()
        popoverCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.cancelReferencesPopover()
        }
    }
}

private final class VisibleRowsCollectionLayout: NSCollectionViewLayout {
    var rowHeight: CGFloat = 24
    private let overscanRatio: CGFloat = 0.10

    override var collectionViewContentSize: NSSize {
        guard let collectionView else { return .zero }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        return NSSize(
            width: collectionView.bounds.width,
            height: CGFloat(itemCount) * rowHeight
        )
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else { return [] }
        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard itemCount > 0 else { return [] }
        let visibleRect = collectionView.enclosingScrollView?.contentView.bounds ?? rect
        let contentHeight = CGFloat(itemCount) * rowHeight
        guard visibleRect.maxY >= 0, visibleRect.minY < contentHeight else { return [] }

        let firstVisible = max(0, Int(floor(visibleRect.minY / rowHeight)))
        let lastVisible = min(
            itemCount - 1,
            max(firstVisible, Int(ceil(visibleRect.maxY / rowHeight)) - 1)
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
            y: CGFloat(index) * rowHeight,
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

    var body: some View {
        HStack(spacing: 0) {
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
        .contextMenu {
            Button("커밋 해시 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id.oid, forType: .string)
            }
            Button("커밋 메시지 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.subject, forType: .string)
            }
        }
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
    let onHoverChange: (Bool) -> Void

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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .onHover(perform: onHoverChange)
    }

    private func referenceKindTitle(_ kind: GitReference.Kind) -> String {
        switch kind {
        case .local: return "로컬 브랜치"
        case .remote: return "원격 브랜치"
        case .tag: return "태그"
        }
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
