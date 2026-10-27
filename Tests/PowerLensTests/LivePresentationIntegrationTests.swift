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
    func sourceTransitionSurvivesFailuresAndEndsOnlyAfterAMatchingSample() {
        let charging = makeTelemetrySnapshot(isCharging: true, batteryCurrentA: 1, batteryPowerW: -12)
        var tracker = PowerStateTracker()
        var live = LiveTelemetryState()
        live.accept(.init(snapshot: charging, activeEngine: .livePrecision),
                    resolvedState: tracker.resolve(charging), attemptedAt: charging.timestamp)
        live.observe(.init(externalConnected: false, observedAt: charging.timestamp.addingTimeInterval(1)))
        for attempt in 1...3 {
            live.fail(at: charging.timestamp.addingTimeInterval(Double(attempt)))
            #expect(live.health == .delayed(failedAttempts: attempt))
            #expect(live.isAwaitingSource)
            #expect(live.snapshot == charging)
            #expect(live.presentation?.status == .sourceTransition)
            #expect(live.presentation?.notice == nil)
            #expect(live.presentation?.diagnostics.isEmpty == true)
            #expect(live.menuBar.batteryBadge == .none)
        }
        live.rebuildPresentation()
        #expect(live.presentation?.status == .sourceTransition)
        let battery = makeTelemetrySnapshot(powerSource: .battery, externalConnected: false,
                                            batteryCurrentA: -1, batteryPowerW: 12, adapterInputPowerW: 0, systemLoadW: 12)
        live.accept(.init(snapshot: battery, activeEngine: .livePrecision),
                    resolvedState: tracker.resolve(battery), attemptedAt: battery.timestamp)
        #expect(!live.isAwaitingSource)
        #expect(live.health == .live)
        #expect(live.presentation?.graph.state == .discharging)
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
