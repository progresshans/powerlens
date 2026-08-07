import Darwin
import Foundation
import ObjectiveC

/// Reads the charging policy currently applied by macOS without changing it.
///
/// PowerUI is a private framework, so all dependencies are discovered and
/// validated at runtime. Unsafe or unreadable state remains user-facing
/// `.unavailable`; the reason is carried separately for local diagnostics and
/// compatibility CI.
struct PowerUIChargingPolicyReader: ChargingPolicyReading, Sendable {
    private static let sharedSessionCache = PowerUISmartChargeSessionCache(
        factory: DynamicPowerUISmartChargeSessionFactory()
    )

    private let sessionCache: PowerUISmartChargeSessionCache

    init() {
        sessionCache = Self.sharedSessionCache
    }

    init(
        sessionFactory: any PowerUISmartChargeSessionCreating,
        retryInterval: TimeInterval = 60,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        sessionCache = PowerUISmartChargeSessionCache(
            factory: sessionFactory,
            retryInterval: retryInterval,
            uptime: uptime
        )
    }

    func readChargingPolicyObservation() -> ChargingPolicyObservation {
        sessionCache.readChargingPolicyObservation()
    }
}

protocol PowerUISmartChargeQuerying: AnyObject {
    func isManualChargeLimitEnabled() throws -> Bool
    func manualChargeLimit() throws -> Int
    func isOptimizedChargingEngaged() throws -> Bool
}

protocol PowerUISmartChargeSessionCreating: AnyObject {
    func makeSession() -> Result<
        any PowerUISmartChargeQuerying,
        PowerUISessionCreationError
    >
}

enum ChargingPolicyStatusResolver {
    static func resolve(
        using client: any PowerUISmartChargeQuerying
    ) -> ChargingPolicyObservation {
        let isManualLimitEnabled: Bool
        do {
            isManualLimitEnabled = try client.isManualChargeLimitEnabled()
        } catch let error as PowerUIQueryError {
            switch error {
            case .unsupported:
                // Manual charge limits are not present on every supported Mac.
                // Optimized charging can still be observed independently.
                return resolveOptimizedCharging(
                    using: client,
                    successDiagnostic: error.diagnostic(
                        classification: .optionalCapabilityMissing
                    )
                )
            case .incompatibleSignature, .operationFailed:
                return unavailableObservation(for: error)
            }
        } catch {
            return unavailableObservation(
                for: error,
                component: PowerUIRuntime.manualLimitEnabledContract.selectorName
            )
        }

        if isManualLimitEnabled {
            do {
                let targetPercent = try client.manualChargeLimit()
                guard (1...100).contains(targetPercent) else {
                    return ChargingPolicyObservation(
                        status: .unavailable,
                        diagnostic: SystemCompatibilityDiagnostic(
                            subsystem: .powerUI,
                            classification: .invalidResponse,
                            reason: .invalidManualChargeLimit,
                            component: PowerUIRuntime.manualLimitContract.selectorName,
                            observedInteger: targetPercent
                        )
                    )
                }
                return ChargingPolicyObservation(
                    status: .manualLimit(targetPercent: targetPercent),
                    diagnostic: .compatiblePowerUI
                )
            } catch let error as PowerUIQueryError {
                return unavailableObservation(for: error)
            } catch {
                return unavailableObservation(
                    for: error,
                    component: PowerUIRuntime.manualLimitContract.selectorName
                )
            }
        }

        return resolveOptimizedCharging(using: client)
    }

    private static func resolveOptimizedCharging(
        using client: any PowerUISmartChargeQuerying,
        successDiagnostic: SystemCompatibilityDiagnostic = .compatiblePowerUI
    ) -> ChargingPolicyObservation {
        do {
            return ChargingPolicyObservation(
                status: try client.isOptimizedChargingEngaged()
                    ? .optimizedCharging
                    : .inactive,
                diagnostic: successDiagnostic
            )
        } catch let error as PowerUIQueryError {
            return unavailableObservation(for: error)
        } catch {
            return unavailableObservation(
                for: error,
                component: PowerUIRuntime.optimizedChargingContract.selectorName
            )
        }
    }

    private static func unavailableObservation(
        for error: PowerUIQueryError
    ) -> ChargingPolicyObservation {
        ChargingPolicyObservation(
            status: .unavailable,
            diagnostic: error.diagnostic()
        )
    }

