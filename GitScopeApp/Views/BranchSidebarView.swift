import SwiftUI

/// 사이드바 목록에서 선택할 수 있는 대상.
///
/// 섹션 헤더와 폴더 행은 펼침/접힘 전용이므로 태그를 달지 않는다. `List` 는 선택 타입과 같은
/// 태그가 붙은 행만 선택 대상으로 삼기 때문에, 태그 부착 여부가 곧 선택 가능 여부다.
private enum SidebarSelection: Hashable {
    case currentBranches
    case reference(String)
}

struct BranchSidebarView: View {
    @ObservedObject var model: AppModel

    private var normalizedSearch: String {
        model.branchSearch.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

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
    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: {
                if model.isCurrentBranchesSelected { return .currentBranches }
                if let selectedID = model.selectedReferenceGroupID {
                    return .reference(selectedID)
                }
                return nil
            },
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

    @ViewBuilder
    private func referenceSection(
        _ title: String,
        kind: GitReference.Kind
    ) -> some View {
        let matching = filteredReferenceGroups(kind: kind)
        if normalizedSearch.isEmpty || !matching.isEmpty {
            Section(isExpanded: groupExpansion(kind)) {
                ReferenceTreeRows(
                    model: model,
                    folder: referenceTree(groups: matching),
                    kind: kind,
                    isSearching: !normalizedSearch.isEmpty
                )
            } header: {
                // 접을 수 있는 섹션 헤더는 내용 텍스트가 접근성 트리에 노출되지 않아 직접 붙인다.
                Text(title)
                    .accessibilityLabel("\(title) 그룹")
            }
        }
    }

    /// 검색 중에는 모든 그룹을 강제로 펼치고, 그때의 접기 시도는 무시해 상태를 보존한다.
    private func groupExpansion(_ kind: GitReference.Kind) -> Binding<Bool> {
        Binding(
            get: {
                !normalizedSearch.isEmpty || model.expandedReferenceGroups.contains(kind)
            },
            set: { isExpanded in
                guard normalizedSearch.isEmpty else { return }
                if isExpanded {
                    model.expandedReferenceGroups.insert(kind)
                } else {
                    model.expandedReferenceGroups.remove(kind)
                }
            }
        )
    }

    private func filteredReferenceGroups(kind: GitReference.Kind) -> [MergedReferenceGroup] {
        let groups = model.referenceGroupsByKind[kind] ?? []
        guard !normalizedSearch.isEmpty else { return groups }
        return groups.filter { group in
            group.shortName.localizedLowercase.contains(normalizedSearch)
                || repositoryNames(of: group, in: model).contains {
                    $0.localizedLowercase.contains(normalizedSearch)
                }
        }
    }

    private func referenceTree(
        groups: [MergedReferenceGroup]
    ) -> ReferenceFolder {
        let root = MutableReferenceFolder(name: "", path: "")
        for group in groups {
            let components = group.shortName.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                root.references.append(group)
                continue
            }

            var current = root
            for component in components.dropLast() {
                if let child = current.children[component] {
                    current = child
                } else {
                    let path = current.path.isEmpty ? component : "\(current.path)/\(component)"
                    let child = MutableReferenceFolder(name: component, path: path)
                    current.children[component] = child
                    current = child
                }
            }
            current.references.append(group)
        }
        return root.snapshot()
    }
}

/// 폴더 계층을 그리는 재귀 행 묶음.
///
/// 들여쓰기와 삼각형은 `DisclosureGroup` 이 처리한다. 재귀는 함수가 아니라 뷰 타입으로
/// 해야 한다 — `@ViewBuilder` 함수를 자기 자신으로 재귀시키면 반환 타입이 순환한다.
private struct ReferenceTreeRows: View {
    @ObservedObject var model: AppModel
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
    private func folderExpansion(_ folder: ReferenceFolder) -> Binding<Bool> {
        let id = "\(kind.rawValue)::\(folder.path)"
        return Binding(
            get: {
                isSearching || !model.collapsedReferenceFolders.contains(id)
            },
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

private struct ReferenceRow: View {
    @ObservedObject var model: AppModel
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

    private var referenceIcon: String {
        switch group.kind {
        case .local: return group.isCurrent ? "tag.fill" : "point.3.connected.trianglepath.dotted"
        case .remote: return "network"
        case .tag: return "tag"
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
            model.pullRebase(group.references)
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
                || pullTargets.isEmpty
        )

        Button {
            model.push(group.references)
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
                || pushTargets.isEmpty
        )

        if pullTargets.isEmpty {
            Divider()
            Button("Pull은 현재 브랜치에서만 가능") {}
                .disabled(true)
        }
    }

    private var pullTargets: [GitReference] {
        group.references.filter {
            $0.isCurrent && $0.tracking != nil && $0.tracking?.isGone != true
        }
    }

    private var pushTargets: [GitReference] {
        group.references.filter {
            $0.tracking != nil && $0.tracking?.isGone != true
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
private struct SidebarLabel: View {
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

@MainActor
private func repositoryNames(
    of group: MergedReferenceGroup,
    in model: AppModel
) -> [String] {
    let repositoryIDs = Set(group.references.map(\.repositoryID))
    return model.repositories
        .filter { repositoryIDs.contains($0.id) }
        .map(\.name)
}

@MainActor
private func repositoryName(
    of reference: GitReference,
    in model: AppModel
) -> String {
    model.repositories.first(where: { $0.id == reference.repositoryID })?.name
        ?? reference.repositoryID.rawValue
}

private final class MutableReferenceFolder {
    let name: String
    let path: String
    var children: [String: MutableReferenceFolder] = [:]
    var references: [MergedReferenceGroup] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    func snapshot() -> ReferenceFolder {
        ReferenceFolder(
            name: name,
            path: path,
            children: children.values
                .map { $0.snapshot() }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            references: references.sorted {
                $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
            }
        )
    }
}

private struct ReferenceFolder: Identifiable {
    let name: String
    let path: String
    let children: [ReferenceFolder]
    let references: [MergedReferenceGroup]

    var id: String { path }
}

private struct SidebarDetail {
    let text: AttributedString
    let help: String
}
