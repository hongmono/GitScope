import SwiftUI

/// `ReferenceFolder` 계층을 그리는 재귀 행 묶음.
///
/// 들여쓰기와 삼각형은 `DisclosureGroup` 이 처리한다. 재귀는 함수가 아니라 뷰 타입으로
/// 해야 한다 — `@ViewBuilder` 함수를 자기 자신으로 재귀시키면 반환 타입이 순환한다.
///
/// 트리 자체는 `AppModel` 이 캐시해 두므로 이 뷰는 받은 계층을 그리기만 한다.
struct ReferenceTreeRows: View {
    var model: AppModel
    let folder: ReferenceFolder
    let kind: GitReference.Kind
    let isSearching: Bool

    var body: some View {
        ForEach(folder.references) { group in
            ReferenceRow(model: model, group: group)
        }

        ForEach(folder.children) { child in
            DisclosureGroup(isExpanded: folderExpansion(child)) {
                ReferenceTreeRows(
                    model: model,
                    folder: child,
                    kind: kind,
                    isSearching: isSearching
                )
            } label: {
                SidebarLabel(
                    title: child.name,
                    systemImage: "folder",
                    iconColor: .secondary
                )
            }
            // `DisclosureGroup` 레이블은 접근성 트리에서 이름이 빈 heading 으로 바뀌므로
            // 행 자체에 이름을 붙인다.
            .accessibilityLabel("\(child.name) 폴더")
        }
    }

    /// 검색 중에는 모든 폴더를 강제로 펼치고, 그때의 접기 시도는 무시해 상태를 보존한다.
    ///
    /// 현재 값은 `body` 평가 중에 읽어 둔다. 프로퍼티 단위 관찰에서는 나중에 불리는 `get`
    /// 클로저 안의 읽기가 이 뷰의 추적으로 잡히지 않는다.
    private func folderExpansion(_ folder: ReferenceFolder) -> Binding<Bool> {
        let id = "\(kind.rawValue)::\(folder.path)"
        let isExpanded = isSearching || !model.collapsedReferenceFolders.contains(id)
        return Binding(
            get: { isExpanded },
            set: { isExpanded in
                guard !isSearching else { return }
                if isExpanded {
                    model.collapsedReferenceFolders.remove(id)
                } else {
                    model.collapsedReferenceFolders.insert(id)
                }
            }
        )
    }
}

struct ReferenceRow: View {
    var model: AppModel
    let group: MergedReferenceGroup

    var body: some View {
        HStack(spacing: 6) {
            SidebarLabel(
                title: referenceTitle,
                systemImage: referenceIcon,
                iconColor: group.isCurrent ? .pink : .blue
            )

            Spacer(minLength: 6)

            if let detail = trackingDetail {
                // 선택된 행은 accent 로 채워지므로 ↑↓ 상태색을 그대로 얹으면 대비가 무너진다.
                // 색만 빼고 같은 내용을 그려 네이티브 선택 전경색(흰색)을 따르게 한다.
                Text(isSelected ? AttributedString(detail.help) : detail.text)
                    .font(AppFont.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .trailing)
                    .help(detail.help)
            }
        }
        .tag(SidebarSelection.reference(group.id))
        .contextMenu {
            if group.kind == .local {
                branchContextMenu
            }
        }
    }

    private var isSelected: Bool {
        model.selectedReferenceGroupID == group.id
    }

    private var referenceTitle: String {
        let names = repositoryNames(of: group, in: model)
        let branchName = group.shortName.split(separator: "/").last.map(String.init)
            ?? group.shortName
        guard names.count < model.repositories.count else {
            return branchName
        }
        return "\(branchName) (\(names.joined(separator: ", ")))"
    }

    /// 사이드바는 원격을 네트워크 기호로, 현재 체크아웃된 로컬 브랜치를 채워진 기호로 따로
    /// 구분한다. 그 밖의 경우는 히스토리 배지와 같은 기호를 쓴다.
    private var referenceIcon: String {
        switch group.kind {
        case .local:
            return group.isCurrent
                ? "tag.fill"
                : ReferenceKindStyle.systemImage(for: .local)
        case .remote: return "network"
        case .tag: return ReferenceKindStyle.systemImage(for: .tag)
        }
    }

