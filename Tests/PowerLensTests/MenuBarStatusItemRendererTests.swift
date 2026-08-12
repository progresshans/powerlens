import Testing
@testable import PowerLens

@MainActor
struct MenuBarStatusItemRendererTests {
    @Test
    func assetSelectionRoundsBatteryLevelToNearestFivePercent() {
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 78, badge: .none) == "battery.80percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 76, badge: .none) == "battery.75percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: -10, badge: .none) == "battery.0percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 102, badge: .none) == "battery.100percent")
    }

    @Test
    func cacheAndFallbackShareOneCanonicalFivePercentLevel() {
        #expect(MenuBarStatusItemRenderer.canonicalAssetPercent(level: nil) == 0)
        #expect(MenuBarStatusItemRenderer.canonicalAssetPercent(level: 63) == 65)
        #expect(MenuBarStatusItemRenderer.canonicalAssetPercent(level: 65) == 65)
        #expect(MenuBarStatusItemRenderer.canonicalAssetPercent(level: 67) == 65)
        #expect(MenuBarStatusItemRenderer.canonicalAssetPercent(level: 105) == 100)
    }

    @Test
    func everyBadgeComposesOntoTheSameBatteryAsset() {
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 80, badge: .none) == "battery.80percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 80, badge: .chargingBolt) == "battery.80percent")
        #expect(MenuBarStatusItemRenderer.assetIdentifier(level: 80, badge: .pluggedHolding) == "battery.80percent")
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
