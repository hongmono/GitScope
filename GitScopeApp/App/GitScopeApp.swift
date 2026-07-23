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
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("GitScope — workspace") {
            ContentView(model: model)
                .frame(minWidth: 1_180, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            CommandGroup(replacing: .newItem) {
                Button("워크스페이스 열기…") {
                    model.openWorkspace()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.remoteOperation != nil)
            }

            CommandMenu("Git") {
                Button("새로고침") {
                    model.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.workspaceURLs.isEmpty || model.isLoading)
            }
        }
    }
}
