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
