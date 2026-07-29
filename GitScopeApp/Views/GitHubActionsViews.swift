import AppKit
import SwiftUI

/// 히스토리 행 오른쪽 끝에 붙는 GitHub Actions 상태 배지.
struct GitHubActionsHistoryBadge: View {
    let summary: GitHubActionsSummary
    let isSelected: Bool
    @State private var isShowingRuns = false
    @State private var checks: [GitHubCheckRun] = []
    @State private var isLoadingChecks = false

    var body: some View {
        Button {
            isShowingRuns.toggle()
        } label: {
            Image(systemName: GitHubActionsLabels.systemImage(for: summary.state))
                .font(AppFont.badge)
                .foregroundStyle(
                    isSelected
                        ? Color.primary
                        : GitHubActionsLabels.color(for: summary.state)
                )
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(
            "GitHub Actions \(GitHubActionsLabels.title(for: summary.state)), "
                + "\(summary.runs.count)개 워크플로"
        )
        .popover(isPresented: $isShowingRuns, arrowEdge: .trailing) {
            GitHubActionsRunsPopover(
                summary: summary,
                checks: checks,
                isLoadingChecks: isLoadingChecks
            )
        }
        .task(id: isShowingRuns) {
            guard isShowingRuns, checks.isEmpty else { return }
            isLoadingChecks = true
            do {
                checks = try await GitHubActionsService.shared.loadCheckRuns(
                    repository: summary.repository,
                    commitSHA: summary.commitID.oid
                )
            } catch {
                checks = []
            }
            isLoadingChecks = false
        }
    }

    private var helpText: String {
        let workflows = summary.runs.prefix(6).map { run in
            "\(run.name): \(GitHubActionsLabels.title(for: run.state))"
        }
        return (["GitHub Actions · \(summary.runs.count)개 워크플로"] + workflows)
            .joined(separator: "\n")
    }
}

private struct GitHubActionsRunsPopover: View {
    let summary: GitHubActionsSummary
    let checks: [GitHubCheckRun]
    let isLoadingChecks: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text("GitHub Actions")
                    .font(AppFont.paneTitle)
                Spacer(minLength: 12)
                Text("\(summary.runs.count)개 워크플로")
                    .font(AppFont.rowLabel)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text("워크플로")
                        .font(AppFont.metadataTitle)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    ForEach(summary.runs) { run in
                        GitHubActionsStatusRow(
                            title: run.name,
                            detail: run.detailSummary,
                            state: run.state,
                            webURL: run.webURL,
                            style: .popover
                        )
                    }

                    if isLoadingChecks || !checks.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        Text("Jobs 및 Checks")
                            .font(AppFont.metadataTitle)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)

                        if isLoadingChecks {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("상태를 불러오는 중…")
                                    .font(AppFont.rowLabel)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 38)
                            .padding(.horizontal, 8)
                        } else {
                            ForEach(checks) { check in
                                GitHubActionsStatusRow(
                                    title: check.name,
                                    detail: check.appName,
                                    state: check.state,
                                    webURL: check.webURL,
                                    style: .popover
                                )
                            }
                        }
                    }
                }
            }
            .frame(
                height: min(
                    max(CGFloat(visibleRowCount) * 42 + 20, 62),
                    314
                )
            )
        }
        .padding(12)
        .frame(width: 340)
    }

    private var visibleRowCount: Int {
        summary.runs.count + max(checks.count, isLoadingChecks ? 1 : 0)
    }
}

/// 워크플로 실행·체크 하나를 GitHub 링크 버튼으로 그리는 공용 행.
///
/// 히스토리 팝오버와 커밋 상세 패널이 같은 정보를 같은 동작(클릭 시 브라우저 열기, 링크가
/// 없으면 비활성, 포인팅 핸드 커서)으로 보여 준다. 두 자리의 밀도만 달라 그 차이를
/// `Style` 로 주입한다.
struct GitHubActionsStatusRow: View {
    enum Style {
        /// 히스토리 배지 팝오버. 제목·부제를 두 줄로 쌓고 호버 배경과 외부 링크 글리프를 둔다.
        case popover
        /// 커밋 상세 패널. 카드 안에 조밀하게 한 줄로 놓는다.
        case inspector
    }

    let title: String
    let detail: String?
    let state: GitHubActionsState
    let webURL: URL?
    let style: Style
    @State private var isHovered = false

    var body: some View {
        switch style {
        case .popover:
            linkButton { popoverContent }
                .help(webURL == nil ? "" : "\(title) 실행을 GitHub에서 열기")
                .accessibilityLabel(
                    "\(title), \(GitHubActionsLabels.title(for: state))"
                        + (webURL == nil ? "" : ", GitHub에서 열기")
                )
        case .inspector:
            linkButton { inspectorContent }
        }
    }

    private func linkButton(
        @ViewBuilder content: () -> some View
    ) -> some View {
        Button {
            if let webURL {
                NSWorkspace.shared.open(webURL)
            }
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .disabled(webURL == nil)
        .onContinuousHover { phase in
            switch phase {
            case .active where webURL != nil:
                isHovered = true
                NSCursor.pointingHand.set()
            case .active, .ended:
                isHovered = false
                NSCursor.arrow.set()
            }
        }
    }

    private var popoverContent: some View {
        HStack(spacing: 8) {
            stateIcon(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.rowLabelEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppFont.rowLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(GitHubActionsLabels.title(for: state))
                .font(AppFont.badge)
                .foregroundStyle(GitHubActionsLabels.color(for: state))

            if webURL != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(AppFont.decorativeGlyph)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.accentColor.opacity(0.11) : .clear)
        )
        .contentShape(Rectangle())
    }

    private var inspectorContent: some View {
        HStack(spacing: 7) {
            stateIcon(width: 13)
            Text(title)
                .font(AppFont.rowLabelEmphasized)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppFont.rowLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(GitHubActionsLabels.title(for: state))
                .font(AppFont.rowLabel)
                .foregroundStyle(GitHubActionsLabels.color(for: state))
        }
        .contentShape(Rectangle())
    }

    private func stateIcon(width: CGFloat) -> some View {
        Image(systemName: GitHubActionsLabels.systemImage(for: state))
            .foregroundStyle(GitHubActionsLabels.color(for: state))
            .frame(width: width)
    }
}

enum GitHubActionsLabels {
    static func title(for state: GitHubActionsState) -> String {
        switch state {
        case .queued: return "대기 중"
        case .inProgress: return "실행 중"
        case .success: return "성공"
        case .failure: return "실패"
        case .cancelled: return "취소됨"
        case .neutral: return "건너뜀"
        case .unknown: return "확인 필요"
        }
    }

    static func systemImage(for state: GitHubActionsState) -> String {
        switch state {
        case .queued: return "clock.fill"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle.fill"
        case .neutral: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    static func color(for state: GitHubActionsState) -> Color {
        switch state {
        case .queued: return AppStatusColor.warning
        case .inProgress: return AppStatusColor.progress
        case .success: return AppStatusColor.success
        case .failure: return AppStatusColor.danger
        case .cancelled, .neutral, .unknown: return AppStatusColor.neutral
        }
    }
}
