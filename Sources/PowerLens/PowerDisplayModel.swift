import Foundation

extension TelemetrySnapshot {
    var statusHeadline: String {
        switch externalPowerState {
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
        if externalPowerState == .holding {
            return L10n.text("status.subheadline.holdingCurrentLevel")
        }

        switch chargerAdequacy {
        case .insufficient:
            if let deficit = estimatedPowerDeficitW {
                return L10n.tr("status.subheadline.deficit", Formatters.power(deficit))
            }
            return L10n.text("status.subheadline.powerLimited")
        case .constrained:
            if let adapterInputPowerW, let systemLoadW {
                return L10n.tr("status.subheadline.inputVsLoad", Formatters.power(adapterInputPowerW), Formatters.power(systemLoadW))
            }
            return L10n.text("status.subheadline.tightHeadroom")
        case .ample:
            if let headroom = ratedHeadroomW {
                return L10n.tr("status.subheadline.ratedHeadroom", Formatters.power(headroom))
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
        if externalPowerState == .connected, chargerAdequacy == .insufficient {
            return "exclamationmark.triangle.fill"
        }
        return externalPowerState.menuBarSymbolName
    }

    func menuBarSymbolName(using diagnostics: [DiagnosticItem], externalPowerState: ExternalPowerState? = nil) -> String {
        let resolvedState = externalPowerState ?? self.externalPowerState

        if resolvedState == .connected,
           diagnostics.contains(where: { Self.powerDiagnosticTitles.contains($0.title) }) {
            return "exclamationmark.triangle.fill"
        }

        return resolvedState.menuBarSymbolName
    }
}
