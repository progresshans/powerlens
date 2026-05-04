import Testing
@testable import PowerLens

struct DiagnosticsTests {
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
        #expect(snapshot.diagnostics.contains(where: { $0.title == L10n.text("diag.slowCharger.title") }))
        #expect(
            TelemetrySnapshot.stableDiagnostics(for: [snapshot, snapshot, snapshot])
                .contains(where: { $0.title == L10n.text("diag.slowCharger.title") })
        )
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
        #expect(!snapshot.diagnostics.contains(where: { $0.title == L10n.text("diag.slowCharger.title") }))
        #expect(!snapshot.diagnostics.contains(where: { $0.title == L10n.text("diag.negotiatedLow.title") }))
        #expect(
            TelemetrySnapshot.stableDiagnostics(for: [snapshot, snapshot, snapshot]).first?.title
                == L10n.text("diag.healthy.title")
        )
    }

    @Test
    func stableHoldingStateUsesPauseIconOnMenuBar() {
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

        let state = TelemetrySnapshot.stableExternalPowerState(
            for: [snapshot, snapshot, snapshot, snapshot, snapshot],
            requiredConsecutiveSamples: 5
        )

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

        #expect(snapshot.primaryDisplayedPowerW == 11.7)
        #expect(snapshot.menuBarTitle == "78% · 11.7W")
    }

    @Test
    func requiresRepeatedSamplesBeforeShowingPowerWarnings() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 67,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: 62,
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
            batteryCurrentA: -0.48,
            batteryPowerW: 5.9,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 18.4,
            adapterVoltageV: 19.26,
            adapterCurrentA: 0.95,
            systemLoadW: 25.9,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        let earlyDiagnostics = TelemetrySnapshot.stableDiagnostics(for: [snapshot])
        let stableDiagnostics = TelemetrySnapshot.stableDiagnostics(for: [snapshot, snapshot, snapshot])

        #expect(earlyDiagnostics.first?.title == L10n.text("diag.healthy.title"))
        #expect(stableDiagnostics.contains(where: { $0.title == L10n.text("diag.slowCharger.title") }))
    }

    @Test
    func menuBarWarningIconAlsoWaitsForStablePowerWarning() {
        let snapshot = TelemetrySnapshot(
            batteryLevel: 67,
            powerSource: .ac,
            isCharging: false,
            isCharged: false,
            externalConnected: true,
            timeToEmptyMinutes: 62,
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
            batteryCurrentA: -0.48,
            batteryPowerW: 5.9,
            adapterDescription: "PD Charger",
            adapterMaxPowerW: 97,
            adapterInputPowerW: 18.4,
            adapterVoltageV: 19.26,
            adapterCurrentA: 0.95,
            systemLoadW: 25.9,
            lowPowerModeEnabled: false,
            thermalState: "Nominal",
            serialNumber: "SERIAL",
            frontmostAppName: "Codex"
        )

        let earlyDiagnostics = TelemetrySnapshot.stableDiagnostics(for: [snapshot])
        let stableDiagnostics = TelemetrySnapshot.stableDiagnostics(for: [snapshot, snapshot, snapshot])

        #expect(snapshot.menuBarSymbolName(using: earlyDiagnostics) == "powerplug.fill")
        #expect(snapshot.menuBarSymbolName(using: stableDiagnostics) == "exclamationmark.triangle.fill")
    }
}
