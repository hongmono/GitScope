import AppKit
import SwiftUI

struct BranchSidebarView: View {
    @ObservedObject var model: AppModel
    @State private var expandedReferenceGroups: Set<GitReference.Kind> = [.local]
    @State private var collapsedReferenceFolders: Set<String> = []

    private var normalizedSearch: String {
        model.branchSearch.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    SidebarButton(
                        title: "HEAD(현재 브랜치)",
                        systemImage: "scope",
                        isSelected: model.isCurrentBranchesSelected
                    ) {
                        model.selectCurrentBranches()
                    }

                    referenceGroup("로컬", kind: .local)
                    referenceGroup("원격", kind: .remote)
                    referenceGroup("태그", kind: .tag)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 7)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("브랜치 또는 태그", text: $model.branchSearch)
                .textFieldStyle(.plain)
            if !model.branchSearch.isEmpty {
                Button {
                    model.branchSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
    }

    @ViewBuilder
    private func referenceGroup(
        _ title: String,
        kind: GitReference.Kind
    ) -> some View {
        let matching = filteredReferenceGroups(kind: kind)
        if normalizedSearch.isEmpty || !matching.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                SidebarDisclosureButton(
                    title: title,
                    systemImage: kind == .tag ? "tag" : "point.3.connected.trianglepath.dotted",
                    isExpanded: isReferenceGroupExpanded(kind),
                    isSelected: false,
                    indent: 0
                ) {
                    toggleReferenceGroup(kind)
                }

                if isReferenceGroupExpanded(kind) {
                    ForEach(visibleReferenceTreeItems(groups: matching, kind: kind)) { item in
                        referenceTreeItem(item, kind: kind)
                    }
                }
            }
        }
    }

    private func isReferenceGroupExpanded(_ kind: GitReference.Kind) -> Bool {
        !normalizedSearch.isEmpty || expandedReferenceGroups.contains(kind)
    }

    private func toggleReferenceGroup(_ kind: GitReference.Kind) {
        guard normalizedSearch.isEmpty else { return }
        if expandedReferenceGroups.contains(kind) {
            expandedReferenceGroups.remove(kind)
        } else {
            expandedReferenceGroups.insert(kind)
        }
    }

    @ViewBuilder
    private func referenceTreeItem(
        _ item: ReferenceTreeItem,
        kind: GitReference.Kind
    ) -> some View {
        switch item {
        case let .reference(group, depth):
            SidebarButton(
                title: referenceTitle(group),
                systemImage: referenceIcon(group),
                isSelected: model.selectedReferenceGroupID == group.id,
                detail: trackingDetail(group),
                accent: group.isCurrent ? .pink : .blue
            ) {
                model.selectReferenceGroup(group)
            }
            .padding(.leading, 20 + CGFloat(depth * 20))
            .contextMenu {
                if group.kind == .local {
                    branchContextMenu(group)
                }
            }
        case let .folder(folder, depth):
            SidebarDisclosureButton(
                title: folder.name,
                systemImage: "folder",
                isExpanded: isReferenceFolderExpanded(folder, kind: kind),
                isSelected: false,
                indent: 20 + CGFloat(depth * 20)
            ) {
                toggleReferenceFolder(folder, kind: kind)
            }
        }
    }

    private func visibleReferenceTreeItems(
        groups: [MergedReferenceGroup],
        kind: GitReference.Kind
    ) -> [ReferenceTreeItem] {
        let root = referenceTree(groups: groups)
        var items: [ReferenceTreeItem] = []
        appendVisibleReferenceTreeItems(
            from: root,
            kind: kind,
            depth: 0,
            to: &items
        )
        return items
    }

    private func appendVisibleReferenceTreeItems(
        from folder: ReferenceFolder,
        kind: GitReference.Kind,
        depth: Int,
        to items: inout [ReferenceTreeItem]
    ) {
        items.append(contentsOf: folder.references.map { .reference($0, depth: depth) })
        for child in folder.children {
            items.append(.folder(child, depth: depth))
            if isReferenceFolderExpanded(child, kind: kind) {
                appendVisibleReferenceTreeItems(
                    from: child,
                    kind: kind,
                    depth: depth + 1,
                    to: &items
                )
            }
        }
    }

    private func isReferenceFolderExpanded(
        _ folder: ReferenceFolder,
        kind: GitReference.Kind
    ) -> Bool {
        !normalizedSearch.isEmpty || !collapsedReferenceFolders.contains(folderStateID(folder, kind: kind))
    }

    private func toggleReferenceFolder(
        _ folder: ReferenceFolder,
        kind: GitReference.Kind
    ) {
        guard normalizedSearch.isEmpty else { return }
        let id = folderStateID(folder, kind: kind)
        if collapsedReferenceFolders.contains(id) {
            collapsedReferenceFolders.remove(id)
        } else {
            collapsedReferenceFolders.insert(id)
        }
    }

    private func folderStateID(
        _ folder: ReferenceFolder,
        kind: GitReference.Kind
    ) -> String {
        "\(kind.rawValue)::\(folder.path)"
    }

    private func filteredReferenceGroups(kind: GitReference.Kind) -> [MergedReferenceGroup] {
        let groups = model.mergedReferenceGroups.filter { $0.kind == kind }
        guard !normalizedSearch.isEmpty else { return groups }
        return groups.filter { group in
            group.shortName.localizedLowercase.contains(normalizedSearch)
                || repositoryNames(group).contains {
                    $0.localizedLowercase.contains(normalizedSearch)
                }
        }
    }

    private func referenceTitle(_ group: MergedReferenceGroup) -> String {
        let names = repositoryNames(group)
        let branchName = group.shortName.split(separator: "/").last.map(String.init)
            ?? group.shortName
        guard names.count < model.repositories.count else {
            return branchName
        }
        return "\(branchName) (\(names.joined(separator: ", ")))"
    }

    private func repositoryNames(_ group: MergedReferenceGroup) -> [String] {
        let repositoryIDs = Set(group.references.map(\.repositoryID))
        return model.repositories
            .filter { repositoryIDs.contains($0.id) }
            .map(\.name)
    }

    private func repositoryName(_ reference: GitReference) -> String {
        model.repositories.first(where: { $0.id == reference.repositoryID })?.name
            ?? reference.repositoryID.rawValue
    }

    private func trackingDetail(_ group: MergedReferenceGroup) -> SidebarDetail? {
        guard group.kind == .local else { return nil }
        var text = AttributedString()
        var helpParts: [String] = []

        for (index, reference) in group.references.enumerated() {
            if index > 0 {
                text.append(AttributedString("  ·  "))
            }
            if group.references.count > 1 {
                text.append(AttributedString("\(repositoryName(reference)): "))
            }

            if let tracking = reference.tracking {
                text.append(AttributedString("\(tracking.upstreamShortName) "))
                if tracking.isGone {
                    var gone = AttributedString("· 삭제됨")
                    gone.foregroundColor = .red
                    text.append(gone)
                } else {
                    var ahead = AttributedString("↑\(tracking.aheadCount)")
                    ahead.foregroundColor = .green
                    text.append(ahead)
                    text.append(AttributedString(" "))

                    var behind = AttributedString("↓\(tracking.behindCount)")
                    behind.foregroundColor = .orange
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
                    ? "\(repositoryName(reference)): \(plainDetail)"
                    : plainDetail
            )
        }

        return SidebarDetail(
            text: text,
            help: helpParts.joined(separator: "  ·  ")
        )
    }

    @ViewBuilder
    private func branchContextMenu(_ group: MergedReferenceGroup) -> some View {
        Button {} label: {
            Label(groupTrackingSummary(group), systemImage: "arrow.up.arrow.down")
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
                || pullTargets(in: group).isEmpty
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
                || pushTargets(in: group).isEmpty
        )

        if pullTargets(in: group).isEmpty {
            Divider()
            Button("Pull은 현재 브랜치에서만 가능") {}
                .disabled(true)
        }
    }

    private func pullTargets(in group: MergedReferenceGroup) -> [GitReference] {
        group.references.filter {
            $0.isCurrent && $0.tracking != nil && $0.tracking?.isGone != true
        }
    }

    private func pushTargets(in group: MergedReferenceGroup) -> [GitReference] {
        group.references.filter {
            $0.tracking != nil && $0.tracking?.isGone != true
        }
    }

    private func groupTrackingSummary(_ group: MergedReferenceGroup) -> String {
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

    private func referenceIcon(_ group: MergedReferenceGroup) -> String {
        switch group.kind {
        case .local: return group.isCurrent ? "tag.fill" : "point.3.connected.trianglepath.dotted"
        case .remote: return "network"
        case .tag: return "tag"
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

private enum ReferenceTreeItem: Identifiable {
    case folder(ReferenceFolder, depth: Int)
    case reference(MergedReferenceGroup, depth: Int)

    var id: String {
        switch self {
        case let .folder(folder, _):
            return "folder::\(folder.path)"
        case let .reference(group, _):
            return "reference::\(group.id)"
        }
    }
}

private struct SidebarDisclosureButton: View {
    let title: String
    let systemImage: String
    let isExpanded: Bool
    let isSelected: Bool
    let indent: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: systemImage)
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.leading, 6 + indent)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var detail: SidebarDetail? = nil
    var accent: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                    .foregroundStyle(accent)
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190, alignment: .trailing)
                        .help(detail.help)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}

private struct SidebarDetail {
    let text: AttributedString
    let help: String
}
