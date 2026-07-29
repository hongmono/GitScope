import AppKit
import SwiftUI

enum HistoryColumnMetrics {
    static let repositoryWidth: CGFloat = 132
    static let singleRepositoryLeadingInset: CGFloat = 4
    static let authorWidth: CGFloat = 108
    static let dateWidth: CGFloat = 112
    static let rowHeight: CGFloat = 24
    static let topContentInset: CGFloat = 4
    static let minimumCommitWidth: CGFloat = 80
}

struct HistoryColumnVisibility: Equatable {
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

struct HistoryColumnHeader: View {
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
        .font(AppFont.columnHeader)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25, alignment: .leading)
        .background(AppColor.columnHeaderFill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColor.separator)
                .frame(height: 1)
        }
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(AppColor.separator.opacity(0.36))
            .frame(width: 1)
    }
}

struct VirtualizedHistoryRow: View {
    let row: CommitRow
    let rowIndex: Int
    let graphColumnWidth: CGFloat
    let laneSpacing: CGFloat
    let isSelected: Bool
    let repositoryColorIndex: Int
    let githubActionsSummary: GitHubActionsSummary?
    let visibility: HistoryColumnVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if visibility.showsRepository {
                RepositoryHistoryCell(
                    commit: row.commit,
                    colorIndex: repositoryColorIndex,
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
            AppColor.subtleFill
                .frame(width: graphColumnWidth)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("커밋 그래프")
                .accessibilityValue(graphAccessibilityValue)
            columnDivider
            CommitMessageHistoryCell(
                commit: row.commit,
                isSelected: isSelected
            )
                .padding(.leading, 8)
                .padding(.trailing, githubActionsSummary == nil ? 8 : 28)
                .frame(
                    minWidth: HistoryColumnMetrics.minimumCommitWidth,
                    maxWidth: .infinity
                )
                .overlay(alignment: .trailing) {
                    if let githubActionsSummary {
                        GitHubActionsHistoryBadge(
                            summary: githubActionsSummary,
                            isSelected: isSelected
                        )
                        .padding(.trailing, 8)
                    }
                }
            if visibility.showsAuthor {
                columnDivider
                Text(row.commit.authorName)
                    .font(AppFont.rowLabelEmphasized)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: HistoryColumnMetrics.authorWidth, alignment: .leading)
            }
            if visibility.showsDate {
                columnDivider
                Text(CommitDateFormatter.string(from: row.commit.committerDate))
                    .font(AppFont.rowLabel)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: HistoryColumnMetrics.dateWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: HistoryColumnMetrics.rowHeight, alignment: .leading)
        .background(rowBackground)
        .appGlassSelection(isSelected)
        .contentShape(Rectangle())
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isSelected
        )
    }

    private var rowBackground: Color {
        if isSelected {
            return .clear
        }
        if rowIndex.isMultiple(of: 2) {
            return AppColor.zebraStripe
        }
        return .clear
    }

    private var graphAccessibilityValue: String {
        let commit = row.commit
        if commit.isWorkingTree {
            return "커밋되지 않은 작업 트리 변경 사항, \(row.graph.nodeLane + 1)번 레인"
        }
        if commit.isHead {
            return "현재 HEAD 커밋, \(row.graph.nodeLane + 1)번 레인"
        }
        if row.graph.isBranchPoint {
            return "브랜치 \(row.graph.incomingLanes.count)개가 갈라진 기준 커밋, "
                + "\(row.graph.nodeLane + 1)번 레인"
        }
        if commit.parentOIDs.isEmpty {
            return "루트 커밋, \(row.graph.nodeLane + 1)번 레인"
        }
        if commit.parentOIDs.count > 1 {
            return "부모 \(commit.parentOIDs.count)개를 가진 병합 커밋, "
                + "\(row.graph.nodeLane + 1)번 레인"
        }
        return "일반 커밋, \(row.graph.nodeLane + 1)번 레인"
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(AppColor.separator.opacity(0.28))
            .frame(width: 1)
    }
}

private struct RepositoryHistoryCell: View {
    let commit: GitCommit
    let colorIndex: Int
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var repositoryColor: Color {
        AppPalette.repositoryBackgrounds[colorIndex]
    }

    private var repositoryName: String {
        RepositoryNameCache.name(for: commit.id.repositoryID)
    }

    /// 파스텔 배경은 라이트 모드 기준이라 다크 모드에서는 옅게 깔아 주변 표면과 맞춘다.
    private var backgroundOpacity: Double {
        colorScheme == .dark ? 0.20 : 0.74
    }

    var body: some View {
        // 모든 행에 전체 저장소 이름을 같은 스타일로 그린다. 연속 행이라고 이름을 줄이거나
        // 흐리게 하면 읽을 수 없는 표기가 되고, 같은 열에 두 가지 표기가 섞인다.
        Text(repositoryName)
            .font(AppFont.rowLabel)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(repositoryColor.opacity(backgroundOpacity))
            .overlay(isSelected ? Color.accentColor.opacity(0.13) : .clear)
            .help(repositoryName)
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
                    color: AppStatusColor.warning,
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(AppFont.rowLabel)
        .clipped()
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
        .font(AppFont.badge)
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
            Image(systemName: ReferenceKindStyle.systemImage(for: reference.kind))
            Text(reference.shortName)
                .lineLimit(1)
        }
        .font(AppFont.badge)
        .foregroundStyle(
            isSelected
                ? Color.primary
                : ReferenceKindStyle.color(for: reference.kind)
        )
    }
}

struct CommitReferencesPopover: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("브랜치 및 태그")
                .font(AppFont.paneTitle)

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(GitReference.Kind.allCases, id: \.rawValue) { kind in
                        let references = commit.references.filter { $0.kind == kind }
                        if !references.isEmpty {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: ReferenceKindStyle.systemImage(for: kind))
                                    .foregroundStyle(ReferenceKindStyle.color(for: kind))
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(kind.longDisplayName)
                                        .font(AppFont.metadataTitle)
                                        .foregroundStyle(.secondary)
                                    ForEach(references) { reference in
                                        Text(reference.shortName)
                                            .font(AppFont.metadataValue)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if commit.references.isEmpty {
                        Text("연결된 브랜치 또는 태그가 없습니다.")
                            .font(AppFont.rowLabel)
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
            .font(AppFont.rowLabel)
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// 저장소 경로 → 표시 이름 캐시. 행 body 마다 `URL(fileURLWithPath:)` 를 만들지 않도록
/// 한 번 계산한 이름을 재사용한다. 워크스페이스의 저장소 수는 작아 상한은 두지 않는다.
@MainActor
private enum RepositoryNameCache {
    private static var names: [RepositoryID: String] = [:]

    static func name(for id: RepositoryID) -> String {
        if let cached = names[id] { return cached }
        let name = URL(fileURLWithPath: id.rawValue).lastPathComponent
        names[id] = name
        return name
    }
}
