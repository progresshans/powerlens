import Foundation

enum Formatters {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func power(_ value: Double) -> String {
        number(value, fractionDigits: 1, suffix: "W")
    }

    static func batteryPowerFlow(_ value: Double?) -> String {
        guard let value else {
            return L10n.text("common.none")
        }

        if abs(value) < 0.05 {
            return power(0)
        }

        if value < 0 {
            return L10n.tr("format.batteryPower.charging", power(abs(value)))
        }

        return L10n.tr("format.batteryPower.discharging", power(value))
    }

    static func voltage(_ value: Double) -> String {
        number(value, fractionDigits: 2, suffix: "V")
    }

    static func current(_ value: Double) -> String {
        number(value, fractionDigits: 2, suffix: "A")
    }

    static func batteryCurrentFlow(_ value: Double?) -> String {
        guard let value else {
            return L10n.text("common.none")
        }

        if abs(value) < 0.005 {
            return current(0)
        }

        if value < 0 {
            return L10n.tr("format.batteryCurrent.discharging", current(abs(value)))
        }

        return L10n.tr("format.batteryCurrent.charging", current(value))
    }

    static func temperature(_ value: Double) -> String {
        number(value, fractionDigits: 1, suffix: "°C")
    }

    static func minutes(_ value: Int?) -> String {
        guard let value, value > 0 else {
            return L10n.text("common.none")
        }

        let hours = value / 60
        let minutes = value % 60

        if hours == 0 {
            return L10n.tr("format.minutesOnly", minutes)
        }

        return L10n.tr("format.hoursMinutes", hours, minutes)
    }

    static func lastUpdated(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .standard)
                .locale(L10n.locale)
        )
    }

    static func relativeAge(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))

        if seconds < 5 {
            return L10n.text("format.justNow")
        }

        if seconds < 60 {
            return L10n.tr("format.secondsAgo", seconds)
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return L10n.tr("format.minutesAgo", minutes)
        }

        let hours = minutes / 60
        return L10n.tr("format.hoursAgo", hours)
    }

    private static func number(_ value: Double, fractionDigits: Int, suffix: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(number)\(suffix)"
    }
}
