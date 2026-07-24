import Darwin
import Foundation
import ObjectiveC

/// Reads the charging policy currently applied by macOS without changing it.
///
/// PowerUI is a private framework, so all of its dependencies are discovered
/// and validated at runtime. A missing or incompatible dependency is a
/// supported condition and produces `.unavailable`.
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

    func readChargingPolicyStatus() -> ObservedChargingPolicyStatus {
        sessionCache.readChargingPolicyStatus()
    }
}

protocol PowerUISmartChargeQuerying: AnyObject {
    func isManualChargeLimitEnabled() throws -> Bool
    func manualChargeLimit() throws -> Int
    func isOptimizedChargingEngaged() throws -> Bool
}

protocol PowerUISmartChargeSessionCreating: AnyObject {
    func makeSession() -> (any PowerUISmartChargeQuerying)?
}

enum ChargingPolicyStatusResolver {
    static func resolve(
        using client: any PowerUISmartChargeQuerying
    ) -> ObservedChargingPolicyStatus {
        let isManualLimitEnabled: Bool
        do {
            isManualLimitEnabled = try client.isManualChargeLimitEnabled()
        } catch PowerUIQueryError.unsupported {
            // Manual charge limits are not present on every supported macOS
            // release. Optimized charging can still be observed independently.
            return resolveOptimizedCharging(using: client)
        } catch {
            return .unavailable
        }

        if isManualLimitEnabled {
            do {
                let targetPercent = try client.manualChargeLimit()
                guard (1...100).contains(targetPercent) else {
                    return .unavailable
                }
                return .manualLimit(targetPercent: targetPercent)
            } catch {
                return .unavailable
            }
        }

        return resolveOptimizedCharging(using: client)
    }

    private static func resolveOptimizedCharging(
        using client: any PowerUISmartChargeQuerying
    ) -> ObservedChargingPolicyStatus {
        do {
            return try client.isOptimizedChargingEngaged()
                ? .optimizedCharging
                : .inactive
        } catch {
            return .unavailable
        }
    }
}

enum PowerUIQueryError: Error {
    /// The selector is absent because this policy API is not available.
    case unsupported

    /// A selector exists, but calling it with the known ABI would be unsafe.
    case incompatibleSignature

    /// PowerUI completed the query with an error.
    case operationFailed(NSError)
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

/// Owns the process-long runtime session used by a reader.
///
/// Calls are serialized because the private client's thread-safety contract is
/// unknown. Only session creation is cached; every read performs fresh queries
/// so changes made in System Settings appear without restarting PowerLens.
private final class PowerUISmartChargeSessionCache: @unchecked Sendable {
    private enum State {
        case uninitialized
        case available(any PowerUISmartChargeQuerying)
        case unavailable(retryAfterUptime: TimeInterval)
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

    func readChargingPolicyStatus() -> ObservedChargingPolicyStatus {
        lock.lock()
        defer {
            lock.unlock()
        }

        let client: any PowerUISmartChargeQuerying
        switch state {
        case .uninitialized:
            guard let newClient = factory.makeSession() else {
                state = .unavailable(
                    retryAfterUptime: uptime() + retryInterval
                )
                return .unavailable
            }
            state = .available(newClient)
            client = newClient
        case .available(let existingClient):
            client = existingClient
        case .unavailable(let retryAfterUptime):
            guard uptime() >= retryAfterUptime else {
                return .unavailable
            }
            guard let newClient = factory.makeSession() else {
                state = .unavailable(
                    retryAfterUptime: uptime() + retryInterval
                )
                return .unavailable
            }
            state = .available(newClient)
            client = newClient
        }

        return autoreleasepool {
            ChargingPolicyStatusResolver.resolve(using: client)
        }
    }
}

private enum PowerUIRuntime {
    static let frameworkPath =
        "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    static let clientClassName = "PowerUISmartChargeClient"
    static let clientName = "PowerLens"

