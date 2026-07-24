import Foundation
import Testing
@testable import PowerLens

struct ChargingPolicyReaderTests {
    @Test(arguments: [87, 93])
    func manualLimitUsesTheRuntimeValue(
        targetPercent: Int
    ) {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(targetPercent)],
            optimizedChargingEngaged: .success(true)
        )

        let status = ChargingPolicyStatusResolver.resolve(using: client)

        #expect(status == .manualLimit(targetPercent: targetPercent))
        #expect(client.calls == [.manualLimitEnabled, .manualLimit])
    }

    @Test
    func manualLimitTakesPrecedenceWithoutQueryingOptimizedCharging() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(80)],
            optimizedChargingEngaged: .success(true)
        )

        #expect(
            ChargingPolicyStatusResolver.resolve(using: client)
                == .manualLimit(targetPercent: 80)
        )
        #expect(client.calls == [.manualLimitEnabled, .manualLimit])
    }

    @Test
    func optimizedChargingIsReadAfterManualLimitIsInactive() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(false),
            manualLimits: [.success(80)],
            optimizedChargingEngaged: .success(true)
        )

        #expect(
            ChargingPolicyStatusResolver.resolve(using: client)
                == .optimizedCharging
        )
        #expect(client.calls == [
            .manualLimitEnabled,
            .optimizedChargingEngaged,
        ])
    }

    @Test
    func missingManualLimitAPIStillAllowsOptimizedChargingFallback() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .failure(.unsupported),
            manualLimits: [.success(80)],
            optimizedChargingEngaged: .success(true)
        )

        #expect(
            ChargingPolicyStatusResolver.resolve(using: client)
                == .optimizedCharging
        )
        #expect(client.calls == [
            .manualLimitEnabled,
            .optimizedChargingEngaged,
        ])
    }

    @Test
    func inactiveMeansNeitherManagedPolicyIsEngaged() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(false),
            manualLimits: [.success(80)],
            optimizedChargingEngaged: .success(false)
        )

        #expect(ChargingPolicyStatusResolver.resolve(using: client) == .inactive)
    }

    @Test(arguments: [0, 101, 255])
    func invalidManualLimitIsUnavailable(targetPercent: Int) {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(targetPercent)],
            optimizedChargingEngaged: .success(false)
        )

        #expect(
            ChargingPolicyStatusResolver.resolve(using: client)
                == .unavailable
        )
    }

    @Test
    func queryErrorsDoNotGuessThePolicy() {
        let clients = [
            SmartChargeQueryStub(
                manualLimitEnabled: .failure(.operationFailed),
                manualLimits: [.success(80)],
                optimizedChargingEngaged: .success(true)
            ),
            SmartChargeQueryStub(
                manualLimitEnabled: .success(true),
                manualLimits: [.failure(.operationFailed)],
                optimizedChargingEngaged: .success(true)
            ),
            SmartChargeQueryStub(
                manualLimitEnabled: .success(false),
                manualLimits: [.success(80)],
                optimizedChargingEngaged: .failure(.operationFailed)
            ),
        ]

        for client in clients {
            #expect(
                ChargingPolicyStatusResolver.resolve(using: client)
                    == .unavailable
            )
        }
    }

    @Test
    func valuesRefreshOnEveryReadWhileTheRuntimeSessionIsReused() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(87), .success(93)],
            optimizedChargingEngaged: .success(false)
        )
        let factory = SmartChargeSessionFactoryStub(session: client)
        let reader = PowerUIChargingPolicyReader(sessionFactory: factory)

        #expect(
            reader.readChargingPolicyStatus()
                == .manualLimit(targetPercent: 87)
        )
        #expect(
            reader.readChargingPolicyStatus()
                == .manualLimit(targetPercent: 93)
        )
        #expect(factory.makeSessionCallCount == 1)
        #expect(client.calls == [
            .manualLimitEnabled,
            .manualLimit,
            .manualLimitEnabled,
            .manualLimit,
        ])
    }

    @Test
    func failedSessionCreationIsContainedDuringBackoff() {
        let factory = SmartChargeSessionFactoryStub(session: nil)
        let reader = PowerUIChargingPolicyReader(sessionFactory: factory)

        #expect(reader.readChargingPolicyStatus() == .unavailable)
        #expect(reader.readChargingPolicyStatus() == .unavailable)
        #expect(factory.makeSessionCallCount == 1)
    }

    @Test
    func readerRetriesAndRecoversWhenBackoffExpires() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(87)],
            optimizedChargingEngaged: .success(false)
        )
        let uptime = UptimeStub(value: 1_000)
        let factory = SmartChargeSessionFactoryStub(
            sessions: [nil, client]
        )
        let reader = PowerUIChargingPolicyReader(
            sessionFactory: factory,
            retryInterval: 60,
            uptime: { uptime.value }
        )

        #expect(reader.readChargingPolicyStatus() == .unavailable)
        uptime.advance(by: 59)
        #expect(reader.readChargingPolicyStatus() == .unavailable)
        #expect(factory.makeSessionCallCount == 1)

        uptime.advance(by: 1)
        #expect(
            reader.readChargingPolicyStatus()
                == .manualLimit(targetPercent: 87)
        )
        #expect(factory.makeSessionCallCount == 2)
    }

    @Test
    func observedStatusSupportsCodableRoundTrips() throws {
        let statuses: [ObservedChargingPolicyStatus] = [
            .inactive,
            .manualLimit(targetPercent: 93),
            .optimizedCharging,
            .unavailable,
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in statuses {
            let decoded = try decoder.decode(
                ObservedChargingPolicyStatus.self,
                from: encoder.encode(status)
            )
            #expect(decoded == status)
            #expect(decoded.targetPercent == status.targetPercent)
        }
    }

    @Test
    func consumerCanInjectAStubThroughTheReadingBoundary() {
        let reader: any ChargingPolicyReading = ChargingPolicyReaderStub(
            status: .manualLimit(targetPercent: 92)
        )

        #expect(
            reader.readChargingPolicyStatus()
                == .manualLimit(targetPercent: 92)
        )
    }
}

