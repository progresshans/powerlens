import Foundation
import IOKit.ps
import Testing
@testable import PowerLens

@MainActor
struct PowerSourceMonitorTests {
    @Test
    func registersBeforeReadingAndEmitsTheInitialState() {
        let log = PowerSourceCallLog()
        let reader = StubPowerSourceStateReader(connected: false)
        reader.onRead = { log.calls.append("read") }
        let events = StubPowerSourceEvents()
        events.onStart = { log.calls.append("register") }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let monitor = PowerSourceMonitor(reader: reader, events: events, now: { now })
        var observations: [PowerSourceObservation] = []
        var reasons: [PowerSourceObservationReason] = []

        monitor.start { observation, reason in
            observations.append(observation)
            reasons.append(reason)
        }

        #expect(log.calls == ["register", "read"])
        #expect(observations == [.init(externalConnected: false, observedAt: now)])
        #expect(reasons == [.initial])
    }

    @Test
    func deduplicatesRepeatedStateEventsButAlwaysReconcilesAfterWake() {
        let reader = StubPowerSourceStateReader(connected: false)
        let events = StubPowerSourceEvents()
        let monitor = PowerSourceMonitor(reader: reader, events: events)
        var connectedStates: [Bool] = []
        var reasons: [PowerSourceObservationReason] = []
        monitor.start { observation, reason in
            connectedStates.append(observation.externalConnected)
            reasons.append(reason)
        }

        events.emit(.powerSourceChanged)
        reader.connected = true
        events.emit(.powerSourceChanged)
        events.emit(.powerSourceChanged)
        events.emit(.wake)
        reader.connected = false
        events.emit(.powerSourceChanged)

        #expect(connectedStates == [false, true, true, false])
        #expect(reasons == [.initial, .powerSourceChanged, .wake, .powerSourceChanged])
    }

    @Test
    func queuedCallbacksCannotReadOrPublishAfterStop() throws {
        let reader = StubPowerSourceStateReader(connected: false)
        let events = StubPowerSourceEvents()
        let monitor = PowerSourceMonitor(reader: reader, events: events)
        var callbackCount = 0
        monitor.start { _, _ in callbackCount += 1 }
        let queuedCallback = try #require(events.handler)
        let previousStops = events.stopCount

        monitor.stop()
        reader.connected = true
        queuedCallback(.powerSourceChanged)
        queuedCallback(.wake)

        #expect(events.stopCount == previousStops + 1)
        #expect(reader.readCount == 1)
        #expect(callbackCount == 1)
    }

    @Test
    func restartIgnoresCallbacksFromThePreviousRegistration() throws {
        let reader = StubPowerSourceStateReader(connected: false)
        let events = StubPowerSourceEvents()
        let monitor = PowerSourceMonitor(reader: reader, events: events)
        var oldCallbackCount = 0
        var newConnectedStates: [Bool] = []
        monitor.start { _, _ in oldCallbackCount += 1 }
        let queuedCallback = try #require(events.handler)
        monitor.start { observation, _ in
            newConnectedStates.append(observation.externalConnected)
        }

        reader.connected = true
        queuedCallback(.powerSourceChanged)
        #expect(reader.readCount == 2)
        events.emit(.powerSourceChanged)

        #expect(oldCallbackCount == 1)
        #expect(newConnectedStates == [false, true])
    }

    @Test
    func releasingTheMonitorStopsObserversAndLeavesQueuedCallbacksHarmless() throws {
        let reader = StubPowerSourceStateReader(connected: false)
        let events = StubPowerSourceEvents()
        var monitor: PowerSourceMonitor? = PowerSourceMonitor(reader: reader, events: events)
        let monitorWasReleased = { [weak monitor] in monitor == nil }
        var callbackCount = 0
        monitor?.start { _, _ in callbackCount += 1 }
        let queuedCallback = try #require(events.handler)
        let previousStops = events.stopCount

        monitor = nil
        queuedCallback(.powerSourceChanged)

        #expect(monitorWasReleased())
        #expect(events.stopCount == previousStops + 1)
        #expect(reader.readCount == 1)
        #expect(callbackCount == 1)
    }

