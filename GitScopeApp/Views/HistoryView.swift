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
                    showsRepositoryColumn: model.repositories.count > 1,
                    repositoryColorIndices: repositoryColorIndices,
                    githubActionsByCommit: model.githubActionsByCommit
                ) { commit in
                    model.selectCommit(commit)
                } onClearSelection: {
                    model.clearSelection()
                } onVisibleGraphLaneCountChange: { laneCount in
                    visibleGraphLaneCount = laneCount
                }
            }
        }
        .background(.clear)
    }
}

private struct HistoryFilterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            HistorySearchField(
                text: $model.query,
                prompt: "텍스트 또는 해시"
            )
            .frame(minWidth: 120, maxWidth: 270)
            .frame(height: 28)

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

    private func referenceKindTitle(_ kind: GitReference.Kind) -> String {
        switch kind {
        case .local: return "로컬"
        case .remote: return "원격"
        case .tag: return "태그"
        }
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
