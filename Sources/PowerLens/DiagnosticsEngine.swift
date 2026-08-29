import Foundation

extension TelemetrySnapshot {
    var diagnostics: [DiagnosticItem] {
        diagnostics(resolvedState: nil)
    }

    func diagnostics(resolvedState: ResolvedPowerState?) -> [DiagnosticItem] {
        var results: [DiagnosticItem] = []
        let shouldShowPowerWarnings: Bool
        if let resolvedState {
            shouldShowPowerWarnings =
                resolvedState.powerDeliveryState == .sustainedShortfall
        } else {
            shouldShowPowerWarnings = !shouldSuppressPowerDeliveryWarnings
        }

        if shouldShowPowerWarnings {
            if let confirmedShortfall = resolvedState?.confirmedShortfall {
                if let warning = powerDeliveryShortfallDiagnostic(
                    for: confirmedShortfall
                ) {
                    results.append(warning)
                }
            } else {
                if let warning = powerDeliveryShortfallDiagnostic {
                    results.append(warning)
                }
            }
        }

        if let temperature = batteryTemperatureC,
           temperature >= 36 {
            results.append(
                DiagnosticItem(
                    kind: .temperatureHigh,
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
                    kind: .batteryHealthWear,
                    severity: .caution,
                    title: L10n.text("diag.healthWear.title"),
                    message: L10n.tr("diag.healthWear.message", Formatters.percent(health))
                )
            )
        }

        if lowPowerModeEnabled {
            results.append(
                DiagnosticItem(
                    kind: .lowPowerMode,
                    severity: .info,
                    title: L10n.text("diag.lowPowerMode.title"),
                    message: L10n.text("diag.lowPowerMode.message")
                )
            )
        }

        let managedState: ManagedChargingState?
        if let resolvedState {
            managedState = resolvedState.managedChargingState
        } else {
            managedState = managedChargingState
        }
        if let managedChargingDiagnostic = managedChargingDiagnostic(
            for: managedState
        ) {
            results.append(managedChargingDiagnostic)
        }

        if results.isEmpty {
            results.append(healthyDiagnostic)
        }

        return Self.sortedBySeverity(results)
    }

    private static func sortedBySeverity(_ diagnostics: [DiagnosticItem]) -> [DiagnosticItem] {
        diagnostics.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = severityRank(lhs.element.severity)
                let rhsRank = severityRank(rhs.element.severity)

                if lhsRank == rhsRank {
                    return lhs.offset < rhs.offset
                }

                return lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func severityRank(_ severity: DiagnosticSeverity) -> Int {
        switch severity {
        case .warning:
            0
        case .caution:
            1
        case .info:
            2
        }
    }

    private var managedChargingDiagnostic: DiagnosticItem? {
        managedChargingDiagnostic(for: managedChargingState)
    }

    private func managedChargingDiagnostic(
        for managedChargingState: ManagedChargingState?
    ) -> DiagnosticItem? {
        guard let title = managedChargingDiagnosticTitle(
                  for: managedChargingState
              ),
              let message = managedChargingDiagnosticMessage(
                  for: managedChargingState
              ) else {
            return nil
        }

        return DiagnosticItem(
            kind: .managedCharging,
            severity: .info,
            title: title,
            message: message
        )
    }

    private var powerDeliveryShortfallDiagnostic: DiagnosticItem? {
        guard hasMaterialBatteryAssist,
              hasCorroboratedPowerDeliveryShortfall,
              let input = adapterInputPowerW,
              let load = systemLoadW else {
            return nil
        }

        return DiagnosticItem(
            kind: .powerDeliveryShortfall,
            severity: .warning,
            title: L10n.text("diag.powerDeliveryShortfall.title"),
            message: L10n.tr(
                "diag.powerDeliveryShortfall.message",
                Formatters.power(input),
                Formatters.power(load)
            )
        )
    }

    private func powerDeliveryShortfallDiagnostic(
        for evidence: ConfirmedPowerDeliveryShortfall
    ) -> DiagnosticItem? {
        return DiagnosticItem(
            kind: .powerDeliveryShortfall,
            severity: .warning,
            title: L10n.text("diag.powerDeliveryShortfall.title"),
            message: L10n.tr(
                "diag.powerDeliveryShortfall.message",
                Formatters.power(evidence.adapterInputPowerW),
                Formatters.power(evidence.systemLoadW)
            )
        )
    }

    private var healthyDiagnostic: DiagnosticItem {
        DiagnosticItem(
            kind: .healthy,
            severity: .info,
            title: L10n.text("diag.healthy.title"),
            message: L10n.text("diag.healthy.message")
        )
    }

    static var powerDiagnosticTitles: Set<String> {
        [
            L10n.text("diag.powerDeliveryShortfall.title"),
        ]
    }
}
