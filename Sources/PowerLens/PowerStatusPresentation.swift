import Foundation

/// The single hue a piece of status copy carries. Energy endpoints use
/// `LensPalette` hues instead, so status and flow colors never compete.
enum StatusTone: Equatable, Sendable {
    case charging
    case charger
    case caution
    case warning
    case neutral
}

/// Answer-first status copy for the popover and the dashboard: a short capsule,
/// one sentence that says what is happening, and one with the numbers.
struct PowerStatusPresentation: Equatable, Sendable {
    let tone: StatusTone
    let capsuleTitle: String
    let capsuleSymbol: String
    let title: String
    let subtitle: String

    init(tone: StatusTone, capsuleTitle: String, capsuleSymbol: String, title: String, subtitle: String) {
        self.tone = tone
        self.capsuleTitle = capsuleTitle
        self.capsuleSymbol = capsuleSymbol
        self.title = title
        self.subtitle = subtitle
    }

    init(snapshot: TelemetrySnapshot, resolvedState: ResolvedPowerState?, readings suppliedReadings: PowerFlowReadings? = nil) {
        let readings = suppliedReadings ?? PowerFlowReadings(snapshot: snapshot)

        if !snapshot.externalConnected {
            tone = .neutral
            capsuleTitle = L10n.text("capsule.onBattery")
            capsuleSymbol = BatterySymbol.name(level: snapshot.batteryLevel, isCharging: false)
            if let minutes = snapshot.timeToEmptyMinutes, minutes > 0 {
                title = L10n.tr("status.title.timeRemaining", Formatters.minutes(minutes))
            } else {
                title = snapshot.statusHeadline(resolvedState: resolvedState)
            }
            if let system = readings.systemPower {
                subtitle = L10n.tr("status.subtitle.macUsing", system.formatted)
            } else {
                subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
            }
            return
        }

        if resolvedState?.powerDeliveryState == .sustainedShortfall {
            tone = .warning
            capsuleTitle = L10n.text("capsule.shortfall")
            capsuleSymbol = "exclamationmark.triangle.fill"
            title = L10n.text("status.title.shortfall")
            if let deficit = resolvedState?.confirmedShortfall?.deficitW ?? snapshot.estimatedPowerDeficitW {
                subtitle = L10n.tr("status.subtitle.shortfall", Formatters.power(deficit))
            } else {
                subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
            }
            return
        }

        let externalState = resolvedState?.externalPowerState ?? snapshot.externalPowerState
        let managedState = resolvedState != nil
            ? resolvedState?.managedChargingState
            : snapshot.managedChargingState

        if let managedHeadline = snapshot.managedChargingHeadline(for: managedState) {
            (tone, capsuleTitle, capsuleSymbol) = Self.capsule(for: externalState)
            title = managedHeadline
            subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
            return
        }

        if resolvedState?.powerDeliveryState == .transientBatteryAssist {
            tone = .caution
            capsuleTitle = L10n.text("capsule.assist")
            capsuleSymbol = "bolt.fill"
            title = L10n.text("status.title.assist")
            if let battery = readings.batteryPower, readings.state == .underpowered {
                subtitle = L10n.tr("status.subtitle.assist", battery.formatted)
            } else {
                subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
            }
            return
        }

        (tone, capsuleTitle, capsuleSymbol) = Self.capsule(for: externalState)
        switch externalState {
        case .charging:
            title = L10n.text("status.title.charging")
            if readings.state == .charging,
               let system = readings.systemPower,
               let battery = readings.batteryPower {
                subtitle = L10n.tr("status.subtitle.chargingSplit", system.formatted, battery.formatted)
            } else {
                subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
            }
        case .holding:
            title = L10n.text("status.title.holding")
            if let level = snapshot.batteryLevel {
                subtitle = L10n.tr("status.subtitle.holding", Formatters.percent(level))
            } else {
                subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
            }
        case .connected, .onBattery:
            title = snapshot.statusHeadline(resolvedState: resolvedState)
            subtitle = snapshot.statusSubheadline(resolvedState: resolvedState)
        }
    }

