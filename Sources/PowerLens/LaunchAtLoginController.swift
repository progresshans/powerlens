import Foundation
import ServiceManagement

/// Manages the "launch at login" login-item registration using the modern
/// `SMAppService` API (macOS 13+). The published `isEnabled` reflects the
/// current registration so the Settings toggle stays in sync, including the
/// pending "requires approval" state after the user enables it.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false

    init() {
        refresh()
    }

    /// Re-reads the system registration status. Call when the Settings window
    /// appears in case the user changed the login item in System Settings.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("PowerLens launch-at-login update failed: \(error.localizedDescription)")
        }

        refresh()
    }
}
