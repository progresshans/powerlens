import CoreGraphics
import Testing
@testable import PowerLens

struct GaugeLayoutTests {
    @Test
    func gaugeDoesNotDrawMinimumFillForZeroOrUnknownFraction() {
        #expect(GaugeLayout.fillWidth(fraction: nil, trackWidth: 320) == 0)
        #expect(GaugeLayout.fillWidth(fraction: 0, trackWidth: 320) == 0)
        #expect(GaugeLayout.fillWidth(fraction: -0.08, trackWidth: 320) == 0)
    }

    @Test
    func gaugeFillWidthTracksTheActualFraction() {
        #expect(abs(GaugeLayout.fillWidth(fraction: 0.01, trackWidth: 320) - 3.2) < 0.0001)
        #expect(GaugeLayout.fillWidth(fraction: 0.5, trackWidth: 320) == 160)
        #expect(GaugeLayout.fillWidth(fraction: 1.2, trackWidth: 320) == 320)
    }
}
