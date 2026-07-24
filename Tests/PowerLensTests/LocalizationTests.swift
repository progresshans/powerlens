import Foundation
import Testing
@testable import PowerLens

struct LocalizationTests {
    @Test
    func managedChargingCopyExistsInEnglishAndKorean() {
        let keys = [
            "status.manualLimit.charging",
            "status.manualLimit.reducing",
            "status.manualLimit.holding",
            "status.manualLimit.active",
            "status.optimizedCharging.active",
            "status.optimizedCharging.holding",
            "status.subheadline.manualLimit.charging",
            "status.subheadline.manualLimit.reducing",
            "status.subheadline.manualLimit.holding",
            "status.subheadline.manualLimit.active",
            "status.subheadline.optimizedCharging.active",
            "status.subheadline.optimizedCharging.holding",
            "status.subheadline.optimizedCharging.activeFlowUnknown",
            "status.subheadline.manualLimit.transientAssist",
            "status.subheadline.optimizedCharging.transientAssist",
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
