import AppKit
import SwiftUI

struct CommitDetailsView: View {
    var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VSplitView {
            changedFilesPane
            diffPane
        }
        .background(.clear)
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
                InspectorUnavailableView(
                    title: "변경 사항을 확인할 커밋 선택",
                    systemImage: "doc.on.doc",
                    description: "히스토리에서 커밋을 고르면 변경된 파일 목록이 표시됩니다."
                )
            } else if model.isLoadingDetails {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let details = model.selectedDetails {
                VStack(spacing: 0) {
                    CommitSummary(commit: details.commit)
                    Divider()
                    if details.files.isEmpty {
                        InspectorUnavailableView(
                            title: "변경된 파일이 없습니다",
                            systemImage: "tray",
                            description: "이 커밋은 파일 내용을 바꾸지 않았습니다."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(details.files) { file in
                                    Button {
                                        model.selectChangedFile(file)
                                    } label: {
                                        HStack(spacing: 7) {
                                            // rename/copy 는 "R100" 처럼 4글자라 11pt 고정폭 기준
                                            // 약 27pt 가 필요하다. 좁으면 두 줄로 접혀 25pt 행 리듬이 깨진다.
                                            Text(file.status)
                                                .font(AppFont.badgeMono)
                                                .foregroundStyle(statusColor(file.status))
                                                .lineLimit(1)
                                                .frame(width: 30, alignment: .leading)
                                            Image(systemName: "doc.text")
                                                .foregroundStyle(.secondary)
                                            Text(file.path)
                                                .font(AppFont.rowLabel)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 9)
                                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                                        .appGlassSelection(model.selectedFile?.id == file.id)
                                        .padding(.horizontal, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            } else {
                InspectorUnavailableView(
                    title: "커밋 정보를 불러오지 못했습니다",
                    systemImage: "exclamationmark.triangle",
                    description: "다른 커밋을 선택하거나 저장소를 새로 고쳐 주세요."
                )
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
                InspectorUnavailableView(
                    title: "커밋 세부 정보",
                    systemImage: "text.alignleft",
                    description: "커밋을 선택하면 메시지와 메타데이터가 여기에 표시됩니다."
                )
            } else if model.isLoadingPatch {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let patch = model.selectedPatch, !patch.isEmpty {
                DiffView(patch: patch)
            } else {
                InspectorUnavailableView(
                    title: "표시할 diff가 없습니다",
                    systemImage: "doc.plaintext",
                    description: "바이너리 파일이거나 내용 변경이 없는 파일입니다."
                )
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return AppStatusColor.success }
        if status.hasPrefix("D") { return AppStatusColor.danger }
        if status.hasPrefix("R") { return AppStatusColor.progress }
        return AppStatusColor.warning
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
            return "\(kind.displayName): \(names.joined(separator: ", "))"
        }
        .joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(commit.subject.isEmpty ? "(메시지 없음)" : commit.subject)
                    .font(AppFont.sectionTitle)
                    .textSelection(.enabled)

                if !messageBody.isEmpty {
                    Text(messageBody)
                        .font(AppFont.metadataValue)
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
                    .font(AppFont.badge)
                Text(GitHubActionsLabels.title(for: summary.state))
                    .font(AppFont.rowLabelEmphasized)
                    .foregroundStyle(GitHubActionsLabels.color(for: summary.state))
                Spacer(minLength: 8)
                if let url = summary.primaryURL {
                    Button("GitHub에서 열기") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.link)
                    .font(AppFont.rowLabel)
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

            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary.runs) { run in
                    GitHubActionsStatusRow(
                        title: run.name,
                        detail: run.detailSummary,
                        state: run.state,
                        webURL: run.webURL,
                        style: .inspector
                    )
                }
            }

            if isLoadingChecks {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Job 상태를 불러오는 중…")
                        .font(AppFont.rowLabel)
                        .foregroundStyle(.secondary)
                }
            } else if !checks.isEmpty {
                Divider()
                Text("Jobs 및 Checks")
                    .font(AppFont.metadataTitle)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in
                        GitHubActionsStatusRow(
                            title: check.name,
                            detail: check.appName,
                            state: check.state,
                            webURL: check.webURL,
                            style: .inspector
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(AppColor.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppColor.separator.opacity(0.55), lineWidth: 0.5)
        )
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
                    .font(AppFont.metadataTitle)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(monospaced ? AppFont.monoSmall : AppFont.metadataValue)
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
                .font(AppFont.paneTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        // 인스펙터는 시스템이 자체 배경을 깔아준다. 여기에 띠 채움을 더하면 이중 배경이 되고,
        // 위아래 두 헤더가 인스펙터 폭에서 두 줄의 회색 띠로 보인다. 구분은 아래 `Divider()` 가 맡는다.
    }
}

private struct CommitSummary: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(commit.subject)
                .font(AppFont.sectionTitle)
                .textSelection(.enabled)
            if commit.isWorkingTree {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(AppStatusColor.warning)
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
                        .font(AppFont.monoSmall)
                        .textSelection(.enabled)
                }
                .foregroundStyle(commit.isHead ? Color.accentColor : .secondary)
            }
        }
        .font(AppFont.rowLabel)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 좁은 인스펙터 폭(약 300pt)에 맞춘 빈 상태.
///
/// `ContentUnavailableView` 의 기본 타이포 스케일은 창 전체를 차지하는 빈 상태 기준이라,
/// 상세 패널에 두 개가 위아래로 쌓이면 제목이 두 줄로 접히며 패널을 압도한다. 레이블 폰트만
/// 낮춰 네이티브 컴포넌트를 그대로 쓰는 방법은 실제 패널 높이에서 아이콘이 그려지지 않는
/// 경우가 있어(같은 코드로 아래 패널은 그려지고 위 패널은 누락) 쓰지 않는다. 아이콘·제목·설명
/// 3요소가 항상 나오도록 동등한 구조를 직접 쌓고, 크기는 `AppFont` 토큰만 사용한다.
///
/// 중앙 히스토리처럼 창 전체 폭을 쓰는 빈 상태는 네이티브 `ContentUnavailableView` 를 유지한다.
private struct InspectorUnavailableView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(AppFont.loadingGlyph)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.bottom, 2)
            Text(title)
                .font(AppFont.sectionTitle)
                .multilineTextAlignment(.center)
            Text(description)
                .font(AppFont.rowLabel)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct DiffView: View {
    let patch: String

    @Environment(\.colorScheme) private var colorScheme

    /// 이 뷰는 부모 body 가 재평가될 때마다 새로 만들어지므로 init 에서 파싱하면 큰 패치는
    /// 재평가마다 전체 문자열을 다시 분해한다. 파싱 결과를 `@State` 에 두고 패치가 실제로
    /// 바뀔 때만 갱신한다.
    @State private var lines: [DiffLine] = []

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(AppFont.monoSmall)
                            .foregroundStyle(foreground(for: line.kind))
                            .padding(.horizontal, 7)
                            .frame(minWidth: 900, minHeight: 17, alignment: .leading)
                            .background(background(for: line.kind))
                            .textSelection(.enabled)
                    }
                }
                .frame(
                    minWidth: max(geometry.size.width, 900),
                    minHeight: geometry.size.height,
                    alignment: .topLeading
                )
            }
            // 인스펙터 아래 칸을 꽉 채우는 코드 캔버스. 카드 시절의 5pt 인셋과 둥근 모서리를
            // 없애고 평평한 텍스트 배경만 남겨 인스펙터 배경과 톤이 겹치지 않게 한다.
            .background(AppColor.contentSurface)
        }
        .onChange(of: patch, initial: true) { _, patch in
            lines = DiffLine.parse(patch)
        }
    }

    private func foreground(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .fileHeader, .hunkHeader: return .secondary
        case .addition: return AppStatusColor.success
        case .deletion: return AppStatusColor.danger
        case .context: return .primary
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .hunkHeader: return AppStatusColor.progressFill.opacity(highlightOpacity)
        case .addition: return AppStatusColor.successFill.opacity(highlightOpacity)
        case .deletion: return AppStatusColor.dangerFill.opacity(highlightOpacity)
        case .fileHeader, .context: return .clear
        }
    }

    /// 다크에서는 바탕이 거의 검정이어서 라이트와 같은 불투명도로는 하이라이트가 보이지 않는다.
    private var highlightOpacity: Double {
        colorScheme == .dark ? 0.16 : 0.085
    }
}
