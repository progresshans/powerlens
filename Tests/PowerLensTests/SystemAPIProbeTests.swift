import Foundation
import Testing
@testable import PowerLens

struct SystemAPIProbeTests {
    @Test
    func commandDetectionDoesNotTreatNormalLaunchAsAProbe() {
        #expect(
            SystemAPIProbeCommand.isRequested(
                arguments: ["PowerLens", "--system-api-probe", "--format", "json"]
            )
        )
        #expect(
            !SystemAPIProbeCommand.isRequested(arguments: ["PowerLens"])
        )
    }

    @Test
    func reportHasAStableSanitizedSchema() throws {
        let report = SystemAPIProbe.makeReport()
        let data = try JSONEncoder().encode(report)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedText = try #require(String(data: data, encoding: .utf8))

        #expect(
            report.schemaVersion == SystemAPIProbeReport.currentSchemaVersion
        )
        #expect(report.host.architecture == "arm64")
        #expect(report.powerUI.methods.count == PowerUIRuntime.contracts.count)
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(!encodedText.contains("serialNumber"))
        #expect(!encodedText.contains("frontmostApp"))
        #expect(!encodedText.contains("batteryPowerW"))
        #expect(!encodedText.contains("adapterInputPowerW"))
    }

    @Test
    func reportSupportsCodableRoundTrip() throws {
        let report = SystemAPIProbe.makeReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            SystemAPIProbeReport.self,
            from: data
        )

        #expect(decoded == report)
    }
}