    private static func capsule(for state: ExternalPowerState) -> (StatusTone, String, String) {
        switch state {
        case .charging:
            (.charging, L10n.text("capsule.charging"), "bolt.fill")
        case .holding:
            (.charger, L10n.text("capsule.charger"), "powerplug.fill")
        case .connected:
            (.charger, L10n.text("capsule.connected"), "powerplug.fill")
        case .onBattery:
            (.neutral, L10n.text("capsule.onBattery"), "battery.75percent")
        }
    }
}

/// One card that explains the current situation and what to try. Only shown
/// when there is something worth reading; a healthy state needs no card.
struct PowerNotice: Equatable, Sendable {
    let tone: StatusTone
    let symbol: String
    let title: String
    let message: String

    static func current(
        snapshot: TelemetrySnapshot,
        resolvedState: ResolvedPowerState?,
        diagnostics: [DiagnosticItem]
    ) -> PowerNotice? {
        if snapshot.externalConnected, resolvedState?.powerDeliveryState == .sustainedShortfall {
            let message: String
            if let rated = snapshot.adapterMaxPowerW,
               let system = PowerFlowReadings(snapshot: snapshot).systemPower {
                message = L10n.tr("notice.shortfall.message", system.formatted, Formatters.ratedPower(rated))
            } else {
                message = L10n.text("notice.shortfall.messageGeneric")
            }
            return PowerNotice(
                tone: .warning,
                symbol: "exclamationmark.triangle.fill",
                title: L10n.text("notice.shortfall.title"),
                message: message
            )
        }

        if snapshot.externalConnected, resolvedState?.powerDeliveryState == .transientBatteryAssist {
            return PowerNotice(
                tone: .caution,
                symbol: "exclamationmark.triangle.fill",
                title: L10n.text("notice.assist.title"),
                message: L10n.text("notice.assist.message")
            )
        }

        let hidden: Set<DiagnosticKind> = [.healthy, .lowPowerMode, .powerDeliveryShortfall]
        guard let item = diagnostics.first(where: { !hidden.contains($0.kind) }) else {
            return nil
        }

        switch item.severity {
        case .info:
            return PowerNotice(tone: .charger, symbol: "info.circle.fill", title: item.title, message: item.message)
        case .caution:
            return PowerNotice(tone: .caution, symbol: "exclamationmark.triangle.fill", title: item.title, message: item.message)
        case .warning:
            return PowerNotice(tone: .warning, symbol: "exclamationmark.triangle.fill", title: item.title, message: item.message)
        }
    }
}

/// A number with its interpretation underneath ("좋아요", "적당해요").
struct MetricTilePresentation: Equatable, Sendable {
    let label: String
    let symbol: String
    let value: String
    let caption: String
    let captionTone: StatusTone

    static func battery(snapshot: TelemetrySnapshot, resolvedState: ResolvedPowerState?) -> Self {
        let externalState = resolvedState?.externalPowerState ?? snapshot.externalPowerState
        let delivery = resolvedState?.powerDeliveryState
        let caption: String
        let tone: StatusTone

        if !snapshot.externalConnected {
            if let minutes = snapshot.timeToEmptyMinutes, minutes > 0 {
                caption = L10n.tr("tile.battery.remaining", Formatters.minutes(minutes))
            } else {
                caption = L10n.text("tile.battery.onBattery")
            }
            tone = .neutral
        } else if delivery == .sustainedShortfall {
            caption = L10n.text("tile.battery.dropping")
            tone = .warning
        } else if delivery == .transientBatteryAssist {
            caption = L10n.text("tile.battery.dropping")
            tone = .caution
        } else {
            switch externalState {
            case .charging:
                if let minutes = snapshot.timeToFullMinutes, minutes > 0 {
                    caption = L10n.tr("tile.battery.untilFull", Formatters.minutes(minutes))
                } else {
                    caption = L10n.text("tile.battery.charging")
                }
                tone = .charging
            case .holding:
                caption = L10n.text("tile.battery.steady")
                tone = .charger
            case .connected, .onBattery:
                caption = L10n.text("tile.battery.connected")
                tone = .neutral
            }
        }

        return Self(
            label: L10n.text("ui.metric.battery"),
            symbol: BatterySymbol.name(level: snapshot.batteryLevel, isCharging: externalState == .charging),
            value: snapshot.batteryLevel.map(Formatters.percent) ?? L10n.text("common.none"),
            caption: caption,
            captionTone: tone
        )
    }

