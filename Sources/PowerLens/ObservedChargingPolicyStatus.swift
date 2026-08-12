import Foundation

/// The charging policy configuration that PowerLens can observe from macOS.
///
/// PowerLens observes this state only. It never changes or temporarily
/// overrides the user's charging settings. A configured manual limit does not
/// prove that macOS is enforcing it in every sample: macOS can temporarily
/// charge beyond the selected limit.
enum ObservedChargingPolicyStatus: Codable, Equatable, Sendable {
    /// macOS does not currently report a manual limit or optimized charging.
    case inactive

    /// The user-selected manual charge limit is enabled.
    ///
    /// The percentage comes from macOS at runtime. It is intentionally not
    /// restricted to the set of values offered by the current Settings UI.
    /// Physical battery telemetry determines whether charging is currently
    /// following, holding at, or temporarily exceeding this limit.
    case manualLimit(targetPercent: Int)

    /// Optimized Battery Charging is currently engaged.
    case optimizedCharging

    /// The policy could not be inspected safely on this version of macOS.
    case unavailable

    var targetPercent: Int? {
        guard case .manualLimit(let targetPercent) = self else {
            return nil
        }
        return targetPercent
    }
}

/// An injectable, read-only boundary for charging-policy telemetry.
protocol ChargingPolicyReading: Sendable {
    func readChargingPolicyObservation() -> ChargingPolicyObservation
}

extension ChargingPolicyReading {
    /// Convenience for consumers that only need the user-facing policy state.
    func readChargingPolicyStatus() -> ObservedChargingPolicyStatus {
        readChargingPolicyObservation().status
    }
}
