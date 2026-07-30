import Testing
@testable import PowerLens

struct SettingsPaneTests {
    @Test
    func legacyStoredRawValuesMapToTheirReplacementPanes() {
        #expect(SettingsPane(storedRawValue: "behavior") == .general)
        #expect(SettingsPane(storedRawValue: "telemetry") == .data)
        #expect(SettingsPane(storedRawValue: "history") == .data)
    }

    @Test
    func canonicalStoredRawValuesRoundTrip() {
        for pane in SettingsPane.allCases {
            let decoded = SettingsPane(storedRawValue: pane.rawValue)

            #expect(decoded == pane)
            #expect(decoded.rawValue == pane.rawValue)
        }
    }

    @Test
    func unknownStoredRawValuesFallBackToGeneral() {
        #expect(SettingsPane(storedRawValue: "future-pane") == .general)
        #expect(SettingsPane(storedRawValue: "") == .general)
    }

    @Test
    func allCasesContainOnlyTheThreeCurrentPanesInSidebarOrder() {
        #expect(SettingsPane.allCases.count == 3)
        #expect(SettingsPane.allCases == [.general, .data, .updates])
    }

    @Test
    func rawValuesAreUnique() {
        let rawValues = SettingsPane.allCases.map(\.rawValue)

        #expect(Set(rawValues).count == rawValues.count)
    }
}
