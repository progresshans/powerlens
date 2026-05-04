import Foundation

extension TelemetrySnapshot {
    var diagnostics: [DiagnosticItem] {
        var results: [DiagnosticItem] = []

        if !shouldSuppressPowerDeliveryWarnings,
           let warning = slowChargerDiagnostic {
            results.append(warning)
        }

        if !shouldSuppressPowerDeliveryWarnings,
           let warning = negotiatedLowDiagnostic {
            results.append(warning)
        }

        if let temperature = batteryTemperatureC,
           temperature >= 36 {
            results.append(
                DiagnosticItem(
                    severity: .caution,
                    title: L10n.text("diag.temperatureHigh.title"),
                    message: L10n.tr("diag.temperatureHigh.message", Formatters.temperature(temperature))
                )
            )
        }

        if let health = chargeHealthPercent,
           health < 85 {
            results.append(
                DiagnosticItem(
                    severity: .caution,
                    title: L10n.text("diag.healthWear.title"),
                    message: L10n.tr("diag.healthWear.message", Formatters.percent(health))
                )
            )
        }

        if lowPowerModeEnabled {
            results.append(
                DiagnosticItem(
                    severity: .info,
                    title: L10n.text("diag.lowPowerMode.title"),
                    message: L10n.text("diag.lowPowerMode.message")
                )
            )
        }

        if results.isEmpty {
            results.append(healthyDiagnostic)
        }

        return results
    }

    static func stableDiagnostics(for recentSnapshots: [TelemetrySnapshot], requiredConsecutiveSamples: Int = 3) -> [DiagnosticItem] {
        guard let current = recentSnapshots.last else {
            return []
        }

        var results = current.diagnostics.filter { !Self.powerDiagnosticTitles.contains($0.title) && $0.title != L10n.text("diag.healthy.title") }
        let stableWindow = Array(recentSnapshots.suffix(requiredConsecutiveSamples))
        let stableHoldDetected = stableExternalPowerState(
            for: recentSnapshots,
            requiredConsecutiveSamples: requiredConsecutiveSamples
        ) == .holding

        if stableWindow.count >= requiredConsecutiveSamples, !stableHoldDetected {
            if stableWindow.allSatisfy({ $0.slowChargerDiagnostic != nil && !$0.shouldSuppressPowerDeliveryWarnings }),
               let warning = current.slowChargerDiagnostic {
                results.append(warning)
            }

            if stableWindow.allSatisfy({ $0.negotiatedLowDiagnostic != nil && !$0.shouldSuppressPowerDeliveryWarnings }),
               let warning = current.negotiatedLowDiagnostic {
                results.append(warning)
            }
        }

        if results.isEmpty {
            results.append(current.healthyDiagnostic)
        }

        return results
    }

    private var slowChargerDiagnostic: DiagnosticItem? {
        guard hasSlowChargerCondition,
              let deficit = estimatedPowerDeficitW else {
            return nil
        }

        return DiagnosticItem(
            severity: .warning,
            title: L10n.text("diag.slowCharger.title"),
            message: L10n.tr("diag.slowCharger.message", Formatters.power(deficit))
        )
    }

    private var negotiatedLowDiagnostic: DiagnosticItem? {
        guard hasNegotiatedLowCondition,
              let rated = adapterMaxPowerW,
              let input = adapterInputPowerW else {
            return nil
        }

        return DiagnosticItem(
            severity: .caution,
            title: L10n.text("diag.negotiatedLow.title"),
            message: L10n.tr("diag.negotiatedLow.message", Formatters.power(rated), Formatters.power(input))
        )
    }

    private var healthyDiagnostic: DiagnosticItem {
        DiagnosticItem(
            severity: .info,
            title: L10n.text("diag.healthy.title"),
            message: L10n.text("diag.healthy.message")
        )
    }

    static var powerDiagnosticTitles: Set<String> {
        [
            L10n.text("diag.slowCharger.title"),
            L10n.text("diag.negotiatedLow.title"),
        ]
    }
}
