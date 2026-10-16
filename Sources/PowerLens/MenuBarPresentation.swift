import Foundation

@MainActor
struct MenuBarPresentation: Equatable {
    let snapshot: TelemetrySnapshot?
    let symbolName: String
    let batteryBadge: MenuBarStatusItemRenderer.Badge
    let statusHeadline: String?

    static let waiting = MenuBarPresentation(
        snapshot: nil,
        symbolName: "bolt.fill",
        batteryBadge: .none,
        statusHeadline: nil
    )
}
