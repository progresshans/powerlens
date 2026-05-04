import Testing
@testable import PowerLens

@MainActor
struct MenuBarStatusItemRendererTests {
    @Test
    func assetSelectionRoundsBatteryLevelToNearestFivePercent() {
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 78, badge: .none) == "default/battery.80percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 76, badge: .none) == "default/battery.75percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: -10, badge: .none) == "default/battery.0percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 102, badge: .none) == "default/battery.100percent")
    }

    @Test
    func assetSelectionUsesBadgeSpecificFoldersAndNames() {
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 80, badge: .none) == "default/battery.80percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 80, badge: .chargingBolt) == "bolt/battery.80percent.bolt")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 80, badge: .pluggedHolding) == "powerplug/battery.80percent.powerplug")
    }

    @Test
    func badgeResolutionUsesStableExternalPowerState() {
        #expect(MenuBarStatusItemRenderer.Badge.resolved(for: .onBattery) == .none)
        #expect(MenuBarStatusItemRenderer.Badge.resolved(for: .connected) == .pluggedHolding)
        #expect(MenuBarStatusItemRenderer.Badge.resolved(for: .charging) == .chargingBolt)
        #expect(MenuBarStatusItemRenderer.Badge.resolved(for: .holding) == .pluggedHolding)
    }

    @Test
    func allFivePercentBatteryAssetsAreLoadable() {
        for level in stride(from: 0, through: 100, by: 5) {
            #expect(MenuBarStatusItemRenderer.canLoadAsset(level: Double(level), badge: .none))
            #expect(MenuBarStatusItemRenderer.canLoadAsset(level: Double(level), badge: .chargingBolt))
            #expect(MenuBarStatusItemRenderer.canLoadAsset(level: Double(level), badge: .pluggedHolding))
        }
    }
}
