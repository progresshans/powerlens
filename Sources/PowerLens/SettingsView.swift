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
    @State private var isConfirmingLongTermHistoryDiscard = false

    private var selectedPane: SettingsPane {
        SettingsPane(storedRawValue: selectedPaneRaw)
    }

    private var paneSelection: Binding<String?> {
        Binding(
            get: { selectedPane.rawValue },
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
        .onChange(of: telemetryEnginePreference) {
            store.refreshNow()
        }
        .onChange(of: updateChannel) {
            softwareUpdateController.updateChannelPreferenceChanged()
        }
        .onChange(of: rawHistoryWindow) {
            store.historyRetentionPreferencesChanged()
        }
        .onChange(of: longTermResolution) {
            store.historyRetentionPreferencesChanged()
        }
        .alert(
            L10n.text("history.longTerm.off.confirm.title"),
            isPresented: $isConfirmingLongTermHistoryDiscard
        ) {
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(
                L10n.text("history.longTerm.off.confirm.action"),
                role: .destructive
            ) {
                longTermResolution = LongTermResolution.off.rawValue
            }
        } message: {
            Text(longTermHistoryDiscardMessage)
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
            case .data:
                dataSection
            case .updates:
                updatesSection
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

            Toggle(isOn: $showDockIcon) {
                rowLabel(
                    L10n.text("dockIcon.toggle"),
                    showDockIcon
                        ? L10n.text("dockIcon.description.visible")
                        : L10n.text("dockIcon.description.hidden")
                )
            }
        } header: {
            Text(L10n.text("settings.section.menuBarAndDock"))
        }

        Section {
            Toggle(isOn: launchAtLoginBinding) {
                rowLabel(L10n.text("launchAtLogin.toggle"))
            }

            Toggle(isOn: $notificationsEnabled) {
                rowLabel(L10n.text("notifications.toggle"), L10n.text("notifications.description"))
            }
        } header: {
            Text(L10n.text("settings.section.system"))
        }
    }

    // MARK: - Data

    @ViewBuilder
    private var dataSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    LiveDot(color: telemetryStatusColor)
                    StatusChip(text: telemetryStatusChipText)
                }
            } label: {
                rowLabel(L10n.text("settings.row.status"), store.telemetryStatusText)
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
        } header: {
            Text(L10n.text("settings.section.telemetry"))
        } footer: {
            Text(L10n.text("settings.section.telemetry.footer"))
        }

        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    LiveDot(color: historyStatusColor)
                    StatusChip(text: historyStatusChipText)
                }
            } label: {
                rowLabel(
                    L10n.text("settings.row.status"),
                    historyStatusDetailText
                )
            }

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
                Picker(L10n.text("history.longTerm.title"), selection: longTermResolutionBinding) {
                    ForEach(LongTermResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution.rawValue)
                    }
                }
                .labelsHidden()
                .disabled(rawHistoryWindow == RawHistoryWindow.forever.rawValue)
            } label: {
                rowLabel(
                    L10n.text("history.longTerm.title"),
                    longTermHistoryDetail
                )
            }
        } header: {
            Text(L10n.text("settings.section.history"))
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
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
                .disabled(
                    !softwareUpdateController.isConfigured
                        || !softwareUpdateController.canCheckForUpdates
                )
            } label: {
                rowLabel(
                    L10n.text("updates.check"),
                    L10n.text("updates.check.description")
                )
            }

            Toggle(isOn: automaticUpdatesBinding) {
                rowLabel(
                    L10n.text("updates.automatic"),
                    L10n.text("updates.automatic.description")
                )
            }
            .disabled(!softwareUpdateController.isConfigured)
        } footer: {
            if !softwareUpdateController.isConfigured {
                Text(L10n.text("updates.notConfigured"))
            }
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

    private var longTermResolutionBinding: Binding<String> {
        Binding(
            get: { longTermResolution },
            set: { proposedRawValue in
                guard let proposed = LongTermResolution(rawValue: proposedRawValue) else {
                    return
                }
                let current = LongTermResolution(rawValue: longTermResolution) ?? .daily

                if LongTermResolution.requiresDestructiveConfirmation(
                    from: current,
                    to: proposed
                ) {
                    isConfirmingLongTermHistoryDiscard = true
                    return
                }

                longTermResolution = proposed.rawValue
            }
        )
    }

    private var telemetryStatusChipText: String {
        switch store.telemetryHealth {
        case .waiting:
            L10n.text("telemetry.live.waiting")
        case .live:
            store.activeTelemetryEngine.displayName
        case .delayed:
            L10n.text("telemetry.delayed")
        case .unavailable:
            L10n.text("telemetry.unavailable")
        }
    }

    private var telemetryStatusColor: Color {
        switch store.telemetryHealth {
        case .waiting:
            .gray
        case .live:
            .green
        case .delayed:
            .orange
        case .unavailable:
            .red
        }
    }

    private var historyStatusChipText: String {
        switch store.historyHealth {
        case .checking:
            L10n.text("history.status.checking")
        case .available:
            L10n.text("history.status.available")
        case .degraded:
            L10n.text("history.status.degraded")
        }
    }

    private var historyStatusDetailText: String {
        switch store.historyHealth {
        case .checking:
            L10n.text("history.status.checking.detail")
        case .available:
            L10n.text("history.status.available.detail")
        case .degraded:
            L10n.text("history.status.degraded.detail")
        }
    }

    private var historyStatusColor: Color {
        switch store.historyHealth {
        case .checking:
            .gray
        case .available:
            .green
        case .degraded:
            .red
        }
    }

    private var longTermHistoryDetail: String {
        if longTermResolution == LongTermResolution.off.rawValue {
            return L10n.text("history.longTerm.off.detail")
        }
        return L10n.text("history.longTerm.detail")
    }

    private var longTermHistoryDiscardMessage: String {
        let window = RawHistoryWindow(rawValue: rawHistoryWindow) ?? .days90
        return L10n.tr("history.longTerm.off.confirm.message", window.title)
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
