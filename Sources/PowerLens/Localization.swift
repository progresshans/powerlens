import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var resolvedLocalizationIdentifier: String {
        switch self {
        case .system:
            Self.systemLocalizationIdentifier()
        case .english, .korean:
            rawValue
        }
    }

    var locale: Locale {
        Locale(identifier: resolvedLocalizationIdentifier)
    }

    var bundle: Bundle {
        if let path = PowerLensResources.bundle.path(forResource: resolvedLocalizationIdentifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }

        return PowerLensResources.bundle
    }

    var displayName: String {
        switch self {
        case .system:
            L10n.text("language.system")
        case .english:
            L10n.text("language.english")
        case .korean:
            L10n.text("language.korean")
        }
    }

    static func systemLocalizationIdentifier(
        preferredLanguages: [String] = Locale.preferredLanguages,
        availableLocalizations: [String] = PowerLensResources.bundle.localizations,
        developmentLocalization: String? = PowerLensResources.bundle.developmentLocalization
    ) -> String {
        let candidates = Bundle.preferredLocalizations(
            from: availableLocalizations.filter { $0 != "Base" },
            forPreferences: preferredLanguages
        )

        if let match = candidates.first {
            return match
        }

        if let developmentLocalization {
            return developmentLocalization
        }

        return "en"
    }
}

enum L10n {
    static var currentLanguage: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: AppLanguage.storageKey),
              let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return language
    }

    static var locale: Locale {
        currentLanguage.locale
    }

    static func text(_ key: String) -> String {
        currentLanguage.bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = text(key)
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func localizedPowerSource(_ kind: PowerSourceKind) -> String {
        switch kind {
        case .ac:
            text("powerSource.ac")
        case .battery:
            text("powerSource.battery")
        case .offline:
            text("powerSource.offline")
        case .unknown:
            text("powerSource.unknown")
        }
    }

    static func localizedThermalState(_ state: String) -> String {
        switch state {
        case "Nominal":
            text("thermal.nominal")
        case "Fair":
            text("thermal.fair")
        case "Serious":
            text("thermal.serious")
        case "Critical":
            text("thermal.critical")
        default:
            text("thermal.unknown")
        }
    }

    static func localizedBatteryHealth(_ health: String?) -> String {
        guard let health else {
            return text("common.unknown")
        }

        return switch health {
        case "Normal":
            text("health.normal")
        case "Aged":
            text("health.aged")
        case "Check Battery":
            text("health.checkBattery")
        case "Service Recommended":
            text("health.serviceRecommended")
        default:
            health
        }
    }
}
