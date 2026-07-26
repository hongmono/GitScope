import Combine
import Sparkle
import SwiftUI

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("업데이트 확인…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// 설정 창에서 켜고 끄는 원격 조회 기능의 저장 키.
///
/// 저장된 값이 없으면 켜짐으로 취급해 기존 동작을 유지한다. `SettingsView` 의 `@AppStorage`
/// 기본값과 같은 값을 돌려줘야 한다.
enum AppSettings {
    static let authorAvatarLookupEnabledKey = "settings.authorAvatarLookupEnabled.v1"
    static let githubActionsEnabledKey = "settings.githubActionsEnabled.v1"

    /// 커밋 작성자 아바타를 원격에서 조회할지 여부.
    static var isAuthorAvatarLookupEnabled: Bool {
        isEnabled(forKey: authorAvatarLookupEnabledKey)
    }

    /// GitHub Actions 상태를 조회할지 여부.
    static var isGitHubActionsEnabled: Bool {
        isEnabled(forKey: githubActionsEnabledKey)
    }

    private static func isEnabled(forKey key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.authorAvatarLookupEnabledKey)
    private var isAuthorAvatarLookupEnabled = true
    @AppStorage(AppSettings.githubActionsEnabledKey)
    private var isGitHubActionsEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("커밋 작성자 아바타 불러오기", isOn: $isAuthorAvatarLookupEnabled)
            } header: {
                Text("작성자 아바타")
            } footer: {
                Text("GitHub와 gh CLI로 작성자 아바타를 조회합니다. 끄면 이름 기반 색상 아바타만 표시합니다.")
                    .font(AppFont.metadataValue)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("GitHub Actions 상태 표시", isOn: $isGitHubActionsEnabled)
            } header: {
                Text("GitHub Actions")
            } footer: {
                Text("커밋의 워크플로 실행 상태를 GitHub API로 주기적으로 조회합니다. 끄면 상태 배지가 사라집니다.")
                    .font(AppFont.metadataValue)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 460)
    }
}

@main
struct GitScopeApp: App {
    @StateObject private var model = AppModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: shouldStartSparkleUpdater,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("\(appDisplayName) — workspace") {
            windowContent
        }
        .windowStyle(.titleBar)
        // `.unifiedCompact` 은 사이드바가 타이틀바 아래에서 시작하게 만들어 가로 이음매를 남긴다.
        // `.unified` 라야 `NavigationSplitView` 사이드바 머티리얼이 창 최상단까지 이어지고
        // 신호등이 그 위에 얹힌다. 여전히 1행 툴바다.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            #if !DEBUG
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif

            CommandGroup(replacing: .newItem) {
                Button("워크스페이스 열기…") {
                    model.openWorkspace()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.remoteOperation != nil)
            }

            CommandGroup(after: .sidebar) {
                Button(
                    model.isBranchSidebarVisible
                        ? "브랜치 사이드바 숨기기"
                        : "브랜치 사이드바 보기"
                ) {
                    withAnimation(AppMotion.pane) {
                        model.isBranchSidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)

                Button(
                    model.isCommitDetailsVisible
                        ? "커밋 상세 숨기기"
                        : "커밋 상세 보기"
                ) {
                    withAnimation(AppMotion.pane) {
                        model.isCommitDetailsVisible.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            CommandMenu("Git") {
                Button("모든 원격 저장소 가져오기") {
                    model.fetchAll()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.repositories.isEmpty || model.isLoading)
            }

            CommandGroup(before: .windowList) {
                ForEach(
                    Array(model.workspaceTabs.prefix(9).enumerated()),
                    id: \.element.id
                ) { index, tab in
                    Button(tab.title) {
                        model.activateWorkspaceTab(tab.id)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: .command
                    )
                    .disabled(model.remoteOperation != nil)
                }

                if !model.workspaceTabs.isEmpty {
                    Divider()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "GitScope"
    }

    /// 창 제목. 툴바에서는 숨기지만 Mission Control·Window 메뉴에서 창을 식별하는 데 쓰인다.
    private var windowTitle: String {
        model.activeWorkspaceTab?.title ?? appDisplayName
    }

    /// 창 배경을 칠하지 않는다. 불투명한 컨테이너 배경은 `NavigationSplitView` 사이드바의
    /// 반투명 머티리얼을 가려 네이티브 3-pane 외형을 무너뜨린다.
    ///
    /// 최소 너비는 실측값이다. 이보다 좁으면 분할 뷰가 열을 압축하지 않고 넘쳐서 사이드바
    /// 내용이 왼쪽으로 잘린다. 1100·1150 사이가 실제 하한이며 1180 은 그 위의 최소 상용값이다.
    private var windowContent: some View {
        ContentView(model: model)
            .frame(minWidth: 1_180, minHeight: 720)
            .navigationTitle(windowTitle)
    }
}

private var shouldStartSparkleUpdater: Bool {
    #if DEBUG
    false
    #else
    true
    #endif
}