    private static func unavailableObservation(
        for error: any Error,
        component: String
    ) -> ChargingPolicyObservation {
        let error = error as NSError
        return ChargingPolicyObservation(
            status: .unavailable,
            diagnostic: SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: .transientFailure,
                reason: .queryFailed,
                component: component,
                errorDomain: error.domain,
                errorCode: error.code
            )
        )
    }
}

enum PowerUIQueryError: Error {
    /// The selector is absent because this policy API is not available.
    case unsupported(selector: String)

    /// A selector exists, but calling it with the known ABI would be unsafe.
    case incompatibleSignature(
        selector: String,
        expected: String,
        actual: String?
    )

    /// PowerUI completed the query with an error.
    case operationFailed(selector: String, NSError)

    func diagnostic(
        classification: SystemCompatibilityClassification? = nil
    ) -> SystemCompatibilityDiagnostic {
        switch self {
        case .unsupported(let selector):
            return SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: classification ?? .contractMismatch,
                reason: .methodMissing,
                component: selector
            )
        case let .incompatibleSignature(selector, expected, actual):
            return SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: classification ?? .contractMismatch,
                reason: .methodSignatureMismatch,
                component: selector,
                expectedTypeEncoding: expected,
                actualTypeEncoding: actual
            )
        case let .operationFailed(selector, error):
            return SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: classification ?? .transientFailure,
                reason: .queryFailed,
                component: selector,
                errorDomain: error.domain,
                errorCode: error.code
            )
        }
    }
}

enum PowerUISessionCreationError: Error, Equatable, Sendable {
    case frameworkLoadFailed
    case clientClassMissing
    case methodMissing(selector: String)
    case incompatibleSignature(
        selector: String,
        expected: String,
        actual: String?
    )
    case initializationFailed

    var diagnostic: SystemCompatibilityDiagnostic {
        switch self {
        case .frameworkLoadFailed:
            SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: .contractMismatch,
                reason: .frameworkLoadFailed,
                component: "PowerUI.framework"
            )
        case .clientClassMissing:
            SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: .contractMismatch,
                reason: .clientClassMissing,
                component: PowerUIRuntime.clientClassName
            )
        case .methodMissing(let selector):
            SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: .contractMismatch,
                reason: .methodMissing,
                component: selector
            )
        case let .incompatibleSignature(selector, expected, actual):
            SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: .contractMismatch,
                reason: .methodSignatureMismatch,
                component: selector,
                expectedTypeEncoding: expected,
                actualTypeEncoding: actual
            )
        case .initializationFailed:
            SystemCompatibilityDiagnostic(
                subsystem: .powerUI,
                classification: .environmentUnavailable,
                reason: .initializationFailed,
                component: PowerUIRuntime.initializeContract.selectorName
            )
        }
    }
}

enum ObjectiveCBooleanReturnABI: Equatable, Sendable {
    case boolean
    case signedChar

    init?(typeEncoding: String) {
        switch typeEncoding {
        case "B":
            self = .boolean
        case "c":
            self = .signedChar
        default:
            return nil
        }
    }
}

enum ObjectiveCMethodDispatch: String, Codable, Sendable {
    case classMethod
    case instanceMethod
}

struct ObjectiveCMethodContract: Sendable {
    let selectorName: String
    let dispatch: ObjectiveCMethodDispatch
    let allowedReturnTypes: [String]
    let argumentTypes: [String]

    var selector: Selector {
        NSSelectorFromString(selectorName)
    }

    var expectedTypeEncoding: String {
        "return=\(allowedReturnTypes.joined(separator: "|"));args=\(argumentTypes.joined(separator: ","))"
    }
}

enum ObjectiveCMethodContractInspection: Equatable, Sendable {
    case missing
    case compatible(actualTypeEncoding: String)
    case incompatible(actualTypeEncoding: String?)
}

enum ObjectiveCMethodInspector {
    static func method(
        on objectClass: AnyClass,
        contract: ObjectiveCMethodContract
    ) -> Method? {
        switch contract.dispatch {
        case .classMethod:
            class_getClassMethod(objectClass, contract.selector)
        case .instanceMethod:
            class_getInstanceMethod(objectClass, contract.selector)
        }
    }

    static func inspect(
        on objectClass: AnyClass,
        contract: ObjectiveCMethodContract
    ) -> ObjectiveCMethodContractInspection {
        guard let method = method(on: objectClass, contract: contract) else {
            return .missing
        }

        let actual = typeEncoding(of: method)
        guard contract.allowedReturnTypes.contains(returnType(of: method) ?? ""),
              argumentTypes(of: method) == contract.argumentTypes
        else {
            return .incompatible(actualTypeEncoding: actual)
        }

        return .compatible(actualTypeEncoding: actual ?? "unknown")
    }