private final class SmartChargeQueryStub: PowerUISmartChargeQuerying {
    enum Call: Equatable {
        case manualLimitEnabled
        case manualLimit
        case optimizedChargingEngaged
    }

    private let manualLimitEnabled: Result<Bool, StubError>
    private var manualLimits: [Result<Int, StubError>]
    private let optimizedChargingEngaged: Result<Bool, StubError>
    private(set) var calls: [Call] = []

    init(
        manualLimitEnabled: Result<Bool, StubError>,
        manualLimits: [Result<Int, StubError>],
        optimizedChargingEngaged: Result<Bool, StubError>
    ) {
        self.manualLimitEnabled = manualLimitEnabled
        self.manualLimits = manualLimits
        self.optimizedChargingEngaged = optimizedChargingEngaged
    }

    func isManualChargeLimitEnabled() throws -> Bool {
        calls.append(.manualLimitEnabled)
        return try manualLimitEnabled.getForManualSupport()
    }

    func manualChargeLimit() throws -> Int {
        calls.append(.manualLimit)
        guard !manualLimits.isEmpty else {
            throw StubError.operationFailed
        }
        return try manualLimits.removeFirst().get()
    }

    func isOptimizedChargingEngaged() throws -> Bool {
        calls.append(.optimizedChargingEngaged)
        return try optimizedChargingEngaged.get()
    }
}

private final class SmartChargeSessionFactoryStub:
    PowerUISmartChargeSessionCreating
{
    private var sessions: [(any PowerUISmartChargeQuerying)?]
    private(set) var makeSessionCallCount = 0

    init(session: (any PowerUISmartChargeQuerying)?) {
        sessions = [session]
    }

    init(sessions: [(any PowerUISmartChargeQuerying)?]) {
        self.sessions = sessions
    }

    func makeSession() -> (any PowerUISmartChargeQuerying)? {
        makeSessionCallCount += 1
        guard sessions.count > 1 else {
            return sessions.first ?? nil
        }
        return sessions.removeFirst()
    }
}

private struct ChargingPolicyReaderStub: ChargingPolicyReading {
    let status: ObservedChargingPolicyStatus

    func readChargingPolicyStatus() -> ObservedChargingPolicyStatus {
        status
    }
}

private final class UptimeStub: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval

    init(value: TimeInterval) {
        storedValue = value
    }

    var value: TimeInterval {
        lock.withLock {
            storedValue
        }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            storedValue += interval
        }
    }
}

private enum StubError: Error {
    case unsupported
    case operationFailed
}

private extension Result where Failure == StubError {
    func getForManualSupport() throws -> Success {
        do {
            return try get()
        } catch StubError.unsupported {
            throw PowerUIQueryError.unsupported
        }
    }
}
