import Testing
@testable import PowerLens

struct PowerFlowPresentationModelTests {
    @Test
    func directPowerUsesOnlyInputToSystemRoute() {
        let snapshot = makeTelemetrySnapshot(
            timeToEmptyMinutes: 60,
            adapterInputPowerW: 18.6,
            systemLoadW: 10.8
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .directPower)
        #expect(model.externalToSystemPower == 10.8)
        #expect(model.batteryToSystemPower == 0)
        #expect(model.externalToBatteryPower == 0)
        #expect(model.routes.map(\.role) == [.input])
        #expect(model.routes.first?.source.value == "18.6W")
        #expect(model.routes.first?.target.value == "10.8W")
    }

    @Test
    func holdingKeepsSingleInputToSystemRoute() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: 0,
            batteryPowerW: 0,
            adapterInputPowerW: 11.7,
            systemLoadW: 11.7
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .holding)
        #expect(model.routes.count == 1)
        #expect(model.routes.first?.role == .input)
        #expect(model.routes.first?.source.value == "11.7W")
        #expect(model.routes.first?.target.value == "11.7W")
    }

    @Test
    func underpoweredMergesInputAndBatteryIntoSystemLoad() {
        let snapshot = makeTelemetrySnapshot(
            batteryCurrentA: -0.4,
            batteryPowerW: 3.8,
            adapterInputPowerW: 9.1,
            systemLoadW: 12.9
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .underpowered)
        #expect(model.externalToSystemPower == 9.1)
        #expect(abs(model.batteryToSystemPower - 3.8) < 0.0001)
        #expect(model.routes.map(\.role) == [.input, .battery])
        #expect(model.routes[0].source.value == "9.1W")
        #expect(model.routes[1].source.value == "3.8W")
        #expect(model.routes[1].target.value == "12.9W")
    }

    @Test
    func chargingSplitsInputIntoSystemAndBatteryCharge() {
        let snapshot = makeTelemetrySnapshot(
            isCharging: true,
            batteryCurrentA: 3.44,
            batteryPowerW: -46.4,
            adapterInputPowerW: 53.6,
            systemLoadW: 7.2
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .charging)
        #expect(model.externalToSystemPower == 7.2)
        #expect(model.externalToBatteryPower == 46.4)
        #expect(model.batteryToSystemPower == 0)
        #expect(model.routes.map(\.role) == [.input, .charge])
        #expect(model.routes[0].target.value == "7.2W")
        #expect(model.routes[1].target.value == "46.4W")
    }

    @Test
    func batteryOnlyShowsBatteryToSystemLoad() {
        let snapshot = makeTelemetrySnapshot(
            powerSource: .battery,
            externalConnected: false,
            timeToEmptyMinutes: 240,
            batteryCurrentA: -0.82,
            batteryPowerW: 9.1,
            adapterInputPowerW: 0,
            systemLoadW: 9.1,
            adapterMaxPowerW: nil
        )

        let model = PowerFlowPresentationModel(snapshot: snapshot)

        #expect(model.state == .discharging)
        #expect(model.inputPower == 0)
        #expect(model.batteryToSystemPower == 9.1)
        #expect(model.routes.map(\.role) == [.battery])
        #expect(model.routes.first?.source.value == "9.1W")
        #expect(model.routes.first?.target.value == "9.1W")
    }
}
