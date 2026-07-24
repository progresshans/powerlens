import Foundation

extension TelemetrySnapshot {
    var statusHeadline: String {
        statusHeadline(resolvedState: nil)
    }

    func statusHeadline(resolvedState: ResolvedPowerState?) -> String {
        if !externalConnected {
            return L10n.text("status.runningOnBattery")
        }

        if resolvedState?.powerDeliveryState == .sustainedShortfall {
            return L10n.text("status.adapterBatteryAssist")
        }

        let managedState: ManagedChargingState?
        if let resolvedState {
            managedState = resolvedState.managedChargingState
        } else {
            managedState = managedChargingState
        }
        if let managedHeadline = managedChargingHeadline(for: managedState) {
            return managedHeadline
        }

        let resolvedExternalPowerState = resolvedState?.externalPowerState
            ?? externalPowerState
        switch resolvedExternalPowerState {
        case .onBattery:
            return L10n.text("status.runningOnBattery")
        case .charging:
            return L10n.text("status.chargingFromExternalPower")
        case .holding:
            return L10n.text("status.holdingCurrentLevel")
        case .connected:
            break
        }

        if let deficit = estimatedPowerDeficitW, deficit > 5 {
            return L10n.text("status.adapterBatteryAssist")
        }

        return L10n.text("status.externalPowerConnected")
    }

    var statusSubheadline: String {
        statusSubheadline(resolvedState: nil)
    }

    func statusSubheadline(resolvedState: ResolvedPowerState?) -> String {
        if !externalConnected {
            return L10n.text("status.subheadline.batteryOnly")
        }

        if let resolvedState,
           resolvedState.powerDeliveryState == .sustainedShortfall {
            return stablePowerDeliverySubheadline(
                confirmedShortfall: resolvedState.confirmedShortfall
            )
        }

        let managedState: ManagedChargingState?
        if let resolvedState {
            managedState = resolvedState.managedChargingState
        } else {
            managedState = managedChargingState
        }
        if resolvedState?.powerDeliveryState == .transientBatteryAssist {
            switch managedState {
            case .holdingAtLimit:
                return L10n.text(
                    "status.subheadline.manualLimit.transientAssist"
                )
            case .optimizedHold:
                return L10n.text(
                    "status.subheadline.optimizedCharging.transientAssist"
                )
            case .chargingToLimit, .reducingToLimit, .limitConfigured,
                 .optimizedCharging, .optimizedActive, nil:
                break
            }
        }

        if let managedSubheadline = managedChargingSubheadline(
            for: managedState
        ) {
            return managedSubheadline
        }

        let resolvedExternalPowerState = resolvedState?.externalPowerState
            ?? externalPowerState
        if resolvedExternalPowerState == .holding {
            return L10n.text("status.subheadline.holdingCurrentLevel")
        }

        return powerDeliverySubheadline
    }

    private var powerDeliverySubheadline: String {
        switch chargerAdequacy {
        case .insufficient:
            if let deficit = estimatedPowerDeficitW {
                return L10n.tr(
                    "status.subheadline.deficit",
                    Formatters.power(deficit)
                )
            }
            return L10n.text("status.subheadline.powerLimited")
        case .constrained:
            if let adapterInputPowerW, let systemLoadW {
                return L10n.tr(
                    "status.subheadline.inputVsLoad",
                    Formatters.power(adapterInputPowerW),
                    Formatters.power(systemLoadW)
                )
            }
            return L10n.text("status.subheadline.tightHeadroom")
        case .ample:
            if let headroom = ratedHeadroomW {
                return L10n.tr(
                    "status.subheadline.ratedHeadroom",
                    Formatters.power(headroom)
                )
            }
            return L10n.text("status.subheadline.currentChargerHealthy")
        case .adequate:
            return L10n.text("status.subheadline.currentChargerSufficient")
        case .disconnected:
            return L10n.text("status.subheadline.batteryOnly")
        case .unknown:
            return L10n.text("status.subheadline.qualityUnknown")
        }
    }

    private func stablePowerDeliverySubheadline(
        confirmedShortfall: ConfirmedPowerDeliveryShortfall?
    ) -> String {
        guard let confirmedShortfall else {
            return powerDeliverySubheadline
        }

        if confirmedShortfall.isSlowCharger {
            return L10n.tr(
                "status.subheadline.deficit",
                Formatters.power(confirmedShortfall.deficitW)
            )
        }
        if confirmedShortfall.isNegotiatedLow {
            return L10n.tr(
                "status.subheadline.inputVsLoad",
                Formatters.power(
                    confirmedShortfall.adapterInputPowerW
                ),
                Formatters.power(
                    confirmedShortfall.systemLoadW
                )
            )
        }
        return L10n.text("status.subheadline.powerLimited")
    }

