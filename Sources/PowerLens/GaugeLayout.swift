import CoreGraphics

/// Fill width for a battery-level track: no minimum sliver for an empty or
/// unknown level, and never wider than the track.
enum GaugeLayout {
    static func fillWidth(fraction: Double?, trackWidth: CGFloat) -> CGFloat {
        guard let fraction, fraction.isFinite, fraction > 0, trackWidth > 0 else {
            return 0
        }
        return trackWidth * min(fraction, 1)
    }
}
