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
    private let detailsState = PopoverDetailsState()
    private var currentMaxContentHeight: CGFloat?
    /// The SwiftUI content exists only while the popover is open, so a closed
    /// popover does no work on refreshes or timer ticks.
    private var isContentMounted = false
    private var resize: PopoverResize?
    private var resizeLink: CADisplayLink?
    private var pendingResizeStart: CFTimeInterval?
    private var lastContentHeight: CGFloat = 0
    private var mountedLocaleIdentifier: String?

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

    /// Called on every defaults change; rebuilds only when the language
    /// changed, so writing an unrelated setting never interrupts the popover.
    func refreshLocalizedViews(snapshot: TelemetrySnapshot?) {
        guard isContentMounted, L10n.locale.identifier != mountedLocaleIdentifier else {
            return
        }
        mountContent()
        if popover.isShown {
            updateLayout(using: snapshot)
        }
    }

    func updateLayoutIfShown(using snapshot: TelemetrySnapshot?) {
        // A running resize catches up with the latest layout when it ends.
        guard popover.isShown, resize == nil else {
            return
        }

        updateLayout(using: snapshot)
    }

    /// Runs `change` with the details animation, then animates the popover to
    /// the content height it produces. NSPopover's own resize is nearly
    /// instant, so the popover instead reaches the new height frame by frame
    /// on the same curve. A size set this way reaches the screen as SwiftUI
    /// draws each frame of the layout animation.
    private func animateResize(_ change: () -> Void) {
        cancelResize()
        pendingResizeStart = popover.isShown ? CACurrentMediaTime() : nil
        withAnimation(PopoverResizeAnimation.animation, change)
    }

    /// The on-screen content reports its full height whenever it changes.
    private func contentHeightDidChange(_ height: CGFloat) {
        lastContentHeight = height
        let start = pendingResizeStart
        pendingResizeStart = nil
        guard popover.isShown, store.latest != nil, resize == nil else {
            return
        }
        let decision = PopoverHeightDecision(
            contentHeight: height,
            maximumHeight: maximumPopoverHeight(),
            isScrolling: currentMaxContentHeight != nil
        )
        if case .resize = decision, let start, CACurrentMediaTime() - start < 0.25 {
            beginResize(to: height, start: start)
        } else {
            apply(decision)
            detailsState.save()
        }
    }

    /// Sizes the popover at once. Starting or stopping scrolling is never
    /// animated.
    private func apply(_ decision: PopoverHeightDecision) {
        switch decision {
        case let .resize(height):
            setContentHeight(height)
        case .relayout:
            updateLayout(using: store.latest)
        case .keepScrolling:
            break
        }
    }

    private func beginResize(to height: CGFloat, start: CFTimeInterval) {
        resize = PopoverResize(from: popover.contentSize.height, to: height, start: start)
        let link = popoverController.view.displayLink(target: self, selector: #selector(stepResize(_:)))
        link.add(to: .main, forMode: .common)
        resizeLink = link
    }

    @objc private func stepResize(_ link: CADisplayLink) {
        guard let resize else {
            cancelResize()
            return
        }
        let progress = min(1, max(0, (link.targetTimestamp - resize.start) / PopoverResizeAnimation.duration))
        setContentHeight(resize.from + (resize.to - resize.from) * PopoverResizeAnimation.curve.value(at: progress))
        guard progress >= 1 else {
            return
        }
        cancelResize()
        // Catch up with content that changed during the animation. It may
        // no longer fit on screen, so it goes through the same check.
        if popover.isShown {
            apply(PopoverHeightDecision(
                contentHeight: lastContentHeight,
                maximumHeight: maximumPopoverHeight(),
                isScrolling: currentMaxContentHeight != nil
            ))
        }
        detailsState.save()
    }

    /// Stops a running resize where it is.
    private func cancelResize() {
        resizeLink?.invalidate()
        resizeLink = nil
        resize = nil
    }

    /// Whole points only: AppKit rounds the popover window to whole points,
    /// so a fractional height moves its top edge by a point from one frame
    /// to the next and the popover shakes while it resizes.
    private func setContentHeight(_ height: CGFloat) {
        popover.contentSize = NSSize(width: MenuBarRootView.contentWidth, height: height.rounded(.up))
    }

    func popoverDidShow(_ notification: Notification) {
        visibility.isShown = true
        store.presentationDidBecomeActive()
        onVisibilityChange()
    }

    func popoverDidClose(_ notification: Notification) {
        visibility.isShown = false
        cancelResize()
        pendingResizeStart = nil
        detailsState.save()
        unmountContent()
        onVisibilityChange()
    }

    private func configurePopover() {
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        // Only the presenter sizes the popover, from the height the content
        // reports, so it can animate a size change.
        popoverController.sizingOptions = []
        popoverSizingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverController
    }

    private func mountContent() {
        popoverController.rootView = makeRootView(maxContentHeight: currentMaxContentHeight, visibility: visibility)
        popoverSizingController.rootView = makeRootView()
        isContentMounted = true
        mountedLocaleIdentifier = L10n.locale.identifier
    }

    private func unmountContent() {
        popoverController.rootView = AnyView(EmptyView())
        popoverSizingController.rootView = AnyView(EmptyView())
        isContentMounted = false
    }

    /// Pass `visibility` only for the on-screen copy, so the off-screen sizing
    /// copy never animates or resizes the popover.
    private func makeRootView(maxContentHeight: CGFloat? = nil, visibility: PopoverVisibility? = nil) -> AnyView {
        let isOnScreen = visibility != nil
        return AnyView(
            PopoverVisibilityReader(visibility: visibility ?? PopoverVisibility()) {
                MenuBarRootView(
                    store: store,
                    openDashboard: openDashboard,
                    openSettings: openSettings,
                    quitApplication: quitApplication,
                    maxContentHeight: maxContentHeight,
                    detailsState: detailsState,
                    animateResize: { [weak self] change in
                        guard let self else { return change() }
                        self.animateResize(change)
                    },
                    onContentHeightChange: { [weak self] height in
                        if isOnScreen {
                            self?.contentHeightDidChange(height)
                        }
                    }
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

        setContentHeight(currentMaxContentHeight.map { min(unrestrictedSize.height, $0) } ?? unrestrictedSize.height)
    }

    private func maximumPopoverHeight() -> CGFloat {
        let screen = popover.contentViewController?.view.window?.screen ?? NSScreen.main
        let visibleHeight = screen?.visibleFrame.height ?? 800
        return max(360, visibleHeight - 80)
    }
}

/// Whether the popover shows its details section. Shared by the on-screen
/// and sizing copies, so both lay out the same state, and kept across
/// launches.
@MainActor
final class PopoverDetailsState: ObservableObject {
    static let storageKey = "popover.showsDetails"

    @Published var isExpanded: Bool

    init() {
        isExpanded = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    /// Writing a default makes the app refresh its menu bar item and windows,
    /// so this runs only once motion has stopped.
    func save() {
        guard UserDefaults.standard.bool(forKey: Self.storageKey) != isExpanded else {
            return
        }
        UserDefaults.standard.set(isExpanded, forKey: Self.storageKey)
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

/// How the popover answers a new content height. Content taller than the
/// screen allows scrolls inside a popover held at the maximum height.
enum PopoverHeightDecision: Equatable {
    /// The content fits; size the popover to it.
    case resize(CGFloat)
    /// Scrolling starts or stops, which needs a new layout.
    case relayout
    /// Still too tall; the popover stays at the maximum and scrolls.
    case keepScrolling

    init(contentHeight: CGFloat, maximumHeight: CGFloat, isScrolling: Bool) {
        let needsScrolling = contentHeight > maximumHeight
        if needsScrolling != isScrolling {
            self = .relayout
        } else if needsScrolling {
            self = .keepScrolling
        } else {
            self = .resize(contentHeight)
        }
    }
}

private struct PopoverResize {
    let from: CGFloat
    let to: CGFloat
    let start: CFTimeInterval
}

/// One curve for the popover's height and its SwiftUI content, so the
/// footer moves with the popover's edge.
enum PopoverResizeAnimation {
    static let duration: CFTimeInterval = 0.3
    /// Ease in and out. A slow start also hides a late first frame, which a
    /// curve that moves most at the start shows as a jump.
    static let curve = CubicBezierTiming(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let animation = Animation.timingCurve(
        curve.x1, curve.y1, curve.x2, curve.y2, duration: duration
    )
}

/// A CSS-style cubic Bézier timing function from (0, 0) to (1, 1).
struct CubicBezierTiming: Equatable, Sendable {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    /// Eased progress for linear progress `x` in 0...1.
    func value(at x: Double) -> Double {
        let x = min(max(x, 0), 1)
        var t = x
        for _ in 0..<8 {
            let error = Self.bezier(t, x1, x2) - x
            if abs(error) < 1e-6 {
                return Self.bezier(t, y1, y2)
            }
            let slope = Self.slope(t, x1, x2)
            guard abs(slope) > 1e-6 else { break }
            t -= error / slope
        }
        // Newton's method stalled on a flat stretch; bisect instead.
        var low = 0.0
        var high = 1.0
        t = x
        while high - low > 1e-6 {
            if Self.bezier(t, x1, x2) < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return Self.bezier(t, y1, y2)
    }

    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        ((1 + 3 * p1 - 3 * p2) * t + (3 * p2 - 6 * p1)) * t * t + 3 * p1 * t
    }

    private static func slope(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        3 * (1 + 3 * p1 - 3 * p2) * t * t + 2 * (3 * p2 - 6 * p1) * t + 3 * p1
    }
}
