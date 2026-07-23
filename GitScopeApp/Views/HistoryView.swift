import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var visibleGraphLaneCount = 1

    private var graphLaneCount: Int {
        max(1, visibleGraphLaneCount)
    }

    private var graphColumnWidth: CGFloat {
        max(112, 40 + CGFloat(graphLaneCount - 1) * 18)
    }

    private var repositoryColorIndices: [RepositoryID: Int] {
        Dictionary(
            uniqueKeysWithValues: model.repositories.map { repository in
                (
                    repository.id,
                    repository.colorIndex % AppPalette.repositoryBackgrounds.count
                )
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryFilterBar(model: model)
            Divider()

            if model.rows.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "표시할 커밋이 없습니다",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("검색어나 필터를 변경해보세요.")
                )
            } else {
                VirtualizedHistoryList(
                    rows: model.rows,
                    selectedCommitID: model.selectedCommit?.id,
                    graphColumnWidth: graphColumnWidth,
                    graphLaneCount: graphLaneCount,
                    repositoryColorIndices: repositoryColorIndices
                ) { commit in
                    model.selectCommit(commit)
                } onClearSelection: {
                    model.clearSelection()
                } onVisibleGraphLaneCountChange: { laneCount in
                    visibleGraphLaneCount = laneCount
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct HistoryFilterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("텍스트 또는 해시", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 180, maxWidth: 270)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor))
            )

            FilterMenu(
                title: model.selectedReference?.shortName ?? "브랜치",
                isActive: model.selectedReference != nil
            ) {
                Button("모든 브랜치") { model.selectRepository(nil) }
                Divider()
                ForEach(GitReference.Kind.allCases, id: \.self) { kind in
                    let groups = model.mergedReferenceGroups.filter { $0.kind == kind }
                    if !groups.isEmpty {
                        Menu(referenceKindTitle(kind)) {
                            ForEach(groups) { group in
                                Button(group.shortName) {
                                    model.selectReferenceGroup(group)
                                }
                            }
                        }
                    }
                }
            }

            FilterMenu(
                title: model.authorFilter ?? "사용자",
                isActive: model.authorFilter != nil
            ) {
                Button("모든 사용자") { model.authorFilter = nil }
                Divider()
                ForEach(model.availableAuthors, id: \.self) { author in
                    Button(author) { model.authorFilter = author }
                }
            }

            FilterMenu(
                title: model.dateScope.rawValue,
                isActive: model.dateScope != .all
            ) {
                ForEach(HistoryDateScope.allCases) { scope in
                    Button(scope.rawValue) { model.dateScope = scope }
                }
            }

            FilterMenu(
                title: "경로",
                isActive: model.visibleRepositoryIDs.count != model.repositories.count
            ) {
                Button("모두 선택") {
                    model.showAllRepositories()
                }
                Divider()
                Section("루트") {
                    ForEach(model.repositories) { repository in
                        Button {
                            model.toggleRepositoryVisibility(repository)
                        } label: {
                            Label(
                                repository.name,
                                systemImage: model.visibleRepositoryIDs.contains(repository.id)
                                    ? "checkmark.square.fill"
                                    : "square"
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Text("\(model.rows.count)개")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func referenceKindTitle(_ kind: GitReference.Kind) -> String {
        switch kind {
        case .local: return "로컬"
        case .remote: return "원격"
        case .tag: return "태그"
        }
    }
}

private struct FilterMenu<Content: View>: View {
    let title: String
    let isActive: Bool
    private let content: Content

    init(title: String, isActive: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
