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
                if let warning = slowChargerDiagnostic(
                    for: confirmedShortfall
                ) {
                    results.append(warning)
                }
                if let warning = negotiatedLowDiagnostic(
                    for: confirmedShortfall
                ) {
                    results.append(warning)
                }
            } else {
                if let warning = slowChargerDiagnostic {
                    results.append(warning)
                }
                if let warning = negotiatedLowDiagnostic {
                    results.append(warning)
                }
            }
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
            severity: .info,
            title: title,
            message: message
        )
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

    private func slowChargerDiagnostic(
        for evidence: ConfirmedPowerDeliveryShortfall
    ) -> DiagnosticItem? {
        guard evidence.isSlowCharger else {
            return nil
        }

        return DiagnosticItem(
            severity: .warning,
            title: L10n.text("diag.slowCharger.title"),
            message: L10n.tr(
                "diag.slowCharger.message",
                Formatters.power(evidence.deficitW)
            )
        )
    }

    private func negotiatedLowDiagnostic(
        for evidence: ConfirmedPowerDeliveryShortfall
    ) -> DiagnosticItem? {
        guard evidence.isNegotiatedLow,
              let adapterMaxPowerW = evidence.adapterMaxPowerW else {
            return nil
        }

        return DiagnosticItem(
            severity: .caution,
            title: L10n.text("diag.negotiatedLow.title"),
            message: L10n.tr(
                "diag.negotiatedLow.message",
                Formatters.power(adapterMaxPowerW),
                Formatters.power(evidence.adapterInputPowerW)
            )
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
