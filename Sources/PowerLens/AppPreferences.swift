import Foundation

enum DockIconPreference {
    static let storageKey = "showDockIcon"
    static let defaultValue = false

    static var current: Bool {
        guard UserDefaults.standard.object(forKey: storageKey) != nil else {
            return defaultValue
        }

        return UserDefaults.standard.bool(forKey: storageKey)
    }
}

enum MenuBarDisplayStylePreference: String, CaseIterable, Identifiable {
    case powerLens
    case powerText
    case nativeBattery
    case nativeBatteryOnly

    static let storageKey = "menuBarDisplayStyle"
    static let defaultValue = Self.powerLens.rawValue

    var id: String { rawValue }

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let style = Self(rawValue: rawValue) else {
            return .powerLens
        }

        return style
    }

    var title: String {
        switch self {
        case .powerLens:
            L10n.text("menuBarStyle.powerLens.title")
        case .powerText:
            L10n.text("menuBarStyle.powerText.title")
        case .nativeBattery:
            L10n.text("menuBarStyle.nativeBattery.title")
        case .nativeBatteryOnly:
            L10n.text("menuBarStyle.nativeBatteryOnly.title")
        }
    }

    var detail: String {
        switch self {
        case .powerLens:
            L10n.text("menuBarStyle.powerLens.detail")
        case .powerText:
            L10n.text("menuBarStyle.powerText.detail")
        case .nativeBattery:
            L10n.text("menuBarStyle.nativeBattery.detail")
        case .nativeBatteryOnly:
            L10n.text("menuBarStyle.nativeBatteryOnly.detail")
        }
    }
}
