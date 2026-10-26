import AppKit
import SwiftUI

@MainActor
final class MenuBarPopoverPresenter: NSObject, NSPopoverDelegate {
    private let store: PowerLensStore
    private let openDashboard: () -> Void
    private let openSettings: () -> Void
    private let quitApplication: () -> Void
    private let onVisibilityChange: () -> Void
    private let popover = NSPopover()
    private let popoverController = NSHostingController(rootView: AnyView(EmptyView()))
    private let popoverSizingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let visibility = PopoverVisibility()
    private var currentMaxContentHeight: CGFloat?
    /// The SwiftUI content exists only while the popover is open, so a closed
    /// popover does no work on refreshes or timer ticks.
    private var isContentMounted = false

    var isShown: Bool {
        popover.isShown
    }

    init(
        store: PowerLensStore,
        openDashboard: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        quitApplication: @escaping () -> Void,
        onVisibilityChange: @escaping () -> Void
    ) {
        self.store = store
        self.openDashboard = openDashboard
        self.openSettings = openSettings
        self.quitApplication = quitApplication
        self.onVisibilityChange = onVisibilityChange
        super.init()

        configurePopover()
    }

    func toggle(relativeTo button: NSStatusBarButton?, snapshot: TelemetrySnapshot?) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        guard let button else {
            return
        }

        mountContent()
        updateLayout(using: snapshot)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func refreshLocalizedViews(snapshot: TelemetrySnapshot?) {
        guard isContentMounted else {
            return
        }
        mountContent()
        if popover.isShown {
            updateLayout(using: snapshot)
        }
    }

    func updateLayoutIfShown(using snapshot: TelemetrySnapshot?) {
        guard popover.isShown else {
            return
        }

        updateLayout(using: snapshot)
    }

    func popoverDidShow(_ notification: Notification) {
        visibility.isShown = true
        onVisibilityChange()
    }

    func popoverDidClose(_ notification: Notification) {
        visibility.isShown = false
        unmountContent()
        onVisibilityChange()
    }

    private func configurePopover() {
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popoverController.sizingOptions = [.preferredContentSize]
        popoverSizingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverController
    }

    private func mountContent() {
        popoverController.rootView = makeRootView(maxContentHeight: currentMaxContentHeight, visibility: visibility)
        popoverSizingController.rootView = makeRootView()
        isContentMounted = true
    }

    private func unmountContent() {
        popoverController.rootView = AnyView(EmptyView())
        popoverSizingController.rootView = AnyView(EmptyView())
        isContentMounted = false
    }

    /// Pass `visibility` only for the on-screen copy, so the off-screen sizing
    /// copy never animates.
    private func makeRootView(maxContentHeight: CGFloat? = nil, visibility: PopoverVisibility? = nil) -> AnyView {
        AnyView(
            PopoverVisibilityReader(visibility: visibility ?? PopoverVisibility()) {
                MenuBarRootView(
                    store: store,
                    openDashboard: openDashboard,
                    openSettings: openSettings,
                    quitApplication: quitApplication,
                    maxContentHeight: maxContentHeight
                )
            }
            .environment(\.locale, L10n.locale)
        )
    }

    private func updateLayout(using snapshot: TelemetrySnapshot?) {
        guard snapshot != nil else {
            if currentMaxContentHeight != nil {
                currentMaxContentHeight = nil
                popoverController.rootView = makeRootView(visibility: visibility)
            }
            currentMaxContentHeight = nil
            popover.contentSize = NSSize(
                width: MenuBarRootView.loadingSize.width,
                height: MenuBarRootView.loadingSize.height
            )
            return
        }

        popoverSizingController.view.invalidateIntrinsicContentSize()
        popoverSizingController.view.layoutSubtreeIfNeeded()

        let unrestrictedSize = popoverSizingController.view.fittingSize
        let availableHeight = maximumPopoverHeight()
        let desiredMaxContentHeight = unrestrictedSize.height > availableHeight ? availableHeight : nil

        if currentMaxContentHeight != desiredMaxContentHeight {
            currentMaxContentHeight = desiredMaxContentHeight
            popoverController.rootView = makeRootView(maxContentHeight: currentMaxContentHeight, visibility: visibility)
        }

        popoverController.view.invalidateIntrinsicContentSize()
        popoverController.view.layoutSubtreeIfNeeded()

        let visibleSize = popoverController.view.fittingSize
        popover.contentSize = NSSize(
            width: max(visibleSize.width, MenuBarRootView.contentWidth),
            height: currentMaxContentHeight.map { min(visibleSize.height, $0) } ?? visibleSize.height
        )
    }

    private func maximumPopoverHeight() -> CGFloat {
        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 800
        return max(360, visibleHeight - 80)
    }
}

/// Whether the popover is on screen. Motion inside it, like the light moving
/// along the power flow, runs only while someone can see it.
@MainActor
final class PopoverVisibility: ObservableObject {
    @Published var isShown = false
}

private struct PopoverVisibilityReader<Content: View>: View {
    @ObservedObject var visibility: PopoverVisibility
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.flowLightIsActive, visibility.isShown)
    }
}

extension EnvironmentValues {
    /// True only inside a popover that is on screen.
    @Entry var flowLightIsActive = false
}