    static func returnType(of method: Method) -> String? {
        copiedType(method_copyReturnType(method))
    }

    static func argumentTypes(of method: Method) -> [String]? {
        let count = Int(method_getNumberOfArguments(method))
        var result: [String] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            guard let value = copiedType(
                method_copyArgumentType(method, UInt32(index))
            ) else {
                return nil
            }
            result.append(value)
        }
        return result
    }

    static func typeEncoding(of method: Method) -> String? {
        guard let returnType = returnType(of: method),
              let argumentTypes = argumentTypes(of: method)
        else {
            return nil
        }
        return "return=\(returnType);args=\(argumentTypes.joined(separator: ","))"
    }

    private static func copiedType(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> String? {
        guard let pointer else {
            return nil
        }
        defer {
            free(pointer)
        }
        return String(cString: pointer)
    }
}

enum PowerUIRuntime {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    static let clientClassName = "PowerUISmartChargeClient"
    static let clientName = "PowerLens"

    static let allocateContract = ObjectiveCMethodContract(
        selectorName: "alloc",
        dispatch: .classMethod,
        allowedReturnTypes: ["@"],
        argumentTypes: ["@", ":"]
    )
    static let initializeContract = ObjectiveCMethodContract(
        selectorName: "initWithClientName:",
        dispatch: .instanceMethod,
        allowedReturnTypes: ["@"],
        argumentTypes: ["@", ":", "@"]
    )
    static let manualLimitEnabledContract = ObjectiveCMethodContract(
        selectorName: "isMCLCurrentlyEnabled:",
        dispatch: .instanceMethod,
        allowedReturnTypes: ["Q"],
        argumentTypes: ["@", ":", "^@"]
    )
    static let manualLimitContract = ObjectiveCMethodContract(
        selectorName: "getMCLLimitWithError:",
        dispatch: .instanceMethod,
        allowedReturnTypes: ["C"],
        argumentTypes: ["@", ":", "^@"]
    )
    static let optimizedChargingContract = ObjectiveCMethodContract(
        selectorName: "isOBCEngaged:",
        dispatch: .instanceMethod,
        allowedReturnTypes: ["B", "c"],
        argumentTypes: ["@", ":", "^@"]
    )

    static let contracts = [
        allocateContract,
        initializeContract,
        manualLimitEnabledContract,
        manualLimitContract,
        optimizedChargingContract,
    ]
}

/// Owns the process-long runtime session used by a reader.
///
/// Calls are serialized because the private client's thread-safety contract is
/// unknown. Only session creation is cached; every read performs fresh queries
/// so changes made in System Settings appear without restarting PowerLens.
private final class PowerUISmartChargeSessionCache: @unchecked Sendable {
    private enum State {
        case uninitialized
        case available(any PowerUISmartChargeQuerying)
        case unavailable(
            error: PowerUISessionCreationError,
            retryAfterUptime: TimeInterval
        )
    }

    private let lock = NSLock()
    private let factory: any PowerUISmartChargeSessionCreating
    private let retryInterval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private var state = State.uninitialized

    init(
        factory: any PowerUISmartChargeSessionCreating,
        retryInterval: TimeInterval = 60,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.factory = factory
        self.retryInterval = max(retryInterval, 0)
        self.uptime = uptime
    }

    func readChargingPolicyObservation() -> ChargingPolicyObservation {
        lock.lock()
        defer {
            lock.unlock()
        }

        let client: any PowerUISmartChargeQuerying
        switch state {
        case .uninitialized:
            switch factory.makeSession() {
            case .success(let newClient):
                state = .available(newClient)
                client = newClient
            case .failure(let error):
                state = .unavailable(
                    error: error,
                    retryAfterUptime: uptime() + retryInterval
                )
                return Self.unavailableObservation(for: error)
            }
        case .available(let existingClient):
            client = existingClient
        case let .unavailable(error, retryAfterUptime):
            guard uptime() >= retryAfterUptime else {
                return Self.unavailableObservation(for: error)
            }
            switch factory.makeSession() {
            case .success(let newClient):
                state = .available(newClient)
                client = newClient
            case .failure(let newError):
                state = .unavailable(
                    error: newError,
                    retryAfterUptime: uptime() + retryInterval
                )
                return Self.unavailableObservation(for: newError)
            }
        }

        return autoreleasepool {
            ChargingPolicyStatusResolver.resolve(using: client)
        }
    }

