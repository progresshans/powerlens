import SwiftUI

@main
struct PowerLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        configureSceneActions()
        return appScenes
    }

    private func configureSceneActions() {
        appDelegate.setDashboardWindowAction {
            openWindow(id: PowerLensSceneID.dashboard)
        }

        appDelegate.setSettingsWindowAction {
            openWindow(id: PowerLensSceneID.settings)
        }
    }

    @SceneBuilder
    private var appScenes: some Scene {
        Window(L10n.text("ui.window.dashboard"), id: PowerLensSceneID.dashboard) {
            DashboardSceneRootView(
                store: appDelegate.store,
                openSettings: { appDelegate.openSettingsWindow() }
            )
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("ui.section.settings")) {
                    appDelegate.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window(L10n.text("ui.window.settings"), id: PowerLensSceneID.settings) {
            SettingsSceneRootView(store: appDelegate.store)
        }
    }
}
