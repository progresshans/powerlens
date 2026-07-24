import Foundation

/// The charging policy that macOS is currently applying.
///
/// PowerLens observes this state only. It never changes or temporarily
/// overrides the user's charging settings.
enum ObservedChargingPolicyStatus: Codable, Equatable, Sendable {
    /// macOS is not currently applying a manual limit or optimized charging.
    case inactive

    /// The user-selected manual charge limit is active.
    ///
    /// The percentage comes from macOS at runtime. It is intentionally not
    /// restricted to the set of values offered by the current Settings UI.
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
    func readChargingPolicyStatus() -> ObservedChargingPolicyStatus
}
