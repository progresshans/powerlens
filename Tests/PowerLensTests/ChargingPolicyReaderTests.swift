import Foundation
import Testing
@testable import PowerLens

struct ChargingPolicyReaderTests {
    @Test
    func objectiveCBooleanReturnABIRecognizesSupportedEncodings() {
        #expect(
            ObjectiveCBooleanReturnABI(typeEncoding: "B") == .boolean
        )
        #expect(
            ObjectiveCBooleanReturnABI(typeEncoding: "c") == .signedChar
        )
    }

    @Test(arguments: ["C", "i", "q", "Q", ""])
    func objectiveCBooleanReturnABIRejectsUnsupportedEncodings(
        typeEncoding: String
    ) {
        #expect(
            ObjectiveCBooleanReturnABI(typeEncoding: typeEncoding) == nil
        )
    }

    @Test(arguments: [87, 93])
    func manualLimitUsesTheRuntimeValue(
        targetPercent: Int
    ) {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(targetPercent)],
            optimizedChargingEngaged: .success(true)
        )

        let status = ChargingPolicyStatusResolver.resolve(using: client).status
        let observation = ChargingPolicyStatusResolver.resolve(
            using: SmartChargeQueryStub(
                manualLimitEnabled: .success(true),
                manualLimits: [.success(targetPercent)],
                optimizedChargingEngaged: .success(true)
            )
        )

        #expect(status == .manualLimit(targetPercent: targetPercent))
        #expect(observation.diagnostic == .compatiblePowerUI)
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
                .status
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
                .status
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

        let observation = ChargingPolicyStatusResolver.resolve(using: client)

        #expect(observation.status == .optimizedCharging)
        #expect(
            observation.diagnostic.classification
                == .optionalCapabilityMissing
        )
        #expect(observation.diagnostic.reason == .methodMissing)
        #expect(
            observation.diagnostic.component
                == PowerUIRuntime.manualLimitEnabledContract.selectorName
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

        #expect(
            ChargingPolicyStatusResolver.resolve(using: client).status
                == .inactive
        )
    }

    @Test(arguments: [0, 101, 255])
    func invalidManualLimitIsUnavailable(targetPercent: Int) {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(true),
            manualLimits: [.success(targetPercent)],
            optimizedChargingEngaged: .success(false)
        )

        let observation = ChargingPolicyStatusResolver.resolve(using: client)

        #expect(observation.status == .unavailable)
        #expect(observation.diagnostic.classification == .invalidResponse)
        #expect(observation.diagnostic.reason == .invalidManualChargeLimit)
        #expect(observation.diagnostic.observedInteger == targetPercent)
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
            let observation = ChargingPolicyStatusResolver.resolve(using: client)
            #expect(observation.status == .unavailable)
            #expect(observation.diagnostic.classification == .transientFailure)
            #expect(observation.diagnostic.reason == .queryFailed)
        }
    }

    @Test
    func requiredOptimizedSelectorFailureIsAContractMismatch() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .success(false),
            manualLimits: [.success(80)],
            optimizedChargingEngaged: .failure(.unsupported)
        )

        let observation = ChargingPolicyStatusResolver.resolve(using: client)

        #expect(observation.status == .unavailable)
        #expect(observation.diagnostic.classification == .contractMismatch)
        #expect(observation.diagnostic.reason == .methodMissing)
        #expect(
            observation.diagnostic.component
                == PowerUIRuntime.optimizedChargingContract.selectorName
        )
    }

    @Test
    func incompatibleQuerySignatureIsAContractMismatch() {
        let client = SmartChargeQueryStub(
            manualLimitEnabled: .failure(.incompatibleSignature),
            manualLimits: [.success(80)],
            optimizedChargingEngaged: .success(false)
        )

        let observation = ChargingPolicyStatusResolver.resolve(using: client)

        #expect(observation.status == .unavailable)
        #expect(observation.diagnostic.classification == .contractMismatch)
        #expect(observation.diagnostic.reason == .methodSignatureMismatch)
        #expect(observation.diagnostic.actualTypeEncoding == "return=i;args=@,:,^@")
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
    func failedSessionCreationReasonSurvivesBackoff() {
        let failure = PowerUISessionCreationError.incompatibleSignature(
            selector: "initWithClientName:",
            expected: "return=@;args=@,:,@",
            actual: "return=v;args=@,:,@"
        )
        let factory = SmartChargeSessionFactoryStub(
            results: [.failure(failure)]
        )
        let reader = PowerUIChargingPolicyReader(sessionFactory: factory)

        let first = reader.readChargingPolicyObservation()
        let second = reader.readChargingPolicyObservation()

        #expect(first == second)
        #expect(first.status == .unavailable)
        #expect(first.diagnostic.classification == .contractMismatch)
        #expect(first.diagnostic.reason == .methodSignatureMismatch)
        #expect(first.diagnostic.actualTypeEncoding == "return=v;args=@,:,@")
        #expect(factory.makeSessionCallCount == 1)
    }

    @Test
    func sessionCreationFailuresHaveStableSanitizedClassifications() {
        let cases: [(PowerUISessionCreationError, SystemCompatibilityClassification, SystemCompatibilityReasonCode)] = [
            (.frameworkLoadFailed, .contractMismatch, .frameworkLoadFailed),
            (.clientClassMissing, .contractMismatch, .clientClassMissing),
            (
                .methodMissing(selector: "alloc"),
                .contractMismatch,
                .methodMissing
            ),
            (
                .incompatibleSignature(
                    selector: "alloc",
                    expected: "return=@;args=@,:",
                    actual: "return=v;args=@,:"
                ),
                .contractMismatch,
                .methodSignatureMismatch
            ),
            (
                .initializationFailed,
                .environmentUnavailable,
                .initializationFailed
            ),
        ]

        for (error, classification, reason) in cases {
            #expect(error.diagnostic.classification == classification)
            #expect(error.diagnostic.reason == reason)
            #expect(error.diagnostic.errorDomain == nil)
            #expect(error.diagnostic.errorCode == nil)
        }
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
        let recovered = reader.readChargingPolicyObservation()
        #expect(recovered.status == .manualLimit(targetPercent: 87))
        #expect(recovered.diagnostic == .compatiblePowerUI)
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
    func compatibilityDiagnosticSupportsCodableRoundTrips() throws {
        let diagnostic = SystemCompatibilityDiagnostic(
            subsystem: .powerUI,
            classification: .contractMismatch,
            reason: .methodSignatureMismatch,
            component: "isOBCEngaged:",
            expectedTypeEncoding: "return=B|c;args=@,:,^@",
            actualTypeEncoding: "return=i;args=@,:,^@"
        )

        let data = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(
            SystemCompatibilityDiagnostic.self,
            from: data
        )

        #expect(decoded == diagnostic)
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
        return try manualLimitEnabled.getForPowerUI(
            selector: PowerUIRuntime.manualLimitEnabledContract.selectorName
        )
    }

    func manualChargeLimit() throws -> Int {
        calls.append(.manualLimit)
        guard !manualLimits.isEmpty else {
            throw StubError.operationFailed
        }
        return try manualLimits.removeFirst().getForPowerUI(
            selector: PowerUIRuntime.manualLimitContract.selectorName
        )
    }

    func isOptimizedChargingEngaged() throws -> Bool {
        calls.append(.optimizedChargingEngaged)
        return try optimizedChargingEngaged.getForPowerUI(
            selector: PowerUIRuntime.optimizedChargingContract.selectorName
        )
    }
}

private final class SmartChargeSessionFactoryStub:
    PowerUISmartChargeSessionCreating
{
    private var sessions: [Result<
        any PowerUISmartChargeQuerying,
        PowerUISessionCreationError
    >]
    private(set) var makeSessionCallCount = 0

    init(session: (any PowerUISmartChargeQuerying)?) {
        sessions = [session.map(Result.success)
            ?? .failure(.frameworkLoadFailed)]
    }

    init(sessions: [(any PowerUISmartChargeQuerying)?]) {
        self.sessions = sessions.map {
            $0.map(Result.success) ?? .failure(.frameworkLoadFailed)
        }
    }

    init(results: [Result<
        any PowerUISmartChargeQuerying,
        PowerUISessionCreationError
    >]) {
        sessions = results
    }

    func makeSession() -> Result<
        any PowerUISmartChargeQuerying,
        PowerUISessionCreationError
    > {
        makeSessionCallCount += 1
        guard sessions.count > 1 else {
            return sessions.first ?? .failure(.frameworkLoadFailed)
        }
        return sessions.removeFirst()
    }
}

private struct ChargingPolicyReaderStub: ChargingPolicyReading {
    let status: ObservedChargingPolicyStatus

    func readChargingPolicyObservation() -> ChargingPolicyObservation {
        ChargingPolicyObservation(
            status: status,
            diagnostic: .compatiblePowerUI
        )
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
    case incompatibleSignature
    case operationFailed
}

private extension Result where Failure == StubError {
    func getForPowerUI(selector: String) throws -> Success {
        do {
            return try get()
        } catch StubError.unsupported {
            throw PowerUIQueryError.unsupported(
                selector: selector
            )
        } catch StubError.incompatibleSignature {
            throw PowerUIQueryError.incompatibleSignature(
                selector: selector,
                expected: "return=expected;args=@,:,^@",
                actual: "return=i;args=@,:,^@"
            )
        } catch StubError.operationFailed {
            throw PowerUIQueryError.operationFailed(
                selector: selector,
                NSError(
                    domain: "PowerLensTests.PowerUI",
                    code: 17
                )
            )
        }
    }
}
