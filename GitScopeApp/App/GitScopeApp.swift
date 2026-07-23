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
            ContentView(model: model)
                .frame(minWidth: 1_180, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
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

            CommandMenu("Git") {
                Button("모든 원격 저장소 가져오기") {
                    model.fetchAll()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.repositories.isEmpty || model.isLoading)
            }

            CommandMenu("탭") {
                ForEach(1...9, id: \.self) { number in
                    Button("\(number)번째 탭으로 이동") {
                        model.activateWorkspaceTab(at: number - 1)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(number))),
                        modifiers: .command
                    )
                    .disabled(
                        number > model.workspaceTabs.count
                            || model.remoteOperation != nil
                    )
                }
            }
        }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "GitScope"
    }
}

private var shouldStartSparkleUpdater: Bool {
    #if DEBUG
    false
    #else
    true
    #endif
}
