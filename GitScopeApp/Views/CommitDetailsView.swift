import AppKit
import SwiftUI

struct CommitDetailsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VSplitView {
            changedFilesPane
            diffPane
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: model.selectedCommit?.id
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: model.isLoadingDetails
        )
    }

    private var changedFilesPane: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "변경 파일", systemImage: "doc.on.doc")
            Divider()

            if model.selectedCommit == nil {
                DetailsPlaceholder(text: "변경 사항을 확인할 커밋 선택")
            } else if model.isLoadingDetails {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let details = model.selectedDetails {
                VStack(spacing: 0) {
                    CommitSummary(commit: details.commit)
                    Divider()
                    if details.files.isEmpty {
                        DetailsPlaceholder(text: "변경된 파일이 없습니다")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(details.files) { file in
                                    Button {
                                        model.selectChangedFile(file)
                                    } label: {
                                        HStack(spacing: 7) {
                                            Text(file.status)
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundStyle(statusColor(file.status))
                                                .frame(width: 18)
                                            Image(systemName: "doc.text")
                                                .foregroundStyle(.secondary)
                                            Text(file.path)
                                                .font(.system(size: 11))
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 9)
                                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                                        .background(
                                            model.selectedFile?.id == file.id
                                                ? Color.accentColor.opacity(0.14)
                                                : .clear
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
                        }
                    }
                }
            } else {
                DetailsPlaceholder(text: "커밋 정보를 불러오지 못했습니다")
            }
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: model.selectedFile?.path ?? "커밋 세부 정보",
                systemImage: "text.alignleft"
            )
            Divider()

            if let commit = model.selectedCommit, model.selectedFile == nil {
                CommitInformationView(
                    commit: commit,
                    githubActionsSummary: model.githubActionsByCommit[commit.id],
                    githubChecks: model.selectedGitHubChecks,
                    isLoadingGitHubChecks: model.isLoadingSelectedGitHubChecks
                )
            } else if model.selectedCommit == nil {
                DetailsPlaceholder(text: "커밋 세부 정보")
            } else if model.isLoadingPatch {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let patch = model.selectedPatch, !patch.isEmpty {
                DiffView(patch: patch)
            } else {
                DetailsPlaceholder(text: "표시할 diff가 없습니다")
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return .green }
        if status.hasPrefix("D") { return .red }
        if status.hasPrefix("R") { return .blue }
        return .orange
    }
}

private struct CommitInformationView: View {
    let commit: GitCommit
    let githubActionsSummary: GitHubActionsSummary?
    let githubChecks: [GitHubCheckRun]
    let isLoadingGitHubChecks: Bool

    private var messageBody: String {
        let body = commit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix(commit.subject) else { return body }
        return String(body.dropFirst(commit.subject.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var referenceDetails: String {
        GitReference.Kind.allCases.compactMap { kind in
            let names = commit.references
                .filter { $0.kind == kind }
                .map(\.shortName)
            guard !names.isEmpty else { return nil }
            return "\(referenceKindTitle(kind)): \(names.joined(separator: ", "))"
        }
        .joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(commit.subject.isEmpty ? "(메시지 없음)" : commit.subject)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)

                if !messageBody.isEmpty {
                    Text(messageBody)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let githubActionsSummary {
                    GitHubActionsDetailsSection(
                        summary: githubActionsSummary,
                        checks: githubChecks,
                        isLoadingChecks: isLoadingGitHubChecks
                    )
                }

                Divider()

                if commit.isWorkingTree {
                    CommitMetadataRow(
                        title: "상태",
                        value: "커밋 전 작업 트리",
                        systemImage: "hammer.fill"
                    )
                    if let baseOID = commit.parentOIDs.first {
                        CommitMetadataRow(
                            title: "기준 커밋",
                            value: baseOID,
                            systemImage: "arrow.down.to.line",
                            monospaced: true
                        )
                    }
                } else {
                    if commit.isHead {
                        CommitMetadataRow(
                            title: "현재 위치",
                            value: "HEAD",
                            systemImage: "location.fill"
                        )
                    }
                    CommitMetadataRow(
                        title: "작성자",
                        value: "\(commit.authorName) <\(commit.authorEmail)>",
                        systemImage: "person.crop.circle"
                    )
                    CommitMetadataRow(
                        title: "작성 시각",
                        value: commit.authorDate.formatted(
                            .dateTime.year().month().day().hour().minute().second()
                        ),
                        systemImage: "clock"
                    )
                    CommitMetadataRow(
                        title: "커밋 해시",
                        value: commit.id.oid,
                        systemImage: "number",
                        monospaced: true
                    )
                    if !referenceDetails.isEmpty {
                        CommitMetadataRow(
                            title: "브랜치 및 태그",
                            value: referenceDetails,
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                    CommitMetadataRow(
                        title: "부모",
                        value: commit.parentOIDs.isEmpty
                            ? "없음"
                            : commit.parentOIDs.joined(separator: "\n"),
                        systemImage: "arrow.triangle.branch",
                        monospaced: true
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func referenceKindTitle(_ kind: GitReference.Kind) -> String {
        switch kind {
        case .local: return "로컬"
        case .remote: return "원격"
        case .tag: return "태그"
        }
    }
}

private struct GitHubActionsDetailsSection: View {
    let summary: GitHubActionsSummary
    let checks: [GitHubCheckRun]
    let isLoadingChecks: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: GitHubActionsLabels.systemImage(for: summary.state))
                    .foregroundStyle(GitHubActionsLabels.color(for: summary.state))
                Text("GitHub Actions")
                    .font(.system(size: 11, weight: .semibold))
                Text(GitHubActionsLabels.title(for: summary.state))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(GitHubActionsLabels.color(for: summary.state))
                Spacer(minLength: 8)
                if let url = summary.primaryURL {
                    Button("GitHub에서 열기") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary.runs) { run in
                    GitHubActionsResultRow(
                        title: run.name,
                        detail: workflowDetail(run),
                        state: run.state,
                        webURL: run.webURL
                    )
                }
            }

            if isLoadingChecks {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Job 상태를 불러오는 중…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else if !checks.isEmpty {
                Divider()
                Text("Jobs 및 Checks")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in
                        GitHubActionsResultRow(
                            title: check.name,
                            detail: check.appName,
                            state: check.state,
                            webURL: check.webURL
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        )
    }

    private func workflowDetail(_ run: GitHubWorkflowRun) -> String {
        var parts = ["#\(run.runNumber)"]
        if let branch = run.headBranch, !branch.isEmpty {
            parts.append(branch)
        }
        parts.append(run.event)
        return parts.joined(separator: " · ")
    }
}

private struct GitHubActionsResultRow: View {
    let title: String
    let detail: String?
    let state: GitHubActionsState
    let webURL: URL?

    var body: some View {
        Button {
            if let webURL {
                NSWorkspace.shared.open(webURL)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: GitHubActionsLabels.systemImage(for: state))
                    .foregroundStyle(GitHubActionsLabels.color(for: state))
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(GitHubActionsLabels.title(for: state))
                    .font(.system(size: 9))
                    .foregroundStyle(GitHubActionsLabels.color(for: state))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(webURL == nil)
    }
}

private struct CommitMetadataRow: View {
    let title: String
    let value: String
    let systemImage: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 10.5, design: monospaced ? .monospaced : .default))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PaneHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct CommitSummary: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(commit.subject)
                .font(.system(size: 12, weight: .semibold))
                .textSelection(.enabled)
            if commit.isWorkingTree {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.orange)
                    Text("현재 작업 트리")
                    Spacer()
                }
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                    Text("\(commit.authorName) <\(commit.authorEmail)>")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: commit.isHead ? "location.fill" : "number")
                    Text(commit.isHead ? "HEAD · \(commit.id.oid)" : commit.id.oid)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
                .foregroundStyle(commit.isHead ? Color.accentColor : .secondary)
            }
        }
        .font(.system(size: 10))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailsPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffView: View {
    private struct DiffLine: Identifiable {
        let id: Int
        let text: String
    }

    private let lines: [DiffLine]

    init(patch: String) {
        lines = patch.components(separatedBy: .newlines)
            .enumerated()
            .map { DiffLine(id: $0.offset, text: $0.element) }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(foreground(for: line.text))
                            .padding(.horizontal, 7)
                            .frame(minWidth: 900, minHeight: 17, alignment: .leading)
                            .background(background(for: line.text))
                            .textSelection(.enabled)
                    }
                }
                .frame(
                    minWidth: max(geometry.size.width, 900),
                    minHeight: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return .secondary
        }
        if line.hasPrefix("+") { return Color(red: 0.10, green: 0.45, blue: 0.20) }
        if line.hasPrefix("-") { return Color(red: 0.72, green: 0.18, blue: 0.16) }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("@@") { return Color.blue.opacity(0.08) }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.09) }
        return .clear
    }
}
