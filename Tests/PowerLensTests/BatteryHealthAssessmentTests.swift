import Testing
@testable import PowerLens

struct BatteryHealthAssessmentTests {
    private func snapshot(
        fullChargeCapacityMah: Int? = nil,
        designCapacityMah: Int? = 6000,
        text: String? = nil,
        condition: String? = nil
    ) -> TelemetrySnapshot {
        makeTelemetrySnapshot(
            designCapacityMah: designCapacityMah,
            fullChargeCapacityMah: fullChargeCapacityMah,
            batteryHealthText: text,
            batteryHealthCondition: condition
        )
    }

    @Test
    func computedCapacityDecidesBeforeTheMacOSText() {
        #expect(snapshot(fullChargeCapacityMah: 5400, text: "Check Battery").batteryHealthAssessment == .normal)
        #expect(snapshot(fullChargeCapacityMah: 4800, text: "Normal").batteryHealthAssessment == .aged)
    }

    @Test
    func serviceRecommendationWinsOverCapacity() {
        #expect(snapshot(fullChargeCapacityMah: 5900, condition: "Service Recommended").batteryHealthAssessment == .serviceRecommended)
    }

    @Test
    func macOSTextIsUsedWithoutCapacity() {
        #expect(snapshot(text: "Normal").batteryHealthAssessment == .normal)
        #expect(snapshot(text: "Aged").batteryHealthAssessment == .aged)
        #expect(snapshot(text: "Check Battery").batteryHealthAssessment == .checkBattery)
    }

    @Test
    func missingOrUnrecognizedEvidenceIsUnknown() {
        #expect(snapshot().batteryHealthAssessment == .unknown)
        #expect(snapshot(designCapacityMah: nil, text: "Good").batteryHealthAssessment == .unknown)
    }

    @Test
    func onlyAConfirmedNormalBatteryIsCalledHealthy() {
        let good = L10n.text("battery.title.good")

        #expect(BatteryHealthPresentation(.normal).title == good)
        for assessment in [BatteryHealthAssessment.aged, .checkBattery, .serviceRecommended, .unknown] {
            #expect(BatteryHealthPresentation(assessment).title != good)
        }
        #expect(BatteryHealthPresentation(.unknown).tone == .neutral)
        #expect(BatteryHealthPresentation(.checkBattery).tone == .caution)
    }

    @Test
    func checkBatteryTextTintsTheHealthTile() {
        #expect(MetricTilePresentation.health(snapshot: snapshot(text: "Check Battery")).captionTone == .caution)
        #expect(MetricTilePresentation.health(snapshot: snapshot()).captionTone == .neutral)
    }

    @Test
    func summaryTextIsUnchanged() {
        #expect(snapshot(text: "Check Battery").batteryHealthSummary == L10n.text("health.checkBattery"))
        #expect(snapshot().batteryHealthSummary == L10n.text("common.unknown"))
        #expect(snapshot(designCapacityMah: nil, text: "Good").batteryHealthSummary == "Good")
    }
}