    @Test
    func failedRegistrationStillAllowsInitialAndExplicitReadsAndWakeRecovery() {
        let reader = StubPowerSourceStateReader(connected: false)
        let events = StubPowerSourceEvents(registrationSucceeds: false)
        let monitor = PowerSourceMonitor(reader: reader, events: events)
        var reasons: [PowerSourceObservationReason] = []
        monitor.start { _, reason in reasons.append(reason) }

        reader.connected = true
        #expect(monitor.readCurrent()?.externalConnected == true)
        #expect(reasons == [.initial])
        events.emit(.wake)

        #expect(reasons == [.initial, .wake])
    }

    @Test
    func unavailableReadNeverBecomesADisconnectObservation() {
        let reader = StubPowerSourceStateReader(connected: nil)
        let events = StubPowerSourceEvents()
        let monitor = PowerSourceMonitor(reader: reader, events: events)
        var connectedStates: [Bool] = []
        monitor.start { observation, _ in
            connectedStates.append(observation.externalConnected)
        }
        #expect(connectedStates.isEmpty)

        reader.connected = true
        events.emit(.powerSourceChanged)
        reader.connected = nil
        events.emit(.powerSourceChanged)
        events.emit(.wake)
        #expect(monitor.readCurrent() == nil)

        #expect(connectedStates == [true])
    }

    @Test
    func explicitReadsHaveFreshTimestampsWithoutPublishing() {
        let reader = StubPowerSourceStateReader(connected: false)
        let events = StubPowerSourceEvents()
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let monitor = PowerSourceMonitor(reader: reader, events: events, now: { now })
        var callbackCount = 0
        monitor.start { _, _ in callbackCount += 1 }

        now = now.addingTimeInterval(10)
        reader.connected = true
        #expect(monitor.readCurrent() == .init(externalConnected: true, observedAt: now))
        #expect(callbackCount == 1)
    }

    @Test
    func selectsTheInternalBatteryWhenAUpsAppearsFirst() {
        let descriptions: [[String: Any]] = [
            [kIOPSTypeKey: kIOPSUPSType, kIOPSPowerSourceStateKey: kIOPMACPowerKey],
            [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSPowerSourceStateKey: kIOPMBatteryPowerKey,
            ],
        ]

        #expect(SystemPowerSourceStateReader.externalConnected(in: descriptions) == false)
    }

    @Test
    func acceptsInternalTransportWhenTypeIsMissingButNotForAKnownUps() {
        let battery: [String: Any] = [
            kIOPSTransportTypeKey: kIOPSInternalType,
            kIOPSPowerSourceStateKey: kIOPMACPowerKey,
        ]
        var ups = battery
        ups[kIOPSTypeKey] = kIOPSUPSType

        #expect(SystemPowerSourceStateReader.externalConnected(in: [battery]) == true)
        #expect(SystemPowerSourceStateReader.externalConnected(in: [ups]) == nil)
    }

    @Test
    func missingBatteryOrUnknownStateIsUnavailable() {
        #expect(SystemPowerSourceStateReader.externalConnected(in: []) == nil)
        #expect(SystemPowerSourceStateReader.externalConnected(in: [[
            kIOPSTypeKey: kIOPSUPSType,
            kIOPSPowerSourceStateKey: kIOPMACPowerKey,
        ]]) == nil)
        #expect(SystemPowerSourceStateReader.externalConnected(in: [[
            kIOPSTypeKey: kIOPSInternalBatteryType,
        ]]) == nil)
        #expect(SystemPowerSourceStateReader.externalConnected(in: [[
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSPowerSourceStateKey: "Off Line",
        ]]) == nil)
    }
}

@MainActor
private final class PowerSourceCallLog {
    var calls: [String] = []
}

@MainActor
private final class StubPowerSourceStateReader: PowerSourceStateReading {
    var connected: Bool?
    var onRead: (() -> Void)?
    private(set) var readCount = 0

    init(connected: Bool?) {
        self.connected = connected
    }

    func readExternalConnected() -> Bool? {
        readCount += 1
        onRead?()
        return connected
    }
}

@MainActor
private final class StubPowerSourceEvents: PowerSourceEventObserving {
    var handler: (@MainActor (PowerSourceObservationReason) -> Void)?
    var onStart: (() -> Void)?
    private(set) var stopCount = 0
    private let registrationSucceeds: Bool

    init(registrationSucceeds: Bool = true) {
        self.registrationSucceeds = registrationSucceeds
    }

    func start(
        _ onEvent: @escaping @MainActor (PowerSourceObservationReason) -> Void
    ) -> Bool {
        onStart?()
        handler = onEvent
        return registrationSucceeds
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ reason: PowerSourceObservationReason) {
        handler?(reason)
    }
}
