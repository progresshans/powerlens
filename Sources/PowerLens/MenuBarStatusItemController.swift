import AppKit
import Foundation

@MainActor
final class MenuBarStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let action: (AnyObject?) -> Void

    var button: NSStatusBarButton? {
        statusItem.button
    }

    init(action: @escaping (AnyObject?) -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.action = action
        super.init()

        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(performAction(_:))
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageLeading
    }

    func update(
        snapshot: TelemetrySnapshot?,
        symbolName: String,
        batteryBadge: MenuBarStatusItemRenderer.Badge
    ) {
        guard let button else {
            return
        }

        let style = MenuBarDisplayStylePreference.current
        button.image = menuBarImage(
            for: style,
            snapshot: snapshot,
            symbolName: symbolName,
            batteryBadge: snapshot == nil ? .none : batteryBadge
        )
        button.imagePosition = imagePosition(for: style)
        button.attributedTitle = menuBarTitle(for: style, snapshot: snapshot)
        button.toolTip = snapshot?.statusHeadline ?? "PowerLens"
    }

    @objc
    private func performAction(_ sender: AnyObject?) {
        action(sender)
    }

    private func menuBarImage(
        for style: MenuBarDisplayStylePreference,
        snapshot: TelemetrySnapshot?,
        symbolName: String,
        batteryBadge: MenuBarStatusItemRenderer.Badge
    ) -> NSImage? {
        switch style {
        case .powerLens:
            let symbolName = snapshot == nil ? "bolt.fill" : symbolName
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PowerLens")
            image?.isTemplate = true
            return image
        case .powerText:
            return nil
        case .nativeBattery, .nativeBatteryOnly:
            return MenuBarStatusItemRenderer.batteryImage(
                level: snapshot?.batteryLevel,
                badge: batteryBadge
            )
        }
    }

    private func imagePosition(for style: MenuBarDisplayStylePreference) -> NSControl.ImagePosition {
        switch style {
        case .powerLens:
            return .imageLeading
        case .powerText:
            return .noImage
        case .nativeBattery:
            return .imageTrailing
        case .nativeBatteryOnly:
            return .imageOnly
        }
    }

    private func menuBarTitle(
        for style: MenuBarDisplayStylePreference,
        snapshot: TelemetrySnapshot?
    ) -> NSAttributedString {
        let title: String
        switch style {
        case .powerLens, .powerText:
            title = snapshot?.menuBarTitle ?? "PowerLens"
        case .nativeBattery:
            title = snapshot?.batteryLevel.map(Formatters.percent) ?? "--"
        case .nativeBatteryOnly:
            title = ""
        }

        return NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: menuBarFontSize(for: style),
                    weight: menuBarFontWeight(for: style)
                ),
            ]
        )
    }

    private func menuBarFontSize(for style: MenuBarDisplayStylePreference) -> CGFloat {
        let systemSize = NSFont.menuBarFont(ofSize: 0).pointSize

        switch style {
        case .nativeBattery, .nativeBatteryOnly:
            return max(10, systemSize - 2)
        case .powerLens, .powerText:
            return systemSize
        }
    }

    private func menuBarFontWeight(for style: MenuBarDisplayStylePreference) -> NSFont.Weight {
        switch style {
        case .nativeBattery, .nativeBatteryOnly:
            return .regular
        case .powerLens, .powerText:
            return .medium
        }
    }
}
