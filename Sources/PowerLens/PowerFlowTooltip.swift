import Foundation

enum PowerFlowTooltip {
    static func text(
        snapshot: TelemetrySnapshot,
        readings: PowerFlowReadings? = nil
    ) -> String {
        let readings = readings ?? PowerFlowReadings(snapshot: snapshot)
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 3

        var lines = [
            L10n.tr(
                "ui.flow.tooltip.displayedSystem",
                readings.systemPower?.formatted ?? L10n.text("common.none")
            ),
            anchorDescription(readings),
            calculation(readings),
        ]

        if let inputNote = inputNote(snapshot: snapshot, readings: readings) {
            lines.append(inputNote)
        }
        if let adjustment = adjustmentText(snapshot: snapshot, readings: readings) {
            lines.append(adjustment)
        }
        if let adjustedBattery = adjustedBatteryText(readings) {
            lines.append(adjustedBattery)
        }
        if let direction = directionNote(snapshot: snapshot, readings: readings, formatter: formatter) {
            lines.append(direction)
        }
        if let batteryCalculation = batteryCalculation(
            snapshot: snapshot,
            readings: readings,
            formatter: formatter
        ) {
            lines.append(batteryCalculation)
        }

        lines += [
            L10n.tr("ui.flow.tooltip.rawInput", rawPower(snapshot.adapterInputPowerW, formatter: formatter)),
            L10n.tr("ui.flow.tooltip.rawBattery", rawBatteryPower(snapshot, formatter: formatter)),
            L10n.tr("ui.flow.tooltip.rawSystem", rawPower(snapshot.systemLoadW, formatter: formatter)),
        ]

        if let observedBalance = observedBalance(snapshot: snapshot, readings: readings, formatter: formatter) {
            lines.append(observedBalance)
        }
        if let differenceW = readings.discrepancyW {
            lines.append(L10n.tr(
                "ui.flow.tooltip.observedBalanceDifference",
                rawPower(differenceW, formatter: formatter)
            ))
        }
        if let reason = readings.fallbackReason {
            lines.append(reasonText(reason))
        }
        return lines.joined(separator: "\n")
    }

    static func menuBar(
        snapshot: TelemetrySnapshot?,
        statusHeadline: String?
    ) -> String {
        let headline = statusHeadline ?? "PowerLens"
        guard let snapshot else { return headline }
        return "\(headline)\n\n\(text(snapshot: snapshot))"
    }

    private static func calculation(_ readings: PowerFlowReadings) -> String {
        guard readings.hasBalancedFlow, let system = readings.systemPower else {
            return L10n.text("ui.flow.tooltip.noCalculation")
        }
        switch readings.state {
        case .charging:
            if let input = readings.inputPower, let battery = readings.batteryPower {
                return L10n.tr(
                    "ui.flow.tooltip.displayCharging",
                    input.formatted,
                    system.formatted,
                    battery.formatted
                )
            }
        case .underpowered:
            if let input = readings.inputPower, let battery = readings.batteryPower {
                return L10n.tr(
                    "ui.flow.tooltip.displayAssist",
                    input.formatted,
                    battery.formatted,
                    system.formatted
                )
            }
        case .holding, .directPower:
            if let input = readings.inputPower {
                return L10n.tr("ui.flow.tooltip.displayInput", input.formatted, system.formatted)
            }
        case .discharging:
            if let battery = readings.batteryPower {
                return L10n.tr("ui.flow.tooltip.displayBattery", battery.formatted, system.formatted)
            }
        case .unknown:
            break
        }
        return L10n.text("ui.flow.tooltip.noCalculation")
    }

    /// Explains why a displayed input that is calculated from the system
    /// anchor can differ from the original input reading.
    private static func inputNote(
        snapshot: TelemetrySnapshot,
        readings: PowerFlowReadings
    ) -> String? {
        guard readings.hasBalancedFlow,
              readings.systemPowerSource == .measured,
              readings.inputPower != nil else {
            return nil
        }
        let calculation = L10n.text("ui.flow.tooltip.inputFromAnchor")
        guard snapshot.powerMeasurementSetSource == .smc else {
            return calculation
        }
        return "\(calculation)\n\(L10n.text("ui.flow.tooltip.smcTiming"))"
    }

    private static func adjustmentText(
        snapshot: TelemetrySnapshot,
        readings: PowerFlowReadings
    ) -> String? {
        switch readings.inputAdjustment {
        case .raisedToZero:
            return L10n.text("ui.flow.tooltip.adjust.inputFloor")
        case .limitedToAdapterRating:
            return L10n.tr(
                "ui.flow.tooltip.adjust.inputRating",
                snapshot.adapterMaxPowerW.map(Formatters.power) ?? L10n.text("common.none")
            )
        case nil:
            return nil
        }
    }

    private static func adjustedBatteryText(_ readings: PowerFlowReadings) -> String? {
        guard readings.hasBalancedFlow,
              readings.inputAdjustment != nil,
              let battery = readings.batteryPower,
              battery.isApproximate else {
            return nil
        }
        switch readings.state {
        case .charging:
            return L10n.tr("ui.flow.tooltip.adjustedBatteryCharge", battery.formatted)
        case .underpowered:
            return L10n.tr("ui.flow.tooltip.adjustedBatteryAssist", battery.formatted)
        case .holding, .directPower, .discharging, .unknown:
            return nil
        }
    }

