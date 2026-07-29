import SwiftUI

/// 히스토리 필터 바의 브랜치 메뉴 내용.
///
/// 위에서부터 필터 끄기 → 체크된 항목(평평하게) → 종류별 폴더 서브메뉴 순이다.
/// 체크된 항목을 상단에 모아 두는 이유는, 서브메뉴 깊숙이 들어가지 않고도 한 번에
/// 끄고 켤 수 있어야 하기 때문이다.
struct BranchScopeMenuContent: View {
    var model: AppModel

    var body: some View {
        Button("모든 브랜치") {
            model.clearBranchFilters()
        }

        // 사이드바 선택이 범위를 덮고 있을 때만 나온다. 선택만 풀고 범위로 돌아가는 길이
        // 없으면 "모든 브랜치"로 범위까지 지우는 수밖에 없다.
        if model.hasBranchSelection, model.branchScope.isActive {
            Button("브랜치 선택 해제 (범위로 복귀)") {
                model.clearBranchSelection()
            }
        }

        Divider()

        // 이 기능의 핵심 항목이라 서브메뉴에 숨기지 않고 체크 여부와 무관하게 항상 이 자리에 둔다.
        Button {
            model.toggleAllLocalBranchesInScope()
        } label: {
            Label(
                "로컬 브랜치 전부",
                systemImage: model.branchScope.includesAllLocalBranches
                    ? "checkmark.square.fill"
                    : "square"
            )
        }

        ForEach(model.branchScopeMenuItems) { item in
            Button {
                model.removeBranchScopeMember(id: item.id)
            } label: {
                // 지금 워크스페이스에 없는 브랜치도 이름으로 남긴다. 감추면 "모든 브랜치"로
                // 전부 지우는 것 말고는 해제할 방법이 없는 막다른 상태가 된다.
                Label(item.menuTitle, systemImage: "checkmark.square.fill")
            }
        }

        Divider()

        ForEach(GitReference.Kind.allCases, id: \.self) { kind in
            let folder = model.referenceFoldersByKind[kind] ?? .empty
            if !folder.isEmpty {
                Menu(kind.displayName) {
                    BranchScopeFolderMenu(model: model, folder: folder)
                }
            }
        }
    }
}

/// 폴더 계층을 그대로 옮긴 브랜치 범위 서브메뉴.
///
/// 사이드바와 같은 `ReferenceFolder` 를 소비한다. 재귀는 함수가 아니라 뷰 타입으로 해야
/// 한다 — `@ViewBuilder` 함수를 자기 자신으로 재귀시키면 반환 타입이 순환한다.
struct BranchScopeFolderMenu: View {
    var model: AppModel
    let folder: ReferenceFolder

    var body: some View {
        ForEach(folder.references) { group in
            Button {
                model.toggleBranchScopeMember(group)
            } label: {
                Label(
                    leafTitle(of: group),
                    systemImage: model.branchScope.contains(group)
                        ? "checkmark.square.fill"
                        : "square"
                )
            }
        }

        ForEach(folder.children) { child in
            Menu("\(child.name)/") {
                BranchScopeFolderMenu(model: model, folder: child)
            }
        }
    }

    /// 폴더가 앞부분을 이미 말해 주므로 마지막 조각만 그린다. 사이드바 행과 같은 규칙이다.
    private func leafTitle(of group: MergedReferenceGroup) -> String {
        group.shortName.split(separator: "/").last.map(String.init) ?? group.shortName
    }
}
