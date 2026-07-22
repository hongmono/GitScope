import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ToolWindowTabs(model: model)
            Divider()

            if model.workspaceURLs.isEmpty && !model.isLoading {
                WelcomeView(model: model)
            } else {
                workspaceContent
            }
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
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.workspaceURLs.isEmpty || model.isLoading)
            .help("새로고침 (⌘R)")
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
