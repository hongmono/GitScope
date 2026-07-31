import SwiftUI

struct HistoryView: View {
    var model: AppModel
    @State private var visibleGraphLaneCount = 1
    @State private var colorIndexCache = RepositoryColorIndexCache()

    private var graphLaneCount: Int {
        max(1, visibleGraphLaneCount)
    }

    private var graphColumnWidth: CGFloat {
        max(112, 40 + CGFloat(graphLaneCount - 1) * 18)
    }

    /// 저장소 목록이 실제로 바뀔 때만 색 인덱스 표를 다시 만든다. body 평가마다 Dictionary 를
    /// 새로 만들면 매 갱신이 저장소 수만큼의 할당이 된다. 관찰되지 않는 참조 타입이라 body
    /// 평가 중에 채워 넣어도 무효화 루프가 생기지 않는다.
    private var repositoryColorIndices: [RepositoryID: Int] {
        if colorIndexCache.repositories != model.repositories {
            colorIndexCache.repositories = model.repositories
            colorIndexCache.indices = Dictionary(
                uniqueKeysWithValues: model.repositories.map { repository in
                    (
                        repository.id,
                        repository.colorIndex % AppPalette.repositoryBackgrounds.count
                    )
                }
            )
        }
        return colorIndexCache.indices
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
                    selectedCommitIDs: model.selectedCommitIDs,
                    graphColumnWidth: graphColumnWidth,
                    graphLaneCount: graphLaneCount,
                    showsRepositoryColumn: model.repositories.count > 1,
                    repositoryColorIndices: repositoryColorIndices,
                    githubActionsByCommit: model.githubActionsByCommit
                ) { commits in
                    model.selectCommits(commits)
                } onVisibleGraphLaneCountChange: { laneCount in
                    visibleGraphLaneCount = laneCount
                }
            }

            // 상한을 채운 저장소가 있으면 이력이 잘렸음을 알린다. 가상화 리스트(NSCollectionView)
            // 내부 footer 로 넣으면 레이아웃 구조를 건드리게 되므로 리스트 바깥 하단에 둔다.
            if model.isCommitHistoryTruncated {
                Divider()
                Text(
                    model.repositories.count > 1
                        ? "일부 저장소는 최근 \(AppModel.commitLoadLimit.formatted())개 커밋만 표시됩니다"
                        : "최근 \(AppModel.commitLoadLimit.formatted())개 커밋만 표시됩니다"
                )
                .font(AppFont.rowLabel)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .background(.clear)
    }
}

/// `HistoryView.repositoryColorIndices` 의 메모 저장소. `@State` 로 붙들어 뷰 정체성이
/// 유지되는 동안 재사용된다.
@MainActor
private final class RepositoryColorIndexCache {
    var repositories: [GitRepository] = []
    var indices: [RepositoryID: Int] = [:]
}

private struct HistoryFilterBar: View {
    // 검색 필드에 `$model.query` 바인딩을 넘겨야 해서 `@Bindable` 로 받는다.
    @Bindable var model: AppModel

    /// 브랜치 축은 두 층이라 제목도 이긴 쪽을 따른다.
    ///
    /// 사이드바 선택이 있으면 그 이름(HEAD 선택은 이름이 없어 기본 제목), 선택이 없을 때만
    /// 저장해 둔 범위의 항목 수를 보여준다.
    private var branchFilterTitle: String {
        if let reference = model.selectedReference { return reference.shortName }
        if model.isCurrentBranchesSelected { return "브랜치" }
        return model.branchScope.isActive
            ? "브랜치 \(model.branchScope.memberCount)개"
            : "브랜치"
    }

    var body: some View {
        HStack(spacing: 8) {
            HistorySearchField(
                text: $model.query,
                prompt: "텍스트 또는 해시"
            )
            .frame(minWidth: 120, maxWidth: 270)
            .frame(height: 28)

            FilterMenu(
                title: branchFilterTitle,
                isActive: model.selectedReference != nil || model.branchScope.isActive
            ) {
                BranchScopeMenuContent(model: model)
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
                .font(AppFont.rowLabel)
                .foregroundStyle(.secondary)
        }
        .font(AppFont.rowLabel)
        // 창 가장자리까지 꽉 차는 띠라 카드 시절의 7pt 대신 툴바 관례인 10pt 를 쓴다.
        .padding(.horizontal, 10)
        .frame(height: 40)
        // 자체 배경 채움을 두지 않는다. 바로 아래 히스토리 표의 열 머리글이 이미
        // `columnHeaderFill` 띠라, 여기에도 채움을 깔면 미세하게 다른 두 띠가 붙어 지저분해진다.
        // 표와의 구분은 아래 `Divider()` 헤어라인 한 줄이 담당한다.
    }

}

/// 히스토리 검색 필드.
///
/// 브랜치 사이드바는 `.searchable(placement: .sidebar)` 를 쓰는데, 이는 내부적으로
/// `NSSearchField` 를 그린다. 히스토리 검색은 필터 메뉴들과 한 줄에 놓여야 해서 `.searchable`
/// 을 쓸 수 없으므로, 같은 `NSSearchField` 를 직접 얹어 두 검색 필드의 생김새를 맞춘다.
/// 커스텀 컨테이너로 흉내 내면 모서리·테두리·클리어 버튼이 매번 시스템과 어긋난다.
private struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = prompt
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        nsView.placeholderString = prompt
        guard nsView.stringValue != text else { return }
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
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
            HStack(spacing: 5) {
                // 폭이 넉넉하면 제목 전체가 보이고, 좁아지면 그때 시스템이 가운데를 줄인다.
                // `fixedSize()` 를 쓰면 긴 참조 이름만큼 필터 바 고유 폭이 늘어나고,
                // 그 아래에서는 제안이 비어 있어 `frame(maxWidth:)` 도 clamp 되지 않는다.
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        // 셰브런은 `.borderlessButton` 이 레이블 뒤에 그려 주는 것만 쓴다. 레이블 HStack 에
        // 직접 넣으면 이 스타일이 그것을 표시자로 보고 앞쪽으로 옮겨, 앞뒤로 두 개가 된다.
        .menuStyle(.borderlessButton)
        .appGlassControl(
            tint: isActive ? Color.accentColor : nil,
            interactive: true
        )
        .help(title)
        .accessibilityLabel(title)
    }
}
