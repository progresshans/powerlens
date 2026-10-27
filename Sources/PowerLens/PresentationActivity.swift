import AppKit

/// Work demand is separate from an individual window's show/focus events.
/// Settings needs live readings, but does not consume process-energy samples.
struct PresentationActivity: Equatable {
    var popover = false
    var dashboard = false
    var settings = false
    var dashboardShowsEnergyApps = true

    var needsLiveReadings: Bool { popover || dashboard || settings }
    var needsEnergyApps: Bool { popover || (dashboard && dashboardShowsEnergyApps) }
}

enum WindowContentVisibility {
    @MainActor
    static func isVisible(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
}
