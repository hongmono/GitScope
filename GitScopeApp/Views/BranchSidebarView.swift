import AppKit
import SwiftUI

struct BranchSidebarView: View {
    @ObservedObject var model: AppModel
    @State private var expandedReferenceGroups: Set<GitReference.Kind> = [.local]

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
                    ForEach(matching) { group in
                        SidebarButton(
                            title: referenceTitle(group),
                            systemImage: referenceIcon(group),
                            isSelected: model.selectedReferenceGroupID == group.id,
                            accent: group.isCurrent ? .pink : .blue
                        ) {
                            model.selectReferenceGroup(group)
                        }
                        .padding(.leading, 20)
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
        guard names.count < model.repositories.count else {
            return group.shortName
        }
        return "\(group.shortName) (\(names.joined(separator: ", ")))"
    }

    private func repositoryNames(_ group: MergedReferenceGroup) -> [String] {
        let repositoryIDs = Set(group.references.map(\.repositoryID))
        return model.repositories
            .filter { repositoryIDs.contains($0.id) }
            .map(\.name)
    }

    private func referenceIcon(_ group: MergedReferenceGroup) -> String {
        switch group.kind {
        case .local: return group.isCurrent ? "tag.fill" : "point.3.connected.trianglepath.dotted"
        case .remote: return "network"
        case .tag: return "tag"
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
