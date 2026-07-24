import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stateAnimation: Animation? {
        reduceMotion
            ? .linear(duration: 0.10)
            : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowTabs(model: model)
            Divider()

            ZStack {
                if model.workspaceURLs.isEmpty && model.isLoadingWorkspace {
                    InitialWorkspaceLoadingView()
                        .transition(.opacity)
                } else if model.workspaceURLs.isEmpty {
                    WelcomeView(model: model)
                        .transition(.opacity)
                } else {
                    workspaceContent
                        .id(model.activeWorkspaceTabID)
                        .transition(.opacity)

                    if model.isLoadingWorkspace {
                        WorkspaceLoadingOverlay()
                            .transition(.opacity)
                    }
                }
            }
            .animation(stateAnimation, value: model.isLoadingWorkspace)
            .animation(stateAnimation, value: model.workspaceURLs)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.restoreWorkspaceIfNeeded()
        }
        .alert(
            "GitScope 오류",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
    }

    private var workspaceContent: some View {
        HSplitView {
            BranchSidebarView(model: model)
                .frame(minWidth: 235, idealWidth: 285, maxWidth: 380)

            HistoryView(model: model)
                .frame(minWidth: 650, idealWidth: 900)

            CommitDetailsView(model: model)
                .frame(minWidth: 300, idealWidth: 480)
        }
    }
}

private struct InitialWorkspaceLoadingView: View {
    var body: some View {
        VStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text("Git 로그를 불러오는 중")
                    .font(.system(size: 16, weight: .semibold))
                Text("저장소와 브랜치를 확인하고 커밋 그래프를 구성하고 있습니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Git 로그를 불러오는 중")
    }
}

private struct WorkspaceLoadingOverlay: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.36)

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Git 로그 업데이트 중…")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Git 로그 업데이트 중")
    }
}

private struct ToolWindowTabs: View {
    @ObservedObject var model: AppModel
    @State private var tabContentWidth: CGFloat = 640

    private let maximumTabContentWidth: CGFloat = 640

    var body: some View {
        HStack(spacing: 4) {
            if !model.workspaceTabs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(model.workspaceTabs) { tab in
                            WorkspaceTabItem(
                                tab: tab,
                                isSelected: model.activeWorkspaceTabID == tab.id,
                                isDisabled: model.remoteOperation != nil,
                                onSelect: {
                                    model.activateWorkspaceTab(tab.id)
                                },
                                onClose: {
                                    model.closeWorkspaceTab(tab.id)
                                }
                            )
                        }
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: TabContentWidthPreferenceKey.self,
                                value: geometry.size.width
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(
                    minWidth: 0,
                    idealWidth: min(tabContentWidth, maximumTabContentWidth),
                    maxWidth: min(tabContentWidth, maximumTabContentWidth),
                    alignment: .leading
                )
                .layoutPriority(1)
                .onPreferenceChange(TabContentWidthPreferenceKey.self) { width in
                    tabContentWidth = width
                }
            }

            Button {
                model.openWorkspace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .disabled(model.remoteOperation != nil)
            .help("워크스페이스 열기 (⌘O)")

            Spacer()

            if model.repositories.count > 1 {
                Text("\(model.repositories.count)개 저장소")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 6)
            }

            if let notice = model.githubActionsNotice {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(notice)
                    .accessibilityLabel("GitHub Actions 정보를 불러오지 못함")
            }

            if model.repositories.contains(where: { $0.githubRepository != nil }) {
                Button {
                    model.refreshGitHubActions()
                } label: {
                    Image(systemName: "bolt.horizontal.circle")
                }
                .buttonStyle(.plain)
                .help("GitHub Actions 상태 새로고침")
            }

            Button {
                model.fetchAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.repositories.isEmpty || model.isLoading)
            .help("모든 원격 저장소 가져오기 (⌘R)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TabContentWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WorkspaceTabItem: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(tab.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help("탭 닫기")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minWidth: 90, maxWidth: 180, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected
                        ? Color(nsColor: .selectedControlColor).opacity(0.16)
                        : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isSelected
                        ? Color(nsColor: .separatorColor).opacity(0.6)
                        : Color.clear,
                    lineWidth: 0.5
                )
        )
        .help(tab.subtitle)
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Git 워크스페이스를 열어주세요")
                .font(.system(size: 18, weight: .semibold))
            Text("선택한 폴더와 하위 폴더의 Git 저장소를 한 화면에 표시합니다.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("워크스페이스 열기…") {
                model.openWorkspace()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
