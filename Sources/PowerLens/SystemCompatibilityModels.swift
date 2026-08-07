import Foundation

enum SystemCompatibilitySubsystem: String, Codable, CaseIterable, Sendable {
    case powerUI
}

enum SystemCompatibilityClassification: String, Codable, Sendable {
    case compatible
    case optionalCapabilityMissing
    case environmentUnavailable
    case transientFailure
    case contractMismatch
    case invalidResponse
}

enum SystemCompatibilityReasonCode: String, Codable, Sendable {
    case none
    case frameworkLoadFailed
    case clientClassMissing
    case methodMissing
    case methodSignatureMismatch
    case initializationFailed
    case queryFailed
    case invalidManualChargeLimit
}

/// A sanitized explanation of a system-interface observation.
///
/// This model deliberately excludes free-form error descriptions, raw sensor
/// readings, hardware identifiers, app identity, and filesystem paths. It is
/// safe to place in PowerLens' bounded local compatibility record.
struct SystemCompatibilityDiagnostic: Codable, Equatable, Sendable {
    let subsystem: SystemCompatibilitySubsystem
    let classification: SystemCompatibilityClassification
    let reason: SystemCompatibilityReasonCode
    let component: String?
    let expectedTypeEncoding: String?
    let actualTypeEncoding: String?
    let errorDomain: String?
    let errorCode: Int?
    let observedInteger: Int?

    init(
        subsystem: SystemCompatibilitySubsystem,
        classification: SystemCompatibilityClassification,
        reason: SystemCompatibilityReasonCode,
        component: String? = nil,
        expectedTypeEncoding: String? = nil,
        actualTypeEncoding: String? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        observedInteger: Int? = nil
    ) {
        self.subsystem = subsystem
        self.classification = classification
        self.reason = reason
        self.component = component
        self.expectedTypeEncoding = expectedTypeEncoding
        self.actualTypeEncoding = actualTypeEncoding
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.observedInteger = observedInteger
    }

    static let compatiblePowerUI = SystemCompatibilityDiagnostic(
        subsystem: .powerUI,
        classification: .compatible,
        reason: .none
    )
}

struct ChargingPolicyObservation: Equatable, Sendable {
    let status: ObservedChargingPolicyStatus
    let diagnostic: SystemCompatibilityDiagnostic
}