    static func health(snapshot: TelemetrySnapshot) -> Self {
        let tone: StatusTone = switch snapshot.batteryHealthAssessment {
        case .serviceRecommended: .warning
        case .aged, .checkBattery: .caution
        case .normal, .unknown: .neutral
        }

        return Self(
            label: L10n.text("ui.metric.health"),
            symbol: "heart.fill",
            value: snapshot.chargeHealthPercent.map(Formatters.percent) ?? L10n.text("common.none"),
            caption: snapshot.batteryHealthSummary,
            captionTone: tone
        )
    }

    static func temperature(snapshot: TelemetrySnapshot) -> Self {
        let tone: StatusTone
        switch snapshot.thermalState.lowercased() {
        case "fair":
            tone = .caution
        case "serious", "critical":
            tone = .warning
        default:
            tone = .neutral
        }

        return Self(
            label: L10n.text("ui.metric.batteryTemp"),
            symbol: "thermometer.medium",
            value: snapshot.batteryTemperatureC.map(Formatters.wholeTemperature) ?? L10n.text("common.none"),
            caption: L10n.localizedThermalState(snapshot.thermalState),
            captionTone: tone
        )
    }
}

/// The headline for a battery health assessment, shared by the Battery page
/// and the Now page's insights so both say the same thing.
struct BatteryHealthPresentation: Equatable {
    let title: String
    let capsuleTitle: String
    let tone: StatusTone
    let symbol: String

    init(_ assessment: BatteryHealthAssessment) {
        let alert = "exclamationmark.triangle.fill"
        switch assessment {
        case .normal:
            (title, capsuleTitle, tone, symbol) = (L10n.text("battery.title.good"), L10n.text("battery.capsule.good"), .charging, "checkmark")
        case .aged:
            (title, capsuleTitle, tone, symbol) = (L10n.text("battery.title.aged"), L10n.text("battery.capsule.aged"), .caution, alert)
        case .checkBattery:
            (title, capsuleTitle, tone, symbol) = (L10n.text("battery.title.check"), L10n.text("battery.capsule.check"), .caution, alert)
        case .serviceRecommended:
            (title, capsuleTitle, tone, symbol) = (L10n.text("battery.title.service"), L10n.text("battery.capsule.service"), .warning, alert)
        case .unknown:
            (title, capsuleTitle, tone, symbol) = (L10n.text("battery.title.unknown"), L10n.text("battery.capsule.unknown"), .neutral, "questionmark")
        }
    }
}

enum BatterySymbol {
    static func name(level: Double?, isCharging: Bool) -> String {
        if isCharging {
            return "battery.100percent.bolt"
        }
        // A generic battery, not an empty one, when the level is unknown.
        guard let level else {
            return "minus.plus.batteryblock"
        }

        switch level {
        case ..<13:
            return "battery.0percent"
        case ..<38:
            return "battery.25percent"
        case ..<63:
            return "battery.50percent"
        case ..<88:
            return "battery.75percent"
        default:
            return "battery.100percent"
        }
    }
}

extension PowerStatusPresentation {
    /// Shown until a sample matches the observed power source, while the
    /// previous values are kept dimmed even if reconciliation reads fail.
    static var sourceTransition: PowerStatusPresentation {
        PowerStatusPresentation(
            tone: .neutral,
            capsuleTitle: L10n.text("capsule.remeasuring"),
            capsuleSymbol: "arrow.triangle.2.circlepath",
            title: L10n.text("status.title.sourceTransition"),
            subtitle: L10n.text("status.subtitle.sourceTransition")
        )
    }
}
