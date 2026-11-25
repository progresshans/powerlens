import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PowerLens

@MainActor
struct LivePresentationIntegrationTests {
    @Test
    func detachingAWindowStopsVisibilityNotifications() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        var visible = false
        var observer: WindowVisibilityObserver.Coordinator? = .init(isVisible: Binding(
            get: { visible }, set: { visible = $0 }
        ))
        observer?.observe(window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(visible)
        observer?.observe(nil)
        visible = false
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!visible)
        let isReleased = { [weak observer] in observer == nil }
        observer = nil
        #expect(isReleased())
    }

    @Test
    func sourceTransitionSurvivesFailuresAndEndsOnlyAfterAMatchingSample() throws {
        let charging = makeTelemetrySnapshot(isCharging: true, batteryCurrentA: 1, batteryPowerW: -12)
        var tracker = PowerStateTracker()
        var live = LiveTelemetryState()
        #expect(live.menuBar.tooltip == "PowerLens")
        live.observe(.init(externalConnected: true, observedAt: charging.timestamp))
        #expect(live.menuBar.tooltip == L10n.text("status.externalPowerConnected"))
        let chargingState = tracker.resolve(charging)
        live.accept(.init(snapshot: charging, activeEngine: .livePrecision),
                    resolvedState: chargingState, attemptedAt: charging.timestamp)
        let chargingBody = try #require(live.presentation?.tooltip)
        #expect(live.menuBar.tooltip == "\(charging.statusHeadline(resolvedState: chargingState))\n\n\(chargingBody)")
        live.observe(.init(externalConnected: false, observedAt: charging.timestamp.addingTimeInterval(1)))
        let transitionTooltip = "\(L10n.text("status.runningOnBattery"))\n\n\(chargingBody)"
        for attempt in 1...3 {
            live.fail(at: charging.timestamp.addingTimeInterval(Double(attempt)))
            #expect(live.health == .delayed(failedAttempts: attempt))
            #expect(live.isAwaitingSource)
            #expect(live.snapshot == charging)
            #expect(live.presentation?.status == .sourceTransition)
            #expect(live.presentation?.notice == nil)
            #expect(live.presentation?.diagnostics.isEmpty == true)
            #expect(live.menuBar.batteryBadge == .none)
            #expect(live.menuBar.tooltip == transitionTooltip)
        }
        live.rebuildPresentation()
        #expect(live.presentation?.status == .sourceTransition)
        #expect(live.menuBar.tooltip == transitionTooltip)
        let battery = makeTelemetrySnapshot(powerSource: .battery, externalConnected: false,
                                            batteryCurrentA: -1, batteryPowerW: 12, adapterInputPowerW: 0, systemLoadW: 12)
        let batteryState = tracker.resolve(battery)
        live.accept(.init(snapshot: battery, activeEngine: .livePrecision),
                    resolvedState: batteryState, attemptedAt: battery.timestamp)
        #expect(!live.isAwaitingSource)
        #expect(live.health == .live)
        #expect(live.presentation?.graph.state == .discharging)
        let batteryBody = try #require(live.presentation?.tooltip)
        #expect(batteryBody == PowerFlowTooltip.text(snapshot: battery))
        #expect(batteryBody != chargingBody)
        #expect(live.menuBar.tooltip == "\(battery.statusHeadline(resolvedState: batteryState))\n\n\(batteryBody)")
    }

    @Test
    func menuBarTooltipUpdatesWhenOnlyRawPowerChanges() throws {
        let first = makeTelemetrySnapshot(systemLoadW: 10.011)
        let second = makeTelemetrySnapshot(systemLoadW: 10.019)
        #expect(first.menuBarTitle == second.menuBarTitle)
        var live = LiveTelemetryState()
        var tracker = PowerStateTracker()
        live.accept(.init(snapshot: first, activeEngine: .livePrecision),
                    resolvedState: tracker.resolve(first), attemptedAt: first.timestamp)
        let firstBody = try #require(live.presentation?.tooltip)

        let state = tracker.resolve(second)
        live.accept(.init(snapshot: second, activeEngine: .livePrecision),
                    resolvedState: state, attemptedAt: second.timestamp)
        let secondBody = try #require(live.presentation?.tooltip)
        #expect(secondBody != firstBody)
        #expect(secondBody == PowerFlowTooltip.text(snapshot: second))
        #expect(live.menuBar.tooltip == "\(second.statusHeadline(resolvedState: state))\n\n\(secondBody)")
    }

    @Test(arguments: ["Nominal", "Critical"])
    func batteryTemperatureDoesNotBorrowSystemThermalPressure(thermal: String) {
        let missing = makeTelemetrySnapshot(thermalState: thermal, batteryTemperatureC: nil)
        #expect(MetricTilePresentation.temperature(snapshot: missing).caption == L10n.text("thermal.unknown"))
        #expect(DashboardInsight.temperatureTitle(snapshot: missing) == L10n.text("insight.temperature.unknown"))
        let warm = makeTelemetrySnapshot(thermalState: thermal, batteryTemperatureC: 37)
        #expect(MetricTilePresentation.temperature(snapshot: warm).caption == L10n.text("thermal.fair"))
        #expect(MetricTilePresentation.temperature(snapshot: warm).captionTone == .caution)
        #expect(warm.diagnostics.first { $0.kind == .temperatureHigh }?.title == L10n.text("diag.temperatureWarm.title"))
        #expect(!DashboardInsight.temperatureTitle(snapshot: warm).contains(L10n.text("thermal.nominal")))
        let hot = makeTelemetrySnapshot(thermalState: thermal, batteryTemperatureC: 40)
        #expect(MetricTilePresentation.temperature(snapshot: hot).caption == L10n.text("thermal.serious"))
        #expect(MetricTilePresentation.temperature(snapshot: hot).captionTone == .warning)
        #expect(hot.diagnostics.first { $0.kind == .temperatureHigh }?.title == L10n.text("diag.temperatureHigh.title"))
        #expect(!DashboardInsight.temperatureTitle(snapshot: hot).contains(L10n.text("thermal.nominal")))
        let normal = makeTelemetrySnapshot(thermalState: thermal, batteryTemperatureC: 30)
        #expect(MetricTilePresentation.temperature(snapshot: normal).caption == L10n.text("thermal.nominal"))
        #expect(!normal.diagnostics.contains { $0.kind == .temperatureHigh })
    }

    @Test(arguments: [
        (35.9, BatteryTemperatureAssessment.normal), (36, .elevated),
        (39.9, .elevated), (40, .hot), (.nan, .unknown),
    ])
    func batteryTemperatureBandsMatchTheChart(celsius: Double, expected: BatteryTemperatureAssessment) {
        #expect(BatteryTemperatureAssessment(celsius) == expected)
    }

    @Test
    func batteryTemperatureCaptionNamesTheWarmThreshold() {
        let threshold = Formatters.wholeTemperature(BatteryTemperatureAssessment.elevatedThreshold)
        #expect(threshold == "36°C")
        #expect(L10n.tr("battery.temperature.caption", "", threshold).contains(threshold))
    }

    @Test
    func confirmedShortfallHasOneInterpretationAndDoesNotAssignAHardwareCause() {
        let snapshot = makeTelemetrySnapshot(timeToEmptyMinutes: 84, batteryVoltageV: 12.38,
            batteryCurrentA: -0.54, batteryPowerW: 6.7, adapterInputPowerW: 20.9, systemLoadW: 28.6)
        var tracker = PowerStateTracker(configuration: .init(transientAssistGrace: 0, shortfallEvidenceConfirmation: 0))
        let resolved = tracker.resolve(snapshot)
        #expect(resolved.powerDeliveryState == .sustainedShortfall)
        let diagnostics = snapshot.diagnostics(resolvedState: resolved)
        let presentation = LivePowerPresentation(snapshot: snapshot, resolvedState: resolved, diagnostics: diagnostics, isAwaitingSource: false)
        #expect(presentation.charger.caption == L10n.text("charger.usage.shortfall"))
        #expect(presentation.notice?.title == diagnostics.first?.title)
        #expect(presentation.notice?.message == diagnostics.first?.message)
        // Each surface adds something instead of repeating the headline.
        #expect(presentation.notice?.title != presentation.status.title)
        #expect(presentation.charger.caption != presentation.status.title)
        #expect(diagnostics.map(\.id) == snapshot.diagnostics(resolvedState: resolved).map(\.id))
    }

    @Test(arguments: [Double?.none, 0, -1])
    func theActualGaugeDrawsNoFillForMissingOrEmptyValues(fraction: Double?) throws {
        let renderer = ImageRenderer(content: BarGauge(fraction: fraction, tint: .green).frame(width: 320, height: 8))
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        for x in 0..<bitmap.pixelsWide {
            let color = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(color.greenComponent - color.redComponent < 0.2)
        }
    }

    @Test
    func workDemandMatchesConsumersRatherThanAnyOpenWindow() {
        var activity = PresentationActivity(settings: true)
        #expect(activity.needsLiveReadings && !activity.needsEnergyApps)
        activity.dashboard = true
        #expect(activity.needsEnergyApps)
        activity.dashboardShowsEnergyApps = false
        #expect(!activity.needsEnergyApps)
        activity.popover = true
        #expect(activity.needsEnergyApps)
        activity.popover = false
        activity.dashboard = false
        activity.settings = false
        #expect(!activity.needsLiveReadings && !activity.needsEnergyApps)
    }
}
