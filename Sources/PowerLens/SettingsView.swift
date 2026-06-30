import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PowerLensStore
    @ObservedObject var softwareUpdateController: SoftwareUpdateController
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(TelemetryEnginePreference.storageKey) private var telemetryEnginePreference = TelemetryEnginePreference.auto.rawValue
    @AppStorage(DockIconPreference.storageKey) private var showDockIcon = DockIconPreference.defaultValue
    @AppStorage(MenuBarDisplayStylePreference.storageKey) private var menuBarDisplayStyle = MenuBarDisplayStylePreference.defaultValue
    @AppStorage(NotificationPreference.storageKey) private var notificationsEnabled = NotificationPreference.defaultValue
    @AppStorage(UpdateChannelPreference.storageKey) private var updateChannel = UpdateChannelPreference.defaultValue
    @AppStorage(RawHistoryWindow.storageKey) private var rawHistoryWindow = RawHistoryWindow.defaultValue
    @AppStorage(LongTermResolution.storageKey) private var longTermResolution = LongTermResolution.defaultValue
    @SceneStorage("settings.selectedPane") private var selectedPaneRaw = SettingsPane.general.rawValue

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    private var paneSelection: Binding<String?> {
        Binding(
            get: { selectedPaneRaw },
            set: { selectedPaneRaw = $0 ?? SettingsPane.general.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            launchAtLoginController.refresh()
        }
        .onChange(of: telemetryEnginePreference) { _ in
            store.refreshNow()
        }
        .onChange(of: updateChannel) { _ in
            softwareUpdateController.updateChannelPreferenceChanged()
        }
    }

    private var sidebar: some View {
        List(selection: paneSelection) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(Optional(pane.rawValue))
            }
        }
        .navigationSplitViewColumnWidth(min: 188, ideal: 200, max: 240)
    }

    private var detail: some View {
        Form {
            switch selectedPane {
            case .general:
                generalSection
            case .telemetry:
                telemetrySection
            case .history:
                historySection
            case .behavior:
                behaviorSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(selectedPane.title)
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        Section {
            LabeledContent {
                Picker(L10n.text("language.title"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
            } label: {
                rowLabel(L10n.text("language.title"))
            }
        }
    }

    // MARK: - Telemetry

    @ViewBuilder
    private var telemetrySection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    LiveDot()
                    StatusChip(text: store.activeTelemetryEngine.displayName)
                }
            } label: {
                rowLabel(L10n.text("settings.telemetry.status"), store.telemetryStatusText)
            }

            LabeledContent {
                Picker(L10n.text("telemetry.label.preference"), selection: $telemetryEnginePreference) {
                    ForEach(TelemetryEnginePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .labelsHidden()
            } label: {
                rowLabel(
                    L10n.text("telemetry.label.preference"),
                    (TelemetryEnginePreference(rawValue: telemetryEnginePreference) ?? .auto).detail
                )
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section {
            LabeledContent {
                Picker(L10n.text("history.rawWindow.title"), selection: $rawHistoryWindow) {
                    ForEach(RawHistoryWindow.allCases) { window in
                        Text(window.title).tag(window.rawValue)
                    }
                }
                .labelsHidden()
            } label: {
                rowLabel(L10n.text("history.rawWindow.title"), L10n.text("history.rawWindow.detail"))
            }

            LabeledContent {
                Picker(L10n.text("history.longTerm.title"), selection: $longTermResolution) {
                    ForEach(LongTermResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution.rawValue)
                    }
                }
                .labelsHidden()
                .disabled(rawHistoryWindow == RawHistoryWindow.forever.rawValue)
            } label: {
                rowLabel(L10n.text("history.longTerm.title"), L10n.text("history.longTerm.detail"))
            }
        }
    }

    // MARK: - Behavior

    @ViewBuilder
    private var behaviorSection: some View {
        Section {
            LabeledContent {
                Picker(L10n.text("menuBarStyle.title"), selection: $menuBarDisplayStyle) {
                    ForEach(MenuBarDisplayStylePreference.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .labelsHidden()
            } label: {
                rowLabel(
                    L10n.text("menuBarStyle.title"),
                    (MenuBarDisplayStylePreference(rawValue: menuBarDisplayStyle) ?? .powerLens).detail
                )
            }
        }

        Section {
            Toggle(isOn: $showDockIcon) {
                rowLabel(
                    L10n.text("dockIcon.toggle"),
                    showDockIcon
                        ? L10n.text("dockIcon.description.visible")
                        : L10n.text("dockIcon.description.hidden")
                )
            }

            Toggle(isOn: launchAtLoginBinding) {
                rowLabel(L10n.text("launchAtLogin.toggle"))
            }

            Toggle(isOn: $notificationsEnabled) {
                rowLabel(L10n.text("notifications.toggle"), L10n.text("notifications.description"))
            }
        }

        Section {
            LabeledContent {
                Picker(L10n.text("updates.channel"), selection: $updateChannel) {
                    ForEach(UpdateChannelPreference.allCases) { channel in
                        Text(channel.title).tag(channel.rawValue)
                    }
                }
                .labelsHidden()
                .disabled(!softwareUpdateController.isConfigured)
            } label: {
                rowLabel(
                    L10n.text("updates.channel"),
                    (UpdateChannelPreference(rawValue: updateChannel) ?? .stable).detail
                )
            }

            LabeledContent {
                Button(L10n.text("updates.check.button")) {
                    softwareUpdateController.checkForUpdates()
                }
                .disabled(!softwareUpdateController.canCheckForUpdates)
            } label: {
                rowLabel(
                    L10n.text("updates.check"),
                    softwareUpdateController.isConfigured
                        ? L10n.text("updates.check.description")
                        : L10n.text("updates.notConfigured")
                )
            }

            Toggle(isOn: automaticUpdatesBinding) {
                rowLabel(
                    L10n.text("updates.automatic"),
                    softwareUpdateController.isConfigured
                        ? L10n.text("updates.automatic.description")
                        : L10n.text("updates.notConfigured")
                )
            }
            .disabled(!softwareUpdateController.isConfigured)
        }
    }

    // MARK: - Helpers

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginController.isEnabled },
            set: { launchAtLoginController.setEnabled($0) }
        )
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { softwareUpdateController.automaticallyChecksForUpdates },
            set: { softwareUpdateController.automaticallyChecksForUpdates = $0 }
        )
    }

    @ViewBuilder
    private func rowLabel(_ title: String, _ detail: String? = nil) -> some View {
        if let detail, !detail.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(title)
        }
    }
}
