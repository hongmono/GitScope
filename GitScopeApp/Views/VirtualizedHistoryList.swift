import SwiftUI

/// 히스토리 표의 최상위 뷰.
///
/// 열 머리글(`HistoryColumnHeader`)과 가상화된 본문(`VirtualizedHistoryCollection`)을 세로로
/// 쌓고, 창 너비에 따라 어떤 열을 보일지(`HistoryColumnVisibility`)만 결정한다.
struct VirtualizedHistoryList: View {
    let rows: [CommitRow]
    let selectedCommitIDs: Set<CommitID>
    let graphColumnWidth: CGFloat
    let graphLaneCount: Int
    let showsRepositoryColumn: Bool
    let repositoryColorIndices: [RepositoryID: Int]
    let githubActionsByCommit: [CommitID: GitHubActionsSummary]
    let onSelectionChange: ([GitCommit]) -> Void
    let onVisibleGraphLaneCountChange: (Int) -> Void
    /// 설정 토글이 바뀌면 이 값이 바뀌면서 `updateNSView` → 그래프 다시 그리기가 이어진다.
    @AppStorage(AppSettings.authorAvatarLookupEnabledKey)
    private var showsRemoteAvatars = true

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
                VirtualizedHistoryCollection(
                    rows: rows,
                    selectedCommitIDs: selectedCommitIDs,
                    graphColumnWidth: visibility.graphColumnWidth,
                    laneSpacing: visibility.laneSpacing,
                    repositoryColorIndices: repositoryColorIndices,
                    githubActionsByCommit: githubActionsByCommit,
                    visibility: visibility,
                    showsRemoteAvatars: showsRemoteAvatars,
                    onSelectionChange: onSelectionChange,
                    onVisibleGraphLaneCountChange: onVisibleGraphLaneCountChange
                )
            }
        }
        .background(.clear)
    }
}