    var managedChargingHeadline: String? {
        managedChargingHeadline(for: managedChargingState)
    }

    func managedChargingHeadline(
        for managedChargingState: ManagedChargingState?
    ) -> String? {
        guard let managedChargingState else {
            return nil
        }

        switch managedChargingState {
        case let .chargingToLimit(targetPercent):
            return L10n.tr(
                "status.manualLimit.charging",
                Formatters.percent(Double(targetPercent))
            )
        case let .reducingToLimit(targetPercent):
            return L10n.tr(
                "status.manualLimit.reducing",
                Formatters.percent(Double(targetPercent))
            )
        case let .holdingAtLimit(targetPercent):
            return L10n.tr(
                "status.manualLimit.holding",
                Formatters.percent(Double(targetPercent))
            )
        case .optimizedCharging:
            return L10n.text("status.optimizedCharging.active")
        case .optimizedHold:
            return L10n.text("status.optimizedCharging.holding")
        case .limitConfigured, .optimizedActive:
            return nil
        }
    }

    var managedChargingSubheadline: String? {
        managedChargingSubheadline(for: managedChargingState)
    }

    func managedChargingSubheadline(
        for managedChargingState: ManagedChargingState?
    ) -> String? {
        guard let managedChargingState else {
            return nil
        }

        switch managedChargingState {
        case .chargingToLimit:
            return L10n.text("status.subheadline.manualLimit.charging")
        case .reducingToLimit:
            return L10n.text("status.subheadline.manualLimit.reducing")
        case .holdingAtLimit:
            return L10n.text("status.subheadline.manualLimit.holding")
        case .optimizedCharging:
            return L10n.text("status.subheadline.optimizedCharging.active")
        case .optimizedHold:
            return L10n.text("status.subheadline.optimizedCharging.holding")
        case .limitConfigured, .optimizedActive:
            return nil
        }
    }

    var managedChargingDiagnosticTitle: String? {
        managedChargingDiagnosticTitle(for: managedChargingState)
    }

    func managedChargingDiagnosticTitle(
        for managedChargingState: ManagedChargingState?
    ) -> String? {
        guard let managedChargingState else {
            return nil
        }

        switch managedChargingState {
        case let .limitConfigured(targetPercent):
            return L10n.tr(
                "status.manualLimit.active",
                Formatters.percent(Double(targetPercent))
            )
        case .optimizedActive:
            return L10n.text("status.optimizedCharging.active")
        case .chargingToLimit, .reducingToLimit, .holdingAtLimit,
             .optimizedCharging, .optimizedHold:
            return managedChargingHeadline(for: managedChargingState)
        }
    }

    var managedChargingDiagnosticMessage: String? {
        managedChargingDiagnosticMessage(for: managedChargingState)
    }

    func managedChargingDiagnosticMessage(
        for managedChargingState: ManagedChargingState?
    ) -> String? {
        guard let managedChargingState else {
            return nil
        }

        switch managedChargingState {
        case .limitConfigured:
            return L10n.text("status.subheadline.manualLimit.active")
        case .optimizedActive:
            return L10n.text(
                "status.subheadline.optimizedCharging.activeFlowUnknown"
            )
        case .chargingToLimit, .reducingToLimit, .holdingAtLimit,
             .optimizedCharging, .optimizedHold:
            return managedChargingSubheadline(for: managedChargingState)
        }
    }

    var primaryDisplayedPowerW: Double? {
        if let systemLoadW {
            return systemLoadW
        }

        if let adapterInputPowerW {
            return adapterInputPowerW
        }

        if let batteryPowerW {
            return abs(batteryPowerW)
        }

        return nil
    }

    var menuBarTitle: String {
        let battery = batteryLevel.map(Formatters.percent) ?? "--"

        if let primaryDisplayedPowerW {
            return "\(battery) · \(Formatters.power(primaryDisplayedPowerW))"
        }

        return battery
    }

    var menuBarSymbolName: String {
        if externalPowerState == .connected,
           chargerAdequacy == .insufficient,
           !shouldSuppressPowerDeliveryWarnings {
            return "exclamationmark.triangle.fill"
        }
        return externalPowerState.menuBarSymbolName
    }

    func menuBarSymbolName(
        using diagnostics: [DiagnosticItem],
        externalPowerState: ExternalPowerState? = nil
    ) -> String {
        let resolvedState = externalPowerState ?? self.externalPowerState

        if resolvedState == .connected,
           diagnostics.contains(where: {
               Self.powerDiagnosticTitles.contains($0.title)
           }) {
            return "exclamationmark.triangle.fill"
        }

        return resolvedState.menuBarSymbolName
    }
}