    private static func unavailableObservation(
        for error: PowerUISessionCreationError
    ) -> ChargingPolicyObservation {
        ChargingPolicyObservation(
            status: .unavailable,
            diagnostic: error.diagnostic
        )
    }
}

private final class DynamicPowerUISmartChargeSessionFactory:
    PowerUISmartChargeSessionCreating
{
    func makeSession() -> Result<
        any PowerUISmartChargeQuerying,
        PowerUISessionCreationError
    > {
        guard let frameworkHandle = dlopen(
            PowerUIRuntime.frameworkPath,
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            return .failure(.frameworkLoadFailed)
        }

        switch DynamicPowerUISmartChargeClient.make(
            frameworkHandle: frameworkHandle
        ) {
        case .success(let client):
            return .success(client)
        case .failure(let error):
            dlclose(frameworkHandle)
            return .failure(error)
        }
    }
}

private final class DynamicPowerUISmartChargeClient:
    PowerUISmartChargeQuerying
{
    private typealias AllocateFunction =
        @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
    private typealias InitializeFunction =
        @convention(c) (
            UnsafeMutableRawPointer,
            Selector,
            NSString
        ) -> Unmanaged<AnyObject>?
    private typealias UnsignedIntegerQueryFunction =
        @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> UInt
    private typealias UnsignedByteQueryFunction =
        @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> UInt8
    private typealias BooleanQueryFunction =
        @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Bool
    private typealias SignedCharQueryFunction =
        @convention(c) (
            AnyObject,
            Selector,
            AutoreleasingUnsafeMutablePointer<NSError?>?
        ) -> Int8

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var object: NSObject?
    private let objectClass: AnyClass

    private init(
        frameworkHandle: UnsafeMutableRawPointer,
        object: NSObject,
        objectClass: AnyClass
    ) {
        self.frameworkHandle = frameworkHandle
        self.object = object
        self.objectClass = objectClass
    }

    deinit {
        // Release the framework-owned object before balancing dlopen.
        object = nil
        if let frameworkHandle {
            dlclose(frameworkHandle)
            self.frameworkHandle = nil
        }
    }

    static func make(
        frameworkHandle: UnsafeMutableRawPointer
    ) -> Result<DynamicPowerUISmartChargeClient, PowerUISessionCreationError> {
        guard let clientClass = NSClassFromString(
            PowerUIRuntime.clientClassName
        ) else {
            return .failure(.clientClassMissing)
        }

        let allocateContract = PowerUIRuntime.allocateContract
        guard let allocateMethod = try? validatedMethod(
            on: clientClass,
            contract: allocateContract
        ) else {
            return .failure(validationError(
                on: clientClass,
                contract: allocateContract
            ))
        }

        let initializeContract = PowerUIRuntime.initializeContract
        guard let initializeMethod = try? validatedMethod(
            on: clientClass,
            contract: initializeContract
        ) else {
            return .failure(validationError(
                on: clientClass,
                contract: initializeContract
            ))
        }

        let allocate = unsafeBitCast(
            method_getImplementation(allocateMethod),
            to: AllocateFunction.self
        )
        let initialize = unsafeBitCast(
            method_getImplementation(initializeMethod),
            to: InitializeFunction.self
        )
        let allocatedObject = allocate(
            clientClass,
            allocateContract.selector
        ).toOpaque()

        guard let initializedObject = initialize(
            allocatedObject,
            initializeContract.selector,
            PowerUIRuntime.clientName as NSString
        )?.takeRetainedValue() as? NSObject,
              let initializedClass = object_getClass(initializedObject)
        else {
            return .failure(.initializationFailed)
        }

        return .success(DynamicPowerUISmartChargeClient(
            frameworkHandle: frameworkHandle,
            object: initializedObject,
            objectClass: initializedClass
        ))
    }

    func isManualChargeLimitEnabled() throws -> Bool {
        let contract = PowerUIRuntime.manualLimitEnabledContract
        let method = try Self.validatedQueryMethod(
            on: objectClass,
            contract: contract
        )
        let query = unsafeBitCast(
            method_getImplementation(method),
            to: UnsignedIntegerQueryFunction.self
        )

        var error: NSError?
        guard let object else {
            throw PowerUIQueryError.unsupported(
                selector: contract.selectorName
            )
        }
        let rawValue = query(object, contract.selector, &error)
        try throwIfNeeded(error, selector: contract.selectorName)
        return rawValue != 0
    }

    func manualChargeLimit() throws -> Int {
        let contract = PowerUIRuntime.manualLimitContract
        let method = try Self.validatedQueryMethod(
            on: objectClass,
            contract: contract
        )
        let query = unsafeBitCast(
            method_getImplementation(method),
            to: UnsignedByteQueryFunction.self
        )

        var error: NSError?
        guard let object else {
            throw PowerUIQueryError.unsupported(
                selector: contract.selectorName
            )
        }
        let rawValue = query(object, contract.selector, &error)
        try throwIfNeeded(error, selector: contract.selectorName)
        return Int(rawValue)
    }

    func isOptimizedChargingEngaged() throws -> Bool {
        let contract = PowerUIRuntime.optimizedChargingContract
        guard let object else {
            throw PowerUIQueryError.unsupported(
                selector: contract.selectorName
            )
        }
        let method = try Self.validatedQueryMethod(
            on: objectClass,
            contract: contract
        )
        let returnType = ObjectiveCMethodInspector.returnType(of: method)
        guard let returnType,
              let returnABI = ObjectiveCBooleanReturnABI(
                  typeEncoding: returnType
              )
        else {
            throw PowerUIQueryError.incompatibleSignature(
                selector: contract.selectorName,
                expected: contract.expectedTypeEncoding,
                actual: ObjectiveCMethodInspector.typeEncoding(of: method)
            )
        }
        let implementation = method_getImplementation(method)

        switch returnABI {
        case .boolean:
            let query = unsafeBitCast(
                implementation,
                to: BooleanQueryFunction.self
            )
            var error: NSError?
            let result = query(object, contract.selector, &error)
            try throwIfNeeded(error, selector: contract.selectorName)
            return result
        case .signedChar:
            let query = unsafeBitCast(
                implementation,
                to: SignedCharQueryFunction.self
            )
            var error: NSError?
            let rawValue = query(object, contract.selector, &error)
            try throwIfNeeded(error, selector: contract.selectorName)
            return rawValue != 0
        }
    }

    private func throwIfNeeded(
        _ error: NSError?,
        selector: String
    ) throws {
        if let error {
            throw PowerUIQueryError.operationFailed(selector: selector, error)
        }
    }

    private static func validatedQueryMethod(
        on objectClass: AnyClass,
        contract: ObjectiveCMethodContract
    ) throws -> Method {
        do {
            return try validatedMethod(on: objectClass, contract: contract)
        } catch PowerUISessionCreationError.methodMissing {
            throw PowerUIQueryError.unsupported(selector: contract.selectorName)
        } catch let PowerUISessionCreationError.incompatibleSignature(
            selector,
            expected,
            actual
        ) {
            throw PowerUIQueryError.incompatibleSignature(
                selector: selector,
                expected: expected,
                actual: actual
            )
        } catch {
            throw PowerUIQueryError.unsupported(selector: contract.selectorName)
        }
    }

    private static func validatedMethod(
        on objectClass: AnyClass,
        contract: ObjectiveCMethodContract
    ) throws -> Method {
        guard let method = ObjectiveCMethodInspector.method(
            on: objectClass,
            contract: contract
        ) else {
            throw PowerUISessionCreationError.methodMissing(
                selector: contract.selectorName
            )
        }

        guard case .compatible = ObjectiveCMethodInspector.inspect(
            on: objectClass,
            contract: contract
        ) else {
            throw PowerUISessionCreationError.incompatibleSignature(
                selector: contract.selectorName,
                expected: contract.expectedTypeEncoding,
                actual: ObjectiveCMethodInspector.typeEncoding(of: method)
            )
        }
        return method
    }

    private static func validationError(
        on objectClass: AnyClass,
        contract: ObjectiveCMethodContract
    ) -> PowerUISessionCreationError {
        switch ObjectiveCMethodInspector.inspect(
            on: objectClass,
            contract: contract
        ) {
        case .missing:
            .methodMissing(selector: contract.selectorName)
        case .incompatible(let actualTypeEncoding):
            .incompatibleSignature(
                selector: contract.selectorName,
                expected: contract.expectedTypeEncoding,
                actual: actualTypeEncoding
            )
        case .compatible:
            // This path is only reached after a failed validation attempt. If
            // runtime metadata changed between checks, fail closed.
            .incompatibleSignature(
                selector: contract.selectorName,
                expected: contract.expectedTypeEncoding,
                actual: nil
            )
        }
    }
}
