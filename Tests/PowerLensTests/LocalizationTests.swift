import Foundation
import Testing
@testable import PowerLens

struct LocalizationTests {
    @Test
    func managedChargingAndFlowCopyExistsInEnglishAndKorean() {
        let keys = [
            "status.manualLimit.charging",
            "status.manualLimit.chargingBeyond",
            "status.manualLimit.above",
            "status.manualLimit.reducing",
            "status.manualLimit.holding",
            "status.manualLimit.active",
            "status.optimizedCharging.active",
            "status.optimizedCharging.holding",
            "status.subheadline.manualLimit.charging",
            "status.subheadline.manualLimit.chargingBeyond",
            "status.subheadline.manualLimit.above",
            "status.subheadline.manualLimit.reducing",
            "status.subheadline.manualLimit.holding",
            "status.subheadline.manualLimit.active",
            "status.subheadline.optimizedCharging.active",
            "status.subheadline.optimizedCharging.holding",
            "status.subheadline.optimizedCharging.activeFlowUnknown",
            "status.subheadline.manualLimit.transientAssist",
            "status.subheadline.optimizedCharging.transientAssist",
            "diag.manualLimit.chargingBeyond.message",
            "diag.manualLimit.above.message",
            "charger.usage.shortfall",
            "ui.metric.systemLoad",
            "ui.flow.tooltip.displayedSystem",
            "ui.flow.tooltip.noCalculation",
            "ui.flow.tooltip.expression.charging",
            "ui.flow.tooltip.expression.assist",
            "ui.flow.tooltip.expression.input",
            "ui.flow.tooltip.expression.battery",
            "ui.flow.tooltip.rawInput",
            "ui.flow.tooltip.rawBattery",
            "ui.flow.tooltip.rawSystem",
            "ui.flow.tooltip.currentVoltageBattery",
            "ui.flow.tooltip.batteryCurrentVoltageCalculation",
            "ui.flow.tooltip.batteryResidualCalculation",
            "ui.flow.tooltip.reason.invalidBalance",
            "ui.flow.tooltip.reason.conflictingDirection",
            "ui.flow.tooltip.reason.missingMeasurement",
            "ui.flow.tooltip.anchor.measured",
            "ui.flow.tooltip.anchor.powerBalance",
            "ui.flow.tooltip.anchor.unavailable",
            "ui.flow.tooltip.displayCharging",
            "ui.flow.tooltip.displayAssist",
            "ui.flow.tooltip.displayInput",
            "ui.flow.tooltip.displayBattery",
            "ui.flow.tooltip.inputFromAnchor",
            "ui.flow.tooltip.smcTiming",
            "ui.flow.tooltip.adjust.inputFloor",
            "ui.flow.tooltip.adjust.inputRating",
            "ui.flow.tooltip.adjustedBatteryCharge",
            "ui.flow.tooltip.adjustedBatteryAssist",
            "ui.flow.tooltip.smcDirection",
            "ui.flow.tooltip.observedBalance",
            "ui.flow.tooltip.observedBalanceDifference",
            "telemetry.status.waiting",
            "telemetry.status.sourceTransition",
            "telemetry.status.delayed",
            "telemetry.status.unavailable",
            "telemetry.delayed",
            "telemetry.unavailable",
            "telemetry.delayed.detail",
            "settings.pane.data",
            "settings.pane.updates",
            "settings.section.menuBarAndDock",
            "settings.section.system",
            "settings.section.telemetry",
            "settings.section.history",
            "settings.section.telemetry.footer",
            "settings.row.status",
            "history.status.checking",
            "history.status.available",
            "history.status.degraded",
            "history.status.checking.detail",
            "history.status.available.detail",
            "history.status.degraded.detail",
            "history.longTerm.off.detail",
            "history.longTerm.off.confirm.title",
            "history.longTerm.off.confirm.message",
            "history.longTerm.off.confirm.action",
            "common.cancel",
        ]

        for language in [AppLanguage.english, .korean] {
            for key in keys {
                let localized = language.bundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: "Localizable"
                )

                #expect(!localized.isEmpty)
                #expect(localized != key)
            }
        }
    }

    @Test
    func smcTimingCopyDoesNotPromiseAFixedOneSecondDelay() {
        for language in [AppLanguage.english, .korean] {
            let text = language.bundle.localizedString(
                forKey: "ui.flow.tooltip.smcTiming",
                value: nil,
                table: "Localizable"
            )
            for unsupportedTiming in ["one second", "1 second", "1초", "1 초"] {
                #expect(!text.contains(unsupportedTiming))
            }
        }
    }

    @Test
    func chargingBeyondLimitCopyDoesNotClaimAnUnobservableDestination() {
        let keys = [
            "status.manualLimit.chargingBeyond",
            "status.subheadline.manualLimit.chargingBeyond",
            "diag.manualLimit.chargingBeyond.message",
            "diag.manualLimit.above.message",
        ]

        for language in [AppLanguage.english, .korean] {
            for key in keys {
                let localized = language.bundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: "Localizable"
                )

                #expect(!localized.contains("100%"))
            }
        }
    }

    @Test
    func longTermHistoryDiscardConfirmationNamesTheRetainedWindow() {
        for language in [AppLanguage.english, .korean] {
            let format = language.bundle.localizedString(
                forKey: "history.longTerm.off.confirm.message",
                value: nil,
                table: "Localizable"
            )
            let windowTitle = language.bundle.localizedString(
                forKey: "history.window.days90",
                value: nil,
                table: "Localizable"
            )
            let message = String(
                format: format,
                locale: language.locale,
                arguments: [windowTitle]
            )

            #expect(message.contains(windowTitle))
            #expect(!message.contains("%@"))
        }
    }

    @Test
    func batteryHealthSummaryPrefersComputedCapacityWhenRawStatusConflicts() {
        let snapshot = sampleSnapshot(
            fullChargeCapacityMah: 5639,
            batteryHealthText: "Check Battery"
        )

        #expect(snapshot.chargeHealthPercent?.rounded() == 90)
        #expect(snapshot.batteryHealthSummary == L10n.text("health.normal"))
    }

    @Test
    func batteryHealthSummaryKeepsServiceRecommendation() {
        let snapshot = sampleSnapshot(
            fullChargeCapacityMah: 5639,
            batteryHealthText: "Service Recommended"
        )

        #expect(snapshot.batteryHealthSummary == L10n.text("health.serviceRecommended"))
    }

    @Test
    func batteryCurrentFlowUsesDirectionLabels() {
        #expect(
            Formatters.batteryCurrentFlow(-0.82)
                == L10n.tr("format.batteryCurrent.discharging", Formatters.current(0.82))
        )
        #expect(
            Formatters.batteryCurrentFlow(0.82)
                == L10n.tr("format.batteryCurrent.charging", Formatters.current(0.82))
        )
        #expect(Formatters.batteryCurrentFlow(0) == Formatters.current(0))
    }

    @Test
    func systemLanguagePrefersKoreanLocalizationWhenAvailable() {
        let resolved = AppLanguage.systemLocalizationIdentifier(
            preferredLanguages: ["ko-KR", "en-US"],
            availableLocalizations: ["en", "ko"],
            developmentLocalization: "en"
        )

        #expect(resolved == "ko")
    }

    @Test
    func systemLanguageFallsBackToDevelopmentLocalization() {
        let resolved = AppLanguage.systemLocalizationIdentifier(
            preferredLanguages: ["fr-FR"],
            availableLocalizations: ["en", "ko"],
            developmentLocalization: "en"
        )

        #expect(resolved == "en")
    }

    private func sampleSnapshot(
        fullChargeCapacityMah: Int,
        batteryHealthText: String?,
        batteryHealthCondition: String? = nil
    ) -> TelemetrySnapshot {
        TelemetrySnapshot(
            batteryLevel: 70,
            powerSource: .battery,
            isCharging: false,
            isCharged: false,
            externalConnected: false,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            designCapacityMah: 6249,
            fullChargeCapacityMah: fullChargeCapacityMah,
            nominalCapacityMah: 5791,
            cycleCount: 75,
            designCycleCount: 1000,
            batteryHealthText: batteryHealthText,
            batteryHealthCondition: batteryHealthCondition,
            batteryTemperatureC: 30.4,
            batteryVoltageV: 12.25,
            batteryCurrentA: -0.82,
            batteryPowerW: 9.8,
            adapterDescription: nil,
            adapterMaxPowerW: nil,
            adapterInputPowerW: 0,
            adapterVoltageV: 0,
            adapterCurrentA: 0,
            systemLoadW: 9.8,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "PowerLens"
        )
    }
}
