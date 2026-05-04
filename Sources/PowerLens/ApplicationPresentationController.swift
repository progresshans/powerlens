import AppKit
import Foundation

@MainActor
final class ApplicationPresentationController {
    private var currentActivationPolicy: NSApplication.ActivationPolicy?
    private var temporaryRegularPolicyExpiration: Date?

    func applyActivationPolicy(force: Bool = false, hasManagedWindow: Bool) {
        let desiredPolicy: NSApplication.ActivationPolicy =
            DockIconPreference.current || shouldHoldTemporaryRegularPolicy || hasManagedWindow
                ? .regular
                : .accessory

        guard force || desiredPolicy != currentActivationPolicy else {
            return
        }

        setActivationPolicy(desiredPolicy)

        if desiredPolicy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func prepareForWindowPresentation(reapplyActivationPolicy: @escaping () -> Void) {
        temporaryRegularPolicyExpiration = Date().addingTimeInterval(1.5)
        setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            reapplyActivationPolicy()
        }
    }

    func clearTemporaryRegularPolicy() {
        temporaryRegularPolicyExpiration = nil
    }

    private func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard policy != currentActivationPolicy else {
            return
        }

        NSApp.setActivationPolicy(policy)
        currentActivationPolicy = policy
    }

    private var shouldHoldTemporaryRegularPolicy: Bool {
        guard let expiration = temporaryRegularPolicyExpiration else {
            return false
        }

        if expiration > Date() {
            return true
        }

        temporaryRegularPolicyExpiration = nil
        return false
    }
}

@MainActor
final class ManagedWindowController {
    private let managedIdentifiers: Set<String>

    init(managedIdentifiers: Set<String>) {
        self.managedIdentifiers = managedIdentifiers
    }

    func hasManagedWindow(includeMiniaturized: Bool) -> Bool {
        NSApp.windows.contains { window in
            guard isManagedWindow(window) else {
                return false
            }

            if includeMiniaturized {
                return window.isVisible || window.isMiniaturized
            }

            return window.isVisible && !window.isMiniaturized
        }
    }

    func focusManagedWindow(
        identifier: String,
        remainingAttempts: Int = 4,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else {
                completion(false)
                return
            }

            guard let window = self.managedWindow(identifier: identifier) else {
                if remainingAttempts > 0 {
                    self.focusManagedWindow(
                        identifier: identifier,
                        remainingAttempts: remainingAttempts - 1,
                        completion: completion
                    )
                    return
                }

                completion(false)
                return
            }

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completion(true)
        }
    }

    func updateManagedWindowTitle(identifier: String, title: String) {
        guard let window = managedWindow(identifier: identifier) else {
            return
        }

        window.title = title
    }

    private func managedWindow(identifier: String) -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue == identifier
        }
    }

    private func isManagedWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else {
            return false
        }

        return managedIdentifiers.contains(identifier)
    }
}
