import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PowerLensStore
    @ObservedObject var softwareUpdateController: SoftwareUpdateController
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(TelemetryEnginePreference.storageKey) private var telemetryEnginePreference = TelemetryEnginePreference.auto.rawValue
    @AppStorage(DockIconPreference.storageKey) private var showDockIcon = DockIconPreference.defaultValue
    @AppStorage(MenuBarDisplayStylePreference.storageKey) private var menuBarDisplayStyle = MenuBarDisplayStylePreference.defaultValue
    @AppStorage(UpdateChannelPreference.storageKey) private var updateChannel = UpdateChannelPreference.defaultValue
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
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: telemetryEnginePreference) { _ in
            store.refreshNow()
        }
        .onChange(of: updateChannel) { _ in
            softwareUpdateController.updateChannelPreferenceChanged()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("ui.dashboardTitle"))
                    .font(.title2.weight(.bold))

                Text(L10n.text("ui.section.settings"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)

            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(Optional(pane.rawValue))
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(190)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            SettingsHeader(pane: selectedPane)

            Divider()

            ScrollView {
                selectedFormContent
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var selectedFormContent: some View {
        switch selectedPane {
        case .general:
            generalForm
        case .telemetry:
            telemetryForm
        case .behavior:
            behaviorForm
        }
    }

    private var generalForm: some View {
        SettingsGroup {
            PreferenceRow(
                title: L10n.text("language.title"),
                detail: L10n.text("language.description")
            ) {
                Picker(L10n.text("language.title"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 250)
            }
        }
    }

    private var telemetryForm: some View {
        SettingsGroup {
            TelemetryStatusRow(
                title: L10n.text("settings.telemetry.status"),
                statusText: store.telemetryStatusText,
                activeEngineName: store.activeTelemetryEngine.displayName
            )

            SettingsDivider()

            PreferenceRow(
                title: L10n.text("telemetry.label.preference"),
                detail: (TelemetryEnginePreference(rawValue: telemetryEnginePreference) ?? .auto).detail
            ) {
                Picker(L10n.text("telemetry.label.preference"), selection: $telemetryEnginePreference) {
                    ForEach(TelemetryEnginePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: SettingsLayout.controlColumnWidth)
            }

            SettingsDivider()

            ValueRow(
                title: L10n.text("telemetry.label.active"),
                detail: store.telemetryStatusText,
                value: store.activeTelemetryEngine.displayName
            )
        }
    }

    private var behaviorForm: some View {
        SettingsGroup {
            PreferenceRow(
                title: L10n.text("menuBarStyle.title"),
                detail: (MenuBarDisplayStylePreference(rawValue: menuBarDisplayStyle) ?? .powerLens).detail
            ) {
                MenuBarDisplayStyleMenu(selection: $menuBarDisplayStyle)
            }

            SettingsDivider()

            PreferenceRow(
                title: L10n.text("dockIcon.toggle"),
                detail: showDockIcon
                    ? L10n.text("dockIcon.description.visible")
                    : L10n.text("dockIcon.description.hidden")
            ) {
                Toggle(L10n.text("dockIcon.toggle"), isOn: $showDockIcon)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            SettingsDivider()

            PreferenceRow(
                title: L10n.text("updates.channel"),
                detail: (UpdateChannelPreference(rawValue: updateChannel) ?? .stable).detail
            ) {
                Picker(L10n.text("updates.channel"), selection: $updateChannel) {
                    ForEach(UpdateChannelPreference.allCases) { channel in
                        Text(channel.title).tag(channel.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!softwareUpdateController.isConfigured)
            }

            SettingsDivider()

            PreferenceRow(
                title: L10n.text("updates.check"),
                detail: softwareUpdateController.isConfigured
                    ? L10n.text("updates.check.description")
                    : L10n.text("updates.notConfigured")
            ) {
                Button(L10n.text("updates.check.button")) {
                    softwareUpdateController.checkForUpdates()
                }
                .disabled(!softwareUpdateController.canCheckForUpdates)
                .controlSize(.regular)
            }

            SettingsDivider()

            PreferenceRow(
                title: L10n.text("updates.automatic"),
                detail: softwareUpdateController.isConfigured
                    ? L10n.text("updates.automatic.description")
                    : L10n.text("updates.notConfigured")
            ) {
                Toggle(
                    L10n.text("updates.automatic"),
                    isOn: Binding(
                        get: { softwareUpdateController.automaticallyChecksForUpdates },
                        set: { softwareUpdateController.automaticallyChecksForUpdates = $0 }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!softwareUpdateController.isConfigured)
            }

            SettingsDivider()

            ValueRow(
                title: L10n.text("settings.currentMode"),
                detail: showDockIcon
                    ? L10n.text("dockIcon.mode.regular")
                    : L10n.text("dockIcon.mode.accessory"),
                value: showDockIcon ? L10n.text("common.on") : L10n.text("common.off")
            )
        }
    }
}
