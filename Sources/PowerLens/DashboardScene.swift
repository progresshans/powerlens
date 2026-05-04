import AppKit
import SwiftUI

enum PowerLensSceneID {
    static let dashboard = "dashboard"
    static let settings = "settings"
}

enum PowerLensWindowIdentifier {
    static let dashboard = "PowerLensDashboardWindow"
    static let settings = "PowerLensSettingsWindow"
}

@MainActor
final class DashboardSceneController {
    private var openDashboardWindow: (() -> Void)?
    private var hasPendingOpenRequest = false

    func setOpenDashboardWindowAction(_ action: @escaping () -> Void) {
        openDashboardWindow = action

        guard hasPendingOpenRequest else {
            return
        }

        hasPendingOpenRequest = false
        action()
    }

    func showDashboard() {
        guard let openDashboardWindow else {
            hasPendingOpenRequest = true
            return
        }

        hasPendingOpenRequest = false
        openDashboardWindow()
    }

    @discardableResult
    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else {
            return true
        }

        showDashboard()
        return false
    }
}

struct DashboardSceneRootView: View {
    @ObservedObject var store: PowerLensStore
    let openSettings: () -> Void
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        DashboardView(store: store, openSettings: openSettings)
            .environment(\.locale, L10n.locale)
            .id(appLanguage)
            .background(
                WindowConfigurationView(
                    appLanguage: appLanguage,
                    titleKey: "ui.window.dashboard",
                    identifier: PowerLensWindowIdentifier.dashboard,
                    minSize: NSSize(width: 1120, height: 760),
                    frameAutosaveName: PowerLensWindowIdentifier.dashboard
                )
                    .frame(width: 0, height: 0)
            )
    }
}

struct SettingsSceneRootView: View {
    @ObservedObject var store: PowerLensStore
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        SettingsView(store: store)
            .environment(\.locale, L10n.locale)
            .id(appLanguage)
            .background(
                WindowConfigurationView(
                    appLanguage: appLanguage,
                    titleKey: "ui.window.settings",
                    identifier: PowerLensWindowIdentifier.settings,
                    minSize: NSSize(width: 760, height: 480),
                    frameAutosaveName: nil
                )
                .frame(width: 0, height: 0)
            )
    }
}

private struct WindowConfigurationView: NSViewRepresentable {
    let appLanguage: String
    let titleKey: String
    let identifier: String
    let minSize: NSSize
    let frameAutosaveName: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        scheduleWindowConfigurationIfNeeded(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard nsView.window != nil else {
            scheduleWindowConfigurationIfNeeded(for: nsView, coordinator: context.coordinator)
            return
        }

        configureWindow(for: nsView, coordinator: context.coordinator)
    }

    private func scheduleWindowConfigurationIfNeeded(for view: NSView, coordinator: Coordinator) {
        guard !coordinator.hasPendingConfiguration else {
            return
        }

        coordinator.hasPendingConfiguration = true
        DispatchQueue.main.async {
            coordinator.hasPendingConfiguration = false
            configureWindow(for: view, coordinator: coordinator)
        }
    }

    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        guard let window = view.window else {
            return
        }

        _ = appLanguage

        if coordinator.windowNumber != window.windowNumber {
            coordinator.windowNumber = window.windowNumber
            coordinator.lastTitle = nil
            coordinator.lastMinSize = nil
            coordinator.lastIdentifier = nil
            coordinator.didApplyFrameAutosaveName = false
        }

        let title = L10n.text(titleKey)
        if coordinator.lastTitle != title {
            window.title = title
            coordinator.lastTitle = title
        }

        if coordinator.lastMinSize != minSize {
            window.minSize = minSize
            coordinator.lastMinSize = minSize
        }

        if coordinator.lastIdentifier != identifier {
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
            coordinator.lastIdentifier = identifier
        }

        if window.tabbingMode != .disallowed {
            window.tabbingMode = .disallowed
        }

        if !window.isRestorable {
            window.isRestorable = true
        }

        if let frameAutosaveName {
            if !coordinator.didApplyFrameAutosaveName {
                window.setFrameAutosaveName(frameAutosaveName)
                coordinator.didApplyFrameAutosaveName = true
            }
        }
    }

    final class Coordinator {
        var hasPendingConfiguration = false
        var windowNumber: Int?
        var lastTitle: String?
        var lastMinSize: NSSize?
        var lastIdentifier: String?
        var didApplyFrameAutosaveName = false
    }
}
