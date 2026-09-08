import Testing
@testable import PowerLens

struct DiagnosticsTests {
    @Test
    func menuBarPreservesApproximationOnlyForDerivedBatteryFallback() {
        let derivedBattery = makeTelemetrySnapshot(
            batteryLevel: 79,
            batteryPowerW: 10.045,
            batteryPowerSource: .currentAndVoltage,
            adapterInputPowerW: nil,
            systemLoadW: nil
        )
        let directBattery = makeTelemetrySnapshot(
            batteryLevel: 79,
            batteryPowerW: 10.045,
            batteryPowerSource: .directTelemetry,
            adapterInputPowerW: nil,
            systemLoadW: nil
        )
        let measuredSystem = makeTelemetrySnapshot(
            batteryLevel: 79,
            batteryPowerW: 10.045,
            batteryPowerSource: .currentAndVoltage,
            adapterInputPowerW: 20,
            systemLoadW: 30
        )
        let measuredInput = makeTelemetrySnapshot(
            batteryLevel: 79,
            batteryPowerW: 10.045,
            batteryPowerSource: .currentAndVoltage,
            adapterInputPowerW: 20,
            systemLoadW: nil
        )

        #expect(derivedBattery.menuBarTitle == "79% · ≈10.0W")
        #expect(directBattery.menuBarTitle == "79% · 10.0W")
        #expect(measuredSystem.menuBarTitle == "79% · 30.0W")
        #expect(measuredInput.menuBarTitle == "79% · 20.0W")
    }

    @Test
    func menuBarWarningUsesDiagnosticKindAcrossTitleChanges() {
        let snapshot = makeTelemetrySnapshot()
        let warning = DiagnosticItem(
            kind: .powerDeliveryShortfall,
            severity: .warning,
            title: "Translated power warning",
            message: "The same condition in another language"
        )
        let unrelated = DiagnosticItem(
            kind: .temperatureHigh,
            severity: .warning,
            title: L10n.text("diag.powerDeliveryShortfall.title"),
            message: "A different condition with the same title"
        )

        #expect(
            snapshot.menuBarSymbolName(using: [warning], externalPowerState: .connected)
                == "exclamationmark.triangle.fill"
        )
        #expect(
            snapshot.menuBarSymbolName(using: [unrelated], externalPowerState: .connected)
                == "powerplug.fill"
        )
    }

    @Test
    func detectsInsufficientPowerWhenLoadExceedsInput() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 80,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: 84,
            timeToFullMinutes: nil,
            designCapacityMah: 6249,
            fullChargeCapacityMah: 5637,
            nominalCapacityMah: 5874,
            cycleCount: 74,
            designCycleCount: 1000,
            batteryHealthText: "Normal",
            batteryHealthCondition: nil,
            batteryTemperatureC: 29.5,
            batteryVoltageV: 12.38,
            batteryCurrentA: -0.54,
            batteryPowerW: 6.7,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 20.9,
            adapterVoltageV: 19.26,
            adapterCurrentA: 1.09,
            systemLoadW: 28.6,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        #expect(snapshot.chargerAdequacy == .insufficient)
        #expect(snapshot.statusHeadline == L10n.text("status.adapterBatteryAssist"))
        #expect(snapshot.diagnostics.contains(where: {
            $0.title == L10n.text("diag.powerDeliveryShortfall.title")
        }))
    }

    @Test
    func reportsHealthyHeadroomForAdequateAdapter() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 83,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            designCapacityMah: 6249,
            fullChargeCapacityMah: 5790,
            nominalCapacityMah: 5874,
            cycleCount: 74,
            designCycleCount: 1000,
            batteryHealthText: "Normal",
            batteryHealthCondition: nil,
            batteryTemperatureC: 30,
            batteryVoltageV: 12.41,
            batteryCurrentA: 0.0,
            batteryPowerW: 0.0,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 31.2,
            adapterVoltageV: 20.1,
            adapterCurrentA: 1.55,
            systemLoadW: 22.0,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        #expect(snapshot.chargerAdequacy == .ample)
        #expect(snapshot.diagnostics.first?.title == L10n.text("diag.healthy.title"))
    }

    @Test
    func suppressesPowerWarningsWhileChargeIsLikelyBeingHeld() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 78,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            designCapacityMah: 6249,
            fullChargeCapacityMah: 5637,
            nominalCapacityMah: 5874,
            cycleCount: 74,
            designCycleCount: 1000,
            batteryHealthText: "Normal",
            batteryHealthCondition: nil,
            batteryTemperatureC: 29.5,
            batteryVoltageV: 12.38,
            batteryCurrentA: 0.0,
            batteryPowerW: 0.0,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 8.1,
            adapterVoltageV: 19.26,
            adapterCurrentA: 0.42,
            systemLoadW: 11.7,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        #expect(snapshot.shouldSuppressPowerDeliveryWarnings)
        #expect(snapshot.statusHeadline == L10n.text("status.holdingCurrentLevel"))
        #expect(!snapshot.diagnostics.contains(where: {
            $0.title == L10n.text("diag.powerDeliveryShortfall.title")
        }))
    }

    @Test
    func resolvedHoldingStateUsesPauseIconOnMenuBar() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 78,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            designCapacityMah: 6249,
            fullChargeCapacityMah: 5637,
            nominalCapacityMah: 5874,
            cycleCount: 74,
            designCycleCount: 1000,
            batteryHealthText: "Normal",
            batteryHealthCondition: nil,
            batteryTemperatureC: 29.5,
            batteryVoltageV: 12.38,
            batteryCurrentA: 0.0,
            batteryPowerW: 0.0,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 11.7,
            adapterVoltageV: 19.26,
            adapterCurrentA: 0.61,
            systemLoadW: 11.7,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        var tracker = PowerStateTracker(configuration: .init(holdConfirmation: 0))
        let state = tracker.resolve(snapshot).externalPowerState

        #expect(state == .holding)
        #expect(snapshot.menuBarSymbolName(using: [], externalPowerState: state) == "pause.circle.fill")
    }

    @Test
    func menuBarTitleUsesSamePrimaryPowerValueAsPopover() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 78,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            designCapacityMah: 6249,
            fullChargeCapacityMah: 5637,
            nominalCapacityMah: 5874,
            cycleCount: 74,
            designCycleCount: 1000,
            batteryHealthText: "Normal",
            batteryHealthCondition: nil,
            batteryTemperatureC: 29.5,
            batteryVoltageV: 12.38,
            batteryCurrentA: 0.0,
            batteryPowerW: 0.0,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 8.1,
            adapterVoltageV: 19.26,
            adapterCurrentA: 0.42,
            systemLoadW: 11.7,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        #expect(snapshot.primaryDisplayedPower?.watts == 11.7)
        #expect(snapshot.menuBarTitle == "78% · 11.7W")
    }

}
