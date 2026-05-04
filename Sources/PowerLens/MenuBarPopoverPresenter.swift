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
    private var currentMaxContentHeight: CGFloat?

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

        updateLayout(using: snapshot)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func refreshLocalizedViews(snapshot: TelemetrySnapshot?) {
        popoverController.rootView = makeRootView(maxContentHeight: currentMaxContentHeight)
        popoverSizingController.rootView = makeRootView()
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
        onVisibilityChange()
    }

    func popoverDidClose(_ notification: Notification) {
        onVisibilityChange()
    }

    private func configurePopover() {
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popoverController.sizingOptions = [.preferredContentSize]
        popoverSizingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverController
        popoverController.rootView = makeRootView(maxContentHeight: currentMaxContentHeight)
        popoverSizingController.rootView = makeRootView()
        updateLayout(using: store.latest)
    }

    private func makeRootView(maxContentHeight: CGFloat? = nil) -> AnyView {
        AnyView(
            MenuBarRootView(
                store: store,
                openDashboard: openDashboard,
                openSettings: openSettings,
                quitApplication: quitApplication,
                maxContentHeight: maxContentHeight
            )
            .environment(\.locale, L10n.locale)
        )
    }

    private func updateLayout(using snapshot: TelemetrySnapshot?) {
        guard snapshot != nil else {
            if currentMaxContentHeight != nil {
                currentMaxContentHeight = nil
                popoverController.rootView = makeRootView()
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
            popoverController.rootView = makeRootView(maxContentHeight: currentMaxContentHeight)
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
