import Foundation
import Testing
@testable import PowerLens

@Suite(.serialized)
struct AppPreferencesTests {
    @Test
    func dockIconPreferenceDefaultsToHidden() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: DockIconPreference.storageKey)
        defer { restore(previousValue, forKey: DockIconPreference.storageKey, in: defaults) }

        defaults.removeObject(forKey: DockIconPreference.storageKey)

        #expect(DockIconPreference.current == false)
    }

    @Test
    func dockIconPreferenceReadsStoredValue() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: DockIconPreference.storageKey)
        defer { restore(previousValue, forKey: DockIconPreference.storageKey, in: defaults) }

        defaults.set(true, forKey: DockIconPreference.storageKey)

        #expect(DockIconPreference.current == true)
    }

    @Test
    func menuBarDisplayStyleDefaultsToPowerLens() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: MenuBarDisplayStylePreference.storageKey)
        defer { restore(previousValue, forKey: MenuBarDisplayStylePreference.storageKey, in: defaults) }

        defaults.removeObject(forKey: MenuBarDisplayStylePreference.storageKey)

        #expect(MenuBarDisplayStylePreference.current == .powerLens)
    }

    @Test
    func menuBarDisplayStyleReadsStoredValue() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: MenuBarDisplayStylePreference.storageKey)
        defer { restore(previousValue, forKey: MenuBarDisplayStylePreference.storageKey, in: defaults) }

        defaults.set(MenuBarDisplayStylePreference.nativeBattery.rawValue, forKey: MenuBarDisplayStylePreference.storageKey)

        #expect(MenuBarDisplayStylePreference.current == .nativeBattery)
    }

    @Test
    func updateChannelDefaultsToStable() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: UpdateChannelPreference.storageKey)
        defer { restore(previousValue, forKey: UpdateChannelPreference.storageKey, in: defaults) }

        defaults.removeObject(forKey: UpdateChannelPreference.storageKey)

        #expect(UpdateChannelPreference.current == .stable)
    }

    @Test
    func updateChannelReadsStoredValue() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: UpdateChannelPreference.storageKey)
        defer { restore(previousValue, forKey: UpdateChannelPreference.storageKey, in: defaults) }

        defaults.set(UpdateChannelPreference.alpha.rawValue, forKey: UpdateChannelPreference.storageKey)

        #expect(UpdateChannelPreference.current == .alpha)
    }

    @Test
    func updateChannelStableFeedUsesConfiguredStableURL() {
        let feed = UpdateChannelPreference.resolvedFeedURLString(
            for: .stable,
            stableFeedURLString: " https://example.com/powerlens/appcast.xml ",
            alphaFeedURLString: nil
        )

        #expect(feed == "https://example.com/powerlens/appcast.xml")
    }

    @Test
    func updateChannelAlphaFeedUsesConfiguredAlphaURL() {
        let feed = UpdateChannelPreference.resolvedFeedURLString(
            for: .alpha,
            stableFeedURLString: "https://example.com/powerlens/appcast.xml",
            alphaFeedURLString: " https://example.com/powerlens/appcast-alpha.xml "
        )

        #expect(feed == "https://example.com/powerlens/appcast-alpha.xml")
    }

    @Test
    func updateChannelAlphaFeedDerivesFromConfiguredStableURL() {
        let feed = UpdateChannelPreference.resolvedFeedURLString(
            for: .alpha,
            stableFeedURLString: "http://127.0.0.1:18080/updates/appcast.xml",
            alphaFeedURLString: nil
        )

        #expect(feed == "http://127.0.0.1:18080/updates/appcast-alpha.xml")
    }

    @Test
    func updateChannelFallsBackToStableProductionFeed() {
        let feed = UpdateChannelPreference.resolvedFeedURLString(
            for: .stable,
            stableFeedURLString: nil,
            alphaFeedURLString: nil
        )

        #expect(feed == UpdateChannelPreference.fallbackStableFeedURL)
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
