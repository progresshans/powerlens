import AppKit
import Foundation
import IOKit.ps
import notify

/// A lightweight observation of the current power source, independent of the
/// timestamp and measurements in a full telemetry snapshot.
struct PowerSourceObservation: Equatable, Sendable {
    let externalConnected: Bool
    let observedAt: Date
}

enum PowerSourceObservationReason: Equatable, Sendable {
    case initial
    case powerSourceChanged
    case wake
}

@MainActor
protocol PowerSourceMonitoring: AnyObject {
    func start(
        _ onChange: @escaping @MainActor (
            PowerSourceObservation, PowerSourceObservationReason
        ) -> Void
    )
    func stop()
    func readCurrent() -> PowerSourceObservation?
}

@MainActor
protocol PowerSourceStateReading {
    func readExternalConnected() -> Bool?
}

@MainActor
protocol PowerSourceEventObserving: AnyObject {
    @discardableResult
    func start(
        _ onEvent: @escaping @MainActor (PowerSourceObservationReason) -> Void
    ) -> Bool
    func stop()
}

@MainActor
final class PowerSourceMonitor: PowerSourceMonitoring {
    private let reader: any PowerSourceStateReading
    private let events: any PowerSourceEventObserving
    private let now: () -> Date
    private var onChange: (@MainActor (
        PowerSourceObservation, PowerSourceObservationReason
    ) -> Void)?
    private var lastConnected: Bool?
    private var generation = 0

    init(
        reader: any PowerSourceStateReading = SystemPowerSourceStateReader(),
        events: any PowerSourceEventObserving = SystemPowerSourceEvents(),
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.events = events
        self.now = now
    }

    func start(
        _ onChange: @escaping @MainActor (
            PowerSourceObservation, PowerSourceObservationReason
        ) -> Void
    ) {
        stop()
        self.onChange = onChange
        let generation = self.generation

        // Subscribe before reading to avoid missing a transition between the
        // initial state read and registration. A registration failure leaves
        // normal telemetry polling and wake observations available.
        events.start { [weak self] reason in
            guard let self, self.generation == generation else {
                return
            }
            self.observe(reason: reason)
        }
        observe(reason: .initial)
    }

    func stop() {
        generation += 1
        onChange = nil
        lastConnected = nil
        events.stop()
    }

    func readCurrent() -> PowerSourceObservation? {
        guard let connected = reader.readExternalConnected() else {
            return nil
        }
        return PowerSourceObservation(
            externalConnected: connected,
            observedAt: now()
        )
    }

    private func observe(reason: PowerSourceObservationReason) {
        guard let observation = readCurrent() else {
            return
        }
        guard reason != .powerSourceChanged
            || observation.externalConnected != lastConnected else {
            return
        }
        lastConnected = observation.externalConnected
        onChange?(observation, reason)
    }

    isolated deinit {
        events.stop()
    }
}

@MainActor
struct SystemPowerSourceStateReader: PowerSourceStateReading {
    func readExternalConnected() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
                as? [CFTypeRef] else {
            return nil
        }
        let descriptions = sources.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any]
        }
        return Self.externalConnected(in: descriptions)
    }

    /// A UPS may appear before the built-in battery in the list. Its state
    /// must never replace the Mac battery's AC connection state.
    static func externalConnected(in descriptions: [[String: Any]]) -> Bool? {
        guard let battery = PowerSourceDescriptionSelector.internalBattery(in: descriptions) else {
            return nil
        }

        switch battery[kIOPSPowerSourceStateKey] as? String {
        case kIOPMACPowerKey:
            return true
        case kIOPMBatteryPowerKey:
            return false
        default:
            // Missing/unknown data is not evidence of unplugging the charger.
            return nil
        }
    }
}

@MainActor
final class SystemPowerSourceEvents: PowerSourceEventObserving {
    private var notificationToken: Int32?
    private var wakeObserver: (any NSObjectProtocol)?
    private var generation = 0

    @discardableResult
    func start(
        _ onEvent: @escaping @MainActor (PowerSourceObservationReason) -> Void
    ) -> Bool {
        stop()
        let generation = self.generation
        var token: Int32 = 0
        // Unlike the general power-source notification, this fires only when
        // the active power source changes, avoiding percentage/time wakeups.
        let status = notify_register_dispatch(
            kIOPSNotifyPowerSource,
            &token,
            .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else {
                    return
                }
                onEvent(.powerSourceChanged)
            }
        }
        if status == NOTIFY_STATUS_OK {
            notificationToken = token
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else {
                    return
                }
                onEvent(.wake)
            }
        }
        return status == NOTIFY_STATUS_OK
    }

    func stop() {
        generation += 1
        if let notificationToken {
            notify_cancel(notificationToken)
            self.notificationToken = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    isolated deinit {
        stop()
    }
}