    private static func directionNote(
        snapshot: TelemetrySnapshot,
        readings: PowerFlowReadings,
        formatter: NumberFormatter
    ) -> String? {
        guard readings.fallbackReason != .conflictingDirection,
              let smcDirection = readings.smcBatteryDirection,
              smcDirection != snapshot.batteryFlowEvidence else {
            return nil
        }
        return L10n.tr(
            "ui.flow.tooltip.smcDirection",
            rawMeasurement(snapshot.batteryCurrentA, unit: "A", formatter: formatter)
        )
    }

    private static func anchorDescription(_ readings: PowerFlowReadings) -> String {
        switch readings.systemPowerSource {
        case .measured:
            L10n.text("ui.flow.tooltip.anchor.measured")
        case .powerBalance:
            L10n.text("ui.flow.tooltip.anchor.powerBalance")
        case .unavailable:
            L10n.text("ui.flow.tooltip.anchor.unavailable")
        }
    }

    private static func observedBalance(
        snapshot: TelemetrySnapshot,
        readings: PowerFlowReadings,
        formatter: NumberFormatter
    ) -> String? {
        guard readings.fallbackReason != .conflictingDirection,
              let candidateW = readings.candidateSystemPowerW, candidateW.isFinite else {
            return nil
        }
        let expression: String
        switch readings.observedState {
        case .charging, .underpowered:
            expression = L10n.tr(
                readings.observedState == .charging
                    ? "ui.flow.tooltip.expression.charging"
                    : "ui.flow.tooltip.expression.assist",
                rawPower(snapshot.adapterInputPowerW, formatter: formatter),
                rawPower(readings.observedBatteryPowerW, formatter: formatter)
            )
        case .holding, .directPower:
            expression = L10n.tr(
                "ui.flow.tooltip.expression.input",
                rawPower(snapshot.adapterInputPowerW, formatter: formatter)
            )
        case .discharging:
            expression = L10n.tr(
                "ui.flow.tooltip.expression.battery",
                rawPower(readings.observedBatteryPowerW ?? candidateW, formatter: formatter)
            )
        case .unknown:
            return nil
        }
        return L10n.tr(
            "ui.flow.tooltip.observedBalance",
            expression,
            rawPower(candidateW, formatter: formatter)
        )
    }

    private static func reasonText(_ reason: PowerFlowFallbackReason) -> String {
        let key: String
        switch reason {
        case .invalidBalance:
            key = "ui.flow.tooltip.reason.invalidBalance"
        case .conflictingDirection:
            key = "ui.flow.tooltip.reason.conflictingDirection"
        case .missingMeasurement:
            key = "ui.flow.tooltip.reason.missingMeasurement"
        }
        return L10n.text(key)
    }

    private static func batteryCalculation(
        snapshot: TelemetrySnapshot,
        readings: PowerFlowReadings,
        formatter: NumberFormatter
    ) -> String? {
        guard readings.fallbackReason != .conflictingDirection else {
            return nil
        }
        let directionKey: String
        switch readings.observedBatteryDirection {
        case .charging:
            directionKey = "format.batteryPower.charging"
        case .discharging:
            directionKey = "format.batteryPower.discharging"
        case .calm, .conflicted, .unavailable:
            return nil
        }
        let result = L10n.tr(
            directionKey,
            rawPower(readings.observedBatteryPowerW, formatter: formatter)
        )

        switch readings.batteryValueSource {
        case .currentAndVoltage:
            return L10n.tr(
                "ui.flow.tooltip.batteryCurrentVoltageCalculation",
                rawMeasurement(snapshot.batteryCurrentA, unit: "A", formatter: formatter),
                rawMeasurement(snapshot.batteryVoltageV, unit: "V", formatter: formatter),
                result
            )
        case .inputLoadDifference:
            let input = L10n.tr(
                "ui.flow.tooltip.expression.input",
                rawPower(snapshot.adapterInputPowerW, formatter: formatter)
            )
            let system = "\(L10n.text("ui.metric.systemLoad")) \(rawPower(snapshot.systemLoadW, formatter: formatter))"
            switch readings.observedState {
            case .charging:
                return L10n.tr("ui.flow.tooltip.batteryResidualCalculation", input, system, result)
            case .underpowered:
                return L10n.tr("ui.flow.tooltip.batteryResidualCalculation", system, input, result)
            default:
                return nil
            }
        case .measured, .unavailable:
            return nil
        }
    }

    private static func rawPower(_ value: Double?, formatter: NumberFormatter) -> String {
        rawMeasurement(value, unit: "W", formatter: formatter)
    }

    private static func rawMeasurement(
        _ value: Double?,
        unit: String,
        formatter: NumberFormatter
    ) -> String {
        guard let value, value.isFinite,
              let number = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) else {
            return L10n.text("common.none")
        }
        return "\(number)\(unit)"
    }

    private static func rawBatteryPower(
        _ snapshot: TelemetrySnapshot,
        formatter: NumberFormatter
    ) -> String {
        guard let value = snapshot.batteryPowerW, value.isFinite else {
            return L10n.text("common.none")
        }
        let magnitude = rawPower(abs(value), formatter: formatter)
        let power = snapshot.batteryPowerIsDerived
            ? L10n.tr("ui.flow.tooltip.currentVoltageBattery", magnitude)
            : magnitude
        if value > 0 {
            return L10n.tr("format.batteryPower.discharging", power)
        }
        if value < 0 {
            return L10n.tr("format.batteryPower.charging", power)
        }
        return power
    }
}
