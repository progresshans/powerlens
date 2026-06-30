import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PowerLensStore()
    let softwareUpdateController = SoftwareUpdateController()
    let launchAtLoginController = LaunchAtLoginController()

    private let diagnosticsNotifier = DiagnosticsNotifier()

    private let dashboardSceneController = DashboardSceneController()
    private let presentationController = ApplicationPresentationController()
    private let managedWindowController = ManagedWindowController(
        managedIdentifiers: [
            PowerLensWindowIdentifier.dashboard,
            PowerLensWindowIdentifier.settings,
        ]
    )
    private var openSettingsWindowAction: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    private lazy var statusItemController = MenuBarStatusItemController { [weak self] sender in
        self?.togglePopover(sender)
    }

    private lazy var popoverPresenter = MenuBarPopoverPresenter(
        store: store,
        openDashboard: { [weak self] in
            self?.openDashboard()
        },
        openSettings: { [weak self] in
            self?.openSettingsWindow()
        },
        quitApplication: {
            NSApp.terminate(nil)
        },
        onVisibilityChange: { [weak self] in
            self?.updateRefreshCadence()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy(force: true)
        _ = statusItemController
        _ = popoverPresenter
        observeChanges()
        softwareUpdateController.startIfConfigured()
        updateStatusItem(using: store.latest)
        updateRefreshCadence()

        if DockIconPreference.current {
            dashboardSceneController.showDashboard()
        }
    }

    func setDashboardWindowAction(_ action: @escaping () -> Void) {
        dashboardSceneController.setOpenDashboardWindowAction(action)
    }

    func setSettingsWindowAction(_ action: @escaping () -> Void) {
        openSettingsWindowAction = action
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else {
            return true
        }

        showDashboardWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func openSettingsWindow() {
        prepareForWindowPresentation()
        openSettingsWindowAction?()
        focusManagedWindow(identifier: PowerLensWindowIdentifier.settings)
    }

    func checkForUpdates() {
        softwareUpdateController.checkForUpdates()
    }

    private func observeChanges() {
        store.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else {
                    return
                }

                self.updateStatusItem(using: snapshot)
                self.popoverPresenter.updateLayoutIfShown(using: snapshot)
            }
            .store(in: &cancellables)

        store.$diagnostics
            .receive(on: RunLoop.main)
            .sink { [weak self] diagnostics in
                self?.diagnosticsNotifier.process(diagnostics: diagnostics)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyActivationPolicy()
                self?.refreshLocalizedViews()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard L10n.currentLanguage == .system else {
                    return
                }

                self?.refreshLocalizedViews()
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification),
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification),
            NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification),
            NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification),
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateWindowDrivenPresentation()
        }
        .store(in: &cancellables)
    }

    private func togglePopover(_ sender: AnyObject?) {
        popoverPresenter.toggle(relativeTo: statusItemController.button, snapshot: store.latest)
    }

    private func refreshLocalizedViews() {
        popoverPresenter.refreshLocalizedViews(snapshot: store.latest)
        updateStatusItem(using: store.latest)
        managedWindowController.updateManagedWindowTitle(
            identifier: PowerLensWindowIdentifier.dashboard,
            title: L10n.text("ui.window.dashboard")
        )
        managedWindowController.updateManagedWindowTitle(
            identifier: PowerLensWindowIdentifier.settings,
            title: L10n.text("ui.window.settings")
        )
    }

    private func updateStatusItem(using snapshot: TelemetrySnapshot?) {
        statusItemController.update(
            snapshot: snapshot,
            symbolName: store.menuBarSymbolName,
            batteryBadge: store.menuBarBatteryBadge
        )
    }

    private func openDashboard() {
        popoverPresenter.close()
        showDashboardWindow()
    }

    private func showDashboardWindow() {
        prepareForWindowPresentation()
        dashboardSceneController.showDashboard()
        focusManagedWindow(identifier: PowerLensWindowIdentifier.dashboard)
    }

    private func updateRefreshCadence() {
        let hasVisibleWindow = managedWindowController.hasManagedWindow(includeMiniaturized: false)
        store.setRefreshCadence((popoverPresenter.isShown || hasVisibleWindow) ? .interactive : .background)
    }

    private func updateWindowDrivenPresentation() {
        DispatchQueue.main.async { [weak self] in
            self?.applyActivationPolicy()
            self?.updateRefreshCadence()
        }
    }

    private func prepareForWindowPresentation() {
        presentationController.prepareForWindowPresentation { [weak self] in
            self?.applyActivationPolicy()
        }
    }

    private func focusManagedWindow(identifier: String) {
        managedWindowController.focusManagedWindow(identifier: identifier) { [weak self] didFocus in
            guard let self else {
                return
            }

            if didFocus {
                self.presentationController.clearTemporaryRegularPolicy()
            }

            self.applyActivationPolicy()
            self.updateRefreshCadence()
        }
    }

    private func applyActivationPolicy(force: Bool = false) {
        presentationController.applyActivationPolicy(
            force: force,
            hasManagedWindow: managedWindowController.hasManagedWindow(includeMiniaturized: true)
        )
    }
}