    static let allocateSelector = NSSelectorFromString("alloc")
    static let initializeSelector = NSSelectorFromString("initWithClientName:")
    static let manualLimitEnabledSelector =
        NSSelectorFromString("isMCLCurrentlyEnabled:")
    static let manualLimitSelector =
        NSSelectorFromString("getMCLLimitWithError:")
    static let optimizedChargingEngagedSelector =
        NSSelectorFromString("isOBCEngaged:")
}

private final class DynamicPowerUISmartChargeSessionFactory:
    PowerUISmartChargeSessionCreating
{
    func makeSession() -> (any PowerUISmartChargeQuerying)? {
        guard let frameworkHandle = dlopen(
            PowerUIRuntime.frameworkPath,
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            return nil
        }

        guard let client = DynamicPowerUISmartChargeClient.make(
            frameworkHandle: frameworkHandle
        ) else {
            dlclose(frameworkHandle)
            return nil
        }

        return client
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
    ) -> DynamicPowerUISmartChargeClient? {
        guard let clientClass = NSClassFromString(
                  PowerUIRuntime.clientClassName
              ),
              let allocateMethod = class_getClassMethod(
                  clientClass,
                  PowerUIRuntime.allocateSelector
              ),
              hasExactSignature(
                  allocateMethod,
                  returnType: "@",
                  argumentTypes: ["@", ":"]
              ),
              let initializeMethod = class_getInstanceMethod(
                  clientClass,
                  PowerUIRuntime.initializeSelector
              ),
              hasExactSignature(
                  initializeMethod,
                  returnType: "@",
                  argumentTypes: ["@", ":", "@"]
              )
        else {
            return nil
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
            PowerUIRuntime.allocateSelector
        ).toOpaque()

        guard let initializedObject = initialize(
            allocatedObject,
            PowerUIRuntime.initializeSelector,
            PowerUIRuntime.clientName as NSString
        )?.takeRetainedValue() as? NSObject,
              let initializedClass = object_getClass(initializedObject)
        else {
            return nil
        }

        return DynamicPowerUISmartChargeClient(
            frameworkHandle: frameworkHandle,
            object: initializedObject,
            objectClass: initializedClass
        )
    }

    func isManualChargeLimitEnabled() throws -> Bool {
        let selector = PowerUIRuntime.manualLimitEnabledSelector
        let method = try queryMethod(
            selector,
            returnType: "Q"
        )
        let query = unsafeBitCast(
            method_getImplementation(method),
            to: UnsignedIntegerQueryFunction.self
        )

        var error: NSError?
        guard let object else {
            throw PowerUIQueryError.unsupported
        }
        let rawValue = query(object, selector, &error)
        try throwIfNeeded(error)
        return rawValue != 0
    }

    func manualChargeLimit() throws -> Int {
        let selector = PowerUIRuntime.manualLimitSelector
        let method = try queryMethod(
            selector,
            returnType: "C"
        )
        let query = unsafeBitCast(
            method_getImplementation(method),
            to: UnsignedByteQueryFunction.self
        )

        var error: NSError?
        guard let object else {
            throw PowerUIQueryError.unsupported
        }
        let rawValue = query(object, selector, &error)
        try throwIfNeeded(error)
        return Int(rawValue)
    }

    func isOptimizedChargingEngaged() throws -> Bool {
        let selector = PowerUIRuntime.optimizedChargingEngagedSelector
        guard let object else {
            throw PowerUIQueryError.unsupported
        }
        let (method, returnABI) = try booleanQueryMethod(selector)
        let implementation = method_getImplementation(method)

        switch returnABI {
        case .boolean:
            let query = unsafeBitCast(
                implementation,
                to: BooleanQueryFunction.self
            )
            var error: NSError?
            let result = query(object, selector, &error)
            try throwIfNeeded(error)
            return result
        case .signedChar:
            let query = unsafeBitCast(
                implementation,
                to: SignedCharQueryFunction.self
            )
            var error: NSError?
            let rawValue = query(object, selector, &error)
            try throwIfNeeded(error)
            return rawValue != 0
        }
    }

    private func queryMethod(
        _ selector: Selector,
        returnType: String
    ) throws -> Method {
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            throw PowerUIQueryError.unsupported
        }
        guard Self.hasExactSignature(
            method,
            returnType: returnType,
            argumentTypes: ["@", ":", "^@"]
        ) else {
            throw PowerUIQueryError.incompatibleSignature
        }
        return method
    }

    private func booleanQueryMethod(
        _ selector: Selector
    ) throws -> (Method, ObjectiveCBooleanReturnABI) {
        guard let method = class_getInstanceMethod(objectClass, selector) else {
            throw PowerUIQueryError.unsupported
        }
        guard Self.hasExactArgumentTypes(
            method,
            argumentTypes: ["@", ":", "^@"]
        ),
              let returnType = Self.copiedType(
                  method_copyReturnType(method)
              ),
              let returnABI = ObjectiveCBooleanReturnABI(
                  typeEncoding: returnType
              )
        else {
            throw PowerUIQueryError.incompatibleSignature
        }
        return (method, returnABI)
    }

    private func throwIfNeeded(_ error: NSError?) throws {
        if let error {
            throw PowerUIQueryError.operationFailed(error)
        }
    }

    private static func hasExactSignature(
        _ method: Method,
        returnType: String,
        argumentTypes: [String]
    ) -> Bool {
        guard copiedType(method_copyReturnType(method)) == returnType,
              hasExactArgumentTypes(
                  method,
                  argumentTypes: argumentTypes
              )
        else {
            return false
        }

        return true
    }

    private static func hasExactArgumentTypes(
        _ method: Method,
        argumentTypes: [String]
    ) -> Bool {
        guard method_getNumberOfArguments(method) == argumentTypes.count else {
            return false
        }

        return argumentTypes.indices.allSatisfy { index in
            copiedType(method_copyArgumentType(method, UInt32(index)))
                == argumentTypes[index]
        }
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