    private var trackingDetail: SidebarDetail? {
        guard group.kind == .local else { return nil }
        var text = AttributedString()
        var helpParts: [String] = []

        for (index, reference) in group.references.enumerated() {
            if index > 0 {
                text.append(AttributedString("  ·  "))
            }
            if group.references.count > 1 {
                text.append(AttributedString("\(repositoryName(of: reference, in: model)): "))
            }

            if let tracking = reference.tracking {
                text.append(AttributedString("\(tracking.upstreamShortName) "))
                if tracking.isGone {
                    var gone = AttributedString("· 삭제됨")
                    gone.foregroundColor = AppStatusColor.danger
                    text.append(gone)
                } else {
                    var ahead = AttributedString("↑\(tracking.aheadCount)")
                    ahead.foregroundColor = AppStatusColor.success
                    text.append(ahead)
                    text.append(AttributedString(" "))

                    var behind = AttributedString("↓\(tracking.behindCount)")
                    behind.foregroundColor = AppStatusColor.warning
                    text.append(behind)
                }
            } else {
                text.append(AttributedString("upstream 없음"))
            }

            let plainDetail: String
            if let tracking = reference.tracking {
                plainDetail = tracking.isGone
                    ? "\(tracking.upstreamShortName) · 삭제됨"
                    : "\(tracking.upstreamShortName) ↑\(tracking.aheadCount) ↓\(tracking.behindCount)"
            } else {
                plainDetail = "upstream 없음"
            }
            helpParts.append(
                group.references.count > 1
                    ? "\(repositoryName(of: reference, in: model)): \(plainDetail)"
                    : plainDetail
            )
        }

        return SidebarDetail(
            text: text,
            help: helpParts.joined(separator: "  ·  ")
        )
    }

    @ViewBuilder
    private var branchContextMenu: some View {
        Button {} label: {
            Label(groupTrackingSummary, systemImage: "arrow.up.arrow.down")
        }
        .disabled(true)

        Divider()

        Button {
            model.pullRebase(group)
        } label: {
            Label(
                model.remoteOperation?.kind == .pull
                    ? "Pull 중…"
                    : "Pull (Rebase)",
                systemImage: "arrow.down"
            )
        }
        .disabled(
            model.remoteOperation != nil
                || group.pullTargets.isEmpty
        )

        Button {
            model.push(group)
        } label: {
            Label(
                model.remoteOperation?.kind == .push
                    ? "Push 중…"
                    : "Push",
                systemImage: "arrow.up"
            )
        }
        .disabled(
            model.remoteOperation != nil
                || group.pushTargets.isEmpty
        )

        if group.pullTargets.isEmpty {
            Divider()
            Button("Pull은 현재 브랜치에서만 가능") {}
                .disabled(true)
        }
    }

    private var groupTrackingSummary: String {
        let tracked = group.references.compactMap(\.tracking)
        guard !tracked.isEmpty else { return "Upstream이 설정되지 않음" }

        let upstreams = Set(tracked.map(\.upstreamShortName))
        let upstreamTitle = upstreams.count == 1
            ? upstreams.first ?? "upstream"
            : "\(upstreams.count)개 upstream"
        let ahead = tracked.reduce(0) { $0 + $1.aheadCount }
        let behind = tracked.reduce(0) { $0 + $1.behindCount }
        let missingCount = group.references.count - tracked.count
        let missingSuffix = missingCount > 0 ? " · 미설정 \(missingCount)" : ""
        return "\(upstreamTitle) · ↑\(ahead) ↓\(behind)\(missingSuffix)"
    }
}

/// 사이드바 행 레이블. 타이포그래피는 네이티브 `List` 기본값을 그대로 쓰고 아이콘 색만 지정한다.
struct SidebarLabel: View {
    let title: String
    let systemImage: String
    let iconColor: Color

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
        }
    }
}

/// 그룹이 걸쳐 있는 저장소 이름. `AppModel` 의 이름 캐시를 읽어 저장소 목록을 훑지 않는다.
///
/// 순서는 `group.references` 를 따른다(저장소 경로 오름차순). 지금 워크스페이스에 없는
/// 저장소의 참조는 이름을 찾지 못하므로 빠진다.
@MainActor
func repositoryNames(
    of group: MergedReferenceGroup,
    in model: AppModel
) -> [String] {
    var seenIDs = Set<RepositoryID>()
    return group.references.compactMap { reference in
        guard seenIDs.insert(reference.repositoryID).inserted else { return nil }
        return model.repositoryNamesByID[reference.repositoryID]
    }
}

@MainActor
func repositoryName(
    of reference: GitReference,
    in model: AppModel
) -> String {
    model.repositoryNamesByID[reference.repositoryID] ?? reference.repositoryID.rawValue
}

private struct SidebarDetail {
    let text: AttributedString
    let help: String
}
