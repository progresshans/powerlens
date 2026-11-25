import Foundation
import Testing
@testable import PowerLens

struct BatteryHealthChartSeriesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }

    // 23:00 in the test calendar. The next local day starts at offset 3600.
    private func point(_ offset: Int, _ capacity: Int?, _ cycles: Int?, design: Int = 5000) -> BatteryHealthPoint {
        BatteryHealthPoint(date: Date(timeIntervalSince1970: Double(15 * 3600 + offset)),
                           fullChargeCapacityMah: capacity, designCapacityMah: design,
                           nominalCapacityMah: nil, cycleCount: cycles)
    }

    @Test
    func healthKeepsDailyEndpointsAndPercentExtremaInObservationOrder() {
        let trend = [
            point(0, 4500, 20), point(60, 4700, 20), point(120, 4400, nil),
            point(180, 4650, 20, design: 6000), point(240, 4400, 21), point(300, nil, 21),
            point(3600, 4500, 21), point(3660, 4500, 21), point(3720, nil, 21),
        ]
        let series = BatteryHealthChartSeries(trend: trend, calendar: calendar)
        #expect(series.health == [trend[0], trend[1], trend[3], trend[4], trend[6], trend[7]])
        #expect(series.cycles == [trend[0], trend[4], trend[8]])
    }

    @Test
    func cyclesKeepResetsAndLatestValidReadingWithoutDuplicatingAChange() {
        let trend = [
            point(0, nil, nil), point(1, nil, 9), point(2, nil, nil), point(3, nil, 9),
            point(4, nil, 10), point(5, nil, 1), point(6, nil, nil),
        ]
        let series = BatteryHealthChartSeries(trend: trend, calendar: calendar)
        #expect(series.health.isEmpty)
        #expect(series.cycles == [trend[1], trend[4], trend[5]])
    }

    @Test
    func separateObservationsAtTheSameTimestampKeepTheirOrder() {
        let trend = [point(0, 4500, 9), point(1, 4450, 10), point(1, 4500, 11)]
        let series = BatteryHealthChartSeries(trend: trend, calendar: calendar)
        #expect(series.health == trend)
        #expect(series.cycles == trend)
    }

    @Test
    func oneHealthReadingIsDrawnOnceAndMissingCyclesAreOmitted() {
        let observation = point(0, 4500, nil)
        let series = BatteryHealthChartSeries(trend: [observation], calendar: calendar)
        #expect(series.health == [observation])
        #expect(series.cycles.isEmpty)
    }
}
