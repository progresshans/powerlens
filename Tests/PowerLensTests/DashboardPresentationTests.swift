import Testing
@testable import PowerLens

struct ChargingMethodPresentationTests {
    @Test
    func aConfiguredLimitStaysVisibleOnBattery() {
        // The policy is read on battery too; unplugging must not turn an 80%
        // limit into "default".
        let onBattery = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            chargingPolicyStatus: .manualLimit(targetPercent: 80)
        )
        let method = ChargingMethodPresentation(policy: onBattery.chargingPolicyStatus)

        #expect(method.value == "80%")
        #expect(method.fraction == 0.8)
    }

    @Test
    func eachPolicyHasItsOwnDescription() {
        #expect(ChargingMethodPresentation(policy: .inactive).value == L10n.text("battery.charging.default"))
        #expect(ChargingMethodPresentation(policy: .inactive).fraction == 1)
        #expect(ChargingMethodPresentation(policy: .optimizedCharging).value == L10n.text("battery.charging.optimized"))
    }

    @Test
    func anUnreadablePolicyIsUnknownNotDefault() {
        for policy in [ObservedChargingPolicyStatus.unavailable, .manualLimit(targetPercent: 0), nil] {
            let method = ChargingMethodPresentation(policy: policy)
            #expect(method.value == L10n.text("common.none"))
            #expect(method.caption == L10n.text("battery.charging.unknownCaption"))
            #expect(method.fraction == nil)
        }
    }
}
