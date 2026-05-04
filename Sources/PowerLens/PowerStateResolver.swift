import Foundation

extension TelemetrySnapshot {
    var estimatedPowerDeficitW: Double? {
        guard externalConnected, let systemLoadW, let adapterInputPowerW else { return nil }
        return systemLoadW - adapterInputPowerW
    }

    var batteryChargeInflowW: Double {
        max(-(batteryPowerW ?? 0), 0)
    }

    var isBatteryChargingForDisplay: Bool {
        isCharging || batteryChargeInflowW > PowerStateThresholds.displayChargeInflowW
    }

    var ratedHeadroomW: Double? {
        guard externalConnected, let adapterMaxPowerW, let systemLoadW else { return nil }
        return adapterMaxPowerW - systemLoadW
    }

    var isHoldingBatteryLevelCandidate: Bool {
        guard externalConnected else { return false }

        guard !isBatteryChargingForDisplay,
              timeToFullMinutes == nil,
              timeToEmptyMinutes == nil else {
            return false
        }

        let calmSignals = [
            batteryPowerW.map { abs($0) <= PowerStateThresholds.holdBatteryPowerToleranceW },
            batteryCurrentA.map { abs($0) <= PowerStateThresholds.holdBatteryCurrentToleranceA },
        ].compactMap { $0 }

        if !calmSignals.isEmpty {
            return calmSignals.allSatisfy { $0 }
        }

        return isCharged || (batteryLevel ?? 0) >= 99
    }

    var externalPowerState: ExternalPowerState {
        if !externalConnected {
            return .onBattery
        }

        if isBatteryChargingForDisplay {
            return .charging
        }

        if isHoldingBatteryLevelCandidate {
            return .holding
        }

        return .connected
    }

    var chargerAdequacy: ChargerAdequacy {
        guard externalConnected else { return .disconnected }

        if let deficit = estimatedPowerDeficitW {
            if deficit > 5 {
                return .insufficient
            }
            if deficit > 1.5 {
                return .constrained
            }
        }

        if let headroom = ratedHeadroomW {
            if headroom >= 30 {
                return .ample
            }
            if headroom >= 10 {
                return .adequate
            }
            if headroom >= 0 {
                return .constrained
            }
            return .insufficient
        }

        return .unknown
    }

    var hasSlowChargerCondition: Bool {
        guard externalConnected,
              let deficit = estimatedPowerDeficitW else { return false }
        return deficit > 5
    }

    var hasNegotiatedLowCondition: Bool {
        guard externalConnected,
              let rated = adapterMaxPowerW,
              let input = adapterInputPowerW,
              let load = systemLoadW,
              rated > 0 else { return false }

        let batteryIsSupportingLoad = batteryPowerW.map { $0 > 2 } ?? false
        let batteryCurrentIsDischarging = batteryCurrentA.map { $0 < -0.15 } ?? false
        let chargerIsActivelyCharging = isCharging
        let loadMeaningfullyExceedsInput = estimatedPowerDeficitW.map { $0 > 2.5 } ?? false

        return input < rated * 0.55
            && load > input * 0.85
            && (
                batteryIsSupportingLoad
                    || batteryCurrentIsDischarging
                    || chargerIsActivelyCharging
                    || loadMeaningfullyExceedsInput
            )
    }

    var shouldSuppressPowerDeliveryWarnings: Bool {
        isHoldingBatteryLevelCandidate
    }

    static func stableExternalPowerState(
        for recentSnapshots: [TelemetrySnapshot],
        requiredConsecutiveSamples: Int = 3
    ) -> ExternalPowerState {
        guard let current = recentSnapshots.last else {
            return .connected
        }

        if !current.externalConnected {
            return .onBattery
        }

        if current.isBatteryChargingForDisplay {
            return .charging
        }

        let stableWindow = Array(recentSnapshots.suffix(requiredConsecutiveSamples))
        let levels = stableWindow.compactMap(\.batteryLevel)
        let levelDrift = levels.isEmpty ? 0 : (levels.max() ?? 0) - (levels.min() ?? 0)

        if stableWindow.count >= requiredConsecutiveSamples,
           stableWindow.allSatisfy(\.isHoldingBatteryLevelCandidate),
           levelDrift <= PowerStateThresholds.holdBatteryLevelDriftPercent {
            return .holding
        }

        return .connected
    }
}

private enum PowerStateThresholds {
    static let displayChargeInflowW = 0.35
    static let holdBatteryPowerToleranceW = 4.0
    static let holdBatteryCurrentToleranceA = 0.2
    static let holdBatteryLevelDriftPercent = 1.0
}
