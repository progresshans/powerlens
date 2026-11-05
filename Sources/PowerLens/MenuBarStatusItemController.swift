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
        batteryBadge: MenuBarStatusItemRenderer.Badge,
        statusHeadline: String?,
        lowPowerMode: Bool = false,
        powerWarning: Bool = false
    ) {
        guard let button else {
            return
        }

        let style = MenuBarDisplayStylePreference.current
        button.image = menuBarImage(
            for: style,
            snapshot: snapshot,
            symbolName: symbolName,
            batteryBadge: batteryBadge,
            tint: MenuBarStatusItemRenderer.Tint(lowPowerFill: lowPowerMode, warningBadge: powerWarning)
        )
        button.imagePosition = imagePosition(for: style)
        button.attributedTitle = menuBarTitle(for: style, snapshot: snapshot, showsWarningDot: powerWarning)
        let tooltip = PowerFlowTooltip.menuBar(
            snapshot: snapshot,
            statusHeadline: statusHeadline
        )
        button.toolTip = tooltip
        button.setAccessibilityHelp(tooltip)
    }

    @objc
    private func performAction(_ sender: AnyObject?) {
        action(sender)
    }

    private func menuBarImage(
        for style: MenuBarDisplayStylePreference,
        snapshot: TelemetrySnapshot?,
        symbolName: String,
        batteryBadge: MenuBarStatusItemRenderer.Badge,
        tint: MenuBarStatusItemRenderer.Tint
    ) -> NSImage? {
        switch style {
        case .powerLens:
            return powerLensSymbol(named: symbolName, lowPowerMode: tint.lowPowerFill)
        case .powerText:
            return nil
        case .nativeBattery, .nativeBatteryOnly:
            return MenuBarStatusItemRenderer.batteryImage(
                level: snapshot?.batteryLevel,
                badge: batteryBadge,
                tint: tint
            )
        case .percentInside:
            return MenuBarStatusItemRenderer.percentInsideImage(
                level: snapshot?.batteryLevel,
                badge: batteryBadge,
                tint: tint
            )
        }
    }

    /// The Detailed style's symbol turns yellow in Low Power Mode, like the
    /// battery icons and the macOS battery fill.
    private func powerLensSymbol(named symbolName: String, lowPowerMode: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PowerLens")
        guard lowPowerMode,
              let palette = Self.lowPowerPalette(forSymbolNamed: symbolName),
              let tinted = image?.withSymbolConfiguration(.init(paletteColors: palette))
        else {
            image?.isTemplate = true
            return image
        }

        tinted.isTemplate = false
        return tinted
    }

    /// Palette for a menu bar symbol in Low Power Mode, or nil to keep it
    /// as is. Two-layer symbols keep their outline (or pause bars) in the
    /// text color and fill yellow; single-layer glyphs are all fill. The
    /// warning triangle keeps its own look so it is never read as Low Power
    /// Mode.
    static func lowPowerPalette(forSymbolNamed symbolName: String) -> [NSColor]? {
        switch symbolName {
        case "exclamationmark.triangle.fill":
            nil
        case "battery.75", "pause.circle.fill":
            [.textColor, .systemYellow]
        default:
            [.systemYellow]
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
        case .nativeBatteryOnly, .percentInside:
            return .imageOnly
        }
    }

    private func menuBarTitle(
        for style: MenuBarDisplayStylePreference,
        snapshot: TelemetrySnapshot?,
        showsWarningDot: Bool
    ) -> NSAttributedString {
        let title: String
        switch style {
        case .powerLens, .powerText:
            title = snapshot?.menuBarTitle ?? "PowerLens"
        case .nativeBattery:
            title = snapshot?.batteryLevel.map(Formatters.percent) ?? "--"
        case .nativeBatteryOnly, .percentInside:
            title = ""
        }

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: menuBarFontSize(for: style),
            weight: menuBarFontWeight(for: style)
        )
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: font])
        // Text-only readouts have no badge to tint, so a warning gets a dot.
        if showsWarningDot, style == .powerText {
            attributed.append(NSAttributedString(
                string: " \u{25CF}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize * 0.6),
                    .foregroundColor: NSColor.systemRed,
                    .baselineOffset: font.pointSize * 0.12,
                ]
            ))
        }
        return attributed
    }

    private func menuBarFontSize(for style: MenuBarDisplayStylePreference) -> CGFloat {
        let systemSize = NSFont.menuBarFont(ofSize: 0).pointSize

        switch style {
        case .nativeBattery, .nativeBatteryOnly, .percentInside:
            return max(10, systemSize - 2)
        case .powerLens, .powerText:
            return systemSize
        }
    }

    private func menuBarFontWeight(for style: MenuBarDisplayStylePreference) -> NSFont.Weight {
        switch style {
        case .nativeBattery, .nativeBatteryOnly, .percentInside:
            return .regular
        case .powerLens, .powerText:
            return .medium
        }
    }
}
