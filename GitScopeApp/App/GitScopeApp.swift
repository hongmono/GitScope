import SwiftUI

@main
struct GitScopeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("GitScope — workspace") {
            ContentView(model: model)
                .frame(minWidth: 1_180, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("워크스페이스 열기…") {
                    model.openWorkspace()
                }
                .keyboardShortcut("o", modifiers: .command)
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
