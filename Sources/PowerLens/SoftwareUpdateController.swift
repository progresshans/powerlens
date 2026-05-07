import AppKit
import Sparkle

@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var didStartUpdater = false
    private var updaterStartErrorDescription: String?

    override init() {
        super.init()
    }

    var isConfigured: Bool {
        Self.hasConfiguredSparkleMetadata
    }

    var canCheckForUpdates: Bool {
        guard isConfigured else {
            return true
        }

        guard didStartUpdater else {
            return true
        }

        return updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            guard isConfigured, didStartUpdater else {
                return false
            }

            return updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            guard isConfigured else {
                showUnconfiguredAlert()
                return
            }

            guard startIfConfigured() else {
                showStartFailureAlert()
                return
            }

            updaterController.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    @discardableResult
    func startIfConfigured() -> Bool {
        guard isConfigured else {
            return false
        }

        guard !didStartUpdater else {
            return true
        }

        do {
            try updaterController.updater.start()
            didStartUpdater = true
            updaterStartErrorDescription = nil
            objectWillChange.send()
            return true
        } catch {
            updaterStartErrorDescription = error.localizedDescription
            NSLog("PowerLens Sparkle updater failed to start: \(error.localizedDescription)")
            objectWillChange.send()
            return false
        }
    }

    func checkForUpdates() {
        guard isConfigured else {
            showUnconfiguredAlert()
            return
        }

        guard startIfConfigured() else {
            showStartFailureAlert()
            return
        }

        updaterController.checkForUpdates(nil)
    }

    func updateChannelPreferenceChanged() {
        guard isConfigured, didStartUpdater else {
            objectWillChange.send()
            return
        }

        updaterController.updater.resetUpdateCycle()
        objectWillChange.send()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateChannelPreference.currentFeedURLString
    }

    private func showUnconfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.text("updates.unconfigured.title")
        alert.informativeText = L10n.text("updates.unconfigured.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text("common.ok"))
        alert.runModal()
    }

    private func showStartFailureAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.text("updates.startFailed.title")
        alert.informativeText = startFailureMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("common.ok"))
        alert.runModal()
    }

    private var startFailureMessage: String {
        let message = L10n.text("updates.startFailed.message")
        guard let updaterStartErrorDescription,
              !updaterStartErrorDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return message
        }

        return "\(message)\n\n\(updaterStartErrorDescription)"
    }

    private static var hasConfiguredSparkleMetadata: Bool {
        guard UpdateChannelPreference.feedURLString(for: .stable) != nil,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return true
    }
}
