import CoreGraphics

/// Fill width for a battery-level track: no minimum sliver for an empty or
/// unknown level, and never wider than the track.
enum PowerFlowBatteryLevelStripLayout {
    static func clampedLevel(_ level: Double?) -> Double {
        min(max(level ?? 0, 0), 100)
    }

    static func shouldShowFill(_ level: Double?) -> Bool {
        level != nil && clampedLevel(level) > 0
    }

    static func fillWidth(level: Double?, trackWidth: CGFloat) -> CGFloat {
        guard shouldShowFill(level), trackWidth > 0 else {
            return 0
        }

        return trackWidth * CGFloat(clampedLevel(level) / 100)
    }
}
