import Testing
@testable import PowerLens

struct EnergyModeReaderTests {
    @Test
    func highPowerCapableMacsReadPowermode() {
        let output = """
        System-wide power settings:
        Currently in use:
         powermode            2
         lowpowermode         0
        """

        #expect(EnergyModeReader.mode(pmsetOutput: output, lowPowerFallback: false) == .highPower)
    }

    @Test
    func powermodeZeroIsAutomatic() {
        #expect(EnergyModeReader.mode(pmsetOutput: " powermode 0\n", lowPowerFallback: false) == .automatic)
        #expect(EnergyModeReader.mode(pmsetOutput: " powermode 1\n", lowPowerFallback: false) == .lowPower)
    }

    @Test
    func macsWithoutHighPowerModeOnlyReportLowPower() {
        let output = " lowpowermode         0\n sleep 1\n"

        #expect(EnergyModeReader.mode(pmsetOutput: output, lowPowerFallback: false) == .standard)
        #expect(EnergyModeReader.mode(pmsetOutput: output, lowPowerFallback: true) == .lowPower)
        #expect(EnergyModeReader.mode(pmsetOutput: nil, lowPowerFallback: true) == .lowPower)
    }
}
