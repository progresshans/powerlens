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
}

struct DashboardSceneRootView: View {
    @StateObject private var session = DashboardSession()
    @ObservedObject var store: PowerLensStore
    let openSettings: () -> Void
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        VisibleWindowContent(onVisibilityChange: { visible in
            if visible { store.presentationDidBecomeActive() }
        }) {
            DashboardView(store: store, openSettings: openSettings, session: session)
        }
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
    @ObservedObject var softwareUpdateController: SoftwareUpdateController
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        SettingsView(
            store: store,
            softwareUpdateController: softwareUpdateController,
            launchAtLoginController: launchAtLoginController
        )
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

/// Mounts a window's content only while the window can be seen. SwiftUI keeps
/// a closed `Window` scene's views alive, and they would otherwise redraw on
/// every refresh, and on every tick of their timers, with nobody looking.
struct VisibleWindowContent<Content: View>: View {
    var onVisibilityChange: (Bool) -> Void = { _ in }
    @ViewBuilder let content: Content
    @State private var isVisible = true

    var body: some View {
        ZStack {
            if isVisible {
                content
            } else {
                Color.clear
            }
        }
        .background(
            WindowVisibilityObserver(isVisible: $isVisible)
                .frame(width: 0, height: 0)
        )
        .onAppear { onVisibilityChange(isVisible) }
        .onChange(of: isVisible) { onVisibilityChange(isVisible) }
    }
}

struct WindowVisibilityObserver: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.observe(window)
        }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        context.coordinator.isVisible = $isVisible
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.observe(nil)
    }

    final class ObserverView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var isVisible: Binding<Bool>
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
        }

        func observe(_ window: NSWindow?) {
            guard window !== self.window else {
                return
            }
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            self.window = window
            guard let window else {
                return
            }

            // Becoming key arrives before the first frame is drawn, so content
            // is back in place when the window reappears.
            let changes: [(Notification.Name, Rule)] = [
                (NSWindow.didBecomeKeyNotification, .shown),
                (NSWindow.didDeminiaturizeNotification, .shown),
                (NSWindow.willCloseNotification, .hidden),
                (NSWindow.didMiniaturizeNotification, .hidden),
                (NSWindow.didChangeOcclusionStateNotification, .occlusion),
            ]
            tokens = changes.map { name, rule in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else {
                            return
                        }
                        self.set(rule.isVisible(window))
                    }
                }
            }
            set(WindowContentVisibility.isVisible(window))
        }

        private enum Rule: Sendable {
            case shown
            case hidden
            case occlusion

            @MainActor
            func isVisible(_ window: NSWindow) -> Bool {
                switch self {
                case .shown: true
                case .hidden: false
                case .occlusion: WindowContentVisibility.isVisible(window)
                }
            }
        }

        private func set(_ value: Bool) {
            if isVisible.wrappedValue != value {
                isVisible.wrappedValue = value
            }
        }

        isolated deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
