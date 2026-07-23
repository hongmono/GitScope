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

    var body: some View {
        HStack(spacing: 4) {
            ToolTab(title: "Git", isSelected: false)
            ToolTab(title: "로그", isSelected: true)
            ToolTab(title: "콘솔", isSelected: false)

            Divider()
                .frame(height: 17)
                .padding(.horizontal, 3)

            Button {
                model.openWorkspace()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .disabled(model.remoteOperation != nil)
            .help("워크스페이스 열기 (⌘O)")

            Spacer()

            if model.workspaceURLs.count == 1, let workspaceURL = model.workspaceURL {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(workspaceURL.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !model.workspaceURLs.isEmpty {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.secondary)
                Text("\(model.workspaceURLs.count)개 위치 · \(model.repositories.count)개 저장소")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 6)
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

private struct ToolTab: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color(nsColor: .selectedControlColor).opacity(0.14) : .clear)
            )
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
