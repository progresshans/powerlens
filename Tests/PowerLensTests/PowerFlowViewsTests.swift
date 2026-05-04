import CoreGraphics
import Testing
@testable import PowerLens

struct PowerFlowViewsTests {
    @Test
    func batteryLevelStripDoesNotDrawMinimumFillForZeroOrUnknownLevel() {
        #expect(PowerFlowBatteryLevelStripLayout.fillWidth(level: nil, trackWidth: 320) == 0)
        #expect(PowerFlowBatteryLevelStripLayout.fillWidth(level: 0, trackWidth: 320) == 0)
        #expect(PowerFlowBatteryLevelStripLayout.fillWidth(level: -8, trackWidth: 320) == 0)
    }

    @Test
    func batteryLevelStripFillWidthTracksActualBatteryPercentage() {
        #expect(abs(PowerFlowBatteryLevelStripLayout.fillWidth(level: 1, trackWidth: 320) - 3.2) < 0.0001)
        #expect(PowerFlowBatteryLevelStripLayout.fillWidth(level: 50, trackWidth: 320) == 160)
        #expect(PowerFlowBatteryLevelStripLayout.fillWidth(level: 120, trackWidth: 320) == 320)
    }
}
