import Testing
@testable import PowerLens

struct FormattersTests {
    @Test
    func adapterRatingsAreWholeWatts() {
        #expect(Formatters.ratedPower(96.6) == "97W")
        #expect(Formatters.ratedPower(140) == "140W")
    }

    @Test
    func tileTemperatureDropsTheTenth() {
        #expect(Formatters.wholeTemperature(30.3) == "30°C")
    }
}
