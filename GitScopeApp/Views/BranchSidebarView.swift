import SwiftUI

/// 사이드바 목록에서 선택할 수 있는 대상.
///
/// 섹션 헤더와 폴더 행은 펼침/접힘 전용이므로 태그를 달지 않는다. `List` 는 선택 타입과 같은
/// 태그가 붙은 행만 선택 대상으로 삼기 때문에, 태그 부착 여부가 곧 선택 가능 여부다.
///
/// 참조 행은 `ReferenceTree.swift` 가 그리므로 파일 밖에서도 보이게 둔다.
enum SidebarSelection: Hashable {
    case currentBranches
    case reference(String)
}

struct BranchSidebarView: View {
    // `.searchable` 에 `$model.branchSearch` 바인딩을 넘겨야 해서 `@Bindable` 로 받는다.
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            SidebarLabel(
                title: "HEAD(현재 브랜치)",
                systemImage: "scope",
                iconColor: .secondary
            )
            .tag(SidebarSelection.currentBranches)

            referenceSection("로컬", kind: .local)
            referenceSection("원격", kind: .remote)
            referenceSection("태그", kind: .tag)
        }
        .listStyle(.sidebar)
        .searchable(
            text: $model.branchSearch,
            placement: .sidebar,
            prompt: "브랜치 또는 태그"
        )
    }

    /// 선택 상태의 진실은 `AppModel` 이므로 별도 `@State` 없이 모델에서 읽고 모델로 쓴다.
    ///
    /// `nil` 쓰기는 무시한다. 빈 영역을 눌렀거나 검색으로 선택된 행이 걸러졌을 때 들어오는데,
    /// 이를 모델에 반영하면 히스토리 필터가 풀려 기존 동작이 깨진다.
    ///
    /// 현재 값은 `get` 클로저 안이 아니라 여기서 미리 읽는다. 프로퍼티 단위 관찰에서는 `body`
    /// 평가 중에 읽은 것만 추적되므로, 나중에 불리는 클로저 안에서만 읽으면 선택이 바뀌어도
    /// 목록이 다시 그려지지 않는다. 쓰기 쪽은 누른 순간의 최신 상태를 봐야 해서 그대로 둔다.
    private var selection: Binding<SidebarSelection?> {
        let current: SidebarSelection? = if model.isCurrentBranchesSelected {
            .currentBranches
        } else if let selectedID = model.selectedReferenceGroupID {
            .reference(selectedID)
        } else {
            nil
        }
        return Binding(
            get: { current },
            set: { newValue in
                switch newValue {
                case .currentBranches:
                    guard !model.isCurrentBranchesSelected else { return }
                    model.selectCurrentBranches()
                case let .reference(id):
                    guard model.selectedReferenceGroupID != id,
                          let group = model.mergedReferenceGroups.first(where: { $0.id == id })
                    else { return }
                    model.selectReferenceGroup(group)
                case .none:
                    break
                }
            }
        )
    }

    /// 그릴 폴더 트리는 `AppModel` 이 참조 목록·검색어가 바뀔 때 한 번만 만들어 둔다.
    /// body 는 캐시된 계층을 읽기만 한다.
    @ViewBuilder
    private func referenceSection(
        _ title: String,
        kind: GitReference.Kind
    ) -> some View {
        let isSearching = !model.normalizedBranchSearch.isEmpty
        let folder = model.searchedReferenceFoldersByKind[kind] ?? .empty
        if !isSearching || !folder.isEmpty {
            Section(isExpanded: groupExpansion(kind)) {
                ReferenceTreeRows(
                    model: model,
                    folder: folder,
                    kind: kind,
                    isSearching: isSearching
                )
            } header: {
                // 접을 수 있는 섹션 헤더는 내용 텍스트가 접근성 트리에 노출되지 않아 직접 붙인다.
                Text(title)
                    .accessibilityLabel("\(title) 그룹")
            }
        }
    }

    /// 검색 중에는 모든 그룹을 강제로 펼치고, 그때의 접기 시도는 무시해 상태를 보존한다.
    ///
    /// `selection` 과 같은 이유로 현재 값은 `body` 평가 중에 읽어 둔다.
    private func groupExpansion(_ kind: GitReference.Kind) -> Binding<Bool> {
        let isExpanded = !model.normalizedBranchSearch.isEmpty
            || model.expandedReferenceGroups.contains(kind)
        return Binding(
            get: { isExpanded },
            set: { isExpanded in
                guard model.normalizedBranchSearch.isEmpty else { return }
                if isExpanded {
                    model.expandedReferenceGroups.insert(kind)
                } else {
                    model.expandedReferenceGroups.remove(kind)
                }
            }
        )
    }
}
