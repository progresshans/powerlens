import Foundation

@MainActor
struct MenuBarPresentation: Equatable {
    let snapshot: TelemetrySnapshot?
    let symbolName: String
    let batteryBadge: MenuBarStatusItemRenderer.Badge
    let statusHeadline: String?
    /// Matches macOS: the battery fill turns yellow in Low Power Mode.
    var lowPowerMode = false
    /// A confirmed power shortfall. Shown on the badge only, never the fill,
    /// so it cannot be mistaken for Low Power Mode.
    var powerWarning = false

    static let waiting = MenuBarPresentation(
        snapshot: nil,
        symbolName: "bolt.fill",
        batteryBadge: .none,
        statusHeadline: nil
    )
}
