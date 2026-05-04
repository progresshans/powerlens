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

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
