import Foundation
import Testing
@testable import PowerLens

struct TelemetryCoordinatorTests {
    @Test
    func autoPrefersLivePrecisionWhenAvailable() throws {
        let policyReader = StubChargingPolicyReader(
            status: .manualLimit(targetPercent: 85)
        )
        let coordinator = TelemetryCoordinator(
            compatibleReader: StubReader(snapshot: makeSnapshot(systemLoadW: nil, adapterInputPowerW: nil)),
            livePrecisionReader: StubReader(snapshot: makeSnapshot(systemLoadW: 22.0, adapterInputPowerW: 20.9)),
            chargingPolicyReader: policyReader
        )

        let result = try coordinator.readSnapshot(preference: .auto)

        #expect(result.activeEngine == .livePrecision)
        #expect(result.snapshot.systemLoadW == 22.0)
        #expect(result.snapshot.chargingPolicyStatus == .manualLimit(targetPercent: 85))
        #expect(policyReader.readCount == 1)
    }

    @Test
    func autoFallsBackToCompatibleWhenLivePrecisionFails() throws {
        let policyReader = StubChargingPolicyReader(status: .optimizedCharging)
        let coordinator = TelemetryCoordinator(
            compatibleReader: StubReader(snapshot: makeSnapshot(systemLoadW: nil, adapterInputPowerW: nil)),
            livePrecisionReader: StubReader(error: TelemetryReadError.unavailable),
            chargingPolicyReader: policyReader
        )

        let result = try coordinator.readSnapshot(preference: .auto)

        #expect(result.activeEngine == .compatible)
        #expect(result.snapshot.systemLoadW == nil)
        #expect(result.snapshot.chargingPolicyStatus == .optimizedCharging)
        #expect(policyReader.readCount == 1)
    }

    @Test
    func livePrecisionModeFallsBackInsteadOfBreakingTheApp() throws {
        let policyReader = StubChargingPolicyReader(status: .unavailable)
        let coordinator = TelemetryCoordinator(
            compatibleReader: StubReader(snapshot: makeSnapshot(systemLoadW: nil, adapterInputPowerW: nil)),
            livePrecisionReader: StubReader(error: TelemetryReadError.unavailable),
            chargingPolicyReader: policyReader
        )

        let result = try coordinator.readSnapshot(preference: .livePrecision)

        #expect(result.activeEngine == .compatible)
        #expect(result.snapshot.adapterInputPowerW == nil)
        #expect(result.snapshot.chargingPolicyStatus == .unavailable)
        #expect(policyReader.readCount == 1)
    }

    @Test
    func legacySnapshotWithoutChargingPolicyStillDecodes() throws {
        let legacySnapshot = makeSnapshot(
            systemLoadW: 22,
            adapterInputPowerW: 20
        )
        let enrichedSnapshot = legacySnapshot.withChargingPolicyStatus(
            .manualLimit(targetPercent: 90)
        )
        let encoded = try JSONEncoder().encode(enrichedSnapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "chargingPolicyStatus")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            TelemetrySnapshot.self,
            from: legacyData
        )

        #expect(decoded == legacySnapshot)
        #expect(decoded.chargingPolicyStatus == nil)
    }
}

private struct StubReader: TelemetrySnapshotReader {
    let snapshot: TelemetrySnapshot?
    let error: Error?

    init(snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
        self.error = nil
    }

    init(error: Error) {
        self.snapshot = nil
        self.error = error
    }

    func readSnapshot() throws -> TelemetrySnapshot {
        if let error {
            throw error
        }

        guard let snapshot else {
            throw TelemetryReadError.unavailable
        }

        return snapshot
    }
}

private final class StubChargingPolicyReader:
    ChargingPolicyReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let status: ObservedChargingPolicyStatus
    private var storedReadCount = 0

    init(status: ObservedChargingPolicyStatus) {
        self.status = status
    }

    var readCount: Int {
        lock.withLock {
            storedReadCount
        }
    }

    func readChargingPolicyStatus() -> ObservedChargingPolicyStatus {
        lock.withLock {
            storedReadCount += 1
        }
        return status
    }
}

private func makeSnapshot(
    systemLoadW: Double?,
    adapterInputPowerW: Double?
) -> TelemetrySnapshot {
    TelemetrySnapshot(
        timestamp: Date(timeIntervalSince1970: 1_775_628_000),
        batteryLevel: 80,
        powerSource: .ac,
        isCharging: false,
        isCharged: false,
        externalConnected: true,
        timeToEmptyMinutes: nil,
        timeToFullMinutes: nil,
        designCapacityMah: 6249,
        fullChargeCapacityMah: 5637,
        nominalCapacityMah: 5874,
        cycleCount: 74,
        designCycleCount: 1000,
        batteryHealthText: "Normal",
        batteryHealthCondition: nil,
        batteryTemperatureC: 29.5,
        batteryVoltageV: 12.38,
        batteryCurrentA: 0.0,
        batteryPowerW: 0.0,
        adapterDescription: "PD Charger",
        adapterMaxPowerW: 97,
        adapterInputPowerW: adapterInputPowerW,
        adapterVoltageV: 19.26,
        adapterCurrentA: 1.09,
        systemLoadW: systemLoadW,
        lowPowerModeEnabled: false,
        thermalState: "Nominal",
        serialNumber: "SERIAL",
        frontmostAppBundleID: "com.openai.codex",
        frontmostAppName: "Codex"
    )
}
