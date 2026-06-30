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

enum NotificationPreference {
    static let storageKey = "diagnosticsNotificationsEnabled"
    static let defaultValue = false

    static var enabled: Bool {
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

enum UpdateChannelPreference: String, CaseIterable, Identifiable {
    case stable
    case alpha

    static let storageKey = "updateChannel"
    static let defaultValue = Self.stable.rawValue
    static let stableFeedInfoKey = "SUFeedURL"
    static let alphaFeedInfoKey = "SUAlphaFeedURL"
    static let fallbackStableFeedURL = "https://progresshans.github.io/powerlens/appcast.xml"
    static let fallbackAlphaFeedURL = "https://progresshans.github.io/powerlens/appcast-alpha.xml"

    var id: String { rawValue }

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let channel = Self(rawValue: rawValue) else {
            return .stable
        }

        return channel
    }

    var title: String {
        switch self {
        case .stable:
            L10n.text("updates.channel.stable")
        case .alpha:
            L10n.text("updates.channel.alpha")
        }
    }

    var detail: String {
        switch self {
        case .stable:
            L10n.text("updates.channel.stable.detail")
        case .alpha:
            L10n.text("updates.channel.alpha.detail")
        }
    }

    static var currentFeedURLString: String? {
        feedURLString(for: current)
    }

    static func feedURLString(for channel: Self, bundle: Bundle = .main) -> String? {
        resolvedFeedURLString(
            for: channel,
            stableFeedURLString: bundle.object(forInfoDictionaryKey: stableFeedInfoKey) as? String,
            alphaFeedURLString: bundle.object(forInfoDictionaryKey: alphaFeedInfoKey) as? String
        )
    }

    static func resolvedFeedURLString(
        for channel: Self,
        stableFeedURLString: String?,
        alphaFeedURLString: String?
    ) -> String? {
        let stableFeed = normalizedFeedURLString(stableFeedURLString) ?? fallbackStableFeedURL

        switch channel {
        case .stable:
            return stableFeed
        case .alpha:
            return normalizedFeedURLString(alphaFeedURLString)
                ?? Self.alphaFeedURLString(derivedFromStableFeedURLString: stableFeed)
                ?? fallbackAlphaFeedURL
        }
    }

    private static func normalizedFeedURLString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func alphaFeedURLString(derivedFromStableFeedURLString stableFeedURLString: String) -> String? {
        guard var components = URLComponents(string: stableFeedURLString),
              !components.path.isEmpty else {
            return nil
        }

        let directory = (components.path as NSString).deletingLastPathComponent
        components.path = directory == "/" || directory.isEmpty
            ? "/appcast-alpha.xml"
            : "\(directory)/appcast-alpha.xml"
        return components.string
    }
}
