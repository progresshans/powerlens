import Foundation

struct TelemetryFreshness: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case waiting
        case live
        case delayed
        case unavailable
    }

    static let liveAgeLimit: TimeInterval = 6
    static let criticalDelayAge: TimeInterval = 60

    let state: State
    let age: TimeInterval?

    init(
        refreshDate: Date?,
        health: TelemetryHealth,
        now: Date
    ) {
        age = refreshDate.map {
            max(0, now.timeIntervalSince($0))
        }

        switch health {
        case .waiting:
            state = .waiting
        case .unavailable:
            state = .unavailable
        case .delayed:
            state = .delayed
        case .live:
            guard let age else {
                state = .waiting
                return
            }
            state = age <= Self.liveAgeLimit ? .live : .delayed
        }
    }

    var title: String {
        switch state {
        case .waiting, .live:
            L10n.text("telemetry.live")
        case .delayed:
            L10n.text("telemetry.delayed")
        case .unavailable:
            L10n.text("telemetry.unavailable")
        }
    }

    var isLive: Bool {
        state == .live
    }

    var isCriticallyDelayed: Bool {
        state == .delayed
            && (age ?? .infinity) > Self.criticalDelayAge
    }
}
